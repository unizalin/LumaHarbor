import Foundation

/// Independent shadow/highlight colour tinting (spec §3.3).
public struct SplitToning: Codable, Equatable, Hashable, Sendable {
    public var shadowHue: Double {
        didSet { shadowHue = Self.clamp(shadowHue, 0, 360) }
    }
    public var shadowSaturation: Double {
        didSet { shadowSaturation = Self.clamp(shadowSaturation, 0, 100) }
    }
    public var highlightHue: Double {
        didSet { highlightHue = Self.clamp(highlightHue, 0, 360) }
    }
    public var highlightSaturation: Double {
        didSet { highlightSaturation = Self.clamp(highlightSaturation, 0, 100) }
    }
    /// Negative biases toward shadows, positive toward highlights.
    public var balance: Double {
        didSet { balance = Self.clamp(balance, -100, 100) }
    }

    public init(
        shadowHue: Double = 0, shadowSaturation: Double = 0,
        highlightHue: Double = 0, highlightSaturation: Double = 0,
        balance: Double = 0
    ) {
        self.shadowHue = Self.clamp(shadowHue, 0, 360)
        self.shadowSaturation = Self.clamp(shadowSaturation, 0, 100)
        self.highlightHue = Self.clamp(highlightHue, 0, 360)
        self.highlightSaturation = Self.clamp(highlightSaturation, 0, 100)
        self.balance = Self.clamp(balance, -100, 100)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, low), high)
    }

    public static let neutral = SplitToning()

    /// Hue/balance are meaningless once both saturations are zero, so identity
    /// only checks saturation (spec §3.3).
    public var isIdentity: Bool { shadowSaturation == 0 && highlightSaturation == 0 }

    private enum CodingKeys: String, CodingKey {
        case shadowHue, shadowSaturation, highlightHue, highlightSaturation, balance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ low: Double, _ high: Double) throws -> Double {
            Self.clamp(try container.decodeIfPresent(Double.self, forKey: key) ?? 0, low, high)
        }
        self.shadowHue = try value(.shadowHue, 0, 360)
        self.shadowSaturation = try value(.shadowSaturation, 0, 100)
        self.highlightHue = try value(.highlightHue, 0, 360)
        self.highlightSaturation = try value(.highlightSaturation, 0, 100)
        self.balance = try value(.balance, -100, 100)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shadowHue, forKey: .shadowHue)
        try container.encode(shadowSaturation, forKey: .shadowSaturation)
        try container.encode(highlightHue, forKey: .highlightHue)
        try container.encode(highlightSaturation, forKey: .highlightSaturation)
        try container.encode(balance, forKey: .balance)
    }
}
