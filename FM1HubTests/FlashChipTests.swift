import XCTest
@testable import FM1Hub

/// Newer FM-1s have another flash chip, and a firmware made for the first ones bricks them. Every cell of the decision
/// table is pinned here, with both positions of the Settings switch, so that a change to one cell can't slip through.
final class FlashChipTests: XCTestCase {
    private let other: UInt32 = 0x12_3456
    private let all: [ChipSupport] = [.new, .any, .old, .official, .unknown]

    private func v(_ device: DeviceFlash, _ package: ChipSupport, allow: Bool = false) -> ChipVerdict {
        ChipGuard.verdict(device: device, package: package, allowUnsafe: allow)
    }

    func testTheKnownChips() {
        XCTAssertEqual(FlashChip.first, 0x856014)
        XCTAssertEqual(FlashChip.newer, 0xB36014)
        XCTAssertEqual(FlashChip.known.map(\.id), [0x856014, 0xB36014], "the README and the Flash chips page list these two")
        XCTAssertEqual(FlashChip.hex(0xB36014), "0xB36014")
        XCTAssertEqual(FlashChip.hex(0x14), "0x000014")
    }

    func testTheFirstChipTakesEveryFirmware() {
        for p in all {
            for allow in [false, true] { XCTAssertEqual(v(.reported(FlashChip.first), p, allow: allow), .install, "\(p)") }
        }
    }

    func testTheNewerChip() {
        let newer = DeviceFlash.reported(FlashChip.newer)
        for allow in [false, true] {
            XCTAssertEqual(v(newer, .new, allow: allow), .install)
            XCTAssertEqual(v(newer, .any, allow: allow), .install)
            XCTAssertEqual(v(newer, .official, allow: allow), .install, "newer FM-1s ship with M-VAVE's firmware")
            XCTAssertEqual(v(newer, .unknown, allow: allow), .warn(.newerChipUnknownPackage), "a warning, never a refusal")
        }
        XCTAssertEqual(v(newer, .old), .refused(FlashChip.newer), "the switch is off: refused")
        XCTAssertEqual(v(newer, .old, allow: true), .dangerous(FlashChip.newer), "the switch is on: asked as dangerous")
    }

    func testAThirdChip() {
        let third = DeviceFlash.reported(other)
        for allow in [false, true] {
            XCTAssertEqual(v(third, .any, allow: allow), .install, "it does not check the chip")
            XCTAssertEqual(v(third, .new, allow: allow), .warn(.unknownChip(other)), "it knows only the two chips")
            XCTAssertEqual(v(third, .official, allow: allow), .warn(.unknownChip(other)))
            XCTAssertEqual(v(third, .unknown, allow: allow), .warn(.unknownChip(other)))
        }
        XCTAssertEqual(v(third, .old), .refused(other), "a first-FM-1 firmware accepts only the first chip")
        XCTAssertEqual(v(third, .old, allow: true), .dangerous(other))
    }

    /// Most of the time: M-VAVE's firmware and most others never say. The switch does not matter here.
    func testNotReported() {
        for allow in [false, true] {
            XCTAssertEqual(v(.notReported, .new, allow: allow), .install)
            XCTAssertEqual(v(.notReported, .any, allow: allow), .install, "no note")
            XCTAssertEqual(v(.notReported, .official, allow: allow), .install)
            XCTAssertEqual(v(.notReported, .old, allow: allow), .warn(.oldPackage))
            XCTAssertEqual(v(.notReported, .unknown, allow: allow), .warn(.unknownPackage))
        }
    }

    /// What the user agreed to, against what the device says at the point of no return.
    func testConsentAtThePointOfNoReturn() {
        let newer = FlashChip.newer
        XCTAssertTrue(ChipGuard.allows(.install, consent: .install))
        XCTAssertTrue(ChipGuard.allows(.install, consent: .warn(.oldPackage)), "the FM-1 turned out to be a first one")
        XCTAssertFalse(ChipGuard.allows(.warn(.newerChipUnknownPackage), consent: .install), "it reported its chip only now")
        XCTAssertTrue(ChipGuard.allows(.warn(.newerChipUnknownPackage), consent: .warn(.unknownPackage)),
                      "the warning agreed to said an unsafe firmware may brick a newer FM-1")
        XCTAssertFalse(ChipGuard.allows(.dangerous(newer), consent: .warn(.oldPackage)), "dangerous needs its own Yes")
        XCTAssertTrue(ChipGuard.allows(.dangerous(newer), consent: .dangerous(newer)))
        XCTAssertFalse(ChipGuard.allows(.dangerous(newer), consent: .dangerous(other)), "agreed for another chip")
        for consent: ChipVerdict in [.install, .warn(.oldPackage), .dangerous(newer), .refused(newer)] {
            XCTAssertFalse(ChipGuard.allows(.refused(newer), consent: consent), "a refusal is never agreed away")
        }
    }

