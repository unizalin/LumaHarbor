import XCTest
@testable import RawProcessingCore

final class BrushMaskTests: XCTestCase {
    func testNeutralPatchAllowsNilAndClosedRangeEndpoints() throws {
        let patch = BrushMaskPatch(
            exposure: -5,
            contrast: 100,
            highlights: nil,
            shadows: -100,
            whites: 100,
            blacks: -100,
            saturation: 100,
            temperature: -1_200,
            tint: 100
        )
        XCTAssertNoThrow(try patch.validated())
    }

    func testPatchRejectsOutOfRangeAndNonFiniteValues() {
        for keyPath in [
            \BrushMaskPatch.exposure, \BrushMaskPatch.contrast,
            \BrushMaskPatch.highlights, \BrushMaskPatch.shadows,
            \BrushMaskPatch.whites, \BrushMaskPatch.blacks,
            \BrushMaskPatch.saturation, \BrushMaskPatch.temperature,
            \BrushMaskPatch.tint
        ] {
            var patch = BrushMaskPatch()
            patch[keyPath: keyPath] = keyPath == \BrushMaskPatch.temperature ? 1_201 : 101
            XCTAssertThrowsError(try patch.validated(), "expected (keyPath) to reject an upper-bound overflow")
            patch[keyPath: keyPath] = .infinity
            XCTAssertThrowsError(try patch.validated(), "expected (keyPath) to reject infinity")
        }
    }

    func testSourceCoordinatePathAndStrokeRoundTrip() throws {
        let point = BrushMaskPoint(x: 0.125, y: 0.875, pressure: 0.5)
        let path = BrushMaskPath(points: [point])
        let stroke = BrushMaskStroke(path: path, mode: .erase, size: 0.2, feather: 0.3, flow: 0.4, density: 0.5)
        let mask = try BrushMask(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Sky",
            rendererVersion: 1,
            strokes: [stroke],
            adjustments: BrushMaskPatch(exposure: 1.25, temperature: -30)
        ).validated()

        let data = try JSONEncoder().encode(mask)
        let decoded = try JSONDecoder().decode(BrushMask.self, from: data)
        XCTAssertEqual(decoded, mask)
        XCTAssertEqual(decoded.strokes.first?.mode, .erase)
        XCTAssertEqual(decoded.strokes.first?.path.points.first?.x, 0.125)
    }

    func testUnknownRendererVersionIsRejected() throws {
        let mask = BrushMask(rendererVersion: 2)
        XCTAssertThrowsError(try mask.validated())
    }

    func testLegacyExperimentalV3BrushShapeDecodes() throws {
        let json = Data(#"""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "rendererVersion": 1,
          "strokes": [{
            "mode": "paint",
            "points": [{"x": 0.25, "y": 0.75}],
            "size": 0.1,
            "feather": 0.2,
            "flow": 1,
            "density": 1
          }],
          "adjustments": {"exposure": 1}
        }
        """#.utf8)
        let decoded = try JSONDecoder().decode(BrushMask.self, from: json)
        XCTAssertEqual(decoded.rendererVersion, 1)
        XCTAssertEqual(decoded.strokes.count, 1)
        XCTAssertEqual(decoded.adjustments.exposure, 1)
    }
}
