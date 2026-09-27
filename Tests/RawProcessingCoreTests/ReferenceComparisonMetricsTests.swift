import XCTest
@testable import RawProcessingCore

final class ReferenceComparisonMetricsTests: XCTestCase {
    func testLightroomReferenceThresholdsExposeVersionedPerMetricEvaluation() {
        let thresholds = LightroomReferenceThresholds.current

        XCTAssertEqual(thresholds.version, 2)
        XCTAssertEqual(thresholds.meanAbsoluteEffectError, 0.04, accuracy: 0.000_000_1)
        XCTAssertEqual(thresholds.p95AbsoluteEffectError, 0.12, accuracy: 0.000_000_1)
        XCTAssertEqual(thresholds.luminanceEffectSSIM, 0.95, accuracy: 0.000_000_1)
        XCTAssertEqual(thresholds.highlightClippingFractionDelta, 0.02, accuracy: 0.000_000_1)
        XCTAssertEqual(thresholds.shadowClippingFractionDelta, 0.02, accuracy: 0.000_000_1)

        let passing = thresholds.evaluate(ReferenceComparisonResult(
            meanAbsoluteEffectError: 0.04,
            p95AbsoluteEffectError: 0.12,
            luminanceEffectSSIM: 0.95,
            highlightClippingFractionDelta: 0.02,
            shadowClippingFractionDelta: 0.02,
            sampleCount: 10
        ))
        XCTAssertTrue(passing.meanAbsoluteEffectErrorPassed)
        XCTAssertTrue(passing.p95AbsoluteEffectErrorPassed)
        XCTAssertTrue(passing.luminanceEffectSSIMPassed)
        XCTAssertTrue(passing.isPassing)

        let failing = thresholds.evaluate(ReferenceComparisonResult(
            meanAbsoluteEffectError: 0.040_001,
            p95AbsoluteEffectError: 0.12,
            luminanceEffectSSIM: 0.95,
            highlightClippingFractionDelta: 0.021,
            shadowClippingFractionDelta: 0.02,
            sampleCount: 10
        ))
        XCTAssertFalse(failing.meanAbsoluteEffectErrorPassed)
        XCTAssertTrue(failing.p95AbsoluteEffectErrorPassed)
        XCTAssertTrue(failing.luminanceEffectSSIMPassed)
        XCTAssertFalse(failing.highlightClippingFractionDeltaPassed)
        XCTAssertTrue(failing.shadowClippingFractionDeltaPassed)
        XCTAssertFalse(failing.isPassing)
    }

    func testClippingFractionsUseEncodedSRGBBoundariesAndDirectPair() throws {
        let result = try ReferenceComparisonMetrics.compare(
            mode: .neutralDirect,
            width: 2,
            height: 1,
            lrNeutral: [
                SIMD4<Float>(0.01, 0.0, 0.0, 1),
                SIMD4<Float>(0.98, 0.2, 0.2, 1)
            ],
            lrPreset: Array(repeating: SIMD4<Float>(0.2, 0.2, 0.2, 1), count: 2),
            lhNeutral: [
                SIMD4<Float>(0.02, 0.02, 0.02, 1),
                SIMD4<Float>(1.0, 0.2, 0.2, 1)
            ],
            lhPreset: Array(repeating: SIMD4<Float>(0.2, 0.2, 0.2, 1), count: 2)
        )

        XCTAssertEqual(result.shadowClippingFractionDelta, 0.5, accuracy: 0.000_000_1)
        XCTAssertEqual(result.highlightClippingFractionDelta, 0.5, accuracy: 0.000_000_1)
    }

    func testIdenticalEffectPairsHaveZeroErrorAndPerfectSSIM() throws {
        let neutral = Array(repeating: SIMD4<Float>(0.2, 0.3, 0.4, 1), count: 121)
        let preset = Array(repeating: SIMD4<Float>(0.4, 0.5, 0.6, 1), count: 121)

        let result = try ReferenceComparisonMetrics.compare(
            width: 11,
            height: 11,
            lrNeutral: neutral,
            lrPreset: preset,
            lhNeutral: neutral,
            lhPreset: preset
        )

        XCTAssertEqual(result.meanAbsoluteEffectError, 0, accuracy: 0.000_000_1)
        XCTAssertEqual(result.p95AbsoluteEffectError, 0, accuracy: 0.000_000_1)
        XCTAssertEqual(result.luminanceEffectSSIM, 1, accuracy: 0.000_000_1)
        XCTAssertEqual(result.sampleCount, 121)
    }

