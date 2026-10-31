import XCTest
@testable import FM1Hub

/// Resume has to find the one package that was being written, not merely one with the same identity: a firmware
/// rebuilt between two attempts keeps its identity and changes its hash. These tests pin that lookup down.
final class PackageStoreTests: XCTestCase {

    func testLocalPackageMatchesTheExactBuildWhenAHashIsGiven() throws {
        let store = PackageStore.shared
        let a = try FWSCPackage(data: FWSCPackageTests.makePackage(product: "FM-1_904", payload: 1024))
        let b = try FWSCPackage(data: FWSCPackageTests.makePackage(product: "FM-1_904", payload: 2048))
        XCTAssertEqual(a.product, b.product)
        XCTAssertNotEqual(a.sha256, b.sha256, "two builds of one firmware share its identity, not its hash")

        let ua = try store.keep(a)
        let ub = try store.keep(b)
        defer {
            try? FileManager.default.removeItem(at: ua)
            try? FileManager.default.removeItem(at: ub)
        }

        XCTAssertEqual(store.localPackage(product: "FM-1_904", sha256: a.sha256)?.sha256, a.sha256)
        XCTAssertEqual(store.localPackage(product: "FM-1_904", sha256: b.sha256)?.sha256, b.sha256)
        XCTAssertNil(store.localPackage(product: "FM-1_904", sha256: String(repeating: "0", count: 64)),
                     "a build that is not the pending one must not be offered to Resume")
        XCTAssertNotNil(store.localPackage(product: "FM-1_904"),
                        "without a hash any build with that identity still counts, as before")
        XCTAssertNil(store.localPackage(product: "FM-1_999", sha256: a.sha256))
    }

    func testKeepIsIdempotentAndNamedAfterIdentityAndHash() throws {
        let store = PackageStore.shared
        let p = try FWSCPackage(data: FWSCPackageTests.makePackage(product: "FM-1_905", payload: 512))
        let first = try store.keep(p)
        let second = try store.keep(p)
        defer { try? FileManager.default.removeItem(at: first) }
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "FM-1_905-\(p.sha256.prefix(8)).fwsc")
        XCTAssertEqual(try Data(contentsOf: first).count, p.bytes.count)
    }

    /// A truncated file under the cache name must not be trusted: that file is what a resume looks up by hash.
    func testKeepReplacesACacheEntryThatDoesNotHashRight() throws {
        let store = PackageStore.shared
        let p = try FWSCPackage(data: FWSCPackageTests.makePackage(product: "FM-1_906", payload: 512))
        let url = try store.keep(p)
        defer { try? FileManager.default.removeItem(at: url) }

        try Data(p.bytes.prefix(1000)).write(to: url, options: .atomic)
        XCTAssertNil(store.localPackage(product: "FM-1_906", sha256: p.sha256),
                     "a truncated file is not that package, however it is named")

        XCTAssertEqual(try store.keep(p), url)
        XCTAssertEqual(try Data(contentsOf: url).count, p.bytes.count, "the bad file was replaced, not accepted")
        XCTAssertEqual(store.localPackage(product: "FM-1_906", sha256: p.sha256)?.sha256, p.sha256)
    }

    func testTheCeilingIsSmallEnoughToBeMeaningfulAndBigEnoughForARealPackage() {
        XCTAssertGreaterThan(PackageStore.maxPackageBytes, FWSCPackage.stockV15Size)
        XCTAssertLessThanOrEqual(PackageStore.maxPackageBytes, 8_000_000)
    }

    func testFileNameIsSafeForTheFileSystem() {
        let f = PackageStoreTests.firmware(id: "melodee", version: "2.0 beta/2", sha256: "abcdef1234567890")
        let name = PackageStore.shared.fileName(for: f)
        XCTAssertEqual(name, "melodee-2.0_beta_2-abcdef12.fwsc")
        XCTAssertFalse(name.contains("/"))
    }

    /// A catalogue entry built from JSON, since `Firmware` decodes rather than taking a memberwise init.
    static func firmware(id: String, version: String, sha256: String, size: Int = 699_956,
                         product: String = "FM-1_904") -> Firmware {
        let json = """
        {"id":"\(id)","name":"\(id)","author":"someone","version":"\(version)","what":"","kind":["synths"],
         "pkg":"fw/\(id).fwsc","product":"\(product)","size":\(size),"sha256":"\(sha256)"}
        """
        return try! JSONDecoder().decode(Firmware.self, from: Data(json.utf8))
    }
}
