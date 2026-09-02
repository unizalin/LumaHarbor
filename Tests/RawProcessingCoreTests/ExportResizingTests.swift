import CoreGraphics
import XCTest
@testable import RawProcessingCore

/// AwayPhotoRawEditor parity Phase 1 Task 4: max-width/max-height export
/// resizing. Aspect ratio is always preserved and the image is never
/// upscaled -- a request whose caps exceed the native size is a no-op.
final class ExportResizingTests: XCTestCase {
    private let native = CGSize(width: 4_000, height: 3_000)

    func testNoCapsLeavesTheSizeUnchanged() {
        let size = ExportResizing.fittedSize(nativeSize: native, maximumWidth: nil, maximumHeight: nil)
        XCTAssertEqual(size, native)
    }

    func testMaximumWidthScalesBothDimensionsProportionally() {
        let size = ExportResizing.fittedSize(nativeSize: native, maximumWidth: 2_000, maximumHeight: nil)
        XCTAssertEqual(size, CGSize(width: 2_000, height: 1_500))
    }

    func testMaximumHeightScalesBothDimensionsProportionally() {
        let size = ExportResizing.fittedSize(nativeSize: native, maximumWidth: nil, maximumHeight: 1_500)
        XCTAssertEqual(size, CGSize(width: 2_000, height: 1_500))
    }

    /// Both caps given: the tighter one wins, matching "fit within a box"
    /// rather than "fill it".
    func testTheTighterOfTwoCapsWins() {
        let size = ExportResizing.fittedSize(nativeSize: native, maximumWidth: 1_000, maximumHeight: 1_200)
        // width cap -> 1000x750; height cap -> 1600x1200. The width cap is
        // tighter, so it wins and the result must still respect both caps.
        XCTAssertEqual(size, CGSize(width: 1_000, height: 750))
    }

    func testCapsLargerThanTheSourceNeverUpscale() {
        let size = ExportResizing.fittedSize(nativeSize: native, maximumWidth: 8_000, maximumHeight: 6_000)
        XCTAssertEqual(size, native)
    }

    func testAZeroOrNegativeCapIsTreatedAsNoLimitRatherThanCollapsingToZero() {
        let size = ExportResizing.fittedSize(nativeSize: native, maximumWidth: 0, maximumHeight: nil)
        XCTAssertEqual(size, native)
    }

    func testFittingTransformAppliedToTheNativeExtentProducesTheFittedSize() {
        let transform = ExportResizing.fittingTransform(nativeSize: native, maximumWidth: 2_000, maximumHeight: nil)
        let transformed = CGRect(origin: .zero, size: native).applying(transform)
        XCTAssertEqual(transformed.size, CGSize(width: 2_000, height: 1_500))
    }

    func testDegenerateNativeSizeIsPassedThroughRatherThanCrashing() {
        let size = ExportResizing.fittedSize(nativeSize: .zero, maximumWidth: 100, maximumHeight: 100)
        XCTAssertEqual(size, .zero)
    }
}
