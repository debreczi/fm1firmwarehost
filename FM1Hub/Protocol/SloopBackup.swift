// SPDX-License-Identifier: GPL-3.0-only
// Ported from the SLOOP web editor (github.com/isod89/sloop-fm1), built on the Felucca web editor,
// Copyright (C) 2026 Leo Kuroshita (@kurogedelic), Hügelton Instruments.
//
// Complete musical archives of SLOOP and the firmwares built on it: the working project, the settings, the song
// sections, the user presets, the FM6 bank, the SYN kits, the MIDI map, the theme and the sample slots. The file is the
// editor's own ("sloop-backup" v1), so an archive made here opens in the web editor of the firmware it came from.
//
// Every firmware of the family is backed up the same way, because each lists what it holds. Writing back is another
// matter: those built on SLOOP keep objects of their own, in orders and formats only their own editors know, so the app
// writes back SLOOP's archives to SLOOP and leaves the others to their editors.

import Foundation

struct SloopArchiveObject: Codable {
    let id: Int
    let len: Int
    let crc: UInt32
    let data: String   // base64

    var bytes: [UInt8]? { Data(base64Encoded: data).map { [UInt8]($0) } }
}

struct SloopArchive: Codable {
    static let fileName = "sloop-backup.json"
    static let formatName = "sloop-backup"

    var format: String
    var version: Int
    var firmware: String
    var date: String
    var objects: [SloopArchiveObject]

    var totalBytes: Int { objects.reduce(0) { $0 + $1.len } }
}

/// What a firmware of the editor protocol says about itself (INFO).
struct EditorInfo: Equatable {
    let version: String         // "FELUCCA SLOOP 2.8.4"
    let paramCount: Int
    let protocolVersion: Int    // 0 on firmware older than protocol v5

    /// The firmware's own name: "SLOOP 2.8.4". This protocol's firmwares send it after Felucca's. Felucca itself sends
    /// only its version there ("FELUCCA v1.8.0"), which makes it "Felucca 1.8.0". A release build of many of them adds
    /// " BETA" to the version the hub knows ("FELUCCA sloopDX 4.0 BETA").
    static func ownName(of version: String) -> String {
        let suffix = " BETA"
        let words = version.hasSuffix(suffix) ? String(version.dropLast(suffix.count)) : version
        let prefix = "FELUCCA "
        guard words.hasPrefix(prefix) else { return words }
        let rest = words.dropFirst(prefix.count)
        guard let first = rest.first else { return words }
        if first.isNumber { return "Felucca \(rest)" }
        if first == "v", rest.dropFirst().first?.isNumber == true { return "Felucca \(rest.dropFirst())" }
        return String(rest)
    }
    var name: String { EditorInfo.ownName(of: version) }

    /// The firmware sends at most 24 characters here, so one that long may be cut in the middle of its version:
    /// "FELUCCA CoralFlower 0.6." is 0.6.1. Then it says nothing about the version, and nothing is taken from it.
    static func wholeName(of version: String) -> String? { version.count < 24 ? ownName(of: version) : nil }
    var wholeName: String? { EditorInfo.wholeName(of: version) }

    /// Backup and restore came with protocol v6 (SLOOP 2.3).
    var hasBackup: Bool { protocolVersion >= 6 }
    /// The newest project format this firmware reads: 2.6 (71 parameters) 6, 2.4 .. 2.5 (61) 5, older 4.
    var newestProjectFormat: Int { paramCount >= 71 ? 6 : paramCount >= 61 ? 5 : 4 }
}

/// One request and its reply over the editor protocol.
protocol EditorLink {
    func request(_ cmd: UInt8, _ args: [UInt8], timeout: TimeInterval, retries: Int, accepts: ([UInt8]) -> Bool) async throws -> [UInt8]
}

private extension EditorLink {
    func request(_ cmd: UInt8, _ args: [UInt8], timeout: TimeInterval, retries: Int) async throws -> [UInt8] {
        try await request(cmd, args, timeout: timeout, retries: retries, accepts: { _ in true })
    }
}

extension FeluccaLink: EditorLink {}

enum MusicBackupKind { case felucca, sloop }

enum SloopBackup {
    enum Cmd {
        static let info: UInt8 = 1, list: UInt8 = 34, get: UInt8 = 35, put: UInt8 = 36
    }
    private enum Op {
        static let begin: UInt8 = 0, data: UInt8 = 1, commit: UInt8 = 2, abort: UInt8 = 3
    }
    static let chunk = 256
    static let sampleDataOffset = 512, sampleHeaderLength = 480
    /// The order they are written back: banks, song sections, the working project, then the settings.
    static let restoreOrder = [6, 7, 8, 9, 10, 11, 2, 3, 4, 5, 0, 1]
    static let sampleIds = [32, 33, 34, 35]
    /// Objects a firmware older than the file may not have: it answers their begin with 1 or 5, and they are skipped.
    static let optionalIds: Set<Int> = [8, 9, 10, 11]
    /// What the app says of an archive it leaves to the firmware's own editor.
    static let ownEditorOnly = "This music goes back through the web editor of the firmware it came from. Share the files from this backup and open the sloop-backup file there."
    /// Far above any object an FM-1 can hold: a manifest may not make the phone allocate more than this for one.
    static let maxObjectSize = 1 << 20

