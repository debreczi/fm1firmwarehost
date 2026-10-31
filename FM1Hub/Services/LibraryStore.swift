import Foundation
import Observation

/// What the app remembers: every install, the update being written, and the snapshots of the device.
/// Kept as JSON in Documents.
@MainActor
@Observable
final class LibraryStore {
    /// Every field is read with `decodeIfPresent`, because a library written by an older version of the app does
    /// not have the newer keys — and synthesised `Decodable` would throw on a missing one rather than fall back to
    /// the declared default, turning an upgrade into a corrupt library and an empty history.
    private struct Library: Codable {
        var history: [InstallRecord] = []
        var snapshots: [Snapshot] = []
        var pending: PendingUpdate?
        var rescues: [RescueNote] = []

        init(history: [InstallRecord] = [], snapshots: [Snapshot] = [],
             pending: PendingUpdate? = nil, rescues: [RescueNote] = []) {
            self.history = history
            self.snapshots = snapshots
            self.pending = pending
            self.rescues = rescues
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            history = try c.decodeIfPresent([InstallRecord].self, forKey: .history) ?? []
            snapshots = try c.decodeIfPresent([Snapshot].self, forKey: .snapshots) ?? []
            pending = try c.decodeIfPresent(PendingUpdate.self, forKey: .pending)
            rescues = try c.decodeIfPresent([RescueNote].self, forKey: .rescues) ?? []
        }
    }

    private(set) var history: [InstallRecord] = []
    private(set) var snapshots: [Snapshot] = []
    /// The package being written right now, or the one that was being written when an update was interrupted.
    /// This is what the app believes; `write()` is what gets it onto the disk.
    private(set) var pending: PendingUpdate?

    /// Every library that could not be read and is still waiting to be fetched, newest first. Saved with the
    /// library so they survive the relaunch: only the user puts one away, because only the user can go and get
    /// that file. There can be more than one, and a later failure must not quietly replace an earlier one.
    private(set) var rescueNotes: [RescueNote] = []
    /// The last write that did not reach the disk. Cleared the moment one does.
    private(set) var writeProblem: String?

    /// True while the app believes something the disk has not taken. Cleared by the next write that succeeds.
    var unsaved: Bool { writeProblem != nil }

    /// What stands between an unreadable library and the write that would replace it. While one is held, nothing is
    /// allowed to write over the original: it is the only copy of the user's history, and an ordinary install must
    /// not be what destroys it. Every write tries again first, so the hold clears itself as soon as it can.
    private enum Hold {
        /// Read, but with nowhere to be copied to yet. `file` is the name the copy will have.
        case bytes(Data, file: String)
        /// There, but not even readable. Nothing can be kept aside yet — and a read that fails is no proof that a
        /// write would, so the original still must not be replaced.
        case unreadable(file: String)

        /// The notice this hold belongs to. Only that one's dismissal can release it.
        var file: String {
            switch self {
            case .bytes(_, let f): return f
            case .unreadable(let f): return f
            }
        }
    }
    private var hold: Hold?

    /// What the screens show, worst first.
    var notices: [LibraryNotice] {
        (writeProblem.map { [LibraryNotice(kind: .write, text: $0)] } ?? [])
            + rescueNotes.map { LibraryNotice(kind: .rescue, text: $0.text, file: $0.file) }
    }

    /// The first thing that is wrong, if anything is.
    var problem: String? { notices.first?.text }

    func dismiss(_ n: LibraryNotice) {
        settle()
        switch n.kind {
        case .rescue:
            // The file itself is kept — it is the user's data — but renamed out of the outstanding namespace, so a
            // later corruption rebuilding the list from the folder does not raise a notice already put away. The
            // rename *is* the acknowledgement, so if it fails the notice stays: pretending otherwise would let the
            // warning come back later with no explanation.
            if let f = n.file, f.hasPrefix(LibraryStore.outstanding) {
                do {
                    try acknowledge(f)
                } catch {
                    writeProblem = "That warning could not be put away (\(error.localizedDescription)): the rescue "
                        + "file is still in the app's folder under its old name. Try again in a moment."
                    return
                }
            }
            // The user says they have *these* bytes, which releases the hold only if the hold is about them.
            // Acknowledging one rescue says nothing about another library whose bytes still have nowhere to live.
            if hold?.file == n.file { hold = nil }
            rescueNotes.removeAll { $0.file == n.file }
            save()
        case .write:
            writeProblem = nil
        }
    }

