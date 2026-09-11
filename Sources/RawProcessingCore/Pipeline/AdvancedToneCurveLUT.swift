import Foundation

/// Turns an arbitrary-length control-point curve into a fixed-resolution
/// lookup table, so `CIColorKernel` can do a flat per-pixel table lookup
/// instead of evaluating a spline on the GPU (spec §4.3).
///
/// Pure Swift, no Core Image — this is the part of Task 6 that is actually
/// unit-testable; the kernel that samples this table on the GPU is not
/// (verified manually instead, spec §6).
public enum AdvancedToneCurveLUT {
    /// - Parameters:
    ///   - points: Normalised 0...1 control points. Does not need to arrive
    ///     sorted or monotonic in y -- both are enforced here so a hostile or
    ///     malformed style file can't solarise the render (same risk as
    ///     `ToneCurveMapping.enforceMonotonicOutput`).
    ///   - resolution: Number of samples in the returned table.
    public static func build(from points: [ToneCurvePoint], resolution: Int = 256) -> [Float] {
        guard resolution > 0 else { return [] }
        // A one-sample LUT cannot represent an interval. Define it as the
        // curve's black-endpoint sample (or zero for the empty identity curve)
        // so this degenerate public-API input stays finite and deterministic.
        if resolution == 1 {
            guard !points.isEmpty else { return [0] }
            let sorted = points.sorted { $0.x < $1.x }
            return [Float(clamp01(interpolate(0, in: sorted)))]
        }
        guard !points.isEmpty else {
            return (0..<resolution).map { Float($0) / Float(resolution - 1) }
        }
        guard points.count > 1 else {
            let value = Float(clamp01(points[0].y))
            return Array(repeating: value, count: resolution)
        }

        let sorted = points.sorted { $0.x < $1.x }
        var table = [Float](repeating: 0, count: resolution)
        for i in 0..<resolution {
            let x = Double(i) / Double(resolution - 1)
            table[i] = Float(clamp01(interpolate(x, in: sorted)))
        }
        return enforceMonotonicNonDecreasing(table)
    }

    /// Composes a per-channel curve after the composite curve (spec §8 step
    /// 4: composite is applied first, then the channel curve), producing one
    /// combined table. Sampling the already-built discrete tables (rather
    /// than composing the two continuous curves directly) keeps this a thin
    /// wrapper around `build`, at the cost of one extra rounding step per
    /// sample -- well within the pipeline's `0.5/255` average / `2/255` p99
    /// accuracy budget (spec §11.4 item 24).
    ///
    /// Composing two non-decreasing tables always yields a non-decreasing
    /// table, so no extra monotonic enforcement is needed here.
    public static func buildCombined(
        compositePoints: [ToneCurvePoint],
        channelPoints: [ToneCurvePoint],
        resolution: Int = 256
    ) -> [Float] {
        let compositeTable = build(from: compositePoints, resolution: resolution)
        // An identity channel leaves the composite result untouched -- return
        // it directly rather than round-tripping every sample through an
        // index lookup, which would otherwise quantise an exact composite
        // value to the nearest 1/(resolution-1) step for no reason.
        guard !channelPoints.isEmpty else { return compositeTable }
        let channelTable = build(from: channelPoints, resolution: resolution)
        guard resolution > 1 else { return compositeTable }
        let lastIndex = Float(resolution - 1)
        return compositeTable.map { value in
            let index = Int((value * lastIndex).rounded())
            let clampedIndex = Swift.min(Swift.max(index, 0), resolution - 1)
            return channelTable[clampedIndex]
        }
    }

    private static func interpolate(_ x: Double, in points: [ToneCurvePoint]) -> Double {
        if x <= points.first!.x { return points.first!.y }
        if x >= points.last!.x { return points.last!.y }
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            guard x <= current.x else { continue }
            let span = current.x - previous.x
            guard span > 0 else { return current.y }
            let t = (x - previous.x) / span
            return previous.y + t * (current.y - previous.y)
        }
        return points.last!.y
    }

    private static func enforceMonotonicNonDecreasing(_ table: [Float]) -> [Float] {
        var result = table
        for i in 1..<result.count {
            result[i] = max(result[i], result[i - 1])
        }
        return result
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
