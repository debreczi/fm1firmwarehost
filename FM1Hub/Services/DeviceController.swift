import Foundation
import Observation
import SwiftUI

/// What the device layer is doing right now, for the screens.
enum DevicePhase: Equatable {
    case idle
    case connecting
    case downloading(Double)
    case installing(InstallStep)
    case backingUp(Int, Int)
    case restoring(Int, Int)

    var isBusy: Bool { self != .idle }

    var title: String {
        switch self {
        case .idle: return "Idle"
        case .connecting: return "Looking for the FM-1"
        case .downloading: return "Loading the package"
        case .installing(let s): return s.title
        case .backingUp: return "Backing up"
        case .restoring: return "Restoring"
        }
    }

    var fraction: Double? {
        switch self {
        case .idle, .connecting: return nil
        case .downloading(let f): return f
        case .installing(let s): return s.fraction
        case .backingUp(let d, let t), .restoring(let d, let t): return t > 0 ? Double(d) / Double(t) : nil
        }
    }
}

/// A running or finished job, shown in the progress sheet.
struct DeviceJob: Identifiable, Equatable {
    enum Kind: Equatable { case install, stock, resume, snapshot, restoreFirmware, restoreArchive, file }
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
    private(set) var feluccaBackupSupported: Bool?
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
    }

    var whoIs: WhoIs? { catalog.whoIs(identity?.text) }
    var isConnected: Bool { identity != nil }
    var isBusy: Bool { phase.isBusy }

    private func makeUpdater() -> FM1Updater {
        let u = FM1Updater(engine: engine)
        u.probeAll = settings.probeAllPorts
        u.chosenPorts = Set(settings.chosenPorts)
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

    private func setupChanged() {
        refreshPorts()
        if midiPorts.isEmpty, !isBusy {
            identity = nil
            feluccaBackupSupported = nil
            statusMessage = "No MIDI device."
        }
    }

    func choosePort(_ name: String) {
        if !settings.chosenPorts.contains(name) { settings.chosenPorts.append(name) }
        otherPorts.removeAll { $0 == name }
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
                feluccaBackupSupported = nil
                if !dev.identity.isLoader { await probeFeluccaSupport() }
            } else {
                identity = nil
                feluccaBackupSupported = nil
                otherPorts = up.others()
                statusMessage = "No FM-1 found" + up.seen() + ". Plug it in by USB, close other MIDI apps, try again."
                append("no FM-1" + up.seen())
            }
            refreshPorts()
            phase = .idle
        }
    }

    /// Does the running firmware answer the Felucca backup protocol? (Felucca and the firmwares built on it do.)
    private func probeFeluccaSupport() async {
        guard let dev = await openDevice() else { return }
        let fl = FeluccaLink(link: dev.link)
        let ok = await FeluccaBackup.supported(fl)
        dev.link.close()
        feluccaBackupSupported = ok
        append(ok ? "backup protocol: supported" : "backup protocol: not answered")
    }

    private func openDevice() async -> FM1Device? {
        let up = updater ?? makeUpdater()
        return await up.find { !$0.isLoader }
    }

    func cancel() {
        updater?.cancel()
        task?.cancel()
    }

    // MARK: Install

    func install(_ f: Firmware) {
        guard !isBusy else { return }
        var j = DeviceJob(kind: .install, title: f.name, subtitle: "\(f.version) · by \(f.author)", colour: Look.colour(for: f.id), imageURL: f.imageURL)
        start(job: j) { [self] in
            let before = identity?.text
            try await autoSnapshotIfWanted()
            phase = .downloading(0)
            let pkg = try await packages.package(for: f) { p in Task { @MainActor in self.phase = .downloading(p) } }
            let after = try await flash(pkg, product: f.product, stockLoader: f.usesStockLoader)
            if !settings.keepPackagesOffline { try? FileManager.default.removeItem(at: packages.localURL(for: f)) }
            library.add(InstallRecord(firmwareId: f.id, name: f.name, version: f.version, product: f.product, sha256: f.sha256,
                                      identityBefore: before, identityAfter: after, source: .hub, success: true))
            j.message = "\(f.name) \(f.version) is on your FM-1."
            return j
        } onFailure: { [self] e in
            library.add(InstallRecord(firmwareId: f.id, name: f.name, version: f.version, product: f.product, sha256: f.sha256,
                                      identityBefore: identity?.text, identityAfter: nil, source: .hub, success: false, error: e.localizedDescription))
        }
    }

    func installStock() {
        guard !isBusy else { return }
        var j = DeviceJob(kind: .stock, title: "Official firmware V15", subtitle: "M-VAVE's own FM-1 V15", colour: Color(hex: "#9aa4b2"), imageURL: nil)
        start(job: j) { [self] in
            let before = identity?.text
            try await autoSnapshotIfWanted()
            phase = .downloading(0)
            let pkg = try await packages.stockPackage(catalog.stock) { p in Task { @MainActor in self.phase = .downloading(p) } }
            let after = try await flash(pkg, product: FWSCPackage.stockV15Product, stockLoader: true)
            library.add(InstallRecord(firmwareId: nil, name: "Official firmware", version: "V15", product: FWSCPackage.stockV15Product, sha256: pkg.sha256,
                                      identityBefore: before, identityAfter: after, source: .stock, success: true))
            j.message = "The official V15 is on your FM-1."
            return j
        } onFailure: { [self] e in
            library.add(InstallRecord(firmwareId: nil, name: "Official firmware", version: "V15", product: FWSCPackage.stockV15Product, sha256: nil,
                                      identityBefore: identity?.text, identityAfter: nil, source: .stock, success: false, error: e.localizedDescription))
        }
    }

    /// A package chosen in the Files app: the hub's own format, or the official V15 downloaded from m-vave.com.
    func installFile(_ url: URL) {
        guard !isBusy else { return }
        var j = DeviceJob(kind: .file, title: url.lastPathComponent, subtitle: "Package from a file", colour: Color(hex: "#9aa4b2"), imageURL: nil)
        start(job: j) { [self] in
            let before = identity?.text
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let pkg = try FWSCPackage(data: data)
            guard pkg.product.hasPrefix("FM-1_") else { throw FM1Error.package("The file is for \(pkg.product), not for an FM-1.") }
            let who = catalog.whoIs(pkg.product)
            let known = catalog.firmwares.first { $0.sha256 == pkg.sha256 }
            j.title = known?.name ?? who?.name ?? pkg.product
            j.subtitle = known.map { "\($0.version) · \(url.lastPathComponent)" } ?? url.lastPathComponent
            if let k = known { j.colour = Look.colour(for: k.id); j.imageURL = k.imageURL }
            try await autoSnapshotIfWanted()
            let after = try await flash(pkg, product: pkg.product, stockLoader: pkg.isStockV15 || known?.usesStockLoader == true)
            library.add(InstallRecord(firmwareId: known?.id, name: j.title, version: known?.version ?? "", product: pkg.product, sha256: pkg.sha256,
                                      identityBefore: before, identityAfter: after, source: .file, success: true))
            j.message = "\(j.title) is on your FM-1."
            return j
        } onFailure: { [self] e in
            library.add(InstallRecord(firmwareId: nil, name: url.lastPathComponent, version: "", product: "", sha256: nil,
                                      identityBefore: identity?.text, identityAfter: nil, source: .file, success: false, error: e.localizedDescription))
        }
    }

    /// The device is in update mode (an interrupted update): write the package again, from the loader.
    func resume(_ f: Firmware?) {
        guard !isBusy else { return }
        let title = f?.name ?? "Official firmware V15"
        var j = DeviceJob(kind: .resume, title: "Resume: \(title)", subtitle: f?.version ?? "V15", colour: f.map { Look.colour(for: $0.id) } ?? Color(hex: "#9aa4b2"), imageURL: f?.imageURL)
        start(job: j) { [self] in
            phase = .downloading(0)
            let pkg: FWSCPackage
            if let f = f { pkg = try await packages.package(for: f) } else { pkg = try await packages.stockPackage(catalog.stock) }
            let up = makeUpdater()
            let stockProduct: String? = (f == nil || f?.usesStockLoader == true) ? pkg.product : nil
            let done = try await up.resume(image: pkg.logicalImage, stockProduct: stockProduct) { s in Task { @MainActor in self.phase = .installing(s) } }
            guard done else { throw FM1Error.stopped("The loader stopped before the end. Replug and try again.") }
            identity = FM1Identity.parse(text: pkg.product)
            identityDate = Date()
            loaderWaiting = nil
            library.add(InstallRecord(firmwareId: f?.id, name: title, version: f?.version ?? "V15", product: pkg.product, sha256: pkg.sha256,
                                      identityBefore: "update loader", identityAfter: pkg.product, source: .resume, success: true))
            j.message = "\(title) was written. If the FM-1 did not restart, power-cycle it."
            return j
        } onFailure: { _ in }
    }

    /// Running firmware -> loader -> new firmware, or straight from a waiting loader. Returns the identity reported after.
    private func flash(_ pkg: FWSCPackage, product: String, stockLoader: Bool) async throws -> String {
        let up = makeUpdater()
        let image = pkg.logicalImage
        var after: String
        if let ota = await up.loaderPresent() {
            append("loader waiting: \(ota.text), resuming")
            let done = try await up.resume(image: image, stockProduct: stockLoader ? product : nil) { s in Task { @MainActor in self.phase = .installing(s) } }
            guard done else { throw FM1Error.stopped("The loader stopped before the end. Replug and press Install again.") }
            after = product
        } else {
            after = try await up.install(image: image, product: product) { s in Task { @MainActor in self.phase = .installing(s) } }
        }
        identity = FM1Identity.parse(text: after)
        identityDate = Date()
        loaderWaiting = nil
        feluccaBackupSupported = nil
        return after
    }

    private func start(job: DeviceJob, work: @MainActor @escaping () async throws -> DeviceJob, onFailure: @MainActor @escaping (Error) -> Void) {
        self.job = job
        showJobSheet = true
        phase = .connecting
        statusMessage = ""
        task = Task {
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
                if fe?.code == "notfound" { otherPorts = updater?.others() ?? [] }
                append("error: \(j.message)")
                onFailure(error)
            }
            self.job = j
            phase = .idle
        }
    }

    // MARK: Snapshots

    /// Before an install: when the setting is on and the running firmware answers the backup protocol, keep its music.
    private func autoSnapshotIfWanted() async throws {
        guard settings.autoSnapshotBeforeInstall else { return }
        guard let dev = await openDevice() else { return }
        let fl = FeluccaLink(link: dev.link)
        guard await FeluccaBackup.supported(fl) else { dev.link.close(); return }
        append("auto backup before install")
        identity = dev.identity
        do {
            let s = try await makeSnapshot(dev: dev, fl: fl, name: "Before install · \(whoIsName(dev.identity))", withPackage: true)
            library.add(s)
        } catch {
            append("auto backup failed: \(error.localizedDescription)")
            dev.link.close()
            throw FM1Error.stopped("The backup before the install failed (\(error.localizedDescription)). Nothing was written. Stop playback on the FM-1 and try again, or turn the automatic backup off in Settings.")
        }
        dev.link.close()
    }

    private func whoIsName(_ id: FM1Identity) -> String {
        let w = catalog.whoIs(id.text)
        if let f = w?.firmware { return f.name + (w?.exact == true ? " \(f.version)" : "") }
        return w?.name ?? id.text
    }

    /// Save the state of the FM-1: which firmware is on it (and its package, when the hub has it), plus the Felucca
    /// archive when the firmware answers the backup protocol.
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
                s = try await makeSnapshot(dev: dev, fl: fl, name: name ?? whoIsName(dev.identity), withPackage: true)
            } catch {
                dev.link.close()
                throw error
            }
            dev.link.close()
            library.add(s)
            j.title = s.name
            j.message = s.hasArchive
                ? "Saved: \(s.firmwareName)\(s.hasPackage ? " with its package" : "") and the music archive (\(ByteCountFormatter.string(fromByteCount: Int64(s.archiveBytes ?? 0), countStyle: .file)))."
                : "Saved: \(s.firmwareName)\(s.hasPackage ? " with its package" : ""). This firmware does not offer a music archive over USB; use its own backup tool for projects and presets."
            return j
        } onFailure: { _ in }
    }

    private func makeSnapshot(dev: FM1Device, fl: FeluccaLink, name: String, withPackage: Bool) async throws -> Snapshot {
        let who = catalog.whoIs(dev.identity.text)
        var s = Snapshot(name: name, identity: dev.identity.text, firmwareId: who?.firmware?.id,
                         firmwareName: who?.firmware?.name ?? who?.name ?? dev.identity.text,
                         version: who?.exact == true ? who?.firmware?.version : nil, product: nil, packageFile: nil,
                         packageSHA256: nil, packageSize: nil, packageExact: false, archiveFile: nil, archiveBytes: nil, archiveObjects: nil)
        let folder = library.folder(for: s)
        Paths.ensure(folder)
        // the music, first: while the device is still the one we found
        if await FeluccaBackup.supported(fl) {
            phase = .backingUp(0, 1)
            let archive = try await FeluccaBackup.capture(fl, firmware: dev.identity.text) { d, t in Task { @MainActor in self.phase = .backingUp(d, t) } }
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let data = try enc.encode(archive)
            try data.write(to: folder.appendingPathComponent("felucca-backup.json"), options: .atomic)
            s.archiveFile = "felucca-backup.json"
            s.archiveBytes = archive.totalBytes
            s.archiveObjects = archive.objects.count
            feluccaBackupSupported = true
        } else {
            feluccaBackupSupported = false
        }
        // the package: the exact version when the hub has it, else the hub's current one of that family
        if withPackage {
            if dev.identity.text == FWSCPackage.stockV15Product {
                if let pkg = try? await packages.stockPackage(catalog.stock) {
                    try? Data(pkg.bytes).write(to: folder.appendingPathComponent("package.fwsc"), options: .atomic)
                    s.packageFile = "package.fwsc"; s.packageSHA256 = pkg.sha256; s.packageSize = pkg.bytes.count; s.product = pkg.product; s.packageExact = true
                }
            } else if let f = who?.firmware {
                phase = .downloading(0)
                if let pkg = try? await packages.package(for: f) {
                    try? Data(pkg.bytes).write(to: folder.appendingPathComponent("package.fwsc"), options: .atomic)
                    s.packageFile = "package.fwsc"; s.packageSHA256 = pkg.sha256; s.packageSize = pkg.bytes.count; s.product = pkg.product
                    s.packageExact = who?.exact == true
                    s.version = f.version
                }
            }
        }
        return s
    }

    /// Put a snapshot's firmware back.
    func restoreFirmware(_ s: Snapshot) {
        guard !isBusy, let url = library.packageURL(for: s) else { return }
        var j = DeviceJob(kind: .restoreFirmware, title: "Restore: \(s.firmwareName)", subtitle: s.version ?? s.identity, colour: s.firmwareId.map { Look.colour(for: $0) } ?? Color(hex: "#42f5f5"), imageURL: s.firmwareId.map { HubAPI.url("img/\($0).png") })
        start(job: j) { [self] in
            let before = identity?.text
            let pkg = try FWSCPackage(data: try Data(contentsOf: url))
            if let sha = s.packageSHA256, sha != pkg.sha256 { throw FM1Error.package("The saved package does not match its checksum.") }
            try await autoSnapshotIfWanted()
            let fw = s.firmwareId.flatMap { catalog.firmware(id: $0) }
            let after = try await flash(pkg, product: pkg.product, stockLoader: pkg.isStockV15 || fw?.usesStockLoader == true)
            library.add(InstallRecord(firmwareId: s.firmwareId, name: s.firmwareName, version: s.version ?? "", product: pkg.product, sha256: pkg.sha256,
                                      identityBefore: before, identityAfter: after, source: .snapshot, success: true))
            j.message = "\(s.firmwareName) is back on your FM-1." + (s.hasArchive ? " Now restore the music archive from the same backup." : "")
            return j
        } onFailure: { [self] e in
            library.add(InstallRecord(firmwareId: s.firmwareId, name: s.firmwareName, version: s.version ?? "", product: s.product ?? "", sha256: s.packageSHA256,
                                      identityBefore: identity?.text, identityAfter: nil, source: .snapshot, success: false, error: e.localizedDescription))
        }
    }

    /// Put a snapshot's music archive back (the firmware must be a Felucca-family one, best the same).
    func restoreArchive(_ s: Snapshot) {
        guard !isBusy, let url = library.archiveURL(for: s) else { return }
        var j = DeviceJob(kind: .restoreArchive, title: "Restore music: \(s.name)", subtitle: s.firmwareName, colour: Color(hex: "#42f5f5"), imageURL: nil)
        start(job: j) { [self] in
            let archive = try JSONDecoder().decode(FeluccaArchive.self, from: try Data(contentsOf: url))
            _ = try FeluccaBackup.validate(archive)
            guard let dev = await openDevice() else { throw FM1Error.notFound("FM-1 not found" + (updater?.seen() ?? "")) }
            identity = dev.identity
            let fl = FeluccaLink(link: dev.link)
            guard await FeluccaBackup.supported(fl) else {
                dev.link.close()
                throw FM1Error.protocolError("The firmware on the FM-1 (\(dev.identity.text)) does not answer the backup protocol. Install \(s.firmwareName) first, then restore.")
            }
            phase = .restoring(0, archive.totalBytes)
            do {
                try await FeluccaBackup.restore(fl, archive) { d, t in Task { @MainActor in self.phase = .restoring(d, t) } }
            } catch {
                dev.link.close()
                throw error
            }
            dev.link.close()
            j.message = "The music archive is back on your FM-1" + (archive.firmware != dev.identity.text ? " (it was made on \(archive.firmware), the FM-1 runs \(dev.identity.text))." : ".")
            return j
        } onFailure: { _ in }
    }

    func dismissJob() {
        if job?.finished == true { job = nil }
        showJobSheet = false
    }
}
