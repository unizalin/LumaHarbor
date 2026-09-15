import XCTest
@testable import RawProcessingCore

final class MonochromeAdjustmentsTests: XCTestCase {
    func testNeutralIsIdentity() {
        let neutral = MonochromeAdjustments.neutral
        XCTAssertFalse(neutral.isEnabled)
        XCTAssertEqual(neutral.red, 0)
        XCTAssertEqual(neutral.magenta, 0)
        XCTAssertTrue(neutral.isIdentity)
    }

    func testIdentityIsDeterminedOnlyByEnabledFlag() {
        // Disabled must stay identity even with non-zero mix values queued up
        // for when the user re-enables it -- colour adjustments must not be
        // affected while disabled (spec §6.3: "停用時保留彩色調整").
        var disabledWithMix = MonochromeAdjustments.neutral
        disabledWithMix.red = 80
        disabledWithMix.blue = -50
        XCTAssertTrue(disabledWithMix.isIdentity)

        var enabled = MonochromeAdjustments.neutral
        enabled.isEnabled = true
        XCTAssertFalse(enabled.isIdentity)
    }

    func testClampsEveryBandToDocumentedRange() {
        var m = MonochromeAdjustments(
            isEnabled: true, red: 999, orange: -999, yellow: 999, green: -999,
            aqua: 999, blue: -999, purple: 999, magenta: -999
        )
        XCTAssertEqual(m.red, 100)
        XCTAssertEqual(m.orange, -100)
        XCTAssertEqual(m.yellow, 100)
        XCTAssertEqual(m.green, -100)
        XCTAssertEqual(m.aqua, 100)
        XCTAssertEqual(m.blue, -100)
        XCTAssertEqual(m.purple, 100)
        XCTAssertEqual(m.magenta, -100)
        m.red = 500
        XCTAssertEqual(m.red, 100)
    }

    func testRoundTripsThroughJSON() throws {
        let original = MonochromeAdjustments(
            isEnabled: true, red: 20, orange: -10, yellow: 5, green: -5,
            aqua: 15, blue: -15, purple: 25, magenta: -25
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(MonochromeAdjustments.self, from: data), original)
    }

    func testMissingKeysFallBackToNeutral() throws {
        XCTAssertEqual(try JSONDecoder().decode(MonochromeAdjustments.self, from: Data("{}".utf8)), .neutral)
    }
}
