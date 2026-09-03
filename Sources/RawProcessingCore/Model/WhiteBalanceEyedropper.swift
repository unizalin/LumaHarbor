import Foundation

/// Computes the temperature/tint slider *delta* (design spec §6.4: "滴管
/// 選取預覽上的一點或小範圍，根據取樣結果調整 temperature / tint") that would
/// make a sampled colour more neutral (R ≈ G ≈ B).
///
/// A self-contained, first-version estimate from already-decoded/rendered
/// RGB (spec: "一般影像格式則以已解碼 RGB 估算") -- it deliberately never calls
/// into `CIRAWFilter`'s own `neutralLocation`/`neutralTemperature`
/// algorithm, which is proprietary and has no way to be verified in this
/// environment (no real RAW file fixture to decode against). Working from
/// decoded RGB instead means the exact same function samples a RAW preview
/// and any future non-RAW decode path identically. The RAW-specific "as-shot
/// metadata baseline" half of §6.4 is satisfied by `EditorSession` applying
/// this delta *on top of* the already-committed temperature/tint (which is
/// itself already an offset from `RawWhiteBalanceBaseline`, the decoder's
/// own as-shot neutral -- see `RawWhiteBalance`'s own doc comment), not by
/// this pure function reading any RAW-specific state directly.
public enum WhiteBalanceEyedropper {
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

    /// How strongly a channel imbalance maps to a slider-unit delta. Chosen
    /// so a moderately cast sample produces a visually meaningful nudge
    /// without usually saturating the ±100 slider range in one click --
    /// clicking again on the corrected preview refines it further, the same
    /// click-to-refine behaviour every eyedropper-style tool has.
    private static let temperatureSensitivity = 200.0
    private static let tintSensitivity = 200.0

    /// The `(temperature, tint)` delta, in the same ±100 slider units
    /// `PhotoAdjustments.temperature`/`.tint` use, that would push `sample`
    /// toward neutral gray. Callers add this to the *current* slider values
    /// (not replace them), so repeated sampling refines an existing edit
    /// rather than resetting it -- `AdjustmentCatalog`'s own clamp applies
    /// wherever the caller actually writes the result.
    public static func delta(neutralizing sample: Sample) -> (temperature: Double, tint: Double) {
        guard sample.red.isFinite, sample.green.isFinite, sample.blue.isFinite else { return (0, 0) }
        // Floored well above zero: a sampled black/near-black pixel has no
        // reliable colour information to correct from, and log(0) is
        // undefined.
        let r = max(sample.red, 0.001)
        let g = max(sample.green, 0.001)
        let b = max(sample.blue, 0.001)

        // Blue-orange axis: R warmer than B currently reads as too warm, so
        // cool it down (negative delta cools, per this codebase's own
        // documented "+temperature warms" convention).
        let warmthLog = log2(r / b)
        let temperatureDelta = -warmthLog * temperatureSensitivity

        // Green-magenta axis: G high relative to the R/B average currently
        // reads as too green, so add magenta (negative tint).
        let average = (r + b) / 2
        let greennessLog = log2(g / average)
        let tintDelta = -greennessLog * tintSensitivity

        guard temperatureDelta.isFinite, tintDelta.isFinite else { return (0, 0) }
        return (temperatureDelta, tintDelta)
    }
}
