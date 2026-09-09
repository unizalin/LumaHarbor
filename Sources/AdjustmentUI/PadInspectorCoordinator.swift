import Foundation

/// The five mutually-exclusive editor domains that the Studio Rails tool rail
/// exposes. Switching domain is pure presentation state — it never creates an
/// undo entry, triggers autosave, or re-decodes RAW.
public enum PadInspectorDomain: String, CaseIterable, Equatable, Sendable {
    case adjust
    case preset
    case geometry
    case local
    case info
}

/// Which sub-panel the Adjust inspector currently shows. Only meaningful when
/// the active domain is `.adjust`; the coordinator retains the last-selected
/// submode so switching away and back restores it.
public enum PadAdjustSubmode: String, CaseIterable, Equatable, Sendable {
    case light
    case color
    case detail
}

/// Stable string field identifiers for each Adjust submode panel.
///
/// Keys mirror `AdjustmentFieldID.rawValue` (PresetCore) and `AdjustmentKind.rawValue`
/// (RawProcessingCore) where applicable, so callers can bridge to either type
/// without creating a hard compile-time dependency on those modules here.
///
/// A key must not appear in more than one submode — this is a UI vocabulary
/// contract enforced by `PadInspectorCoordinatorTests`.
public enum PadAdjustSubmodeKinds {
    /// Tone sliders plus the parametric curve panel.
    public static let light: [String] = [
        "exposure", "contrast", "highlights", "shadows", "whites", "blacks",
        "advancedToneCurve",
    ]

    /// White-balance sliders, per-channel HSL, and vibrance/saturation.
    public static let color: [String] = [
        "basic.temperature", "basic.tint",
        "basic.vibrance", "basic.saturation",
        "hsl.red.hue", "hsl.red.saturation", "hsl.red.luminance",
        "hsl.orange.hue", "hsl.orange.saturation", "hsl.orange.luminance",
        "hsl.yellow.hue", "hsl.yellow.saturation", "hsl.yellow.luminance",
        "hsl.green.hue", "hsl.green.saturation", "hsl.green.luminance",
        "hsl.aqua.hue", "hsl.aqua.saturation", "hsl.aqua.luminance",
        "hsl.blue.hue", "hsl.blue.saturation", "hsl.blue.luminance",
        "hsl.purple.hue", "hsl.purple.saturation", "hsl.purple.luminance",
        "hsl.magenta.hue", "hsl.magenta.saturation", "hsl.magenta.luminance",
    ]

    /// Sharpening, noise reduction, vignette, and grain controls.
    public static let detail: [String] = [
        "sharpening.amount", "sharpening.radius", "sharpening.detail", "sharpening.masking",
        "noiseReduction.luminanceAmount", "noiseReduction.luminanceDetail",
        "noiseReduction.colorAmount", "noiseReduction.colorDetail",
        "vignette.amount", "vignette.midpoint", "vignette.roundness", "vignette.feather",
        "grain.amount", "grain.size", "grain.roughness",
    ]
}
