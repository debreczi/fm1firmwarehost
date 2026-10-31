import Foundation

extension Date {
    /// Rounded down to the second, which is the precision the library is written with. Records are stamped with
    /// this so that the value in memory is the same value after a save and a load: anything finer survives in
    /// memory, vanishes on the disk, and makes two copies of one record compare unequal.
    var toTheSecond: Date { Date(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate.rounded(.down)) }
    /// Now, at the precision the library keeps.
    static var nowToTheSecond: Date { Date().toTheSecond }
}

/// How a package reached the device.
enum InstallSource: String, Codable {
    case hub, stock, snapshot, file, resume
}

/// One install attempt, as the app remembers it.
struct InstallRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date.nowToTheSecond
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

/// A library that could not be read, and where its bytes were put instead. Kept in the library itself so the
/// warning outlives the relaunch: the old history lives only in that file until the user has fetched it.
/// The file is named after a hash of its own contents, so one bad library is kept once and two are kept apart.
struct RescueNote: Codable, Hashable {
    var date: Date
    var file: String
    var text: String

    init(date: Date = Date(), file: String, text: String) {
        self.date = date.toTheSecond
        self.file = file
        self.text = text
    }
}

/// Something the app has to own up to about its own saved lists: a library it could not read, or one it could not
/// write. Shown on the screens that display those lists.
struct LibraryNotice: Identifiable, Hashable {
    enum Kind: String { case write, rescue }
    var kind: Kind
    var text: String
    /// For a rescue notice: the copy it is about. Several can be outstanding at once.
    var file: String?

    var id: String { file.map { "\(kind.rawValue):\($0)" } ?? kind.rawValue }
    /// A rescue notice outlives any number of successful writes, so only the user can put it away. A write problem
    /// clears itself as soon as a write succeeds.
    var dismissible: Bool { kind == .rescue }
}

/// The package that is being written to the device right now. It is saved before the loader is entered and cleared
/// only once the device comes back with the expected identity, so an interrupted update resumes with that very
/// package — never with whatever happened to be installed successfully last.
struct PendingUpdate: Codable, Hashable {
    var id = UUID()
    var date = Date.nowToTheSecond
    var product: String             // the identity the package reports, "FM-1_904"
    var sha256: String              // the exact package: Resume accepts no other build
    var firmwareId: String?         // the hub's id, when the package came from the catalogue
    var name: String
    var version: String
    var usesStockLoader: Bool       // the official loader writes this one, not the hub's
    var source: InstallSource
    /// What the device reported just before the attempt, when the app knew. Reconciling a finished update later
    /// depends on it: see `isFinished(by:)`.
    var identityBefore: String?

    /// True when a device reporting this identity has already finished what this record was for, even if this app
    /// was not watching when it happened. Three things have to hold: the device is running the identity the record
    /// aimed at, it is not sitting in a loader, and it was running something *else* before the attempt.
    ///
    /// That last condition is the whole reason this record carries a SHA-256. Two builds of one firmware report the
    /// same identity and differ only by hash, so if the device already reported this identity beforehand — a
    /// re-install, or a rebuilt package of what is already on it — a later identity match says nothing about which
    /// build is running, and the exact record must stay. The same goes for not having known at all.
    func isFinished(by id: FM1Identity) -> Bool {
        guard let before = identityBefore else { return false }
        return !id.isLoader && id.text == product && before != product
    }
}

/// A saved state of the FM-1: which firmware was on it, the exact package to put it back, and (for Felucca-family
/// firmwares) an archive of the music, settings, projects and samples.
struct Snapshot: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date.nowToTheSecond
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
