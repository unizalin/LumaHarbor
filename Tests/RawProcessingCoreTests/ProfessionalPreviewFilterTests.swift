import CoreGraphics
import CoreImage
import XCTest
@testable import RawProcessingCore

final class ProfessionalPreviewFilterTests: XCTestCase {
    private let context = CIContext()

    func testInactiveOptionsIsPassthrough() {
        let options = ProfessionalPreviewOptions()
        XCTAssertFalse(options.isActive)

        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        let output = ProfessionalPreviewRenderer.apply(options, to: image)
        XCTAssertEqual(output, image)
    }

    func testTargetColorSpaceProfiles() {
        XCTAssertNotNil(ProfessionalPreviewRenderer.targetColorSpace(for: .sRGB))
        XCTAssertNotNil(ProfessionalPreviewRenderer.targetColorSpace(for: .displayP3))
        XCTAssertNotNil(ProfessionalPreviewRenderer.targetColorSpace(for: .adobeRGB))
    }

    func testHighlightClippingOverlayMarksBlownHighlights() {
        let options = ProfessionalPreviewOptions(showHighlightClipping: true)
        XCTAssertTrue(options.isActive)

        let blownPixel = CIImage(color: CIColor(red: 1.0, green: 1.0, blue: 1.0)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let output = ProfessionalPreviewRenderer.apply(options, to: blownPixel)

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )

        // Blown pixel should be overlaid in red: high R, low G and B
        XCTAssertGreaterThan(bitmap[0], 200)
        XCTAssertLessThan(bitmap[1], 50)
        XCTAssertLessThan(bitmap[2], 50)
    }

    func testShadowClippingOverlayMarksCrushedShadows() {
        let options = ProfessionalPreviewOptions(showShadowClipping: true)
        XCTAssertTrue(options.isActive)

        let crushedPixel = CIImage(color: CIColor(red: 0.0, green: 0.0, blue: 0.0)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let output = ProfessionalPreviewRenderer.apply(options, to: crushedPixel)

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )

        // Crushed shadow pixel should be overlaid in blue: low R, high B
        XCTAssertLessThan(bitmap[0], 50)
        XCTAssertGreaterThan(bitmap[2], 200)
    }

    func testMidtonesAreNotMarkedByClippingOverlays() {
        let options = ProfessionalPreviewOptions(
            showHighlightClipping: true,
            showShadowClipping: true
        )
        let midtonePixel = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let output = ProfessionalPreviewRenderer.apply(options, to: midtonePixel)

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )

        // Midtone should remain approximately 128 in R, G, B
        XCTAssertEqual(Double(bitmap[0]), 128, accuracy: 15)
        XCTAssertEqual(Double(bitmap[1]), 128, accuracy: 15)
        XCTAssertEqual(Double(bitmap[2]), 128, accuracy: 15)
    }
}
