// SPDX-License-Identifier: GPL-3.0-only
// Ported from the FM-1 Firmware Hub installer and the Felucca web editor
// (Copyright (C) 2026 Leo Kuroshita (@kurogedelic), Hügelton Instruments).
//
// 7-bit packings used over SysEx, and the CRC-32 the Felucca archives carry.

import Foundation

enum SevenBit {
    /// Bit-stream packing used by the FM-1 update protocol (M-UPGRADE compatible):
    /// 8-bit bytes are shifted into a stream and emitted 7 bits at a time, LSB first.
    static func pack7(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count * 8 / 7 + 2)
        var acc: UInt32 = 0
        var nb = 0
        for b in data {
            acc |= UInt32(b) << UInt32(nb)
            nb += 8
            while nb >= 7 {
                out.append(UInt8(acc & 0x7F))
                acc >>= 7
                nb -= 7
            }
        }
        if nb > 0 { out.append(UInt8(acc & 0x7F)) }
        return out
    }

    static func unpack7(_ s: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.count * 7 / 8 + 1)
        var acc: UInt32 = 0
        var nb = 0
        for b in s {
            acc |= UInt32(b & 0x7F) << UInt32(nb)
            nb += 7
            while nb >= 8 {
                out.append(UInt8(acc & 0xFF))
                acc >>= 8
                nb -= 8
            }
        }
        return out
    }

    /// Block packing used by the Felucca editor protocol: groups of 7 bytes, a mask byte
    /// carrying the high bits first, then the 7 low parts.
    static func blockPack(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + bytes.count / 7 + 1)
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let end = min(i + 7, bytes.endIndex)
            var mask: UInt8 = 0
            var j = 0
            for k in i..<end {
                mask |= (bytes[k] >> 7) << UInt8(j)
                j += 1
            }
            out.append(mask)
            for k in i..<end { out.append(bytes[k] & 0x7F) }
            i = end
        }
        return out
    }

    static func blockUnpack(_ a: ArraySlice<UInt8>, size: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size)
        var i = a.startIndex
        var j = 0
        while j < size {
            let n = min(7, size - j)
            guard i < a.endIndex else { throw FM1Error.protocolError("Invalid archive bytes") }
            let mask = a[i]; i += 1
            if (Int(mask) >> n) != 0 { throw FM1Error.protocolError("Invalid archive bytes") }
            for k in 0..<n {
                guard i < a.endIndex, a[i] <= 127 else { throw FM1Error.protocolError("Short archive chunk") }
                out[j] = a[i] | (((mask >> UInt8(k)) & 1) << 7)
                i += 1; j += 1
            }
        }
        if i != a.endIndex { throw FM1Error.protocolError("Trailing archive bytes") }
        return out
    }

    /// A 32-bit number as five 7-bit bytes, LSB first (the top byte holds 4 bits).
    static func u32(_ n: UInt32) -> [UInt8] {
        return (0..<5).map { i in UInt8((n >> UInt32(i * 7)) & (i == 4 ? 15 : 127)) }
    }

    static func r32(_ a: [UInt8], _ off: Int) throws -> UInt32 {
        guard a.count >= off + 5, a[off + 4] <= 15 else { throw FM1Error.protocolError("Invalid archive number") }
        return UInt32(a[off]) | UInt32(a[off + 1]) << 7 | UInt32(a[off + 2]) << 14 | UInt32(a[off + 3]) << 21 | UInt32(a[off + 4]) << 28
    }

    /// Standard CRC-32 (IEEE 802.3, reflected, 0xEDB88320).
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            c ^= UInt32(b)
            for _ in 0..<8 { c = (c >> 1) ^ ((c & 1) != 0 ? 0xEDB8_8320 : 0) }
        }
        return ~c
    }
}

/// Errors the device layer reports. `code` mirrors the hub's installer codes so the UI can give the same hints.
enum FM1Error: LocalizedError {
    case notFound(String)
    case model(String)
    case stopped(String)
    case lost(String)
    case noLoader(String)
    case noReturn(String)
    case mismatch(String)
    case badRequest(String)
    case foreign(String)
    case package(String)
    case protocolError(String)
    case midi(String)
    case backup(String)
    case cancelled

    var code: String {
        switch self {
        case .notFound: return "notfound"
        case .model: return "model"
        case .stopped: return "stopped"
        case .lost: return "lost"
        case .noLoader: return "noloader"
        case .noReturn: return "noreturn"
        case .mismatch: return "mismatch"
        case .badRequest: return "badreq"
        case .foreign: return "foreign"
        case .package: return "package"
        case .protocolError: return "protocol"
        case .midi: return "midi"
        case .backup: return "backup"
        case .cancelled: return "cancelled"
        }
    }

    var errorDescription: String? {
        switch self {
        case .notFound(let s), .model(let s), .stopped(let s), .lost(let s), .noLoader(let s), .noReturn(let s),
             .mismatch(let s), .badRequest(let s), .foreign(let s), .package(let s), .protocolError(let s), .midi(let s), .backup(let s):
            return s
        case .cancelled: return "Cancelled."
        }
    }

    /// True only for the failures the device layer raises before a single byte has gone to the device: no FM-1
    /// answered, it is another model, or it is in another firmware's loader. Everything else is either raised
    /// mid-write or cannot be told apart from one, so it counts as "the device may have been touched".
    var nothingWritten: Bool {
        switch self {
        case .notFound, .model, .foreign, .package, .midi, .backup: return true
        case .stopped, .lost, .noLoader, .noReturn, .mismatch, .badRequest, .protocolError, .cancelled: return false
        }
    }

    /// What to do next, as the hub says it.
    var hint: String {
        switch self {
        case .notFound: return "Plug the FM-1 in by USB, close other MIDI apps, then try again."
        case .noLoader: return "Still stuck? Hold OCT− while switching the FM-1 on, then press Install again."
        case .lost, .stopped: return "Replug the USB cable and press Install again: the device stays in update mode until it is finished."
        case .noReturn: return "Power-cycle the FM-1. If it does not start, hold OCT− while switching it on and install again."
        case .cancelled, .package, .model, .mismatch, .badRequest, .foreign, .protocolError, .midi, .backup: return ""
        }
    }
}
