import Foundation

/// One of the eight Lightroom-style hue bands (spec §3.2).
public struct HSLBand: Codable, Equatable, Hashable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var luminance: Double

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = Self.clamp(hue)
        self.saturation = Self.clamp(saturation)
        self.luminance = Self.clamp(luminance)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, -100), 100)
    }

    private enum CodingKeys: String, CodingKey { case hue, saturation, luminance }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hue = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .hue) ?? 0)
        self.saturation = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0)
        self.luminance = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .luminance) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hue, forKey: .hue)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(luminance, forKey: .luminance)
    }
}

/// Eight-band hue/saturation/luminance, matching Lightroom's HSL panel
/// one-for-one so a future XMP importer needs no colour-space guesswork
/// (spec §3.2).
public struct HSLAdjustments: Codable, Equatable, Hashable, Sendable {
    public var red: HSLBand
    public var orange: HSLBand
    public var yellow: HSLBand
    public var green: HSLBand
    public var aqua: HSLBand
    public var blue: HSLBand
    public var purple: HSLBand
    public var magenta: HSLBand

    public init(
        red: HSLBand = HSLBand(), orange: HSLBand = HSLBand(), yellow: HSLBand = HSLBand(),
        green: HSLBand = HSLBand(), aqua: HSLBand = HSLBand(), blue: HSLBand = HSLBand(),
        purple: HSLBand = HSLBand(), magenta: HSLBand = HSLBand()
    ) {
        self.red = red; self.orange = orange; self.yellow = yellow; self.green = green
        self.aqua = aqua; self.blue = blue; self.purple = purple; self.magenta = magenta
    }

    public static let neutral = HSLAdjustments()

    public var isIdentity: Bool { self == .neutral }

    private enum CodingKeys: String, CodingKey {
        case red, orange, yellow, green, aqua, blue, purple, magenta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func band(_ key: CodingKeys) throws -> HSLBand {
            try container.decodeIfPresent(HSLBand.self, forKey: key) ?? HSLBand()
        }
        self.red = try band(.red); self.orange = try band(.orange)
        self.yellow = try band(.yellow); self.green = try band(.green)
        self.aqua = try band(.aqua); self.blue = try band(.blue)
        self.purple = try band(.purple); self.magenta = try band(.magenta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(red, forKey: .red); try container.encode(orange, forKey: .orange)
        try container.encode(yellow, forKey: .yellow); try container.encode(green, forKey: .green)
        try container.encode(aqua, forKey: .aqua); try container.encode(blue, forKey: .blue)
        try container.encode(purple, forKey: .purple); try container.encode(magenta, forKey: .magenta)
    }
}
