import Foundation

/// Lightroom-style sharpening (spec §3.4). Only `amount` gates identity;
/// `radius`/`detail`/`masking` matter only once sharpening is switched on.
public struct Sharpening: Codable, Equatable, Hashable, Sendable {
    public var amount: Double
    public var radius: Double
    public var detail: Double
    public var masking: Double

    public init(amount: Double = 0, radius: Double = 1.0, detail: Double = 25, masking: Double = 0) {
        self.amount = Self.clamp(amount, 0, 150)
        self.radius = Self.clamp(radius, 0.5, 3.0)
        self.detail = Self.clamp(detail, 0, 100)
        self.masking = Self.clamp(masking, 0, 100)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        guard value.isFinite else { return low > 0 ? low : 0 }
        return Swift.min(Swift.max(value, low), high)
    }

    public static let neutral = Sharpening()

    public var isIdentity: Bool { amount == 0 }

    private enum CodingKeys: String, CodingKey { case amount, radius, detail, masking }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.amount = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .amount) ?? 0, 0, 150)
        self.radius = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .radius) ?? 1.0, 0.5, 3.0)
        self.detail = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .detail) ?? 25, 0, 100)
        self.masking = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .masking) ?? 0, 0, 100)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(amount, forKey: .amount)
        try container.encode(radius, forKey: .radius)
        try container.encode(detail, forKey: .detail)
        try container.encode(masking, forKey: .masking)
    }
}
