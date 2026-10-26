import Foundation

/// One firmware of the hub's catalogue (catalog.json "firmwares").
struct Firmware: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let author: String
    let version: String
    let what: String
    let kinds: [String]
    let ambient: Bool
    let vintage: Bool
    let beta: Bool
    let pkg: String
    let product: String
    let size: Int
    let sha256: String
    let ident: String?
    let repo: String?
    let site: String?
    let source: String?
    let release: String?
    let editor: String?
    let play: String?
    let cheat: String?
    let talk: String?
    let install: String?
    let loader: String?
    let lic: String?
    let tag: String?
    let date: String?
    let added: String?
    let published: String?
    let stars: Int?
    let installs: Int?
    let hid: HID?

    struct HID: Codable, Hashable {
        let keyboard: Bool?
        let mouse: Bool?
        var kinds: [String] { [(keyboard == true ? "keyboard" : nil), (mouse == true ? "mouse" : nil)].compactMap { $0 } }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, author, version, what, kind, ambient, vintage, beta, pkg, product, size, sha256, ident, repo, site, source,
             release, editor, play, cheat, talk, install, loader, lic, tag, date, added, published, stars, installs, hid
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        what = try c.decodeIfPresent(String.self, forKey: .what) ?? ""
        if let one = try? c.decode(String.self, forKey: .kind) { kinds = [one] }
        else { kinds = (try? c.decode([String].self, forKey: .kind)) ?? ["other"] }
        ambient = (try? c.decode(Bool.self, forKey: .ambient)) ?? false
        vintage = (try? c.decode(Bool.self, forKey: .vintage)) ?? false
        beta = (try? c.decode(Bool.self, forKey: .beta)) ?? false
        pkg = try c.decodeIfPresent(String.self, forKey: .pkg) ?? ""
        product = try c.decodeIfPresent(String.self, forKey: .product) ?? ""
        size = (try? c.decode(Int.self, forKey: .size)) ?? 0
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        ident = try? c.decodeIfPresent(String.self, forKey: .ident)
        repo = try? c.decodeIfPresent(String.self, forKey: .repo)
        site = try? c.decodeIfPresent(String.self, forKey: .site)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        release = try? c.decodeIfPresent(String.self, forKey: .release)
        editor = try? c.decodeIfPresent(String.self, forKey: .editor)
        play = try? c.decodeIfPresent(String.self, forKey: .play)
        cheat = try? c.decodeIfPresent(String.self, forKey: .cheat)
        talk = try? c.decodeIfPresent(String.self, forKey: .talk)
        install = try? c.decodeIfPresent(String.self, forKey: .install)
        loader = try? c.decodeIfPresent(String.self, forKey: .loader)
        lic = try? c.decodeIfPresent(String.self, forKey: .lic)
        tag = try? c.decodeIfPresent(String.self, forKey: .tag)
        date = try? c.decodeIfPresent(String.self, forKey: .date)
        added = try? c.decodeIfPresent(String.self, forKey: .added)
        published = try? c.decodeIfPresent(String.self, forKey: .published)
        stars = try? c.decodeIfPresent(Int.self, forKey: .stars)
        installs = try? c.decodeIfPresent(Int.self, forKey: .installs)
        hid = try? c.decodeIfPresent(HID.self, forKey: .hid)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(author, forKey: .author)
        try c.encode(version, forKey: .version); try c.encode(what, forKey: .what); try c.encode(kinds, forKey: .kind)
        try c.encode(ambient, forKey: .ambient); try c.encode(vintage, forKey: .vintage); try c.encode(beta, forKey: .beta)
        try c.encode(pkg, forKey: .pkg); try c.encode(product, forKey: .product); try c.encode(size, forKey: .size)
        try c.encode(sha256, forKey: .sha256)
        try c.encodeIfPresent(ident, forKey: .ident); try c.encodeIfPresent(repo, forKey: .repo); try c.encodeIfPresent(site, forKey: .site)
        try c.encodeIfPresent(source, forKey: .source); try c.encodeIfPresent(release, forKey: .release); try c.encodeIfPresent(editor, forKey: .editor)
        try c.encodeIfPresent(play, forKey: .play); try c.encodeIfPresent(cheat, forKey: .cheat); try c.encodeIfPresent(talk, forKey: .talk)
        try c.encodeIfPresent(install, forKey: .install); try c.encodeIfPresent(loader, forKey: .loader); try c.encodeIfPresent(lic, forKey: .lic)
        try c.encodeIfPresent(tag, forKey: .tag); try c.encodeIfPresent(date, forKey: .date); try c.encodeIfPresent(added, forKey: .added)
        try c.encodeIfPresent(published, forKey: .published); try c.encodeIfPresent(stars, forKey: .stars); try c.encodeIfPresent(installs, forKey: .installs)
        try c.encodeIfPresent(hid, forKey: .hid)
    }

    /// The kinds a filter can tick: the type(s), plus "ambient" and "vintage" when they hold.
    var allKinds: [String] { kinds + (ambient ? ["ambient"] : []) + (vintage ? ["vintage"] : []) }
    var isDevOnly: Bool { allKinds == ["dev"] }
    /// Installed by its own installer, not by the hub's protocol (the package alone is not all of it).
    var needsOwnInstaller: Bool { install != nil && !(install ?? "").isEmpty }
    /// Written by M-VAVE's own loader (a firmware built on the official V15).
    var usesStockLoader: Bool { loader == "mvave" }
    var packageURL: URL { HubAPI.url(pkg) }
    var imageURL: URL { HubAPI.url("img/\(id).png") }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
    var licenseText: String { lic ?? "GPL-3.0" }
    var searchText: String { [name, author, what, version, kinds.joined(separator: " "), product].joined(separator: " ").lowercased() }
}

