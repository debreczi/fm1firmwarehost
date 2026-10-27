import Foundation
import Observation

/// What the app remembers: every install, and the snapshots of the device. Kept as JSON in Documents.
@MainActor
@Observable
final class LibraryStore {
    private struct Library: Codable {
        var history: [InstallRecord] = []
        var snapshots: [Snapshot] = []
    }

    private(set) var history: [InstallRecord] = []
    private(set) var snapshots: [Snapshot] = []

    init() {
        load()
        recoverSnapshots()
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.library) else { return }
        if let lib = try? LibraryStore.decoder().decode(Library.self, from: data) {
            history = lib.history.sorted { $0.date > $1.date }
            snapshots = lib.snapshots.sorted { $0.date > $1.date }
        } else {
            // never overwrite what could not be read: keep it next to the new one
            let keep = Paths.documents.appendingPathComponent("library-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: Paths.library, to: keep)
        }
    }

    private func save() {
        let lib = Library(history: history, snapshots: snapshots)
        if let data = try? LibraryStore.encoder().encode(lib) { try? data.write(to: Paths.library, options: .atomic) }
    }

    /// Each backup's own record, next to its files: the index can always be rebuilt from the folders.
    private func writeRecord(_ s: Snapshot) {
        let folder = Paths.ensure(folder(for: s))
        if let data = try? LibraryStore.encoder().encode(s) {
            try? data.write(to: folder.appendingPathComponent("snapshot.json"), options: .atomic)
        }
    }

    /// Backups whose folder is there but the index does not list: from their own record, else rebuilt from their files
    /// (the package names the firmware, the music archive its identity and date).
    private func recoverSnapshots() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.snapshots, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let known = Set(snapshots.map(\.id))
        var found: [Snapshot] = []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent), !known.contains(id) else { continue }
            if let data = try? Data(contentsOf: dir.appendingPathComponent("snapshot.json")),
               let s = try? LibraryStore.decoder().decode(Snapshot.self, from: data), s.id == id {
                found.append(s)
                continue
            }
            let pkgURL = dir.appendingPathComponent("package.fwsc")
            let arcURL = dir.appendingPathComponent("felucca-backup.json")
            let pkg = (try? Data(contentsOf: pkgURL)).flatMap { try? FWSCPackage(data: $0) }
            let archive = (try? Data(contentsOf: arcURL)).flatMap { try? JSONDecoder().decode(FeluccaArchive.self, from: $0) }
            guard pkg != nil || archive != nil else { continue }   // an empty folder holds nothing to restore
            let identity = archive?.firmware ?? pkg!.product
            let created = archive.flatMap { ISO8601DateFormatter().date(from: $0.created) }
                ?? (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            var s = Snapshot(name: "Recovered backup · \(identity)", identity: identity, firmwareId: nil,
                             firmwareName: pkg?.officialVersion.map { _ in "Official firmware" } ?? identity,
                             version: pkg?.officialVersion, product: pkg?.product,
                             packageFile: pkg != nil ? "package.fwsc" : nil, packageSHA256: pkg?.sha256, packageSize: pkg?.bytes.count,
                             packageExact: pkg?.product == identity,
                             archiveFile: archive != nil ? "felucca-backup.json" : nil,
                             archiveBytes: archive?.totalBytes, archiveObjects: archive?.objects.count)
            s.id = id
            s.date = created
            found.append(s)
        }
        guard !found.isEmpty else { return }
        snapshots = (snapshots + found).sorted { $0.date > $1.date }
        for s in found { writeRecord(s) }
        save()
    }

    /// Names recovered backups after the catalogue is loaded ("Skiff" instead of "FM-1_720" where the hub knows it).
    func nameRecovered(using catalog: CatalogStore) {
        var changed = false
        for i in snapshots.indices where snapshots[i].firmwareName == snapshots[i].identity {
            if let w = catalog.whoIs(snapshots[i].identity) {
                let n = w.firmware?.name ?? w.name
                if n != snapshots[i].firmwareName {
                    snapshots[i].firmwareName = n
                    if snapshots[i].firmwareId == nil, w.exact { snapshots[i].firmwareId = w.firmware?.id }
                    writeRecord(snapshots[i])
                    changed = true
                }
            }
        }
        if changed { save() }
    }

    // MARK: History

    func add(_ r: InstallRecord) {
        history.insert(r, at: 0)
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    func installCount(firmwareId: String) -> Int {
        history.filter { $0.firmwareId == firmwareId && $0.success }.count
    }

    /// The last firmware that was successfully put on the device, by its identity.
    var lastInstalled: InstallRecord? { history.first { $0.success } }

    // MARK: Snapshots

    func folder(for s: Snapshot) -> URL { Paths.snapshots.appendingPathComponent(s.id.uuidString, isDirectory: true) }

    func packageURL(for s: Snapshot) -> URL? {
        guard let f = s.packageFile else { return nil }
        return folder(for: s).appendingPathComponent(f)
    }

    func archiveURL(for s: Snapshot) -> URL? {
        guard let f = s.archiveFile else { return nil }
        return folder(for: s).appendingPathComponent(f)
    }

    func add(_ s: Snapshot) {
        snapshots.insert(s, at: 0)
        writeRecord(s)
        save()
    }

    func update(_ s: Snapshot) {
        if let i = snapshots.firstIndex(where: { $0.id == s.id }) { snapshots[i] = s; writeRecord(s); save() }
    }

    func remove(_ s: Snapshot) {
        snapshots.removeAll { $0.id == s.id }
        try? FileManager.default.removeItem(at: folder(for: s))
        save()
    }

    func snapshotsSize() -> Int64 { Paths.size(of: Paths.snapshots) }
}
