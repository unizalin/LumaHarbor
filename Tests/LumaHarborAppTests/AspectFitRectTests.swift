import CoreGraphics
import XCTest
@testable import LumaHarborApp

/// Phase 2 Task 2.3: `CropOverlayView` draws and hit-tests against exactly
/// the rectangle `EditorView.previewArea`'s `Image(...).aspectRatio
/// (contentMode: .fit)` occupies -- these tests pin the pure-geometry
/// reproduction of that layout so the overlay can never silently drift out
/// of alignment with the photo underneath it.
final class AspectFitRectTests: XCTestCase {
    func testWiderImageThanContainerIsWidthConstrained() {
        // 2:1 image in a square container: full width, half height, vertically centred.
        let rect = AspectFitRect.fitting(
            imageSize: CGSize(width: 200, height: 100),
            in: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    func testTallerImageThanContainerIsHeightConstrained() {
        // 1:2 image in a square container: full height, half width, horizontally centred.
        let rect = AspectFitRect.fitting(
            imageSize: CGSize(width: 100, height: 200),
            in: CGSize(width: 100, height: 100)
        )
        XCTAssertEqual(rect, CGRect(x: 25, y: 0, width: 50, height: 100))
    }

    func testMatchingAspectRatioFillsTheAvailableArea() {
        let rect = AspectFitRect.fitting(
            imageSize: CGSize(width: 300, height: 200),
            in: CGSize(width: 150, height: 100)
        )
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 150, height: 100))
    }

    func testPaddingIsSubtractedSymmetricallyBeforeFitting() {
        let rect = AspectFitRect.fitting(
            imageSize: CGSize(width: 100, height: 100),
            in: CGSize(width: 132, height: 132),
            padding: 16
        )
        // Available area is 100x100 after 16pt padding on every side --
        // a square image exactly fills it, offset by the padding.
        XCTAssertEqual(rect, CGRect(x: 16, y: 16, width: 100, height: 100))
    }

    func testZeroOrNegativeAvailableAreaDoesNotCrashOrProduceNegativeSize() {
        let rect = AspectFitRect.fitting(
            imageSize: CGSize(width: 100, height: 100),
            in: CGSize(width: 10, height: 10),
            padding: 20
        )
        XCTAssertGreaterThanOrEqual(rect.width, 0)
        XCTAssertGreaterThanOrEqual(rect.height, 0)
    }

    func testZeroImageSizeDoesNotCrashOrProduceNaN() {
        let rect = AspectFitRect.fitting(imageSize: .zero, in: CGSize(width: 100, height: 100))
        XCTAssertFalse(rect.width.isNaN)
        XCTAssertFalse(rect.height.isNaN)
    }

    // MARK: - imagePixel(at:imageFrame:imageSize:) -- Phase 2 Task 2.4 (eyedropper)

    func testImagePixelMapsTheFramesTopLeftToPixelZeroZero() {
        let frame = CGRect(x: 16, y: 16, width: 100, height: 100)
        let pixel = AspectFitRect.imagePixel(at: CGPoint(x: 16, y: 16), imageFrame: frame, imageSize: CGSize(width: 200, height: 200))
        XCTAssertEqual(pixel, .zero)
    }

    func testImagePixelMapsTheFramesCentreToTheImagesCentre() {
        let frame = CGRect(x: 16, y: 16, width: 100, height: 100)
        let pixel = AspectFitRect.imagePixel(at: CGPoint(x: 66, y: 66), imageFrame: frame, imageSize: CGSize(width: 200, height: 200))
        XCTAssertEqual(pixel, CGPoint(x: 100, y: 100))
    }

    func testImagePixelScalesNonSquareImagesCorrectly() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 50)
        let pixel = AspectFitRect.imagePixel(at: CGPoint(x: 25, y: 25), imageFrame: frame, imageSize: CGSize(width: 400, height: 200))
        XCTAssertEqual(pixel, CGPoint(x: 100, y: 100))
    }

    func testImagePixelClampsAPointOutsideTheFrameToTheNearestEdge() {
        let frame = CGRect(x: 16, y: 16, width: 100, height: 100)
        let pixel = AspectFitRect.imagePixel(at: CGPoint(x: -50, y: 500), imageFrame: frame, imageSize: CGSize(width: 200, height: 200))
        XCTAssertEqual(pixel, CGPoint(x: 0, y: 200))
    }

    func testImagePixelWithAZeroSizedFrameIsANoOpRatherThanDividingByZero() {
        let pixel = AspectFitRect.imagePixel(at: CGPoint(x: 10, y: 10), imageFrame: .zero, imageSize: CGSize(width: 200, height: 200))
        XCTAssertEqual(pixel, .zero)
    }
}
