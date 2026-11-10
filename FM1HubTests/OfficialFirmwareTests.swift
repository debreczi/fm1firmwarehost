import XCTest
@testable import FM1Hub

/// M-VAVE's own firmware stays first on the Firmwares tab, and a search finds it by the words people use for it.
final class OfficialFirmwareTests: XCTestCase {
    func testAnEmptySearchShowsIt() {
        XCTAssertTrue(OfficialFirmware.matches("", latestVersion: nil))
        XCTAssertTrue(OfficialFirmware.matches("  ", latestVersion: "V16"))
    }

    func testItIsFoundByWhatItIsCalled() {
        for q in ["official", "M-VAVE", "mvave", "stock", "original", "factory", "recovery", "v15", "V16", "Official V16"] {
            XCTAssertTrue(OfficialFirmware.matches(q, latestVersion: "V16"), q)
        }
    }

    func testOtherSearchesHideIt() {
        for q in ["felucca", "drum", "v17", "official felucca"] {
            XCTAssertFalse(OfficialFirmware.matches(q, latestVersion: "V16"), q)
        }
    }

    func testTheLatestVersionIsFoundOnlyOnceKnown() {
        XCTAssertFalse(OfficialFirmware.matches("v16", latestVersion: nil))
        XCTAssertTrue(OfficialFirmware.matches("v17", latestVersion: "V17"))
    }
}
