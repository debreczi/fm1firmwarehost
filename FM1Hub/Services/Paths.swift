import Foundation

/// Where the app keeps things. Documents is visible in the Files app ("On My iPhone > FM-1 Hub"), so packages and
/// snapshots can be copied out, shared, or put in iCloud Drive by hand.
enum Paths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }
    static var packages: URL { ensure(documents.appendingPathComponent("Packages", isDirectory: true)) }
    static var snapshots: URL { ensure(documents.appendingPathComponent("Snapshots", isDirectory: true)) }
    static var library: URL { documents.appendingPathComponent("library.json") }
    static var catalogCache: URL { caches.appendingPathComponent("catalog.json") }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            if let s = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize { total += Int64(s) }
        }
        return total
    }
}
