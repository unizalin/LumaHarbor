import Foundation

/// Computes the temperature/tint slider *delta* (design spec §6.4: "滴管
/// 選取預覽上的一點或小範圍，根據取樣結果調整 temperature / tint") that would
/// make a sampled colour more neutral (R ≈ G ≈ B).
///
/// A self-contained, first-version estimate from already-decoded/rendered
/// RGB (spec: "一般影像格式則以已解碼 RGB 估算") -- it deliberately never calls
/// into `CIRAWFilter`'s own `neutralLocation`/`neutralTemperature`
/// algorithm, which is proprietary and cannot be independently verified
/// against a Lightroom reference render here. Working from decoded RGB means
/// the exact same function samples a RAW preview and any future non-RAW decode
/// path identically. The RAW-specific "as-shot metadata baseline" half of
/// §6.4 is satisfied by `EditorSession` applying this delta *on top of* the
/// already-committed temperature/tint (which is itself already an offset from
/// `RawWhiteBalanceBaseline`, the decoder's own as-shot neutral -- see
/// `RawWhiteBalance`'s own doc comment), not by this pure function reading any
/// RAW-specific state directly.
public enum WhiteBalanceEyedropper {
    public enum SampleIssue: Equatable, Sendable {
        case nonFinite
        case outOfRange
        case tooDark
        case clipped
        case unavailableBaseline
        case staleFrame
    }

    /// One sampled colour, as gamma-encoded sRGB in `0...1` per channel --
    /// the same representation `ImageRenderService.makeCGImage(_:)`/
    /// `PixelSampler.sample(at:in:)` produce (what's actually on screen).
    public struct Sample: Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// The lower bound avoids trying to infer chromaticity from a near-black
    /// pixel, where sensor/read noise dominates the channel ratios.
    public static let minimumReliableLuminance = 0.03
    /// A channel at the top of the display range is clipped and cannot tell
    /// the eyedropper how much warmer/cooler the source really was.
    public static let clippingThreshold = 0.995

    public static func issue(for sample: Sample) -> SampleIssue? {
        let channels = [sample.red, sample.green, sample.blue]
        guard channels.allSatisfy(\.isFinite) else { return .nonFinite }
        guard channels.allSatisfy({ (0...1).contains($0) }) else { return .outOfRange }
        let luminance = 0.2126 * sample.red + 0.7152 * sample.green + 0.0722 * sample.blue
        if luminance < minimumReliableLuminance { return .tooDark }
        if channels.contains(where: { $0 >= clippingThreshold }) { return .clipped }
        return nil
    }

    /// The `(temperature, tint)` delta, in the stored units
    /// `PhotoAdjustments.temperature`/`.tint` use, that would push `sample`
    /// toward neutral gray. Callers add this to the *current* slider values
    /// (not replace them), so repeated sampling refines an existing edit
    /// rather than resetting it -- `AdjustmentCatalog`'s own clamp applies
    /// wherever the caller actually writes the result.
    public static func delta(neutralizing sample: Sample) -> (temperature: Double, tint: Double) {
        guard issue(for: sample) == nil else { return (0, 0) }
        // Floored well above zero: a sampled black/near-black pixel has no
        // reliable colour information to correct from, and log(0) is
        // undefined.
        let r = max(sample.red, 0.001)
        let g = max(sample.green, 0.001)
        let b = max(sample.blue, 0.001)

        // Blue-orange axis: R warmer than B currently reads as too warm, so
        // cool it down (negative delta cools, per this codebase's own
        // documented "+temperature warms" convention). The conversion lives
        // in WhiteBalancePresentation so the eyedropper and Kelvin UI share
        // one unit mapping.
        let temperatureDelta = WhiteBalancePresentation.storedTemperatureOffset(forRedToBlueRatio: r / b)

        // Green-magenta axis: the native RAW renderer's positive tint moves
        // toward magenta. G high relative to the R/B average therefore needs
        // a positive correction; keep this sign aligned with the actual
        // decoder output rather than the old helper convention.
        let average = (r + b) / 2
        let tintDelta = WhiteBalancePresentation.storedTintOffset(forGreenToNeutralRatio: g / average)

        guard temperatureDelta.isFinite, tintDelta.isFinite else { return (0, 0) }
        return (temperatureDelta, tintDelta)
    }

    /// Applies a sampled delta to an existing edit through the same catalogue
    /// range used by sliders, presets, and sidecar decoding.
    public static func applying(
        delta: (temperature: Double, tint: Double),
        to adjustments: PhotoAdjustments,
        baselineKelvin: Double? = nil
    ) -> PhotoAdjustments {
        applyingResolved(delta: delta, to: adjustments, baselineKelvin: baselineKelvin)?.adjustments ?? adjustments
    }

    public struct ApplicationResult: Equatable, Sendable {
        public let adjustments: PhotoAdjustments
        public let diagnostic: WhiteBalancePresentation.ResolutionDiagnostic
    }

    public static func applyingResolved(
        delta: (temperature: Double, tint: Double),
        to adjustments: PhotoAdjustments,
        baselineKelvin: Double?
    ) -> ApplicationResult? {
        guard let baselineKelvin, WhiteBalancePresentation.isValidBaseline(baselineKelvin),
              delta.temperature.isFinite, delta.tint.isFinite else { return nil }
        var updated = adjustments
        guard let startingTemperature = WhiteBalancePresentation.resolve(
            storedOffset: adjustments.temperature, baselineKelvin: baselineKelvin
        ).effectiveStoredOffset else { return nil }
        let resolution = WhiteBalancePresentation.resolve(
            storedOffset: startingTemperature + delta.temperature, baselineKelvin: baselineKelvin
        )
        guard let resolved = resolution.effectiveStoredOffset else { return nil }
        updated[.temperature] = resolved
        updated[.tint] = adjustments.tint + delta.tint
        return ApplicationResult(adjustments: updated.clamped(), diagnostic: resolution.diagnostic)
    }
}
