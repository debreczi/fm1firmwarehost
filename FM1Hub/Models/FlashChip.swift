import Foundation

/// The FM-1's flash chips the app knows, by the JEDEC ID the chip answers with. FM-1s sold since autumn 2026 have a
/// newer chip; a firmware written before it can't save or start another update on it, so the FM-1 is stuck on that
/// firmware ("bricked") until it is rescued from a computer. The README and the app's Flash chips page list the same
/// IDs: change all three together.
enum FlashChip {
    /// Puya P25Q80: the first FM-1s.
    static let first: UInt32 = 0x85_6014
    /// UCUN UC25HQ80: FM-1s sold since autumn 2026, usually with the M-VAVE logo under the screen.
    static let newer: UInt32 = 0xB3_6014

    struct Known: Identifiable, Hashable {
        let id: UInt32
        let part: String
        let units: String
    }

    static let known: [Known] = [
        Known(id: first, part: "Puya P25Q80", units: "The first FM-1s."),
        Known(id: newer, part: "UCUN UC25HQ80", units: "FM-1s sold since autumn 2026, usually with the M-VAVE logo under the screen."),
    ]

    /// "0xB36014".
    static func hex(_ id: UInt32) -> String { String(format: "0x%06X", id) }
}

/// Which chips a package works on, as the hub's catalogue says (its `chip` field, which the hub reads from each
/// package), or as the app knows of M-VAVE's own firmware.
enum ChipSupport: String, Codable, Hashable {
    /// "Every FM-1, the newer chip too."
    case new
    /// Does not check the chip.
    case any
    /// "The first FM-1s only."
    case old
    /// M-VAVE's own firmware: newer FM-1s ship with it.
    case official
    /// Not in the catalogue (an older version, a file), or the catalogue says nothing.
    case unknown

    /// The catalogue's value; anything the app doesn't know is unknown.
    init(catalogValue: String?) {
        switch catalogValue?.lowercased() {
        case "new": self = .new
        case "any": self = .any
        case "old": self = .old
        default: self = .unknown
        }
    }
}

/// What the FM-1 said about its flash chip. Only some firmwares say it (in their answer to the full identity
/// request); M-VAVE's own never does.
enum DeviceFlash: Equatable, Hashable {
    case notReported
    case reported(UInt32)

    init(_ id: UInt32?) { self = id.map { .reported($0) } ?? .notReported }

    var id: UInt32? {
        if case .reported(let id) = self { return id }
        return nil
    }

    /// For the FM-1 screen.
    var summary: String {
        switch self {
        case .notReported: return "not reported by this firmware"
        case .reported(let id) where id == FlashChip.first: return "first FM-1s (\(FlashChip.hex(id)))"
        case .reported(let id) where id == FlashChip.newer: return "newer FM-1s (\(FlashChip.hex(id)))"
        case .reported(let id): return "not known to the app (\(FlashChip.hex(id)))"
        }
    }
}

/// Why an install gets the red warning.
enum ChipWarning: Equatable, Hashable {
    /// The FM-1 did not report its chip, and the firmware is for the first FM-1s only.
    case oldPackage
    /// The FM-1 did not report its chip, and the app can't tell what the firmware supports.
    case unknownPackage
    /// The FM-1 reported the newer chip, and the app can't tell what the firmware supports.
    case newerChipUnknownPackage
    /// The FM-1 reported a chip the app doesn't know, and the firmware is not known to work on any chip.
    case unknownChip(UInt32)
}

/// What happens when an install is asked for.
enum ChipVerdict: Equatable, Hashable {
    case install
    case warn(ChipWarning)
    /// The FM-1 reported a chip this firmware doesn't support, and unsafe installs are allowed: asked as dangerous.
    case dangerous(UInt32)
    /// The same, with unsafe installs not allowed.
    case refused(UInt32)
}

