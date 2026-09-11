import Foundation

/// One 3-way-style colour wheel band (spec §6.3). Hue is meaningless at
/// saturation 0, same convention as `SplitToning`.
public struct ColorGradeBand: Codable, Equatable, Hashable, Sendable {
    public var hue: Double {
        didSet { hue = Self.clamp(hue, 0, 360) }
    }
    public var saturation: Double {
        didSet { saturation = Self.clamp(saturation, 0, 100) }
    }
    public var luminance: Double {
        didSet { luminance = Self.clamp(luminance, -100, 100) }
    }

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = Self.clamp(hue, 0, 360)
        self.saturation = Self.clamp(saturation, 0, 100)
        self.luminance = Self.clamp(luminance, -100, 100)
    }

    fileprivate static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, low), high)
    }

    private enum CodingKeys: String, CodingKey { case hue, saturation, luminance }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hue = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .hue) ?? 0, 0, 360)
        self.saturation = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0, 0, 100)
        self.luminance = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .luminance) ?? 0, -100, 100)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hue, forKey: .hue)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(luminance, forKey: .luminance)
    }
}

/// Shadows/Midtones/Highlights/Global colour grading, replacing the simpler
/// two-zone `SplitToning` with a three-zone model plus a `balance`/`blending`
/// pair controlling how the zones are split and transitioned (P4, design
/// spec §6.3).
public struct ColorGradingAdjustments: Codable, Equatable, Hashable, Sendable {
    public var shadows: ColorGradeBand
    public var midtones: ColorGradeBand
    public var highlights: ColorGradeBand
    public var global: ColorGradeBand
    /// Negative biases the split toward shadows, positive toward highlights
    /// -- same convention as `SplitToning.balance`.
    public var balance: Double {
        didSet { balance = ColorGradeBand.clamp(balance, -100, 100) }
    }
    /// How smoothly the shadow/midtone/highlight zones blend into each
    /// other. 0 = sharp cutoff, 100 = maximally smooth.
    public var blending: Double {
        didSet { blending = ColorGradeBand.clamp(blending, 0, 100) }
    }

    public init(
        shadows: ColorGradeBand = ColorGradeBand(),
        midtones: ColorGradeBand = ColorGradeBand(),
        highlights: ColorGradeBand = ColorGradeBand(),
        global: ColorGradeBand = ColorGradeBand(),
        balance: Double = 0,
        blending: Double = 50
    ) {
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
        self.global = global
        self.balance = ColorGradeBand.clamp(balance, -100, 100)
        self.blending = ColorGradeBand.clamp(blending, 0, 100)
    }

    public static let neutral = ColorGradingAdjustments()

    public var isIdentity: Bool {
        shadows.saturation == 0 && midtones.saturation == 0
            && highlights.saturation == 0 && global.saturation == 0
    }

    private enum CodingKeys: String, CodingKey { case shadows, midtones, highlights, global, balance, blending }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.shadows = try container.decodeIfPresent(ColorGradeBand.self, forKey: .shadows) ?? ColorGradeBand()
        self.midtones = try container.decodeIfPresent(ColorGradeBand.self, forKey: .midtones) ?? ColorGradeBand()
        self.highlights = try container.decodeIfPresent(ColorGradeBand.self, forKey: .highlights) ?? ColorGradeBand()
        self.global = try container.decodeIfPresent(ColorGradeBand.self, forKey: .global) ?? ColorGradeBand()
        self.balance = ColorGradeBand.clamp(try container.decodeIfPresent(Double.self, forKey: .balance) ?? 0, -100, 100)
        self.blending = ColorGradeBand.clamp(try container.decodeIfPresent(Double.self, forKey: .blending) ?? 50, 0, 100)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shadows, forKey: .shadows)
        try container.encode(midtones, forKey: .midtones)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(global, forKey: .global)
        try container.encode(balance, forKey: .balance)
        try container.encode(blending, forKey: .blending)
    }
}
