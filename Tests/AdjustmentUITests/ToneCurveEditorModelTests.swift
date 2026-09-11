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

    func testNearestPointCanRequireAHitRadius() {
        let points = ToneCurveMapping.identity

        XCTAssertEqual(
            ToneCurveEditorModel.nearestPointIndex(
                in: points,
                to: CGPoint(x: 49, y: 51),
                in: CGSize(width: 100, height: 100),
                maximumDistance: 5
            ),
            2
        )
        XCTAssertNil(
            ToneCurveEditorModel.nearestPointIndex(
                in: points,
                to: CGPoint(x: 10, y: 10),
                in: CGSize(width: 100, height: 100),
                maximumDistance: 5
            )
        )
    }

    func testInsertingPointAddsAnOrderedTouchTargetInsideTheCurve() {
        let inserted = ToneCurveEditorModel.insertingPoint(
            ToneCurveMapping.identity,
            at: CGPoint(x: 60, y: 25),
            in: CGSize(width: 100, height: 100)
        )

        XCTAssertEqual(inserted.count, 6)
        XCTAssertTrue(zip(inserted, inserted.dropFirst()).allSatisfy { $0.x < $1.x })
        XCTAssertEqual(inserted[3], ToneCurvePoint(x: 0.6, y: 0.75))
    }

    func testInsertingPointRejectsEndpointsAndDuplicateXValues() {
        let points = ToneCurveMapping.identity

        XCTAssertEqual(
            ToneCurveEditorModel.insertingPoint(points, at: CGPoint(x: 0, y: 50), in: CGSize(width: 100, height: 100)),
            points
        )
        XCTAssertEqual(
            ToneCurveEditorModel.insertingPoint(points, at: CGPoint(x: 50, y: 50), in: CGSize(width: 100, height: 100)),
            points
        )
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

    // MARK: - Delete (visual polish spec §5.1)

    func testDeletingPointRemovesAnInteriorPoint() {
        let points = ToneCurveMapping.identity
        let deleted = ToneCurveEditorModel.deletingPoint(points, at: 2)

        XCTAssertEqual(deleted.count, 4)
        XCTAssertFalse(deleted.contains(points[2]))
    }

    func testDeletingPointRejectsEndpoints() {
        let points = ToneCurveMapping.identity

        XCTAssertEqual(ToneCurveEditorModel.deletingPoint(points, at: 0), points)
        XCTAssertEqual(ToneCurveEditorModel.deletingPoint(points, at: points.count - 1), points)
    }

    func testDeletingPointRefusesToLeaveFewerThanTwoPoints() {
        let points = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.5), ToneCurvePoint(x: 1, y: 1)]
        let deleted = ToneCurveEditorModel.deletingPoint(points, at: 1)
        XCTAssertEqual(deleted.count, 2)

        // Only two points left -- the middle one is already gone, and there
        // is no longer an interior point to delete at all.
        XCTAssertEqual(ToneCurveEditorModel.deletingPoint(deleted, at: 0), deleted)
    }

    func testCanDeletePointMatchesDeletingPointOutcome() {
        let points = ToneCurveMapping.identity
        for index in points.indices {
            XCTAssertEqual(
                ToneCurveEditorModel.canDeletePoint(points, at: index),
                ToneCurveEditorModel.deletingPoint(points, at: index).count < points.count
            )
        }
    }

    // MARK: - VoiceOver "Add Control Point" (visual polish spec §5.3)

    func testInsertingAtLargestGapUsesTheWidestSpanBetweenPoints() {
        let points = [
            ToneCurvePoint(x: 0, y: 0),
            ToneCurvePoint(x: 0.1, y: 0.1),
            ToneCurvePoint(x: 0.9, y: 0.9),
            ToneCurvePoint(x: 1, y: 1),
        ]

        let inserted = ToneCurveEditorModel.insertingAtLargestGap(points)

        XCTAssertEqual(inserted.count, 5)
        XCTAssertEqual(inserted[2], ToneCurvePoint(x: 0.5, y: 0.5))
        XCTAssertTrue(zip(inserted, inserted.dropFirst()).allSatisfy { $0.x < $1.x })
    }

    func testInsertingAtLargestGapIsANoOpWithFewerThanTwoPoints() {
        XCTAssertEqual(ToneCurveEditorModel.insertingAtLargestGap([]), [])
        let single = [ToneCurvePoint(x: 0.5, y: 0.5)]
        XCTAssertEqual(ToneCurveEditorModel.insertingAtLargestGap(single), single)
    }
}
