import Foundation

/// A curve layered on top of the four-slider tone curve (`ToneCurveMapping`),
/// applied later in the pipeline (spec §3.1, §4.2 step 5.5). Unlike the
/// four-slider curve, this one has no fixed point count — its only source is
/// a style file applying an arbitrary Lightroom-style curve, so the shape is
/// whatever `points` says.
///
/// P3 (`docs/superpowers/specs/2026-09-10-per-channel-tone-curves.md`) adds
/// three independent per-channel curves layered after the composite one, in
/// fixed order Composite → Red/Green/Blue (design spec §8 step 4).
public struct AdvancedToneCurve: Codable, Equatable, Hashable, Sendable {
    /// Normalised 0...1 control points. Empty = identity (no-op). Composite
    /// channel; JSON key `points` predates per-channel curves and is kept
    /// unchanged for sidecar/preset backward compatibility.
    public var points: [ToneCurvePoint] {
        didSet { points = Self.sanitise(points) }
    }

    public var redPoints: [ToneCurvePoint] {
        didSet { redPoints = Self.sanitise(redPoints) }
    }

    public var greenPoints: [ToneCurvePoint] {
        didSet { greenPoints = Self.sanitise(greenPoints) }
    }

    public var bluePoints: [ToneCurvePoint] {
        didSet { bluePoints = Self.sanitise(bluePoints) }
    }

    public init(
        points: [ToneCurvePoint] = [],
        redPoints: [ToneCurvePoint] = [],
        greenPoints: [ToneCurvePoint] = [],
        bluePoints: [ToneCurvePoint] = []
    ) {
        self.points = Self.sanitise(points)
        self.redPoints = Self.sanitise(redPoints)
        self.greenPoints = Self.sanitise(greenPoints)
        self.bluePoints = Self.sanitise(bluePoints)
    }

    public static let neutral = AdvancedToneCurve()

    /// Identity requires every channel — composite and all three colour
    /// channels — to be empty. A curve with only a non-empty `redPoints`
    /// still changes the render and must not report as identity.
    public var isIdentity: Bool {
        points.isEmpty && redPoints.isEmpty && greenPoints.isEmpty && bluePoints.isEmpty
    }

    private enum CodingKeys: String, CodingKey { case points, redPoints, greenPoints, bluePoints }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.points = Self.sanitise(
            try container.decodeIfPresent([ToneCurvePoint].self, forKey: .points) ?? []
        )
        self.redPoints = Self.sanitise(
            try container.decodeIfPresent([ToneCurvePoint].self, forKey: .redPoints) ?? []
        )
        self.greenPoints = Self.sanitise(
            try container.decodeIfPresent([ToneCurvePoint].self, forKey: .greenPoints) ?? []
        )
        self.bluePoints = Self.sanitise(
            try container.decodeIfPresent([ToneCurvePoint].self, forKey: .bluePoints) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
        try container.encode(redPoints, forKey: .redPoints)
        try container.encode(greenPoints, forKey: .greenPoints)
        try container.encode(bluePoints, forKey: .bluePoints)
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

/// One of the four independently-editable tone curve channels (spec §6.2).
/// Lives in `RawProcessingCore`, not `AdjustmentUI`, because the XMP mapper
/// and the Metal LUT builder both need it and neither may depend on the UI
/// layer.
public enum ToneCurveChannel: String, CaseIterable, Codable, Sendable {
    case composite, red, green, blue
}

extension AdvancedToneCurve {
    public func points(for channel: ToneCurveChannel) -> [ToneCurvePoint] {
        switch channel {
        case .composite: return points
        case .red: return redPoints
        case .green: return greenPoints
        case .blue: return bluePoints
        }
    }

    public func isIdentity(for channel: ToneCurveChannel) -> Bool {
        points(for: channel).isEmpty
    }

    public func settingPoints(_ newPoints: [ToneCurvePoint], for channel: ToneCurveChannel) -> AdvancedToneCurve {
        var copy = self
        switch channel {
        case .composite: copy.points = newPoints
        case .red: copy.redPoints = newPoints
        case .green: copy.greenPoints = newPoints
        case .blue: copy.bluePoints = newPoints
        }
        return copy
    }

    public func resetting(_ channel: ToneCurveChannel) -> AdvancedToneCurve {
        settingPoints([], for: channel)
    }
}