    func testKnownEffectDifferenceReportsMeanAndP95() throws {
        let neutral = Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: 2)
        let lrPreset = [
            SIMD4<Float>(0.2, 0.4, 0.6, 1),
            SIMD4<Float>(0.2, 0.4, 0.6, 1)
        ]
        let lhPreset = [
            SIMD4<Float>(0.1, 0.5, 0.4, 1),
            SIMD4<Float>(0.1, 0.5, 0.4, 1)
        ]

        let result = try ReferenceComparisonMetrics.compare(
            mode: .presetEffect,
            width: 2,
            height: 1,
            lrNeutral: neutral,
            lrPreset: lrPreset,
            lhNeutral: neutral,
            lhPreset: lhPreset
        )

        XCTAssertEqual(result.meanAbsoluteEffectError, 0.133_333_33, accuracy: 0.000_001)
        XCTAssertEqual(result.p95AbsoluteEffectError, 0.2, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(result.luminanceEffectSSIM, -1)
        XCTAssertLessThanOrEqual(result.luminanceEffectSSIM, 1)
    }

    func testNeutralDirectComparesNeutralImagesWithoutPresetInfluence() throws {
        let result = try ReferenceComparisonMetrics.compare(
            mode: .neutralDirect,
            width: 1,
            height: 1,
            lrNeutral: [SIMD4<Float>(0.2, 0.3, 0.4, 1)],
            lrPreset: [SIMD4<Float>(0.9, 0.9, 0.9, 1)],
            lhNeutral: [SIMD4<Float>(0.1, 0.2, 0.3, 1)],
            lhPreset: [SIMD4<Float>(0.9, 0.9, 0.9, 1)]
        )

        XCTAssertEqual(result.meanAbsoluteError, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(result.p95AbsoluteError, 0.1, accuracy: 0.000_001)
    }

    func testFinalDirectComparesPresetImagesWithoutNeutralInfluence() throws {
        let result = try ReferenceComparisonMetrics.compare(
            mode: .finalDirect,
            width: 1,
            height: 1,
            lrNeutral: [SIMD4<Float>(0.8, 0.8, 0.8, 1)],
            lrPreset: [SIMD4<Float>(0.7, 0.6, 0.5, 1)],
            lhNeutral: [SIMD4<Float>(0.1, 0.1, 0.1, 1)],
            lhPreset: [SIMD4<Float>(0.5, 0.4, 0.3, 1)]
        )

        XCTAssertEqual(result.meanAbsoluteError, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(result.p95AbsoluteError, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(result.luminanceSSIM, result.luminanceEffectSSIM, accuracy: 0.000_001)
    }

    func testDimensionMismatchThrows() {
        XCTAssertThrowsError(try ReferenceComparisonMetrics.compare(
            width: 2,
            height: 1,
            lrNeutral: [SIMD4<Float>(0, 0, 0, 1)],
            lrPreset: [SIMD4<Float>(0, 0, 0, 1)],
            lhNeutral: [SIMD4<Float>(0, 0, 0, 1)],
            lhPreset: [SIMD4<Float>(0, 0, 0, 1)]
        )) { error in
            XCTAssertEqual(error as? ReferenceComparisonError, .sampleCountMismatch)
        }
    }

    func testNonFiniteSampleThrowsWithoutExposingInputDetails() {
        XCTAssertThrowsError(try ReferenceComparisonMetrics.compare(
            width: 1,
            height: 1,
            lrNeutral: [SIMD4<Float>(.nan, 0, 0, 1)],
            lrPreset: [SIMD4<Float>(0, 0, 0, 1)],
            lhNeutral: [SIMD4<Float>(0, 0, 0, 1)],
            lhPreset: [SIMD4<Float>(0, 0, 0, 1)]
        )) { error in
            XCTAssertEqual(error as? ReferenceComparisonError, .nonFiniteSample)
            XCTAssertFalse(String(describing: error).contains("/"))
        }
    }
}
