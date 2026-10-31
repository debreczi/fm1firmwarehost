import XCTest
@testable import FM1Hub

/// Over twenty firmwares report FM-1_900. A backup must never take the first package with that identity for the firmware
/// that was on the device, so what can name one firmware among them is pinned down here.
@MainActor
final class SharedIdentityTests: XCTestCase {
    private static func entry(_ id: String, _ name: String, _ version: String, _ product: String, sha: String = "", installs: Int = 0) -> String {
        #"{"id":"\#(id)","name":"\#(name)","version":"\#(version)","pkg":"fw/\#(id).fwsc","product":"\#(product)","size":1,"sha256":"\#(sha)","installs":\#(installs)}"#
    }

    private func catalog(extra: [String] = []) -> CatalogStore {
        let list = [
            Self.entry("hortator", "Hortator", "0.26.0", "FM-1_900", installs: 50),
            Self.entry("hortator-bt", "Hortator (Bluetooth)", "0.26.0", "FM-1_900", installs: 40),
            Self.entry("sloop", "SLOOP", "2.8.4", "FM-1_900", installs: 10),
            Self.entry("floyd", "SLOOP Floyd FM", "2.4", "FM-1_924"),
            Self.entry("felucca", "Felucca", "1.8.0", "FM-1_918")
        ] + extra
        let c = CatalogStore()
        XCTAssertTrue(c.apply(Data(#"{"firmwares":[\#(list.joined(separator: ","))]}"#.utf8)))
        return c
    }

    // MARK: Who it is

    func testAnIdentityAloneNamesNoneOfThoseSharingIt() {
        let w = catalog().whoIs("FM-1_900")
        XCTAssertNil(w?.firmware)
        XCTAssertEqual(w?.exact, false)
        XCTAssertEqual(catalog().firmwares(reporting: "FM-1_900").count, 3)
    }

    func testTheFirmwaresOwnNameAndVersionNameIt() {
        let w = catalog().whoIs("FM-1_900", named: "SLOOP 2.8.4")
        XCTAssertEqual(w?.firmware?.id, "sloop")
        XCTAssertEqual(w?.exact, true)
        XCTAssertEqual(catalog().whoIs("FM-1_900", named: "sloop 2.8.4 ")?.firmware?.id, "sloop", "firmwares write their names their own way: CLIPPER 1.3")
    }

    func testAnythingLessNamesNone() {
        for said in ["SLOOP 2.4.1", "SLOOP", "2.8.4", "DRUM-DEV", "", "SLOOP Floyd FM 2.4"] {
            XCTAssertNil(catalog().whoIs("FM-1_900", named: said)?.firmware, said)
        }
        XCTAssertNil(catalog().whoIs("FM-1_900", named: nil)?.firmware)
    }

    func testAFirmwareCanNotBeNamedOutsideTheIdentityItReports() {
        XCTAssertNil(catalog().whoIs("FM-1_900", named: "Felucca 1.8.0")?.firmware)
    }

    func testTwoEntriesWithTheSameNameAndVersionNameNeither() {
        let c = catalog(extra: [Self.entry("sloop2", "SLOOP", "2.8.4", "FM-1_900")])
        XCTAssertNil(c.whoIs("FM-1_900", named: "SLOOP 2.8.4")?.firmware)
    }

    func testAnIdentityOfItsOwnStillNamesItsFirmware() {
        let w = catalog().whoIs("FM-1_918", named: "whatever it says")
        XCTAssertEqual(w?.firmware?.id, "felucca")
        XCTAssertEqual(w?.exact, true)
    }

    // MARK: The list to choose from

    func testTheLikeliestComeFirst() {
        let all = catalog().firmwares(reporting: "FM-1_900")
        XCTAssertEqual(Firmware.likeliestFirst(all, reported: nil, lastInstalled: nil).map(\.id), ["hortator", "hortator-bt", "sloop"], "the most installed first")
        XCTAssertEqual(Firmware.likeliestFirst(all, reported: nil, lastInstalled: "hortator-bt").first?.id, "hortator-bt")
        XCTAssertEqual(Firmware.likeliestFirst(all, reported: "SLOOP 2.4.1", lastInstalled: "hortator-bt").first?.id, "sloop", "what it calls itself counts for more")
    }

    // MARK: What a package file says

    private func withController(_ catalog: CatalogStore, _ body: (DeviceController, LibraryStore) throws -> Void) rethrows {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FM1HubSharedIdentity-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(folder: folder)
        try body(DeviceController(catalog: catalog, library: library, settings: AppSettings()), library)
    }

    /// Attaches a package from a file, as the Backups tab does, and takes the file and its cached copy away after.
    private func attach(_ data: Data, to s: Snapshot, device: DeviceController) throws {
        let pkg = try FWSCPackage(data: data)
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).fwsc")
        try data.write(to: file)
        defer {
            try? FileManager.default.removeItem(at: file)
            if let kept = try? PackageStore.shared.keep(pkg) { try? FileManager.default.removeItem(at: kept) }
        }
        XCTAssertNil(device.attachPackage(to: s, fileURL: file))
    }

    private func aBackup(identity: String, name: String = "one of 3 firmwares that report FM-1_900") -> Snapshot {
        Snapshot(name: "A backup", identity: identity, firmwareId: nil, firmwareName: name, version: nil, product: nil, packageFile: nil,
                 packageSHA256: nil, packageSize: nil, packageExact: false, archiveFile: nil, archiveBytes: nil, archiveObjects: nil)
    }

    func testAPackageOfASharedIdentityIsNotTakenForTheFirstFirmwareOrForExact() throws {
        let data = FWSCPackageTests.makePackage(product: "FM-1_900", payload: 1024)
        try withController(catalog()) { device, library in
            let s = aBackup(identity: "FM-1_900")
            library.add(s)
            try attach(data, to: s, device: device)
            let saved = try XCTUnwrap(library.snapshots.first)
            XCTAssertTrue(saved.hasPackage)
            XCTAssertFalse(saved.packageExact, "the identity says nothing about which firmware it is")
            XCTAssertNil(saved.packageConfirmed)
            XCTAssertNil(saved.firmwareId)
            XCTAssertNotEqual(saved.firmwareName, "Hortator", "not the first with that identity")
        }
    }

    func testAPackageTheCatalogueKnowsByItsHashIsNamedButNotConfirmed() throws {
        let data = FWSCPackageTests.makePackage(product: "FM-1_900", payload: 1024)
        let sha = try FWSCPackage(data: data).sha256
        try withController(catalog(extra: [Self.entry("clipper", "Clipper", "1.3", "FM-1_900", sha: sha)])) { device, library in
            let s = aBackup(identity: "FM-1_900")
            library.add(s)
            try attach(data, to: s, device: device)
            let saved = try XCTUnwrap(library.snapshots.first)
            XCTAssertEqual(saved.firmwareId, "clipper")
            XCTAssertEqual(saved.version, "1.3")
            XCTAssertFalse(saved.packageExact, "that this file is Clipper does not make Clipper what was on the device")
            XCTAssertNil(saved.packageConfirmed)
        }
    }

    func testAPackageOfAnIdentityOfItsOwnIsExact() throws {
        let data = FWSCPackageTests.makePackage(product: "FM-1_918", payload: 1024)
        try withController(catalog()) { device, library in
            let s = aBackup(identity: "FM-1_918", name: "Felucca")
            library.add(s)
            try attach(data, to: s, device: device)
            let saved = try XCTUnwrap(library.snapshots.first)
            XCTAssertTrue(saved.packageExact)
            XCTAssertEqual(saved.firmwareName, "Felucca")
        }
    }

    func testAPackageOfAnotherIdentityIsRefused() throws {
        let data = FWSCPackageTests.makePackage(product: "FM-1_918", payload: 1024)
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).fwsc")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try withController(catalog()) { device, library in
            let s = aBackup(identity: "FM-1_900")
            library.add(s)
            XCTAssertNotNil(device.attachPackage(to: s, fileURL: file))
            XCTAssertEqual(library.snapshots.first?.hasPackage, false)
        }
    }

    func testChoosingAFirmwareOfAnotherIdentityDoesNothing() throws {
        let c = catalog()
        try withController(c) { device, library in
            let s = aBackup(identity: "FM-1_900")
            library.add(s)
            device.attachFirmware(try XCTUnwrap(c.firmware(id: "felucca")), to: s)
            XCTAssertNil(device.job, "no job starts for a firmware that does not report this identity")
        }
    }
}