    func testTheWordsKeepBrickedAndNameTheSwitch() {
        XCTAssertTrue(ChipGuard.text(.warn(.oldPackage)).contains("M-VAVE logo under the screen"))
        XCTAssertTrue(ChipGuard.text(.warn(.oldPackage)).contains("brick"))
        XCTAssertTrue(ChipGuard.text(.refused(FlashChip.newer)).contains("Allow installing on unsafe FM-1s"))
        XCTAssertTrue(ChipGuard.text(.refused(FlashChip.newer)).contains("Nothing was installed"))
        XCTAssertTrue(ChipGuard.text(.refused(other)).contains("0x123456"))
        XCTAssertTrue(ChipGuard.stopText(.dangerous(FlashChip.newer)).contains("Nothing was installed"))
        for verdict: ChipVerdict in [.warn(.oldPackage), .warn(.unknownPackage), .warn(.newerChipUnknownPackage), .warn(.unknownChip(other)),
                                     .dangerous(FlashChip.newer), .refused(FlashChip.newer)] {
            XCTAssertFalse(ChipGuard.heading(verdict).isEmpty)
            XCTAssertFalse(ChipGuard.text(verdict).contains("!"), "plain words, no exclamation marks")
        }
    }

    // MARK: The catalogue

    private func catalogue(_ entries: [String]) throws -> [Firmware] {
        try JSONDecoder().decode(Catalog.self, from: Data(#"{"firmwares":[\#(entries.joined(separator: ","))]}"#.utf8)).firmwares
    }

    private func entry(_ id: String, chip: String?, loader: String? = nil) -> String {
        let c = (chip.map { #","chip":"\#($0)""# } ?? "") + (loader.map { #","loader":"\#($0)""# } ?? "")
        return #"{"id":"\#(id)","name":"\#(id)","pkg":"fw/\#(id).fwsc","product":"FM-1_900","sha256":"\#(id)"\#(c)}"#
    }

    /// What the hub said of a package is kept in the app's own storage, by hash: it still counts once the catalogue
    /// moves on, a later word replaces it, and silence takes back only a claim that it is safe.
    func testTheHubsWordIsKeptByHash() throws {
        let id = "kept-\(UUID().uuidString)"
        XCTAssertEqual(PackageStore.shared.seenChip(id), .unknown)
        PackageStore.shared.noteChips(try catalogue([entry(id, chip: "old")]))
        XCTAssertEqual(PackageStore.shared.seenChip(id), .old)
        PackageStore.shared.noteChips(try catalogue([entry(id, chip: "new")]))
        XCTAssertEqual(PackageStore.shared.seenChip(id), .new)
        PackageStore.shared.noteChips(try catalogue([entry(id, chip: nil)]))
        XCTAssertEqual(PackageStore.shared.seenChip(id), .unknown, "the hub no longer says it is safe")
        let old = "kept-old-\(UUID().uuidString)"
        PackageStore.shared.noteChips(try catalogue([entry(old, chip: "old")]))
        PackageStore.shared.noteChips(try catalogue([entry(old, chip: nil)]))
        XCTAssertEqual(PackageStore.shared.seenChip(old), .old, "silence never makes a package safe")
        PackageStore.shared.noteChips(try catalogue([entry(old, chip: "both")]))
        XCTAssertEqual(PackageStore.shared.seenChip(old), .old, "nor does a value the app doesn't know")
        PackageStore.shared.noteChips(try catalogue([entry(old, chip: "any")]))
        XCTAssertEqual(PackageStore.shared.seenChip(old), .any, "the hub's own word does")
        XCTAssertEqual(PackageStore.shared.seenChip("never-\(UUID().uuidString)"), .unknown)
        XCTAssertFalse(PackageStore.shared.seenStockLoader(id))
        PackageStore.shared.noteChips(try catalogue([entry(id, chip: "any", loader: "mvave")]))
        XCTAssertTrue(PackageStore.shared.seenStockLoader(id), "built on M-VAVE's code: its loader writes it")
        PackageStore.shared.noteChips(try catalogue([entry(id, chip: "any")]))
        XCTAssertFalse(PackageStore.shared.seenStockLoader(id))
    }

    func testTheCataloguesChipField() throws {
        let fw = try catalogue([entry("a", chip: "new"), entry("b", chip: "old"), entry("c", chip: "any"), entry("d", chip: nil),
                                entry("e", chip: "both"), entry("f", chip: "NEW")])
        XCTAssertEqual(fw.map(\.chipSupport), [.new, .old, .any, .unknown, .unknown, .new])
        let again = try JSONDecoder().decode(Firmware.self, from: JSONEncoder().encode(fw[1]))
        XCTAssertEqual(again.chip, "old", "the cached copy keeps it")
    }

    /// A backup keeps the value as text: an older library has none, and a value a later version writes reads as none.
    func testABackupsChipValue() throws {
        var s = Snapshot(name: "x", identity: "FM-1_900", firmwareId: nil, firmwareName: "x", version: nil, product: nil, packageFile: nil,
                         packageSHA256: nil, packageSize: nil, packageExact: false, archiveFile: nil, archiveBytes: nil, archiveObjects: nil)
        XCTAssertNil(s.chipSupport)
        var json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        XCTAssertFalse(json.contains("\"chip\""))
        s.chip = "later"
        json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        let back = try JSONDecoder().decode(Snapshot.self, from: Data(json.utf8))
        XCTAssertNil(back.chipSupport)
        s.chip = ChipSupport.old.rawValue
        XCTAssertEqual(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(s)).chipSupport, .old)
    }
}

/// The identity reply can carry the flash chip, and some firmwares shorten their identity in the plain reply. Both
/// broke FM-1 Hub 1.0: the first hid the FM-1 ("No FM-1 found"), the second failed a good install.
final class IdentityReplyTests: XCTestCase {

    /// A cmd 0x11 reply as the firmwares build it: 27 bytes of text and zeros, the JEDEC ID in bytes 24-26.
    private func reply(_ text: String, jedec: UInt32 = 0, tail: [UInt8] = [], checksumOffset: Int = 0, length: UInt8 = 27) -> [UInt8] {
        var body = Array(text.utf8) + tail
        body += Array(repeating: 0, count: max(0, 27 - body.count))
        body = Array(body.prefix(27))
        if jedec != 0 { body[24] = UInt8(jedec >> 16 & 0xFF); body[25] = UInt8(jedec >> 8 & 0xFF); body[26] = UInt8(jedec & 0xFF) }
        let sum = body.reduce(0) { $0 + Int($1) }
        let msg: [UInt8] = [0x00, 0x59, 0x11, length, 0, 0] + body + [UInt8(truncatingIfNeeded: ~sum + checksumOffset)]
        return [0xF0] + SevenBit.pack7(msg) + [0xF7]
    }

    private func hello(_ text: String, _ flash: UInt32? = nil, full: Bool = false) -> FM1Hello {
        FM1Hello(identity: FM1Identity.parse(text: text)!, flashID: flash, full: full)
    }

    func testTheQueries() {
        XCTAssertEqual(SevenBit.unpack7(FM1Protocol.handshakeQuery.dropFirst().dropLast()), [0x00, 0x59, 0x11, 0, 0, 0, 0xFF])
        let full = SevenBit.unpack7(FM1Protocol.fullHandshakeQuery.dropFirst().dropLast())
        XCTAssertEqual(Array(full.prefix(8)), [0x00, 0x59, 0x11, 1, 0, 0, 1, 0xFE], "cmd 0x11, length 1, body 01, checksum")
        XCTAssertEqual(full.count, 8, "decoded to exactly eight bytes, as the firmwares check")
    }

    func testAPlainReply() {
        let h = FM1Protocol.parseHello(reply("FM-1_900"))
        XCTAssertEqual(h?.identity.text, "FM-1_900")
        XCTAssertNil(h?.flashID)
        XCTAssertEqual(FM1Protocol.parseIdentity(reply("FM-1_015"))?.text, "FM-1_015")
        XCTAssertEqual(FM1Protocol.parseIdentity(reply("ota-FM-1_916"))?.isLoader, true)
    }

    func testAReplyWithTheFlashChip() {
        let h = FM1Protocol.parseHello(reply("FM-1_378011", jedec: FlashChip.newer))
        XCTAssertEqual(h?.identity.text, "FM-1_378011", "1.0 read the chip's bytes as text and found no FM-1")
        XCTAssertEqual(h?.flashID, FlashChip.newer)
        XCTAssertEqual(FM1Protocol.parseHello(reply("FM-1_900", jedec: FlashChip.first))?.flashID, FlashChip.first)
    }

    func testTheTextEndsAtItsFirstZero() {
        XCTAssertEqual(FM1Protocol.parseHello(reply("FM-1_900", tail: [0, 0x41, 0x42]))?.identity.text, "FM-1_900")
        // a text that runs into bytes 24-26 leaves no room for a chip ID
        let long = FM1Protocol.parseHello(reply("ABCDEFGHIJKLMNOPQRSTUVW_901"))
        XCTAssertEqual(long?.identity.text, "ABCDEFGHIJKLMNOPQRSTUVW_901")
        XCTAssertNil(long?.flashID)
    }

    func testWhoIsAskedTheFullRequest() {
        XCTAssertTrue(FM1Protocol.asksFullIdentity(after: hello("FM-1_900").identity))
        XCTAssertTrue(FM1Protocol.asksFullIdentity(after: hello("FM-1_378011").identity), "ESTAMPIE answers it with the chip")
        XCTAssertTrue(FM1Protocol.asksFullIdentity(after: hello("FM-1_601").identity))
        XCTAssertFalse(FM1Protocol.asksFullIdentity(after: hello("FM-1_015").identity), "M-VAVE's firmware is sent nothing it doesn't know")
        XCTAssertFalse(FM1Protocol.asksFullIdentity(after: hello("FM-1_016").identity))
        XCTAssertFalse(FM1Protocol.asksFullIdentity(after: hello("FM-1_000").identity), "the USB rescue mode")
        XCTAssertFalse(FM1Protocol.asksFullIdentity(after: hello("ota-FM-1_900").identity), "a loader")
    }

    func testAChipIDCountsOnlyFromAnIntactReply() {
        let broken = FM1Protocol.parseHello(reply("FM-1_378011", jedec: FlashChip.first, checksumOffset: 1))
        XCTAssertEqual(broken?.identity.text, "FM-1_378011", "the identity stands, as it always has")
        XCTAssertNil(broken?.flashID, "the first FM-1s' chip from a reply that doesn't add up counts as not reported")
        XCTAssertEqual(FM1Protocol.parseHello(reply("FM-1_378011", jedec: FlashChip.newer, checksumOffset: 1))?.flashID, FlashChip.newer,
                       "another chip may warn from any reply")
        XCTAssertNil(FM1Protocol.parseHello(reply("FM-1_378011", jedec: FlashChip.first, length: 26))?.flashID)
        XCTAssertEqual(FM1Protocol.parseHello(reply("FM-1_378011", jedec: FlashChip.newer))?.flashID, FlashChip.newer)
    }

    func testMergingTheTwoReplies() {
        // a firmware that doesn't answer the full request keeps its plain answer
        XCTAssertEqual(FM1Protocol.merge(plain: hello("FM-1_900"), full: nil), hello("FM-1_900"))
        // felucca-bsp: three digits to the plain request, the whole identity to the full one
        XCTAssertEqual(FM1Protocol.merge(plain: hello("FM-1_601"), full: hello("FM-1_6010000")), hello("FM-1_6010000", full: true))
        // ESTAMPIE: the same identity, and the chip
        XCTAssertEqual(FM1Protocol.merge(plain: hello("FM-1_378011"), full: hello("FM-1_378011", FlashChip.newer)), hello("FM-1_378011", FlashChip.newer, full: true))
        // a chip in the plain reply stays when the full one has none
        XCTAssertEqual(FM1Protocol.merge(plain: hello("FM-1_601", FlashChip.first), full: hello("FM-1_6010000")), hello("FM-1_6010000", FlashChip.first, full: true))
        // an answer that does not belong to the plain one is not taken
        XCTAssertEqual(FM1Protocol.merge(plain: hello("FM-1_601"), full: hello("FM-1_7010000")), hello("FM-1_601"))
        XCTAssertEqual(FM1Protocol.merge(plain: hello("FM-1_900"), full: hello("FM-1_9001")), hello("FM-1_9001", full: true), "felucca-bsp shortens FM-1_9001 to FM-1_900")
        XCTAssertEqual(FM1Protocol.merge(plain: hello("FM-1_900"), full: hello("SMK_9001")), hello("FM-1_900"), "another model")
        XCTAssertEqual(FM1Protocol.merge(plain: hello("FM-1_6010000"), full: hello("FM-1_601")), hello("FM-1_6010000"))
        // a chip in a reply that does not belong may add a warning, never take one away
        XCTAssertEqual(FM1Protocol.merge(plain: hello("FM-1_601"), full: hello("FM-1_7010000", FlashChip.newer)), hello("FM-1_601", FlashChip.newer))
        XCTAssertEqual(FM1Protocol.merge(plain: hello("FM-1_601"), full: hello("FM-1_7010000", FlashChip.first)), hello("FM-1_601"))
    }

    func testTheShortFormNamesTheSameFirmware() {
        XCTAssertTrue(FM1Identity.same("FM-1_904", "FM-1_904"))
        XCTAssertTrue(FM1Identity.same("FM-1_601", "FM-1_6010000"))
        XCTAssertTrue(FM1Identity.same("FM-1_6010000", "FM-1_601"))
        XCTAssertTrue(FM1Identity.same("FM-1_700", "FM-1_7001700"), "PERF-1's scheme")
        XCTAssertFalse(FM1Identity.same("FM-1_700", "FM-1_7010302"), "not a shortening: the mismatch check stands")
        XCTAssertFalse(FM1Identity.same("FM-1_601", "FM-1_6020000"))
        XCTAssertFalse(FM1Identity.same("FM-1_60", "FM-1_6010000"), "only the three-digit form")
        XCTAssertFalse(FM1Identity.same("FM-1_9010", "FM-1_9010201"), "four digits are a whole identity")
        XCTAssertFalse(FM1Identity.same("ota-FM-1_601", "ota-FM-1_6010000"), "a loader's identity is whole")
        XCTAssertFalse(FM1Identity.same("FM-1_601", "FM-2_6010000"))
    }

    func testAnAnswerNamesThePackageOnlyAsItsShortForm() {
        XCTAssertTrue(FM1Identity.answers("FM-1_904", for: "FM-1_904"))
        XCTAssertTrue(FM1Identity.answers("FM-1_601", for: "FM-1_6010000"), "felucca-bsp's plain reply")
        XCTAssertFalse(FM1Identity.answers("FM-1_6010000", for: "FM-1_601"), "a longer answer is another firmware")
        XCTAssertFalse(FM1Identity.answers("FM-1_602", for: "FM-1_6010000"))
        XCTAssertFalse(FM1Identity.answers("ota-FM-1_601", for: "ota-FM-1_6010000"))
        XCTAssertFalse(FM1Identity.answers("FM-1_601", for: "FM-1_6010000", full: true), "a whole identity of three digits is another firmware")
        XCTAssertTrue(FM1Identity.answers("FM-1_6010000", for: "FM-1_6010000", full: true))
    }

    func testAPendingUpdateFinishedUnderTheShortForm() {
        let p = PendingUpdate(product: "FM-1_6010000", sha256: "beef", firmwareId: "ctl", name: "CTL", version: "1.0",
                              usesStockLoader: false, source: .hub, identityBefore: "FM-1_900")
        XCTAssertFalse(p.isFinished(by: FM1Identity.parse(text: "FM-1_601")!), "a three-digit answer could be another firmware: the record stays")
        XCTAssertTrue(p.isFinished(by: FM1Identity.parse(text: "FM-1_6010000")!))
        var again = p
        again.identityBefore = "FM-1_601"
        XCTAssertFalse(again.isFinished(by: FM1Identity.parse(text: "FM-1_6010000")!), "it ran this firmware before too: which build is unknown")
        let short = PendingUpdate(product: "FM-1_601", sha256: "beef", firmwareId: nil, name: "x", version: "",
                                  usesStockLoader: false, source: .hub, identityBefore: "FM-1_900")
        XCTAssertFalse(short.isFinished(by: FM1Identity.parse(text: "FM-1_6010000")!), "an identity longer than the package's is another firmware")
    }
}