    /// The firmware's own answer to INFO: version string, NENGINES, P_COUNT, G_COUNT, NSTEP, P_E0, the engine names, then
    /// NTRK and the protocol version, which older firmware leaves out.
    static func parseInfo(_ a: [UInt8]) -> EditorInfo? {
        var i = 0
        func text() -> String? {
            guard i <= a.count, let end = a[i...].firstIndex(of: 0),
                  a[i..<end].allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
            defer { i = end + 1 }
            return String(decoding: a[i..<end], as: UTF8.self)
        }
        guard let version = text(), !version.isEmpty, i + 5 <= a.count else { return nil }
        let engines = Int(a[i]), params = Int(a[i + 1])
        i += 5
        for _ in 0..<engines { guard text() != nil else { return nil } }
        return EditorInfo(version: version, paramCount: params, protocolVersion: i + 1 < a.count ? Int(a[i + 1]) : 0)
    }

    static func info(_ fl: some EditorLink) async -> EditorInfo? {
        guard let a = try? await fl.request(Cmd.info, [], timeout: 1.0, retries: 1) else { return nil }
        return parseInfo(a)
    }

    struct ManifestEntry: Equatable { let id: Int; let len: Int; let crc: UInt32 }

    /// BK_LIST's reply: rc, count, then per object its id, length and CRC-32.
    static func manifest(_ a: [UInt8]) throws -> [ManifestEntry] {
        guard a.count >= 2 else { throw FM1Error.protocolError("Incomplete archive manifest") }
        try FeluccaBackup.check(a[0])
        let n = Int(a[1])
        guard a.count >= 2 + n * 11 else { throw FM1Error.protocolError("Incomplete archive manifest") }
        var out: [ManifestEntry] = []
        for k in 0..<n {
            let p = 2 + k * 11
            let id = Int(a[p]), len = Int(try SevenBit.r32(a, p + 1)), crc = try SevenBit.r32(a, p + 6)
            guard len <= maxObjectSize else { throw FM1Error.protocolError("Archive object too large") }
            guard id <= 127, !out.contains(where: { $0.id == id }) else { throw FM1Error.protocolError("Unexpected archive object") }
            out.append(ManifestEntry(id: id, len: len, crc: crc))
        }
        guard out.contains(where: { $0.id == 0 }), out.contains(where: { $0.id == 1 }) else {
            throw FM1Error.protocolError("Archive without the current music or settings")
        }
        return out
    }

    /// Does this firmware answer SLOOP's backup? Asked only of one whose INFO says it should.
    static func supported(_ fl: some EditorLink, info: EditorInfo) async -> Bool {
        guard info.hasBackup, let a = try? await fl.request(Cmd.list, [], timeout: 5.0, retries: 0) else { return false }
        return (try? manifest(a)) != nil
    }

    /// What the running firmware says about itself and which music backup it answers. Felucca's is asked first: its
    /// family has numbers of its own for commands 34-36.
    static func detect(_ fl: FeluccaLink) async -> (info: EditorInfo?, kind: MusicBackupKind?) {
        let said = await info(fl)
        if await FeluccaBackup.supported(fl) { return (said, .felucca) }
        if let said, await supported(fl, info: said) { return (said, .sloop) }
        return (said, nil)
    }

