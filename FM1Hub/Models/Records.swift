import Foundation

/// How a package reached the device.
enum InstallSource: String, Codable {
    case hub, stock, snapshot, file, resume
}

/// One install attempt, as the app remembers it.
struct InstallRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var firmwareId: String?
    var name: String
    var version: String
    var product: String
    var sha256: String?
    var identityBefore: String?
    var identityAfter: String?
    var source: InstallSource
    var success: Bool
    var error: String?
}

/// A saved state of the FM-1: which firmware was on it, the exact package to put it back, and (for Felucca-family
/// firmwares) an archive of the music, settings, projects and samples.
struct Snapshot: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var name: String
    var identity: String                // what the device reported, "FM-1_900"
    var firmwareId: String?             // the hub's id when known
    var firmwareName: String            // "Felucca" or "another firmware (FM-1_123)"
    var version: String?
    var product: String?                // the package identity, when a package is stored
    var packageFile: String?            // relative to the snapshot folder
    var packageSHA256: String?
    var packageSize: Int?
    var packageExact: Bool              // the package is known to be the very version that was on the device
    var archiveFile: String?            // "felucca-backup.json", relative to the snapshot folder
    var archiveBytes: Int?
    var archiveObjects: Int?
    var notes: String = ""

    var hasPackage: Bool { packageFile != nil }
    var hasArchive: Bool { archiveFile != nil }
}
