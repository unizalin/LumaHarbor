import Foundation

/// One control point of the five-point tone curve, in normalised 0...1 space.
public struct ToneCurvePoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Turns the blacks / shadows / highlights / whites sliders into the five
/// control points `CIToneCurve` takes.
///
/// Pure arithmetic on purpose: this is the part of the look that has to stay
/// stable across releases, so it is unit-tested without touching Core Image.
public enum ToneCurveMapping {
    /// How far the 25% and 75% points may travel (in normalised units) at full
    /// slider deflection.
    public static let midpointShift = 0.15
    /// How far the black and white endpoints may travel at full deflection.
    public static let endpointShift = 0.20

    /// The identity curve, used when all four tone sliders sit at zero.
    public static let identity: [ToneCurvePoint] = [
        ToneCurvePoint(x: 0.00, y: 0.00),
        ToneCurvePoint(x: 0.25, y: 0.25),
        ToneCurvePoint(x: 0.50, y: 0.50),
        ToneCurvePoint(x: 0.75, y: 0.75),
        ToneCurvePoint(x: 1.00, y: 1.00)
    ]

    /// `true` when the four tone sliders leave the curve at identity, letting the
    /// pipeline skip the filter entirely.
    public static func isIdentity(_ adjustments: PhotoAdjustments) -> Bool {
        adjustments.blacks == 0
            && adjustments.shadows == 0
            && adjustments.highlights == 0
            && adjustments.whites == 0
    }

    public static func controlPoints(for adjustments: PhotoAdjustments) -> [ToneCurvePoint] {
        guard !isIdentity(adjustments) else { return identity }

        let blacks = adjustments.blacks / 100
        let shadows = adjustments.shadows / 100
        let highlights = adjustments.highlights / 100
        let whites = adjustments.whites / 100

        // Blacks: positive lifts the black point (y grows), negative crushes it
        // by moving the input threshold right (x grows). Either way the endpoint
        // stays a valid corner of the curve.
        let black = blacks >= 0
            ? ToneCurvePoint(x: 0, y: blacks * endpointShift)
            : ToneCurvePoint(x: -blacks * endpointShift, y: 0)

        // Whites mirror blacks at the top end: positive pulls the clipping point
        // left (brighter), negative pulls the output ceiling down.
        let white = whites >= 0
            ? ToneCurvePoint(x: 1 - whites * endpointShift, y: 1)
            : ToneCurvePoint(x: 1, y: 1 + whites * endpointShift)

        let points = [
            black,
            ToneCurvePoint(x: 0.25, y: clamp01(0.25 + shadows * midpointShift)),
            ToneCurvePoint(x: 0.50, y: 0.50),
            ToneCurvePoint(x: 0.75, y: clamp01(0.75 + highlights * midpointShift)),
            white
        ]

        return enforceMonotonicOutput(points)
    }

    /// x is strictly increasing by construction (the endpoints move at most
    /// `endpointShift` = 0.20, leaving a 0.05 gap to the fixed 0.25/0.75 points),
    /// but y can invert when neighbouring sliders are pushed in opposite
    /// directions. A non-monotonic curve makes `CIToneCurve` produce solarised
    /// output, so flatten instead.
    private static func enforceMonotonicOutput(_ points: [ToneCurvePoint]) -> [ToneCurvePoint] {
        var result: [ToneCurvePoint] = []
        result.reserveCapacity(points.count)
        for point in points {
            let y = max(clamp01(point.y), result.last?.y ?? 0)
            result.append(ToneCurvePoint(x: clamp01(point.x), y: y))
        }
        return result
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
