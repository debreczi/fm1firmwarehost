import Foundation
import Observation
import SwiftUI
import UIKit

/// What the device layer is doing right now, for the screens.
enum DevicePhase: Equatable {
    case idle
    case connecting
    case searching(String)
    case downloading(Double)
    case installing(InstallStep)
    case backingUp(Int, Int)
    case restoring(Int, Int)

    var isBusy: Bool { self != .idle }

    var title: String {
        switch self {
        case .idle: return "Idle"
        case .connecting: return "Looking for the FM-1"
        case .searching: return "Finding the package"
        case .downloading: return "Loading the package"
        case .installing(let s): return s.title
        case .backingUp: return "Backing up"
        case .restoring: return "Restoring"
        }
    }

    var fraction: Double? {
        switch self {
        case .idle, .connecting, .searching: return nil
        case .downloading(let f): return f
        case .installing(let s): return s.fraction
        case .backingUp(let d, let t), .restoring(let d, let t): return t > 0 ? Double(d) / Double(t) : nil
        }
    }
}

/// A running or finished job, shown in the progress sheet.
struct DeviceJob: Identifiable, Equatable {
    enum Kind: Equatable { case install, official, resume, snapshot, restoreFirmware, restoreArchive, file }
    let id = UUID()
    let kind: Kind
    var title: String
    var subtitle: String
    var colour: Color
    var imageURL: URL?
    var finished = false
    var success = false
    var message = ""
    var hint = ""
    /// A page that helps with a failure.
    var link: URL? = nil
}

/// The one place that talks to the FM-1: connect, install, snapshot, restore. Everything else observes it.
@MainActor
@Observable
final class DeviceController {
    let catalog: CatalogStore
    let library: LibraryStore
    let settings: AppSettings
    let packages = PackageStore.shared
    private let engine = MIDIEngine.shared

    private(set) var identity: FM1Identity?
    private(set) var identityDate: Date?
    private(set) var phase: DevicePhase = .idle
    private(set) var job: DeviceJob?
    private(set) var log: [String] = []
    private(set) var otherPorts: [String] = []
    private(set) var midiPorts: [String] = []
    private(set) var loaderWaiting: FM1Identity?
    private(set) var musicBackupSupported: Bool?
    /// What the FM-1 found last said about its flash chip, on which port: nil until one answered, and again once that
    /// port is gone while nothing runs. Every handshake replaces it.
    private(set) var flashReport: DeviceFlash?
    private var reportPort: String?
    /// A chip other than the first FM-1s' reported since the FM-1 was plugged in. It stays known while the firmware the
    /// FM-1 runs afterwards says nothing, as most do. A first-FM-1 reading is never carried over like this: taken for
    /// another unit's, it would hide a warning, where this one can only add one.
    private var unsafeChip: UInt32?

    /// What the flash chip check goes by.
    var flashChip: DeviceFlash? {
        if case .reported = flashReport { return flashReport }
        if let id = unsafeChip { return .reported(id) }
        return flashReport
    }
    /// Can the app put the music it backs up back on this firmware? Not on one built on SLOOP.
    private(set) var musicWritesBack = true
    /// What the running firmware says of itself over the editor protocol, when it speaks it: "SLOOP 2.8.4".
    private(set) var reportedName: String?
    /// M-VAVE's current official firmware, once checked: its identity ("FM-1_016") and whether it is on the phone.
    private(set) var officialLatest: String?
    private(set) var officialChecking = false
    /// When m-vave.com last answered, kept across launches (its file is kept too), and when the app last asked it.
    private var officialCheckedAt: Date? {
        get { UserDefaults.standard.object(forKey: PackageStore.officialCheckedAtKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: PackageStore.officialCheckedAtKey) }
    }
    /// What it answered then ("FM-1_016"): the time counts only while the version shown is that answer.
    private var officialCheckedProduct: String? {
        get { UserDefaults.standard.string(forKey: PackageStore.officialCheckedProductKey) }
        set { UserDefaults.standard.set(newValue, forKey: PackageStore.officialCheckedProductKey) }
    }
    private var officialTriedAt: Date?
    private var officialTask: Task<Void, Never>?
    /// Counts Delete cache: an m-vave.com answer from before one is not taken.
    private var officialRun = 0
    var statusMessage: String = ""
    var showJobSheet = false

    private var updater: FM1Updater?
    private var task: Task<Void, Never>?

    init(catalog: CatalogStore, library: LibraryStore, settings: AppSettings) {
        self.catalog = catalog
        self.library = library
        self.settings = settings
        engine.onSetupChanged = { [weak self] in
            Task { @MainActor in self?.setupChanged() }
        }
        refreshPorts()
        officialLatest = keptOfficial()
    }

    var whoIs: WhoIs? { catalog.whoIs(identity?.text, named: reportedName) }
    /// What a new backup is called until the user says otherwise.
    var backupName: String { identity.map { whoIsName($0) } ?? "" }
    var isConnected: Bool { identity != nil }
    /// Is this the firmware on the FM-1? An ambiguous identity says so only when the device itself named it.
    func isRunning(_ f: Firmware) -> Bool {
        guard identity?.text == f.product else { return false }
        return !catalog.identityIsAmbiguous(f.product) || whoIs?.firmware?.id == f.id
    }
    var isBusy: Bool { phase.isBusy }
    var officialLatestVersion: String? { officialLatest.flatMap { FWSCPackage.officialVersion(of: $0) } }

    private func makeUpdater() -> FM1Updater {
        let u = FM1Updater(engine: engine)
        u.probeAll = settings.probeAllPorts
        u.chosenPorts = Set(settings.chosenPorts)
        u.plainOnly = Set(catalog.firmwares.filter(\.usesStockLoader).map(\.product))
        u.log = { [weak self] s in Task { @MainActor in self?.append(s) } }
        updater = u
        return u
    }

