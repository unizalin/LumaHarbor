import CoreGraphics
import XCTest
@testable import LumaHarborApp
@testable import RawProcessingCore

/// Phase 4 Task 4.5: pins the target/size/source drag math and the
/// clone-mode default-source fallback before `SpotHealOverlayView` ever
/// renders a pixel, matching `LinearGradientDragMathTests`'s own reasoning.
/// `resolvedSource(for:)` is deliberately the *same* formula as
/// `LocalAdjustmentRenderer.autoSourcePoint(for:extent:)` (duplicated, not
/// shared, since `LumaHarborApp` cannot depend on a private render-layer
/// function) -- these tests exist so a change to one formula without the
/// other is caught here, not discovered as a visual mismatch between the
/// overlay's initial handle position and what actually renders.
final class SpotHealDragMathTests: XCTestCase {
    private let frame = CGSize(width: 200, height: 100)

    // MARK: - Target handle

    func testTargetDragMovesXAndYByTheNormalizedTranslation() {
        let base = LocalAdjustmentGeometry(x: 0.3, y: 0.4)
        let result = SpotHealDragMath.updatedTargetPosition(
            base: base, translation: CGSize(width: 20, height: 10), imageFrameSize: frame
        )
        XCTAssertEqual(result.x, 0.4, accuracy: 0.0001, "20pt / 200pt width = 0.1 normalized")
        XCTAssertEqual(result.y, 0.5, accuracy: 0.0001, "10pt / 100pt height = 0.1 normalized")
    }

    func testTargetDragLeavesRadiusFeatherSourceAndModeUntouched() {
        let base = LocalAdjustmentGeometry(x: 0.5, y: 0.5, sourceX: 0.2, sourceY: 0.2, radius: 0.1, feather: 30, healMode: .clone)
        let result = SpotHealDragMath.updatedTargetPosition(
            base: base, translation: CGSize(width: 5, height: 5), imageFrameSize: frame
        )
        XCTAssertEqual(result.radius, 0.1)
        XCTAssertEqual(result.feather, 30)
        XCTAssertEqual(result.sourceX, 0.2)
        XCTAssertEqual(result.sourceY, 0.2)
        XCTAssertEqual(result.healMode, .clone)
    }

    func testTargetDragClampsAtTheUnitSquareEdgeRatherThanLeavingTheCanvas() {
        let base = LocalAdjustmentGeometry(x: 0.1, y: 0.1)
        let result = SpotHealDragMath.updatedTargetPosition(
            base: base, translation: CGSize(width: -1_000, height: -1_000), imageFrameSize: frame
        )
        XCTAssertEqual(result.x, 0, accuracy: 0.0001)
        XCTAssertEqual(result.y, 0, accuracy: 0.0001)
    }

    func testTargetDragWithAZeroSizeFrameIsANoOp() {
        let base = LocalAdjustmentGeometry(x: 0.5, y: 0.5)
        let result = SpotHealDragMath.updatedTargetPosition(
            base: base, translation: CGSize(width: 20, height: 20), imageFrameSize: .zero
        )
        XCTAssertEqual(result, base)
    }

    // MARK: - Size (radius) handle

    func testSizeDragSetsRadiusFromDistanceNormalizedToTheShorterFrameSide() {
        // Matches LocalAdjustmentRenderer.applySpotHeal's own
        // `min(extent.width, extent.height)` pixel conversion exactly, so
        // the handle's on-screen circle always matches the actual render.
        let base = LocalAdjustmentGeometry(radius: 0.05)
        let result = SpotHealDragMath.updatedRadius(
            base: base, targetToHandleTranslation: CGVector(dx: 25, dy: 0), imageFrameSize: frame
        )
        XCTAssertEqual(result.radius, 0.25, accuracy: 0.0001, "25pt / shorter side (100pt) = 0.25 normalized")
    }

    func testSizeDragUsesTheStraightLineDistanceNotJustTheXComponent() {
        let base = LocalAdjustmentGeometry(radius: 0.05)
        let result = SpotHealDragMath.updatedRadius(
            base: base, targetToHandleTranslation: CGVector(dx: 30, dy: 40), imageFrameSize: frame
        )
        XCTAssertEqual(result.radius, 0.5, accuracy: 0.0001, "hypot(30,40) = 50; 50pt / 100pt shorter side = 0.5")
    }

