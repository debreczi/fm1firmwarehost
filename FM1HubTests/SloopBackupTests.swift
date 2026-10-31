import XCTest
@testable import FM1Hub

/// A SLOOP as its protocol document describes it (web/EDITOR_PROTOCOL.md in isod89/sloop-fm1): no hardware is needed to
/// hold the app to the frames, the order and the answers of that document.
private final class FakeSloop: EditorLink {
    var objects: [Int: [UInt8]]
    var said = "FELUCCA SLOOP 2.8.4"    // editor.c: ed_str("FELUCCA " FELUCCA_VERSION, 24)
    var params: UInt8 = 71
    var proto: UInt8? = 11
    var playing = false             // commits of projects, banks and settings answer rc 3
    var refused: Set<Int> = []      // a firmware older than these objects answers their begin with 5
    var sampleFails: (cmd: UInt8, rc: UInt8)?
    var commitFails: UInt8?         // what a commit answers, with a late reply to its data request arriving first
    private(set) var writes: [String] = []
    private(set) var listed = 0
    private var staged: (id: Int, len: Int, crc: UInt32, bytes: [UInt8])?
    private var sample: (slot: Int, bytes: [UInt8])?

    init(objects: [Int: [UInt8]]) { self.objects = objects }

    private func u(_ a: [UInt8], _ off: Int) throws -> Int { Int(try SevenBit.r32(a, off)) }

    /// The packed length says how many bytes it holds: a mask byte for every seven.
    private func unpack(_ a: ArraySlice<UInt8>) throws -> [UInt8] {
        let groups = (a.count + 7) / 8
        return try SevenBit.blockUnpack(a, size: a.count - groups)
    }

    func request(_ cmd: UInt8, _ args: [UInt8], timeout: TimeInterval, retries: Int, accepts: ([UInt8]) -> Bool) async throws -> [UInt8] {
        if cmd == 36, args[0] == 2, let rc = commitFails {
            let late: [UInt8] = [1, args[1], 0]
            return accepts(late) ? late : [2, args[1], rc]
        }
        if let f = sampleFails, f.cmd == cmd {
            return cmd == 12 ? Array(args[0...3]) + [f.rc] : [args[0], f.rc]
        }
        let reply = try answer(cmd, args)
        XCTAssertTrue(accepts(reply), "the app must take the device's own reply to command \(cmd) for its own")
        return reply
    }

