// SPDX-License-Identifier: GPL-3.0-only
// Ported from the Felucca web editor, fm1backup.js (Copyright (C) 2026 Leo Kuroshita (@kurogedelic), Hügelton Instruments).
//
// Complete musical archives of a Felucca-family firmware (Felucca and the firmwares built on it): the current music,
// settings, projects, user banks, FM6 patches and sample slots, read and written over the editor's SysEx protocol
// (F0 7D 46 4C cmd ... F7). Requests name whitelisted objects, never flash addresses. The file format is the
// editor's own ("felucca-backup" v1), so an archive made here opens in the Felucca web editor and back.

import Foundation

struct FeluccaArchiveObject: Codable {
    let id: Int
    let size: Int
    let crc: UInt32
    let data: String   // base64

    var bytes: [UInt8]? { Data(base64Encoded: data).map { [UInt8]($0) } }
}

struct FeluccaArchive: Codable {
    var format: String
    var version: Int
    var firmware: String
    var created: String
    var objects: [FeluccaArchiveObject]

    static let ids: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 32, 33, 34]
    static let idsV2: [Int] = ids.filter { $0 != 9 }
    static let idsV1: [Int] = idsV2.filter { $0 != 8 }

    static func idsOf(count: Int) -> [Int]? {
        [ids, idsV2, idsV1].first { $0.count == count }
    }

    var totalBytes: Int { objects.reduce(0) { $0 + $1.size } }
    var sampleBytes: Int { objects.filter { $0.id >= 32 }.reduce(0) { $0 + $1.size } }
}

/// The SysEx conversation with a Felucca-family firmware: one request at a time, the reply by command.
final class FeluccaLink {
    static let header: [UInt8] = [0x7D, 0x46, 0x4C]
    enum Cmd {
        static let smpBegin: UInt8 = 11, smpWrite: UInt8 = 12, smpEnd: UInt8 = 13, smpErase: UInt8 = 14
        static let backupList: UInt8 = 65, backupGet: UInt8 = 66, backupPut: UInt8 = 67
    }
    static let chunk = 256

    let link: MIDILink
    init(link: MIDILink) { self.link = link }

    /// Sends one frame and waits for the reply to the same command that `accepts` takes for its own: a retry can leave a
    /// late reply to an earlier request behind. `retries` resends on a timeout.
    func request(_ cmd: UInt8, _ args: [UInt8], timeout: TimeInterval = 1.2, retries: Int = 0, accepts: ([UInt8]) -> Bool = { _ in true }) async throws -> [UInt8] {
        for b in args where b > 0x7F { throw FM1Error.protocolError("Bad data byte \(b)") }
        var attempt = 0
        while true {
            link.drain()
            guard link.send([0xF0] + FeluccaLink.header + [cmd & 0x7F] + args + [0xF7]) else {
                throw FM1Error.lost("The FM-1 was disconnected.")
            }
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                guard let d = await link.read(timeout: end.timeIntervalSinceNow) else { break }
                guard d.count >= 6, d[0] == 0xF0, d[1] == 0x7D, d[2] == 0x46, d[3] == 0x4C, d.last == 0xF7 else { continue }
                if d[4] == cmd {
                    let reply = Array(d[5..<(d.count - 1)])
                    if accepts(reply) { return reply }
                }
            }
            if link.lost { throw FM1Error.lost("The FM-1 was disconnected.") }
            attempt += 1
            if attempt > retries { throw FM1Error.stopped("Backup timed out. Keep the FM-1 connected and stopped.") }
        }
    }
}

enum FeluccaBackup {
    static func check(_ rc: UInt8) throws {
        guard rc != 0 else { return }
        let m: [UInt8: String] = [1: "Invalid archive object", 2: "Archive data failed validation", 3: "Stop playback first",
                                  4: "Flash write failed", 5: "Start a fresh backup"]
        throw FM1Error.protocolError(m[rc] ?? "Archive error \(rc)")
    }

    struct ManifestEntry { let id: Int; let size: Int; let crc: UInt32 }

