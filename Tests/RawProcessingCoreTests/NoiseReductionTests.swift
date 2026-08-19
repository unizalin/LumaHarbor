import XCTest
@testable import RawProcessingCore

final class NoiseReductionTests: XCTestCase {
    func testNeutralIsLumaAndColorZeroNotLightroomDefaults() {
        // Spec §3.5: "neutral" means LumaHarbor does nothing, not "mimic
        // Lightroom's own new-photo default" (which has colorAmount = 25).
        let neutral = NoiseReduction.neutral
        XCTAssertEqual(neutral.luminanceAmount, 0)
        XCTAssertEqual(neutral.colorAmount, 0)
        XCTAssertEqual(neutral.luminanceDetail, 50)
        XCTAssertEqual(neutral.colorDetail, 50)
        XCTAssertTrue(neutral.isIdentity)
    }

    func testEitherAmountNonZeroBreaksIdentity() {
        XCTAssertFalse(NoiseReduction(luminanceAmount: 1).isIdentity)
        XCTAssertFalse(NoiseReduction(colorAmount: 1).isIdentity)
    }

    func testClampsToZeroTo100() {
        let n = NoiseReduction(luminanceAmount: 500, luminanceDetail: -5, colorAmount: 500, colorDetail: -5)
        XCTAssertEqual(n.luminanceAmount, 100)
        XCTAssertEqual(n.luminanceDetail, 0)
        XCTAssertEqual(n.colorAmount, 100)
        XCTAssertEqual(n.colorDetail, 0)
    }

    func testRoundTripsThroughJSON() throws {
        let original = NoiseReduction(luminanceAmount: 40, luminanceDetail: 60, colorAmount: 20, colorDetail: 70)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(NoiseReduction.self, from: data), original)
    }

    func testMissingKeysFallBackToNeutral() throws {
        XCTAssertEqual(try JSONDecoder().decode(NoiseReduction.self, from: Data("{}".utf8)), .neutral)
    }
}