    private func answer(_ cmd: UInt8, _ args: [UInt8]) throws -> [UInt8] {
        switch cmd {
        case 1:
            var a = Array(said.utf8)
            a += [0, 2, params, 40, 64, 12]
            a += Array("FM".utf8)
            a.append(0)
            a += Array("DRAW".utf8)
            a += [0, 4]
            if let proto { a.append(proto) }
            return a
        case 34:
            listed += 1
            var a: [UInt8] = [0, UInt8(objects.count)]
            for id in objects.keys.sorted() {
                let d = objects[id]!
                a += [UInt8(id)] + SevenBit.u32(UInt32(d.count)) + SevenBit.u32(SevenBit.crc32(d))
            }
            return a
        case 35:
            let id = Int(args[0]), off = try u(args, 1), n = Int(args[6]) | Int(args[7]) << 7
            var reply: [UInt8] = [args[0], 1]
            reply += SevenBit.u32(UInt32(off))
            reply += [args[6], args[7]]
            guard let d = objects[id], n >= 1, n <= 256, off + n <= d.count else { return reply }
            reply[1] = 0
            reply += SevenBit.blockPack(d[off..<(off + n)])
            return reply
        case 36:
            let op = args[0], id = Int(args[1])
            func put(_ rc: UInt8) -> [UInt8] { [op, args[1], rc] }
            switch op {
            case 0:
                if refused.contains(id) { return put(5) }
                staged = (id, try u(args, 2), UInt32(try u(args, 7)), [])
                writes.append("begin \(id)")
                return put(0)
            case 1:
                guard var s = staged, s.id == id, try u(args, 2) == s.bytes.count else { return put(5) }
                s.bytes += try unpack(args[7...])
                staged = s
                return put(s.bytes.count <= 256 * 4096 ? 0 : 1)
            case 2:
                guard let s = staged, s.id == id else { return put(5) }
                if playing { return put(3) }
                guard s.bytes.count == s.len, SevenBit.crc32(s.bytes) == s.crc else { return put(2) }
                objects[id] = s.bytes
                staged = nil
                writes.append("commit \(id)")
                return put(0)
            case 3:
                staged = nil
                writes.append("abort \(id)")
                return put(0)
            default:
                return put(1)
            }
        case 11:
            sample = (Int(args[0]), [UInt8](repeating: 0, count: 512))
            writes.append("sample begin \(args[0])")
            return [args[0], 0]
        case 12:
            let off = Int(args[1]) | Int(args[2]) << 7 | Int(args[3]) << 14
            guard var s = sample, s.slot == Int(args[0]), off >= 512, off % 256 == 0, off == s.bytes.count else { return Array(args[0...3]) + [4] }
            s.bytes += try unpack(args[4...])
            sample = s
            return Array(args[0...3]) + [0]
        case 13:
            guard var s = sample, s.slot == Int(args[0]) else { return [args[0], 1] }
            let header = try unpack(args[1...])
            guard header.count == 480 else { return [args[0], 1] }
            s.bytes.replaceSubrange(0..<480, with: header)
            objects[32 + s.slot] = s.bytes
            sample = nil
            writes.append("sample end \(args[0])")
            return [args[0], 0]
        case 14:
            objects[32 + Int(args[0])] = []
            writes.append("sample erase \(args[0])")
            return [args[0], 0]
        default:
            // "Requests the device does not understand get no reply"
            throw FM1Error.stopped("Backup timed out. Keep the FM-1 connected and stopped.")
        }
    }
}

