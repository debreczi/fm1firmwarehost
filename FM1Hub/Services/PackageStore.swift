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
        let data = try await download(f.packageURL, expectedSize: f.size, exactSize: f.size > 0 ? f.size : nil, onProgress: onProgress)
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
        let data = try await download(url, expectedSize: FWSCPackage.stockV15Size, exactSize: FWSCPackage.stockV15Size, onProgress: onProgress)
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
        // M-VAVE publish no size for this one, so only the ceiling in download() and this floor bound it.
        let data = try await download(HubAPI.officialLatest, expectedSize: 720_000, onProgress: onProgress)
        guard data.count > 200_000 else { throw FM1Error.package("M-VAVE's file is only \(data.count) bytes: not an FM-1 firmware.") }
        let p = try FWSCPackage(data: data)
        guard p.isOfficial else { throw FM1Error.package("M-VAVE's file is not an official FM-1 firmware (it reports \(p.product)).") }
        try? keep(p)
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
    /// Throws when the phone cannot store it: an install about to enter the loader needs this to have worked, or an
    /// interrupted update has no package to resume from.
    @discardableResult
    func keep(_ p: FWSCPackage) throws -> URL {
        let url = Paths.packages.appendingPathComponent("\(p.product)-\(p.sha256.prefix(8)).fwsc")
        // A file already under that name may be a truncated earlier write: only its own bytes may vouch for it,
        // because this is the file a resume looks up by hash later. Anything else is replaced.
        if let there = try? Data(contentsOf: url), FWSCPackage.sha256Hex(there) == p.sha256 { return url }
        do {
            try Data(p.bytes).write(to: url, options: .atomic)
        } catch {
            throw FM1Error.package("The package could not be stored on the phone (\(error.localizedDescription)). Free some space and try again.")
        }
        return url
    }

    /// A package with this identity anywhere on the phone: the package cache, or inside an earlier backup.
    /// With `sha256` given, only that exact build counts.
    func localPackage(product: String, sha256: String? = nil) -> FWSCPackage? {
        var urls = cachedFiles()
        if let snaps = try? FileManager.default.contentsOfDirectory(at: Paths.snapshots, includingPropertiesForKeys: nil) {
            for d in snaps { urls.append(d.appendingPathComponent("package.fwsc")) }
        }
        for u in urls {
            guard let h = FileHandle(forReadingAtPath: u.path) else { continue }
            let head = (try? h.read(upToCount: FWSCPackage.blocks * FWSCPackage.blockSize)) ?? nil
            try? h.close()
            guard let head = head, head.count == FWSCPackage.blocks * FWSCPackage.blockSize, FWSCPackage.productOf([UInt8](head)) == product else { continue }
            if let data = try? Data(contentsOf: u), let p = try? FWSCPackage(data: data), p.product == product,
               sha256 == nil || p.sha256 == sha256 { return p }
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
                guard let data = try? await download(url, expectedSize: a.size, exactSize: a.size, onProgress: nil),
                      let p = try? FWSCPackage(data: data) else { continue }
                if p.product == product {
                    try? keep(p)
                    return p
                }
            }
        }
        return nil
    }

    // MARK: Plumbing

    /// The largest .fwsc that can still be a plausible FM-1 package (they are about 0.7 MB). A body that passes this
    /// is refused, so a broken or hostile endpoint cannot fill the phone's memory until the app is killed.
    static let maxPackageBytes = 4_000_000

    /// Streams a package into memory under a hard ceiling. `exactSize` is the size the catalogue (or a GitHub
    /// release) states for this asset: when it is given, the body has to match it to the byte, before anything is
    /// parsed or kept. `expectedSize` is only the progress bar's estimate for when the server announces no length.
    private func download(_ url: URL, expectedSize: Int, exactSize: Int? = nil,
                          maxBytes: Int = PackageStore.maxPackageBytes,
                          onProgress: ((Double) -> Void)?) async throws -> Data {
        if let exact = exactSize, exact <= 0 || exact > maxBytes {
            throw FM1Error.package("This package is listed as \(exact) bytes, which cannot be an FM-1 package. Nothing was downloaded.")
        }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 60
        req.setValue("FM1Hub-iOS", forHTTPHeaderField: "User-Agent")
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FM1Error.package("The package could not be downloaded (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        // what the server says it will send, refused before the first byte is kept
        let announced = http.expectedContentLength > 0 ? Int(http.expectedContentLength) : nil
        if let n = announced, n > maxBytes {
            throw FM1Error.package("The server offers \(n) bytes for a package; this app accepts at most \(maxBytes). Nothing was downloaded.")
        }
        if let exact = exactSize, let n = announced, n != exact {
            throw FM1Error.package("The server offers \(n) bytes, the catalogue says \(exact). Refresh the catalogue and try again.")
        }
        let total = announced ?? exactSize ?? expectedSize
        var data = Data()
        data.reserveCapacity(min(max(total, 0), maxBytes))
        var last = 0
        for try await b in bytes {
            data.append(b)
            if data.count > maxBytes {
                throw FM1Error.package("The download passed \(maxBytes) bytes without ending, so it is not an FM-1 package. It was stopped.")
            }
            if total > 0, data.count - last >= 16384 {
                last = data.count
                onProgress?(min(1, Double(data.count) / Double(total)))
            }
        }
        if let exact = exactSize, data.count != exact {
            throw FM1Error.package("The package is \(data.count) bytes, the catalogue says \(exact). Nothing was kept.")
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
