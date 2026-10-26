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

    init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: Paths.library),
              let lib = try? JSONDecoder().decode(Library.self, from: data) else { return }
        history = lib.history.sorted { $0.date > $1.date }
        snapshots = lib.snapshots.sorted { $0.date > $1.date }
    }

    private func save() {
        let lib = Library(history: history, snapshots: snapshots)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(lib) { try? data.write(to: Paths.library, options: .atomic) }
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
        save()
    }

    func update(_ s: Snapshot) {
        if let i = snapshots.firstIndex(where: { $0.id == s.id }) { snapshots[i] = s; save() }
    }

    func remove(_ s: Snapshot) {
        snapshots.removeAll { $0.id == s.id }
        try? FileManager.default.removeItem(at: folder(for: s))
        save()
    }

    func snapshotsSize() -> Int64 { Paths.size(of: Paths.snapshots) }
}
