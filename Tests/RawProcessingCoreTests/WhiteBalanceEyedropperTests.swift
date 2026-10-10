import XCTest
@testable import RawProcessingCore

/// Phase 2 Task 2.4: pins the *direction* `WhiteBalanceEyedropper.delta(
/// neutralizing:)` moves the temperature/tint sliders for a given colour
/// cast, the same "don't trust the formula by inspection, assert the
/// direction explicitly" discipline `GeometryRenderer`'s rotate tests
/// (Task 2.2) and `CropDragMath`'s handle tests (Task 2.3) already
/// established in this codebase. This is a self-contained, first-version
/// estimate (design spec §6.4: "一般影像格式則以已解碼 RGB 估算") -- it never
/// calls into `CIRAWFilter`'s own proprietary neutralLocation/
/// neutralTemperature algorithm (untestable here with no RAW fixture), so
/// the same function works identically for a RAW-decoded preview and any
/// future non-RAW decode path.
final class WhiteBalanceEyedropperTests: XCTestCase {
    func testAnAlreadyNeutralSampleProducesNoDelta() {
        let sample = WhiteBalanceEyedropper.Sample(red: 0.5, green: 0.5, blue: 0.5)
        let delta = WhiteBalanceEyedropper.delta(neutralizing: sample)
        XCTAssertEqual(delta.temperature, 0, accuracy: 0.0001)
        XCTAssertEqual(delta.tint, 0, accuracy: 0.0001)
    }

    /// Red higher than blue reads as a warm (orange) cast in the current
    /// render, so the correction must cool the image down -- a negative
    /// temperature delta, matching this codebase's own documented
    /// convention that a *positive* temperature slider value warms the
    /// image (`AdjustmentMapping.kelvinPerTemperatureUnit`'s own doc
    /// comment: "±100 on the temperature slider spans ±4500 K").
    func testAWarmCastSampleCoolsTheTemperatureDown() {
        let sample = WhiteBalanceEyedropper.Sample(red: 0.6, green: 0.5, blue: 0.4)
        let delta = WhiteBalanceEyedropper.delta(neutralizing: sample)
        XCTAssertLessThan(delta.temperature, 0)
    }

    func testACoolCastSampleWarmsTheTemperatureUp() {
        let sample = WhiteBalanceEyedropper.Sample(red: 0.4, green: 0.5, blue: 0.6)
        let delta = WhiteBalanceEyedropper.delta(neutralizing: sample)
        XCTAssertGreaterThan(delta.temperature, 0)
    }

    /// Green higher than the red/blue average reads as too green, so the
    /// correction must add magenta. In the native RAW renderer this is a
    /// positive Tint delta; assert rendered direction rather than the old
    /// helper-sign convention.
    func testAGreenCastSampleAddsMagenta() {
        let sample = WhiteBalanceEyedropper.Sample(red: 0.5, green: 0.6, blue: 0.5)
        let delta = WhiteBalanceEyedropper.delta(neutralizing: sample)
        XCTAssertGreaterThan(delta.tint, 0)
    }

    func testAMagentaCastSampleAddsGreen() {
        let sample = WhiteBalanceEyedropper.Sample(red: 0.55, green: 0.4, blue: 0.55)
        let delta = WhiteBalanceEyedropper.delta(neutralizing: sample)
        XCTAssertLessThan(delta.tint, 0)
    }

    /// A warm-only cast (no green/magenta component) must not perturb tint,
    /// and vice versa -- the two axes are independent, matching how the
    /// temperature and tint sliders behave.
    func testAPureWarmCastDoesNotMoveTint() {
        let sample = WhiteBalanceEyedropper.Sample(red: 0.6, green: 0.5, blue: 0.4)
        let delta = WhiteBalanceEyedropper.delta(neutralizing: sample)
        XCTAssertEqual(delta.tint, 0, accuracy: 0.0001)
    }

    func testAPureGreenCastDoesNotMoveTemperature() {
        let sample = WhiteBalanceEyedropper.Sample(red: 0.5, green: 0.6, blue: 0.5)
        let delta = WhiteBalanceEyedropper.delta(neutralizing: sample)
        XCTAssertEqual(delta.temperature, 0, accuracy: 0.0001)
    }

    func testALargerCastProducesALargerMagnitudeDelta() {
        let mild = WhiteBalanceEyedropper.delta(neutralizing: .init(red: 0.55, green: 0.5, blue: 0.45))
        let strong = WhiteBalanceEyedropper.delta(neutralizing: .init(red: 0.7, green: 0.5, blue: 0.3))
        XCTAssertLessThan(mild.temperature, 0)
        XCTAssertLessThan(strong.temperature, mild.temperature, "a stronger warm cast must cool down by more")
    }

    // MARK: - Safety

    func testNonFiniteChannelsProduceZeroDeltaRatherThanNaN() {
        let sample = WhiteBalanceEyedropper.Sample(red: .nan, green: 0.5, blue: 0.5)
        let delta = WhiteBalanceEyedropper.delta(neutralizing: sample)
        XCTAssertEqual(delta.temperature, 0)
        XCTAssertEqual(delta.tint, 0)
    }

