import XCTest
@testable import RawProcessingCore

final class DCPProfileToneCurveTests: XCTestCase {
    func testIdentityCurveIsNoOp() throws {
        let curve = try DCPProfileToneCurve(
            knots: [
                .init(input: 0, output: 0),
                .init(input: 1, output: 1)
            ]
        )

        XCTAssertEqual(try curve.apply(to: 0.37), 0.37, accuracy: 0.000_001)
    }

    func testInterpolatesMonotonicKnots() throws {
        let curve = try DCPProfileToneCurve(
            knots: [
                .init(input: 0, output: 0),
                .init(input: 0.5, output: 0.25),
                .init(input: 1, output: 1)
            ]
        )

        XCTAssertEqual(try curve.apply(to: 0.25), 0.125, accuracy: 0.000_001)
        XCTAssertEqual(try curve.apply(to: 0.75), 0.625, accuracy: 0.000_001)
    }

    func testRejectsRepeatedOrDecreasingX() {
        XCTAssertThrowsError(
            try DCPProfileToneCurve(knots: [
                .init(input: 0, output: 0),
                .init(input: 0.5, output: 0.5),
                .init(input: 0.5, output: 0.75),
                .init(input: 1, output: 1)
            ])
        )
        XCTAssertThrowsError(
            try DCPProfileToneCurve(knots: [
                .init(input: 0, output: 0),
                .init(input: 0.8, output: 0.8),
                .init(input: 0.4, output: 0.9),
                .init(input: 1, output: 1)
            ])
        )
    }

    func testRejectsOutOfDomainNonFiniteAndNonMonotonicY() {
        XCTAssertThrowsError(
            try DCPProfileToneCurve(knots: [
                .init(input: -0.1, output: 0),
                .init(input: 1, output: 1)
            ])
        )
        XCTAssertThrowsError(
            try DCPProfileToneCurve(knots: [
                .init(input: 0, output: 0),
                .init(input: 1, output: .nan)
            ])
        )
        XCTAssertThrowsError(
            try DCPProfileToneCurve(knots: [
                .init(input: 0, output: 0),
                .init(input: 0.5, output: 0.8),
                .init(input: 1, output: 0.7)
            ])
        )
    }

    func testRejectsInputOutsideCurveDomain() throws {
        let curve = try DCPProfileToneCurve(
            knots: [
                .init(input: 0, output: 0),
                .init(input: 1, output: 1)
            ]
        )

        XCTAssertThrowsError(try curve.apply(to: -0.01))
        XCTAssertThrowsError(try curve.apply(to: 1.01))
        XCTAssertThrowsError(try curve.apply(to: .infinity))
    }

    func testAppliesToneWithoutChangingHueOrSaturation() throws {
        let curve = try DCPProfileToneCurve(
            knots: [
                .init(input: 0, output: 0),
                .init(input: 1, output: 0.25)
            ]
        )

        let output = try curve.applyHuePreserving(to: [0.2, 0.4, 0.8])

        for (actual, expected) in zip(output, [0.05, 0.1, 0.2]) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
    }

    func testProfileMetadataValidatesWithoutUserExposure() throws {
        let metadata = try DCPProfileMetadata(
            baselineExposureOffset: 0.75,
            defaultBlackRender: 1
        ).validated()

        XCTAssertEqual(metadata.baselineExposureOffset, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(metadata.defaultBlackRender, 1)
    }

    func testRejectsInvalidProfileMetadata() {
        XCTAssertThrowsError(
            try DCPProfileMetadata(baselineExposureOffset: .nan, defaultBlackRender: 0).validated()
        )
        XCTAssertThrowsError(
            try DCPProfileMetadata(baselineExposureOffset: 0, defaultBlackRender: 2).validated()
        )
    }
}
