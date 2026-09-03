import CoreGraphics
import XCTest
@testable import LumaHarborApp
@testable import RawProcessingCore

/// Phase 2 Task 2.3: pins the direction and fixed-corner behaviour of every
/// crop handle before `CropOverlayView` ever renders a pixel -- the
/// roadmap's own "UI 正負方向必須用真人或 screenshot fixture 驗證，不能只用
/// 數學座標直覺決定" applies just as much to this pure math as to
/// `GeometryRenderer`'s rotate/straighten sign convention (Task 2.2), so
/// every case below states the expected fixed corner explicitly rather than
/// trusting the formula by inspection alone.
final class CropDragMathTests: XCTestCase {
    private let frame = CGSize(width: 200, height: 100)
    private let base = NormalizedCropRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)

    func testMoveTranslatesWithoutResizing() {
        let result = CropDragMath.updatedCrop(
            base: base, handle: .move, translation: CGSize(width: 20, height: 10), imageFrameSize: frame
        )
        XCTAssertEqual(result.width, base.width, accuracy: 0.0001)
        XCTAssertEqual(result.height, base.height, accuracy: 0.0001)
        XCTAssertEqual(result.x, base.x + 0.1, accuracy: 0.0001, "20pt / 200pt width = 0.1 normalized")
        XCTAssertEqual(result.y, base.y + 0.1, accuracy: 0.0001, "10pt / 100pt height = 0.1 normalized")
    }

    func testMoveClampsAtTheFrameEdgeRatherThanLeavingTheCanvas() {
        let result = CropDragMath.updatedCrop(
            base: base, handle: .move, translation: CGSize(width: -1_000, height: -1_000), imageFrameSize: frame
        )
        XCTAssertEqual(result.x, 0, accuracy: 0.0001)
        XCTAssertEqual(result.y, 0, accuracy: 0.0001)
        XCTAssertEqual(result.width, base.width, accuracy: 0.0001, "size is preserved even when clamped")
    }

    func testBottomRightHandleGrowsFromTheFixedTopLeftCorner() {
        let result = CropDragMath.updatedCrop(
            base: base, handle: .bottomRight, translation: CGSize(width: 20, height: 10), imageFrameSize: frame
        )
        XCTAssertEqual(result.x, base.x, accuracy: 0.0001, "top-left corner (x) stays fixed")
        XCTAssertEqual(result.y, base.y, accuracy: 0.0001, "top-left corner (y) stays fixed")
        XCTAssertEqual(result.width, base.width + 0.1, accuracy: 0.0001)
        XCTAssertEqual(result.height, base.height + 0.1, accuracy: 0.0001)
    }

    func testTopLeftHandleResizesFromTheFixedBottomRightCorner() {
        let result = CropDragMath.updatedCrop(
            base: base, handle: .topLeft, translation: CGSize(width: 20, height: 10), imageFrameSize: frame
        )
        let baseRight = base.x + base.width
        let baseBottom = base.y + base.height
        XCTAssertEqual(result.x + result.width, baseRight, accuracy: 0.0001, "the right edge (opposite the dragged corner) stays fixed")
        XCTAssertEqual(result.y + result.height, baseBottom, accuracy: 0.0001, "the bottom edge (opposite the dragged corner) stays fixed")
        XCTAssertEqual(result.x, base.x + 0.1, accuracy: 0.0001)
        XCTAssertEqual(result.width, base.width - 0.1, accuracy: 0.0001)
    }

    func testTopRightHandleKeepsTheBottomLeftCornerFixed() {
        let result = CropDragMath.updatedCrop(
            base: base, handle: .topRight, translation: CGSize(width: 20, height: 10), imageFrameSize: frame
        )
        XCTAssertEqual(result.x, base.x, accuracy: 0.0001, "left edge stays fixed")
        XCTAssertEqual(result.y + result.height, base.y + base.height, accuracy: 0.0001, "bottom edge stays fixed")
        XCTAssertEqual(result.width, base.width + 0.1, accuracy: 0.0001)
        XCTAssertEqual(result.height, base.height - 0.1, accuracy: 0.0001)
    }

    func testBottomLeftHandleKeepsTheTopRightCornerFixed() {
        let result = CropDragMath.updatedCrop(
            base: base, handle: .bottomLeft, translation: CGSize(width: 20, height: 10), imageFrameSize: frame
        )
        XCTAssertEqual(result.x + result.width, base.x + base.width, accuracy: 0.0001, "right edge stays fixed")
        XCTAssertEqual(result.y, base.y, accuracy: 0.0001, "top edge stays fixed")
        XCTAssertEqual(result.width, base.width - 0.1, accuracy: 0.0001)
        XCTAssertEqual(result.height, base.height + 0.1, accuracy: 0.0001)
    }

    func testDraggingACornerPastItsOppositeCornerFloorsAtTheMinimumSizeRatherThanInverting() {
        // Dragging bottomRight's opposite handle (topLeft) far past the
        // fixed bottom-right corner: known, documented limitation -- this
        // does not swap which handle is "top-left" vs "bottom-right"; it
        // just floors at NormalizedCropRect's own minimum dimension.
        let result = CropDragMath.updatedCrop(
            base: base, handle: .topLeft, translation: CGSize(width: 1_000, height: 1_000), imageFrameSize: frame
        )
        XCTAssertGreaterThanOrEqual(result.width, NormalizedCropRect.minimumDimension)
        XCTAssertGreaterThanOrEqual(result.height, NormalizedCropRect.minimumDimension)
    }

    func testZeroSizedImageFrameIsANoOpRatherThanDividingByZero() {
        let result = CropDragMath.updatedCrop(
            base: base, handle: .move, translation: CGSize(width: 20, height: 10), imageFrameSize: .zero
        )
        XCTAssertEqual(result, base)
    }
}
