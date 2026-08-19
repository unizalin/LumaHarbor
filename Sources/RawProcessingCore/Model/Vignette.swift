import Foundation

/// Post-processing vignette (not lens-correction vignetting). Negative
/// `amount` darkens the corners, positive brightens them (spec §3.6).
public struct Vignette: Codable, Equatable, Hashable, Sendable {
    public var amount: Double
    public var midpoint: Double
    public var roundness: Double
    public var feather: Double

    public init(amount: Double = 0, midpoint: Double = 50, roundness: Double = 0, feather: Double = 50) {
        self.amount = Self.clamp(amount, -100, 100)
        self.midpoint = Self.clamp(midpoint, 0, 100)
        self.roundness = Self.clamp(roundness, -100, 100)
        self.feather = Self.clamp(feather, 0, 100)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, low), high)
    }

    public static let neutral = Vignette()

    public var isIdentity: Bool { amount == 0 }

    private enum CodingKeys: String, CodingKey { case amount, midpoint, roundness, feather }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ fallback: Double, _ low: Double, _ high: Double) throws -> Double {
            Self.clamp(try container.decodeIfPresent(Double.self, forKey: key) ?? fallback, low, high)
        }
        self.amount = try value(.amount, 0, -100, 100)
        self.midpoint = try value(.midpoint, 50, 0, 100)
        self.roundness = try value(.roundness, 0, -100, 100)
        self.feather = try value(.feather, 50, 0, 100)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(amount, forKey: .amount)
        try container.encode(midpoint, forKey: .midpoint)
        try container.encode(roundness, forKey: .roundness)
        try container.encode(feather, forKey: .feather)
    }
}
