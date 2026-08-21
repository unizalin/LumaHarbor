import RawProcessingCore

/// Bridges `AdjustmentFieldID` to `PhotoAdjustments`, the render-side value
/// `AdjustmentPatch` leaves ultimately come from or go into. Lives in
/// `PresetCore` (which already depends on `RawProcessingCore`) rather than in
/// `RawProcessingCore` itself, since `AdjustmentFieldID` is a Preset concept
/// -- spec §9.2's "create a preset from this photo" is the first place that
/// needs to go from a full `PhotoAdjustments` to a selected subset.
public extension PhotoAdjustments {
    /// The value of one field, or `nil` for the whole-value `advancedToneCurve`
    /// leaf (mirrors `AdjustmentPatch.scalarValue(for:)`).
    func scalarValue(for field: AdjustmentFieldID) -> Double? {
        switch field {
        case .basicExposure: return exposure
        case .basicTemperature: return temperature
        case .basicTint: return tint
        case .basicContrast: return contrast
        case .basicHighlights: return highlights
        case .basicShadows: return shadows
        case .basicWhites: return whites
        case .basicBlacks: return blacks
        case .basicVibrance: return vibrance
        case .basicSaturation: return saturation
        case .advancedToneCurve: return nil
        case .hslRedHue: return hsl.red.hue
        case .hslRedSaturation: return hsl.red.saturation
        case .hslRedLuminance: return hsl.red.luminance
        case .hslOrangeHue: return hsl.orange.hue
        case .hslOrangeSaturation: return hsl.orange.saturation
        case .hslOrangeLuminance: return hsl.orange.luminance
        case .hslYellowHue: return hsl.yellow.hue
        case .hslYellowSaturation: return hsl.yellow.saturation
        case .hslYellowLuminance: return hsl.yellow.luminance
        case .hslGreenHue: return hsl.green.hue
        case .hslGreenSaturation: return hsl.green.saturation
        case .hslGreenLuminance: return hsl.green.luminance
        case .hslAquaHue: return hsl.aqua.hue
        case .hslAquaSaturation: return hsl.aqua.saturation
        case .hslAquaLuminance: return hsl.aqua.luminance
        case .hslBlueHue: return hsl.blue.hue
        case .hslBlueSaturation: return hsl.blue.saturation
        case .hslBlueLuminance: return hsl.blue.luminance
        case .hslPurpleHue: return hsl.purple.hue
        case .hslPurpleSaturation: return hsl.purple.saturation
        case .hslPurpleLuminance: return hsl.purple.luminance
        case .hslMagentaHue: return hsl.magenta.hue
        case .hslMagentaSaturation: return hsl.magenta.saturation
        case .hslMagentaLuminance: return hsl.magenta.luminance
        case .splitToningShadowHue: return splitToning.shadowHue
        case .splitToningShadowSaturation: return splitToning.shadowSaturation
        case .splitToningHighlightHue: return splitToning.highlightHue
        case .splitToningHighlightSaturation: return splitToning.highlightSaturation
        case .splitToningBalance: return splitToning.balance
        case .sharpeningAmount: return sharpening.amount
        case .sharpeningRadius: return sharpening.radius
        case .sharpeningDetail: return sharpening.detail
        case .sharpeningMasking: return sharpening.masking
        case .noiseReductionLuminanceAmount: return noiseReduction.luminanceAmount
        case .noiseReductionLuminanceDetail: return noiseReduction.luminanceDetail
        case .noiseReductionColorAmount: return noiseReduction.colorAmount
        case .noiseReductionColorDetail: return noiseReduction.colorDetail
        case .vignetteAmount: return vignette.amount
        case .vignetteMidpoint: return vignette.midpoint
        case .vignetteRoundness: return vignette.roundness
        case .vignetteFeather: return vignette.feather
        case .grainAmount: return grain.amount
        case .grainSize: return grain.size
        case .grainRoughness: return grain.roughness
        }
    }
}

public extension AdjustmentPatch {
    /// Builds a patch containing only `fields`, read out of `adjustments`.
    /// Anything not selected stays genuinely absent (spec §5.2) -- not merely
    /// equal to the default.
    static func extracting(_ fields: Set<AdjustmentFieldID>, from adjustments: PhotoAdjustments) -> AdjustmentPatch {
        var builder = AdjustmentPatchBuilder()
        for field in fields {
            if field == .advancedToneCurve {
                builder.advancedToneCurve = adjustments.advancedToneCurve
            } else if let value = adjustments.scalarValue(for: field) {
                builder.set(field, to: value)
            }
        }
        return builder.build()
    }

    /// Fields whose value in `adjustments` differs from `.neutral` -- the
    /// default selection when creating a preset from a photo (spec §9.2:
    /// "預設勾選與 .neutral 不同的 leaf").
    static func modifiedFields(in adjustments: PhotoAdjustments) -> Set<AdjustmentFieldID> {
        Set(AdjustmentFieldID.allCases.filter { field in
            if field == .advancedToneCurve { return !adjustments.advancedToneCurve.isIdentity }
            return adjustments.scalarValue(for: field) != PhotoAdjustments.neutral.scalarValue(for: field)
        })
    }

    /// A copy with `fields` set back to absent. Used when the user unchecks
    /// an approximate leaf in the XMP import summary before saving (spec
    /// §9.3: "使用者可取消 approximate leaf").
    func excluding(_ fields: Set<AdjustmentFieldID>) -> AdjustmentPatch {
        guard !fields.isEmpty else { return self }
        var builder = AdjustmentPatchBuilder()
        for field in AdjustmentFieldID.allCases where contains(field) && !fields.contains(field) {
            if field == .advancedToneCurve {
                builder.advancedToneCurve = advancedToneCurve
            } else if let value = scalarValue(for: field) {
                builder.set(field, to: value)
            }
        }
        return builder.build()
    }
}
