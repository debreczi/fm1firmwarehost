import XCTest
@testable import FM1Hub

/// Resume has to find the one package that was being written, not merely one with the same identity: a firmware
/// rebuilt between two attempts keeps its identity and changes its hash. These tests pin that lookup down.
final class PackageStoreTests: XCTestCase {

    func testAReleaseCarriesExactlyItsVersion() {
        XCTAssertTrue(PackageStore.carries(version: "2.8.3", "v2.8.3"))
        XCTAssertTrue(PackageStore.carries(version: "2.8.3", "sloop-2.8.3.fwsc"))
        XCTAssertTrue(PackageStore.carries(version: "2.8", "sloop-2.8.fwsc"))
        XCTAssertTrue(PackageStore.carries(version: "0.26.0", "drum-v0.26.0"))
        XCTAssertFalse(PackageStore.carries(version: "2.8", "v2.8.4"), "2.8 is not 2.8.4")
        XCTAssertFalse(PackageStore.carries(version: "8.4", "v2.8.4"))
        XCTAssertFalse(PackageStore.carries(version: "2.8.3", "sloop-2.8.31.fwsc"))
        XCTAssertFalse(PackageStore.carries(version: "2.8.3", "2x8x3"), "a dot means a dot")
        XCTAssertTrue(PackageStore.carries(version: "1.0.9", "BEETLE-RC1.0.9.fwsc"))
    }

    func testAWholeNumberVersionMustEndTheTag() {
        XCTAssertFalse(PackageStore.isVersion("1", tag: "v1.0.0", asset: "sid1-1.0.0.fwsc"))
        XCTAssertFalse(PackageStore.isVersion("1", tag: "1.2", asset: "zen-1-1.2.fwsc"))
        XCTAssertFalse(PackageStore.isVersion("1", tag: "v1.0.1", asset: "mnm1-1.0.1.fwsc"))
        XCTAssertTrue(PackageStore.isVersion("39", tag: "v39", asset: "quest.fwsc"))
        XCTAssertTrue(PackageStore.isVersion("39", tag: "V39", asset: "quest.fwsc"))
        XCTAssertTrue(PackageStore.isVersion("39", tag: "quest-39", asset: "fm1-quest-39.fwsc"), "FM1 Quest's real tags")
        XCTAssertFalse(PackageStore.isVersion("39", tag: "quest-139", asset: "q.fwsc"))
        XCTAssertFalse(PackageStore.isVersion("1", tag: "sid1", asset: "sid1.fwsc"), "part of a name")
        XCTAssertTrue(PackageStore.isVersion("2.8.3", tag: "other", asset: "sloop-2.8.3.fwsc"))
        XCTAssertTrue(PackageStore.isVersion("2.8.3", tag: "v2.8.3", asset: "sloop.fwsc"))
    }

    func testTwoBuildsOfAVersionAreNotPickedBetween() throws {
        let standard = try FWSCPackage(data: FWSCPackageTests.makePackage(product: "FM-1_920", payload: 1024))
        let oneCore = try FWSCPackage(data: FWSCPackageTests.makePackage(product: "FM-1_920", payload: 2048))
        XCTAssertEqual(PackageStore.theOnlyBuild(of: [standard])?.sha256, standard.sha256)
        XCTAssertEqual(PackageStore.theOnlyBuild(of: [standard, standard])?.sha256, standard.sha256)
        XCTAssertNil(PackageStore.theOnlyBuild(of: [oneCore, standard]))
        XCTAssertNil(PackageStore.theOnlyBuild(of: []))
    }

    func testACustomFirmwareOnAnOldOfficialNumberIsNotTheLatestOfficial() throws {
        let store = PackageStore.shared
        let custom = try FWSCPackage(data: FWSCPackageTests.makePackage(product: "FM-1_007", payload: 1024))
        let u = try store.keep(custom)
        defer { try? FileManager.default.removeItem(at: u) }
        XCTAssertNotEqual(store.newestCachedOfficial()?.product, "FM-1_007", "hawk-chua uses that number")
    }

    /// Every package installed is kept, files and custom firmwares too: one above V15 that only looks official (SPAMPY is
    /// FM-1_036, for the first FM-1s only) is never M-VAVE's own, offline or for the flash chip check.
    func testAKeptPackageThatOnlyLooksOfficialIsNotMVAVEs() throws {
        let store = PackageStore.shared
        let custom = try FWSCPackage(data: FWSCPackageTests.makePackage(product: "FM-1_036", payload: 1024))
        let u = try store.keep(custom)
        defer { try? FileManager.default.removeItem(at: u) }
        XCTAssertTrue(custom.isOfficial, "the number alone says official")
        XCTAssertFalse(store.isFetchedOfficial(custom.sha256))
        XCTAssertNotEqual(store.newestCachedOfficial()?.sha256, custom.sha256)
        XCTAssertTrue(store.isFetchedOfficial(FWSCPackage.stockV15SHA256), "the hub's V15 is pinned by its hash")
    }

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
