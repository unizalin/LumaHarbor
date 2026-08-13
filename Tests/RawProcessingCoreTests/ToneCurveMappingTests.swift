import XCTest
@testable import RawProcessingCore

final class ToneCurveMappingTests: XCTestCase {
    func testNeutralProducesTheIdentityCurve() {
        XCTAssertEqual(ToneCurveMapping.controlPoints(for: .neutral), ToneCurveMapping.identity)
        XCTAssertTrue(ToneCurveMapping.isIdentity(.neutral))
    }

    func testOnlyTheFourToneSlidersAffectTheCurve() {
        let colourOnly = PhotoAdjustments(exposure: 3, contrast: 50, vibrance: 80, saturation: -40)
        XCTAssertTrue(ToneCurveMapping.isIdentity(colourOnly))
        XCTAssertEqual(ToneCurveMapping.controlPoints(for: colourOnly), ToneCurveMapping.identity)
    }

    func testAlwaysReturnsFivePoints() {
        for value in stride(from: -100.0, through: 100.0, by: 25) {
            let adjustments = PhotoAdjustments(
                highlights: value, shadows: -value, whites: value, blacks: -value
            )
            XCTAssertEqual(ToneCurveMapping.controlPoints(for: adjustments).count, 5)
        }
    }

    func testXIsStrictlyIncreasingForEveryCombination() {
        // CIToneCurve needs increasing x; a duplicate would silently produce
        // garbage rather than fail.
        for blacks in [-100.0, -50, 0, 50, 100] {
            for whites in [-100.0, -50, 0, 50, 100] {
                let points = ToneCurveMapping.controlPoints(
                    for: PhotoAdjustments(whites: whites, blacks: blacks)
                )
                for (left, right) in zip(points, points.dropFirst()) {
                    XCTAssertLessThan(
                        left.x, right.x,
                        "blacks=\(blacks) whites=\(whites) produced non-increasing x"
                    )
                }
            }
        }
    }

    func testYNeverDecreasesEvenWithOpposingSliders() {
        // Opposing sliders can invert the curve, which shows up as solarisation.
        let hostile = PhotoAdjustments(
            highlights: -100, shadows: 100, whites: -100, blacks: 100
        )
        let points = ToneCurveMapping.controlPoints(for: hostile)
        for (left, right) in zip(points, points.dropFirst()) {
            XCTAssertLessThanOrEqual(left.y, right.y)
        }
    }

    func testEveryPointStaysInsideTheUnitSquare() {
        let extreme = PhotoAdjustments(
            highlights: 100, shadows: 100, whites: 100, blacks: 100
        )
        for point in ToneCurveMapping.controlPoints(for: extreme) {
            XCTAssertGreaterThanOrEqual(point.x, 0)
            XCTAssertLessThanOrEqual(point.x, 1)
            XCTAssertGreaterThanOrEqual(point.y, 0)
            XCTAssertLessThanOrEqual(point.y, 1)
        }
    }

    func testPositiveBlacksLiftsTheBlackPoint() {
        let points = ToneCurveMapping.controlPoints(for: PhotoAdjustments(blacks: 100))
        XCTAssertEqual(points[0].x, 0)
        XCTAssertEqual(points[0].y, ToneCurveMapping.endpointShift, accuracy: 1e-9)
    }

    func testNegativeBlacksCrushesByMovingTheInputThreshold() {
        let points = ToneCurveMapping.controlPoints(for: PhotoAdjustments(blacks: -100))
        XCTAssertEqual(points[0].x, ToneCurveMapping.endpointShift, accuracy: 1e-9)
        XCTAssertEqual(points[0].y, 0)
    }

    func testPositiveWhitesPullsTheClippingPointLeft() {
        let points = ToneCurveMapping.controlPoints(for: PhotoAdjustments(whites: 100))
        XCTAssertEqual(points[4].x, 1 - ToneCurveMapping.endpointShift, accuracy: 1e-9)
        XCTAssertEqual(points[4].y, 1)
    }

    func testNegativeWhitesLowersTheOutputCeiling() {
        let points = ToneCurveMapping.controlPoints(for: PhotoAdjustments(whites: -100))
        XCTAssertEqual(points[4].x, 1)
        XCTAssertEqual(points[4].y, 1 - ToneCurveMapping.endpointShift, accuracy: 1e-9)
    }

    func testShadowsAndHighlightsMoveTheQuarterPoints() {
        let lifted = ToneCurveMapping.controlPoints(for: PhotoAdjustments(shadows: 100))
        XCTAssertEqual(lifted[1].y, 0.25 + ToneCurveMapping.midpointShift, accuracy: 1e-9)

        let recovered = ToneCurveMapping.controlPoints(for: PhotoAdjustments(highlights: -100))
        XCTAssertEqual(recovered[3].y, 0.75 - ToneCurveMapping.midpointShift, accuracy: 1e-9)
    }

    func testMidpointIsNeverMoved() {
        // Keeping 0.5 fixed is what makes these four sliders feel like tone
        // controls rather than a second exposure slider.
        let adjustments = PhotoAdjustments(
            highlights: 80, shadows: -70, whites: 60, blacks: -50
        )
        let points = ToneCurveMapping.controlPoints(for: adjustments)
        XCTAssertEqual(points[2].x, 0.5)
        XCTAssertEqual(points[2].y, 0.5)
    }
}
