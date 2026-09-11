import Foundation

/// Texture, Clarity, and Dehaze -- local/mid-frequency contrast tools distinct
/// from the global `contrast` slider (P4, design spec §6.3).
public struct PresenceAdjustments: Codable, Equatable, Hashable, Sendable {
    public var texture: Double {
        didSet { texture = Self.clamp(texture) }
    }
    public var clarity: Double {
        didSet { clarity = Self.clamp(clarity) }
    }
    public var dehaze: Double {
        didSet { dehaze = Self.clamp(dehaze) }
    }

    public init(texture: Double = 0, clarity: Double = 0, dehaze: Double = 0) {
        self.texture = Self.clamp(texture)
        self.clarity = Self.clamp(clarity)
        self.dehaze = Self.clamp(dehaze)
    }

    public static let neutral = PresenceAdjustments()

    public var isIdentity: Bool { texture == 0 && clarity == 0 && dehaze == 0 }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, -100), 100)
    }

    private enum CodingKeys: String, CodingKey { case texture, clarity, dehaze }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.texture = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .texture) ?? 0)
        self.clarity = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .clarity) ?? 0)
        self.dehaze = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .dehaze) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(texture, forKey: .texture)
        try container.encode(clarity, forKey: .clarity)
        try container.encode(dehaze, forKey: .dehaze)
    }
}