    static func manifest(_ a: [UInt8]) throws -> [ManifestEntry] {
        guard a.count >= 3, a[0] == 1 else { throw FM1Error.protocolError("Unsupported archive protocol") }
        try check(a[1])
        let n = Int(a[2])
        guard let ids = FeluccaArchive.idsOf(count: n), a.count == 3 + n * 11 else { throw FM1Error.protocolError("Incomplete archive manifest") }
        var out: [ManifestEntry] = []
        for (i, id) in ids.enumerated() {
            let p = 3 + i * 11
            guard Int(a[p]) == id else { throw FM1Error.protocolError("Unexpected archive object") }
            let size = Int(try SevenBit.r32(a, p + 1))
            let crc = try SevenBit.r32(a, p + 6)
            if size > (id >= 32 ? 81920 : 3840) || (size == 0 && crc != 0) { throw FM1Error.protocolError("Archive object too large") }
            out.append(ManifestEntry(id: id, size: size, crc: crc))
        }
        return out
    }

    /// Does the firmware answer the backup protocol at all? (A LIST that gets a valid manifest.)
    static func supported(_ fl: FeluccaLink) async -> Bool {
        guard let a = try? await fl.request(FeluccaLink.Cmd.backupList, [], timeout: 2.0) else { return false }
        return (try? manifest(a)) != nil
    }

