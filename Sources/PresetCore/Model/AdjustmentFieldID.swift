import Foundation

/// A stable identifier for one leaf of `AdjustmentPatch`.
///
/// Raw values are the on-disk/JSON-adjacent identity (spec §5.2) used by
/// mapping tables and diagnostics, so renaming a case is a schema-relevant
/// change even though `AdjustmentPatch` itself stores typed nested structs
/// rather than a dictionary keyed by this enum.
public enum AdjustmentFieldID: String, CaseIterable, Codable, Hashable, Sendable {
    case basicExposure = "basic.exposure"
    case basicTemperature = "basic.temperature"
    case basicTint = "basic.tint"
    case basicContrast = "basic.contrast"
    case basicHighlights = "basic.highlights"
    case basicShadows = "basic.shadows"
    case basicWhites = "basic.whites"
    case basicBlacks = "basic.blacks"
    case basicVibrance = "basic.vibrance"
    case basicSaturation = "basic.saturation"

    case advancedToneCurve

    case hslRedHue = "hsl.red.hue"
    case hslRedSaturation = "hsl.red.saturation"
    case hslRedLuminance = "hsl.red.luminance"
    case hslOrangeHue = "hsl.orange.hue"
    case hslOrangeSaturation = "hsl.orange.saturation"
    case hslOrangeLuminance = "hsl.orange.luminance"
    case hslYellowHue = "hsl.yellow.hue"
    case hslYellowSaturation = "hsl.yellow.saturation"
    case hslYellowLuminance = "hsl.yellow.luminance"
    case hslGreenHue = "hsl.green.hue"
    case hslGreenSaturation = "hsl.green.saturation"
    case hslGreenLuminance = "hsl.green.luminance"
    case hslAquaHue = "hsl.aqua.hue"
    case hslAquaSaturation = "hsl.aqua.saturation"
    case hslAquaLuminance = "hsl.aqua.luminance"
    case hslBlueHue = "hsl.blue.hue"
    case hslBlueSaturation = "hsl.blue.saturation"
    case hslBlueLuminance = "hsl.blue.luminance"
    case hslPurpleHue = "hsl.purple.hue"
    case hslPurpleSaturation = "hsl.purple.saturation"
    case hslPurpleLuminance = "hsl.purple.luminance"
    case hslMagentaHue = "hsl.magenta.hue"
    case hslMagentaSaturation = "hsl.magenta.saturation"
    case hslMagentaLuminance = "hsl.magenta.luminance"

    case splitToningShadowHue = "splitToning.shadowHue"
    case splitToningShadowSaturation = "splitToning.shadowSaturation"
    case splitToningHighlightHue = "splitToning.highlightHue"
    case splitToningHighlightSaturation = "splitToning.highlightSaturation"
    case splitToningBalance = "splitToning.balance"

    case sharpeningAmount = "sharpening.amount"
    case sharpeningRadius = "sharpening.radius"
    case sharpeningDetail = "sharpening.detail"
    case sharpeningMasking = "sharpening.masking"

    case noiseReductionLuminanceAmount = "noiseReduction.luminanceAmount"
    case noiseReductionLuminanceDetail = "noiseReduction.luminanceDetail"
    case noiseReductionColorAmount = "noiseReduction.colorAmount"
    case noiseReductionColorDetail = "noiseReduction.colorDetail"

    case vignetteAmount = "vignette.amount"
    case vignetteMidpoint = "vignette.midpoint"
    case vignetteRoundness = "vignette.roundness"
    case vignetteFeather = "vignette.feather"

    case grainAmount = "grain.amount"
    case grainSize = "grain.size"
    case grainRoughness = "grain.roughness"

    // P4: presence is granular (native XMP scalar mapping, see
    // XMPMappingRegistry); the other four groups are single whole-value
    // leaves (design spec §7's revised decision -- no per-user-facing-slider
    // XMP mapping exists for them, so granular field IDs would add
    // switch-case surface with no corresponding native mapping to justify it).
    case presenceTexture = "presence.texture"
    case presenceClarity = "presence.clarity"
    case presenceDehaze = "presence.dehaze"

    case colorGrading
    case monochrome
    case renderingProfile
    case lensCorrection
}

extension AdjustmentFieldID {
    /// The capability family used by the XMP manifest and import summary.
    public var xmpFeatureID: XMPFeatureID {
        switch self {
        case .basicExposure, .basicContrast, .basicHighlights, .basicShadows,
             .basicWhites, .basicBlacks, .basicVibrance, .basicSaturation:
            return .basic
        case .basicTemperature, .basicTint:
            return .whiteBalance
        case .presenceTexture, .presenceClarity, .presenceDehaze:
            return .presence
        case .advancedToneCurve:
            return .toneCurve
        case .hslRedHue, .hslRedSaturation, .hslRedLuminance,
             .hslOrangeHue, .hslOrangeSaturation, .hslOrangeLuminance,
             .hslYellowHue, .hslYellowSaturation, .hslYellowLuminance,
             .hslGreenHue, .hslGreenSaturation, .hslGreenLuminance,
             .hslAquaHue, .hslAquaSaturation, .hslAquaLuminance,
             .hslBlueHue, .hslBlueSaturation, .hslBlueLuminance,
             .hslPurpleHue, .hslPurpleSaturation, .hslPurpleLuminance,
             .hslMagentaHue, .hslMagentaSaturation, .hslMagentaLuminance:
            return .hsl
        case .splitToningShadowHue, .splitToningShadowSaturation,
             .splitToningHighlightHue, .splitToningHighlightSaturation,
             .splitToningBalance:
            return .splitToning
        case .sharpeningAmount, .sharpeningRadius, .sharpeningDetail,
             .sharpeningMasking:
            return .sharpening
        case .noiseReductionLuminanceAmount, .noiseReductionLuminanceDetail,
             .noiseReductionColorAmount, .noiseReductionColorDetail:
            return .noiseReduction
        case .vignetteAmount, .vignetteMidpoint, .vignetteRoundness,
             .vignetteFeather:
            return .vignette
        case .grainAmount, .grainSize, .grainRoughness:
            return .grain
        case .colorGrading:
            return .colorGrading
        case .monochrome:
            return .monochrome
        case .renderingProfile:
            return .renderingProfile
        case .lensCorrection:
            return .lensCorrection
        }
    }
}
