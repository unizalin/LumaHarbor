import XCTest
@testable import RawProcessingCore

final class AdvancedToneCurveTests: XCTestCase {
    func testNeutralIsEmptyAndIdentity() {
        XCTAssertTrue(AdvancedToneCurve.neutral.points.isEmpty)
        XCTAssertTrue(AdvancedToneCurve.neutral.isIdentity)
    }

    func testNonEmptyPointsIsNotIdentity() {
        let curve = AdvancedToneCurve(points: [ToneCurvePoint(x: 0.5, y: 0.6)])
        XCTAssertFalse(curve.isIdentity)
    }

    func testRoundTripsThroughJSON() throws {
        let original = AdvancedToneCurve(points: [
            ToneCurvePoint(x: 0, y: 0),
            ToneCurvePoint(x: 0.5, y: 0.7),
            ToneCurvePoint(x: 1, y: 1)
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AdvancedToneCurve.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMissingKeyFallsBackToNeutral() throws {
        let decoded = try JSONDecoder().decode(AdvancedToneCurve.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, .neutral)
    }

    // MARK: - Per-channel (P3)

    func testNeutralIsIdentityOnAllFourChannels() {
        for channel in ToneCurveChannel.allCases {
            XCTAssertTrue(AdvancedToneCurve.neutral.isIdentity(for: channel))
            XCTAssertTrue(AdvancedToneCurve.neutral.points(for: channel).isEmpty)
        }
    }

    func testSettingOneChannelDoesNotAffectOthers() {
        let curve = AdvancedToneCurve.neutral.settingPoints(
            [ToneCurvePoint(x: 0.2, y: 0.8)], for: .red
        )
        XCTAssertFalse(curve.isIdentity(for: .red))
        XCTAssertTrue(curve.isIdentity(for: .composite))
        XCTAssertTrue(curve.isIdentity(for: .green))
        XCTAssertTrue(curve.isIdentity(for: .blue))
        XCTAssertFalse(curve.isIdentity) // whole-curve identity requires all four
        XCTAssertEqual(curve.points(for: .red), [ToneCurvePoint(x: 0.2, y: 0.8)])
    }

    func testSettingCompositeChannelWritesLegacyPointsProperty() {
        let curve = AdvancedToneCurve.neutral.settingPoints(
            [ToneCurvePoint(x: 0.1, y: 0.2)], for: .composite
        )
        XCTAssertEqual(curve.points, [ToneCurvePoint(x: 0.1, y: 0.2)])
    }

    func testResettingOneChannelClearsOnlyThatChannel() {
        var curve = AdvancedToneCurve.neutral
        curve = curve.settingPoints([ToneCurvePoint(x: 0.3, y: 0.4)], for: .red)
        curve = curve.settingPoints([ToneCurvePoint(x: 0.5, y: 0.6)], for: .green)
        let afterReset = curve.resetting(.red)
        XCTAssertTrue(afterReset.isIdentity(for: .red))
        XCTAssertFalse(afterReset.isIdentity(for: .green))
    }

    func testAllFourChannelsRoundTripThroughJSON() throws {
        let original = AdvancedToneCurve(
            points: [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)],
            redPoints: [ToneCurvePoint(x: 0, y: 0.1), ToneCurvePoint(x: 1, y: 0.9)],
            greenPoints: [ToneCurvePoint(x: 0, y: 0.2), ToneCurvePoint(x: 1, y: 0.8)],
            bluePoints: [ToneCurvePoint(x: 0, y: 0.3), ToneCurvePoint(x: 1, y: 0.7)]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AdvancedToneCurve.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testLegacyJSONWithOnlyPointsKeyDecodesOtherChannelsAsIdentity() throws {
        let legacyJSON = """
        {"points":[{"x":0,"y":0},{"x":0.5,"y":0.7},{"x":1,"y":1}]}
        """
        let decoded = try JSONDecoder().decode(AdvancedToneCurve.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.points, [
            ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.7), ToneCurvePoint(x: 1, y: 1)
        ])
        XCTAssertTrue(decoded.isIdentity(for: .red))
        XCTAssertTrue(decoded.isIdentity(for: .green))
        XCTAssertTrue(decoded.isIdentity(for: .blue))
    }

    func testIsIdentityRequiresAllFourChannelsEmpty() {
        let onlyRed = AdvancedToneCurve.neutral.settingPoints([ToneCurvePoint(x: 0.1, y: 0.9)], for: .red)
        XCTAssertFalse(onlyRed.isIdentity)
        XCTAssertTrue(AdvancedToneCurve.neutral.isIdentity)
    }
}
