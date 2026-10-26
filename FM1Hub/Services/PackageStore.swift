import Foundation

/// Downloads .fwsc packages from the hub, checks them against the catalogue (size, SHA-256, identity) and keeps
/// them in Documents/Packages so a firmware can be put back later without the network.
final class PackageStore {
    static let shared = PackageStore()

    func fileName(for f: Firmware) -> String {
        let v = f.version.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return "\(f.id)-\(v)-\(f.sha256.prefix(8)).fwsc"
    }

    func localURL(for f: Firmware) -> URL { Paths.packages.appendingPathComponent(fileName(for: f)) }
    var stockURL: URL { Paths.packages.appendingPathComponent("FM-1_015-official-V15.fwsc") }

    func isCached(_ f: Firmware) -> Bool { FileManager.default.fileExists(atPath: localURL(for: f).path) }
    var isStockCached: Bool { FileManager.default.fileExists(atPath: stockURL.path) }

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

    /// M-VAVE's official V15 as the hub serves it: only the exact file is accepted.
    func stockPackage(_ stock: StockFirmware?, onProgress: ((Double) -> Void)? = nil) async throws -> FWSCPackage {
        if let data = try? Data(contentsOf: stockURL), let p = try? FWSCPackage(data: data), p.isStockV15 { return p }
        let url = stock?.packageURL ?? HubAPI.url("fw/mvave/FM-1_015.fwsc")
        let data = try await download(url, expectedSize: FWSCPackage.stockV15Size, onProgress: onProgress)
        let p = try FWSCPackage(data: data)
        guard p.isStockV15 else { throw FM1Error.package("This is not the unmodified official FM-1 V15 file.") }
        try? data.write(to: stockURL, options: .atomic)
        return p
    }

    private func download(_ url: URL, expectedSize: Int, onProgress: ((Double) -> Void)?) async throws -> Data {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 60
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
        (try? FileManager.default.contentsOfDirectory(at: Paths.packages, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    }

    func cacheSize() -> Int64 { Paths.size(of: Paths.packages) }

    func clearCache() {
        for u in cachedFiles() { try? FileManager.default.removeItem(at: u) }
    }
}
