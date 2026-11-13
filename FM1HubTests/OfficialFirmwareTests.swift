import XCTest
@testable import FM1Hub

/// M-VAVE's own firmware stays first on the Firmwares tab, and a search finds it by the words people use for it.
final class OfficialFirmwareTests: XCTestCase {
    func testAnEmptySearchShowsIt() {
        XCTAssertTrue(OfficialFirmware.matches("", latest: nil))
        XCTAssertTrue(OfficialFirmware.matches("  ", latest: "FM-1_016"))
    }

    func testItIsFoundByWhatItIsCalled() {
        for q in ["official", "Official firmware", "firmware", "M-VAVE", "mvave", "stock", "original", "factory", "recovery",
                  "fm-1", "fm1", "FM-1_015", "FM-1_016", "v15", "V16", "Official V16", "M-VAVE's", "M-VAVE\u{2019}s firmware",
                  "latest", "current", "update", "recovery image", "back to v15", "known-good"] {
            XCTAssertTrue(OfficialFirmware.matches(q, latest: "FM-1_016"), q)
        }
    }

    func testOtherSearchesHideIt() {
        for q in ["felucca", "drum", "v17", "FM-1_017", "official felucca"] {
            XCTAssertFalse(OfficialFirmware.matches(q, latest: "FM-1_016"), q)
        }
    }

    func testTheLatestVersionIsFoundOnlyOnceKnown() {
        XCTAssertFalse(OfficialFirmware.matches("v16", latest: nil))
        XCTAssertFalse(OfficialFirmware.matches("fm-1_016", latest: nil))
        XCTAssertTrue(OfficialFirmware.matches("v17", latest: "FM-1_017"))
    }
}
