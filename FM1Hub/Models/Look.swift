import SwiftUI

/// Each firmware's colour, as the hub paints its card; a stable colour from the id for the rest.
enum Look {
    static let colours: [String: String] = [
        "dinghy": "#8f62f0", "felucca": "#afd9f4", "sloop": "#e6d1b9", "sloopdx": "#42f5f5", "zp12": "#ff6a3d", "x0x": "#f4c0cb", "x0xrmx": "#c9a6e8", "fomni": "#c9b6ff",
        "salt": "#ff8f7a", "choralroot": "#ffc46b", "jangada": "#ff5fc8", "melodee": "#8fe3b0", "hortator": "#d8dde6", "fimba": "#f0a35e", "ghoulbox": "#ffb000", "jiant": "#ff7a00", "bubba": "#ffc83d", "floyd": "#ffb347", "sloopbanks": "#7fd4ff", "waveloop": "#b58cff",
        "chord": "#f2564e", "fumi": "#b08a5a", "maku": "#f0806a", "rainbow": "#ffd23f", "obervave": "#3c82eb", "shineon": "#f5a524",
        "pigeon": "#b49cff", "cs1": "#f2a93b", "hyp1": "#a35cff", "tonitor": "#00d6ff", "noizdemons": "#7dff3c", "coralflower": "#ff7aa8",
        "mc1": "#ff8a1e", "beetle": "#ff3ad0", "min1": "#3f7be0", "purplemonkey": "#9b5cff", "gammawave": "#ffb800", "tuna": "#3db7e4",
        "frodhes": "#e8a33d", "fomajam": "#a3e635", "kawa": "#d9579c", "nmsfm": "#00a632", "fm1quest": "#f2c373", "grimm": "#cd3018", "fmini": "#e0a458", "chipbox": "#f5a03a", "clipper": "#3d8bf2", "loom": "#e3b23c", "monk": "#e0603a", "flyfish": "#3fa9f5", "bytemania": "#ff4f8b", "mutable": "#f0875a", "dub": "#3fb6a8", "ketch": "#f2c94c", "fmel": "#c98a5a", "zen": "#f4a6c0", "golana": "#f5a54a", "golanadz": "#e8873a", "modelar": "#ff3d9a", "niagara": "#6fb7e8", "unholy": "#c0392b", "emb": "#b5651d",
        "cutador": "#f0a030", "hera": "#1ea7f2", "frasil": "#5cc8f5", "tessera": "#ecb848", "drift": "#e6e6e6", "delrio": "#e5733a", "carnac": "#d6963c", "sidou": "#a77bff", "mono2k": "#f2f1ec", "caravel": "#f7a21b", "midimon": "#39ba62", "makohai": "#5ad1e0", "estampie": "#c4452e", "fizz": "#4a9dff", "fm1gm": "#4aa3df", "386dx": "#f5d63a", "opn1": "#e8303a", "sid1": "#8f7fe0", "minitone": "#22b8a5", "fm1sid": "#6c8cd5", "morpheus": "#3ccf6e", "bunker": "#9d7be8",
        "amb": "#f6d79a", "ctl": "#ef4a33", "winampfm": "#5b7bff", "mycelium": "#9ccce4", "polly": "#7b93e0", "etch": "#cfcfcf", "fm106": "#2a9fd6",
        "tribe": "#fc6c54", "duell": "#e6e6e6", "skiff": "#fcb424", "fart": "#84cc9c", "orbit": "#4f7ff0", "felucca8": "#afd9f4",
    ]
    /// Cards whose picture is a landscape, not a square screen.
    static let wide: Set<String> = ["felucca", "salt", "melodee", "ghoulbox", "waveloop", "duell", "felucca8", "obervave", "fm1sid", "fm1gm", "niagara", "kawa", "coralflower"]

    static func colour(for id: String) -> Color {
        if let hex = colours[id] { return Color(hex: hex) }
        var h: UInt32 = 2166136261
        for b in id.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Color(hue: Double(h % 360) / 360, saturation: 0.55, brightness: 0.9)
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b: Double
        if s.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255
        } else {
            r = 0.5; g = 0.5; b = 0.5
        }
        self.init(red: r, green: g, blue: b)
    }
}
