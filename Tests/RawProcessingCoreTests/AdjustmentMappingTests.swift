import XCTest
@testable import RawProcessingCore

/// Spec §8.2 requires the slider-to-Core-Image mapping to be pinned by tests.
/// These assertions are the pin: changing a constant changes everyone's renders,
/// so it should have to be done deliberately.
final class AdjustmentMappingTests: XCTestCase {
    func testNeutralMapsToACompleteIdentity() {
        let parameters = AdjustmentMapping.renderParameters(for: .neutral)
        XCTAssertTrue(parameters.isExposureIdentity)
        XCTAssertTrue(parameters.isContrastIdentity)
        XCTAssertTrue(parameters.isSaturationIdentity)
        XCTAssertTrue(parameters.isVibranceIdentity)
        XCTAssertTrue(parameters.isToneCurveIdentity)
        XCTAssertTrue(parameters.whiteBalance.isAsShot)
    }

    func testExposureIsPassedThroughAsStops() {
        XCTAssertEqual(
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(exposure: 1.5)).exposureEV,
            1.5
        )
        XCTAssertEqual(
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(exposure: -2)).exposureEV,
            -2
        )
    }

    func testTemperatureSpansPlusMinus4500Kelvin() {
        let warm = AdjustmentMapping.renderParameters(for: PhotoAdjustments(temperature: 100))
        let cool = AdjustmentMapping.renderParameters(for: PhotoAdjustments(temperature: -100))
        XCTAssertEqual(warm.temperatureOffsetKelvin, 4_500)
        XCTAssertEqual(cool.temperatureOffsetKelvin, -4_500)
    }

    func testTintSpansPlusMinus150() {
        let parameters = AdjustmentMapping.renderParameters(for: PhotoAdjustments(tint: 100))
        XCTAssertEqual(parameters.tintOffset, 150)
    }

    func testContrastMapsToHalfToOneAndAHalf() {
        XCTAssertEqual(
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(contrast: 100)).contrast,
            1.5,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(contrast: -100)).contrast,
            0.5,
            accuracy: 1e-9
        )
    }

    func testSaturationMapsToZeroToTwo() {
        XCTAssertEqual(
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(saturation: -100)).saturation,
            0,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(saturation: 100)).saturation,
            2,
            accuracy: 1e-9
        )
    }

    func testVibranceMapsToTheFullFilterRange() {
        XCTAssertEqual(
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(vibrance: 100)).vibrance,
            1,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(vibrance: -100)).vibrance,
            -1,
            accuracy: 1e-9
        )
    }

    func testMappingIsMonotonicAcrossEachSlider() {
        // A slider that isn't monotonic feels broken even when every endpoint is
        // right, so check the middle too.
        let values = stride(from: -100.0, through: 100.0, by: 10).map { value in
            AdjustmentMapping.renderParameters(for: PhotoAdjustments(contrast: value)).contrast
        }
        XCTAssertEqual(values, values.sorted())
    }

    func testMappingClampsHostileInput() {
        var hostile = PhotoAdjustments.neutral
        hostile.exposure = .nan
        let parameters = AdjustmentMapping.renderParameters(for: hostile)
        XCTAssertTrue(parameters.exposureEV.isFinite)
    }

    func testDirectMutationCannotBypassNestedAdjustmentRanges() {
        var hostile = PhotoAdjustments.neutral
        hostile.advancedToneCurve.points = [ToneCurvePoint(x: .nan, y: 4)]
        hostile.hsl.red.hue = .nan
        hostile.hsl.red.saturation = -500
        hostile.splitToning.shadowHue = 900
        hostile.sharpening.amount = 1_000
        hostile.sharpening.radius = -10
        hostile.noiseReduction.colorAmount = .infinity
        hostile.vignette.roundness = -500
        hostile.grain.amount = 1_000

        let parameters = AdjustmentMapping.renderParameters(for: hostile)

        XCTAssertEqual(parameters.advancedToneCurve.points, [ToneCurvePoint(x: 0, y: 1)])
        XCTAssertEqual(parameters.hsl.red.hue, 0)
        XCTAssertEqual(parameters.hsl.red.saturation, -100)
        XCTAssertEqual(parameters.splitToning.shadowHue, 360)
        XCTAssertEqual(parameters.sharpening.amount, 150)
        XCTAssertEqual(parameters.sharpening.radius, 0.5)
        XCTAssertEqual(parameters.noiseReduction.colorAmount, 0)
        XCTAssertEqual(parameters.vignette.roundness, -100)
        XCTAssertEqual(parameters.grain.amount, 100)
    }

    func testWhiteBalanceIsCarriedToTheDecoder() {
        // Spec §9: white balance belongs to demosaicing, so it has to reach the
        // decoder rather than being applied as a post filter.
        let parameters = AdjustmentMapping.renderParameters(
            for: PhotoAdjustments(temperature: 20, tint: -10)
        )
        XCTAssertEqual(parameters.whiteBalance.temperatureOffsetKelvin, 900)
        XCTAssertEqual(parameters.whiteBalance.tintOffset, -15)
        XCTAssertFalse(parameters.whiteBalance.isAsShot)
    }

    func testNeutralIncludesTheNewIdentityFlags() {
        let parameters = AdjustmentMapping.renderParameters(for: .neutral)
        XCTAssertTrue(parameters.isSharpeningIdentity)
        XCTAssertTrue(parameters.isNoiseReductionIdentity)
        XCTAssertTrue(parameters.isVignetteIdentity)
    }

    func testSharpeningIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.sharpening = Sharpening(amount: 60, radius: 1.5, detail: 40, masking: 10)
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.sharpening, adjustments.sharpening)
        XCTAssertFalse(parameters.isSharpeningIdentity)
    }

    func testNoiseReductionIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.noiseReduction = NoiseReduction(luminanceAmount: 30, colorAmount: 20)
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.noiseReduction, adjustments.noiseReduction)
        XCTAssertFalse(parameters.isNoiseReductionIdentity)
    }

    func testVignetteIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.vignette = Vignette(amount: -40, midpoint: 60, roundness: 10, feather: 70)
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.vignette, adjustments.vignette)
        XCTAssertFalse(parameters.isVignetteIdentity)
    }

    func testGrainIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.grain = Grain(amount: 25, size: 60, roughness: 40)
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.grain, adjustments.grain)
        XCTAssertFalse(parameters.isGrainIdentity)
    }

    func testNeutralGrainIsIdentity() {
        XCTAssertTrue(AdjustmentMapping.renderParameters(for: .neutral).isGrainIdentity)
    }

    func testSplitToningIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.splitToning = SplitToning(shadowHue: 210, shadowSaturation: 30, highlightHue: 45, highlightSaturation: 20, balance: 0)
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.splitToning, adjustments.splitToning)
        XCTAssertFalse(parameters.isSplitToningIdentity)
    }

    func testNeutralSplitToningIsIdentity() {
        XCTAssertTrue(AdjustmentMapping.renderParameters(for: .neutral).isSplitToningIdentity)
    }

    func testAdvancedToneCurveIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.advancedToneCurve = AdvancedToneCurve(points: [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)])
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.advancedToneCurve, adjustments.advancedToneCurve)
        XCTAssertFalse(parameters.isAdvancedToneCurveIdentity)
    }

    func testNeutralAdvancedToneCurveIsIdentity() {
        XCTAssertTrue(AdjustmentMapping.renderParameters(for: .neutral).isAdvancedToneCurveIdentity)
    }

    func testHSLIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.hsl.blue = HSLBand(hue: -20, saturation: 40, luminance: 0)
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.hsl, adjustments.hsl)
        XCTAssertFalse(parameters.isHSLIdentity)
    }

    func testNeutralHSLIsIdentity() {
        XCTAssertTrue(AdjustmentMapping.renderParameters(for: .neutral).isHSLIdentity)
    }

    // MARK: - Geometry (Phase 2 Task 1: model/sidecar only, not wired into rendering yet)

    /// `RenderParameters` has no geometry field, and `renderParameters(for:)`
    /// never reads `PhotoAdjustments.geometry` — this pins that on purpose.
    /// Wiring crop/rotate/flip/straighten/perspective into the render chain
    /// is Task 2.2's job; until then, two adjustments differing only in
    /// `geometry` (neutral or not) must render identically, so adding the
    /// field cannot change any existing photo's output.
    func testGeometryNeverAffectsRenderParameters() {
        var withGeometry = PhotoAdjustments(exposure: 0.5, contrast: 20)
        withGeometry.geometry = GeometryAdjustments(
            crop: NormalizedCropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
            rotationDegrees: 90,
            flipHorizontal: true,
            straightenDegrees: 15
        )
        var withoutGeometry = PhotoAdjustments(exposure: 0.5, contrast: 20)
        withoutGeometry.geometry = .neutral

        XCTAssertEqual(
            AdjustmentMapping.renderParameters(for: withGeometry),
            AdjustmentMapping.renderParameters(for: withoutGeometry)
        )
    }

    func testNeutralGeometryDoesNotChangeTheNeutralIdentityRenderParameters() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.geometry = .neutral
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertTrue(parameters.isExposureIdentity)
        XCTAssertTrue(parameters.isContrastIdentity)
        XCTAssertEqual(parameters, AdjustmentMapping.renderParameters(for: .neutral))
    }

    // MARK: - P4: Presence, Color Grading, Monochrome, Rendering Profile, Lens Correction

    func testPresenceIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.presence = PresenceAdjustments(texture: 20, clarity: -10, dehaze: 30)
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.presence, adjustments.presence)
        XCTAssertFalse(parameters.isPresenceIdentity)
    }

    func testNeutralPresenceIsIdentity() {
        XCTAssertTrue(AdjustmentMapping.renderParameters(for: .neutral).isPresenceIdentity)
    }

    func testColorGradingIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.colorGrading.shadows = ColorGradeBand(hue: 220, saturation: 20, luminance: -5)
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.colorGrading, adjustments.colorGrading)
        XCTAssertFalse(parameters.isColorGradingIdentity)
    }

    func testNeutralColorGradingIsIdentity() {
        XCTAssertTrue(AdjustmentMapping.renderParameters(for: .neutral).isColorGradingIdentity)
    }

    func testMonochromeIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.monochrome = MonochromeAdjustments(isEnabled: true, red: 40)
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.monochrome, adjustments.monochrome)
        XCTAssertFalse(parameters.isMonochromeIdentity)
    }

    func testNeutralMonochromeIsIdentity() {
        XCTAssertTrue(AdjustmentMapping.renderParameters(for: .neutral).isMonochromeIdentity)
    }

    func testRenderingProfileIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.renderingProfile = RenderingProfileSelection(profileID: "lumaharbor.vivid", amount: 70)
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.renderingProfile, adjustments.renderingProfile)
        XCTAssertFalse(parameters.isRenderingProfileIdentity)
    }

    func testNeutralRenderingProfileIsIdentity() {
        XCTAssertTrue(AdjustmentMapping.renderParameters(for: .neutral).isRenderingProfileIdentity)
    }

    func testLensCorrectionIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.lensCorrection = LensCorrectionAdjustments(mode: .manual, distortionAmount: 25)
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.lensCorrection, adjustments.lensCorrection)
        XCTAssertFalse(parameters.isLensCorrectionIdentity)
    }

    func testNeutralLensCorrectionIsIdentity() {
        XCTAssertTrue(AdjustmentMapping.renderParameters(for: .neutral).isLensCorrectionIdentity)
    }
}
