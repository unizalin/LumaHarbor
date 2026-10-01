import Foundation

/// Converts the sidecar's decoder-relative white-balance offset into the
/// absolute Kelvin presentation used by Lightroom-style RAW controls.
///
/// The stored value remains an offset so an edit can be replayed against the
/// same photo's as-shot decoder baseline. The presentation layer is deliberately
/// separate: a user entering `3200 K` must not have to know that the current
/// camera baseline was `5476 K`, and a slider should feel more uniform in mired
/// space than in a linear Kelvin scale.
public enum WhiteBalancePresentation {
    public enum Capability: Equatable, Sendable {
        case loading, unavailable, invalid, valid
    }

    public static func capability(baseline: Double?, isLoading: Bool = false) -> Capability {
        guard let baseline else { return isLoading ? .loading : .unavailable }
        return isValidBaseline(baseline) ? .valid : .invalid
    }

    public enum ResolutionDiagnostic: Equatable, Sendable {
        case none
        case clamped
        case invalidBaseline
        case invalidOffset
    }

    public struct Resolution: Equatable, Sendable {
        public let effectiveStoredOffset: Double?
        public let effectiveKelvin: Double?
        public let allowedStoredOffset: ClosedRange<Double>?
        public let diagnostic: ResolutionDiagnostic

        public init(
            effectiveStoredOffset: Double?,
            effectiveKelvin: Double?,
            allowedStoredOffset: ClosedRange<Double>?,
            diagnostic: ResolutionDiagnostic
        ) {
            self.effectiveStoredOffset = effectiveStoredOffset
            self.effectiveKelvin = effectiveKelvin
            self.allowedStoredOffset = allowedStoredOffset
            self.diagnostic = diagnostic
        }

        public var wasClamped: Bool { diagnostic == .clamped }
    }

    public static let minimumKelvin = 2_000.0
    public static let maximumKelvin = 50_000.0
    public static let defaultBaselineKelvin = 5_500.0
    public static let miredPerKelvin = 1_000_000.0
    /// The first-pass RGB eyedropper calibration is expressed in Kelvin so it
    /// cannot drift away from the global RAW temperature mapping. The value
    /// is centralized here; fixture calibration only changes this constant
    /// and its contract tests.
    public static let eyedropperTemperatureSensitivityKelvin = 9_000.0
    public static let eyedropperTintSensitivity = 200.0

    /// Kept equal to the existing renderer mapping so old sidecars retain the
    /// same visual meaning. Only the permitted stored offset range is widened
    /// to cover the RAW Kelvin range exposed by the presentation.
    public static let kelvinPerStoredUnit = 45.0
    // The wider range covers the complete presentation interval even when a
    // camera's as-shot baseline is near the edge of the usual RAW range.
    public static let minimumStoredOffset = -1_200.0
    public static let maximumStoredOffset = 1_200.0

    public static func kelvin(forStoredOffset offset: Double, baselineKelvin: Double) -> Double {
        resolve(storedOffset: offset, baselineKelvin: baselineKelvin).effectiveKelvin
            ?? clampedKelvin(defaultBaselineKelvin + clampedStoredOffset(offset) * kelvinPerStoredUnit)
    }

    /// Resolves the display value only when both the stored offset and the
    /// decoder baseline are trustworthy.  UI write paths must use this form
    /// so an unavailable baseline cannot silently turn into a fabricated
    /// 5500 K reading.
    public static func kelvinIfResolvable(
        forStoredOffset offset: Double,
        baselineKelvin: Double
    ) -> Double? {
        resolve(storedOffset: offset, baselineKelvin: baselineKelvin).effectiveKelvin
    }

    public static func isValidBaseline(_ value: Double) -> Bool {
        validBaseline(value) != nil
    }

    public static func storedOffset(forKelvin kelvin: Double, baselineKelvin: Double) -> Double {
        storedOffsetIfResolvable(forKelvin: kelvin, baselineKelvin: baselineKelvin) ?? 0
    }

