import XCTest
@testable import FM1Hub

/// A .fwsc carries its identity in one marker byte after each of the first 20 blocks, and the image the device
/// addresses is the file without those markers. Both are read before anything is written, so both are tested.
final class FWSCPackageTests: XCTestCase {

    /// A synthetic package that reports `product`, with `payload` bytes after the 20 header blocks.
    static func makePackage(product: String, payload: Int = 1024) -> Data {
        var b = [UInt8](repeating: 0xA5, count: FWSCPackage.blocks * FWSCPackage.blockSize + payload)
        let chars = Array(product.utf8)
        for i in 0..<FWSCPackage.blocks {
            let at = i * FWSCPackage.blockSize + FWSCPackage.keep
            b[at] = i < chars.count ? UInt8((Int(chars[i]) + i + 1) & 0xFF) : 0x7D
        }
        return Data(b)
    }

    func testReadsItsIdentity() throws {
        let p = try FWSCPackage(data: FWSCPackageTests.makePackage(product: "FM-1_904"))
        XCTAssertEqual(p.product, "FM-1_904")
        XCTAssertFalse(p.isOfficial, "9xx is a custom firmware")
        XCTAssertNil(p.officialVersion)
    }

    func testOfficialIdentityAndVersion() throws {
        let p = try FWSCPackage(data: FWSCPackageTests.makePackage(product: "FM-1_016"))
        XCTAssertEqual(p.product, "FM-1_016")
        XCTAssertTrue(p.isOfficial)
        XCTAssertEqual(p.officialVersion, "V16")
    }

    func testOfficialProductPattern() {
        XCTAssertTrue(FWSCPackage.isOfficialProduct("FM-1_015"))
        XCTAssertTrue(FWSCPackage.isOfficialProduct("FM-1_099"))
        XCTAssertFalse(FWSCPackage.isOfficialProduct("FM-1_100"))
        XCTAssertFalse(FWSCPackage.isOfficialProduct("FM-1_904"))
        XCTAssertFalse(FWSCPackage.isOfficialProduct("FM-1_0155"))
        XCTAssertFalse(FWSCPackage.isOfficialProduct(""))
        XCTAssertEqual(FWSCPackage.officialVersion(of: "FM-1_015"), "V15")
        XCTAssertNil(FWSCPackage.officialVersion(of: "FM-1_904"))
    }

    /// The logical image is the file minus exactly one byte per header block, in order.
    func testLogicalImageDropsTheMarkerBytes() throws {
        let data = FWSCPackageTests.makePackage(product: "FM-1_904", payload: 300)
        let p = try FWSCPackage(data: data)
        let image = p.logicalImage
        XCTAssertEqual(image.count, p.bytes.count - FWSCPackage.blocks)
        // the first block contributes its first 0x2F bytes, the marker is gone
        XCTAssertEqual(Array(image.prefix(FWSCPackage.keep)), Array(p.bytes[0..<FWSCPackage.keep]))
        // everything after the header blocks is carried over untouched
        let tail = FWSCPackage.blocks * FWSCPackage.blockSize
        XCTAssertEqual(Array(image.suffix(300)), Array(p.bytes[tail...]))
    }

    func testRejectsAFileTooShortToBeAPackage() {
        let short = Data(repeating: 0, count: FWSCPackage.blocks * FWSCPackage.blockSize - 1)
        XCTAssertThrowsError(try FWSCPackage(data: short)) { e in
            XCTAssertEqual((e as? FM1Error)?.code, "package")
        }
    }

    func testStockV15IsPinnedByItsHash() throws {
        // a package that merely claims to be FM-1_015 is not the official V15 file
        let p = try FWSCPackage(data: FWSCPackageTests.makePackage(product: "FM-1_015"))
        XCTAssertEqual(p.product, FWSCPackage.stockV15Product)
        XCTAssertFalse(p.isStockV15, "only the exact published file may pass")
    }

    func testSHA256IsTheStandardHexDigest() {
        XCTAssertEqual(FWSCPackage.sha256Hex(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