    func testSizeDragLeavesTargetSourceFeatherAndModeUntouched() {
        let base = LocalAdjustmentGeometry(x: 0.3, y: 0.7, sourceX: 0.1, sourceY: 0.1, feather: 60, healMode: .clone)
        let result = SpotHealDragMath.updatedRadius(
            base: base, targetToHandleTranslation: CGVector(dx: 10, dy: 0), imageFrameSize: frame
        )
        XCTAssertEqual(result.x, 0.3)
        XCTAssertEqual(result.y, 0.7)
        XCTAssertEqual(result.sourceX, 0.1)
        XCTAssertEqual(result.sourceY, 0.1)
        XCTAssertEqual(result.feather, 60)
        XCTAssertEqual(result.healMode, .clone)
    }

    func testSizeDragWithAZeroSizeFrameIsANoOp() {
        let base = LocalAdjustmentGeometry(radius: 0.1)
        let result = SpotHealDragMath.updatedRadius(
            base: base, targetToHandleTranslation: CGVector(dx: 20, dy: 20), imageFrameSize: .zero
        )
        XCTAssertEqual(result, base)
    }

    // MARK: - Source handle

    func testSourceDragMovesSourceXYByTheNormalizedTranslationWhenAlreadySet() {
        let base = LocalAdjustmentGeometry(sourceX: 0.2, sourceY: 0.3, healMode: .clone)
        let result = SpotHealDragMath.updatedSourcePosition(
            base: base, translation: CGSize(width: 20, height: 10), imageFrameSize: frame
        )
        XCTAssertEqual(result.sourceX ?? -1, 0.3, accuracy: 0.0001)
        XCTAssertEqual(result.sourceY ?? -1, 0.4, accuracy: 0.0001)
    }

    func testSourceDragLeavesTargetRadiusFeatherAndModeUntouched() {
        let base = LocalAdjustmentGeometry(x: 0.5, y: 0.5, sourceX: 0.2, sourceY: 0.2, radius: 0.1, feather: 30, healMode: .clone)
        let result = SpotHealDragMath.updatedSourcePosition(
            base: base, translation: CGSize(width: 5, height: 5), imageFrameSize: frame
        )
        XCTAssertEqual(result.x, 0.5)
        XCTAssertEqual(result.y, 0.5)
        XCTAssertEqual(result.radius, 0.1)
        XCTAssertEqual(result.feather, 30)
        XCTAssertEqual(result.healMode, .clone)
    }

    func testSourceDragWithAZeroSizeFrameIsANoOp() {
        let base = LocalAdjustmentGeometry(sourceX: 0.2, sourceY: 0.2, healMode: .clone)
        let result = SpotHealDragMath.updatedSourcePosition(
            base: base, translation: CGSize(width: 20, height: 20), imageFrameSize: .zero
        )
        XCTAssertEqual(result, base)
    }

    // MARK: - Default source fallback (mirrors LocalAdjustmentRenderer.autoSourcePoint)

    func testResolvedSourceReturnsTheExplicitPointWhenBothCoordinatesAreSet() {
        let geometry = LocalAdjustmentGeometry(x: 0.5, y: 0.5, sourceX: 0.1, sourceY: 0.9, healMode: .clone)
        let resolved = SpotHealDragMath.resolvedSource(for: geometry)
        XCTAssertEqual(resolved.x, 0.1)
        XCTAssertEqual(resolved.y, 0.9)
    }

    func testResolvedSourceFallsBackToAFixedOffsetAboveTheTargetWhenUnset() {
        let geometry = LocalAdjustmentGeometry(x: 0.5, y: 0.5, radius: 0.05, healMode: .heal)
        let resolved = SpotHealDragMath.resolvedSource(for: geometry)
        // offsetNormalized = min(0.05 * 2.5, 0.45) = 0.125
        XCTAssertEqual(resolved.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(resolved.y, 0.375, accuracy: 0.0001)
    }

    func testResolvedSourceMirrorsBelowTheTargetWhenTooCloseToTheTopEdge() {
        let geometry = LocalAdjustmentGeometry(x: 0.5, y: 0.05, radius: 0.05, healMode: .heal)
        let resolved = SpotHealDragMath.resolvedSource(for: geometry)
        // above = 0.05 - 0.125 = -0.075 < 0 -> mirror below: min(0.05 + 0.125, 1) = 0.175
        XCTAssertEqual(resolved.y, 0.175, accuracy: 0.0001)
    }

    func testResolvedSourceIgnoresAPartiallySetSourcePoint() {
        // Only one of sourceX/sourceY set is treated the same as neither set
        // -- there is no such thing as a half-placed source point.
        var geometry = LocalAdjustmentGeometry(x: 0.4, y: 0.6, radius: 0.05)
        geometry.sourceX = 0.9
        let resolved = SpotHealDragMath.resolvedSource(for: geometry)
        XCTAssertEqual(resolved.x, 0.4, accuracy: 0.0001)
    }
}
