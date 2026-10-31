import XCTest
@testable import FM1Hub

/// `validate` is the gate in front of every destructive request a restore makes: it runs on an archive the user
/// picked, so its rejections matter as much as its acceptance.
final class FeluccaBackupTests: XCTestCase {

    /// The shape validate() accepts: the music and settings objects carry bytes, the sample slots are empty.
    static func makeArchive(ids: [Int] = FeluccaArchive.ids) -> FeluccaArchive {
        let objects = ids.map { id -> FeluccaArchiveObject in
            let bytes: [UInt8] = id >= 32 ? [] : [1, 2, 3, 4]
            return FeluccaArchiveObject(id: id, size: bytes.count, crc: SevenBit.crc32(bytes),
                                        data: Data(bytes).base64EncodedString())
        }
        return FeluccaArchive(format: "felucca-backup", version: 1, firmware: "FM-1_900",
                              created: "2026-10-26T00:00:00Z", objects: objects)
    }

    private static func with(_ a: FeluccaArchive, replacing index: Int, by o: FeluccaArchiveObject) -> FeluccaArchive {
        var a = a
        a.objects[index] = o
        return a
    }

    func testAWellFormedArchivePasses() throws {
        for ids in [FeluccaArchive.ids, FeluccaArchive.idsV2, FeluccaArchive.idsV1] {
            let bytes = try FeluccaBackup.validate(FeluccaBackupTests.makeArchive(ids: ids))
            XCTAssertEqual(bytes.count, ids.count, "every object's bytes come back, in order")
        }
    }

    func testTotalsAreCountedFromTheObjects() {
        let a = FeluccaBackupTests.makeArchive()
        XCTAssertEqual(a.objects.count, 13)
        XCTAssertEqual(a.totalBytes, 4 * 10, "ten objects of four bytes, and three empty sample slots")
        XCTAssertEqual(a.sampleBytes, 0, "the sample slots are empty in this archive")
    }

    func testRejectsAForeignFormat() {
        var a = FeluccaBackupTests.makeArchive()
        a.format = "something-else"
        XCTAssertThrowsError(try FeluccaBackup.validate(a))
    }

    func testRejectsAnotherVersion() {
        var a = FeluccaBackupTests.makeArchive()
        a.version = 2
        XCTAssertThrowsError(try FeluccaBackup.validate(a))
    }

    func testRejectsAnIncompleteObjectList() {
        var a = FeluccaBackupTests.makeArchive()
        a.objects.removeLast()
        XCTAssertThrowsError(try FeluccaBackup.validate(a), "11 objects is none of the known archive shapes")
    }

    func testRejectsObjectsOutOfOrder() {
        var a = FeluccaBackupTests.makeArchive()
        a.objects.swapAt(0, 1)
        XCTAssertThrowsError(try FeluccaBackup.validate(a))
    }

    func testRejectsAChecksumThatDoesNotMatch() {
        let a = FeluccaBackupTests.makeArchive()
        let wrong = FeluccaArchiveObject(id: a.objects[0].id, size: a.objects[0].size,
                                         crc: a.objects[0].crc ^ 0xFFFF, data: a.objects[0].data)
        XCTAssertThrowsError(try FeluccaBackup.validate(FeluccaBackupTests.with(a, replacing: 0, by: wrong))) { e in
            XCTAssertEqual((e as? FM1Error)?.code, "package")
        }
    }

    func testRejectsASizeThatDoesNotMatchTheBytes() {
        let a = FeluccaBackupTests.makeArchive()
        let wrong = FeluccaArchiveObject(id: a.objects[0].id, size: 3, crc: a.objects[0].crc, data: a.objects[0].data)
        XCTAssertThrowsError(try FeluccaBackup.validate(FeluccaBackupTests.with(a, replacing: 0, by: wrong)))
    }

    func testRejectsAnOversizedObject() {
        let a = FeluccaBackupTests.makeArchive()
        let big = [UInt8](repeating: 7, count: 3841)
        let wrong = FeluccaArchiveObject(id: a.objects[0].id, size: big.count, crc: SevenBit.crc32(big),
                                         data: Data(big).base64EncodedString())
        XCTAssertThrowsError(try FeluccaBackup.validate(FeluccaBackupTests.with(a, replacing: 0, by: wrong)))
    }

    func testRejectsASampleObjectTooShortToCarryItsHeader() {
        let a = FeluccaBackupTests.makeArchive()
        let i = a.objects.firstIndex { $0.id >= 32 }!
        let short = [UInt8](repeating: 9, count: 8)
        let wrong = FeluccaArchiveObject(id: a.objects[i].id, size: short.count, crc: SevenBit.crc32(short),
                                         data: Data(short).base64EncodedString())
        XCTAssertThrowsError(try FeluccaBackup.validate(FeluccaBackupTests.with(a, replacing: i, by: wrong)))
    }

    func testRejectsAnArchiveWithoutTheCurrentMusic() {
        let a = FeluccaBackupTests.makeArchive()
        let empty = FeluccaArchiveObject(id: a.objects[0].id, size: 0, crc: SevenBit.crc32([]),
                                         data: Data().base64EncodedString())
        XCTAssertThrowsError(try FeluccaBackup.validate(FeluccaBackupTests.with(a, replacing: 0, by: empty)))
    }
}
