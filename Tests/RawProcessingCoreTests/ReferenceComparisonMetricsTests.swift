import XCTest
@testable import RawProcessingCore

final class ReferenceComparisonMetricsTests: XCTestCase {
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
