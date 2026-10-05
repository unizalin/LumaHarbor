import CoreGraphics
import CoreImage
import XCTest
@testable import RawProcessingCore

final class BrushCoordinateMappingTests: XCTestCase {
    private func renderedRedCentroid(
        sourcePoint: CGPoint,
        sourceSize: CGSize,
        geometry: GeometryAdjustments
    ) throws -> CGPoint {
        let sourceExtent = CGRect(origin: .zero, size: sourceSize)
        let sourcePixel = CGPoint(
            x: sourcePoint.x * sourceSize.width,
            y: (1 - sourcePoint.y) * sourceSize.height
        )
        let marker = CIImage(color: .red).cropped(to: CGRect(
            x: sourcePixel.x - 1.5, y: sourcePixel.y - 1.5, width: 3, height: 3
        ))
        let source = marker
            .composited(over: CIImage(color: .black).cropped(to: sourceExtent))
            .cropped(to: sourceExtent)
        let output = GeometryRenderer.apply(geometry, to: source)
        let cgImage = try ImageRenderService().makeCGImage(output)
        guard let provider = cgImage.dataProvider,
              let data = provider.data as Data? else {
            throw BrushCoordinateMappingError.invalidExtent
        }
        let bytesPerPixel = max(cgImage.bitsPerPixel / 8, 4)
        let bytes = [UInt8](data)
        var sumX = 0.0
        var sumY = 0.0
        var count = 0.0
        for y in 0..<cgImage.height {
            for x in 0..<cgImage.width {
                let index = y * cgImage.bytesPerRow + x * bytesPerPixel
                guard index + 2 < bytes.count else { continue }
                if bytes[index] > 180, bytes[index + 1] < 100, bytes[index + 2] < 100 {
                    sumX += Double(x) + 0.5
                    sumY += Double(y) + 0.5
                    count += 1
                }
            }
        }
        guard count > 0 else { throw BrushCoordinateMappingError.outsideDisplay }
        return CGPoint(x: sumX / count, y: sumY / count)
    }

    func testMappingUsesGeometryRendererPixelOracleAcrossGeometryFamilies() throws {
        let sourceSize = CGSize(width: 64, height: 48)
        let source = CGPoint(x: 0.37, y: 0.28)
        let crop = NormalizedCropRect(x: 0.1, y: 0.08, width: 0.8, height: 0.84)
        let pins = PerspectiveCornerPins(
            topLeft: NormalizedPoint(x: 0.08, y: 0.10),
            topRight: NormalizedPoint(x: 0.92, y: 0.04),
            bottomLeft: NormalizedPoint(x: 0.04, y: 0.90),
            bottomRight: NormalizedPoint(x: 0.96, y: 0.84)
        )
        let cases: [GeometryAdjustments] = [
            GeometryAdjustments(flipHorizontal: true),
            GeometryAdjustments(flipVertical: true),
            GeometryAdjustments(flipHorizontal: true, flipVertical: true),
            GeometryAdjustments(rotationDegrees: 180),
            GeometryAdjustments(rotationDegrees: 270),
            GeometryAdjustments(crop: crop),
            GeometryAdjustments(straightenDegrees: 10),
            GeometryAdjustments(straightenDegrees: -10),
            GeometryAdjustments(perspectiveHorizontal: 25),
            GeometryAdjustments(perspectiveVertical: -25),
            GeometryAdjustments(cornerPins: pins)
        ]
        for geometry in cases {
            let mapping = try BrushCoordinateMapping(sourceSize: sourceSize, geometry: geometry)
            let expected = try mapping.sourceToDisplay(source)
            let observed = try renderedRedCentroid(sourcePoint: source, sourceSize: sourceSize, geometry: geometry)
            let expectedPixel = CGPoint(
                x: expected.x,
                y: expected.y
            )
            XCTAssertEqual(observed.x, expectedPixel.x, accuracy: 3.5, "geometry=\(geometry)")
            XCTAssertEqual(observed.y, expectedPixel.y, accuracy: 3.5, "geometry=\(geometry)")
        }
    }

