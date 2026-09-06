import CoreGraphics
import CoreImage
import XCTest
@testable import RawProcessingCore

/// Roadmap Phase 5 Task 5.2: "Add watermark render tests: text, position,
/// opacity, size" -- design spec §6.11's "浮水印:文字、位置、不透明度、
/// 大小". `WatermarkRenderer.apply(_:to:)` is a pure `CIImage -> CIImage`
/// function, so it's testable the same way `AdjustmentPipelineTests`
/// samples pixels from a synthetic fixture -- no decoder, no real photo.
final class WatermarkRendererTests: XCTestCase {
    private let canvasSize = CGSize(width: 240, height: 160)

    private func makeBaseImage() -> CIImage {
        CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2))
            .cropped(to: CGRect(origin: .zero, size: canvasSize))
    }

    private struct RGB: Equatable, CustomStringConvertible {
        var red: Int
        var green: Int
        var blue: Int

        var description: String { "(\(red), \(green), \(blue))" }
    }

    /// Renders `image` and averages every pixel inside `region` (image
    /// coordinates, origin top-left) into one RGB triple -- tolerant of
    /// exact glyph shape/anti-aliasing, which the render pipeline's own
    /// choices (system font hinting, sub-pixel positioning) could vary
    /// between OS versions.
    private func regionAverage(
        _ image: CIImage,
        region: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> RGB {
        let renderer = ImageRenderService()
        let cgImage = try renderer.makeCGImage(image)
        // `CGImage.cropping(to:)` uses the same top-left-origin convention
        // as `region` -- no flip needed here (unlike drawing a `CGImage`
        // *into* a `CGContext` below, which is bottom-left-origin).
        guard let cropped = cgImage.cropping(to: region) else {
            XCTFail("region \(region) is outside the \(cgImage.width)x\(cgImage.height) image", file: file, line: line)
            return RGB(red: 0, green: 0, blue: 0)
        }

        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), file: file, line: line)
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return RGB(red: Int(bytes[0]), green: Int(bytes[1]), blue: Int(bytes[2]))
    }

    private func delta(_ a: RGB, _ b: RGB) -> Int {
        abs(a.red - b.red) + abs(a.green - b.green) + abs(a.blue - b.blue)
    }

    private var bottomRightQuadrant: CGRect {
        CGRect(x: canvasSize.width / 2, y: canvasSize.height / 2, width: canvasSize.width / 2, height: canvasSize.height / 2)
    }

    private var topLeftQuadrant: CGRect {
        CGRect(x: 0, y: 0, width: canvasSize.width / 2, height: canvasSize.height / 2)
    }

    // MARK: - No-op cases

    func testNilWatermarkLeavesTheImageUnchanged() throws {
        let base = makeBaseImage()
        let result = WatermarkRenderer.apply(nil, to: base)

        XCTAssertEqual(try regionAverage(result, region: bottomRightQuadrant), try regionAverage(base, region: bottomRightQuadrant))
    }

    func testEmptyTextLeavesTheImageUnchanged() throws {
        let base = makeBaseImage()
        let watermark = Watermark(text: "", position: .bottomRight, opacity: 1, sizeFraction: 0.2)
        let result = WatermarkRenderer.apply(watermark, to: base)

        XCTAssertEqual(try regionAverage(result, region: bottomRightQuadrant), try regionAverage(base, region: bottomRightQuadrant))
    }

    func testWhitespaceOnlyTextLeavesTheImageUnchanged() throws {
        let base = makeBaseImage()
        let watermark = Watermark(text: "   ", position: .bottomRight, opacity: 1, sizeFraction: 0.2)
        let result = WatermarkRenderer.apply(watermark, to: base)

        XCTAssertEqual(try regionAverage(result, region: bottomRightQuadrant), try regionAverage(base, region: bottomRightQuadrant))
    }

    // MARK: - Text actually renders

    func testWatermarkTextChangesPixelsNearItsPosition() throws {
        let base = makeBaseImage()
        let watermark = Watermark(text: "LumaHarbor", position: .bottomRight, opacity: 1, sizeFraction: 0.2)
        let result = WatermarkRenderer.apply(watermark, to: base)

        let baseline = try regionAverage(base, region: bottomRightQuadrant)
        let watermarked = try regionAverage(result, region: bottomRightQuadrant)
        XCTAssertGreaterThan(delta(baseline, watermarked), 0, "watermark text must actually change pixels near its own corner")
    }

    // MARK: - Position

    func testPositionOnlyAffectsItsOwnCornerNotTheOppositeOne() throws {
        let base = makeBaseImage()
        let watermark = Watermark(text: "LumaHarbor", position: .bottomRight, opacity: 1, sizeFraction: 0.2)
        let result = WatermarkRenderer.apply(watermark, to: base)

        let baselineOpposite = try regionAverage(base, region: topLeftQuadrant)
        let resultOpposite = try regionAverage(result, region: topLeftQuadrant)
        XCTAssertEqual(baselineOpposite, resultOpposite, "a bottom-right watermark must not touch the top-left corner")
    }

    func testEveryPositionRendersInsideItsOwnNamedCorner() throws {
        let base = makeBaseImage()
        let regions: [(Watermark.Position, CGRect)] = [
            (.topLeft, CGRect(x: 0, y: 0, width: canvasSize.width / 2, height: canvasSize.height / 2)),
            (.topRight, CGRect(x: canvasSize.width / 2, y: 0, width: canvasSize.width / 2, height: canvasSize.height / 2)),
            (.bottomLeft, CGRect(x: 0, y: canvasSize.height / 2, width: canvasSize.width / 2, height: canvasSize.height / 2)),
            (.bottomRight, bottomRightQuadrant),
        ]

        for (position, region) in regions {
            let watermark = Watermark(text: "X", position: position, opacity: 1, sizeFraction: 0.2)
            let result = WatermarkRenderer.apply(watermark, to: base)
            let baseline = try regionAverage(base, region: region)
            let watermarked = try regionAverage(result, region: region)
            XCTAssertGreaterThan(delta(baseline, watermarked), 0, "\(position) watermark must render inside its own named corner")
        }
    }

    // MARK: - Opacity

    func testHigherOpacityChangesPixelsMoreThanLowerOpacity() throws {
        let base = makeBaseImage()
        let low = Watermark(text: "LumaHarbor", position: .bottomRight, opacity: 0.2, sizeFraction: 0.2)
        let high = Watermark(text: "LumaHarbor", position: .bottomRight, opacity: 1.0, sizeFraction: 0.2)

        let baseline = try regionAverage(base, region: bottomRightQuadrant)
        let lowDelta = delta(baseline, try regionAverage(WatermarkRenderer.apply(low, to: base), region: bottomRightQuadrant))
        let highDelta = delta(baseline, try regionAverage(WatermarkRenderer.apply(high, to: base), region: bottomRightQuadrant))

        XCTAssertGreaterThan(highDelta, lowDelta, "full opacity must change pixels more than low opacity")
    }

    // MARK: - Size

    func testLargerSizeReachesFartherFromTheAnchorThanSmallerSize() throws {
        let base = makeBaseImage()
        // A point close to the image's centre -- a small watermark anchored
        // at bottom-right shouldn't reach this far; a much larger one should.
        let farRegion = CGRect(x: 0, y: 0, width: canvasSize.width * 0.4, height: canvasSize.height * 0.4)

        let small = Watermark(text: "LumaHarborLumaHarbor", position: .bottomRight, opacity: 1, sizeFraction: 0.03)
        let large = Watermark(text: "LumaHarborLumaHarbor", position: .bottomRight, opacity: 1, sizeFraction: 0.35)

        let baseline = try regionAverage(base, region: farRegion)
        let smallDelta = delta(baseline, try regionAverage(WatermarkRenderer.apply(small, to: base), region: farRegion))
        let largeDelta = delta(baseline, try regionAverage(WatermarkRenderer.apply(large, to: base), region: farRegion))

        XCTAssertEqual(smallDelta, 0, "a small watermark anchored at the opposite corner must not reach this far")
        XCTAssertGreaterThan(largeDelta, 0, "a large watermark must reach farther across the canvas")
    }

    // MARK: - Coverage

    func testEveryPositionHasAVisibleDisplayName() {
        for position in Watermark.Position.allCases {
            XCTAssertFalse(position.displayName.isEmpty, "\(position) has no display name")
        }
    }

    func testOpacityAndSizeAreClampedToAValidRange() {
        let watermark = Watermark(text: "X", opacity: 5, sizeFraction: -1)
        XCTAssertEqual(watermark.opacity, 1)
        XCTAssertGreaterThan(watermark.sizeFraction, 0)
    }
}
