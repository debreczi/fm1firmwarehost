import Foundation
import Observation

/// Who a device identity belongs to, as the hub works it out.
struct WhoIs {
    let firmware: Firmware?
    let exact: Bool
    let name: String
    var isStock: Bool { firmware == nil && exact && name.contains("official") }
}

@MainActor
@Observable
final class CatalogStore {
    private(set) var firmwares: [Firmware] = []
    private(set) var stock: StockFirmware?
    private(set) var creators: [String: Creator] = [:]
    private(set) var updated: String?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var lastFetched: Date?

    init() {
        loadCache()
    }

    func firmware(id: String) -> Firmware? { firmwares.first { $0.id == id } }

    func loadCache() {
        guard let data = try? Data(contentsOf: Paths.catalogCache) else { return }
        apply(data)
    }

    func refresh(force: Bool = false) async {
        if loading { return }
        if !force, let t = lastFetched, Date().timeIntervalSince(t) < 300, !firmwares.isEmpty { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            var req = URLRequest(url: HubAPI.catalog)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            if apply(data) {
                try? data.write(to: Paths.catalogCache, options: .atomic)
                lastFetched = Date()
            } else {
                error = "The catalogue could not be read."
            }
        } catch {
            self.error = firmwares.isEmpty ? "The catalogue could not be loaded: \(error.localizedDescription)" : nil
        }
    }

    @discardableResult
    func apply(_ data: Data) -> Bool {
        guard let cat = try? JSONDecoder().decode(Catalog.self, from: data) else { return false }
        firmwares = cat.firmwares.filter { !$0.pkg.isEmpty && !$0.product.isEmpty }
        stock = cat.stock
        creators = cat.creators ?? [:]
        updated = cat.updated
        return true
    }

    /// The firmwares of the catalogue an FM-1 reporting this identity may be running: those whose package has it, and
    /// those whose family range names it, because a version the hub no longer lists reports it too (Skiff 1.4 is
    /// FM-1_714, which the hub's Matryoshka also reports).
    func firmwares(reporting identity: String) -> [Firmware] {
        firmwares.filter { f in
            if f.product == identity { return true }
            guard let ident = f.ident, ident != Firmware.anyIdentity, let re = try? NSRegularExpression(pattern: "^(?:" + ident + ")$") else { return false }
            return re.firstMatch(in: identity, range: NSRange(identity.startIndex..., in: identity)) != nil
        }
    }

    /// Can't this identity alone name a firmware? Then nothing may be taken for it: several firmwares have it, or none
    /// does and several ranges cover it; without the catalogue nothing is known; and an official-looking number can be a
    /// custom firmware's. One firmware that has it, with other ranges covering it, still names that one, as the hub says
    /// (FM-1_714 is Matryoshka), but no backup can be sure of it: see `packageIsUnconfirmed`.
    func identityIsAmbiguous(_ identity: String) -> Bool {
        let may = firmwares(reporting: identity)
        if FWSCPackage.isOfficialProduct(identity) { return !may.isEmpty }
        if firmwares.isEmpty { return true }
        let owners = may.filter { $0.product == identity }
        return owners.count > 1 || (owners.isEmpty && may.count > 1)
    }

    /// A backup whose package nothing ties to the firmware that was on the device.
    func packageIsUnconfirmed(in s: Snapshot) -> Bool {
        guard !Demo.isOn, s.hasPackage, s.packageConfirmed != true else { return false }
        return identityIsAmbiguous(s.identity) || firmwares(reporting: s.identity).count > 1 || (!s.packageExact && s.version == nil)
    }

    /// The firmware behind an identity string, as the hub's whoIs(): an exact product match names one, a family
    /// range (the "ident" pattern) names one when only one matches. What the device says of itself (`reported`) can name
    /// one among those the identity may be: its name and version are the hub's, or its name with another version.
    func whoIs(_ text: String?, named reported: String? = nil) -> WhoIs? {
        guard let text = text, !text.isEmpty else { return nil }
        let may = firmwares(reporting: text)
        let official = FWSCPackage.officialVersion(of: text)
        if let v = official, may.isEmpty { return WhoIs(firmware: nil, exact: true, name: "the official firmware (\(v))") }
        if text == "FM-1_000" { return WhoIs(firmware: nil, exact: true, name: "the USB rescue mode (FM-1_000)") }
        if text.lowercased().hasPrefix("ota-") { return WhoIs(firmware: nil, exact: true, name: "the update loader (\(text))") }
        if let f = Firmware.named(reported, among: may) { return WhoIs(firmware: f, exact: f.product == text, name: f.name) }
        let sameName = may.filter { $0.versionSaid(in: reported) != nil }
        if sameName.count == 1 { return WhoIs(firmware: sameName[0], exact: false, name: sameName[0].name) }
        if let v = official { return WhoIs(firmware: nil, exact: false, name: (may.map(\.name) + ["the official firmware (\(v))"]).joined(separator: " or ")) }
        let owners = may.filter { $0.product == text }
        if owners.count == 1 { return WhoIs(firmware: owners[0], exact: true, name: owners[0].name) }
        let list = owners.isEmpty ? may : owners
        if list.count == 2 { return WhoIs(firmware: nil, exact: false, name: list.map(\.name).joined(separator: " or ")) }
        if list.count > 2 { return WhoIs(firmware: nil, exact: false, name: "one of \(list.count) firmwares that report \(text)") }
        var fam = firmwares.filter { f in
            guard let ident = f.ident, let re = try? NSRegularExpression(pattern: "^(?:" + ident + ")$") else { return false }
            return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        if fam.count > 1 { fam = fam.filter { $0.ident != Firmware.anyIdentity } }
        if fam.count == 1 { return WhoIs(firmware: fam[0], exact: false, name: fam[0].name) }
        return WhoIs(firmware: nil, exact: false, name: "another firmware (\(text))")
    }

    /// The firmwares whose makers may have released the version an FM-1 reports: the family the identity pattern names,
    /// and those whose own number has the same length and leading digit (Skiff 1.4 is FM-1_714, Skiff 2.0.1 FM-1_720).
    /// Nearest number first.
    func familyCandidates(for text: String) -> [Firmware] {
        guard let id = FM1Identity.parse(text: text), let us = text.lastIndex(of: "_") else { return [] }
        let digits = text[text.index(after: us)...]
        var out: [Firmware] = []
        for f in firmwares where !f.repo.isNilOrEmpty {
            let own = f.productDigits
            var hit = false
            if let ident = f.ident, ident != Firmware.anyIdentity, let re = try? NSRegularExpression(pattern: "^(?:" + ident + ")$"),
               re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { hit = true }
            if own.count == digits.count, own.first == digits.first { hit = true }
            if hit && !out.contains(where: { $0.repo == f.repo }) { out.append(f) }
        }
        return out.sorted { abs((Int($0.productDigits) ?? 0) - id.version) < abs((Int($1.productDigits) ?? 0) - id.version) }
    }
}

extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
