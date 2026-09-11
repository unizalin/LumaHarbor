import Foundation

/// Black & White mixer: 8 hue-band weights recombined into a single
/// luminance output when enabled (P4, design spec §6.3). Colour adjustments
/// (HSL, Color Grading, etc.) are preserved and unaffected while disabled --
/// `isIdentity` reflects that by depending only on `isEnabled`.
public struct MonochromeAdjustments: Codable, Equatable, Hashable, Sendable {
    public var isEnabled: Bool
    public var red: Double { didSet { red = Self.clamp(red) } }
    public var orange: Double { didSet { orange = Self.clamp(orange) } }
    public var yellow: Double { didSet { yellow = Self.clamp(yellow) } }
    public var green: Double { didSet { green = Self.clamp(green) } }
    public var aqua: Double { didSet { aqua = Self.clamp(aqua) } }
    public var blue: Double { didSet { blue = Self.clamp(blue) } }
    public var purple: Double { didSet { purple = Self.clamp(purple) } }
    public var magenta: Double { didSet { magenta = Self.clamp(magenta) } }

    public init(
        isEnabled: Bool = false,
        red: Double = 0, orange: Double = 0, yellow: Double = 0, green: Double = 0,
        aqua: Double = 0, blue: Double = 0, purple: Double = 0, magenta: Double = 0
    ) {
        self.isEnabled = isEnabled
        self.red = Self.clamp(red)
        self.orange = Self.clamp(orange)
        self.yellow = Self.clamp(yellow)
        self.green = Self.clamp(green)
        self.aqua = Self.clamp(aqua)
        self.blue = Self.clamp(blue)
        self.purple = Self.clamp(purple)
        self.magenta = Self.clamp(magenta)
    }

    public static let neutral = MonochromeAdjustments()

    public var isIdentity: Bool { !isEnabled }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, -100), 100)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, red, orange, yellow, green, aqua, blue, purple, magenta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) throws -> Double {
            Self.clamp(try container.decodeIfPresent(Double.self, forKey: key) ?? 0)
        }
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.red = try value(.red)
        self.orange = try value(.orange)
        self.yellow = try value(.yellow)
        self.green = try value(.green)
        self.aqua = try value(.aqua)
        self.blue = try value(.blue)
        self.purple = try value(.purple)
        self.magenta = try value(.magenta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(red, forKey: .red)
        try container.encode(orange, forKey: .orange)
        try container.encode(yellow, forKey: .yellow)
        try container.encode(green, forKey: .green)
        try container.encode(aqua, forKey: .aqua)
        try container.encode(blue, forKey: .blue)
        try container.encode(purple, forKey: .purple)
        try container.encode(magenta, forKey: .magenta)
    }
}
