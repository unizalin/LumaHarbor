import Foundation
import RawProcessingCore

/// Spec §5.3: merge starts from the photo's current state, replace starts from
/// `.neutral`. Either way, only leaves the patch explicitly sets are touched.
public enum PresetApplicationMode: String, Codable, Sendable {
    case merge
    case replace
}

/// The photo-specific numbers a contextual leaf (white balance) needs at
/// apply time. Spec §5.3: white balance can't be resolved from the patch
/// alone, since Adobe presets store it as an absolute Kelvin/tint pair while
/// LumaHarbor's own sliders are offsets from whatever the RAW decoder reports
/// as as-shot neutral for *this* photo.
public struct PresetApplicationContext: Equatable, Sendable {
    public var baselineTemperatureKelvin: Double?
    public var baselineTint: Double?

    public init(baselineTemperatureKelvin: Double? = nil, baselineTint: Double? = nil) {
        self.baselineTemperatureKelvin = baselineTemperatureKelvin
        self.baselineTint = baselineTint
    }

    public static let none = PresetApplicationContext()
}

/// One thing worth surfacing about how a patch was applied -- a clamp, a
/// skipped contextual leaf -- keyed to safe, non-localized codes (mirrors
/// `XMPDiagnostic`, spec §6.2).
public struct PresetDiagnostic: Equatable, Sendable {
    public var severity: PresetDiagnosticSeverity
    public var code: String
    public var field: AdjustmentFieldID?
    public var detail: String?

    public init(severity: PresetDiagnosticSeverity, code: String, field: AdjustmentFieldID? = nil, detail: String? = nil) {
        self.severity = severity
        self.code = code
        self.field = field
        self.detail = detail
    }
}

public struct PresetApplicationResult: Equatable, Sendable {
    public var adjustments: PhotoAdjustments
    public var diagnostics: [PresetDiagnostic]

    public init(adjustments: PhotoAdjustments, diagnostics: [PresetDiagnostic] = []) {
        self.adjustments = adjustments
        self.diagnostics = diagnostics
    }
}

/// Applies an `AdjustmentPatch` to a photo's current `PhotoAdjustments` in one
/// pure step (spec §5.3). Never touches editor history itself -- the caller
/// records the *result* once, which is what makes a multi-leaf preset a single
/// undo entry (Task 6).
public struct PresetApplicator: Sendable {
    public init() {}