    /// Tries again: both to read a library that would not read at launch, and to write a state that did not land.
    /// Quiet, because the notices already say what is wrong; called from ordinary places like Connect rather than
    /// by the user, so a store with nothing outstanding does nothing at all.
    func flush() {
        let holding = hold != nil
        settle()
        guard unsaved || holding else { return }
        save()
    }

    /// How the library reaches the disk and comes back. Seams, so the failure paths can be tested without having
    /// to fill up a phone or take away its read permissions.
    typealias Writer = @MainActor (Data, URL) throws -> Void
    typealias Reader = @MainActor (URL) throws -> Data
    private let writeData: Writer
    private let readData: Reader
    /// Where the library and its rescue copies live. Injected so the tests cannot touch the real ones.
    private let folder: URL
    private var file: URL { folder.appendingPathComponent("library.json") }

    init(folder: URL = Paths.documents,
         readData: @escaping Reader = { try Data(contentsOf: $0) },
         writeData: @escaping Writer = { data, url in try data.write(to: url, options: .atomic) }) {
        self.folder = folder
        self.readData = readData
        self.writeData = writeData
        if Demo.isOn { return }   // the screenshot mode never reads or writes the real library
        load()
        // Not while a library is held: what it holds may be a better record of these same backups.
        if hold == nil { recoverSnapshots() }
    }

