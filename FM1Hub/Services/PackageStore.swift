import Foundation

/// Downloads .fwsc packages, checks them (size, SHA-256, identity) and keeps every one in Documents/Packages, so a
/// firmware that was once on the device can always be put back without the network.
final class PackageStore {
    static let shared = PackageStore()

    func fileName(for f: Firmware) -> String {
        let v = f.version.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return "\(f.id)-\(v)-\(f.sha256.prefix(8)).fwsc"
    }

    func localURL(for f: Firmware) -> URL { Paths.packages.appendingPathComponent(fileName(for: f)) }
    var stockURL: URL { Paths.packages.appendingPathComponent("FM-1_015-official-V15.fwsc") }

    func isCached(_ f: Firmware) -> Bool { FileManager.default.fileExists(atPath: localURL(for: f).path) }

    // MARK: The hub

    /// The package of a firmware: from disk when it is there and still matches, else from the hub.
    func package(for f: Firmware, onProgress: ((Double) -> Void)? = nil) async throws -> FWSCPackage {
        let url = localURL(for: f)
        if let data = try? Data(contentsOf: url), let p = try? FWSCPackage(data: data), p.sha256 == f.sha256, p.product == f.product {
            return p
        }
        let data = try await download(f.packageURL, expectedSize: f.size, onProgress: onProgress)
        let p = try FWSCPackage(data: data)
        guard p.sha256 == f.sha256 else { throw FM1Error.package("The package does not match the catalogue (SHA-256). Refresh the catalogue and try again.") }
        guard p.product == f.product else { throw FM1Error.package("The package identity is \(p.product), the catalogue says \(f.product).") }
        try? data.write(to: url, options: .atomic)
        return p
    }

    /// M-VAVE's V15 as the hub serves it (the recovery image): only the exact file is accepted.
    func stockPackage(_ stock: StockFirmware?, onProgress: ((Double) -> Void)? = nil) async throws -> FWSCPackage {
        if let data = try? Data(contentsOf: stockURL), let p = try? FWSCPackage(data: data), p.isStockV15 { return p }
        let url = stock?.packageURL ?? HubAPI.url("fw/mvave/FM-1_015.fwsc")
        let data = try await download(url, expectedSize: FWSCPackage.stockV15Size, onProgress: onProgress)
        let p = try FWSCPackage(data: data)
        guard p.isStockV15 else { throw FM1Error.package("This is not the unmodified official FM-1 V15 file.") }
        try? data.write(to: stockURL, options: .atomic)
        return p
    }

    // MARK: M-VAVE's own server

    /// The current official firmware from M-VAVE's download server (V16 at the time of writing; whatever they publish next).
    /// `cachedOnly`: no network, the newest official package on the phone.
    func officialLatest(cachedOnly: Bool = false, onProgress: ((Double) -> Void)? = nil) async throws -> FWSCPackage {
        if cachedOnly {
            guard let p = newestCachedOfficial() else { throw FM1Error.package("No official firmware on this phone yet.") }
            return p
        }
        let data = try await download(HubAPI.officialLatest, expectedSize: 720_000, onProgress: onProgress)
        let p = try FWSCPackage(data: data)
        guard p.isOfficial else { throw FM1Error.package("M-VAVE's file is not an official FM-1 firmware (it reports \(p.product)).") }
        guard p.bytes.count > 200_000, p.bytes.count < 4_000_000 else { throw FM1Error.package("M-VAVE's file has an unexpected size.") }
        keep(p)
        return p
    }

    func newestCachedOfficial() -> FWSCPackage? {
        var best: FWSCPackage?
        for u in cachedFiles() where u.lastPathComponent.hasPrefix("FM-1_0") {
            if let data = try? Data(contentsOf: u), let p = try? FWSCPackage(data: data), p.isOfficial {
                if best == nil || p.product > best!.product { best = p }
            }
        }
        return best
    }

    // MARK: The phone

