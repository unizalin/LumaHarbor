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
    ///
    /// Sized by the *widest* gap on the wheel, not the narrowest. Each centre's
    /// nearest neighbour sits 30, 30, 30, 60, 60, 35, 35 and 40 degrees away
    /// respectively, so the largest of those minimums is 60 — and at 30 (the
    /// smallest of them) every hue at the midpoint of a 60°-apart pair, i.e.
    /// 90°, 150° and 210°, got a combined weight of exactly zero from all eight
    /// bands. Those were hard dead zones where an HSL edit did nothing at all,
    /// which spec §4.3 explicitly rules out（避免區塊交界處色調斷層）.
    ///
    /// At 60 the closely-spaced pairs now overlap to more than 1.0 near their
    /// shared midpoint; the kernel renormalises by the summed weight whenever
    /// that total exceeds 1.0 (see `AdjustmentPipeline.hslKernel`), so the blend
    /// never amplifies beyond one band at full strength.
    public static let halfWidthDegrees = 60.0

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