    /// Reads everything the firmware lists.
    static func capture(_ fl: some EditorLink, info: EditorInfo, onProgress: @escaping (Int, Int) -> Void) async throws -> SloopArchive {
        let man = try manifest(try await fl.request(Cmd.list, [], timeout: 5.0, retries: 0))
        let total = man.reduce(0) { $0 + $1.len }
        var done = 0
        var objects: [SloopArchiveObject] = []
        for o in man {
            var bytes = [UInt8](repeating: 0, count: o.len)
            var off = 0
            while off < o.len {
                let size = min(chunk, o.len - off)
                let at = SevenBit.u32(UInt32(off))
                let a = try await fl.request(Cmd.get, [UInt8(o.id)] + at + [UInt8(size & 127), UInt8(size >> 7)], timeout: 1.5, retries: 2,
                                             accepts: { $0.count >= 7 && Int($0[0]) == o.id && Array($0[2..<7]) == at })
                guard a.count >= 9 else { throw FM1Error.protocolError("Short backup reply") }
                try FeluccaBackup.check(a[1])
                guard Int(a[0]) == o.id, try SevenBit.r32(a, 2) == UInt32(off), (Int(a[7]) | Int(a[8]) << 7) == size else {
                    throw FM1Error.protocolError("Unexpected backup reply")
                }
                let part = try SevenBit.blockUnpack(a[9...], size: size)
                bytes.replaceSubrange(off..<(off + size), with: part)
                off += size
                done += size
                onProgress(done, total)
            }
            if SevenBit.crc32(bytes) != o.crc { throw FM1Error.protocolError("The device changed during backup. Try again while stopped.") }
            objects.append(SloopArchiveObject(id: o.id, len: o.len, crc: o.crc, data: Data(bytes).base64EncodedString()))
        }
        // Not validated here: the editor keeps whatever the firmware lists, and refusing an object only a later firmware
        // has would cost the user the backup and, with the automatic backup on, the install. The CRCs were checked above.
        return SloopArchive(format: SloopArchive.formatName, version: 1, firmware: info.version,
                            date: ISO8601DateFormatter().string(from: Date()), objects: objects)
    }

    /// Every byte checked before the first destructive request. Returns the objects' bytes by id.
    static func validate(_ file: SloopArchive) throws -> [Int: [UInt8]] {
        guard file.format == SloopArchive.formatName, file.version == 1 else { throw FM1Error.package("Not a SLOOP backup.") }
        var all: [Int: [UInt8]] = [:]
        for o in file.objects {
            guard restoreOrder.contains(o.id) || sampleIds.contains(o.id) else { throw FM1Error.package(ownEditorOnly) }
            guard all[o.id] == nil, o.len >= 0, o.len <= maxObjectSize, let bytes = o.bytes else {
                throw FM1Error.package("Invalid backup object.")
            }
            guard bytes.count == o.len, SevenBit.crc32(bytes) == o.crc else { throw FM1Error.package("Backup checksum mismatch.") }
            if sampleIds.contains(o.id), o.len > 0, o.len < sampleDataOffset { throw FM1Error.package("Short sample backup.") }
            all[o.id] = bytes
        }
        guard all[0]?.isEmpty == false, all[1]?.isEmpty == false else { throw FM1Error.package("Backup is missing the current music or settings.") }
        return all
    }

    /// What a sample command's rc means: each command numbers its failures its own way.
    static func sampleProblem(_ cmd: UInt8, rc: UInt8, slot: UInt8) -> String {
        let what: String
        switch (cmd, rc) {
        case (FeluccaLink.Cmd.smpBegin, _), (FeluccaLink.Cmd.smpErase, _), (FeluccaLink.Cmd.smpWrite, 2): what = "could not be erased"
        case (FeluccaLink.Cmd.smpWrite, 3), (FeluccaLink.Cmd.smpEnd, 4): what = "could not be written"
        case (FeluccaLink.Cmd.smpWrite, 4), (FeluccaLink.Cmd.smpEnd, 6): what = "was not open for writing"
        case (FeluccaLink.Cmd.smpEnd, 3): what = "failed its data check"
        case (FeluccaLink.Cmd.smpEnd, _): what = "is not a valid sample"
        default: what = "failed (\(rc))"
        }
        return "Sample slot USR\(slot + 1) \(what)."
    }

    /// The project format of a backup object ("FUN6" as stored, low byte first), 0 when it is no project.
    static func projectFormat(_ d: [UInt8]) -> Int {
        guard d.count >= 4, d[1] == 0x4E, d[2] == 0x55, d[3] == 0x46 else { return 0 }
        return Int(d[0]) - 0x30
    }

    /// The first version number in a firmware's words: [2, 8, 4] for "SLOOP 2.8.4".
    static func versionNumbers(_ text: String) -> [Int]? {
        guard let re = try? NSRegularExpression(pattern: #"(\d+)\.(\d+)(?:\.(\d+))?"#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1...3).map { i -> Int in
            guard let r = Range(m.range(at: i), in: text) else { return 0 }
            return Int(text[r]) ?? 0
        }
    }

    /// "SLOOP 2.6" against a version: true when it is at least that.
    static func firmware(_ text: String, isAtLeast want: [Int]) -> Bool {
        guard let have = versionNumbers(text) else { return false }
        for i in 0..<3 where have[i] != want[i] { return have[i] > want[i] }
        return true
    }

    /// BK_PUT's rc. 5 is the object's begin gone stale here, not the snapshot it is while reading.
    private static func checkPut(_ rc: UInt8) throws {
        if rc == 5 { throw FM1Error.protocolError("The FM-1 lost its place in the restore.") }
        try FeluccaBackup.check(rc)
    }

