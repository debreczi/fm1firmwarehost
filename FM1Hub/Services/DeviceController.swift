import Foundation
import Observation
import SwiftUI

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
    /// M-VAVE's current official firmware, once checked: its identity ("FM-1_016") and whether it is on the phone.
    private(set) var officialLatest: String?
    private(set) var officialChecking = false
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
        officialLatest = packages.newestCachedOfficial()?.product
    }

    var whoIs: WhoIs? { catalog.whoIs(identity?.text) }
    var isConnected: Bool { identity != nil }
    var isBusy: Bool { phase.isBusy }
    var officialLatestVersion: String? { officialLatest.flatMap { FWSCPackage.officialVersion(of: $0) } }

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

    /// Asks M-VAVE's server which official version is current (and keeps the file). Quiet when offline.
    func checkOfficial() async {
        guard !officialChecking else { return }
        officialChecking = true
        defer { officialChecking = false }
        if let p = try? await packages.officialLatest() {
            officialLatest = p.product
            append("official firmware on m-vave.com: \(p.product)")
        }
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
    func installOfficial(latest: Bool) {
        guard !isBusy else { return }
        let title = latest ? "Official firmware" : "Official firmware V15"
        var j = DeviceJob(kind: .official, title: title, subtitle: latest ? "M-VAVE's current release" : "M-VAVE's recovery image, from the hub", colour: Color(hex: "#9aa4b2"), imageURL: nil)
        var product = latest ? (officialLatest ?? "") : FWSCPackage.stockV15Product
        start(job: j) { [self] in
            let before = identity?.text
            try await autoSnapshotIfWanted()
            phase = .downloading(0)
            let pkg: FWSCPackage
            if latest {
                do {
                    pkg = try await packages.officialLatest { p in Task { @MainActor in self.phase = .downloading(p) } }
                } catch {
                    guard let cached = try? await packages.officialLatest(cachedOnly: true) else { throw error }
                    append("m-vave.com unreachable, using the cached \(cached.product)")
                    pkg = cached
                }
                officialLatest = pkg.product
            } else {
                pkg = try await packages.stockPackage(catalog.stock) { p in Task { @MainActor in self.phase = .downloading(p) } }
            }
            product = pkg.product
            j.title = "Official firmware \(pkg.officialVersion ?? pkg.product)"
            let after = try await flash(pkg, product: pkg.product, stockLoader: true)
            library.add(InstallRecord(firmwareId: nil, name: "Official firmware", version: pkg.officialVersion ?? "", product: pkg.product, sha256: pkg.sha256,
                                      identityBefore: before, identityAfter: after, source: .stock, success: true))
            j.message = "The official \(pkg.officialVersion ?? pkg.product) is on your FM-1."
            return j
        } onFailure: { [self] e in
            library.add(InstallRecord(firmwareId: nil, name: "Official firmware", version: FWSCPackage.officialVersion(of: product) ?? "", product: product, sha256: nil,
                                      identityBefore: identity?.text, identityAfter: nil, source: .stock, success: false, error: e.localizedDescription))
        }
    }

    /// A package chosen in the Files app (the last resort: a release the app could not find on its own).
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
            packages.keep(pkg)
            let who = catalog.whoIs(pkg.product)
            let known = catalog.firmwares.first { $0.sha256 == pkg.sha256 }
            j.title = known?.name ?? who?.name ?? pkg.product
            j.subtitle = known.map { "\($0.version) · \(url.lastPathComponent)" } ?? url.lastPathComponent
            if let k = known { j.colour = Look.colour(for: k.id); j.imageURL = k.imageURL }
            try await autoSnapshotIfWanted()
            let after = try await flash(pkg, product: pkg.product, stockLoader: pkg.isOfficial || known?.usesStockLoader == true)
            library.add(InstallRecord(firmwareId: known?.id, name: j.title, version: known?.version ?? "", product: pkg.product, sha256: pkg.sha256,
                                      identityBefore: before, identityAfter: after, source: .file, success: true))
            j.message = "\(j.title) is on your FM-1."
            return j
        } onFailure: { [self] e in
            library.add(InstallRecord(firmwareId: nil, name: url.lastPathComponent, version: "", product: "", sha256: nil,
                                      identityBefore: identity?.text, identityAfter: nil, source: .file, success: false, error: e.localizedDescription))
        }
    }

    /// The device is in update mode (an interrupted update): write the last package again, from the loader.
    func resume() {
        guard !isBusy, let last = library.lastInstalled else { return }
        let f = last.firmwareId.flatMap { catalog.firmware(id: $0) }
        var j = DeviceJob(kind: .resume, title: "Resume: \(last.name)", subtitle: last.version, colour: f.map { Look.colour(for: $0.id) } ?? Color(hex: "#9aa4b2"), imageURL: f?.imageURL)
        start(job: j) { [self] in
            phase = .downloading(0)
            let pkg: FWSCPackage
            if let f = f { pkg = try await packages.package(for: f) }
            else if let p = packages.localPackage(product: last.product) { pkg = p }
            else if last.product == FWSCPackage.stockV15Product { pkg = try await packages.stockPackage(catalog.stock) }
            else { throw FM1Error.package("The last package (\(last.product)) is not on this phone any more.") }
            let up = makeUpdater()
            let stockProduct: String? = (pkg.isOfficial || f?.usesStockLoader == true) ? pkg.product : nil
            let done = try await up.resume(image: pkg.logicalImage, stockProduct: stockProduct) { s in Task { @MainActor in self.phase = .installing(s) } }
            guard done else { throw FM1Error.stopped("The loader stopped before the end. Replug and try again.") }
            identity = FM1Identity.parse(text: pkg.product)
            identityDate = Date()
            loaderWaiting = nil
            library.add(InstallRecord(firmwareId: f?.id, name: last.name, version: last.version, product: pkg.product, sha256: pkg.sha256,
                                      identityBefore: "update loader", identityAfter: pkg.product, source: .resume, success: true))
            j.message = "\(last.name) was written. If the FM-1 did not restart, power-cycle it."
            return j
        } onFailure: { _ in }
    }

    /// Running firmware -> loader -> new firmware, or straight from a waiting loader. Returns the identity reported after.
    private func flash(_ pkg: FWSCPackage, product: String, stockLoader: Bool) async throws -> String {
        let up = makeUpdater()
        let image = pkg.logicalImage
        packages.keep(pkg)
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
            let s = try await makeSnapshot(dev: dev, fl: fl, name: "Before install · \(whoIsName(dev.identity))")
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

    /// Save the state of the FM-1: which firmware is on it with its package (found wherever it is), plus the Felucca
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
                s = try await makeSnapshot(dev: dev, fl: fl, name: name ?? whoIsName(dev.identity))
            } catch {
                dev.link.close()
                throw error
            }
            dev.link.close()
            library.add(s)
            j.title = s.name
            let pkgText = s.hasPackage ? "its firmware package" : "no firmware package (see the backup for why)"
            let musicText = s.hasArchive
                ? "and the music archive (\(ByteCountFormatter.string(fromByteCount: Int64(s.archiveBytes ?? 0), countStyle: .file)))"
                : "but no music archive: this firmware does not offer one over USB"
            j.message = "Saved \(s.firmwareName)\(s.version.map { " \($0)" } ?? ""): \(pkgText), \(musicText)."
            if s.firmwareId != nil, let c = s.firmwareId.map({ Look.colour(for: $0) }) { j.colour = c }
            return j
        } onFailure: { _ in }
    }

    private func makeSnapshot(dev: FM1Device, fl: FeluccaLink, name: String) async throws -> Snapshot {
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
        // the package: wherever it is
        if let found = await findPackage(for: dev.identity.text, who: who) {
            let (pkg, from) = found
            try storePackage(pkg, in: &s)
            append("package for \(dev.identity.text): \(from)")
        } else {
            s.notes = "No package found for \(dev.identity.text): not on the hub, not on this phone, not among the makers' GitHub releases. Install it once through the app, or pick its .fwsc below, and this backup becomes restorable."
            append("no package found for \(dev.identity.text)")
        }
        return s
    }

    /// Where a package with this identity can be: the hub's catalogue, this phone, the maker's GitHub releases,
    /// M-VAVE's server for official versions. The first hit wins. Returns the package and where it came from.
    private func findPackage(for identity: String, who: WhoIs?) async -> (FWSCPackage, String)? {
        if let f = who?.firmware, f.product == identity {
            phase = .searching("The hub has \(f.name) \(f.version).")
            if let p = try? await packages.package(for: f) { return (p, "hub") }
        }
        phase = .searching("Looking on this phone…")
        if let p = packages.localPackage(product: identity) { return (p, "phone") }
        if FWSCPackage.isOfficialProduct(identity) {
            if identity == FWSCPackage.stockV15Product, let p = try? await packages.stockPackage(catalog.stock) { return (p, "hub (V15)") }
            phase = .searching("Asking M-VAVE's server…")
            if let p = try? await packages.officialLatest(), p.product == identity { return (p, "m-vave.com") }
        }
        let candidates = catalog.familyCandidates(for: identity)
        if !candidates.isEmpty {
            phase = .searching("Checking the makers' releases on GitHub…")
            if let p = await packages.releasePackage(product: identity, candidates: candidates, onStatus: { t in Task { @MainActor in self.phase = .searching(t) } }) {
                return (p, "GitHub release")
            }
        }
        return nil
    }

    private func storePackage(_ pkg: FWSCPackage, in s: inout Snapshot) throws {
        let folder = library.folder(for: s)
        Paths.ensure(folder)
        try Data(pkg.bytes).write(to: folder.appendingPathComponent("package.fwsc"), options: .atomic)
        s.packageFile = "package.fwsc"
        s.packageSHA256 = pkg.sha256
        s.packageSize = pkg.bytes.count
        s.product = pkg.product
        s.packageExact = pkg.product == s.identity
        if let v = pkg.officialVersion { s.version = v; s.firmwareName = "Official firmware" }
        else if let f = catalog.firmwares.first(where: { $0.sha256 == pkg.sha256 }) { s.version = f.version; s.firmwareId = f.id; s.firmwareName = f.name }
        else if s.version == nil, let f = catalog.firmwares.first(where: { $0.product == pkg.product }) { s.firmwareName = f.name }
        s.notes = ""
    }

    /// A backup made without a package, completed from a .fwsc the user picked in Files. Returns an error text or nil.
    func attachPackage(to snapshot: Snapshot, fileURL url: URL) -> String? {
        var s = snapshot
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let pkg = try FWSCPackage(data: try Data(contentsOf: url))
            guard pkg.product == s.identity else { return "That file is \(pkg.product); this backup needs \(s.identity)." }
            packages.keep(pkg)
            try storePackage(pkg, in: &s)
            library.update(s)
            return nil
        } catch {
            return error.localizedDescription
        }
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
            let after = try await flash(pkg, product: pkg.product, stockLoader: pkg.isOfficial || fw?.usesStockLoader == true)
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
                throw FM1Error.protocolError("The firmware on the FM-1 (\(dev.identity.text)) does not answer the backup protocol. Restore \(s.firmwareName) first, then the music.")
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
