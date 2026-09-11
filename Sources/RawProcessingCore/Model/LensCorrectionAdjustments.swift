import Foundation

/// Design spec §6.4. `.automatic` delegates to `CIRAWFilter`'s own vendor
/// lens correction at decode time; `.manual` and `.bundledProfile` run a
/// post-decode geometric correction pass (see `AdjustmentPipeline`'s
/// `applyLensCorrection` and `docs/coordination/DECISIONS.md` D-007 for why
/// that pass cannot run strictly before white balance the way design spec §8
/// step 2 idealizes). Exactly one of these is ever active at a time -- never
/// both a decoder-level and a manual correction (§6.4: "不得同時套用").
public enum LensCorrectionMode: String, Codable, Sendable {
    case off, automatic, manual, bundledProfile

    /// Codable via `RawRepresentable` already fails closed to `nil` for an
    /// unrecognised raw value; `LensCorrectionAdjustments`'s own decoder maps
    /// that `nil` to `.off` rather than throwing and losing the whole photo's
    /// adjustments.
}

public struct LensCorrectionAdjustments: Codable, Equatable, Hashable, Sendable {
    public var mode: LensCorrectionMode
    /// `.bundledProfile` mode only.
    public var profileID: String?
    public var distortionAmount: Double {
        didSet { distortionAmount = Self.clamp(distortionAmount) }
    }
    public var vignettingAmount: Double {
        didSet { vignettingAmount = Self.clamp(vignettingAmount) }
    }
    public var tcaAmount: Double {
        didSet { tcaAmount = Self.clamp(tcaAmount) }
    }

    public init(
        mode: LensCorrectionMode = .off,
        profileID: String? = nil,
        distortionAmount: Double = 0,
        vignettingAmount: Double = 0,
        tcaAmount: Double = 0
    ) {
        self.mode = mode
        self.profileID = profileID
        self.distortionAmount = Self.clamp(distortionAmount)
        self.vignettingAmount = Self.clamp(vignettingAmount)
        self.tcaAmount = Self.clamp(tcaAmount)
    }

    public static let neutral = LensCorrectionAdjustments()

    /// Any mode other than `.off` is a real, non-neutral choice -- even
    /// `.automatic` (which has no local amounts to be zero) delegates to the
    /// decoder's own correction, and `.manual`/`.bundledProfile` with all
    /// amounts still at zero is still "the user turned this on".
    public var isIdentity: Bool { mode == .off }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, -100), 100)
    }

    private enum CodingKeys: String, CodingKey { case mode, profileID, distortionAmount, vignettingAmount, tcaAmount }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawMode = try container.decodeIfPresent(String.self, forKey: .mode)
        self.mode = rawMode.flatMap(LensCorrectionMode.init(rawValue:)) ?? .off
        self.profileID = try container.decodeIfPresent(String.self, forKey: .profileID)
        self.distortionAmount = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .distortionAmount) ?? 0)
        self.vignettingAmount = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .vignettingAmount) ?? 0)
        self.tcaAmount = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .tcaAmount) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(profileID, forKey: .profileID)
        try container.encode(distortionAmount, forKey: .distortionAmount)
        try container.encode(vignettingAmount, forKey: .vignettingAmount)
        try container.encode(tcaAmount, forKey: .tcaAmount)
    }
}

extension LensCorrectionAdjustments {
    /// Whether `CoreImageRawDecoder` should set `CIRAWFilter.isLensCorrectionEnabled`,
    /// and to what value, for this mode -- pure mapping logic kept separate
    /// from the actual `CIRAWFilter` side effect so it can be unit tested
    /// without a real RAW file (design spec §6.4: exactly one correction path
    /// is ever active, never both a decoder-level and a manual/profile one).
    /// `.automatic` still needs `CIRAWFilter.isLensCorrectionSupported`
    /// checked by the caller before acting on `true` -- this property can't
    /// know that without a live filter instance.
    public var decoderShouldEnableLensCorrection: Bool {
        mode == .automatic
    }
}

/// Matching engine for bundled, Lensfun-derived lens correction profiles
/// (design spec §6.4 item 3, §17). Ships with zero bundled profiles (see the
/// P4 spec's §1 item 1) -- a real Lensfun database is external, licensed
/// (CC BY-SA 3.0) data this environment cannot fetch or fabricate. `match`
/// always returning `nil` today is the correct, honest "no matching profile"
/// fallback (design spec §6.4 item 4), not a placeholder bug: a future task
/// that adds real profile data only needs to populate the backing table this
/// type reads from, not change this matching contract.
public enum LensProfileDatabase {
    public static func match(
        cameraMake: String,
        cameraModel: String,
        lensModel: String,
        focalLengthMM: Double,
        aperture: Double
    ) -> LensCorrectionAdjustments? {
        nil
    }
}
