import Foundation

/// Simulated film grain (spec §3.7).
public struct Grain: Codable, Equatable, Hashable, Sendable {
    public var amount: Double {
        didSet { amount = Self.clamp(amount) }
    }
    /// 0...100, mapped to a blur radius in pixels defined against a
    /// full-resolution decode; `AdjustmentPipeline` scales that radius down
    /// by `scaleFactor` for a downsampled preview decode (spec §7 Gate B3).
    /// This only normalises clump *size* — the underlying noise texture is
    /// still generated at one sample per decoded pixel, so its base
    /// frequency stays tied to decode resolution regardless of this value.
    public var size: Double {
        didSet { size = Self.clamp(size) }
    }
    public var roughness: Double {
        didSet { roughness = Self.clamp(roughness) }
    }

    public init(amount: Double = 0, size: Double = 25, roughness: Double = 50) {
        self.amount = Self.clamp(amount)
        self.size = Self.clamp(size)
        self.roughness = Self.clamp(roughness)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, 0), 100)
    }

    public static let neutral = Grain()

    public var isIdentity: Bool { amount == 0 }

    private enum CodingKeys: String, CodingKey { case amount, size, roughness }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.amount = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .amount) ?? 0)
        self.size = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .size) ?? 25)
        self.roughness = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .roughness) ?? 50)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(amount, forKey: .amount)
        try container.encode(size, forKey: .size)
        try container.encode(roughness, forKey: .roughness)
    }
}
