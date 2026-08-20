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

    func testWeightsAcrossAllBandsOverlapWithoutGaps() {
        // halfWidthDegrees is 60, sized by the *widest* gap between adjacent
        // band centers, so the 30-degrees-apart bands now deliberately overlap
        // to more than 1.0. At hue 15 that is red@0 (1 - 15/60 = 0.75) plus
        // orange@30 (0.75) plus yellow@60 (1 - 45/60 = 0.25) = 1.75 exactly;
        // magenta@315 sits 60 degrees away and contributes nothing.
        //
        // The old assertion capped this at 1.2, which only held while
        // halfWidthDegrees was 30 -- and 30 left hard dead zones at 90/150/210
        // degrees. Over-1.0 overlap is now the intended shape; the kernel
        // divides by the summed weight when it exceeds 1.0 so the blend still
        // cannot amplify past a single band at full strength (see
        // AdjustmentPipeline.hslKernel).
        let totalAtBoundary = HSLKernelWeights.bandCenters.reduce(0.0) { total, center in
            total + HSLKernelWeights.weight(forHueDegrees: 15, centerDegrees: center)
        }
        XCTAssertEqual(totalAtBoundary, 1.75, accuracy: 1e-9)
    }

    func testNoHueOnTheWheelFallsInADeadZone() {
        // Spec 4.3 requires smooth coverage everywhere. With halfWidthDegrees
        // at 30 the midpoints of the 60-degrees-apart pairs -- 90 between
        // yellow@60 and green@120, 150 between green and aqua, 210 between aqua
        // and blue -- summed to exactly zero, so an HSL edit on a pixel at one
        // of those hues silently did nothing at all.
        for hue in stride(from: 0.0, to: 360.0, by: 0.5) {
            let total = HSLKernelWeights.bandCenters.reduce(0.0) { running, center in
                running + HSLKernelWeights.weight(forHueDegrees: hue, centerDegrees: center)
            }
            XCTAssertGreaterThan(total, 0, "Hue \(hue) has no band coverage at all")
        }
    }
}
