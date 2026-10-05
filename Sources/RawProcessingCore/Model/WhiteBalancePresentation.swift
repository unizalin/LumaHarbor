import Foundation

/// Converts the decoder-relative white-balance offset into the absolute
/// Kelvin value shown by the editor, while keeping the persisted value in
/// stable relative units.  The decoder baseline is required for all new
/// writes; an unavailable baseline never becomes a fabricated 5500 K value.
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
    public static let eyedropperTemperatureSensitivityKelvin = 9_000.0
    public static let eyedropperTintSensitivity = 200.0

    /// One stored temperature unit remains 45 K for compatibility with the
    /// existing decoder mapping. The wider range is only a persistence safety
    /// envelope; effective values are narrowed by each photo's baseline.
    public static let kelvinPerStoredUnit = 45.0
    public static let minimumStoredOffset = -1_200.0
    public static let maximumStoredOffset = 1_200.0

    public static func kelvin(forStoredOffset offset: Double, baselineKelvin: Double) -> Double {
        resolve(storedOffset: offset, baselineKelvin: baselineKelvin).effectiveKelvin
            ?? clampedKelvin(defaultBaselineKelvin + clampedStoredOffset(offset) * kelvinPerStoredUnit)
    }

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

    /// The exact intersection required by the mainline white-balance contract.
    public static func allowedStoredOffsetRange(baselineKelvin: Double) -> ClosedRange<Double>? {
        guard let baseline = validBaseline(baselineKelvin) else { return nil }
        let lower = max(minimumStoredOffset, (minimumKelvin - baseline) / kelvinPerStoredUnit)
        let upper = min(maximumStoredOffset, (maximumKelvin - baseline) / kelvinPerStoredUnit)
        guard lower <= upper else { return nil }
        return lower...upper
    }

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

    /// Final decoder-facing guard. The input is in Kelvin offset units, while
    /// the shared resolver operates in stored units.
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

    public static func storedTemperatureOffset(forRedToBlueRatio ratio: Double) -> Double {
        guard ratio.isFinite, ratio > 0 else { return 0 }
        let kelvinDelta = -log2(ratio) * eyedropperTemperatureSensitivityKelvin
        return clampedStoredOffset(kelvinDelta / kelvinPerStoredUnit)
    }

    public static func storedTintOffset(forGreenToNeutralRatio ratio: Double) -> Double {
        guard ratio.isFinite, ratio > 0 else { return 0 }
        return min(max(log2(ratio) * eyedropperTintSensitivity, -100), 100)
    }

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
