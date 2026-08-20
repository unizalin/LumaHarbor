import Foundation

/// A curve layered on top of the four-slider tone curve (`ToneCurveMapping`),
/// applied later in the pipeline (spec §3.1, §4.2 step 5.5). Unlike the
/// four-slider curve, this one has no fixed point count — its only source is
/// a style file applying an arbitrary Lightroom-style curve, so the shape is
/// whatever `points` says.
public struct AdvancedToneCurve: Codable, Equatable, Hashable, Sendable {
    /// Normalised 0...1 control points. Empty = identity (no-op).
    public var points: [ToneCurvePoint] {
        didSet { points = Self.sanitise(points) }
    }

    public init(points: [ToneCurvePoint] = []) {
        self.points = Self.sanitise(points)
    }

    public static let neutral = AdvancedToneCurve(points: [])

    public var isIdentity: Bool { points.isEmpty }

    private enum CodingKeys: String, CodingKey { case points }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.points = Self.sanitise(
            try container.decodeIfPresent([ToneCurvePoint].self, forKey: .points) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
    }

    private static func sanitise(_ points: [ToneCurvePoint]) -> [ToneCurvePoint] {
        points.map { point in
            ToneCurvePoint(x: clamp01(point.x), y: clamp01(point.y))
        }
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, 0), 1)
    }
}
