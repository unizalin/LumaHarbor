import XCTest
@preconcurrency import CoreImage
@testable import RawProcessingCore

final class AdvancedMasksRenderTests: XCTestCase {
    private func makeSolidImage(color: CIColor, width: Int = 100, height: Int = 100) -> CIImage {
        CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func sampleCenterPixel(from image: CIImage) -> (r: Double, g: Double, b: Double) {
        let extent = image.extent
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        var pixel: [UInt8] = [0, 0, 0, 0]
        let midX = Int(extent.midX)
        let midY = Int(extent.midY)
        ctx.render(
            image,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: midX, y: midY, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        return (Double(pixel[0]) / 255.0, Double(pixel[1]) / 255.0, Double(pixel[2]) / 255.0)
    }

    func testRadialGradientMaskAppliesAdjustmentToCenter() {
        let base = makeSolidImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0))
        let radial = LocalAdjustment(
            kind: .radialGradient,
            geometry: LocalAdjustmentGeometry(x: 0.5, y: 0.5, radius: 0.4, feather: 0),
            adjustments: LocalAdjustmentPatch(exposure: 1.0)
        )

        let rendered = LocalAdjustmentRenderer.apply([radial], to: base)
        let center = sampleCenterPixel(from: rendered)

        // With +1.0 exposure, center should be significantly brighter than 0.5
        XCTAssertGreaterThan(center.r, 0.6)
        XCTAssertGreaterThan(center.g, 0.6)
    }

    func testMaskInversionInvertsEffect() {
        let base = makeSolidImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0))
        var radial = LocalAdjustment(
            kind: .radialGradient,
            geometry: LocalAdjustmentGeometry(x: 0.5, y: 0.5, radius: 0.2, feather: 0),
            adjustments: LocalAdjustmentPatch(exposure: 1.0)
        )
        radial.isInverted = true

        let rendered = LocalAdjustmentRenderer.apply([radial], to: base)
        let center = sampleCenterPixel(from: rendered)

        // When inverted, the center is masked out (remains ~0.5)
        XCTAssertEqual(center.r, 0.5, accuracy: 0.1)
    }

    func testMaskOpacityScalesAdjustmentStrength() {
        let base = makeSolidImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0))
        let fullAdj = LocalAdjustment(
            kind: .linearGradient,
            geometry: LocalAdjustmentGeometry(x: 0.5, y: 0.5, range: 0.8),
            adjustments: LocalAdjustmentPatch(exposure: 1.0)
        )
        var halfAdj = fullAdj
        halfAdj.opacity = 50.0

        let fullRendered = LocalAdjustmentRenderer.apply([fullAdj], to: base)
        let halfRendered = LocalAdjustmentRenderer.apply([halfAdj], to: base)

        let fullPixel = sampleCenterPixel(from: fullRendered)
        let halfPixel = sampleCenterPixel(from: halfRendered)

        XCTAssertGreaterThan(fullPixel.r, halfPixel.r)
        XCTAssertGreaterThan(halfPixel.r, 0.5)
    }

    func testBrushMaskRendersStroke() {
        let base = makeSolidImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0))
        let stroke = BrushStroke(
            points: [BrushPoint(x: 0.5, y: 0.5, pressure: 1.0)],
            radius: 0.3,
            feather: 10
        )
        var geo = LocalAdjustmentGeometry()
        geo.brushStrokes = [stroke]

        let brushAdj = LocalAdjustment(
            kind: .brush,
            geometry: geo,
            adjustments: LocalAdjustmentPatch(exposure: 2.0)
        )

        let rendered = LocalAdjustmentRenderer.apply([brushAdj], to: base)
        let center = sampleCenterPixel(from: rendered)

        XCTAssertGreaterThan(center.r, 0.3)
    }

    func testSubjectAndBackgroundMasksRenderWithoutCrashing() {
        let base = makeSolidImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1.0))
        let subjectAdj = LocalAdjustment(
            kind: .subject,
            adjustments: LocalAdjustmentPatch(exposure: 0.8)
        )
        let bgAdj = LocalAdjustment(
            kind: .background,
            adjustments: LocalAdjustmentPatch(exposure: -0.5)
        )

        let subjectRendered = LocalAdjustmentRenderer.apply([subjectAdj], to: base)
        let bgRendered = LocalAdjustmentRenderer.apply([bgAdj], to: base)

        XCTAssertEqual(subjectRendered.extent, base.extent)
        XCTAssertEqual(bgRendered.extent, base.extent)
    }

    func testSpotHealRedEyeRemovesRedDominance() {
        // Red eye pixel: R = 0.9, G = 0.1, B = 0.1
        let redEyeImage = makeSolidImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1.0))
        var geo = LocalAdjustmentGeometry(x: 0.5, y: 0.5, radius: 0.4, feather: 0)
        geo.healMode = .redEye
        geo.redEyePupilRadius = 0.4

        let redEyeAdj = LocalAdjustment(kind: .spotHeal, geometry: geo)
        let fixed = LocalAdjustmentRenderer.apply([redEyeAdj], to: redEyeImage)
        let center = sampleCenterPixel(from: fixed)

        // After red eye removal, R should be reduced to ~ (G + B)/2 = 0.1
        XCTAssertLessThan(center.r, 0.3)
    }

    func testGeometryCornerPinsPerspectiveCorrection() {
        let base = makeSolidImage(color: CIColor(red: 0.7, green: 0.3, blue: 0.2, alpha: 1.0))
        var geo = GeometryAdjustments.neutral
        geo.cornerPins = PerspectiveCornerPins(
            topLeft: NormalizedPoint(x: 0.05, y: 0.05),
            topRight: NormalizedPoint(x: 0.95, y: 0.05),
            bottomLeft: NormalizedPoint(x: 0.02, y: 0.98),
            bottomRight: NormalizedPoint(x: 0.98, y: 0.98)
        )

        let rendered = GeometryRenderer.apply(geo, to: base)
        XCTAssertEqual(rendered.extent.size, base.extent.size)
    }
}
