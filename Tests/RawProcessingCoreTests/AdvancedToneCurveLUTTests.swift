import XCTest
@testable import RawProcessingCore

final class AdvancedToneCurveLUTTests: XCTestCase {
    func testEmptyPointsProducesIdentityLUT() {
        let lut = AdvancedToneCurveLUT.build(from: [], resolution: 256)
        XCTAssertEqual(lut.count, 256)
        XCTAssertEqual(lut.first!, 0, accuracy: 1e-6)
        XCTAssertEqual(lut.last!, 1, accuracy: 1e-6)
        // Identity: value at index i is approximately i / 255.
        for i in stride(from: 0, to: 256, by: 32) {
            XCTAssertEqual(lut[i], Float(i) / 255, accuracy: 1e-6)
        }
    }

    func testKnownControlPointsProduceKnownOutput() {
        // A curve that maps 0->0, 0.5->0.25, 1->1: sampling at the midpoint
        // index should land near 0.25, not the identity's 0.5.
        let points = [
            ToneCurvePoint(x: 0, y: 0),
            ToneCurvePoint(x: 0.5, y: 0.25),
            ToneCurvePoint(x: 1, y: 1)
        ]
        let lut = AdvancedToneCurveLUT.build(from: points, resolution: 256)
        let midIndex = 127 // ~0.5 at 256 resolution
        XCTAssertEqual(lut[midIndex], 0.25, accuracy: 0.02)
    }

    func testSinglePointProducesAFlatLUTAtThatValue() {
        // Degenerate input (a "curve" with one point) can't interpolate --
        // must degrade to a constant rather than crash or extrapolate wildly.
        let lut = AdvancedToneCurveLUT.build(from: [ToneCurvePoint(x: 0.5, y: 0.7)], resolution: 256)
        XCTAssertTrue(lut.allSatisfy { abs($0 - 0.7) < 1e-6 })
    }

    func testOutputIsMonotonicNonDecreasing() {
        // Hostile input: y values that go backwards. The LUT must still come
        // out non-decreasing, or the render solarises (same risk documented
        // on ToneCurveMapping.enforceMonotonicOutput).
        let points = [
            ToneCurvePoint(x: 0, y: 0.5),
            ToneCurvePoint(x: 0.3, y: 0.1),
            ToneCurvePoint(x: 0.7, y: 0.9),
            ToneCurvePoint(x: 1, y: 0.6)
        ]
        let lut = AdvancedToneCurveLUT.build(from: points, resolution: 256)
        for i in 1..<lut.count {
            XCTAssertGreaterThanOrEqual(lut[i], lut[i - 1], "LUT must be non-decreasing at index \(i)")
        }
    }

    func testOutputIsClampedToZeroOne() {
        let points = [ToneCurvePoint(x: 0, y: -5), ToneCurvePoint(x: 1, y: 5)]
        let lut = AdvancedToneCurveLUT.build(from: points, resolution: 256)
        XCTAssertTrue(lut.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testResolutionControlsOutputCount() {
        XCTAssertEqual(AdvancedToneCurveLUT.build(from: [], resolution: 64).count, 64)
    }

    func testSingleSampleResolutionNeverProducesNaN() {
        let identity = AdvancedToneCurveLUT.build(from: [], resolution: 1)
        XCTAssertEqual(identity, [0])
        XCTAssertTrue(identity.allSatisfy(\.isFinite))

        let curve = AdvancedToneCurveLUT.build(
            from: [ToneCurvePoint(x: 0, y: 0.25), ToneCurvePoint(x: 1, y: 0.75)],
            resolution: 1
        )
        XCTAssertEqual(curve, [0.25])
        XCTAssertTrue(curve.allSatisfy(\.isFinite))
    }

    // MARK: - buildCombined (P3: composite ∘ channel)

    func testBuildCombinedWithEmptyChannelEqualsCompositeAlone() {
        let compositePoints = [
            ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.25), ToneCurvePoint(x: 1, y: 1)
        ]
        let compositeAlone = AdvancedToneCurveLUT.build(from: compositePoints, resolution: 256)
        let combined = AdvancedToneCurveLUT.buildCombined(
            compositePoints: compositePoints, channelPoints: [], resolution: 256
        )
        XCTAssertEqual(combined, compositeAlone)
    }

    func testBuildCombinedWithEmptyCompositeEqualsChannelAlone() {
        let channelPoints = [
            ToneCurvePoint(x: 0, y: 0.1), ToneCurvePoint(x: 0.5, y: 0.6), ToneCurvePoint(x: 1, y: 0.9)
        ]
        let channelAlone = AdvancedToneCurveLUT.build(from: channelPoints, resolution: 256)
        let combined = AdvancedToneCurveLUT.buildCombined(
            compositePoints: [], channelPoints: channelPoints, resolution: 256
        )
        XCTAssertEqual(combined, channelAlone)
    }

    func testBuildCombinedComposesBothCurves() {
        // Composite maps 0->0, 1->0.5 (halves everything). Channel maps
        // 0->0, 1->1 identity-shaped but offset: 0.5->0.2. Composing at
        // input 1.0 goes through composite (-> 0.5) then channel(0.5) ~= 0.2.
        let compositePoints = [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 0.5)]
        let channelPoints = [
            ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 0.5, y: 0.2), ToneCurvePoint(x: 1, y: 1)
        ]
        let combined = AdvancedToneCurveLUT.buildCombined(
            compositePoints: compositePoints, channelPoints: channelPoints, resolution: 256
        )
        XCTAssertEqual(combined.last!, 0.2, accuracy: 0.02)
    }

    func testBuildCombinedIsMonotonicNonDecreasing() {
        let compositePoints = [
            ToneCurvePoint(x: 0, y: 0.4), ToneCurvePoint(x: 0.4, y: 0.1),
            ToneCurvePoint(x: 0.8, y: 0.9), ToneCurvePoint(x: 1, y: 0.5)
        ]
        let channelPoints = [
            ToneCurvePoint(x: 0, y: 0.6), ToneCurvePoint(x: 0.3, y: 0.05),
            ToneCurvePoint(x: 0.7, y: 0.95), ToneCurvePoint(x: 1, y: 0.4)
        ]
        let combined = AdvancedToneCurveLUT.buildCombined(
            compositePoints: compositePoints, channelPoints: channelPoints, resolution: 256
        )
        for i in 1..<combined.count {
            XCTAssertGreaterThanOrEqual(combined[i], combined[i - 1], "combined LUT must be non-decreasing at \(i)")
        }
    }

    func testBuildCombinedClampedToZeroOne() {
        let compositePoints = [ToneCurvePoint(x: 0, y: -5), ToneCurvePoint(x: 1, y: 5)]
        let channelPoints = [ToneCurvePoint(x: 0, y: -5), ToneCurvePoint(x: 1, y: 5)]
        let combined = AdvancedToneCurveLUT.buildCombined(
            compositePoints: compositePoints, channelPoints: channelPoints, resolution: 256
        )
        XCTAssertTrue(combined.allSatisfy { $0 >= 0 && $0 <= 1 })
    }
}