    func testIdentityMapsNonCentralLandmarkWithNonZeroExtent() throws {
        let mapping = try BrushCoordinateMapping(
            sourceExtent: CGRect(x: 17, y: 23, width: 160, height: 80),
            geometry: .neutral
        )
        let display = try mapping.sourceToDisplay(CGPoint(x: 0.75, y: 0.25))
        XCTAssertEqual(display.x, 137, accuracy: 0.01)
        XCTAssertEqual(display.y, 43, accuracy: 0.01)
        let source = try mapping.displayToSource(display)
        XCTAssertEqual(source.x, 0.75, accuracy: 1e-6)
        XCTAssertEqual(source.y, 0.25, accuracy: 1e-6)
    }

    func testHorizontalFlipDoesNotUseIdentityFallback() throws {
        let mapping = try BrushCoordinateMapping(
            sourceExtent: CGRect(x: 0, y: 0, width: 160, height: 80),
            geometry: GeometryAdjustments(flipHorizontal: true)
        )
        let display = try mapping.sourceToDisplay(CGPoint(x: 0.2, y: 0.25))
        XCTAssertEqual(display.x, 128, accuracy: 0.01)
        XCTAssertEqual(display.y, 20, accuracy: 0.01)
        XCTAssertNotEqual(display.x, 32, accuracy: 0.01)
    }

    func testClockwiseNinetyMapsTopLeftLandmarkToTopRight() throws {
        let mapping = try BrushCoordinateMapping(
            sourceExtent: CGRect(origin: .zero, size: CGSize(width: 160, height: 80)),
            geometry: GeometryAdjustments(rotationDegrees: 90)
        )
        let display = try mapping.sourceToDisplay(CGPoint(x: 0.2, y: 0.2))
        XCTAssertEqual(display.x, 64, accuracy: 0.01)
        XCTAssertEqual(display.y, 32, accuracy: 0.01)
    }

    func testOutsideCropAndNonInvertibleMappingAreRejected() throws {
        let crop = NormalizedCropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let mapping = try BrushCoordinateMapping(
            sourceExtent: CGRect(origin: .zero, size: CGSize(width: 100, height: 50)),
            geometry: GeometryAdjustments(crop: crop)
        )
        XCTAssertThrowsError(try mapping.sourceToDisplay(CGPoint(x: 0.1, y: 0.1)))
        XCTAssertThrowsError(try mapping.displayToSource(CGPoint(x: -1, y: 10)))

        XCTAssertThrowsError(try BrushCoordinateMapping(
            sourceExtent: CGRect(x: 0, y: 0, width: 0, height: 40), geometry: .neutral
        ))

        let collapsed = PerspectiveCornerPins(
            topLeft: NormalizedPoint(x: 0.5, y: 0.5),
            topRight: NormalizedPoint(x: 0.5, y: 0.5),
            bottomLeft: NormalizedPoint(x: 0.5, y: 0.5),
            bottomRight: NormalizedPoint(x: 0.5, y: 0.5)
        )
        XCTAssertThrowsError(try BrushCoordinateMapping(
            sourceExtent: CGRect(origin: .zero, size: CGSize(width: 100, height: 50)),
            geometry: GeometryAdjustments(cornerPins: collapsed)
        ))
    }

    func testCombinedGeometryRoundTripsIndependentLandmark() throws {
        let geometry = GeometryAdjustments(
            crop: NormalizedCropRect(x: 0.1, y: 0.15, width: 0.8, height: 0.7),
            rotationDegrees: 90,
            flipVertical: true,
            straightenDegrees: 10,
            perspectiveHorizontal: 25,
            perspectiveVertical: -25
        )
        let mapping = try BrushCoordinateMapping(
            sourceExtent: CGRect(origin: .zero, size: CGSize(width: 320, height: 180)),
            geometry: geometry
        )
        let source = CGPoint(x: 0.67, y: 0.22)
        let display = try mapping.sourceToDisplay(source)
        let roundTrip = try mapping.displayToSource(display)
        XCTAssertEqual(roundTrip.x, source.x, accuracy: 1e-5)
        XCTAssertEqual(roundTrip.y, source.y, accuracy: 1e-5)
    }
}
