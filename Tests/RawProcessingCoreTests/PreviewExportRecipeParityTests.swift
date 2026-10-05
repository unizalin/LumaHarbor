import Foundation
import CoreImage
import CoreGraphics
import XCTest
@testable import RawProcessingCore

final class PreviewExportRecipeParityTests: XCTestCase {
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return bytes }
        context.draw(image, in: CGRect(
            x: -CGFloat(x), y: -(CGFloat(image.height) - CGFloat(y) - 1),
            width: CGFloat(image.width), height: CGFloat(image.height)
        ))
        return bytes
    }

    func testPreviewAndExportReceiveTheSameFullQualityRecipe() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RecipeParity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("DSC0001.ARW")
        try Data(repeating: 0x44, count: 64).write(to: source)
        var adjustments = PhotoAdjustments.neutral
        adjustments.rawRenderingCompatibility = .adobeProcess2012V1
        adjustments.lensCorrection = LensCorrectionAdjustments(mode: .automatic)
        adjustments.brushMasks = [
            BrushMask(
                strokes: [BrushMaskStroke(points: [BrushMaskPoint(x: 0.3, y: 0.35)], size: 0.2)],
                adjustments: BrushMaskPatch(exposure: 1)
            ),
            BrushMask(
                strokes: [BrushMaskStroke(points: [BrushMaskPoint(x: 0.7, y: 0.65)], size: 0.2)],
                adjustments: BrushMaskPatch(blacks: 1)
            )
        ]

        let decoder = SyntheticRawDecoder()
        let preview = try await CoreImagePreviewRenderer(decoder: decoder).render(
            PreviewRequest(
                subject: PreviewSubject(UUID()),
                url: source,
                adjustments: adjustments,
                targetPixelDimension: 64,
                quality: .full
            )
        )
        let outcome = try await PhotoExporter(decoder: decoder).export(
            ExportRequest(
                sourceURL: source,
                adjustments: adjustments,
                destinationDirectory: root,
                baseFilename: "output",
                format: .jpeg
            )
        )

        XCTAssertEqual(preview.rawRenderRecipe, outcome.rawRenderRecipe)
        XCTAssertEqual(preview.rawRenderRecipe?.policy, .adobeProcess2012V1)
        XCTAssertEqual(preview.rawRenderRecipe?.effectivePolicy, .native)
        XCTAssertEqual(preview.pixelSize, outcome.pixelSize)
        let exportedImage = try XCTUnwrap(CIImage(contentsOf: outcome.url))
        XCTAssertEqual(exportedImage.extent.size, preview.pixelSize)
        let exportedCG = try ImageRenderService().makeCGImage(exportedImage)
        XCTAssertEqual(exportedCG.width, preview.cgImage.width)
        XCTAssertEqual(exportedCG.height, preview.cgImage.height)
        for point in [(10, 8), (22, 15)] {
            let previewPixel = pixel(preview.cgImage, x: point.0, y: point.1)
            let exportPixel = pixel(exportedCG, x: point.0, y: point.1)
            XCTAssertLessThanOrEqual(abs(Int(previewPixel[0]) - Int(exportPixel[0])), 25)
            XCTAssertLessThanOrEqual(abs(Int(previewPixel[1]) - Int(exportPixel[1])), 25)
            XCTAssertLessThanOrEqual(abs(Int(previewPixel[2]) - Int(exportPixel[2])), 25)
        }
        XCTAssertEqual(
            preview.rawRenderRecipe?.workingColorSpaceID,
            RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue
        )
    }
}