final class SloopBackupTests: XCTestCase {
    /// Bytes a CRC can tell apart, with the high bit set often enough to exercise the packing.
    private static func bytes(_ n: Int, seed: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed &* 7 &+ 128) } }

    /// A project object of this format: "FUN6" as stored, low byte first.
    private static func project(format: Int, size: Int = 700) -> [UInt8] {
        [UInt8(0x30 + format), 0x4E, 0x55, 0x46] + bytes(size - 4, seed: format)
    }

    /// A sample slot as it is in flash: the header, up to byte 512 nothing, then the data.
    private static func sample(data: Int, seed: Int) -> [UInt8] {
        bytes(480, seed: seed) + [UInt8](repeating: 0, count: 32) + bytes(data, seed: seed + 1)
    }

    private static func aDevice() -> FakeSloop {
        FakeSloop(objects: [
            0: project(format: 6), 1: bytes(120, seed: 1), 2: project(format: 6, size: 300), 3: [], 4: [], 5: [],
            6: bytes(600, seed: 6), 7: [], 8: bytes(257, seed: 8), 9: bytes(256, seed: 9), 10: bytes(40, seed: 10), 11: bytes(36, seed: 11),
            32: sample(data: 700, seed: 32), 33: [], 34: [], 35: []
        ])
    }

    private static let sloop = EditorInfo(version: "FELUCCA SLOOP 2.8.4", paramCount: 71, protocolVersion: 11)

    private func capture(_ device: FakeSloop) async throws -> SloopArchive {
        try await SloopBackup.capture(device, info: Self.sloop) { _, _ in }
    }

    private func restore(_ file: SloopArchive, to device: FakeSloop, info: EditorInfo = SloopBackupTests.sloop) async throws {
        try await SloopBackup.restore(device, file, info: info) { _, _ in }
    }

    // MARK: INFO

    func testInfoReadsTheEditorsLayout() async throws {
        let said = await SloopBackup.info(Self.aDevice())
        let info = try XCTUnwrap(said)
        XCTAssertEqual(info, Self.sloop)
        XCTAssertEqual(info.name, "SLOOP 2.8.4")
        XCTAssertTrue(info.hasBackup)
        XCTAssertEqual(info.newestProjectFormat, 6)
    }

    func testAFirmwaresOwnNameIsWhatFollowsFeluccas() {
        XCTAssertEqual(EditorInfo.ownName(of: "FELUCCA SLOOP 2.8.4"), "SLOOP 2.8.4")
        XCTAssertEqual(EditorInfo.ownName(of: "FELUCCA CLIPPER 1.3"), "CLIPPER 1.3")
        XCTAssertEqual(EditorInfo.ownName(of: "FELUCCA 1.8.0"), "FELUCCA 1.8.0", "Felucca itself")
        XCTAssertEqual(EditorInfo.ownName(of: "DRUM-DEV"), "DRUM-DEV")
        XCTAssertEqual(EditorInfo.ownName(of: "FELUCCA "), "FELUCCA ")
    }

    func testFirmwareBeforeTheProtocolVersionByteHasNoBackup() async {
        let old = Self.aDevice()
        old.proto = nil
        let info = await SloopBackup.info(old)
        XCTAssertEqual(info?.protocolVersion, 0)
        XCTAssertFalse(info?.hasBackup ?? true)
        let answered = await SloopBackup.supported(old, info: info!)
        XCTAssertFalse(answered)
        XCTAssertEqual(old.listed, 0, "the backup commands are not even asked of a firmware that says it lacks them")
    }

    func testInfoRefusesWhatIsNotAnInfoReply() {
        XCTAssertNil(SloopBackup.parseInfo([]))
        XCTAssertNil(SloopBackup.parseInfo([0, 1, 2, 3, 4, 5]), "no version string")
        XCTAssertNil(SloopBackup.parseInfo(Array("SLOOP".utf8)), "a string that never ends")
        XCTAssertNil(SloopBackup.parseInfo(Array("SLOOP".utf8) + [0, 1, 2]), "cut short")
        var oneEngine = Array("SLOOP".utf8)
        oneEngine += [0, 2, 71, 40, 64, 12]
        oneEngine += Array("FM".utf8)
        oneEngine.append(0)
        XCTAssertNil(SloopBackup.parseInfo(oneEngine), "an engine name missing")
        XCTAssertNil(SloopBackup.parseInfo([0x53, 0x01, 0x4C, 0, 0, 71, 40, 64, 12]), "not text")
    }

    // MARK: The manifest

    func testAManifestNeedsTheMusicAndTheSettings() {
        func entry(_ id: UInt8) -> [UInt8] { [id] + SevenBit.u32(4) + SevenBit.u32(9) }
        XCTAssertEqual(try SloopBackup.manifest([0, 2] + entry(0) + entry(1)).map(\.id), [0, 1])
        XCTAssertThrowsError(try SloopBackup.manifest([0, 1] + entry(0)))
        XCTAssertThrowsError(try SloopBackup.manifest([4, 0]), "rc 4: no flash")
        XCTAssertThrowsError(try SloopBackup.manifest([0, 2] + entry(0)), "fewer objects than it counts")
        XCTAssertThrowsError(try SloopBackup.manifest([0, 3] + entry(0) + entry(1) + entry(1)), "an object twice")
        XCTAssertThrowsError(try SloopBackup.manifest([0]))
    }

    func testAManifestCannotAskForAnAbsurdObject() {
        let huge = [UInt8(0)] + SevenBit.u32(UInt32(SloopBackup.maxObjectSize + 1)) + SevenBit.u32(9)
        let settings = [UInt8(1)] + SevenBit.u32(4) + SevenBit.u32(9)
        XCTAssertThrowsError(try SloopBackup.manifest([0, 2] + huge + settings))
    }

    // MARK: Backup

    func testACaptureReadsEveryObjectIntact() async throws {
        let device = Self.aDevice()
        let archive = try await capture(device)
        XCTAssertEqual(archive.objects.count, device.objects.count)
        for o in archive.objects {
            XCTAssertEqual(o.bytes, device.objects[o.id], "object \(o.id)")
            XCTAssertEqual(o.len, device.objects[o.id]?.count)
        }
        XCTAssertEqual(archive.firmware, "FELUCCA SLOOP 2.8.4", "the editor reads the firmware's version from here")
    }

    func testTheFileIsTheEditorsOwnFormat() async throws {
        let archive = try await capture(Self.aDevice())
        let data = try JSONEncoder().encode(archive)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["format", "version", "firmware", "date", "objects"])
        XCTAssertEqual(json["format"] as? String, "sloop-backup")
        XCTAssertEqual(json["version"] as? Int, 1)
        let first = try XCTUnwrap((json["objects"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(first.keys), ["id", "len", "crc", "data"])
    }

    func testTheProgressReachesTheTotal() async throws {
        let device = Self.aDevice()
        let total = device.objects.values.reduce(0) { $0 + $1.count }
        let seen = Seen()
        _ = try await SloopBackup.capture(device, info: Self.sloop) { d, t in seen.record(d, t) }
        XCTAssertEqual(seen.last?.0, total)
        XCTAssertEqual(seen.last?.1, total)
    }

    // MARK: Restore

    func testARestorePutsEverythingBack() async throws {
        let original = Self.aDevice()
        let archive = try await capture(original)
        let other = FakeSloop(objects: [0: [9], 1: [9], 32: Self.bytes(600, seed: 5)])
        try await restore(archive, to: other)
        XCTAssertEqual(other.objects, original.objects)
    }

    func testARestoreKeepsTheEditorsOrder() async throws {
        let archive = try await capture(Self.aDevice())
        let other = Self.aDevice()
        try await restore(archive, to: other)
        let commits = other.writes.filter { $0.hasPrefix("commit") }
        XCTAssertEqual(commits, [6, 7, 8, 9, 10, 11, 2, 3, 4, 5, 0, 1].map { "commit \($0)" },
                       "banks, sections, the working project, then the settings")
        XCTAssertEqual(other.writes.suffix(5), ["sample begin 0", "sample end 0", "sample erase 1", "sample erase 2", "sample erase 3"],
                       "the samples come last, an empty slot is erased")
    }

    func testObjectsOnlyAFirmwareOfTheFamilyHasAreKeptAndGoBackWithTheBanks() async throws {
        let clipper = Self.aDevice()
        clipper.objects[12] = Self.bytes(100, seed: 12)
        clipper.objects[100] = Self.bytes(20, seed: 100)
        let archive = try await capture(clipper)
        XCTAssertEqual(archive.objects.first { $0.id == 12 }?.len, 100, "a backup does not fail on an object the app has not heard of")

        let same = Self.aDevice()
        try await restore(archive, to: same)
        XCTAssertEqual(same.objects[12], clipper.objects[12])
        XCTAssertEqual(same.objects[100], clipper.objects[100])
        let commits = same.writes.filter { $0.hasPrefix("commit") }
        XCTAssertEqual(commits, [6, 7, 8, 9, 10, 11, 12, 100, 2, 3, 4, 5, 0, 1].map { "commit \($0)" })

        let other = Self.aDevice()
        other.refused = [12, 100]
        try await restore(archive, to: other)
        XCTAssertTrue(other.writes.contains("commit 1"), "a firmware without them still gets the rest")
    }

    func testObjectsAnOlderFirmwareLacksAreSkipped() async throws {
        let archive = try await capture(Self.aDevice())
        let older = Self.aDevice()
        older.refused = [8, 9, 10, 11]
        try await restore(archive, to: older)
        XCTAssertFalse(older.writes.contains("commit 8"))
        XCTAssertTrue(older.writes.contains("commit 1"), "the rest still goes back")
    }

    func testARefusalOfAnObjectEveryFirmwareHasStopsTheRestore() async throws {
        let archive = try await capture(Self.aDevice())
        let device = Self.aDevice()
        device.refused = [6]
        do {
            try await restore(archive, to: device)
            XCTFail("rc 5 on a preset bank is an error")
        } catch {
            XCTAssertTrue(device.writes.isEmpty, "nothing after it")
        }
    }

    func testAPlayingSongStopsTheRestoreAndAbortsTheObject() async throws {
        let archive = try await capture(Self.aDevice())
        let device = Self.aDevice()
        device.playing = true
        do {
            try await restore(archive, to: device)
            XCTFail("rc 3 at the commit is an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Stop playback first")
            XCTAssertEqual(device.writes, ["begin 6", "abort 6"], "nothing further is written")
        }
    }

    func testALateReplyIsNotTakenForTheCommit() async throws {
        let archive = try await capture(Self.aDevice())
        let device = Self.aDevice()
        device.commitFails = 2
        do {
            try await restore(archive, to: device)
            XCTFail("the commit answered 2: a late reply to the data request must not read as its success")
        } catch {
            XCTAssertTrue(device.writes.contains("abort 6"))
        }
    }

    func testALateBackupReplyIsLeftForTheOneItBelongsTo() async throws {
        let device = Self.aDevice()
        let late = LateReplies(device: device)
        let archive = try await SloopBackup.capture(late, info: Self.sloop) { _, _ in }
        XCTAssertEqual(archive.objects.first { $0.id == 6 }?.bytes, device.objects[6])
        XCTAssertGreaterThan(late.ignored, 0, "the test did offer it replies to earlier requests")
    }

    func testASampleFailureSaysWhatItIs() async throws {
        let archive = try await capture(Self.aDevice())
        for (cmd, rc, words) in [(UInt8(12), UInt8(3), "could not be written"), (12, 2, "could not be erased"), (12, 4, "was not open"),
                                 (13, 3, "failed its data check"), (13, 4, "could not be written"), (13, 5, "not a valid sample"), (11, 1, "could not be erased")] {
            let device = Self.aDevice()
            device.sampleFails = (cmd, rc)
            do {
                try await restore(archive, to: device)
                XCTFail("command \(cmd) answered \(rc)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("USR1"), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains(words), error.localizedDescription)
                XCTAssertFalse(error.localizedDescription.contains("Stop playback"))
            }
        }
    }

    func testProjectsNewerThanTheFirmwareReadsAreRefusedBeforeAnythingIsWritten() async throws {
        let archive = try await capture(Self.aDevice())
        let device = Self.aDevice()
        do {
            try await restore(archive, to: device, info: EditorInfo(version: "SLOOP 2.5", paramCount: 61, protocolVersion: 10))
            XCTFail("a format 6 project does not open in 2.5")
        } catch {
            XCTAssertTrue(device.writes.isEmpty)
            XCTAssertEqual((error as? FM1Error)?.nothingWritten, true)
        }
    }

    func testAFirmwareWithoutBackupIsRefusedBeforeAnythingIsWritten() async throws {
        let archive = try await capture(Self.aDevice())
        let device = Self.aDevice()
        do {
            try await restore(archive, to: device, info: EditorInfo(version: "SLOOP 2.2", paramCount: 40, protocolVersion: 5))
            XCTFail("no backup commands on protocol 5")
        } catch {
            XCTAssertTrue(device.writes.isEmpty)
        }
    }

    func testABackupWithoutTheMIDIObjectRestoresItsDefaults() async throws {
        var archive = try await capture(Self.aDevice())
        archive.objects.removeAll { $0.id == 10 }
        let device = Self.aDevice()
        try await restore(archive, to: device)
        var defaults = [UInt8](repeating: 0, count: 40)
        defaults.replaceSubrange(32..<37, with: [1, 2, 3, 10, 2])
        XCTAssertEqual(device.objects[10], defaults, "BK_LIST leaves it out only while it is the default")

        archive.firmware = "SLOOP 2.4"
        let older = Self.aDevice()
        let before = older.objects[10]
        try await restore(archive, to: older)
        XCTAssertEqual(older.objects[10], before, "2.4 has no MIDI settings to put back")
    }

    // MARK: The gate in front of a restore

    private func refusesBeforeWriting(_ change: (inout SloopArchive) -> Void) async throws {
        var archive = try await capture(Self.aDevice())
        change(&archive)
        XCTAssertThrowsError(try SloopBackup.validate(archive))
        let device = Self.aDevice()
        do {
            try await restore(archive, to: device)
            XCTFail("this file must not reach the device")
        } catch {
            XCTAssertTrue(device.writes.isEmpty)
        }
    }

    func testADamagedFileNeverReachesTheDevice() async throws {
        try await refusesBeforeWriting { $0.format = "felucca-backup" }
        try await refusesBeforeWriting { $0.version = 2 }
        try await refusesBeforeWriting { $0.objects.removeAll { $0.id == 0 } }
        try await refusesBeforeWriting { $0.objects.removeAll { $0.id == 1 } }
        try await refusesBeforeWriting { $0.objects.append($0.objects[0]) }
        try await refusesBeforeWriting { a in
            let o = a.objects[0]
            a.objects[0] = SloopArchiveObject(id: o.id, len: o.len, crc: o.crc &+ 1, data: o.data)
        }
        try await refusesBeforeWriting { a in
            let o = a.objects[0]
            a.objects[0] = SloopArchiveObject(id: o.id, len: o.len + 1, crc: o.crc, data: o.data)
        }
        try await refusesBeforeWriting { a in
            a.objects.append(SloopArchiveObject(id: 200, len: 0, crc: 0, data: ""))
        }
        try await refusesBeforeWriting { a in
            let short = [UInt8](repeating: 1, count: 100)
            a.objects.removeAll { $0.id == 33 }
            a.objects.append(SloopArchiveObject(id: 33, len: 100, crc: SevenBit.crc32(short), data: Data(short).base64EncodedString()))
        }
    }

    // MARK: Small helpers

    func testVersionsCompareAsTheEditorCompares() {
        XCTAssertTrue(SloopBackup.firmware("SLOOP 2.8.4", isAtLeast: [2, 5, 1]))
        XCTAssertTrue(SloopBackup.firmware("SLOOP 2.5.1", isAtLeast: [2, 5, 1]))
        XCTAssertFalse(SloopBackup.firmware("SLOOP 2.5", isAtLeast: [2, 5, 1]))
        XCTAssertFalse(SloopBackup.firmware("SLOOP 2.4.9", isAtLeast: [2, 5, 1]))
        XCTAssertFalse(SloopBackup.firmware("DRUM-DEV", isAtLeast: [2, 5, 1]))
    }

    func testAProjectSaysItsFormat() {
        XCTAssertEqual(SloopBackup.projectFormat(Self.project(format: 6)), 6)
        XCTAssertEqual(SloopBackup.projectFormat([1, 2, 3, 4]), 0)
        XCTAssertEqual(SloopBackup.projectFormat([]), 0)
    }
}

/// Offers each backup read the reply to the read before it first, as a late reply after a retry would be.
private final class LateReplies: EditorLink {
    let device: FakeSloop
    private(set) var ignored = 0
    private var previous: [UInt8]?

    init(device: FakeSloop) { self.device = device }

    func request(_ cmd: UInt8, _ args: [UInt8], timeout: TimeInterval, retries: Int, accepts: ([UInt8]) -> Bool) async throws -> [UInt8] {
        if cmd == 35, let old = previous, !accepts(old) { ignored += 1 }
        let reply = try await device.request(cmd, args, timeout: timeout, retries: retries, accepts: accepts)
        if cmd == 35 { previous = reply }
        return reply
    }
}

private final class Seen {
    private(set) var last: (Int, Int)?
    func record(_ d: Int, _ t: Int) { last = (d, t) }
}
