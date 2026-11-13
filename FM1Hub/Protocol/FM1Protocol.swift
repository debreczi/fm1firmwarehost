// SPDX-License-Identifier: GPL-3.0-only
// Ported from the FM-1 Firmware Hub (Copyright (C) 2026 Leo Kuroshita (@kurogedelic), Hügelton Instruments).
//
// The FM-1 USB-MIDI update protocol (M-UPGRADE compatible). Step 1: the running firmware reads parts of
// the package and stages the update loader. Step 2: the loader reads the whole image and writes it. In both
// steps the device sends cmd 0x30 read requests on the logical image and the host answers.

import Foundation

/// What an FM-1 answers to the identity request: "FM-1_900", "ota-FM-1_916" (the update loader), "FM-1_015" (stock V15).
struct FM1Identity: Equatable, Hashable, Codable {
    let text: String
    let model: String
    let version: Int

    var isLoader: Bool { model.lowercased().hasPrefix("ota-") }
    /// The update loader of SLOOP / Felucca packages ("ota-FM-1_9XX"). A device left in the update mode of another
    /// firmware (the stock updater's loader) is never written: its loader may lay the image out differently.
    var isHubLoader: Bool {
        let t = text.lowercased()
        guard t.hasPrefix("ota-fm-1_"), t.count == 12 else { return false }
        let digits = t.suffix(3)
        return digits.first == "9" && digits.allSatisfy { $0.isNumber }
    }
    var modelWithoutLoader: String {
        model.lowercased().hasPrefix("ota-") ? String(model.dropFirst(4)) : model
    }

    static func parse(text: String) -> FM1Identity? {
        guard let us = text.lastIndex(of: "_") else { return nil }
        let model = String(text[..<us])
        let digits = String(text[text.index(after: us)...])
        guard !model.isEmpty, !digits.isEmpty, digits.allSatisfy({ $0.isNumber }), !model.contains("_") else { return nil }
        return FM1Identity(text: text, model: model, version: Int(digits) ?? Int(digits.prefix(9)) ?? 0)
    }

    /// The name, "_" and exactly three digits: what M-UPGRADE 3.11 takes, and what firmwares built on felucca-bsp answer
    /// the plain query with when their own identity is longer ("FM-1_6010000" -> "FM-1_601").
    var isThreeDigits: Bool {
        guard let us = text.lastIndex(of: "_") else { return false }
        return text[text.index(after: us)...].count == 3
    }

    /// Does a device's answer name the firmware a package carries? The same text, or the three-digit form of the
    /// package's identity, which a firmware answers the plain request with. Only that way round: an answer longer than
    /// the package's identity is another firmware.
    static func answers(_ observed: String, for expected: String) -> Bool {
        observed == expected || (observed.count < expected.count && same(observed, expected))
    }

    /// Do two identities name the same firmware? The same text, or one is the three-digit form of the other, which a
    /// firmware answers when it does not answer the full identity request.
    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        guard let s = parse(text: short), s.isThreeDigits, let l = parse(text: long), l.model == s.model, !s.isLoader,
              long.hasPrefix(short) else { return false }
        return true
    }
}

/// What an FM-1 answered to the identity request: its identity, and its flash chip's JEDEC ID when it sends one.
struct FM1Hello: Equatable {
    let identity: FM1Identity
    let flashID: UInt32?
}

/// A cmd 0x30 read request from the device.
struct FM1ReadRequest {
    let flags: UInt8
    let address: UInt32
    let length: Int
}

enum FM1Protocol {
    /// The identity request, as M-UPGRADE sends it: cmd 0x11 with no body.
    static let handshakeQuery: [UInt8] = [0xF0, 0x00, 0x32, 0x45, 0x00, 0x00, 0x00, 0x40, 0x7F, 0xF7]
    /// The full identity request: cmd 0x11 with the one-byte body 01 (PERF-1's scheme, in felucca-bsp and ESTAMPIE).
    /// Firmwares that know it answer with their whole identity, and some with their flash chip's JEDEC ID in bytes
    /// 24-26. Never sent to M-VAVE's firmware or to an update loader.
    static let fullHandshakeQuery: [UInt8] = [0xF0, 0x00, 0x32, 0x45, 0x08, 0x00, 0x00, 0x40, 0x00, 0x7E, 0x01, 0xF7]
    static let upgrade: [UInt8] = [0xF0, 0x22, 0x24, 0x35, 0x7F, 0xF7]
    /// The ROM bootloader key: after it, the FM-1 shows up as a USB disk "UBOOT1.00" and needs a computer to recover.
    static let bootloaderKey: [UInt8] = [0xF0, 0x22, 0x24, 0x35, 0x7D, 0xF7]
    static let maxData = 512
    static let finishStep1: UInt32 = 0xE000_0000
    static let finishStep2: UInt32 = 0xF000_0000
    /// The reads of a package: step 1, step 2 (as the installers count them), for the progress bar.
    static let step1Reads = 74
    static let step2Reads = 1179

