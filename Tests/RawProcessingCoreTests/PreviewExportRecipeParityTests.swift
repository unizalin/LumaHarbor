import Foundation
import XCTest
@testable import RawProcessingCore

final class PreviewExportRecipeParityTests: XCTestCase {
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
        XCTAssertEqual(
            preview.rawRenderRecipe?.workingColorSpaceID,
            RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue
        )
    }
}