    /// - Parameter temperatureIsAbsoluteKelvin: `true` when `patch`'s
    ///   `basic.temperature`/`basic.tint` leaves (if present) came from an
    ///   Adobe document, where Temperature is an absolute Kelvin value and
    ///   Tint is relative to that document's own as-shot neutral -- both need
    ///   `context`'s baseline to become a LumaHarbor offset. `false` (the
    ///   default) for native presets, whose leaves are already LumaHarbor
    ///   offset units and portable across any photo without a baseline.
    ///   Callers derive this from `PresetDocument.source`, not per-call
    ///   guesswork, since it's a property of where the patch came from.
    ///
    /// Never throws -- every leaf that can't be resolved (e.g. a contextual
    /// white-balance leaf with no baseline) is left untouched and reported
    /// through `PresetApplicationResult.diagnostics` instead, which is the
    /// only outcome a caller actually needs to look at. A `throws` signature
    /// here previously invited callers to swallow it with `try?`, discarding
    /// `diagnostics` along with it -- there is nothing else it needs to fail.
    public func apply(
        _ patch: AdjustmentPatch,
        to current: PhotoAdjustments,
        mode: PresetApplicationMode,
        context: PresetApplicationContext,
        temperatureIsAbsoluteKelvin: Bool = false
    ) -> PresetApplicationResult {
        var result = mode == .replace ? PhotoAdjustments.neutral : current
        var diagnostics: [PresetDiagnostic] = []

        if let basic = patch.basic {
            if let value = basic.exposure { result[.exposure] = value }
            if let value = basic.contrast { result[.contrast] = value }
            if let value = basic.highlights { result[.highlights] = value }
            if let value = basic.shadows { result[.shadows] = value }
            if let value = basic.whites { result[.whites] = value }
            if let value = basic.blacks { result[.blacks] = value }
            if let value = basic.vibrance { result[.vibrance] = value }
            if let value = basic.saturation { result[.saturation] = value }

            if let value = basic.temperature {
                applyContextual(
                    field: .basicTemperature,
                    rawValue: value,
                    baseline: context.baselineTemperatureKelvin,
                    isAbsolute: temperatureIsAbsoluteKelvin,
                    span: AdjustmentMapping.kelvinPerTemperatureUnit,
                    kind: .temperature,
                    to: &result,
                    diagnostics: &diagnostics
                )
            }
            if let value = basic.tint {
                applyContextual(
                    field: .basicTint,
                    rawValue: value,
                    baseline: context.baselineTint,
                    isAbsolute: temperatureIsAbsoluteKelvin,
                    span: AdjustmentMapping.tintPerUnit,
                    kind: .tint,
                    to: &result,
                    diagnostics: &diagnostics
                )
            }
        }

        if let curve = patch.advancedToneCurve {
            result.advancedToneCurve = curve
        }

        if let hsl = patch.hsl {
            apply(hsl.red, to: &result.hsl.red)
            apply(hsl.orange, to: &result.hsl.orange)
            apply(hsl.yellow, to: &result.hsl.yellow)
            apply(hsl.green, to: &result.hsl.green)
            apply(hsl.aqua, to: &result.hsl.aqua)
            apply(hsl.blue, to: &result.hsl.blue)
            apply(hsl.purple, to: &result.hsl.purple)
            apply(hsl.magenta, to: &result.hsl.magenta)
        }

        if let splitToning = patch.splitToning {
            if let value = splitToning.shadowHue { result.splitToning.shadowHue = value }
            if let value = splitToning.shadowSaturation { result.splitToning.shadowSaturation = value }
            if let value = splitToning.highlightHue { result.splitToning.highlightHue = value }
            if let value = splitToning.highlightSaturation { result.splitToning.highlightSaturation = value }
            if let value = splitToning.balance { result.splitToning.balance = value }
        }

        if let sharpening = patch.sharpening {
            if let value = sharpening.amount { result.sharpening.amount = value }
            if let value = sharpening.radius { result.sharpening.radius = value }
            if let value = sharpening.detail { result.sharpening.detail = value }
            if let value = sharpening.masking { result.sharpening.masking = value }
        }

        if let noiseReduction = patch.noiseReduction {
            if let value = noiseReduction.luminanceAmount { result.noiseReduction.luminanceAmount = value }
            if let value = noiseReduction.luminanceDetail { result.noiseReduction.luminanceDetail = value }
            if let value = noiseReduction.colorAmount { result.noiseReduction.colorAmount = value }
            if let value = noiseReduction.colorDetail { result.noiseReduction.colorDetail = value }
        }

        if let vignette = patch.vignette {
            if let value = vignette.amount { result.vignette.amount = value }
            if let value = vignette.midpoint { result.vignette.midpoint = value }
            if let value = vignette.roundness { result.vignette.roundness = value }
            if let value = vignette.feather { result.vignette.feather = value }
        }

        if let grain = patch.grain {
            if let value = grain.amount { result.grain.amount = value }
            if let value = grain.size { result.grain.size = value }
            if let value = grain.roughness { result.grain.roughness = value }
        }

        return PresetApplicationResult(adjustments: result, diagnostics: diagnostics)
    }

    private func apply(_ band: HSLBandPatch?, to current: inout HSLBand) {
        guard let band else { return }
        if let value = band.hue { current.hue = value }
        if let value = band.saturation { current.saturation = value }
        if let value = band.luminance { current.luminance = value }
    }

    /// Resolves one white-balance leaf. When `isAbsolute` and a baseline is
    /// available, converts `rawValue` (absolute Kelvin, or a tint already
    /// relative to the document's own baseline) into a LumaHarbor offset and
    /// clamps it into range, diagnosing if clamping changed the value.
    /// Without a baseline, the current value is left untouched and a
    /// diagnostic explains why (spec §5.3: never fake a baseline with 0).
    private func applyContextual(
        field: AdjustmentFieldID,
        rawValue: Double,
        baseline: Double?,
        isAbsolute: Bool,
        span: Double,
        kind: AdjustmentKind,
        to result: inout PhotoAdjustments,
        diagnostics: inout [PresetDiagnostic]
    ) {
        guard isAbsolute else {
            result[kind] = rawValue
            return
        }
        guard let baseline else {
            diagnostics.append(PresetDiagnostic(
                severity: .warning,
                code: "missingWhiteBalanceBaseline",
                field: field,
                detail: "requested=\(rawValue)"
            ))
            return
        }
        let converted = (rawValue - baseline) / span
        let clamped = AdjustmentCatalog.definition(for: kind).clamp(converted)
        result[kind] = clamped
        if clamped != converted {
            diagnostics.append(PresetDiagnostic(
                severity: .warning,
                code: "clampedWhiteBalance",
                field: field,
                detail: "requested=\(rawValue) converted=\(converted) clamped=\(clamped)"
            ))
        }
    }
}
