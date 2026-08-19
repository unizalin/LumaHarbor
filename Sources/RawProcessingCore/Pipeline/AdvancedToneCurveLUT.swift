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
