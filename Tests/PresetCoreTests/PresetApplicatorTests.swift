import XCTest
@testable import PresetCore
import RawProcessingCore

final class PresetApplicatorTests: XCTestCase {
    private let applicator = PresetApplicator()

    // MARK: - Merge vs replace

    func testMergeChangesOnlyPresentLeaves() throws {
        let current = PhotoAdjustments(exposure: 2, contrast: 30, saturation: 40)
        let patch = AdjustmentPatch(basic: .init(exposure: 0, saturation: -20))
        let result = try applicator.apply(patch, to: current, mode: .merge, context: .none)
        XCTAssertEqual(result.adjustments.exposure, 0)
        XCTAssertEqual(result.adjustments.contrast, 30)
        XCTAssertEqual(result.adjustments.saturation, -20)
    }

    func testReplaceStartsFromNeutral() throws {
        let current = PhotoAdjustments(exposure: 2, contrast: 30)
        let patch = AdjustmentPatch(basic: .init(exposure: 1))
        let result = try applicator.apply(patch, to: current, mode: .replace, context: .none)
        XCTAssertEqual(result.adjustments.exposure, 1)
        XCTAssertEqual(result.adjustments.contrast, 0)
    }

    func testEmptyPatchIsANoOpUnderMerge() throws {
        let current = PhotoAdjustments(exposure: 1, contrast: 20)
        let result = try applicator.apply(AdjustmentPatch(), to: current, mode: .merge, context: .none)
        XCTAssertEqual(result.adjustments, current)
    }

    func testEmptyPatchResetsToNeutralUnderReplace() throws {
        let current = PhotoAdjustments(exposure: 1, contrast: 20)
        let result = try applicator.apply(AdjustmentPatch(), to: current, mode: .replace, context: .none)
        XCTAssertEqual(result.adjustments, .neutral)
    }

    // MARK: - Every leaf group, table-driven

    func testMergeAppliesEveryNestedGroupIndependently() throws {
        let current = PhotoAdjustments.neutral
        let patch = AdjustmentPatch(
            basic: .init(contrast: 15),
            advancedToneCurve: AdvancedToneCurve(points: [ToneCurvePoint(x: 0.25, y: 0.4)]),
            hsl: HSLAdjustmentPatch(red: HSLBandPatch(hue: 10)),
            splitToning: SplitToningPatch(shadowSaturation: 20),
            sharpening: SharpeningPatch(amount: 40),
            noiseReduction: NoiseReductionPatch(luminanceAmount: 15),
            vignette: VignettePatch(amount: -10),
            grain: GrainPatch(amount: 25)
        )
        let result = try applicator.apply(patch, to: current, mode: .merge, context: .none)
        XCTAssertEqual(result.adjustments.contrast, 15)
        XCTAssertEqual(result.adjustments.advancedToneCurve.points, [ToneCurvePoint(x: 0.25, y: 0.4)])
        XCTAssertEqual(result.adjustments.hsl.red.hue, 10)
        XCTAssertEqual(result.adjustments.splitToning.shadowSaturation, 20)
        XCTAssertEqual(result.adjustments.sharpening.amount, 40)
        XCTAssertEqual(result.adjustments.noiseReduction.luminanceAmount, 15)
        XCTAssertEqual(result.adjustments.vignette.amount, -10)
        XCTAssertEqual(result.adjustments.grain.amount, 25)
    }

    func testMergePreservesUntouchedLeavesWithinASharedGroup() throws {
        var current = PhotoAdjustments.neutral
        current.hsl.red.hue = 5
        current.hsl.orange.saturation = 12
        let patch = AdjustmentPatch(hsl: HSLAdjustmentPatch(red: HSLBandPatch(luminance: -7)))
        let result = try applicator.apply(patch, to: current, mode: .merge, context: .none)
        // Explicitly patched leaf changes...
        XCTAssertEqual(result.adjustments.hsl.red.luminance, -7)
        // ...but sibling leaves in the same band, and other bands entirely,
        // are untouched -- merge is leaf-granular, not group-granular.
        XCTAssertEqual(result.adjustments.hsl.red.hue, 5)
        XCTAssertEqual(result.adjustments.hsl.orange.saturation, 12)
    }

    func testExplicitZeroOverwritesNonZeroCurrentValueUnderMerge() throws {
        let current = PhotoAdjustments(exposure: 2)
        let patch = AdjustmentPatch(basic: .init(exposure: 0))
        let result = try applicator.apply(patch, to: current, mode: .merge, context: .none)
        XCTAssertEqual(result.adjustments.exposure, 0)
    }

    func testAbsentAdvancedToneCurveLeavesCurrentCurveUntouchedUnderMerge() throws {
        var current = PhotoAdjustments.neutral
        current.advancedToneCurve = AdvancedToneCurve(points: [ToneCurvePoint(x: 0.1, y: 0.2)])
        let result = try applicator.apply(AdjustmentPatch(basic: .init(exposure: 1)), to: current, mode: .merge, context: .none)
        XCTAssertEqual(result.adjustments.advancedToneCurve, current.advancedToneCurve)
    }

    // MARK: - White balance context

    func testContextualTemperatureConvertsAbsoluteKelvinAgainstBaseline() throws {
        let current = PhotoAdjustments.neutral
        let patch = AdjustmentPatch(basic: .init(temperature: 6000))
        let context = PresetApplicationContext(baselineTemperatureKelvin: 5000, baselineTint: 0)
        let result = try applicator.apply(
            patch, to: current, mode: .merge, context: context,
            temperatureIsAbsoluteKelvin: true
        )
        // (6000 - 5000) / 45 == 22.222...
        XCTAssertEqual(result.adjustments.temperature, (6000 - 5000) / AdjustmentMapping.kelvinPerTemperatureUnit, accuracy: 0.0001)
    }

    func testMissingBaselineKeepsCurrentTemperatureAndEmitsDiagnostic() throws {
        let current = PhotoAdjustments(temperature: 12)
        let patch = AdjustmentPatch(basic: .init(temperature: 6000))
        let result = try applicator.apply(
            patch, to: current, mode: .merge, context: .none,
            temperatureIsAbsoluteKelvin: true
        )
        XCTAssertEqual(result.adjustments.temperature, 12)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "missingWhiteBalanceBaseline" })
    }

    func testOutOfRangeContextualTemperatureClampsAndDiagnoses() throws {
        let current = PhotoAdjustments.neutral
        let patch = AdjustmentPatch(basic: .init(temperature: 60000))
        let context = PresetApplicationContext(baselineTemperatureKelvin: 5000, baselineTint: 0)
        let result = try applicator.apply(
            patch, to: current, mode: .merge, context: context,
            temperatureIsAbsoluteKelvin: true
        )
        XCTAssertEqual(result.adjustments.temperature, 100) // clamped to the slider's max
        XCTAssertTrue(result.diagnostics.contains { $0.code == "clampedWhiteBalance" })
    }

    // MARK: - Single-call, pure-function contract

    func testApplyingSameResultTwiceProducesEqualOutput() throws {
        let current = PhotoAdjustments(exposure: 1)
        let patch = AdjustmentPatch(basic: .init(contrast: 20))
        let first = try applicator.apply(patch, to: current, mode: .merge, context: .none)
        let second = try applicator.apply(patch, to: current, mode: .merge, context: .none)
        XCTAssertEqual(first.adjustments, second.adjustments)
    }
}
