import Foundation

/// A curve layered on top of the four-slider tone curve (`ToneCurveMapping`),
/// applied later in the pipeline (spec §3.1, §4.2 step 5.5). Unlike the
/// four-slider curve, this one has no fixed point count — its only source is
/// a style file applying an arbitrary Lightroom-style curve, so the shape is
/// whatever `points` says.
public struct AdvancedToneCurve: Codable, Equatable, Hashable, Sendable {
    /// Normalised 0...1 control points. Empty = identity (no-op).
    public var points: [ToneCurvePoint]

    public init(points: [ToneCurvePoint] = []) {
        self.points = points
    }

    public static let neutral = AdvancedToneCurve(points: [])

    public var isIdentity: Bool { points.isEmpty }

    private enum CodingKeys: String, CodingKey { case points }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.points = try container.decodeIfPresent([ToneCurvePoint].self, forKey: .points) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
    }
}
