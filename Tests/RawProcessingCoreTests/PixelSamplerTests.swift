import CoreGraphics
import CoreImage
import XCTest
@testable import RawProcessingCore

final class PixelSamplerTests: XCTestCase {
    /// A four-quadrant marker image, built and rendered the same way
    /// `GeometryRendererTests.makeQuadrantImage` is, so a coordinate-mapping
    /// mistake shows up as a wrong colour rather than a passing test that
    /// happens to still add up. Visual top-left red, top-right green,
    /// bottom-left blue, bottom-right yellow.
    private func makeQuadrantCGImage(size: CGSize = CGSize(width: 8, height: 8)) throws -> CGImage {
        let half = CGSize(width: size.width / 2, height: size.height / 2)
        func quad(_ color: CIColor, x: CGFloat, y: CGFloat) -> CIImage {
            CIImage(color: color).cropped(to: CGRect(x: x, y: y, width: half.width, height: half.height))
        }
        let topLeft = quad(.red, x: 0, y: half.height)
        let topRight = quad(.green, x: half.width, y: half.height)
        let bottomLeft = quad(.blue, x: 0, y: 0)
        let bottomRight = quad(CIColor(red: 1, green: 1, blue: 0), x: half.width, y: 0)
        let composed = topLeft
            .composited(over: topRight)
            .composited(over: bottomLeft)
            .composited(over: bottomRight)
            .cropped(to: CGRect(origin: .zero, size: size))
        return try ImageRenderService().makeCGImage(composed)
    }

    private func assertApproximately(
        _ sample: (red: Double, green: Double, blue: Double)?,
        _ expected: (red: Double, green: Double, blue: Double),
        tolerance: Double = 0.1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let sample = try XCTUnwrap(sample, file: file, line: line)
        XCTAssertEqual(sample.red, expected.red, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(sample.green, expected.green, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(sample.blue, expected.blue, accuracy: tolerance, file: file, line: line)
    }

    func testSamplingTheVisualTopLeftReadsRed() throws {
        let image = try makeQuadrantCGImage()
        let sample = PixelSampler.sample(at: CGPoint(x: 2, y: 2), in: image)
        try assertApproximately(sample, (1, 0, 0))
    }

    func testSamplingTheVisualTopRightReadsGreen() throws {
        let image = try makeQuadrantCGImage()
        let sample = PixelSampler.sample(at: CGPoint(x: 6, y: 2), in: image)
        try assertApproximately(sample, (0, 1, 0))
    }

    func testSamplingTheVisualBottomLeftReadsBlue() throws {
        let image = try makeQuadrantCGImage()
        let sample = PixelSampler.sample(at: CGPoint(x: 2, y: 6), in: image)
        try assertApproximately(sample, (0, 0, 1))
    }

    func testSamplingTheVisualBottomRightReadsYellow() throws {
        let image = try makeQuadrantCGImage()
        let sample = PixelSampler.sample(at: CGPoint(x: 6, y: 6), in: image)
        try assertApproximately(sample, (1, 1, 0))
    }

    func testOutOfBoundsPointsClampToTheNearestEdgePixelRatherThanReturningNil() throws {
        let image = try makeQuadrantCGImage()
        let sample = PixelSampler.sample(at: CGPoint(x: -50, y: -50), in: image)
        try assertApproximately(sample, (1, 0, 0))
    }

    func testAOnePixelImageSamplesItsOnlyPixel() throws {
        let image = try makeQuadrantCGImage(size: CGSize(width: 1, height: 1))
        let sample = PixelSampler.sample(at: CGPoint(x: 0, y: 0), in: image)
        XCTAssertNotNil(sample)
    }
}
