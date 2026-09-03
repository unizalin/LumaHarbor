import CoreGraphics
import CoreImage
import XCTest
@testable import RawProcessingCore

/// Synthetic-image tests for `GeometryRenderer` (Phase 2 Task 2): rotate 90,
/// flip, crop and straighten, exercised on a four-quadrant marker image so
/// direction bugs show up as a swapped colour rather than a passing
/// pixel-count assertion that happens to still add up. Tolerance-based
/// where a transform interpolates (straighten, perspective); exact where it
/// doesn't (crop, 90° rotate, flip).
final class GeometryRendererTests: XCTestCase {
    private let size = CGSize(width: 8, height: 8)

    // MARK: - Fixture

    /// A four-quadrant marker image: visual top-left red, top-right green,
    /// bottom-left blue, bottom-right yellow. "Visual"/on-screen position is
    /// what every assertion below reasons about; `pixel(at:in:)` already
    /// converts to Core Image's bottom-left-origin, y-up storage for you.
    private func makeQuadrantImage(size: CGSize? = nil) -> CIImage {
        let size = size ?? self.size
        let half = CGSize(width: size.width / 2, height: size.height / 2)
        func quad(_ color: CIColor, x: CGFloat, y: CGFloat) -> CIImage {
            CIImage(color: color).cropped(to: CGRect(x: x, y: y, width: half.width, height: half.height))
        }
        // Core Image storage is y-up (0 at the visual bottom), so the
        // *visual* top row is the *higher* y range here.
        let topLeft = quad(.red, x: 0, y: half.height)
        let topRight = quad(.green, x: half.width, y: half.height)
        let bottomLeft = quad(.blue, x: 0, y: 0)
        let bottomRight = quad(CIColor(red: 1, green: 1, blue: 0), x: half.width, y: 0)
        return topLeft
            .composited(over: topRight)
            .composited(over: bottomLeft)
            .composited(over: bottomRight)
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private enum Quadrant { case topLeft, topRight, bottomLeft, bottomRight }

    /// Renders and samples one quadrant's centre, in visual/on-screen
    /// coordinates with (0,0) at the top-left -- matching how a human reads
    /// "top-left corner", not Core Image's own bottom-left-origin storage.
    private func sample(
        _ quadrant: Quadrant,
        of image: CIImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (red: Int, green: Int, blue: Int) {
        let renderer = ImageRenderService()
        let cgImage = try renderer.makeCGImage(image)
        let quarterW = CGFloat(cgImage.width) / 4
        let quarterH = CGFloat(cgImage.height) / 4
        let point: CGPoint
        switch quadrant {
        case .topLeft: point = CGPoint(x: quarterW, y: quarterH)
        case .topRight: point = CGPoint(x: quarterW * 3, y: quarterH)
        case .bottomLeft: point = CGPoint(x: quarterW, y: quarterH * 3)
        case .bottomRight: point = CGPoint(x: quarterW * 3, y: quarterH * 3)
        }

        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), file: file, line: line)
        // CGContext's own origin is bottom-left, so flip the requested row
        // and offset the full-size draw so the wanted pixel lands on the
        // 1x1 canvas -- the same trick `AdjustmentPipelineTests.pixel(at:)`
        // uses.
        context.draw(cgImage, in: CGRect(
            x: -point.x,
            y: -(CGFloat(cgImage.height) - 1 - point.y),
            width: CGFloat(cgImage.width),
            height: CGFloat(cgImage.height)
        ))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func assertColor(
        _ sample: (red: Int, green: Int, blue: Int),
        isApproximately expected: (red: Int, green: Int, blue: Int),
        tolerance: Int = 20,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(abs(sample.red - expected.red), tolerance, "red " + message, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(sample.green - expected.green), tolerance, "green " + message, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(sample.blue - expected.blue), tolerance, "blue " + message, file: file, line: line)
    }

    private let red = (red: 255, green: 0, blue: 0)
    private let green = (red: 0, green: 255, blue: 0)
    private let blue = (red: 0, green: 0, blue: 255)
    private let yellow = (red: 255, green: 255, blue: 0)

    // MARK: - Neutral / identity

    func testNeutralGeometryIsAnExactPassthrough() throws {
        let source = makeQuadrantImage()
        let output = GeometryRenderer.apply(.neutral, to: source)
        try assertColor(sample(.topLeft, of: output), isApproximately: red, tolerance: 2)
        try assertColor(sample(.topRight, of: output), isApproximately: green, tolerance: 2)
        try assertColor(sample(.bottomLeft, of: output), isApproximately: blue, tolerance: 2)
        try assertColor(sample(.bottomRight, of: output), isApproximately: yellow, tolerance: 2)
        XCTAssertEqual(output.extent, source.extent)
    }

    // MARK: - Rotate 90 (exact)

    func testRotateClockwise90MovesTheTopLeftMarkerToTheTopRight() throws {
        let source = makeQuadrantImage()
        let geometry = GeometryAdjustments(rotationDegrees: 90)
        let output = GeometryRenderer.apply(geometry, to: source)

        // A 90deg clockwise turn: old top-left -> new top-right, old
        // top-right -> new bottom-right, old bottom-right -> new
        // bottom-left, old bottom-left -> new top-left.
        try assertColor(sample(.topLeft, of: output), isApproximately: blue, tolerance: 2)
        try assertColor(sample(.topRight, of: output), isApproximately: red, tolerance: 2)
        try assertColor(sample(.bottomRight, of: output), isApproximately: green, tolerance: 2)
        try assertColor(sample(.bottomLeft, of: output), isApproximately: yellow, tolerance: 2)
    }

    func testRotate180PutsTheOppositeCornerOnTop() throws {
        let source = makeQuadrantImage()
        let geometry = GeometryAdjustments(rotationDegrees: 180)
        let output = GeometryRenderer.apply(geometry, to: source)

        try assertColor(sample(.topLeft, of: output), isApproximately: yellow, tolerance: 2)
        try assertColor(sample(.topRight, of: output), isApproximately: blue, tolerance: 2)
        try assertColor(sample(.bottomLeft, of: output), isApproximately: green, tolerance: 2)
        try assertColor(sample(.bottomRight, of: output), isApproximately: red, tolerance: 2)
    }

    func testRotate270IsTheInverseOfRotate90() throws {
        let source = makeQuadrantImage()
        let geometry = GeometryAdjustments(rotationDegrees: 270)
        let output = GeometryRenderer.apply(geometry, to: source)

        try assertColor(sample(.topLeft, of: output), isApproximately: green, tolerance: 2)
        try assertColor(sample(.topRight, of: output), isApproximately: yellow, tolerance: 2)
        try assertColor(sample(.bottomLeft, of: output), isApproximately: red, tolerance: 2)
        try assertColor(sample(.bottomRight, of: output), isApproximately: blue, tolerance: 2)
    }

    func testRotate90SwapsWidthAndHeight() {
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 8))
        let output = GeometryRenderer.apply(GeometryAdjustments(rotationDegrees: 90), to: source)
        XCTAssertEqual(output.extent.width, 8, accuracy: 0.01)
        XCTAssertEqual(output.extent.height, 16, accuracy: 0.01)
    }

    // MARK: - Flip (exact)

    func testFlippingHorizontalMirrorsLeftAndRight() throws {
        let source = makeQuadrantImage()
        let geometry = GeometryAdjustments(flipHorizontal: true)
        let output = GeometryRenderer.apply(geometry, to: source)

        try assertColor(sample(.topLeft, of: output), isApproximately: green, tolerance: 2)
        try assertColor(sample(.topRight, of: output), isApproximately: red, tolerance: 2)
        try assertColor(sample(.bottomLeft, of: output), isApproximately: yellow, tolerance: 2)
        try assertColor(sample(.bottomRight, of: output), isApproximately: blue, tolerance: 2)
    }

    func testFlippingVerticalMirrorsTopAndBottom() throws {
        let source = makeQuadrantImage()
        let geometry = GeometryAdjustments(flipVertical: true)
        let output = GeometryRenderer.apply(geometry, to: source)

        try assertColor(sample(.topLeft, of: output), isApproximately: blue, tolerance: 2)
        try assertColor(sample(.topRight, of: output), isApproximately: yellow, tolerance: 2)
        try assertColor(sample(.bottomLeft, of: output), isApproximately: red, tolerance: 2)
        try assertColor(sample(.bottomRight, of: output), isApproximately: green, tolerance: 2)
    }

    func testFlippingBothAxesIsTheSameAsRotating180() throws {
        let source = makeQuadrantImage()
        let flipped = GeometryRenderer.apply(GeometryAdjustments(flipHorizontal: true, flipVertical: true), to: source)
        let rotated = GeometryRenderer.apply(GeometryAdjustments(rotationDegrees: 180), to: source)

        try assertColor(sample(.topLeft, of: flipped), isApproximately: sample(.topLeft, of: rotated), tolerance: 2)
        try assertColor(sample(.bottomRight, of: flipped), isApproximately: sample(.bottomRight, of: rotated), tolerance: 2)
    }

    // MARK: - Crop (exact)

    func testCroppingToTheTopLeftQuarterLeavesOnlyThatColor() throws {
        let source = makeQuadrantImage()
        let geometry = GeometryAdjustments(crop: NormalizedCropRect(x: 0, y: 0, width: 0.5, height: 0.5))
        let output = GeometryRenderer.apply(geometry, to: source)

        XCTAssertEqual(output.extent.width, 4, accuracy: 0.01)
        XCTAssertEqual(output.extent.height, 4, accuracy: 0.01)
        try assertColor(sample(.topLeft, of: output), isApproximately: red, tolerance: 2)
        try assertColor(sample(.topRight, of: output), isApproximately: red, tolerance: 2)
        try assertColor(sample(.bottomLeft, of: output), isApproximately: red, tolerance: 2)
        try assertColor(sample(.bottomRight, of: output), isApproximately: red, tolerance: 2)
    }

    func testCroppingToTheBottomRightQuarterLeavesOnlyThatColor() throws {
        let source = makeQuadrantImage()
        let geometry = GeometryAdjustments(crop: NormalizedCropRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        let output = GeometryRenderer.apply(geometry, to: source)

        try assertColor(sample(.topLeft, of: output), isApproximately: yellow, tolerance: 2)
        try assertColor(sample(.bottomRight, of: output), isApproximately: yellow, tolerance: 2)
    }

    func testFullFrameCropIsANoOp() throws {
        let source = makeQuadrantImage()
        let geometry = GeometryAdjustments(crop: .full)
        let output = GeometryRenderer.apply(geometry, to: source)
        XCTAssertEqual(output.extent, source.extent)
    }

    // MARK: - Crop then rotate (documented order)

    func testCropThenRotateAppliesCropInTheSourcesOwnCoordinateSpace() throws {
        let source = makeQuadrantImage()
        // Crop to the visual top half (red + green), then rotate 90deg CW.
        // Documented order: crop happens first, in the un-rotated source's
        // own coordinates, so this must crop the *original* top half, not
        // whatever ends up "on top" after rotating.
        let geometry = GeometryAdjustments(
            crop: NormalizedCropRect(x: 0, y: 0, width: 1, height: 0.5),
            rotationDegrees: 90
        )
        let output = GeometryRenderer.apply(geometry, to: source)

        XCTAssertEqual(output.extent.width, 4, accuracy: 0.01, "cropped height (4) becomes the rotated width")
        XCTAssertEqual(output.extent.height, 8, accuracy: 0.01, "cropped width (8) becomes the rotated height")
        // Top half was red (left) + green (right); rotating that strip 90
        // CW puts red at the top and green at the bottom.
        try assertColor(sample(.topLeft, of: output), isApproximately: red, tolerance: 2)
        try assertColor(sample(.topRight, of: output), isApproximately: red, tolerance: 2)
        try assertColor(sample(.bottomLeft, of: output), isApproximately: green, tolerance: 2)
        try assertColor(sample(.bottomRight, of: output), isApproximately: green, tolerance: 2)
    }

    // MARK: - Straighten (tolerance / property-based)

    func testStraightenLeavesTheCanvasSizeUnchanged() {
        let source = makeQuadrantImage()
        let output = GeometryRenderer.apply(GeometryAdjustments(straightenDegrees: 15), to: source)
        XCTAssertEqual(output.extent, source.extent, "straighten is clamped back to the working canvas, not grown")
    }

    func testStraightenByZeroIsAnExactPassthrough() throws {
        let source = makeQuadrantImage()
        let output = GeometryRenderer.apply(GeometryAdjustments(straightenDegrees: 0), to: source)
        try assertColor(sample(.topLeft, of: output), isApproximately: red, tolerance: 2)
    }

    func testStraightenActuallyMovesContentRelativeToUnstraightened() throws {
        // A much bigger canvas than the other tests' 8x8: the seam shift a
        // modest angle produces scales with distance from the rotation
        // centre, and 8px isn't enough radius for a robust, non-flaky
        // sub-pixel-adjacent assertion.
        let bigSize = CGSize(width: 64, height: 64)
        let source = makeQuadrantImage(size: bigSize)
        let straight = GeometryRenderer.apply(.neutral, to: source)
        let straightened = GeometryRenderer.apply(GeometryAdjustments(straightenDegrees: 20), to: source)

        let renderer = ImageRenderService()
        let straightCG = try renderer.makeCGImage(straight)
        let straightenedCG = try renderer.makeCGImage(straightened)
        XCTAssertEqual(straightCG.width, straightenedCG.width)
        XCTAssertEqual(straightCG.height, straightenedCG.height)

        func edgePixel(_ image: CGImage) throws -> (red: Int, green: Int, blue: Int) {
            var bytes = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(
                data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            // Right at the vertical seam (red|green), on the very top row --
            // far enough from the rotation centre that a 20deg turn clearly
            // moves which quadrant's colour lands here.
            let point = CGPoint(x: CGFloat(image.width) / 2, y: 0)
            context.draw(image, in: CGRect(
                x: -point.x, y: -(CGFloat(image.height) - 1 - point.y),
                width: CGFloat(image.width), height: CGFloat(image.height)
            ))
            return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
        }

        let before = try edgePixel(straightCG)
        let after = try edgePixel(straightenedCG)
        XCTAssertTrue(
            before.red != after.red || before.green != after.green || before.blue != after.blue,
            "a 20deg straighten should visibly move the seam near the edge -- before=\(before) after=\(after)"
        )
    }

    func testStraightenPositiveThenNegativeRoughlyCancelsAtTheCentre() throws {
        let source = makeQuadrantImage()
        let there = GeometryRenderer.apply(GeometryAdjustments(straightenDegrees: 12), to: source)
        let thereAndBack = GeometryRenderer.apply(GeometryAdjustments(straightenDegrees: -12), to: there)
        // The deep centre of each quadrant survives a small round-trip
        // rotation; this is a property check, not a claim that straighten
        // is losslessly invertible in general (edges are not preserved).
        try assertColor(sample(.topLeft, of: thereAndBack), isApproximately: red, tolerance: 40)
    }

    // MARK: - Perspective (tolerance / property-based)

    func testNeutralPerspectiveIsAnExactPassthrough() throws {
        let source = makeQuadrantImage()
        let output = GeometryRenderer.apply(GeometryAdjustments(perspectiveHorizontal: 0, perspectiveVertical: 0), to: source)
        try assertColor(sample(.topLeft, of: output), isApproximately: red, tolerance: 2)
        XCTAssertEqual(output.extent, source.extent)
    }

    func testPerspectiveLeavesTheCanvasSizeUnchanged() {
        let source = makeQuadrantImage()
        let output = GeometryRenderer.apply(GeometryAdjustments(perspectiveHorizontal: 40), to: source)
        XCTAssertEqual(output.extent, source.extent)
    }

    func testOppositeSignedHorizontalPerspectiveProducesDifferentResults() throws {
        let source = makeQuadrantImage()
        let positive = GeometryRenderer.apply(GeometryAdjustments(perspectiveHorizontal: 60), to: source)
        let negative = GeometryRenderer.apply(GeometryAdjustments(perspectiveHorizontal: -60), to: source)

        let renderer = ImageRenderService()
        let positiveCG = try renderer.makeCGImage(positive)
        let negativeCG = try renderer.makeCGImage(negative)

        func topEdgePixel(_ image: CGImage) throws -> (red: Int, green: Int, blue: Int) {
            var bytes = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(
                data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            let point = CGPoint(x: CGFloat(image.width) / 2 - 1, y: 1)
            context.draw(image, in: CGRect(
                x: -point.x, y: -(CGFloat(image.height) - 1 - point.y),
                width: CGFloat(image.width), height: CGFloat(image.height)
            ))
            return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
        }

        let positiveTop = try topEdgePixel(positiveCG)
        let negativeTop = try topEdgePixel(negativeCG)
        XCTAssertTrue(
            positiveTop.red != negativeTop.red || positiveTop.green != negativeTop.green || positiveTop.blue != negativeTop.blue,
            "opposite-signed perspective must not render identically"
        )
    }

    // MARK: - appliedPixelSize (pure, no rendering)

    func testAppliedPixelSizeIsUnchangedForNeutralGeometry() {
        let size = GeometryRenderer.appliedPixelSize(of: CGSize(width: 4_000, height: 3_000), geometry: .neutral)
        XCTAssertEqual(size, CGSize(width: 4_000, height: 3_000))
    }

    func testAppliedPixelSizeScalesByTheCropFraction() {
        let geometry = GeometryAdjustments(crop: NormalizedCropRect(x: 0, y: 0, width: 0.5, height: 0.25))
        let size = GeometryRenderer.appliedPixelSize(of: CGSize(width: 4_000, height: 4_000), geometry: geometry)
        XCTAssertEqual(size, CGSize(width: 2_000, height: 1_000))
    }

    func testAppliedPixelSizeSwapsDimensionsForA90DegreeRotation() {
        let geometry = GeometryAdjustments(rotationDegrees: 90)
        let size = GeometryRenderer.appliedPixelSize(of: CGSize(width: 4_000, height: 3_000), geometry: geometry)
        XCTAssertEqual(size, CGSize(width: 3_000, height: 4_000))
    }

    func testAppliedPixelSizeDoesNotSwapFor180DegreeRotation() {
        let geometry = GeometryAdjustments(rotationDegrees: 180)
        let size = GeometryRenderer.appliedPixelSize(of: CGSize(width: 4_000, height: 3_000), geometry: geometry)
        XCTAssertEqual(size, CGSize(width: 4_000, height: 3_000))
    }

    func testAppliedPixelSizeCombinesCropAndRotate() {
        let geometry = GeometryAdjustments(
            crop: NormalizedCropRect(x: 0, y: 0, width: 0.5, height: 0.5),
            rotationDegrees: 90
        )
        let size = GeometryRenderer.appliedPixelSize(of: CGSize(width: 4_000, height: 2_000), geometry: geometry)
        // Crop first: 2000x1000. Then a 90deg rotate swaps to 1000x2000.
        XCTAssertEqual(size, CGSize(width: 1_000, height: 2_000))
    }

    func testAppliedPixelSizeIsUnchangedByStraightenOrPerspectiveAlone() {
        let geometry = GeometryAdjustments(straightenDegrees: 10, perspectiveHorizontal: 30)
        let size = GeometryRenderer.appliedPixelSize(of: CGSize(width: 4_000, height: 3_000), geometry: geometry)
        XCTAssertEqual(size, CGSize(width: 4_000, height: 3_000))
    }
}
