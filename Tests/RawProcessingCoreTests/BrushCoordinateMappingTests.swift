import CoreGraphics
import CoreImage
import XCTest
@testable import RawProcessingCore

final class BrushCoordinateMappingTests: XCTestCase {
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
