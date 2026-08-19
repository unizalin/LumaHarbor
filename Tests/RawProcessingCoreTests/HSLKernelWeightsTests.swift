import XCTest
@testable import RawProcessingCore

final class HSLKernelWeightsTests: XCTestCase {
    func testEightBandCentersSpanTheHueWheel() {
        XCTAssertEqual(HSLKernelWeights.bandCenters.count, 8)
        // Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta order,
        // matching HSLAdjustments's field order (spec §3.2).
        XCTAssertEqual(HSLKernelWeights.bandCenters, [0, 30, 60, 120, 180, 240, 275, 315])
    }

    func testWeightIsOneAtExactCenter() {
        XCTAssertEqual(HSLKernelWeights.weight(forHueDegrees: 60, centerDegrees: 60), 1.0, accuracy: 1e-9)
    }

    func testWeightFallsOffAwayFromCenter() {
        let atCenter = HSLKernelWeights.weight(forHueDegrees: 60, centerDegrees: 60)
        let near = HSLKernelWeights.weight(forHueDegrees: 70, centerDegrees: 60)
        let far = HSLKernelWeights.weight(forHueDegrees: 150, centerDegrees: 60)
        XCTAssertGreaterThan(atCenter, near)
        XCTAssertGreaterThan(near, far)
    }

    func testWeightWrapsAroundZeroDegrees() {
        // Red is centred at 0/360 -- a hue of 350 should weight almost as
        // strongly toward red as a hue of 10 does, not fall off as if 0 and
        // 360 were unrelated ends of a line.
        let justBelow = HSLKernelWeights.weight(forHueDegrees: 350, centerDegrees: 0)
        let justAbove = HSLKernelWeights.weight(forHueDegrees: 10, centerDegrees: 0)
        XCTAssertEqual(justBelow, justAbove, accuracy: 1e-9)
        XCTAssertGreaterThan(justBelow, 0.5)
    }

    func testWeightsAcrossAllBandsSumToAtMostOnePlusOverlap() {
        // Neighbouring bands should overlap smoothly (no hard seams) but a
        // hue exactly between two centers shouldn't get more than ~1 total
        // weight, or the blended adjustment amplifies instead of blending.
        let totalAtBoundary = HSLKernelWeights.bandCenters.reduce(0.0) { total, center in
            total + HSLKernelWeights.weight(forHueDegrees: 15, centerDegrees: center)
        }
        XCTAssertLessThanOrEqual(totalAtBoundary, 1.2)
        XCTAssertGreaterThan(totalAtBoundary, 0.9)
    }
}