    /// Writes an archive back: the objects in `restoreOrder`, each committed on its own, then the samples.
    static func restore(_ fl: some EditorLink, _ file: SloopArchive, info: EditorInfo, onProgress: @escaping (Int, Int) -> Void) async throws {
        var bytesOf = try validate(file)
        let madeOn = EditorInfo.ownName(of: file.firmware)
        guard madeOn.hasPrefix("SLOOP ") else { throw FM1Error.package(ownEditorOnly) }
        guard info.hasBackup, info.name.hasPrefix("SLOOP ") else {
            throw FM1Error.package("This music was made on \(madeOn), and the FM-1 runs \(info.name). Restore the firmware first.")
        }
        // Back onto an older SLOOP: stop before anything is written if it can't read the projects, not at the first one.
        // On the same or a newer SLOOP it can, and this table may not know a format that came after it.
        if !firmware(info.version, isAtLeast: versionNumbers(file.firmware) ?? [0, 0, 0]) {
            let newest = [0, 2, 3, 4, 5].compactMap { bytesOf[$0] }.map(projectFormat).max() ?? 0
            if newest > info.newestProjectFormat {
                throw FM1Error.package("This backup was made on \(madeOn), newer than the \(info.name) on the FM-1. Restore the firmware first.")
            }
        }
        // A backup without object 10 had the MIDI settings at their defaults: restored as such, not left as they are now
        if bytesOf[10] == nil, firmware(file.firmware, isAtLeast: [2, 5, 1]) {
            var d = [UInt8](repeating: 0, count: 40)
            d.replaceSubrange(32..<37, with: [1, 2, 3, 10, 2])
            bytesOf[10] = d
        }
        let total = max(bytesOf.values.reduce(0) { $0 + $1.count }, 1)
        var done = 0
        func put(_ op: UInt8, _ id: UInt8, _ rest: [UInt8] = [], timeout: TimeInterval, retries: Int) async throws -> UInt8 {
            let a = try await fl.request(Cmd.put, [op, id] + rest, timeout: timeout, retries: retries,
                                         accepts: { $0.count >= 3 && $0[0] == op && $0[1] == id })
            return a[2]
        }
        for objectId in restoreOrder {
            guard let d = bytesOf[objectId] else { continue }
            let id = UInt8(objectId)
            let begun = try await put(Op.begin, id, SevenBit.u32(UInt32(d.count)) + SevenBit.u32(SevenBit.crc32(d)), timeout: 1.5, retries: 1)
            if optionalIds.contains(objectId), begun == 1 || begun == 5 {
                done += d.count
                onProgress(done, total)
                continue
            }
            try checkPut(begun)
            do {
                var off = 0
                while off < d.count {
                    let end = min(off + chunk, d.count)
                    try checkPut(try await put(Op.data, id, SevenBit.u32(UInt32(off)) + SevenBit.blockPack(d[off..<end]), timeout: 1.5, retries: 1))
                    done += end - off
                    onProgress(done, total)
                    off = end
                }
                try checkPut(try await put(Op.commit, id, timeout: 5.0, retries: 0))
            } catch {
                _ = try? await put(Op.abort, id, timeout: 1.5, retries: 0)
                throw error
            }
        }
        for objectId in sampleIds {
            guard let d = bytesOf[objectId] else { continue }
            let slot = UInt8(objectId - 32)
            func sample(_ cmd: UInt8, _ args: [UInt8], timeout: TimeInterval, retries: Int = 0) async throws {
                // SMP_WRITE echoes the offset as well
                let echoed = cmd == FeluccaLink.Cmd.smpWrite ? Array(args.prefix(3)) : []
                let a = try await fl.request(cmd, [slot] + args, timeout: timeout, retries: retries,
                                             accepts: { $0.count >= 2 + echoed.count && $0[0] == slot && Array($0[1..<(1 + echoed.count)]) == echoed })
                if let rc = a.last, rc != 0 { throw FM1Error.protocolError(sampleProblem(cmd, rc: rc, slot: slot)) }
            }
            if d.isEmpty {
                try await sample(FeluccaLink.Cmd.smpErase, [], timeout: 2.5)
                continue
            }
            try await sample(FeluccaLink.Cmd.smpBegin, [], timeout: 1.0)
            var off = sampleDataOffset
            while off < d.count {
                let end = min(off + chunk, d.count)
                try await sample(FeluccaLink.Cmd.smpWrite, [UInt8(off & 127), UInt8((off >> 7) & 127), UInt8((off >> 14) & 127)] + SevenBit.blockPack(d[off..<end]), timeout: 1.0, retries: 1)
                done += end - off
                onProgress(done, total)
                off = end
            }
            try await sample(FeluccaLink.Cmd.smpEnd, SevenBit.blockPack(d[0..<sampleHeaderLength]), timeout: 2.0)
            done += sampleDataOffset
            onProgress(done, total)
        }
    }
}