    /// Optional form used by write paths that must distinguish an unavailable
    /// baseline from a valid zero offset.  The non-optional compatibility
    /// helper above remains for existing presentation-only callers.
    public static func storedOffsetIfResolvable(
        forKelvin kelvin: Double,
        baselineKelvin: Double
    ) -> Double? {
        guard kelvin.isFinite,
              let baseline = validBaseline(baselineKelvin),
              let range = allowedStoredOffsetRange(baselineKelvin: baseline) else {
            return nil
        }
        let target = clampedKelvin(kelvin)
        let raw = (target - baseline) / kelvinPerStoredUnit
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    /// Returns the intersection of the legacy stored range and the absolute
    /// Kelvin range for a particular decoder baseline.
    public static func allowedStoredOffsetRange(baselineKelvin: Double) -> ClosedRange<Double>? {
        guard let baseline = validBaseline(baselineKelvin) else { return nil }
        let lower = max(minimumStoredOffset, (minimumKelvin - baseline) / kelvinPerStoredUnit)
        let upper = min(maximumStoredOffset, (maximumKelvin - baseline) / kelvinPerStoredUnit)
        guard lower <= upper else { return nil }
        return lower...upper
    }

    /// Resolves a sidecar-relative offset before presentation, preview,
    /// export, or a native RAW decoder receives it.
    public static func resolve(storedOffset: Double, baselineKelvin: Double) -> Resolution {
        guard let baseline = validBaseline(baselineKelvin),
              let allowed = allowedStoredOffsetRange(baselineKelvin: baseline) else {
            return Resolution(
                effectiveStoredOffset: nil,
                effectiveKelvin: nil,
                allowedStoredOffset: nil,
                diagnostic: .invalidBaseline
            )
        }
        guard storedOffset.isFinite else {
            return Resolution(
                effectiveStoredOffset: 0,
                effectiveKelvin: baseline,
                allowedStoredOffset: allowed,
                diagnostic: .invalidOffset
            )
        }
        let effective = min(max(storedOffset, allowed.lowerBound), allowed.upperBound)
        let diagnostic: ResolutionDiagnostic = effective == storedOffset ? .none : .clamped
        return Resolution(
            effectiveStoredOffset: effective,
            effectiveKelvin: baseline + effective * kelvinPerStoredUnit,
            allowedStoredOffset: allowed,
            diagnostic: diagnostic
        )
    }

    /// Resolves a decoder-relative Kelvin offset using the decoder's actual
    /// as-shot baseline. This is the final defense for callers that bypass the
    /// inspector and hand a `RawWhiteBalance` directly to the decoder.
    public static func resolve(offsetKelvin: Double, baselineKelvin: Double) -> Double? {
        guard offsetKelvin.isFinite,
              let baseline = validBaseline(baselineKelvin),
              let allowed = allowedStoredOffsetRange(baselineKelvin: baseline) else {
            return nil
        }
        let minimumOffsetKelvin = allowed.lowerBound * kelvinPerStoredUnit
        let maximumOffsetKelvin = allowed.upperBound * kelvinPerStoredUnit
        return min(max(offsetKelvin, minimumOffsetKelvin), maximumOffsetKelvin)
    }

    /// Converts the red/blue log ratio used by the RGB eyedropper into the
    /// same stored relative units the RAW decoder consumes.
    public static func storedTemperatureOffset(forRedToBlueRatio ratio: Double) -> Double {
        guard ratio.isFinite, ratio > 0 else { return 0 }
        let kelvinDelta = -log2(ratio) * eyedropperTemperatureSensitivityKelvin
        return clampedStoredOffset(kelvinDelta / kelvinPerStoredUnit)
    }

    /// Converts the green-vs-neutral log ratio into the stored tint units used
    /// by `CIRAWFilter.neutralTint`.
    public static func storedTintOffset(forGreenToNeutralRatio ratio: Double) -> Double {
        guard ratio.isFinite, ratio > 0 else { return 0 }
        return min(max(log2(ratio) * eyedropperTintSensitivity, -100), 100)
    }

    /// Maps cool → warm from left → right using mired space. The visual
    /// direction matches Lightroom even though mired itself decreases as
    /// Kelvin rises.
    public static func sliderValue(forKelvin kelvin: Double) -> Double {
        let mired = miredPerKelvin / clampedKelvin(kelvin)
        return maximumMired - (mired - minimumMired)
    }

    public static func sliderRange(baselineKelvin: Double) -> ClosedRange<Double> {
        guard let allowed = allowedStoredOffsetRange(baselineKelvin: baselineKelvin) else {
            return minimumSliderValue...maximumSliderValue
        }
        let lowerKelvin = baselineKelvin + allowed.lowerBound * kelvinPerStoredUnit
        let upperKelvin = baselineKelvin + allowed.upperBound * kelvinPerStoredUnit
        return sliderValue(forKelvin: lowerKelvin)...sliderValue(forKelvin: upperKelvin)
    }

    public static func kelvin(forSliderValue value: Double) -> Double {
        let slider = min(max(value, minimumSliderValue), maximumSliderValue)
        let mired = maximumMired - (slider - minimumSliderValue)
        return clampedKelvin(miredPerKelvin / mired)
    }

    public static func clampedKelvin(_ value: Double) -> Double {
        guard value.isFinite else { return defaultBaselineKelvin }
        return min(max(value, minimumKelvin), maximumKelvin)
    }

    public static func clampedStoredOffset(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, minimumStoredOffset), maximumStoredOffset)
    }

    private static func validBaseline(_ value: Double) -> Double? {
        guard value.isFinite, value >= minimumKelvin, value <= maximumKelvin else { return nil }
        return value
    }

    public static let minimumSliderValue: Double = {
        maximumMired - (maximumMired - minimumMired)
    }()
    public static let maximumSliderValue: Double = {
        maximumMired - (minimumMired - minimumMired)
    }()

    private static let minimumMired = miredPerKelvin / maximumKelvin
    private static let maximumMired = miredPerKelvin / minimumKelvin
}