/// M-VAVE's official V15 as the hub serves it (catalog.json "stock").
struct StockFirmware: Codable, Hashable {
    let pkg: String
    let sha256: String
    let size: Int
    let product: String
    let license: String?
    let notice: String?
    let terms: String?
    let source: String?
    var packageURL: URL { HubAPI.url(pkg) }
}

struct Creator: Codable, Hashable {
    let login: String?
    let avatar: String?
    let youtube: String?
}

struct Catalog: Codable {
    let updated: String?
    let firmwares: [Firmware]
    let stock: StockFirmware?
    let creators: [String: Creator]?
}

enum HubAPI {
    static let base = URL(string: "https://thefirmwarehub.com/")!
    static let catalog = URL(string: "https://thefirmwarehub.com/catalog.json")!
    static let site = URL(string: "https://thefirmwarehub.com/")!
    static let knowledgeBase = URL(string: "https://thefirmwarehub.com/kb/")!
    static let creatorsPage = URL(string: "https://thefirmwarehub.com/creators/")!
    static let submit = URL(string: "https://thefirmwarehub.com/submit/")!
    static let stockDownload = URL(string: "https://www.m-vave.com/download")!

    static func url(_ path: String) -> URL {
        if let u = URL(string: path), u.scheme != nil { return u }
        let p = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: p, relativeTo: base)?.absoluteURL ?? base
    }
}

/// The filter groups, as the hub lays them out.
struct KindGroup: Identifiable {
    let id: String
    let title: String
    let anyMatch: Bool
    let kinds: [(key: String, label: String)]
}

enum Kinds {
    static let groups: [KindGroup] = [
        KindGroup(id: "type", title: "Type", anyMatch: true, kinds: [
            ("synth", "Synths"), ("groove", "Grooveboxes"), ("drums", "Drums & samplers"), ("chords", "Chords"),
            ("tracker", "Trackers"), ("dev", "For devs"), ("other", "Other")]),
        KindGroup(id: "style", title: "Style", anyMatch: true, kinds: [("ambient", "Ambient & drone"), ("vintage", "Vintage")]),
    ]
    static let labels: [String: String] = ["synth": "synth", "groove": "groovebox", "drums": "drums · sampler", "chords": "chords",
                                           "tracker": "tracker", "dev": "for developers", "other": "other", "ambient": "ambient · drone", "vintage": "vintage"]
    static let icons: [String: String] = ["synth": "pianokeys", "groove": "square.grid.3x3.fill", "drums": "circle.grid.2x2.fill", "chords": "music.note.list",
                                          "tracker": "list.number", "dev": "chevron.left.forwardslash.chevron.right", "other": "sparkles", "ambient": "cloud.fill", "vintage": "hourglass"]
    static func label(_ k: String) -> String { labels[k] ?? k }
    static func icon(_ k: String) -> String { icons[k] ?? "tag" }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case installs, newest, added, name, stars
    var id: String { rawValue }
    var label: String {
        switch self {
        case .installs: return "Most installed"
        case .newest: return "Newest release"
        case .added: return "Recently added"
        case .name: return "Name"
        case .stars: return "GitHub stars"
        }
    }
}
