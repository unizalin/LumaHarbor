import XCTest
@testable import RawProcessingCore

final class AdvancedMasksModelTests: XCTestCase {
    func testLocalAdjustmentKindAllCasesExist() {
        let kinds: [LocalAdjustmentKind] = [
            .linearGradient,
            .radialGradient,
            .brush,
            .luminanceRange,
            .colorRange,
            .subject,
            .background,
            .spotHeal
        ]
        XCTAssertEqual(kinds.count, 8)
        XCTAssertEqual(LocalAdjustmentKind.radialGradient.rawValue, "radialGradient")
        XCTAssertEqual(LocalAdjustmentKind.brush.rawValue, "brush")
        XCTAssertEqual(LocalAdjustmentKind.luminanceRange.rawValue, "luminanceRange")
        XCTAssertEqual(LocalAdjustmentKind.colorRange.rawValue, "colorRange")
        XCTAssertEqual(LocalAdjustmentKind.subject.rawValue, "subject")
        XCTAssertEqual(LocalAdjustmentKind.background.rawValue, "background")
    }

    func testLocalAdjustmentDefaultsForNewFields() {
        let adj = LocalAdjustment(kind: .brush)
        XCTAssertEqual(adj.name, "")
        XCTAssertEqual(adj.opacity, 100)
        XCTAssertFalse(adj.isInverted)
    }

    func testLocalAdjustmentCustomPropertiesRoundTrip() throws {
        var adj = LocalAdjustment(kind: .radialGradient)
        adj.name = "Sky Radial"
        adj.opacity = 75
        adj.isInverted = true

        let data = try JSONEncoder().encode(adj)
        let decoded = try JSONDecoder().decode(LocalAdjustment.self, from: data)

        XCTAssertEqual(decoded.name, "Sky Radial")
        XCTAssertEqual(decoded.opacity, 75)
        XCTAssertTrue(decoded.isInverted)
    }

    func testBrushStrokeAndPointClamping() {
        let point = BrushPoint(x: 1.5, y: -0.2, pressure: 1.2)
        XCTAssertEqual(point.x, 1.0)
        XCTAssertEqual(point.y, 0.0)
        XCTAssertEqual(point.pressure, 1.0)

        let stroke = BrushStroke(
            points: [point],
            radius: 2.0,
            feather: 150
        )
        XCTAssertEqual(stroke.radius, 1.0)
        XCTAssertEqual(stroke.feather, 100)
    }

    func testRangeMaskGeometryClamping() {
        var geo = LocalAdjustmentGeometry()
        geo.luminanceMin = -0.5
        geo.luminanceMax = 1.5
        geo.colorTargetHue = 400
        geo.colorHueTolerance = 200

        XCTAssertEqual(geo.luminanceMin, 0.0)
        XCTAssertEqual(geo.luminanceMax, 1.0)
        XCTAssertEqual(geo.colorTargetHue, 40)
        XCTAssertEqual(geo.colorHueTolerance, 180)
    }

    func testSpotHealRedEyeMode() {
        XCTAssertEqual(SpotHealMode.redEye.rawValue, "redEye")
        var geo = LocalAdjustmentGeometry()
        geo.healMode = .redEye
        geo.redEyePupilRadius = 0.03
        XCTAssertEqual(geo.healMode, .redEye)
        XCTAssertEqual(geo.redEyePupilRadius, 0.03)
    }

    func testPerspectiveCornerPins() {
        let pins = PerspectiveCornerPins.standard
        XCTAssertTrue(pins.isIdentity)

        let customPins = PerspectiveCornerPins(
            topLeft: NormalizedPoint(x: 0.1, y: 0.05),
            topRight: NormalizedPoint(x: 0.9, y: 0.05),
            bottomLeft: NormalizedPoint(x: 0.05, y: 0.95),
            bottomRight: NormalizedPoint(x: 0.95, y: 0.95)
        )
        XCTAssertFalse(customPins.isIdentity)

        var geo = GeometryAdjustments.neutral
        XCTAssertTrue(geo.isIdentity)
        geo.cornerPins = customPins
        XCTAssertFalse(geo.isIdentity)

        let resetGeo = geo.resettingPerspective()
        XCTAssertNil(resetGeo.cornerPins)
        XCTAssertTrue(resetGeo.isIdentity)
    }

    func testGeometryAdjustmentsWithCornerPinsRoundTrip() throws {
        var geo = GeometryAdjustments.neutral
        geo.cornerPins = PerspectiveCornerPins(
            topLeft: NormalizedPoint(x: 0.05, y: 0.05),
            topRight: NormalizedPoint(x: 0.95, y: 0.05),
            bottomLeft: NormalizedPoint(x: 0.02, y: 0.98),
            bottomRight: NormalizedPoint(x: 0.98, y: 0.98)
        )

        let data = try JSONEncoder().encode(geo)
        let decoded = try JSONDecoder().decode(GeometryAdjustments.self, from: data)
        XCTAssertEqual(decoded.cornerPins, geo.cornerPins)
    }
}
