import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import RawProcessingCore

/// Integration-level guard that the async production entry point used by
/// preview/export preserves the synchronous pixel contract while materializing
/// a real image. The larger timed workload lives in RawProcessingCoreTests so
/// it can run without a fixture or application lifecycle.
final class BrushMaskPerformanceAcceptanceTests: XCTestCase {
    func testAsyncBrushPipelineMaterializesInOriginalMaskOrder() async throws {
        let extent = CGRect(x: 3, y: 5, width: 320, height: 240)
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        let masks = (0..<4).map { maskIndex in
            BrushMask(
                id: UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", maskIndex + 1))!,
                strokes: [BrushMaskStroke(
                    points: [
                        BrushMaskPoint(x: 0.08, y: 0.12 + Double(maskIndex) * 0.17),
                        BrushMaskPoint(x: 0.88, y: 0.12 + Double(maskIndex) * 0.17)
                    ],
                    size: 0.06,
                    feather: 0.2,
                    flow: 0.7
                )],
                adjustments: BrushMaskPatch(exposure: maskIndex.isMultiple(of: 2) ? 0.25 : -0.15)
            )
        }
        let sync = try BrushMaskRenderer.applyValidated(masks, to: source)
        let asyncImage = try await BrushMaskRenderer.applyValidatedAsync(masks, to: source)
        let service = ImageRenderService(preferMetal: false)
        let syncCGImage = try service.makeCGImage(sync)
        let asyncCGImage = try service.makeCGImage(asyncImage)

        XCTAssertEqual(asyncCGImage.width, 320)
        XCTAssertEqual(asyncCGImage.height, 240)
        XCTAssertEqual(syncCGImage.dataProvider?.data as Data?, asyncCGImage.dataProvider?.data as Data?)
    }
}
