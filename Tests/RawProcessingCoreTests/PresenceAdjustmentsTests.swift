import XCTest
@testable import RawProcessingCore

final class PresenceAdjustmentsTests: XCTestCase {
    func testNeutralIsIdentity() {
        let neutral = PresenceAdjustments.neutral
        XCTAssertEqual(neutral.texture, 0)
        XCTAssertEqual(neutral.clarity, 0)
        XCTAssertEqual(neutral.dehaze, 0)
        XCTAssertTrue(neutral.isIdentity)
    }

    func testAnyNonZeroFieldBreaksIdentity() {
        XCTAssertFalse(PresenceAdjustments(texture: 1).isIdentity)
        XCTAssertFalse(PresenceAdjustments(clarity: 1).isIdentity)
        XCTAssertFalse(PresenceAdjustments(dehaze: 1).isIdentity)
    }

    func testClampsToDocumentedRanges() {
        let p = PresenceAdjustments(texture: 999, clarity: -999, dehaze: 999)
        XCTAssertEqual(p.texture, 100)
        XCTAssertEqual(p.clarity, -100)
        XCTAssertEqual(p.dehaze, 100)
    }

    func testRoundTripsThroughJSON() throws {
        let original = PresenceAdjustments(texture: 30, clarity: -20, dehaze: 50)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(PresenceAdjustments.self, from: data), original)
    }

    func testMissingKeysFallBackToNeutral() throws {
        XCTAssertEqual(try JSONDecoder().decode(PresenceAdjustments.self, from: Data("{}".utf8)), .neutral)
    }
}
