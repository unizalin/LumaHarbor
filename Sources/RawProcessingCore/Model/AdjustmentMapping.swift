import Foundation

/// Everything the Core Image chain needs, expressed as plain numbers.
///
/// Separating "what the sliders mean" from "which filter runs" is what lets the
/// mapping be unit-tested with no GPU, no RAW file and no `CIContext`.
public struct RenderParameters: Equatable, Sendable {
    /// `CIExposureAdjust.inputEV`, applied in linear light.
    public let exposureEV: Double
    /// Added to the decoder's as-shot neutral temperature, in Kelvin.
    public let temperatureOffsetKelvin: Double
    /// Added to the decoder's as-shot neutral tint.
    public let tintOffset: Double
    /// `CIColorControls.contrast` (1.0 == unchanged).
    public let contrast: Double
    /// `CIColorControls.saturation` (1.0 == unchanged).
    public let saturation: Double
    /// `CIVibrance.amount` (0.0 == unchanged).
    public let vibrance: Double
    /// `CIToneCurve` control points, already monotonic.
    public let toneCurve: [ToneCurvePoint]
    public let sharpening: Sharpening
    public let noiseReduction: NoiseReduction
    public let vignette: Vignette
    public let grain: Grain
    public let splitToning: SplitToning
    public let advancedToneCurve: AdvancedToneCurve
    public let hsl: HSLAdjustments

    public var whiteBalance: RawWhiteBalance {
        RawWhiteBalance(
            temperatureOffsetKelvin: temperatureOffsetKelvin,
            tintOffset: tintOffset
        )
    }

    /// Whether the tone curve filter can be skipped.
    public var isToneCurveIdentity: Bool { toneCurve == ToneCurveMapping.identity }
    public var isContrastIdentity: Bool { contrast == 1 }
    public var isSaturationIdentity: Bool { saturation == 1 }
    public var isVibranceIdentity: Bool { vibrance == 0 }
    public var isExposureIdentity: Bool { exposureEV == 0 }
    public var isSharpeningIdentity: Bool { sharpening.isIdentity }
    public var isNoiseReductionIdentity: Bool { noiseReduction.isIdentity }
    public var isVignetteIdentity: Bool { vignette.isIdentity }
    public var isGrainIdentity: Bool { grain.isIdentity }
    public var isSplitToningIdentity: Bool { splitToning.isIdentity }
    public var isAdvancedToneCurveIdentity: Bool { advancedToneCurve.isIdentity }
    public var isHSLIdentity: Bool { hsl.isIdentity }
}

/// The one place slider units become Core Image units.
///
/// Spec §8.2 requires this to be centralised and pinned by tests; the constants
/// below are therefore part of the observable behaviour, not implementation
/// detail. Changing one changes everyone's renders.
public enum AdjustmentMapping {
    /// ±100 on the temperature slider spans ±4500 K around the as-shot neutral,
    /// which covers tungsten-to-shade without letting the slider reach values
    /// `CIRAWFilter` clips anyway.
    public static let kelvinPerTemperatureUnit = 45.0
    /// ±100 tint spans ±150, matching the usable range of `CIRAWFilter.neutralTint`.
    public static let tintPerUnit = 1.5
    /// ±100 contrast maps to 0.5...1.5 in `CIColorControls`.
    public static let contrastSpan = 0.5
    /// ±100 saturation maps to 0.0...2.0 (fully desaturated to double).
    public static let saturationSpan = 1.0
    /// ±100 vibrance maps to the full -1...1 `CIVibrance` range.
    public static let vibranceSpan = 1.0
    /// `CISharpenLuminance.inputSharpness` span. Amount 0...150 maps to
    /// sharpness 0...3.0; radius passes straight through (spec's radius range
    /// 0.5...3.0 already matches the filter's own expected units).
    public static let sharpenLuminanceSharpnessSpan = 3.0 / 150.0
    /// `CINoiseReduction` exposes exactly two knobs (`inputNoiseLevel`,
    /// `inputSharpness`), not independent luminance/colour controls. Amount is
    /// the average of the two Lightroom-style amounts, mapped to a noise level
    /// span Apple's own filter treats as strong (its own default is 0.02).
    public static let noiseReductionNoiseLevelSpan = 0.1 / 100.0
    public static let noiseReductionSharpnessSpan = 2.0 / 100.0

    public static func renderParameters(for adjustments: PhotoAdjustments) -> RenderParameters {
        let clamped = adjustments.clamped()
        return RenderParameters(
            exposureEV: clamped.exposure,
            temperatureOffsetKelvin: clamped.temperature * kelvinPerTemperatureUnit,
            tintOffset: clamped.tint * tintPerUnit,
            contrast: 1 + (clamped.contrast / 100) * contrastSpan,
            saturation: 1 + (clamped.saturation / 100) * saturationSpan,
            vibrance: (clamped.vibrance / 100) * vibranceSpan,
            toneCurve: ToneCurveMapping.controlPoints(for: clamped),
            sharpening: clamped.sharpening,
            noiseReduction: clamped.noiseReduction,
            vignette: clamped.vignette,
            grain: clamped.grain,
            splitToning: clamped.splitToning,
            advancedToneCurve: clamped.advancedToneCurve,
            hsl: clamped.hsl
        )
    }
}