    private func append(_ s: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date())) \(s)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    func clearLog() { log.removeAll() }

    func refreshPorts() {
        var seen = Set<String>()
        midiPorts = engine.sources().map(\.name).filter { seen.insert($0).inserted }
    }

    /// The screenshot mode: an FM-1 running Felucca, and optionally an install of X0X in progress.
    func seedDemo() {
        if let f = catalog.firmware(id: "felucca") { identity = FM1Identity.parse(text: f.product) }
        identityDate = Date().addingTimeInterval(-90)
        musicBackupSupported = true
        officialLatest = "FM-1_016"
        midiPorts = ["Felucca"]
        if Demo.job, let x = catalog.firmware(id: "x0x") {
            job = DeviceJob(kind: .install, title: x.name, subtitle: "\(x.version) · by \(x.author)", colour: Look.colour(for: x.id), imageURL: x.imageURL)
            phase = .installing(.write(704))
            showJobSheet = true
        }
    }

    private func setupChanged() {
        if Demo.isOn { return }
        refreshPorts()
        // an FM-1 unplugged while nothing runs takes what it said with it; an install's own restarts don't
        if !isBusy, let p = reportPort, !midiPorts.contains(p) {
            flashReport = nil
            reportPort = nil
            // the next FM-1 may be another one, other MIDI gear still plugged in or not; but while an update is
            // unfinished this one is the unit it was for, wherever its port went
            if library.pending == nil { unsafeChip = nil }
        }
        if midiPorts.isEmpty, !isBusy {
            identity = nil
            musicBackupSupported = nil
            reportedName = nil
            loaderWaiting = nil          // unplugged: the Resume card must not keep claiming a loader is waiting
            if library.pending == nil { unsafeChip = nil }   // the next FM-1 may have another chip; an unfinished update's stays
            statusMessage = "No MIDI device."
        }
    }

    func choosePort(_ name: String) {
        if !settings.chosenPorts.contains(name) { settings.chosenPorts.append(name) }
        otherPorts.removeAll { $0 == name }
    }

    /// Asks m-vave.com which official version is current, in a task of its own that no screen cancels when it goes
    /// away, so the tabs share one download. Without `force` it asks only when the last answer is some hours old, or ten
    /// minutes after a try that failed (offline, or a file the app didn't accept); pull to refresh forces it. None
    /// starts while the FM-1 is busy.
    func refreshOfficial(force: Bool = false) {
        guard officialTask == nil, !isBusy, !Demo.isOn else { return }
        let now = Date()
        if !force {
            if let l = officialLatest, l == officialCheckedProduct, let t = officialCheckedAt, t <= now, now.timeIntervalSince(t) < 6 * 3600 { return }
            if let t = officialTriedAt, t <= now, now.timeIntervalSince(t) < 600 { return }
        }
        officialTriedAt = now
        let run = officialRun
        officialTask = Task { [weak self] in
            await self?.checkOfficial()
            if self?.officialRun == run { self?.officialTask = nil }
        }
    }

    /// Asks M-VAVE's server which official version is current (and keeps the file). Quiet when offline.
    func checkOfficial() async {
        guard !officialChecking, !Demo.isOn else { return }
        officialChecking = true
        defer { officialChecking = false }
        let run = officialRun
        if let p = try? await packages.officialLatest(), run == officialRun {   // not one Delete cache has overtaken
            noteOfficialAnswer(p)
            append("official firmware on m-vave.com: \(p.product)")
        }
    }

    /// What the app shows as M-VAVE's latest before asking: m-vave.com's last answer, else the newest file it once
    /// answered with that is on the phone. The hub's V15 is not M-VAVE's latest.
    private func keptOfficial() -> String? {
        officialCheckedProduct ?? packages.newestCachedOfficial().flatMap { $0.isStockV15 ? nil : $0.product }
    }

    /// The phone's packages were deleted: m-vave.com's last answer goes with them (the package store forgets it too).
    func forgetOfficialAnswer() {
        officialTask?.cancel()           // a check on its way would bring back what was deleted
        officialTask = nil
        officialRun += 1
        officialLatest = keptOfficial()
        officialTriedAt = nil
    }

    /// m-vave.com answered with this file, whoever asked: it is the version shown as M-VAVE's latest, and the time
    /// before the next check counts from now.
    private func noteOfficialAnswer(_ p: FWSCPackage) {
        officialLatest = p.product
        officialCheckedAt = Date()
        officialCheckedProduct = p.product
        officialTriedAt = nil
    }

    // MARK: Connect

    func connect() {
        guard !isBusy else { return }
        phase = .connecting
        statusMessage = ""
        task = Task {
            let up = makeUpdater()
            let dev = await up.find { _ in true }
            if let dev = dev {
                dev.link.close()
                identity = dev.identity
                identityDate = Date()
                loaderWaiting = dev.identity.isLoader ? dev.identity : nil
                otherPorts = []
                statusMessage = ""
                append("identity \(dev.identity.text) on \(dev.portName)")
                noteFlash(dev.flashID, port: dev.portName)
                musicBackupSupported = nil
                reportedName = nil
                reconcilePending(dev.identity)
                if !dev.identity.isLoader { await probeMusicBackup() }
            } else {
                identity = nil
                musicBackupSupported = nil
                reportedName = nil
                loaderWaiting = nil          // nothing answered: there is no loader to show a Resume card for
                flashReport = nil            // a newer chip stays known: an FM-1 still plugged in may just be busy
                reportPort = nil
                otherPorts = up.others()
                statusMessage = "No FM-1 found" + up.seen() + ". Plug it in by USB, close other MIDI apps, try again."
                append("no FM-1" + up.seen())
            }
            // Connect is the one thing the user does again and again, so it is where a library write that did not
            // land gets another go: nothing else on this path writes it.
            library.flush()
            refreshPorts()
            phase = .idle
        }
    }

    /// What does the running firmware say of itself, and does it answer a music backup? (Felucca, SLOOP and the
    /// firmwares built on them do.)
    private func probeMusicBackup() async {
        guard let dev = await openDevice() else { return }
        let music = await SloopBackup.detect(FeluccaLink(link: dev.link))
        dev.link.close()
        reportedName = music.info?.wholeName
        musicBackupSupported = music.kind != nil
        musicWritesBack = music.kind != .sloop || music.info?.isSloop == true
        append("firmware says: \(music.info?.version ?? "nothing")")
        append(music.kind != nil ? "backup protocol: supported" : "backup protocol: not answered")
    }

    private func openDevice() async -> FM1Device? {
        let up = updater ?? makeUpdater()
        let dev = await up.find { !$0.isLoader }
        if let dev { noteFlash(dev.flashID, port: dev.portName) }
        return dev
    }

    // MARK: Flash chips

    /// What a device found just now said of its chip. A newer or unknown chip is also remembered (`unsafeChip`); the
    /// first FM-1s' chip, reported now, puts that away. A device that says nothing, a loader too, leaves only that.
    private func noteFlash(_ id: UInt32?, port: String) {
        if let id, flashChip != .reported(id) { append("flash chip \(FlashChip.hex(id))") }
        flashReport = DeviceFlash(id)
        reportPort = port
        if let id { unsafeChip = id == FlashChip.first ? nil : id }
    }

    /// Which flash chips a package works on, by its SHA-256 alone: the catalogue's word for this very package when it
    /// says one, M-VAVE's own firmware (the V15 or a file fetched from M-VAVE), or what the catalogue said of it when the
    /// app last read it (kept in the app's own storage; a catalogue gone silent keeps "the first FM-1s only" there). What
    /// a backup's or record's files say, which can be edited, never decides it.
    func chipSupport(sha256: String, product: String) -> ChipSupport {
        guard !sha256.isEmpty else { return .unknown }
        if let f = catalog.firmwares.first(where: { $0.sha256 == sha256 }), f.chipSupport != .unknown { return f.chipSupport }
        if packages.isFetchedOfficial(sha256) { return .official }
        return packages.seenChip(sha256)
    }

    /// May M-VAVE's update loader write this package? By its hash: M-VAVE's own, or one the hub says is built on
    /// M-VAVE's code, now or when the app last read the catalogue. An older build the app never saw listed goes as
    /// its family: when every firmware the catalogue lists with its identity is built on M-VAVE's code; then as the
    /// firmware a backup names (`firmwareId`) is written, when the catalogue knows no firmware with that identity; then
    /// as M-VAVE's own, for an M-VAVE number no community firmware in the catalogue reports.
    private func usesStockLoader(_ pkg: FWSCPackage, firmwareId: String? = nil) -> Bool {
        if packages.isFetchedOfficial(pkg.sha256) { return true }
        if let f = catalog.firmwares.first(where: { $0.sha256 == pkg.sha256 }) { return f.usesStockLoader }
        if packages.seenStockLoader(pkg.sha256) { return true }
        let family = catalog.firmwares(reporting: pkg.product)
        if !family.isEmpty { return family.allSatisfy(\.usesStockLoader) }
        if let id = firmwareId, let f = catalog.firmware(id: id) { return f.usesStockLoader }   // an older build whose identity has changed since
        return pkg.isOfficial && !catalog.firmwares.isEmpty
    }

    func chipSupport(of s: Snapshot) -> ChipSupport {
        Self.atLeastOld(chipSupport(sha256: s.packageSHA256 ?? "", product: s.product ?? s.identity), remembered: s.chipSupport)
    }

    func chipSupport(of p: PendingUpdate) -> ChipSupport {
        Self.atLeastOld(chipSupport(sha256: p.sha256, product: p.product), remembered: p.chip.flatMap(ChipSupport.init(rawValue:)))
    }

    /// A record's own "the first FM-1s only" counts where the app knows nothing else: it can only make the check
    /// stricter, so an edited file gains nothing by it. Nothing else a record says counts.
    private static func atLeastOld(_ c: ChipSupport, remembered: ChipSupport?) -> ChipSupport {
        c == .unknown && remembered == .old ? .old : c
    }

    /// What the flash chip check says now about installing a package with this support.
    func chipVerdict(_ support: ChipSupport) -> ChipVerdict {
        ChipGuard.verdict(device: flashChip ?? .notReported, package: support, allowUnsafe: settings.allowUnsafeInstalls)
    }

    /// Can an update this firmware never started be a newer FM-1 stuck on a firmware that doesn't know its chip? Not when
    /// the FM-1 reported the first chip, and not when the running version is known to work on newer FM-1s: M-VAVE's own,
    /// or one the device named exactly and the hub says works on them.
    private func mayBeStuck(_ id: FM1Identity) -> Bool {
        guard !id.isLoader, flashChip?.id != FlashChip.first else { return false }
        if FWSCPackage.isOfficialProduct(id.text), catalog.firmwares(reporting: id.text).isEmpty { return false }
        guard let f = Firmware.named(reportedName, among: catalog.firmwares(reporting: id.text)), f.product == id.text else { return true }
        return f.chipSupport == .old || f.chipSupport == .unknown
    }

    func cancel() {
        updater?.cancel()
        task?.cancel()
    }

    // MARK: Install

    /// `consent`: what the user agreed to when the flash chip check asked (`chipVerdict`). It is checked again against
    /// the device itself before anything is written.
    func install(_ f: Firmware, consent: ChipVerdict = .install) {
        guard !isBusy else { return }
        var j = DeviceJob(kind: .install, title: f.name, subtitle: "\(f.version) · by \(f.author)", colour: Look.colour(for: f.id), imageURL: f.imageURL)
        start(job: j) { [self] in
            let before = identity?.text
            try await autoSnapshotIfWanted()
            phase = .downloading(0)
            let pkg = try await packages.package(for: f) { p in Task { @MainActor in self.phase = .downloading(p) } }
            let after = try await flash(pkg, product: f.product, stockLoader: f.usesStockLoader,
                                        name: f.name, version: f.version, firmwareId: f.id, source: .hub,
                                        consent: consent)
            library.add(InstallRecord(firmwareId: f.id, name: f.name, version: f.version, product: f.product, sha256: f.sha256,
                                      identityBefore: before, identityAfter: after, source: .hub, success: true))
            j.message = "\(f.name) \(f.version) is on your FM-1."
            return j
        } onFailure: { [self] e in
            library.add(InstallRecord(firmwareId: f.id, name: f.name, version: f.version, product: f.product, sha256: f.sha256,
                                      identityBefore: identity?.text, identityAfter: nil, source: .hub, success: false, error: e.localizedDescription))
        }
    }

    /// M-VAVE's own firmware: the current one from their server (`latest`), or the V15 recovery image from the hub.
    /// `shown`: the identity the question named ("FM-1_016"), so the result can say when M-VAVE's file has changed since.
    func installOfficial(latest: Bool, shown: String? = nil, consent: ChipVerdict = .install) {
        guard !isBusy else { return }
        let title = latest ? "Official firmware" : "Official firmware V15"
        var j = DeviceJob(kind: .official, title: title, subtitle: latest ? "M-VAVE's current release" : "M-VAVE's recovery image, from the hub", colour: Color(hex: "#9aa4b2"), imageURL: nil)
        var product = latest ? (officialLatest ?? "") : FWSCPackage.stockV15Product
        start(job: j) { [self] in
            let before = identity?.text
            try await autoSnapshotIfWanted()
            phase = .downloading(0)
            let pkg: FWSCPackage
            var fromPhone = false
            if latest {
                do {
                    pkg = try await packages.officialLatest { p in Task { @MainActor in self.phase = .downloading(p) } }
                } catch {
                    if Task.isCancelled { throw FM1Error.cancelled }   // Cancel, not "m-vave.com can't be reached"
                    // the hub's V15 is not M-VAVE's latest: "Back to V15" is the way to that one
                    guard let cached = try? await packages.officialLatest(cachedOnly: true), !cached.isStockV15 else {
                        throw FM1Error.package("m-vave.com's file couldn't be fetched or wasn't accepted (\(error.localizedDescription)), and no copy of it is on this phone. Try again online, or use Back to V15 for the recovery image.")
                    }
                    append("m-vave.com's file couldn't be fetched or wasn't accepted (\(error.localizedDescription)), using the cached \(cached.product)")
                    pkg = cached
                    fromPhone = true
                    j.subtitle = "M-VAVE's release, the copy on this phone"
                    job?.subtitle = j.subtitle            // the sheet shows it now, whatever comes next
                }
                if !fromPhone { noteOfficialAnswer(pkg) }   // the phone's copy says nothing of what M-VAVE publishes
            } else {
                pkg = try await packages.stockPackage(catalog.stock) { p in Task { @MainActor in self.phase = .downloading(p) } }
            }
            product = pkg.product
            j.title = "Official firmware \(pkg.officialVersion ?? pkg.product)"
            let after = try await flash(pkg, product: pkg.product, stockLoader: true,
                                        name: "Official firmware", version: pkg.officialVersion ?? "", firmwareId: nil, source: .stock,
                                        consent: consent)
            library.add(InstallRecord(firmwareId: nil, name: "Official firmware", version: pkg.officialVersion ?? "", product: pkg.product, sha256: pkg.sha256,
                                      identityBefore: before, identityAfter: after, source: .stock, success: true))
            j.message = "The official \(pkg.officialVersion ?? pkg.product) is on your FM-1."
            if fromPhone {
                j.message += " m-vave.com's file couldn't be fetched or wasn't accepted, so the copy on this phone was used."
                if let s = shown, s != pkg.product, let v = FWSCPackage.officialVersion(of: s) { j.message += " The app had shown \(v)." }
            } else if latest, let s = shown, s != pkg.product, let v = FWSCPackage.officialVersion(of: s) {
                j.message += " The app had shown \(v): M-VAVE's file has changed since."
            }
            return j
        } onFailure: { [self] e in
            library.add(InstallRecord(firmwareId: nil, name: "Official firmware", version: FWSCPackage.officialVersion(of: product) ?? "", product: product, sha256: nil,
                                      identityBefore: identity?.text, identityAfter: nil, source: .stock, success: false, error: e.localizedDescription))
        }
    }

    /// A package file read for the flash chip check before it is installed: nil when it can't be read (the install
    /// then says why, and the history keeps it).
    func pickedPackage(_ url: URL) -> (package: FWSCPackage, firmware: Firmware?, support: ChipSupport)? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let pkg = try? FWSCPackage(data: data), pkg.product.hasPrefix("FM-1_") else { return nil }
        return (pkg, catalog.firmwares.first { $0.sha256 == pkg.sha256 }, chipSupport(sha256: pkg.sha256, product: pkg.product))
    }

    /// A package chosen in the Files app (the last resort: a release the app could not find on its own).
    /// `expectedSHA256`: the file the question was about; one that has changed since is not written.
    func installFile(_ url: URL, consent: ChipVerdict = .install, expectedSHA256: String? = nil) {
        guard !isBusy else { return }
        var j = DeviceJob(kind: .file, title: url.lastPathComponent, subtitle: "Package from a file", colour: Color(hex: "#9aa4b2"), imageURL: nil)
        start(job: j) { [self] in
            let before = identity?.text
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let pkg = try FWSCPackage(data: data)
            guard pkg.product.hasPrefix("FM-1_") else { throw FM1Error.package("The file is for \(pkg.product), not for an FM-1.") }
            if let e = expectedSHA256, e != pkg.sha256 {
                throw FM1Error.package("The file changed after you were asked about it: nothing was written. Pick it again.")
            }
            try? packages.keep(pkg)
            let who = catalog.whoIs(pkg.product)
            let known = catalog.firmwares.first { $0.sha256 == pkg.sha256 }
            j.title = known?.name ?? (catalog.identityIsAmbiguous(pkg.product) ? url.lastPathComponent : who?.name ?? pkg.product)
            j.subtitle = known.map { "\($0.version) · \(url.lastPathComponent)" } ?? url.lastPathComponent
            if let k = known { j.colour = Look.colour(for: k.id); j.imageURL = k.imageURL }
            try await autoSnapshotIfWanted()
            let after = try await flash(pkg, product: pkg.product, stockLoader: usesStockLoader(pkg),
                                        name: j.title, version: known?.version ?? "", firmwareId: known?.id, source: .file,
                                        consent: consent)
            library.add(InstallRecord(firmwareId: known?.id, name: j.title, version: known?.version ?? "", product: pkg.product, sha256: pkg.sha256,
                                      identityBefore: before, identityAfter: after, source: .file, success: true))
            j.message = "\(j.title) is on your FM-1."
            return j
        } onFailure: { [self] e in
            library.add(InstallRecord(firmwareId: nil, name: url.lastPathComponent, version: "", product: "", sha256: nil,
                                      identityBefore: identity?.text, identityAfter: nil, source: .file, success: false, error: e.localizedDescription))
        }
    }

    /// The device is in update mode (an interrupted update): write the package that was being written again — that
    /// very one, resolved by its SHA-256, never whatever was installed successfully last.
    /// `expected`: the record the question was about; if another has taken its place since, nothing is written.
    func resume(consent: ChipVerdict = .install, expected: PendingUpdate? = nil) {
        guard !isBusy, let pending = library.pending else { return }
        let f = pending.firmwareId.flatMap { catalog.firmware(id: $0) }
        var j = DeviceJob(kind: .resume, title: "Resume: \(pending.name)", subtitle: pending.version, colour: f.map { Look.colour(for: $0.id) } ?? Color(hex: "#9aa4b2"), imageURL: f?.imageURL)
        start(job: j) { [self] in
            if let e = expected, e.sha256 != pending.sha256 || e.product != pending.product {
                throw FM1Error.package("The interrupted update changed after you were asked about it: nothing was written. Press Resume again to decide.")
            }
            phase = .downloading(0)
            let pkg = try await pendingPackage(pending, firmware: f)
            if Task.isCancelled { throw FM1Error.cancelled }   // the updater made here knows nothing of an earlier Cancel
            let up = makeUpdater()
            defer { if let b = up.cameBack { noteFlash(b.flashID, port: b.port) } }   // whatever the outcome
            // The record already exists; this writes back the loader identity this attempt found, so that if the
            // record was made without knowing what the device was running, a later Connect can still settle it.
            let outcome = try await up.resume(image: pkg.logicalImage, expectedProduct: pending.product, stockLoader: pending.usesStockLoader,
                                              beforeWriting: { [self] found in
                                                  noteFlash(found.flashID, port: found.portName)
                                                  let now = chipVerdict(chipSupport(of: pending))
                                                  guard ChipGuard.allows(now, consent: consent) else {
                                                      append("flash chip check: \(flashChip?.summary ?? "not reported"), resume: nothing written")
                                                      throw FM1Error.chipCheck(ChipGuard.stopText(now))
                                                  }
                                                  var p = pending
                                                  p.identityBefore = found.identity.text
                                                  try library.refreshPending(p)
                                              },
                                              onStep: { s in Task { @MainActor in self.phase = .installing(s) } })
            // the record stays on the list in both failure cases: it is still the half-written update
            guard case .written(let after) = outcome else {
                if outcome == .noLoader {
                    loaderWaiting = nil
                    throw FM1Error.notFound("The FM-1 is not in update mode any more: nothing was written. Press Connect to see what it is running.")
                }
                throw FM1Error.stopped("The loader stopped before the end. Replug and try again.")
            }
            forgetPending()
            identity = FM1Identity.parse(text: after)
            identityDate = Date()
            loaderWaiting = nil
            musicBackupSupported = nil
            reportedName = pending.firmwareId != nil && !pending.version.isEmpty ? "\(pending.name) \(pending.version)" : nil
            // the id the record was made with, not whatever the catalogue happens to hold now
            library.add(InstallRecord(firmwareId: pending.firmwareId, name: pending.name, version: pending.version, product: after, sha256: pkg.sha256,
                                      identityBefore: "update loader", identityAfter: after, source: .resume, success: true))
            j.message = "\(pending.name) was written and the FM-1 came back as \(after)."
            return j
        } onFailure: { _ in }
    }

    /// The pending update's package, by its exact hash: the hub's catalogue, this phone (the cache or an earlier
    /// backup), or the hub's official V15. A file that does not hash to the record is not the pending package and
    /// is never written.
    private func pendingPackage(_ pending: PendingUpdate, firmware f: Firmware?) async throws -> FWSCPackage {
        if let p = packages.localPackage(product: pending.product, sha256: pending.sha256) { return p }
        if let f = f, f.sha256 == pending.sha256, let p = try? await packages.package(for: f), p.sha256 == pending.sha256 { return p }
        if pending.product == FWSCPackage.stockV15Product, pending.sha256 == FWSCPackage.stockV15SHA256,
           let p = try? await packages.stockPackage(catalog.stock), p.sha256 == pending.sha256 { return p }
        throw FM1Error.package("The package that was being written (\(pending.name), \(pending.product)) is not on this phone any more. Install it again from the list: that continues from the loader too.")
    }

    /// Running firmware -> loader -> new firmware, or straight from a waiting loader. Returns the identity reported
    /// after. What is about to be written is recorded before the loader is entered, so an interruption can be
    /// resumed with this exact package; the record is cleared only once the device has reported the new identity.
    ///
    /// The flash chip check runs again at the point of no return, with what the device found there reported: a chip
    /// learnt only then, which what the user agreed to (`consent`) does not cover, stops the install with nothing written.
    private func flash(_ pkg: FWSCPackage, product: String, stockLoader: Bool,
                       name: String, version: String, firmwareId: String?, source: InstallSource,
                       consent: ChipVerdict, remembered: ChipSupport? = nil) async throws -> String {
        // Cancel reaches the updater of the moment, and the updater made here starts afresh: one pressed before now, or
        // while the loader is asked for below, is only remembered by the task.
        if Task.isCancelled { throw FM1Error.cancelled }
        let up = makeUpdater()
        defer { if let b = up.cameBack { noteFlash(b.flashID, port: b.port) } }   // whatever the outcome
        let image = pkg.logicalImage
        try packages.keep(pkg)   // Resume needs this file: refuse the install rather than lose it
        // The record is written by this hook, which the updater calls once it has found the device and checked its
        // model and before it sends anything. So it exists before a single byte goes down, and it carries the
        // identity this very attempt saw — not a remembered one — which is what lets a later Connect decide
        // whether the update finished. A device that is refused never replaces an earlier record at all.
        // The token the hook brings back is this job's own. Without it nothing is abandoned, so a job that fails
        // before the hook ever runs cannot undo the recovery record of an earlier write that did go half-way.
        var token: LibraryStore.AttemptToken?
        var stuckSuspect = false
        let record: FM1Updater.BeforeWriting = { [self] dev in
            let found = dev.identity
            noteFlash(dev.flashID, port: dev.portName)
            // the catalogue of this moment, for this very file; a backup's "the first FM-1s only" as for its question
            let support = Self.atLeastOld(chipSupport(sha256: pkg.sha256, product: pkg.product), remembered: remembered)
            let now = chipVerdict(support)
            guard ChipGuard.allows(now, consent: consent) else {
                append("flash chip check: \(flashChip?.summary ?? "not reported"), package \(support.rawValue): nothing written")
                throw FM1Error.chipCheck(ChipGuard.stopText(now))
            }
            stuckSuspect = mayBeStuck(found)
            // whatever this leaves on the FM-1, it is no longer known to be what answered before
            reportedName = nil
            musicBackupSupported = nil
            musicWritesBack = true
            token = try library.beginAttempt(PendingUpdate(product: pkg.product, sha256: pkg.sha256, firmwareId: firmwareId,
                                                           name: name, version: version, usesStockLoader: stockLoader,
                                                           source: source, identityBefore: found.text, chip: support.rawValue))
        }
        let after: String
        do {
            let waiting = await up.loaderPresent()
            if Task.isCancelled { throw FM1Error.cancelled }
            if let ota = waiting {
                append("loader waiting: \(ota.text), resuming")
                switch try await up.resume(image: image, expectedProduct: product, stockLoader: stockLoader,
                                           beforeWriting: record,
                                           onStep: { s in Task { @MainActor in self.phase = .installing(s) } }) {
                case .written(let reported):
                    after = reported
                case .noLoader:
                    // the loader answered a moment ago and is gone: not a byte of this package was sent
                    throw FM1Error.notFound("The update loader was there a moment ago and is gone now: nothing was written. Replug the USB cable and press Install again.")
                case .interrupted:
                    throw FM1Error.stopped("The loader stopped before the end. Replug and press Install again.")
                }
            } else {
                after = try await up.install(image: image, product: product, beforeWriting: record,
                                             onStep: { s in Task { @MainActor in self.phase = .installing(s) } })
            }
        } catch {
            // A backstop: every failure before the hook leaves the list as it was already, so this only matters
            // if the point of no return ever moves. The store knows what the attempt supplanted, which is why it
            // and not this is asked to put it back.
            if (error as? FM1Error)?.nothingWritten == true { putBack(token) }
            if case .noRequests(let m)? = error as? FM1Error, stuckSuspect {
                throw FM1Error.stuck(m + " If your FM-1 is a newer one (M-VAVE logo under the screen), the firmware on it may not work with its flash chip: then it can't start an update, and holding OCT− won't help.")
            }
            throw error
        }
        forgetPending()
        identity = FM1Identity.parse(text: after)
        identityDate = Date()
        loaderWaiting = nil
        musicBackupSupported = nil
        // this app just wrote it and it came back with that identity: as good as hearing its name
        reportedName = firmwareId != nil && !version.isEmpty ? "\(name) \(version)" : nil
        return after
    }

    /// Whenever the app learns what the FM-1 is running: if that is what the pending update meant to put there, and
    /// the device was running something else before the attempt, the update finished — whether this app was watching
    /// or the news arrives now. An install interrupted in the post-write window (app killed, or the device back
    /// later than the updater waited) is found here. A write that did not land is retried on the next Connect,
    /// since nothing else in this path writes the library.
    private func reconcilePending(_ id: FM1Identity) {
        guard let p = library.pending, p.isFinished(by: id) else { return }
        append("the FM-1 runs \(id.text), which is what was pending: nothing left to resume")
        forgetPending()
    }

    /// The device has reported the new identity, so there is nothing left to resume. A record that cannot be struck
    /// off is said out loud (the library card shows it) but never turns a finished install into a failed one; the
    /// store keeps the cleared state, so the install record saved next carries it to the disk.
    private func forgetPending() {
        do {
            try library.clearPending()
        } catch {
            append("warning: \(error.localizedDescription)")
        }
    }

    /// This attempt provably never reached the device, so the update actually waiting in the loader is whatever was
    /// on the list before it began. Said plainly either way: put back, or put back only in memory for now.
    private func putBack(_ token: LibraryStore.AttemptToken?) {
        do {
            try library.abandonAttempt(token)
            append("nothing was written: the update to resume is again \(library.pending?.name ?? "none")")
        } catch {
            append("nothing was written: the update to resume is again \(library.pending?.name ?? "none") in the "
                   + "app, but it could not be written back yet (\(error.localizedDescription))")
        }
    }

    private func start(job: DeviceJob, work: @MainActor @escaping () async throws -> DeviceJob, onFailure: @MainActor @escaping (Error) -> Void) {
        self.job = job
        showJobSheet = true
        phase = .connecting
        statusMessage = ""
        // a locked screen suspends the app and stops the transfer: stay awake while the FM-1 is written
        let keepAwake = job.kind != .snapshot
        if keepAwake { UIApplication.shared.isIdleTimerDisabled = true }
        task = Task {
            defer { if keepAwake { UIApplication.shared.isIdleTimerDisabled = false } }
            var j = job
            do {
                j = try await work()
                j.finished = true
                j.success = true
                append("ok: \(j.title)")
            } catch {
                j.finished = true
                j.success = false
                let fe = error as? FM1Error
                j.message = (fe.map { "\($0.code): " } ?? "") + error.localizedDescription
                j.hint = fe?.hint ?? ""
                j.link = fe?.helpURL
                if fe?.code == "notfound" { otherPorts = updater?.others() ?? [] }
                append("error: \(j.message)")
                onFailure(error)
            }
            self.job = j
            phase = .idle
            updater = nil   // a Cancel stays with its updater, so the next job starts with a new one
        }
    }

    // MARK: Snapshots

    /// Before an install: when the setting is on and the running firmware answers a music backup, keep its music.
    private func autoSnapshotIfWanted() async throws {
        guard settings.autoSnapshotBeforeInstall else { return }
        guard let dev = await openDevice() else { return }
        let fl = FeluccaLink(link: dev.link)
        do {
            let music = try await detectMusic(fl)
            guard music.kind != nil else { dev.link.close(); return }
            append("auto backup before install")
            identity = dev.identity
            let s = try await makeSnapshot(dev: dev, fl: fl, music: music, name: nil, prefix: "Before install · ")
            library.add(s)
        } catch {
            append("auto backup failed: \(error.localizedDescription)")
            dev.link.close()
            if let e = error as? FM1Error, case .cancelled = e { throw e }
            throw FM1Error.backup("The backup before the install failed (\(error.localizedDescription)). Nothing was written. Stop playback on the FM-1 and try again, or turn the automatic backup off in Settings.")
        }
        dev.link.close()
    }

    /// Which music backup the firmware answers. A firmware that speaks at all and answers none may have lost a reply, so
    /// it is asked again. One that answered since it was connected and no longer does is an error, not a backup without
    /// the music.
    private func detectMusic(_ fl: FeluccaLink) async throws -> (info: EditorInfo?, kind: MusicBackupKind?) {
        let music = await SloopBackup.detect(fl)
        guard music.kind == nil, music.info != nil || musicBackupSupported == true else { return music }
        let again = await SloopBackup.detect(fl)
        if again.kind == nil, musicBackupSupported == true {
            throw FM1Error.backup("The FM-1 answered the music backup when it was connected, but not now. If its firmware has changed since, press Ask again on the FM-1 tab.")
        }
        return again
    }

    /// A backup only reads, so the advice for a stopped update does not apply to it.
    private func backupFailure(_ error: Error) -> Error {
        guard let e = error as? FM1Error else { return error }
        switch e {
        case .stopped, .lost: return FM1Error.backup(e.localizedDescription + " Nothing on the FM-1 was changed. Stop playback and try again.")
        default: return e
        }
    }

    /// A restore replaces the music object by object, each on its own, so one that stops has done part of it.
    private func restoreFailure(_ error: Error) -> Error {
        guard let e = error as? FM1Error, !e.nothingWritten else { return error }
        if case .cancelled = e { return e }
        var text = e.localizedDescription
        if case .stopped = e { text = "The FM-1 stopped answering." }
        if !text.hasSuffix(".") { text += "." }
        return FM1Error.protocolError(text + " Part of your music may already be replaced. Restoring again is safe.")
    }

    private func whoIsName(_ id: FM1Identity) -> String {
        let w = catalog.whoIs(id.text, named: reportedName)
        if let f = w?.firmware { return f.name + (w?.exact == true ? " \(f.version)" : "") }
        if catalog.identityIsAmbiguous(id.text) { return id.text }   // what it says of itself named none of them
        return w?.name ?? id.text
    }

    /// Save the state of the FM-1: which firmware is on it with its package (found wherever it is), plus the music
    /// archive when the firmware answers a music backup.
    func snapshot(name: String?) {
        guard !isBusy else { return }
        let j = DeviceJob(kind: .snapshot, title: name ?? "Backup", subtitle: "Saving the state of your FM-1", colour: Color(hex: "#42f5f5"), imageURL: nil)
        start(job: j) { [self] in
            var j = j
            guard let dev = await openDevice() else { throw FM1Error.notFound("FM-1 not found" + (updater?.seen() ?? "")) }
            identity = dev.identity
            identityDate = Date()
            let fl = FeluccaLink(link: dev.link)
            let s: Snapshot
            do {
                let music = try await detectMusic(fl)
                s = try await makeSnapshot(dev: dev, fl: fl, music: music, name: name)
            } catch {
                dev.link.close()
                throw backupFailure(error)
            }
            dev.link.close()
            library.add(s)
            j.title = s.name
            let pkgText = s.hasPackage && (catalog.packageIsUnconfirmed(in: s) || !s.packageExact) ? "a firmware package that may not be what was on it (see the backup)"
                : s.hasPackage ? "its firmware package" : catalog.identityIsAmbiguous(s.identity) ? "no firmware package yet (choose yours in the backup)" : "no firmware package (see the backup for why)"
            let musicText = s.hasArchive
                ? "and the music archive (\(ByteCountFormatter.string(fromByteCount: Int64(s.archiveBytes ?? 0), countStyle: .file)))" + (s.musicRestoresInApp ? "" : ", which the app can't put back on this firmware")
                : "but no music archive: this firmware has no backup over USB that the app knows"
            let what = s.firmwareId == nil && catalog.identityIsAmbiguous(s.identity) ? "" : " \(s.firmwareName)\(s.version.map { " \($0)" } ?? "")"
            j.message = "Saved\(what): \(pkgText), \(musicText)."
            if s.firmwareId != nil, let c = s.firmwareId.map({ Look.colour(for: $0) }) { j.colour = c }
            return j
        } onFailure: { _ in }
    }

    private func makeSnapshot(dev: FM1Device, fl: FeluccaLink, music: (info: EditorInfo?, kind: MusicBackupKind?), name: String?, prefix: String = "") async throws -> Snapshot {
        // which firmware this is can't be worked out without the catalogue
        if catalog.firmwares.isEmpty {
            phase = .searching("Loading the hub's catalogue…")
            await catalog.refresh(force: true)
            // that returns at once when the launch's own refresh is on its way, which a timeout ends
            while catalog.loading, !Task.isCancelled { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        reportedName = music.info?.wholeName
        let who = catalog.whoIs(dev.identity.text, named: reportedName)
        let ambiguous = catalog.identityIsAmbiguous(dev.identity.text)
        let named = Firmware.named(reportedName, among: catalog.firmwares(reporting: dev.identity.text))?.product == dev.identity.text
        var s = Snapshot(name: name ?? prefix + whoIsName(dev.identity), identity: dev.identity.text, firmwareId: who?.firmware?.id,
                         // without a catalogue the identity itself, which is named once there is one
                         firmwareName: catalog.firmwares.isEmpty ? dev.identity.text : who?.firmware?.name ?? who?.name ?? dev.identity.text,
                         version: who?.exact == true ? who?.firmware?.version : nil, product: nil, packageFile: nil,
                         packageSHA256: nil, packageSize: nil, packageExact: false, archiveFile: nil, archiveBytes: nil, archiveObjects: nil)
        s.reportedName = reportedName
        let folder = library.folder(for: s)
        Paths.ensure(folder)
        // what is left of a backup that does not finish would come back as a recovered backup at the next launch
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: folder) } }
        if Task.isCancelled { throw FM1Error.cancelled }
        // the music, first: while the device is still the one we found
        if music.kind == .felucca {
            phase = .backingUp(0, 1)
            let archive = try await FeluccaBackup.capture(fl, firmware: dev.identity.text) { d, t in Task { @MainActor in self.phase = .backingUp(d, t) } }
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let data = try enc.encode(archive)
            try data.write(to: folder.appendingPathComponent("felucca-backup.json"), options: .atomic)
            s.archiveFile = "felucca-backup.json"
            s.archiveBytes = archive.totalBytes
            s.archiveObjects = archive.objects.count
            musicBackupSupported = true
            musicWritesBack = true
        } else if music.kind == .sloop, let info = music.info {
            phase = .backingUp(0, 1)
            let archive = try await SloopBackup.capture(fl, info: info, identity: dev.identity.text) { d, t in Task { @MainActor in self.phase = .backingUp(d, t) } }
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let data = try enc.encode(archive)
            try data.write(to: folder.appendingPathComponent(SloopArchive.fileName), options: .atomic)
            s.archiveFile = SloopArchive.fileName
            s.archiveBytes = archive.totalBytes
            s.archiveObjects = archive.objects.count
            s.archiveFirmware = info.version
            musicBackupSupported = true
            musicWritesBack = info.isSloop
        } else {
            musicBackupSupported = false
        }
        // the package: wherever it is
        let found = await findPackage(for: dev.identity.text, who: who, ambiguous: ambiguous)
        if Task.isCancelled { throw FM1Error.cancelled }   // not "no package found", which is what a cancelled search looks like
        if let (pkg, from) = found {
            try storePackage(pkg, in: &s, confirmed: named && from == "hub")
            if let f = who?.firmware, f.needsOwnInstaller { s.ownInstaller = f.install }
            // its maker's release of the version it named: the right file, unless a fork kept the name, version and number
            if from == DeviceController.namedRelease, let f = who?.firmware {
                s.firmwareId = f.id
                s.firmwareName = f.name
                s.version = f.versionSaid(in: reportedName)
                s.packageExact = !ambiguous
            } else if from == "phone" || from == "GitHub release", !packages.isFetchedOfficial(pkg.sha256), who?.exact != true || pkg.sha256 != who?.firmware?.sha256 {
                // found by its identity alone, on the phone or among the makers' releases: nothing ties it to this FM-1
                s.packageExact = false
                if !catalog.firmwares.contains(where: { $0.sha256 == pkg.sha256 }) { s.version = nil }
            }
            append("package for \(dev.identity.text): \(from)")
        } else if catalog.firmwares.isEmpty {
            s.packageNote = "The hub's catalogue could not be loaded when this backup was made, so the app could not tell which firmware this is. Choose it when the phone is online, or pick its file."
            append("no catalogue: no package for \(dev.identity.text)")
        } else if let f = who?.firmware, who?.exact != true, let v = f.versionSaid(in: reportedName) {
            s.packageNote = "Your FM-1 says it runs \(f.name) \(v). The hub has \(f.version), and the app could not get that version from the maker's releases. Choose the hub's, or pick its file."
            append("\(f.name) \(v) not found")
        } else if ambiguous {
            s.packageNote = who?.firmware.map { "\($0.name) \($0.version) could not be loaded from the hub. Choose it when the phone is online." }
                ?? "Several firmwares can report \(dev.identity.text), and this one did not say which it is. Choose yours and this backup becomes restorable."
            append("\(dev.identity.text) is ambiguous: no package chosen")
        } else {
            s.packageNote = "No package found for \(dev.identity.text) on the hub, on this phone or among the makers' GitHub releases, or they could not be reached. Install it once through the app, or pick its .fwsc below, and this backup becomes restorable."
            append("no package found for \(dev.identity.text)")
        }
        finished = true
        return s
    }

    /// Where a package came from when it is the maker's own release of the version the device named.
    private static let namedRelease = "the maker's release of that version"

    /// Where a package with this identity can be: the hub's catalogue, this phone, the maker's GitHub releases,
    /// M-VAVE's server for official versions. The first hit wins. Returns the package and where it came from.
    private func findPackage(for identity: String, who: WhoIs?, ambiguous: Bool) async -> (FWSCPackage, String)? {
        if let f = who?.firmware, who?.exact == true, f.product == identity {
            phase = .searching("The hub has \(f.name) \(f.version).")
            if let p = try? await packages.package(for: f) { return (p, "hub") }
        }
        // It named itself with a version the hub does not have: its maker's release of that very version, on this identity.
        if let f = who?.firmware, who?.exact != true, let v = f.versionSaid(in: reportedName) {
            phase = .searching("Checking \(f.name)'s releases on GitHub…")
            if let p = await packages.releasePackage(product: identity, candidates: [f], version: v, onStatus: { t in Task { @MainActor in self.phase = .searching(t) } }) {
                return (p, DeviceController.namedRelease)
            }
            // alone on this number: the hub's version rather than none, and the backup says it may not be that version
            if !ambiguous, f.product == identity, let p = try? await packages.package(for: f) { return (p, "hub") }
            return nil   // it said which version it is: no other build with this identity may be taken for it
        }
        // Any other package with this identity may be another firmware. Never guess.
        if ambiguous { return nil }
        phase = .searching("Looking on this phone…")
        if let p = packages.localPackage(product: identity) { return (p, "phone") }
        if FWSCPackage.isOfficialProduct(identity) {
            if identity == FWSCPackage.stockV15Product, let p = try? await packages.stockPackage(catalog.stock) { return (p, "hub (V15)") }
            phase = .searching("Asking M-VAVE's server…")
            if let p = try? await packages.officialLatest() {
                noteOfficialAnswer(p)
                if p.product == identity { return (p, "m-vave.com") }
            }
        }
        let candidates = who?.firmware.map { [$0] } ?? catalog.familyCandidates(for: identity)
        if !candidates.isEmpty {
            phase = .searching("Checking the makers' releases on GitHub…")
            if let p = await packages.releasePackage(product: identity, candidates: candidates, onStatus: { t in Task { @MainActor in self.phase = .searching(t) } }) {
                return (p, "GitHub release")
            }
        }
        return nil
    }

    /// `confirmed`: the identity is ambiguous, and the device itself named this firmware. Without that, such an identity
    /// says nothing about which firmware the package is, or whether it is the one that was on the device.
    private func storePackage(_ pkg: FWSCPackage, in s: inout Snapshot, confirmed: Bool = false) throws {
        let folder = library.folder(for: s)
        Paths.ensure(folder)
        try Data(pkg.bytes).write(to: folder.appendingPathComponent("package.fwsc"), options: .atomic)
        let ambiguous = catalog.identityIsAmbiguous(s.identity) || catalog.identityIsAmbiguous(pkg.product)
        // the device said this firmware's name with another version than this package's
        let who = catalog.whoIs(s.identity, named: s.reportedName)
        let saidOtherVersion = who?.exact == false && who?.firmware?.versionSaid(in: s.reportedName) != nil
        s.packageFile = "package.fwsc"
        s.packageSHA256 = pkg.sha256
        s.packageSize = pkg.bytes.count
        s.product = pkg.product
        s.packageExact = pkg.product == s.identity && (confirmed || (!ambiguous && !saidOtherVersion))
        s.packageConfirmed = confirmed ? true : nil
        s.ownInstaller = nil
        if let f = catalog.firmwares.first(where: { $0.sha256 == pkg.sha256 }) {
            s.version = f.version
            s.firmwareId = f.id
            s.firmwareName = f.name
            if f.needsOwnInstaller { s.ownInstaller = f.install }
        }
        else if !ambiguous, packages.isFetchedOfficial(pkg.sha256), let v = pkg.officialVersion { s.version = v; s.firmwareName = "Official firmware" }
        else if ambiguous {
            s.version = nil
            s.firmwareId = nil
            // without a catalogue the identity itself, which is named once there is one
            if s.identity.hasPrefix("FM-1_") { s.firmwareName = catalog.firmwares.isEmpty ? s.identity : catalog.whoIs(s.identity)?.name ?? s.identity }
        }
        else if s.version == nil, let f = catalog.firmwares.first(where: { $0.product == pkg.product }) { s.firmwareName = f.name }
        s.packageNote = nil
        let chip = chipSupport(sha256: pkg.sha256, product: pkg.product)
        s.chip = chip == .unknown ? nil : chip.rawValue
        if s.notes.hasPrefix("No package found for ") { s.notes = "" }   // where older versions left that word
    }

    /// A backup whose identity can't name its firmware, completed with the one the user says it is, from the hub.
    func attachFirmware(_ f: Firmware, to snapshot: Snapshot) {
        guard !isBusy, !f.needsOwnInstaller, catalog.firmwares(reporting: snapshot.identity).contains(f) else { return }
        var j = DeviceJob(kind: .snapshot, title: snapshot.name, subtitle: "\(f.name) \(f.version)", colour: Look.colour(for: f.id), imageURL: f.imageURL)
        start(job: j) { [self] in
            phase = .searching("The hub has \(f.name) \(f.version).")
            let pkg = try await packages.package(for: f)
            if Task.isCancelled { throw FM1Error.cancelled }
            var s = snapshot
            try storePackage(pkg, in: &s, confirmed: f.isNamed(by: snapshot.reportedName, identity: snapshot.identity))
            library.update(s)
            j.message = "\(f.name) \(f.version) is saved with this backup."
            return j
        } onFailure: { _ in }
    }

    /// A backup made without a package, completed from a .fwsc the user picked in Files. Returns an error text or nil.
    func attachPackage(to snapshot: Snapshot, fileURL url: URL) -> String? {
        var s = snapshot
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let pkg = try FWSCPackage(data: try Data(contentsOf: url))
            // a backup recovered from a SLOOP archive alone knows no identity to hold the file to
            guard pkg.product == s.identity || !s.identity.hasPrefix("FM-1_") else { return "That file is \(pkg.product); this backup needs \(s.identity)." }
            try? packages.keep(pkg)
            s.version = nil   // of the package this replaces, or the hub's: this file says for itself, or nothing does
            try storePackage(pkg, in: &s)
            library.update(s)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Put a snapshot's firmware back.
    func restoreFirmware(_ s: Snapshot, consent: ChipVerdict = .install) {
        guard !isBusy, let url = library.packageURL(for: s) else { return }
        let what = catalog.firmwareName(of: s)
        var j = DeviceJob(kind: .restoreFirmware, title: "Restore: \(what)", subtitle: s.version ?? s.identity, colour: s.firmwareId.map { Look.colour(for: $0) } ?? Color(hex: "#42f5f5"), imageURL: s.firmwareId.map { HubAPI.url("img/\($0).png") })
        start(job: j) { [self] in
            let before = identity?.text
            let pkg = try FWSCPackage(data: try Data(contentsOf: url))
            if let sha = s.packageSHA256, sha != pkg.sha256 { throw FM1Error.package("The saved package does not match its checksum.") }
            if catalog.ownInstaller(of: s) != nil { throw FM1Error.package("\(s.firmwareName) is installed by its maker's own page: the package alone is not all of it.") }
            try await autoSnapshotIfWanted()
            let after = try await flash(pkg, product: pkg.product, stockLoader: usesStockLoader(pkg, firmwareId: s.firmwareId),
                                        name: what, version: s.version ?? "", firmwareId: s.firmwareId, source: .snapshot,
                                        consent: consent, remembered: s.chipSupport)
            library.add(InstallRecord(firmwareId: s.firmwareId, name: what, version: s.version ?? "", product: pkg.product, sha256: pkg.sha256,
                                      identityBefore: before, identityAfter: after, source: .snapshot, success: true))
            j.message = "Back on your FM-1: \(what)." + (s.hasArchive && s.musicRestoresInApp ? " Now restore the music archive from the same backup." : "")
            return j
        } onFailure: { [self] e in
            library.add(InstallRecord(firmwareId: s.firmwareId, name: what, version: s.version ?? "", product: s.product ?? "", sha256: s.packageSHA256,
                                      identityBefore: identity?.text, identityAfter: nil, source: .snapshot, success: false, error: e.localizedDescription))
        }
    }

    /// Put a snapshot's music archive back (the firmware must speak the archive's protocol, best the same firmware).
    func restoreArchive(_ s: Snapshot) {
        guard !isBusy, let url = library.archiveURL(for: s) else { return }
        var j = DeviceJob(kind: .restoreArchive, title: "Restore music: \(s.name)", subtitle: catalog.firmwareName(of: s), colour: Color(hex: "#42f5f5"), imageURL: nil)
        start(job: j) { [self] in
            if s.hasSloopArchive {
                j.message = try await restoreSloopArchive(from: url, of: s)
                return j
            }
            let archive = try JSONDecoder().decode(FeluccaArchive.self, from: try Data(contentsOf: url))
            _ = try FeluccaBackup.validate(archive)
            guard let dev = await openDevice() else { throw FM1Error.notFound("FM-1 not found" + (updater?.seen() ?? "")) }
            identity = dev.identity
            let fl = FeluccaLink(link: dev.link)
            guard await FeluccaBackup.supported(fl) else {
                dev.link.close()
                throw FM1Error.protocolError("The firmware on the FM-1 (\(dev.identity.text)) does not answer the backup protocol. Restore \(catalog.firmwareName(of: s)) first, then the music.")
            }
            if Task.isCancelled { dev.link.close(); throw FM1Error.cancelled }   // the last moment Cancel can be pressed
            phase = .restoring(0, archive.totalBytes)
            do {
                try await FeluccaBackup.restore(fl, archive) { d, t in Task { @MainActor in self.phase = .restoring(d, t) } }
            } catch {
                dev.link.close()
                throw restoreFailure(error)
            }
            dev.link.close()
            j.message = "The music archive is back on your FM-1" + (archive.firmware != dev.identity.text ? " (it was made on \(archive.firmware), the FM-1 runs \(dev.identity.text))." : ".")
            return j
        } onFailure: { _ in }
    }

    /// Writes a SLOOP archive back and returns what to tell the user. The file is checked before the FM-1 is touched.
    private func restoreSloopArchive(from url: URL, of s: Snapshot) async throws -> String {
        let archive = try JSONDecoder().decode(SloopArchive.self, from: try Data(contentsOf: url))
        _ = try SloopBackup.validate(archive)
        guard let dev = await openDevice() else { throw FM1Error.notFound("FM-1 not found" + (updater?.seen() ?? "")) }
        identity = dev.identity
        let fl = FeluccaLink(link: dev.link)
        let music = await SloopBackup.detect(fl)
        reportedName = music.info?.wholeName
        guard music.kind == .sloop, let info = music.info else {
            dev.link.close()
            throw FM1Error.protocolError("The firmware on the FM-1 (\(music.info?.name ?? dev.identity.text)) does not answer SLOOP's backup protocol. Restore \(catalog.firmwareName(of: s)) first, then the music.")
        }
        // a firmware built on SLOOP can keep its name: its number tells it apart
        if s.identity.hasPrefix("FM-1_"), !FM1Identity.same(s.identity, dev.identity.text) {
            dev.link.close()
            throw FM1Error.package("This music was made on a firmware that reports \(s.identity), and the FM-1 reports \(dev.identity.text). Restore the firmware first.")
        }
        if Task.isCancelled { dev.link.close(); throw FM1Error.cancelled }   // the last moment Cancel can be pressed
        phase = .restoring(0, archive.totalBytes)
        do {
            try await SloopBackup.restore(fl, archive, info: info) { d, t in Task { @MainActor in self.phase = .restoring(d, t) } }
        } catch {
            dev.link.close()
            throw restoreFailure(error)
        }
        dev.link.close()
        return "The music archive is back on your FM-1" + (archive.firmware != info.version ? " (it was made on \(EditorInfo.ownName(of: archive.firmware)), the FM-1 runs \(info.name))." : ".")
    }

    func dismissJob() {
        if job?.finished == true { job = nil }
        showJobSheet = false
    }
}
