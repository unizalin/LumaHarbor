import XCTest
@testable import RawProcessingCore

final class HSLAdjustmentsTests: XCTestCase {
    func testNeutralIsAllZeroesAndIdentity() {
        let neutral = HSLAdjustments.neutral
        for band in [neutral.red, neutral.orange, neutral.yellow, neutral.green,
                     neutral.aqua, neutral.blue, neutral.purple, neutral.magenta] {
            XCTAssertEqual(band.hue, 0)
            XCTAssertEqual(band.saturation, 0)
            XCTAssertEqual(band.luminance, 0)
        }
        XCTAssertTrue(neutral.isIdentity)
    }

    func testOneBandOffZeroBreaksIdentity() {
        var adjustments = HSLAdjustments.neutral
        adjustments.red.hue = 10
        XCTAssertFalse(adjustments.isIdentity)
    }

    func testBandClampsToPlusMinus100() {
        let band = HSLBand(hue: 500, saturation: -500, luminance: 999)
        XCTAssertEqual(band.hue, 100)
        XCTAssertEqual(band.saturation, -100)
        XCTAssertEqual(band.luminance, 100)
    }

    func testRoundTripsThroughJSON() throws {
        var original = HSLAdjustments.neutral
        original.aqua = HSLBand(hue: -30, saturation: 40, luminance: -10)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HSLAdjustments.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMissingColorKeyFallsBackToNeutralBand() throws {
        let json = Data(#"{"red": {"hue": 20, "saturation": 0, "luminance": 0}}"#.utf8)
        let decoded = try JSONDecoder().decode(HSLAdjustments.self, from: json)
        XCTAssertEqual(decoded.red.hue, 20)
        XCTAssertEqual(decoded.orange, HSLBand())
    }

    func testEncodesAllEightColorKeys() throws {
        let data = try JSONEncoder().encode(HSLAdjustments.neutral)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
        )
    }
}
