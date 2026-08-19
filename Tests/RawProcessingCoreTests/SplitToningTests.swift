import XCTest
@testable import RawProcessingCore

final class SplitToningTests: XCTestCase {
    func testNeutralIsIdentity() {
        XCTAssertTrue(SplitToning.neutral.isIdentity)
    }

    func testBothSaturationsZeroIsIdentityRegardlessOfHueOrBalance() {
        // Spec §3.3: hue/balance are meaningless at zero saturation.
        let splitToning = SplitToning(
            shadowHue: 180, shadowSaturation: 0,
            highlightHue: 90, highlightSaturation: 0, balance: 50
        )
        XCTAssertTrue(splitToning.isIdentity)
    }

    func testEitherSaturationNonZeroBreaksIdentity() {
        XCTAssertFalse(SplitToning(shadowSaturation: 10).isIdentity)
        XCTAssertFalse(SplitToning(highlightSaturation: 10).isIdentity)
    }

    func testHueClampsTo0To360AndSaturationTo0To100() {
        let splitToning = SplitToning(
            shadowHue: -10, shadowSaturation: 200,
            highlightHue: 999, highlightSaturation: -5, balance: 0
        )
        XCTAssertEqual(splitToning.shadowHue, 0)
        XCTAssertEqual(splitToning.shadowSaturation, 100)
        XCTAssertEqual(splitToning.highlightHue, 360)
        XCTAssertEqual(splitToning.highlightSaturation, 0)
    }

    func testBalanceClampsToPlusMinus100() {
        XCTAssertEqual(SplitToning(balance: 500).balance, 100)
        XCTAssertEqual(SplitToning(balance: -500).balance, -100)
    }

    func testRoundTripsThroughJSON() throws {
        let original = SplitToning(
            shadowHue: 210, shadowSaturation: 30,
            highlightHue: 45, highlightSaturation: 20, balance: -15
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SplitToning.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMissingKeysFallBackToNeutral() throws {
        let decoded = try JSONDecoder().decode(SplitToning.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, .neutral)
    }
}