    /// Reads everything the firmware lists. `firmware` names the firmware in the file.
    static func capture(_ fl: FeluccaLink, firmware: String, onProgress: @escaping (Int, Int) -> Void) async throws -> FeluccaArchive {
        let man = try manifest(try await fl.request(FeluccaLink.Cmd.backupList, [], timeout: 3.0))
        let total = man.reduce(0) { $0 + $1.size }
        var done = 0
        var objects: [FeluccaArchiveObject] = []
        for o in man {
            var bytes = [UInt8](repeating: 0, count: o.size)
            var off = 0
            while off < o.size {
                let size = min(FeluccaLink.chunk, o.size - off)
                let a = try await fl.request(FeluccaLink.Cmd.backupGet, [UInt8(o.id)] + SevenBit.u32(UInt32(off)) + [UInt8(size & 127), UInt8(size >> 7)], timeout: 1.0, retries: 1)
                guard a.count >= 9 else { throw FM1Error.protocolError("Short backup reply") }
                try check(a[1])
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
            objects.append(FeluccaArchiveObject(id: o.id, size: o.size, crc: o.crc, data: Data(bytes).base64EncodedString()))
        }
        let archive = FeluccaArchive(format: "felucca-backup", version: 1, firmware: firmware,
                                     created: ISO8601DateFormatter().string(from: Date()), objects: objects)
        _ = try validate(archive)
        return archive
    }

    /// Every byte checked before the first destructive request. Returns the objects' bytes by index.
    static func validate(_ file: FeluccaArchive) throws -> [[UInt8]] {
        guard file.format == "felucca-backup", file.version == 1, let ids = FeluccaArchive.idsOf(count: file.objects.count) else {
            throw FM1Error.package("Not a complete Felucca backup.")
        }
        var all: [[UInt8]] = []
        for (i, o) in file.objects.enumerated() {
            guard o.id == ids[i], o.size >= 0, o.size <= (o.id >= 32 ? 81920 : 3840), let bytes = o.bytes else {
                throw FM1Error.package("Invalid backup object.")
            }
            guard bytes.count == o.size, SevenBit.crc32(bytes) == o.crc else { throw FM1Error.package("Backup checksum mismatch.") }
            if o.id >= 32 && o.size > 0 {
                guard o.size >= 512 else { throw FM1Error.package("Short sample backup.") }
                let magic = le32(bytes, 0), ver = Int(bytes[4]) | Int(bytes[5]) << 8, count = Int(bytes[6]), length = Int(le32(bytes, 16))
                guard magic == 0x504D_5346, ver == 1, count >= 1, count <= 16, length == o.size - 512,
                      SevenBit.crc32(Array(bytes[512...])) == le32(bytes, 20) else { throw FM1Error.package("Invalid sample backup.") }
                for z in 0..<count {
                    let off = 32 + z * 28
                    let start = Int(le32(bytes, off)), n = Int(le32(bytes, off + 4)), ls = Int(le32(bytes, off + 8)), le = Int(le32(bytes, off + 12)), rate = Int(le32(bytes, off + 16))
                    guard n > 0, start <= length, (n + 1) / 2 <= length - start, n <= 163_840, ls <= le, le < n,
                          rate > 0, rate <= 262_144, bytes[off + 24] <= 88, bytes[off + 25] <= bytes[off + 26] else {
                        throw FM1Error.package("Invalid sample zone.")
                    }
                }
            }
            all.append(bytes)
        }
        guard all.count >= 2, !all[0].isEmpty, !all[1].isEmpty else { throw FM1Error.package("Backup is missing the current music or settings.") }
        return all
    }

    private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    /// Writes an archive back: the other objects first, each committed on its own, the settings, then the live music last.
    static func restore(_ fl: FeluccaLink, _ file: FeluccaArchive, onProgress: @escaping (Int, Int) -> Void) async throws {
        let bytesOf = try validate(file)
        let total = file.totalBytes
        var done = 0
        func ask(_ cmd: UInt8, _ args: [UInt8]) async throws -> [UInt8] {
            try await fl.request(cmd, args, timeout: 4.0, retries: 0)
        }
        func put(_ args: [UInt8]) async throws -> [UInt8] {
            let a = try await ask(FeluccaLink.Cmd.backupPut, args)
            guard a.count >= 3 else { throw FM1Error.protocolError("Short restore reply") }
            try check(a[2])
            return a
        }
        var order = Array(2..<file.objects.count)
        order.append(1)
        order.append(0)
        for idx in order {
            let o = file.objects[idx]
            let bytes = bytesOf[idx]
            if o.id >= 32 {
                let slot = UInt8(o.id - 32)
                func checkSmp(_ a: [UInt8]) throws {
                    guard let first = a.first, first == slot, let rc = a.last else { throw FM1Error.protocolError("Unexpected sample reply") }
                    try check(rc)
                }
                if o.size == 0 {
                    try checkSmp(try await ask(FeluccaLink.Cmd.smpErase, [slot]))
                } else {
                    guard o.size >= 512 else { throw FM1Error.package("Short sample backup.") }
                    try checkSmp(try await ask(FeluccaLink.Cmd.smpBegin, [slot]))
                    var off = 512
                    while off < o.size {
                        let end = min(off + FeluccaLink.chunk, o.size)
                        let chunk = bytes[off..<end]
                        try checkSmp(try await ask(FeluccaLink.Cmd.smpWrite, [slot, UInt8(off & 127), UInt8((off >> 7) & 127), UInt8((off >> 14) & 127)] + SevenBit.blockPack(chunk)))
                        done += chunk.count
                        onProgress(done, total)
                        off = end
                    }
                    try checkSmp(try await ask(FeluccaLink.Cmd.smpEnd, [slot] + SevenBit.blockPack(bytes[0..<480])))
                    done += 512
                    onProgress(done, total)
                }
            } else {
                let id = UInt8(o.id)
                let begin: [UInt8] = [0, id] + SevenBit.u32(UInt32(o.size)) + SevenBit.u32(o.crc)
                if o.id == 9 {
                    // firmware before 1.0.3 does not take id 9 (rc 1 at begin, nothing written): skip it
                    let a = try await ask(FeluccaLink.Cmd.backupPut, begin)
                    if a.count >= 3 && a[2] == 1 { done += o.size; onProgress(done, total); continue }
                    guard a.count >= 3 else { throw FM1Error.protocolError("Short restore reply") }
                    try check(a[2])
                } else {
                    _ = try await put(begin)
                }
                do {
                    var off = 0
                    while off < o.size {
                        let end = min(off + FeluccaLink.chunk, o.size)
                        _ = try await put([1, id] + SevenBit.u32(UInt32(off)) + SevenBit.blockPack(bytes[off..<end]))
                        done += end - off
                        onProgress(done, total)
                        off = end
                    }
                    _ = try await put([2, id])
                } catch {
                    _ = try? await ask(FeluccaLink.Cmd.backupPut, [3, id])
                    throw error
                }
            }
        }
    }
}
