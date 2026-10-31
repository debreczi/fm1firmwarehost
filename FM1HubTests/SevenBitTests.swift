import XCTest
@testable import FM1Hub

/// The two 7-bit packings and the CRC-32 every Felucca archive is checked with: if one of these drifts, backups
/// decode to rubbish and an image is written wrong. They are pure functions, so they are tested exactly.
final class SevenBitTests: XCTestCase {

    private var sample: [UInt8] {
        // every byte value, so the high bits and the 7/8 boundaries are all exercised
        (0..<256).map { UInt8($0) } + [0x00, 0xFF, 0x7F, 0x80]
    }

    func testPack7RoundTrip() {
        let data = sample
        let packed = SevenBit.pack7(data)
        XCTAssertTrue(packed.allSatisfy { $0 <= 0x7F }, "packed bytes must fit in 7 bits for SysEx")
        let back = SevenBit.unpack7(packed[...])
        XCTAssertEqual(Array(back.prefix(data.count)), data)
    }

    func testPack7OfEmptyIsEmpty() {
        XCTAssertEqual(SevenBit.pack7([]), [])
        XCTAssertEqual(SevenBit.unpack7([][...]), [])
    }

    func testBlockPackRoundTrip() throws {
        for count in [0, 1, 6, 7, 8, 13, 14, 260] {
            let data = Array(sample.prefix(count))
            let packed = SevenBit.blockPack(data[...])
            XCTAssertTrue(packed.allSatisfy { $0 <= 0x7F }, "block-packed bytes must fit in 7 bits")
            let back = try SevenBit.blockUnpack(packed[...], size: count)
            XCTAssertEqual(back, data, "round trip failed for \(count) bytes")
        }
    }

    func testBlockUnpackRejectsShortAndTrailingBytes() {
        let packed = SevenBit.blockPack(Array(sample.prefix(14))[...])
        let truncated = Array(packed.dropLast(3))
        let padded = packed + [0]
        XCTAssertThrowsError(try SevenBit.blockUnpack(truncated[...], size: 14), "a truncated chunk must not decode")
        XCTAssertThrowsError(try SevenBit.blockUnpack(padded[...], size: 14), "trailing bytes must not decode")
    }

    func testU32RoundTrip() throws {
        for n: UInt32 in [0, 1, 127, 128, 0xFFFF, 0x0FFF_FFFF, 0xFFFF_FFFF] {
            let a = SevenBit.u32(n)
            XCTAssertEqual(a.count, 5)
            XCTAssertTrue(a.allSatisfy { $0 <= 0x7F })
            XCTAssertEqual(try SevenBit.r32(a, 0), n, "round trip failed for \(n)")
        }
    }

    func testR32RejectsTooShortAndOversizedTopByte() {
        XCTAssertThrowsError(try SevenBit.r32([0, 0, 0, 0], 0))
        XCTAssertThrowsError(try SevenBit.r32([0, 0, 0, 0, 16], 0), "the top byte carries 4 bits only")
    }

    /// The two values the standard pins down (IEEE 802.3, reflected polynomial 0xEDB88320).
    func testCRC32KnownValues() {
        XCTAssertEqual(SevenBit.crc32([]), 0)
        XCTAssertEqual(SevenBit.crc32(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(SevenBit.crc32(Array("The quick brown fox jumps over the lazy dog".utf8)), 0x414F_A339)
    }
}
