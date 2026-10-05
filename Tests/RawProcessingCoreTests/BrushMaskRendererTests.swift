import CoreGraphics
import CoreImage
import XCTest
@testable import RawProcessingCore

final class BrushMaskRendererTests: XCTestCase {
    private func baseImage(size: CGSize = CGSize(width: 100, height: 60)) -> CIImage {
        CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    private func sample(_ image: CIImage, at point: CGPoint) throws -> (UInt8, UInt8, UInt8, UInt8) {
        let cg = try ImageRenderService().makeCGImage(image)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cg, in: CGRect(
            x: -point.x, y: -(CGFloat(cg.height) - point.y - 1),
            width: CGFloat(cg.width), height: CGFloat(cg.height)
        ))
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }

    func testPaintAndEraseRespectNonCentralQuadrant() throws {
        let path = BrushMaskPath(points: [
            BrushMaskPoint(x: 0.72, y: 0.25),
            BrushMaskPoint(x: 0.82, y: 0.25)
        ])
        let paint = BrushMaskStroke(path: path, size: 0.2, feather: 0.1, flow: 1)
        let erase = BrushMaskStroke(path: BrushMaskPath(points: [BrushMaskPoint(x: 0.77, y: 0.25)]), mode: .erase, size: 0.08)
        let mask = BrushMask(strokes: [paint, erase], adjustments: BrushMaskPatch(exposure: 2))
        let output = BrushMaskRenderer.apply([mask], to: baseImage())
        let affected = try sample(output, at: CGPoint(x: 72, y: 15))
        let affectedBottom = try sample(output, at: CGPoint(x: 77, y: 45))
        let untouched = try sample(output, at: CGPoint(x: 15, y: 45))
        XCTAssertGreaterThan(affected.0, untouched.0, "paint must affect the non-central stroke")
        XCTAssertEqual(affectedBottom.0, untouched.0, accuracy: 2)
    }

    func testSparseAndDenseCollinearPathsProduceComparablePixels() throws {
        let sparse = BrushMaskPath(points: [BrushMaskPoint(x: 0.1, y: 0.8), BrushMaskPoint(x: 0.9, y: 0.8)])
        let dense = BrushMaskPath(points: stride(from: 0.1, through: 0.9, by: 0.05).map { BrushMaskPoint(x: $0, y: 0.8) })
        let a = BrushMaskRenderer.apply([BrushMask(strokes: [BrushMaskStroke(path: sparse, size: 0.08),], adjustments: BrushMaskPatch(exposure: 1))], to: baseImage())
        let b = BrushMaskRenderer.apply([BrushMask(strokes: [BrushMaskStroke(path: dense, size: 0.08),], adjustments: BrushMaskPatch(exposure: 1))], to: baseImage())
        let pa = try sample(a, at: CGPoint(x: 50, y: 48))
        let pb = try sample(b, at: CGPoint(x: 50, y: 48))
        XCTAssertLessThanOrEqual(abs(Int(pa.0) - Int(pb.0)), 6)
    }

    func testRepeatedPointsAndEmptyMasksAreSafeIdentity() throws {
        let repeated = BrushMaskPath(points: Array(repeating: BrushMaskPoint(x: 0.5, y: 0.5), count: 4))
        XCTAssertNoThrow(_ = BrushMaskRenderer.apply([BrushMask(strokes: [BrushMaskStroke(path: repeated, flow: 0.2)])], to: baseImage()))
        let source = baseImage()
        let output = BrushMaskRenderer.apply([], to: source)
        XCTAssertEqual(output.extent, source.extent)
    }

    func testStrictRendererRejectsOutsideMappingInsteadOfClamping() throws {
        let image = baseImage()
        let geometry = GeometryAdjustments(crop: NormalizedCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let mapping = try BrushCoordinateMapping(sourceExtent: image.extent, geometry: geometry)
        let mask = BrushMask(
            strokes: [BrushMaskStroke(points: [BrushMaskPoint(x: 0.05, y: 0.05)])],
            adjustments: BrushMaskPatch(exposure: 1)
        )
        XCTAssertThrowsError(try BrushMaskRenderer.applyValidated([mask], to: image, mapping: mapping))
    }
}
