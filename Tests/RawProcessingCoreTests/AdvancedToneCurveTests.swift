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
}
