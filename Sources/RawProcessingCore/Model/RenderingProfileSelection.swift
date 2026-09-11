import Foundation

/// Selects a built-in, versioned creative rendering style (design spec §6.3).
/// Unlike Adobe's `crs:CameraProfile`, which references an external DCP file
/// this app cannot reproduce, `profileID` only ever names one of
/// `RenderingProfileCatalog`'s bundled entries.
public struct RenderingProfileSelection: Codable, Equatable, Hashable, Sendable {
    public var profileID: String?
    public var amount: Double {
        didSet { amount = Self.clamp(amount) }
    }
    /// Set by the caller (UI or preset apply) when `profileID` no longer
    /// resolves to a known built-in profile -- never guessed by the renderer.
    public var fallbackReason: String?

    public init(profileID: String? = nil, amount: Double = 100, fallbackReason: String? = nil) {
        self.profileID = profileID
        self.amount = Self.clamp(amount)
        self.fallbackReason = fallbackReason
    }

    public static let neutral = RenderingProfileSelection()

    public var isIdentity: Bool { profileID == nil }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, 0), 100)
    }

    private enum CodingKeys: String, CodingKey { case profileID, amount, fallbackReason }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.profileID = try container.decodeIfPresent(String.self, forKey: .profileID)
        self.amount = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .amount) ?? 100)
        self.fallbackReason = try container.decodeIfPresent(String.self, forKey: .fallbackReason)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(profileID, forKey: .profileID)
        try container.encode(amount, forKey: .amount)
        try container.encodeIfPresent(fallbackReason, forKey: .fallbackReason)
    }
}

/// The fixed set of built-in creative rendering styles (design spec §4). Each
/// profile is a small set of coefficients layered onto the existing
/// contrast/saturation/tone primitives -- not a new render mechanism.
public struct RenderingProfileCoefficients: Equatable, Sendable {
    public var saturationDelta: Double
    public var contrastDelta: Double
    public var shadowsDelta: Double
    public var highlightsDelta: Double

    public init(saturationDelta: Double = 0, contrastDelta: Double = 0, shadowsDelta: Double = 0, highlightsDelta: Double = 0) {
        self.saturationDelta = saturationDelta
        self.contrastDelta = contrastDelta
        self.shadowsDelta = shadowsDelta
        self.highlightsDelta = highlightsDelta
    }
}

public enum RenderingProfileCatalog {
    private static let table: [String: RenderingProfileCoefficients] = [
        "lumaharbor.standard": RenderingProfileCoefficients(),
        "lumaharbor.vivid": RenderingProfileCoefficients(saturationDelta: 20, contrastDelta: 10),
        "lumaharbor.flat": RenderingProfileCoefficients(contrastDelta: -20, shadowsDelta: 15, highlightsDelta: -15),
        "lumaharbor.portrait": RenderingProfileCoefficients(saturationDelta: -5, contrastDelta: -5)
    ]

    public static let allProfileIDs: [String] = Array(table.keys)

    /// `nil` for any `profileID` not in the bundled set -- never a guess.
    public static func coefficients(for profileID: String) -> RenderingProfileCoefficients? {
        table[profileID]
    }
}
