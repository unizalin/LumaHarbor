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
    /// correction must add magenta -- a negative tint delta, matching this
    /// codebase's existing convention that `PhotoAdjustments.tint` is
    /// passed straight through as `CIRAWFilter.neutralTint`'s own offset
    /// (positive tint = more magenta, the standard RAW-converter sign).
    func testAGreenCastSampleAddsMagenta() {
        let sample = WhiteBalanceEyedropper.Sample(red: 0.5, green: 0.6, blue: 0.5)
        let delta = WhiteBalanceEyedropper.delta(neutralizing: sample)
        XCTAssertLessThan(delta.tint, 0)
    }

    func testAMagentaCastSampleAddsGreen() {
        let sample = WhiteBalanceEyedropper.Sample(red: 0.55, green: 0.4, blue: 0.55)
        let delta = WhiteBalanceEyedropper.delta(neutralizing: sample)
        XCTAssertGreaterThan(delta.tint, 0)
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
}