    /// Keeps a package under its identity and hash, whatever its source (a file, M-VAVE, a maker's release).
    @discardableResult
    func keep(_ p: FWSCPackage) -> URL {
        let url = Paths.packages.appendingPathComponent("\(p.product)-\(p.sha256.prefix(8)).fwsc")
        if !FileManager.default.fileExists(atPath: url.path) { try? Data(p.bytes).write(to: url, options: .atomic) }
        return url
    }

    /// A package with this identity anywhere on the phone: the package cache, or inside an earlier backup.
    func localPackage(product: String) -> FWSCPackage? {
        var urls = cachedFiles()
        if let snaps = try? FileManager.default.contentsOfDirectory(at: Paths.snapshots, includingPropertiesForKeys: nil) {
            for d in snaps { urls.append(d.appendingPathComponent("package.fwsc")) }
        }
        for u in urls {
            guard let h = FileHandle(forReadingAtPath: u.path) else { continue }
            let head = (try? h.read(upToCount: FWSCPackage.blocks * FWSCPackage.blockSize)) ?? nil
            try? h.close()
            guard let head = head, head.count == FWSCPackage.blocks * FWSCPackage.blockSize, FWSCPackage.productOf([UInt8](head)) == product else { continue }
            if let data = try? Data(contentsOf: u), let p = try? FWSCPackage(data: data), p.product == product { return p }
        }
        return nil
    }

    // MARK: The makers' GitHub releases

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String; let size: Int }
        let tag_name: String
        let assets: [Asset]
    }

    /// The release package that reports `product`, among the latest releases of the candidates' repositories.
    /// `onStatus` names what is being tried, for the progress sheet.
    func releasePackage(product: String, candidates: [Firmware], onStatus: @escaping (String) -> Void) async -> FWSCPackage? {
        for f in candidates {
            guard let repo = f.repo, !repo.isEmpty else { continue }
            onStatus("Checking \(f.name)'s releases on GitHub…")
            var req = URLRequest(url: HubAPI.releases(repo: repo))
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 20
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let releases = try? JSONDecoder().decode([Release].self, from: data) else { continue }
            // the FM-1 packages, the plain build before SMK-37 variants, newest release first
            var assets: [(String, Release.Asset)] = []
            for r in releases {
                let fw = r.assets.filter { $0.name.lowercased().hasSuffix(".fwsc") && $0.size > 100_000 && $0.size < 4_000_000 }
                    .sorted { ($0.name.lowercased().contains("smk") ? 1 : 0) < ($1.name.lowercased().contains("smk") ? 1 : 0) }
                for a in fw { assets.append((r.tag_name, a)) }
            }
            for (tag, a) in assets.prefix(8) {
                guard let url = URL(string: a.browser_download_url) else { continue }
                onStatus("Trying \(f.name) \(tag): \(a.name)…")
                guard let data = try? await download(url, expectedSize: a.size, onProgress: nil),
                      let p = try? FWSCPackage(data: data) else { continue }
                if p.product == product {
                    keep(p)
                    return p
                }
            }
        }
        return nil
    }

    // MARK: Plumbing

    private func download(_ url: URL, expectedSize: Int, onProgress: ((Double) -> Void)?) async throws -> Data {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 60
        req.setValue("FM1Hub-iOS", forHTTPHeaderField: "User-Agent")
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FM1Error.package("The package could not be downloaded (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let total = http.expectedContentLength > 0 ? Int(http.expectedContentLength) : expectedSize
        var data = Data()
        data.reserveCapacity(max(total, 0))
        var last = 0
        for try await b in bytes {
            data.append(b)
            if total > 0, data.count - last >= 16384 {
                last = data.count
                onProgress?(min(1, Double(data.count) / Double(total)))
            }
        }
        onProgress?(1)
        return data
    }

    func cachedFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: Paths.packages, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "fwsc" }
    }

    func cacheSize() -> Int64 { Paths.size(of: Paths.packages) }

    func clearCache() {
        for u in cachedFiles() { try? FileManager.default.removeItem(at: u) }
    }
}
