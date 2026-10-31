import XCTest
@testable import FM1Hub

/// `nothingWritten` decides whether an interrupted update's recovery record is kept or put back, so a wrong answer
/// here either loses the record of a half-written firmware or leaves a misleading one behind.
final class FM1ErrorTests: XCTestCase {

    func testOnlyPreflightFailuresClaimNothingWasWritten() {
        XCTAssertTrue(FM1Error.notFound("").nothingWritten, "no FM-1 answered at all")
        XCTAssertTrue(FM1Error.model("").nothingWritten, "the device is another model")
        XCTAssertTrue(FM1Error.foreign("").nothingWritten, "it is in another firmware's loader")
        XCTAssertTrue(FM1Error.package("").nothingWritten, "the package was refused before the device was touched")

        XCTAssertFalse(FM1Error.stopped("").nothingWritten, "step 2 cannot be told from step 1: keep the record")
        XCTAssertFalse(FM1Error.lost("").nothingWritten)
        XCTAssertFalse(FM1Error.noLoader("").nothingWritten, "step 1 did run")
        XCTAssertFalse(FM1Error.noReturn("").nothingWritten, "the image went down, the device did not come back")
        XCTAssertFalse(FM1Error.mismatch("").nothingWritten, "something was written, just not what was expected")
        XCTAssertFalse(FM1Error.badRequest("").nothingWritten)
        XCTAssertFalse(FM1Error.protocolError("").nothingWritten)
        XCTAssertFalse(FM1Error.cancelled.nothingWritten, "a cancel can land in the middle of a write")
    }

    func testEveryErrorHasItsOwnCodeAndSomethingToSay() {
        let all: [FM1Error] = [.notFound("a"), .model("a"), .stopped("a"), .lost("a"), .noLoader("a"),
                               .noReturn("a"), .mismatch("a"), .badRequest("a"), .foreign("a"), .package("a"),
                               .protocolError("a"), .midi("a"), .cancelled]
        XCTAssertEqual(Set(all.map(\.code)).count, all.count, "the UI hints off these codes, so they must be distinct")
        for e in all {
            XCTAssertFalse((e.errorDescription ?? "").isEmpty, "\(e.code) has no message")
        }
    }
}
