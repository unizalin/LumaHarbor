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
}