    /// The MIDI ports the installer may probe (never other gear): the FM-1 under SLOOP / Felucca ("Felucca"), under
    /// CLIPPER ("Clipper"), under a firmware named after itself, the update loaders, and the names the stock firmware uses.
    static let portPattern = try! NSRegularExpression(pattern: "fm-1|felucca|sloop|clipper|etch|jiant|ota|update|composite|sinco|usb-midi|m-vave|mvave", options: [.caseInsensitive])

    static func mayProbe(_ name: String) -> Bool {
        let r = NSRange(name.startIndex..., in: name)
        return portPattern.firstMatch(in: name, options: [], range: r) != nil
    }

    static func parseIdentity(_ pkt: [UInt8]) -> FM1Identity? { parseHello(pkt)?.identity }

    /// The identity reply: 27 bytes, the text up to its first zero, then zeros, and in bytes 24-26 (high byte first) the
    /// flash's JEDEC ID when the firmware sends it (0: not sent). Binary can follow the text, so it ends at its first
    /// zero, as felucca-bsp tells hosts to read it. The chip ID counts only from a reply whose length and checksum hold,
    /// as a read request's must; the identity stands without them, as it always has.
    static func parseHello(_ pkt: [UInt8]) -> FM1Hello? {
        guard pkt.count > 2, pkt.first == 0xF0, pkt.last == 0xF7 else { return nil }
        let d = SevenBit.unpack7(pkt[1..<(pkt.count - 1)])
        guard d.count == 34, d[0] == 0, d[1] == 0x59, d[2] == 0x11 else { return nil }
        let body = Array(d[6..<33])
        let end = body.firstIndex(of: 0) ?? body.count
        guard let id = FM1Identity.parse(text: String(decoding: body[..<end], as: UTF8.self)) else { return nil }
        let sum = body.reduce(0) { $0 + Int($1) }
        let intact = d[3] == 27 && d[4] == 0 && d[5] == 0 && UInt8(truncatingIfNeeded: ~sum) == d[33]
        // only where the text has ended before them can those bytes be the chip's
        let jedec = intact && end < 24 ? UInt32(body[24]) << 16 | UInt32(body[25]) << 8 | UInt32(body[26]) : 0
        return FM1Hello(identity: id, flashID: jedec == 0 ? nil : jedec)
    }

    /// Is the full identity request worth sending to a device that answered the plain one with this? Not to M-VAVE's
    /// firmware (FM-1_0xx), the USB rescue mode or an update loader: they don't know it, and the stock firmware is not
    /// sent anything it doesn't know.
    static func asksFullIdentity(after plain: FM1Identity) -> Bool {
        !plain.isLoader && !FWSCPackage.isOfficialProduct(plain.text) && plain.text != "FM-1_000"
    }

    /// The device's answer: the full reply when it gave one that belongs to the plain one (the same text, or the whole
    /// identity whose three-digit form the plain answer was), the plain reply otherwise. A chip ID in either counts, but
    /// one in a reply that does not belong only when it is not the first FM-1s' chip: it may warn, never hide a warning.
    static func merge(plain: FM1Hello, full: FM1Hello?) -> FM1Hello {
        guard let full else { return plain }
        guard full.identity.model == plain.identity.model,
              full.identity.text == plain.identity.text || (plain.identity.isThreeDigits && FM1Identity.same(full.identity.text, plain.identity.text))
        else { return FM1Hello(identity: plain.identity, flashID: plain.flashID ?? full.flashID.flatMap { $0 == FlashChip.first ? nil : $0 }) }
        return FM1Hello(identity: full.identity, flashID: full.flashID ?? plain.flashID)
    }

    static func parseRequest(_ pkt: [UInt8]) -> FM1ReadRequest? {
        guard pkt.count > 2, pkt.first == 0xF0, pkt.last == 0xF7 else { return nil }
        let u = SevenBit.unpack7(pkt[1..<(pkt.count - 1)])
        guard u.count == 15, u[0] == 0, u[1] == 0x59, u[2] == 0x30 else { return nil }
        var s: Int = 0
        for i in 6..<14 { s += Int(u[i]) }
        guard UInt8(truncatingIfNeeded: ~s) == u[14] else { return nil }
        let addr = UInt32(u[7]) | UInt32(u[8]) << 8 | UInt32(u[9]) << 16 | UInt32(u[10]) << 24
        let len = Int(u[11]) | Int(u[12]) << 8 | Int(u[13]) << 16
        return FM1ReadRequest(flags: u[6], address: addr, length: len)
    }

    static func response(address: UInt32, data: [UInt8], flags: UInt8 = 0) -> [UInt8] {
        let len = data.count
        var body: [UInt8] = [0x00, 0x59, 0x30, UInt8((len + 8) & 0xFF), UInt8(((len + 8) >> 8) & 0xFF), 0, flags,
                             UInt8(address & 0xFF), UInt8((address >> 8) & 0xFF), UInt8((address >> 16) & 0xFF), UInt8((address >> 24) & 0xFF),
                             UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF), 0]
        body.append(contentsOf: data)
        var s: Int = 0
        for i in 6..<body.count { s += Int(body[i]) }
        body.append(UInt8(truncatingIfNeeded: ~s))
        return [0xF0] + SevenBit.pack7(body) + [0xF7]
    }

    static func successResponse(address: UInt32) -> [UInt8] {
        response(address: address, data: Array("success".utf8) + [0])
    }
}
