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
}

/// A cmd 0x30 read request from the device.
struct FM1ReadRequest {
    let flags: UInt8
    let address: UInt32
    let length: Int
}

enum FM1Protocol {
    static let handshakeQuery: [UInt8] = [0xF0, 0x00, 0x32, 0x45, 0x00, 0x00, 0x00, 0x40, 0x7F, 0xF7]
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

    static func parseIdentity(_ pkt: [UInt8]) -> FM1Identity? {
        guard pkt.count > 2, pkt.first == 0xF0, pkt.last == 0xF7 else { return nil }
        let d = SevenBit.unpack7(pkt[1..<(pkt.count - 1)])
        guard d.count == 34, d[0] == 0, d[1] == 0x59, d[2] == 0x11 else { return nil }
        var chars = Array(d[6..<33])
        while let last = chars.last, last == 0 { chars.removeLast() }
        let txt = String(decoding: chars, as: UTF8.self)
        return FM1Identity.parse(text: txt)
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