    /// Dates are written as ISO-8601, so they have to be read that way too. A library from an older build (or one
    /// edited by hand) may carry the numeric form Foundation defaults to; both are accepted.
    static func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                if let d = try? Date(s, strategy: .iso8601) { return d }
                if let d = try? Date(s, strategy: .iso8601.time(includingFractionalSeconds: true)) { return d }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not an ISO-8601 date: \(s)")
            }
            let seconds = try c.decode(Double.self)
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        return dec
    }

    static func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    /// Sample backups and installs for the screenshot mode, in memory only (save() is never reached from here).
    func seedDemo(catalog: CatalogStore) {
        let now = Date()
        func ago(_ h: Double) -> Date { now.addingTimeInterval(-h * 3600) }
        func fw(_ id: String) -> Firmware? { catalog.firmware(id: id) }
        var snaps: [Snapshot] = []
        if let f = fw("felucca") {
            var s = Snapshot(name: "Live set, October", identity: f.product, firmwareId: f.id, firmwareName: f.name, version: f.version,
                             product: f.product, packageFile: "package.fwsc", packageSHA256: f.sha256, packageSize: f.size, packageExact: true,
                             archiveFile: "felucca-backup.json", archiveBytes: 262_144 + 18_432, archiveObjects: 13)
            s.date = ago(3)
            snaps.append(s)
        }
        if let f = fw("melodee") {
            var s = Snapshot(name: "Prophet patches", identity: f.product, firmwareId: f.id, firmwareName: f.name, version: f.version,
                             product: f.product, packageFile: "package.fwsc", packageSHA256: f.sha256, packageSize: f.size, packageExact: true,
                             archiveFile: "felucca-backup.json", archiveBytes: 23_040, archiveObjects: 13)
            s.date = ago(30)
            snaps.append(s)
        }
        var off = Snapshot(name: "Factory state", identity: "FM-1_016", firmwareId: nil, firmwareName: "Official firmware", version: "V16",
                           product: "FM-1_016", packageFile: "package.fwsc", packageSHA256: nil, packageSize: 718_196, packageExact: true,
                           archiveFile: nil, archiveBytes: nil, archiveObjects: nil)
        off.date = ago(80)
        snaps.append(off)
        snapshots = snaps

        var recs: [InstallRecord] = []
        func rec(_ id: String, _ h: Double, ok: Bool = true, before: String?, err: String? = nil) {
            guard let f = fw(id) else { return }
            var r = InstallRecord(firmwareId: f.id, name: f.name, version: f.version, product: f.product, sha256: f.sha256,
                                  identityBefore: before, identityAfter: ok ? f.product : nil, source: .hub, success: ok, error: err)
            r.date = ago(h)
            recs.append(r)
        }
        rec("felucca", 2, before: fw("x0x")?.product)
        rec("x0x", 26, before: fw("melodee")?.product)
        rec("melodee", 29, before: "FM-1_016")
        var o = InstallRecord(firmwareId: nil, name: "Official firmware", version: "V16", product: "FM-1_016", sha256: nil,
                              identityBefore: fw("zp12")?.product, identityAfter: "FM-1_016", source: .stock, success: true)
        o.date = ago(52)
        recs.append(o)
        rec("zp12", 75, before: "FM-1_015")
        history = recs.sorted { $0.date > $1.date }
    }

    /// Each backup's own record, next to its files: the index can always be rebuilt from the folders.
    private func writeRecord(_ s: Snapshot) {
        if Demo.isOn { return }
        let dir = Paths.ensure(folder(for: s))
        if let data = try? LibraryStore.makeEncoder().encode(s) {
            try? data.write(to: dir.appendingPathComponent("snapshot.json"), options: .atomic)
        }
    }

    /// Backups whose folder is there but the index does not list: from their own record, else rebuilt from their files
    /// (the package names the firmware, the music archive its identity and date).
    private func recoverSnapshots() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: snapshotsRoot, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let known = Set(snapshots.map(\.id))
        var found: [Snapshot] = []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent), !known.contains(id) else { continue }
            if let data = try? Data(contentsOf: dir.appendingPathComponent("snapshot.json")),
               let s = try? LibraryStore.makeDecoder().decode(Snapshot.self, from: data), s.id == id {
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

    /// Two different things can go wrong, and conflating them loses a perfectly good library: a read that fails
    /// says nothing at all about the contents, while bytes that will not decode are genuinely bad. Only the second
    /// is a rescue. The first leaves the file alone, protected, to be settled by a later read.
    private func load() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let data: Data
        do {
            data = try readData(file)
        } catch {
            hold = .unreadable(file: "library.json")
            rescueNotes = [RescueNote(file: "library.json",
                                      text: "The saved history and backup list could not be read "
                                          + "(\(error.localizedDescription)). It may be perfectly good, so nothing "
                                          + "will be written over it until it can be read again; the lists are empty "
                                          + "until then. The backup folders themselves are untouched.")]
            return
        }
        do {
            try adopt(data)
        } catch {
            rescueNotes = collectRescues(error, bytes: data)
        }
    }

    private func adopt(_ data: Data) throws {
        let lib = try LibraryStore.makeDecoder().decode(Library.self, from: data)
        history = lib.history.sorted { $0.date > $1.date }
        snapshots = lib.snapshots.sorted { $0.date > $1.date }
        pending = lib.pending
        // Earlier rescues the user has not put away yet. A note whose file is no longer in the outstanding
        // namespace was acknowledged — the rename landed even if the save that followed it did not — so the
        // folder has the last word over the note.
        rescueNotes = lib.rescues.filter {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.file).path)
        }
    }

    /// A library that would not read at launch but reads and decodes now was never corrupt. Its entries go back
    /// alongside anything recorded in the meantime, newest first — the old history is not lost, and neither is
    /// what the user has just done. On a clash of ids the live record wins, being the later of the two.
    private func recover(_ data: Data) throws {
        let waiting = (history, snapshots, pending)
        try adopt(data)
        var records: [UUID: InstallRecord] = [:]
        for r in history + waiting.0 { records[r.id] = r }      // the live one wins on a clash
        history = records.values.sorted { $0.date > $1.date }
        var saved: [UUID: Snapshot] = [:]
        for s in snapshots + waiting.1 { saved[s.id] = s }
        snapshots = saved.values.sorted { $0.date > $1.date }
        pending = waiting.2 ?? pending
    }

    /// Everything still waiting to be fetched: the copy just made, plus every copy from an earlier failure that is
    /// still in the folder. An unreadable library cannot tell us about its own predecessors, so the folder is the
    /// record — otherwise a second corruption would quietly retire the first one's warning.
    private func collectRescues(_ error: Error, bytes: Data) -> [RescueNote] {
        let made = rescue(error, bytes: bytes)
        var byFile = [made.file: made]
        for u in rescueFiles() where byFile[u.lastPathComponent] == nil {
            let when = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            byFile[u.lastPathComponent] = RescueNote(
                date: when, file: u.lastPathComponent,
                text: "An earlier history and backup list could not be read either, and is still kept as "
                    + "\(u.lastPathComponent) in the app's folder.")
        }
        return byFile.values.sorted { $0.date > $1.date }
    }

    /// A rescue copy still waiting to be fetched, and one the user has said they have. The name is the record:
    /// a library that cannot be read cannot tell us which of its predecessors were acknowledged.
    private static let outstanding = "library-unreadable-"
    private static let fetched = "library-rescued-"

    /// Moves a rescue copy out of the outstanding namespace. The source is only deleted when something at the
    /// destination is *verified* to hold the same bytes — a matching name is a claim, not proof — and anything
    /// else sitting under that name is left alone, with the copy put beside it instead. Nothing is thrown away
    /// here on the strength of a filename.
    private func acknowledge(_ name: String) throws {
        let fm = FileManager.default
        let from = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: from.path) else { return }   // already gone: nothing to acknowledge
        let hash = String(from.deletingPathExtension().lastPathComponent.dropFirst(LibraryStore.outstanding.count))
        let to = folder.appendingPathComponent("\(LibraryStore.fetched)\(hash).json")
        if holds(to, hash) {
            try fm.removeItem(at: from)               // a verified duplicate, so the source is redundant
        } else if fm.fileExists(atPath: to.path) {
            let beside = folder.appendingPathComponent("\(LibraryStore.fetched)\(hash)-\(UUID().uuidString).json")
            try fm.moveItem(at: from, to: beside)     // something else is under that name: keep both
        } else {
            try fm.moveItem(at: from, to: to)
        }
    }

    private func rescueFiles() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix(LibraryStore.outstanding) && $0.pathExtension == "json" }
    }

    /// The unreadable library is the only copy of the history, so it is kept beside the new one. The copy is named
    /// after the full SHA-256 of its own bytes, so the name *is* the content: the same bad library is kept exactly
    /// once however often the app is relaunched on it, and two different ones cannot land on the same name. Says
    /// what actually happened, not what was hoped.
    private func rescue(_ error: Error, bytes: Data) -> RescueNote {
        let head = "The saved history and backup list could not be read (\(error.localizedDescription)). "
        let tail = " The history starts empty; backups are found again from their folders, which are untouched."
        // FWSCPackage carries the module's SHA-256 helper; there is nothing package-specific about it.
        let mark = FWSCPackage.sha256Hex(bytes)
        let kept = folder.appendingPathComponent("\(LibraryStore.outstanding)\(mark).json")
        func note(_ text: String) -> RescueNote { RescueNote(file: kept.lastPathComponent, text: head + text + tail) }

        if holds(kept, mark) {
            return note("Those very bytes are already kept as \(kept.lastPathComponent) in the app's folder.")
        }
        do {
            try keepAside(bytes, as: kept.lastPathComponent)
            return note("The file was kept as \(kept.lastPathComponent) in the app's folder, to be rescued from Files.")
        } catch {
            // Hold the bytes: until a copy of them exists, this app writes nothing over library.json.
            hold = .bytes(bytes, file: kept.lastPathComponent)
            return note("It could not even be copied aside (\(error.localizedDescription)). Nothing will be written "
                        + "over it until that works, so free some space — or copy library.json out of the app's "
                        + "folder in Files and put this warning away.")
        }
    }

    /// Tried before every write. While an unreadable library's only copy is still the original, writing the new
    /// library would destroy the user's history, so the write is refused instead. Freeing space — or the file
    /// becoming readable again — makes the next ordinary write succeed on its own.
    /// Gives a library that could not be read at launch another chance — and does so *before* anything the store
    /// is asked to do looks at `pending` or records what it is about to change. Resolving it any later would let a
    /// recovered interrupted update be rolled back to the nothing that stood in for it a moment ago.
    private func settle() {
        guard case .unreadable = hold else { return }
        guard let bytes = try? readData(file) else { return }   // still unreadable: the hold stands
        hold = nil
        // It reads now. If it decodes too, nothing was ever wrong with it: take it back rather than keep a copy of
        // a perfectly good library and carry on with empty lists.
        do {
            try recover(bytes)
        } catch {
            rescueNotes = collectRescues(error, bytes: bytes)
        }
        recoverSnapshots()
    }

    private func preserveOriginal() throws {
        guard let hold else { return }
        switch hold {
        case .bytes(let bytes, let name):
            try keepAside(bytes, as: name)
            self.hold = nil
        case .unreadable:
            // `settle()` has already tried; it is still unreadable, and nobody knows what is in it.
            throw FM1Error.package("the list that could not be read still cannot be, and it will not be written "
                                   + "over while nobody knows what is in it")
        }
    }

    /// True when the file really holds the bytes its content-hash name claims. A name is a promise; the bytes are
    /// the proof, and a rescue copy truncated or edited in Files must never pass for the original.
    private func holds(_ url: URL, _ hash: String) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path), let there = try? readData(url) else { return false }
        return FWSCPackage.sha256Hex(there) == hash
    }

    private func keepAside(_ bytes: Data, as name: String) throws {
        let kept = folder.appendingPathComponent(name)
        let hash = FWSCPackage.sha256Hex(bytes)
        guard !holds(kept, hash) else { return }
        do {
            // Atomic, so a damaged copy already sitting there is replaced rather than trusted.
            try writeData(bytes, kept)
        } catch {
            throw FM1Error.package("the unreadable list still cannot be copied aside (\(error.localizedDescription)), "
                                   + "and it will not be written over while that is so")
        }
    }

    /// Writes everything the app currently believes, reporting failure. Because it always writes the whole of the
    /// current state, the next write after a failed one finishes that failed one's job too.
    private func write() throws {
        if Demo.isOn { return }
        do {
            try preserveOriginal()
            let lib = Library(history: history, snapshots: snapshots, pending: pending, rescues: rescueNotes)
            let data = try LibraryStore.makeEncoder().encode(lib)
            try writeData(data, file)
            writeProblem = nil
        } catch {
            writeProblem = "The history and backup list could not be saved (\(error.localizedDescription)). "
                + "Free some space on the phone; until then this list is only in memory."
            throw error
        }
    }

    /// For the lists the user can see on screen: a failure is shown, not thrown.
    private func save() { try? write() }

    // MARK: History

    func add(_ r: InstallRecord) {
        settle()
        history.insert(r, at: 0)
        save()
    }

    func clearHistory() {
        settle()
        history.removeAll()
        save()
    }

    func installCount(firmwareId: String) -> Int {
        history.filter { $0.firmwareId == firmwareId && $0.success }.count
    }

    // MARK: The update being written

    /// What happens to the app's own idea of the pending update when the disk refuses it.
    private enum OnWriteFailure {
        /// Nothing changes. For the record written *before* the device is touched: if it is not durable the caller
        /// refuses to write at all, so the app must go on believing exactly what the disk says.
        case forget
        /// The new value stands. For a record that describes something that has *already* happened to the device:
        /// the truth is the truth whether or not the disk took it, and the next write will carry it.
        case believeAnyway
    }

    /// What was on the list before the attempt now in progress. The store owns this rather than the caller: a
    /// caller would have to snapshot it before the store has had its chance to recover a library it could not read
    /// at launch, and would then put back a value that was never true.
    private struct Attempt { let token: UUID; var supplanted: PendingUpdate? }
    private var attempt: Attempt?

    /// A handle on one attempt's rollback, held by the job that began it. Only that job can abandon it, so a
    /// failure in a later job — one whose own attempt never got as far as being recorded — can never undo the
    /// recovery record of an earlier write that really did go half-way.
    struct AttemptToken: Hashable {
        fileprivate let id: UUID
    }

    /// An attempt begins: this is what is about to be written, so an interruption can be resumed exactly. Throws
    /// when the record did not reach the disk — there would be nothing to resume from, so the caller must refuse
    /// to write rather than go on without it. In memory and on disk, or in neither.
    @discardableResult
    func beginAttempt(_ p: PendingUpdate) throws -> AttemptToken {
        settle()
        let supplanted = pending
        try replacePending(p, onFailure: .forget, failure: "What is about to be written could not be recorded")
        let token = UUID()
        attempt = Attempt(token: token, supplanted: supplanted)
        return AttemptToken(id: token)
    }

    /// The attempt in progress is the same one, found again with the identity this try discovered. Not a new
    /// attempt, so what it supplanted is left as it was.
    func refreshPending(_ p: PendingUpdate) throws {
        settle()
        try replacePending(p, onFailure: .forget, failure: "What is about to be written could not be recorded")
    }

    /// This attempt provably never reached the device: put back whatever was on the list before it began. Does
    /// nothing without the token of the attempt actually in hand — a job that failed before recording an attempt
    /// has nothing to abandon, and must not reach back and abandon an older job's.
    func abandonAttempt(_ token: AttemptToken?) throws {
        guard let token, let a = attempt, a.token == token.id else { return }
        attempt = nil
        guard pending != a.supplanted else { return }
        try replacePending(a.supplanted, onFailure: .believeAnyway,
                           failure: "The interrupted update could not be put back on the list")
    }

    /// The device came back with the expected identity: there is nothing left to resume. The cleared state stands
    /// even if this write fails, so the install record saved next finishes the job instead of resurrecting it.
    func clearPending() throws {
        settle()
        attempt = nil
        guard pending != nil else { return }
        try replacePending(nil, onFailure: .believeAnyway, failure: "The finished update could not be struck off the list")
    }

    private func replacePending(_ p: PendingUpdate?, onFailure: OnWriteFailure, failure: String) throws {
        let previous = pending
        pending = p
        do {
            try write()
        } catch {
            // The write is atomic, so on failure the disk still holds `previous` whichever way we go here.
            if onFailure == .forget { pending = previous }
            throw FM1Error.package("\(failure) (\(error.localizedDescription)). Free some space on the phone and try again.")
        }
    }

    // MARK: Snapshots

    /// `Paths.snapshots` in the app; under the injected folder in the tests, so they cannot touch the real backups.
    private var snapshotsRoot: URL { Paths.ensure(folder.appendingPathComponent("Snapshots", isDirectory: true)) }

    func folder(for s: Snapshot) -> URL { snapshotsRoot.appendingPathComponent(s.id.uuidString, isDirectory: true) }

    func packageURL(for s: Snapshot) -> URL? {
        guard let f = s.packageFile else { return nil }
        return folder(for: s).appendingPathComponent(f)
    }

    func archiveURL(for s: Snapshot) -> URL? {
        guard let f = s.archiveFile else { return nil }
        return folder(for: s).appendingPathComponent(f)
    }

    func add(_ s: Snapshot) {
        settle()
        snapshots.insert(s, at: 0)
        writeRecord(s)
        save()
    }

    func update(_ s: Snapshot) {
        settle()
        if let i = snapshots.firstIndex(where: { $0.id == s.id }) { snapshots[i] = s; writeRecord(s); save() }
    }

    func remove(_ s: Snapshot) {
        settle()
        snapshots.removeAll { $0.id == s.id }
        try? FileManager.default.removeItem(at: folder(for: s))
        save()
    }

    func snapshotsSize() -> Int64 { Paths.size(of: snapshotsRoot) }
}