    func testZeroOrNegativeChannelsDoNotCrashOrProduceNaN() {
        let sample = WhiteBalanceEyedropper.Sample(red: 0, green: 0, blue: 0)
        let delta = WhiteBalanceEyedropper.delta(neutralizing: sample)
        XCTAssertFalse(delta.temperature.isNaN)
        XCTAssertFalse(delta.tint.isNaN)
    }

    func testResultIsAlwaysFinite() {
        let sample = WhiteBalanceEyedropper.Sample(red: 1, green: 0.0001, blue: 1)
        let delta = WhiteBalanceEyedropper.delta(neutralizing: sample)
        XCTAssertTrue(delta.temperature.isFinite)
        XCTAssertTrue(delta.tint.isFinite)
    }

    func testTemperatureDeltaUsesTheSharedKelvinPresentationMapping() {
        let sample = WhiteBalanceEyedropper.Sample(red: 0.6, green: 0.5, blue: 0.4)
        let ratio = sample.red / sample.blue
        let delta = WhiteBalanceEyedropper.delta(neutralizing: sample)

        XCTAssertEqual(
            delta.temperature,
            WhiteBalancePresentation.storedTemperatureOffset(forRedToBlueRatio: ratio),
            accuracy: 0.0001
        )
    }

    func testApplyingEyedropperDeltaClampsBothAxesWithAnExplicitBaseline() {
        let current = PhotoAdjustments(temperature: 1_190, tint: -95)

        let updated = WhiteBalanceEyedropper.applying(
            delta: (temperature: 100, tint: -100),
            to: current,
            baselineKelvin: 5_500
        )

        XCTAssertEqual(updated.temperature, (50_000 - 5_500) / 45.0, accuracy: 1e-9)
        XCTAssertEqual(updated.tint, -100)
    }

    func testApplyingEyedropperDeltaClampsTheFinalTemperatureAgainstThePhotoBaseline() {
        let baseline = 4_536.72802734375
        let sample = WhiteBalanceEyedropper.Sample(red: 0.6, green: 0.5, blue: 0.4)
        let updated = WhiteBalanceEyedropper.applying(
            delta: WhiteBalanceEyedropper.delta(neutralizing: sample),
            to: .neutral,
            baselineKelvin: baseline
        )

        XCTAssertEqual(updated.temperature, (WhiteBalancePresentation.minimumKelvin - baseline) / 45, accuracy: 0.000001)
        XCTAssertEqual(
            baseline + updated.temperature * WhiteBalancePresentation.kelvinPerStoredUnit,
            WhiteBalancePresentation.minimumKelvin,
            accuracy: 0.000001
        )
    }

    func testFinalDeltaResolutionMatrixUsesIndependentKelvinBounds() throws {
        for baseline in [2_000.0, 4_536.72802734375, 5_500, 10_000, 50_000] {
            for oldOffset in [-2_000.0, -100, 0, 10, 2_000] {
                for delta in [-120.0, 0, 120] {
                    var current = PhotoAdjustments.neutral
                    current.temperature = oldOffset
                    let result = try XCTUnwrap(WhiteBalanceEyedropper.applyingResolved(
                        delta: (delta, 0), to: current, baselineKelvin: baseline
                    ))
                    let lower = max(-1_200, (2_000 - baseline) / 45)
                    let upper = min(1_200, (50_000 - baseline) / 45)
                    let start = min(max(oldOffset, lower), upper)
                    let expected = min(max(start + delta, lower), upper)
                    XCTAssertEqual(result.adjustments.temperature, expected, accuracy: 1e-9)
                    let kelvin = baseline + 45 * result.adjustments.temperature
                    XCTAssertGreaterThanOrEqual(kelvin, 2_000 - 1e-6)
                    XCTAssertLessThanOrEqual(kelvin, 50_000 + 1e-6)
                    XCTAssertEqual(result.diagnostic == .clamped, expected != start + delta)
                }
            }
        }
    }

    func testTooDarkSampleIsRejectedBeforeCalculatingAWhiteBalanceDelta() {
        let sample = WhiteBalanceEyedropper.Sample(red: 0.01, green: 0.02, blue: 0.01)

        XCTAssertEqual(WhiteBalanceEyedropper.issue(for: sample), .tooDark)
        XCTAssertEqual(WhiteBalanceEyedropper.delta(neutralizing: sample).temperature, 0)
        XCTAssertEqual(WhiteBalanceEyedropper.delta(neutralizing: sample).tint, 0)
    }

    func testClippedSampleIsRejectedBeforeCalculatingAWhiteBalanceDelta() {
        let sample = WhiteBalanceEyedropper.Sample(red: 1, green: 0.98, blue: 0.97)

        XCTAssertEqual(WhiteBalanceEyedropper.issue(for: sample), .clipped)
        XCTAssertEqual(WhiteBalanceEyedropper.delta(neutralizing: sample).temperature, 0)
        XCTAssertEqual(WhiteBalanceEyedropper.delta(neutralizing: sample).tint, 0)
    }

    func testNonFiniteOrOutOfRangeSampleIsRejected() {
        XCTAssertEqual(
            WhiteBalanceEyedropper.issue(for: .init(red: .nan, green: 0.5, blue: 0.5)),
            .nonFinite
        )
        XCTAssertEqual(
            WhiteBalanceEyedropper.issue(for: .init(red: -0.1, green: 0.5, blue: 0.5)),
            .outOfRange
        )
    }
}
