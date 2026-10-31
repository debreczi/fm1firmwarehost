import XCTest
@testable import FM1Hub

/// `isFinished(by:)` is how the app finds out, from any later connection, that an interrupted update actually
/// landed: the device is running what the record meant to put there. Get it wrong one way and a stale record waits
/// to offer an obsolete package; wrong the other way and the exact record of a half-written update is thrown away.
final class PendingUpdateTests: XCTestCase {

    /// An upgrade: the device was running something else when the attempt started.
    private let upgrade = PendingUpdate(product: "FM-1_904", sha256: "beefbeef", firmwareId: "melodee",
                                        name: "Melodee", version: "2.0", usesStockLoader: false, source: .hub,
                                        identityBefore: "FM-1_900")

    private func identity(_ text: String) -> FM1Identity {
        guard let id = FM1Identity.parse(text: text) else { preconditionFailure("\(text) is not an identity") }
        return id
    }

    func testTheDeviceRunningThePendingFirmwareMeansItIsFinished() {
        XCTAssertTrue(upgrade.isFinished(by: identity("FM-1_904")))
    }

    func testAnotherFirmwareDoesNotFinishIt() {
        XCTAssertFalse(upgrade.isFinished(by: identity("FM-1_900")), "the old firmware is still on the device")
        XCTAssertFalse(upgrade.isFinished(by: identity("FM-1_015")))
    }

    /// A loader reporting the same number is the half-written state, not the finished one.
    func testALoaderNeverFinishesIt() {
        let loader = identity("ota-FM-1_904")
        XCTAssertTrue(loader.isLoader)
        XCTAssertFalse(upgrade.isFinished(by: loader), "a waiting loader is exactly what has to be resumed")
    }

    /// The case the identity cannot settle: a rebuilt package of the firmware already on the device. Both builds
    /// report FM-1_904 and differ only by hash, so the running identity proves nothing and the record must stay.
    func testARebuildOfWhatIsAlreadyOnTheDeviceIsNeverDeclaredFinished() {
        let rebuild = PendingUpdate(product: "FM-1_904", sha256: "0000beef", firmwareId: "melodee", name: "Melodee",
                                    version: "2.1", usesStockLoader: false, source: .hub,
                                    identityBefore: "FM-1_904")
        XCTAssertFalse(rebuild.isFinished(by: identity("FM-1_904")),
                       "the device reported this identity before the attempt too: which build is on it is unknown")
    }

    /// Not having known what was running is the same kind of ignorance.
    func testAnUnknownIdentityBeforeIsNeverDeclaredFinished() {
        var blind = upgrade
        blind.identityBefore = nil
        XCTAssertFalse(blind.isFinished(by: identity("FM-1_904")))
    }

    func testTheOfficialFirmwareCase() {
        let official = PendingUpdate(product: "FM-1_016", sha256: "cafe", firmwareId: nil, name: "Official firmware",
                                     version: "V16", usesStockLoader: true, source: .stock,
                                     identityBefore: "FM-1_015")
        XCTAssertTrue(official.isFinished(by: identity("FM-1_016")))
        XCTAssertFalse(official.isFinished(by: identity("FM-1_015")), "still on the version before")
    }
}
