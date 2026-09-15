import XCTest
@testable import RawProcessingCore

final class ColorGradingAdjustmentsTests: XCTestCase {
    func testNeutralIsIdentity() {
        let neutral = ColorGradingAdjustments.neutral
        XCTAssertEqual(neutral.shadows, ColorGradeBand(hue: 0, saturation: 0, luminance: 0))
        XCTAssertEqual(neutral.midtones, ColorGradeBand(hue: 0, saturation: 0, luminance: 0))
        XCTAssertEqual(neutral.highlights, ColorGradeBand(hue: 0, saturation: 0, luminance: 0))
        XCTAssertEqual(neutral.global, ColorGradeBand(hue: 0, saturation: 0, luminance: 0))
        XCTAssertEqual(neutral.balance, 0)
        XCTAssertEqual(neutral.blending, 50)
        XCTAssertTrue(neutral.isIdentity)
    }

    func testHueAloneDoesNotBreakIdentityButSaturationDoes() {
        // Same convention as SplitToning: hue is meaningless at saturation 0.
        var withHueOnly = ColorGradingAdjustments.neutral
        withHueOnly.shadows.hue = 200
        XCTAssertTrue(withHueOnly.isIdentity)

        var withSaturation = ColorGradingAdjustments.neutral
        withSaturation.highlights.saturation = 10
        XCTAssertFalse(withSaturation.isIdentity)
    }

    func testEachBandBreaksIdentityIndependently() {
        var g = ColorGradingAdjustments.neutral
        g.midtones.saturation = 5
        XCTAssertFalse(g.isIdentity)
        g = ColorGradingAdjustments.neutral
        g.global.saturation = 5
        XCTAssertFalse(g.isIdentity)
    }

    func testClampsToDocumentedRanges() {
        var band = ColorGradeBand(hue: 999, saturation: 999, luminance: 999)
        XCTAssertEqual(band.hue, 360)
        XCTAssertEqual(band.saturation, 100)
        XCTAssertEqual(band.luminance, 100)
        band = ColorGradeBand(hue: -999, saturation: -999, luminance: -999)
        XCTAssertEqual(band.hue, 0)
        XCTAssertEqual(band.saturation, 0)
        XCTAssertEqual(band.luminance, -100)

        var g = ColorGradingAdjustments.neutral
        g.balance = 999
        XCTAssertEqual(g.balance, 100)
        g.blending = -999
        XCTAssertEqual(g.blending, 0)
    }

    func testRoundTripsThroughJSON() throws {
        var original = ColorGradingAdjustments.neutral
        original.shadows = ColorGradeBand(hue: 220, saturation: 30, luminance: -10)
        original.highlights = ColorGradeBand(hue: 40, saturation: 20, luminance: 5)
        original.balance = -15
        original.blending = 70
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ColorGradingAdjustments.self, from: data), original)
    }

    func testMissingKeysFallBackToNeutral() throws {
        XCTAssertEqual(try JSONDecoder().decode(ColorGradingAdjustments.self, from: Data("{}".utf8)), .neutral)
    }
}
