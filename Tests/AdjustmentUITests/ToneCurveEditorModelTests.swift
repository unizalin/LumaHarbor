import CoreGraphics
import XCTest
@testable import AdjustmentUI
import RawProcessingCore

final class ToneCurveEditorModelTests: XCTestCase {
    func testIdentityCurveProvidesFiveTouchTargets() {
        XCTAssertEqual(ToneCurveEditorModel.points(for: .neutral).count, 5)
        XCTAssertEqual(ToneCurveEditorModel.points(for: .neutral).first, ToneCurvePoint(x: 0, y: 0))
        XCTAssertEqual(ToneCurveEditorModel.points(for: .neutral).last, ToneCurvePoint(x: 1, y: 1))
    }

    func testMovingPointClampsToGraphAndKeepsXOrdering() {
        let points = ToneCurveMapping.identity
        let moved = ToneCurveEditorModel.movingPoint(
            points,
            at: 2,
            to: CGPoint(x: 10_000, y: -100),
            in: CGSize(width: 100, height: 100)
        )

        XCTAssertEqual(moved[2].x, points[3].x - 0.01, accuracy: 0.0001)
        XCTAssertEqual(moved[2].y, 1, accuracy: 0.0001)
        XCTAssertTrue(zip(moved, moved.dropFirst()).allSatisfy { $0.x < $1.x })
    }

    func testNearestPointUsesScreenCoordinates() {
        let index = ToneCurveEditorModel.nearestPointIndex(
            in: ToneCurveMapping.identity,
            to: CGPoint(x: 49, y: 51),
            in: CGSize(width: 100, height: 100)
        )

        XCTAssertEqual(index, 2)
    }

    // MARK: - Per-channel (P3)

    func testPointsForChannelReturnsOnlyThatChannelsCurve() {
        let curve = AdvancedToneCurve.neutral.settingPoints(
            [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.2), ToneCurvePoint(x: 1, y: 1)],
            for: .red
        )
        XCTAssertEqual(ToneCurveEditorModel.points(for: curve, channel: .red).count, 3)
        // An identity channel with no user-added points still needs 5 draggable
        // handles, same as the whole-curve identity case.
        XCTAssertEqual(ToneCurveEditorModel.points(for: curve, channel: .green), ToneCurveMapping.identity)
        XCTAssertEqual(ToneCurveEditorModel.points(for: curve, channel: .composite), ToneCurveMapping.identity)
    }

    func testPointsForChannelDefaultsToComposite() {
        // Existing call sites (predating per-channel curves) omit `channel`.
        XCTAssertEqual(ToneCurveEditorModel.points(for: .neutral), ToneCurveEditorModel.points(for: .neutral, channel: .composite))
    }
}