/// The decision table. The README and the Flash chips page describe it; the tests pin every cell.
enum ChipGuard {
    static func verdict(device: DeviceFlash, package: ChipSupport, allowUnsafe: Bool) -> ChipVerdict {
        let unsafe: (UInt32) -> ChipVerdict = { allowUnsafe ? .dangerous($0) : .refused($0) }
        switch device {
        case .reported(let id) where id == FlashChip.first:
            return .install
        case .reported(let id) where id == FlashChip.newer:
            switch package {
            case .new, .any, .official: return .install
            case .old: return unsafe(id)
            case .unknown: return .warn(.newerChipUnknownPackage)
            }
        case .reported(let id):
            // a third chip: a first-FM-1 firmware accepts only the first chip, a newer-chip one only the two known
            switch package {
            case .any: return .install
            case .old: return unsafe(id)
            case .new, .official, .unknown: return .warn(.unknownChip(id))
            }
        case .notReported:
            switch package {
            case .new, .any, .official: return .install
            case .old: return .warn(.oldPackage)
            case .unknown: return .warn(.unknownPackage)
            }
        }
    }

    /// Does what the user agreed to cover what the check says now, at the point of no return? A warning agreed to
    /// covers any warning (each says the firmware may brick a newer FM-1); a dangerous install only the one agreed to
    /// for that chip; a refusal is never covered.
    static func allows(_ now: ChipVerdict, consent: ChipVerdict) -> Bool {
        switch now {
        case .install: return true
        case .refused: return false
        case .warn:
            switch consent {
            case .warn, .dangerous: return true
            case .install, .refused: return false
            }
        case .dangerous(let id): return consent == .dangerous(id)
        }
    }

    /// "the newer flash chip", "a flash chip the app doesn't know (0x123456)".
    static func chipPhrase(_ id: UInt32) -> String {
        id == FlashChip.newer ? "the newer flash chip" : "a flash chip the app doesn't know (\(FlashChip.hex(id)))"
    }

    static func heading(_ v: ChipVerdict) -> String {
        switch v {
        case .install: return ""
        case .warn(.oldPackage): return "Unsafe for newer FM-1s"
        case .warn(.unknownPackage): return "Not known to be safe for newer FM-1s"
        case .warn(.newerChipUnknownPackage): return "Your FM-1 is a newer one"
        case .warn(.unknownChip): return "Unknown flash chip"
        case .dangerous: return "This is dangerous"
        case .refused: return "Not installed"
        }
    }

    static func text(_ v: ChipVerdict) -> String {
        switch v {
        case .install:
            return ""
        case .warn(.oldPackage):
            return "If your FM-1 has the M-VAVE logo under the screen, it is a newer one, and this firmware may brick it."
        case .warn(.unknownPackage):
            return "The app can't tell whether this firmware is safe for newer FM-1s. If your FM-1 has the M-VAVE logo under the screen, it is a newer one, and an unsafe firmware may brick it."
        case .warn(.newerChipUnknownPackage):
            return "Your FM-1 reports the newer flash chip, and the app can't tell whether this firmware supports it. If it doesn't, it may brick your FM-1."
        case .warn(.unknownChip(let id)):
            return "Your FM-1 reports \(chipPhrase(id)). The app can't tell whether this firmware supports it. If it doesn't, it may brick your FM-1."
        case .dangerous(let id):
            return "Your FM-1 has \(chipPhrase(id)), and this firmware is made for the first FM-1s only: it may brick your FM-1. You allowed unsafe installs in Settings, but this is still considered dangerous. Do you want to install it?"
        case .refused(let id):
            return "Your FM-1 has \(chipPhrase(id)), and this firmware is made for the first FM-1s only: it may brick your FM-1. Nothing was installed. To install it anyway, turn on Settings › Allow installing on unsafe FM-1s."
        }
    }

    /// Why an install stopped at the point of no return: the FM-1 reported its chip only then, and what the user agreed
    /// to does not cover it.
    static func stopText(_ now: ChipVerdict) -> String {
        switch now {
        case .refused: return text(now)
        case .dangerous(let id):
            return "Your FM-1 reported \(chipPhrase(id)) just now, and this firmware is made for the first FM-1s only: it may brick your FM-1. Nothing was installed. Press Install again to decide."
        case .warn:
            return text(now) + " Nothing was installed. Press Install again to decide."
        case .install: return ""
        }
    }
}
