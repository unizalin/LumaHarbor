import Foundation

/// Per-band hue-distance weighting for the 8-colour HSL kernel (spec §4.3).
///
/// A triangular falloff around each band's centre hue, on a wrapped 0...360
/// circle, so hues near a boundary blend smoothly between the two nearest
/// bands instead of snapping — the pure-Swift half of Task 7, kept separate
/// from the GPU kernel so the weighting math itself is unit-tested.
public enum HSLKernelWeights {
    /// Centre hue in degrees for red/orange/yellow/green/aqua/blue/purple/magenta,
    /// in the same order as `HSLAdjustments`'s stored properties.
    public static let bandCenters: [Double] = [0, 30, 60, 120, 180, 240, 275, 315]

    /// Half-width, in degrees, of one band's falloff before it reaches zero.
    /// Set to match the minimum 30° spacing between the closest band centers
    /// (e.g. red@0 and orange@30), so two bands at that closest spacing sum
    /// to exactly 1.0 at their shared midpoint -- not a dead zone, not
    /// amplified overlap.
    public static let halfWidthDegrees = 30.0

    /// 1.0 at `centerDegrees`, falling linearly to 0.0 at `halfWidthDegrees`
    /// away, wrapping correctly across the 0/360 seam.
    public static func weight(forHueDegrees hue: Double, centerDegrees: Double) -> Double {
        let distance = wrappedDistance(hue, centerDegrees)
        return max(0, 1 - distance / halfWidthDegrees)
    }

    private static func wrappedDistance(_ a: Double, _ b: Double) -> Double {
        let raw = abs(a.truncatingRemainder(dividingBy: 360) - b.truncatingRemainder(dividingBy: 360))
        return min(raw, 360 - raw)
    }
}
