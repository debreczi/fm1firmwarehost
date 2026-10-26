import Foundation
import Observation

/// Who a device identity belongs to, as the hub works it out.
struct WhoIs {
    let firmware: Firmware?
    let exact: Bool
    let name: String
    var isStock: Bool { firmware == nil && name.contains("official") }
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
    private func apply(_ data: Data) -> Bool {
        guard let cat = try? JSONDecoder().decode(Catalog.self, from: data) else { return false }
        firmwares = cat.firmwares.filter { !$0.pkg.isEmpty && !$0.product.isEmpty }
        stock = cat.stock
        creators = cat.creators ?? [:]
        updated = cat.updated
        return true
    }

    /// The firmware behind an identity string, as the hub's whoIs(): an exact product match names one, a family
    /// range (the "ident" pattern) names one when only one matches.
    func whoIs(_ text: String?) -> WhoIs? {
        guard let text = text, !text.isEmpty else { return nil }
        if text == "FM-1_015" { return WhoIs(firmware: nil, exact: true, name: "the official firmware (V15)") }
        if text == "FM-1_016" { return WhoIs(firmware: nil, exact: true, name: "the official firmware (V16)") }
        if text == "FM-1_000" { return WhoIs(firmware: nil, exact: true, name: "the USB rescue mode (FM-1_000)") }
        if text.lowercased().hasPrefix("ota-") { return WhoIs(firmware: nil, exact: true, name: "the update loader (\(text))") }
        let exact = firmwares.filter { $0.product == text }
        if exact.count == 1 { return WhoIs(firmware: exact[0], exact: true, name: exact[0].name) }
        if exact.count == 2 { return WhoIs(firmware: nil, exact: false, name: exact.map(\.name).joined(separator: " or ")) }
        if exact.count > 2 { return WhoIs(firmware: nil, exact: false, name: "one of \(exact.count) firmwares that report \(text)") }
        var fam = firmwares.filter { f in
            guard let ident = f.ident, let re = try? NSRegularExpression(pattern: "^(?:" + ident + ")$") else { return false }
            return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        if fam.count > 1 { fam = fam.filter { $0.ident != "FM-1_\\d{3,8}" } }
        if fam.count == 1 { return WhoIs(firmware: fam[0], exact: false, name: fam[0].name) }
        return WhoIs(firmware: nil, exact: false, name: "another firmware (\(text))")
    }
}
