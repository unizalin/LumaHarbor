import CoreGraphics
import XCTest
@testable import LumaHarborApp
@testable import RawProcessingCore

/// Phase 4 Task 4.3: pins the direction/range/position math of both linear
/// gradient drag handles before `LinearGradientOverlayView` ever renders a
/// pixel, matching `CropDragMathTests`'s own reasoning -- "UI 正負方向必須用
/// 真人或 screenshot fixture 驗證，不能只用數學座標直覺決定" applies here too,
/// so every case states the expected direction explicitly.
final class LinearGradientDragMathTests: XCTestCase {
    private let frame = CGSize(width: 200, height: 100)

    // MARK: - Position handle

    func testPositionDragMovesXAndYByTheNormalizedTranslation() {
        let base = LocalAdjustmentGeometry(x: 0.3, y: 0.4)
        let result = LinearGradientDragMath.updatedPosition(
            base: base, translation: CGSize(width: 20, height: 10), imageFrameSize: frame
        )
        XCTAssertEqual(result.x, 0.4, accuracy: 0.0001, "20pt / 200pt width = 0.1 normalized")
        XCTAssertEqual(result.y, 0.5, accuracy: 0.0001, "10pt / 100pt height = 0.1 normalized")
    }

    func testPositionDragLeavesAngleRangeAndFeatherUntouched() {
        let base = LocalAdjustmentGeometry(x: 0.5, y: 0.5, angleDegrees: 45, range: 0.3, feather: 20)
        let result = LinearGradientDragMath.updatedPosition(
            base: base, translation: CGSize(width: 5, height: 5), imageFrameSize: frame
        )
        XCTAssertEqual(result.angleDegrees, 45)
        XCTAssertEqual(result.range, 0.3)
        XCTAssertEqual(result.feather, 20)
    }

    func testPositionDragClampsAtTheUnitSquareEdgeRatherThanLeavingTheCanvas() {
        let base = LocalAdjustmentGeometry(x: 0.1, y: 0.1)
        let result = LinearGradientDragMath.updatedPosition(
            base: base, translation: CGSize(width: -1_000, height: -1_000), imageFrameSize: frame
        )
        XCTAssertEqual(result.x, 0, accuracy: 0.0001)
        XCTAssertEqual(result.y, 0, accuracy: 0.0001)
    }

    func testPositionDragWithAZeroSizeFrameIsANoOp() {
        let base = LocalAdjustmentGeometry(x: 0.5, y: 0.5)
        let result = LinearGradientDragMath.updatedPosition(
            base: base, translation: CGSize(width: 20, height: 20), imageFrameSize: .zero
        )
        XCTAssertEqual(result, base)
    }

    // MARK: - Direction handle

    func testDraggingTheTipToTheRightSetsAngleZero() {
        let base = LocalAdjustmentGeometry(angleDegrees: 90, range: 0.1)
        let result = LinearGradientDragMath.updatedDirection(
            base: base, anchorToTipTranslation: CGVector(dx: 50, dy: 0), imageFrameSize: frame
        )
        XCTAssertEqual(result.angleDegrees, 0, accuracy: 0.01)
    }

    func testDraggingTheTipDownwardSetsAngleNinety() {
        // SwiftUI is y-down, and `LocalAdjustmentGeometry.angleDegrees`'s own
        // documented convention is "0 grows right, 90 grows toward the
        // visual bottom" -- dragging straight down must read as +90, not -90.
        let base = LocalAdjustmentGeometry(angleDegrees: 0, range: 0.1)
        let result = LinearGradientDragMath.updatedDirection(
            base: base, anchorToTipTranslation: CGVector(dx: 0, dy: 50), imageFrameSize: frame
        )
        XCTAssertEqual(result.angleDegrees, 90, accuracy: 0.01)
    }

    func testDraggingTheTipUpwardSetsAngleNegativeNinety() {
        let base = LocalAdjustmentGeometry(angleDegrees: 0, range: 0.1)
        let result = LinearGradientDragMath.updatedDirection(
            base: base, anchorToTipTranslation: CGVector(dx: 0, dy: -50), imageFrameSize: frame
        )
        XCTAssertEqual(result.angleDegrees, -90, accuracy: 0.01)
    }

    func testDraggingTheTipToTheLeftSetsAngle180() {
        let base = LocalAdjustmentGeometry(angleDegrees: 0, range: 0.1)
        let result = LinearGradientDragMath.updatedDirection(
            base: base, anchorToTipTranslation: CGVector(dx: -50, dy: 0), imageFrameSize: frame
        )
        XCTAssertEqual(abs(result.angleDegrees), 180, accuracy: 0.01)
    }

    func testRangeIsTheTipDistanceNormalizedToHalfTheFrameDiagonal() {
        let base = LocalAdjustmentGeometry(range: 0.1)
        // frame diagonal = sqrt(200^2 + 100^2) ~= 223.6; half ~= 111.8
        let result = LinearGradientDragMath.updatedDirection(
            base: base, anchorToTipTranslation: CGVector(dx: 111.8, dy: 0), imageFrameSize: frame
        )
        XCTAssertEqual(result.range, 1.0, accuracy: 0.01)
    }

    func testATinyDragBelowTheMinimumLeavesTheAngleAloneRatherThanSnappingToZero() {
        let base = LocalAdjustmentGeometry(angleDegrees: 137, range: 0.1)
        let result = LinearGradientDragMath.updatedDirection(
            base: base, anchorToTipTranslation: CGVector(dx: 0.2, dy: 0.1), imageFrameSize: frame, minimumDragPoints: 1
        )
        XCTAssertEqual(result.angleDegrees, 137, "a near-zero-length drag must not snap the angle to atan2(0,0)'s arbitrary result")
    }

    func testDirectionDragLeavesPositionAndFeatherUntouched() {
        let base = LocalAdjustmentGeometry(x: 0.2, y: 0.3, feather: 40)
        let result = LinearGradientDragMath.updatedDirection(
            base: base, anchorToTipTranslation: CGVector(dx: 30, dy: 30), imageFrameSize: frame
        )
        XCTAssertEqual(result.x, 0.2)
        XCTAssertEqual(result.y, 0.3)
        XCTAssertEqual(result.feather, 40)
    }

    func testDirectionDragWithAZeroSizeFrameIsANoOp() {
        let base = LocalAdjustmentGeometry(angleDegrees: 10, range: 0.2)
        let result = LinearGradientDragMath.updatedDirection(
            base: base, anchorToTipTranslation: CGVector(dx: 50, dy: 50), imageFrameSize: .zero
        )
        XCTAssertEqual(result, base)
    }
}
