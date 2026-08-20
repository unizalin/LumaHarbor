import Foundation

/// Luminance and colour noise reduction (spec §3.5).
public struct NoiseReduction: Codable, Equatable, Hashable, Sendable {
    public var luminanceAmount: Double {
        didSet { luminanceAmount = Self.clamp(luminanceAmount) }
    }
    public var luminanceDetail: Double {
        didSet { luminanceDetail = Self.clamp(luminanceDetail) }
    }
    public var colorAmount: Double {
        didSet { colorAmount = Self.clamp(colorAmount) }
    }
    public var colorDetail: Double {
        didSet { colorDetail = Self.clamp(colorDetail) }
    }

    public init(
        luminanceAmount: Double = 0, luminanceDetail: Double = 50,
        colorAmount: Double = 0, colorDetail: Double = 50
    ) {
        self.luminanceAmount = Self.clamp(luminanceAmount)
        self.luminanceDetail = Self.clamp(luminanceDetail)
        self.colorAmount = Self.clamp(colorAmount)
        self.colorDetail = Self.clamp(colorDetail)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, 0), 100)
    }

    public static let neutral = NoiseReduction()

    public var isIdentity: Bool { luminanceAmount == 0 && colorAmount == 0 }

    private enum CodingKeys: String, CodingKey {
        case luminanceAmount, luminanceDetail, colorAmount, colorDetail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.luminanceAmount = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .luminanceAmount) ?? 0)
        self.luminanceDetail = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .luminanceDetail) ?? 50)
        self.colorAmount = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .colorAmount) ?? 0)
        self.colorDetail = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .colorDetail) ?? 50)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(luminanceAmount, forKey: .luminanceAmount)
        try container.encode(luminanceDetail, forKey: .luminanceDetail)
        try container.encode(colorAmount, forKey: .colorAmount)
        try container.encode(colorDetail, forKey: .colorDetail)
    }
}
