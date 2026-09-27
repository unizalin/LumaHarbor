import Foundation

/// A camera profile requested by an imported preset. The name is kept as a
/// plain value so the recipe remains portable even when this build cannot
/// apply the Adobe profile itself.
public struct RawCameraProfileRequest: Codable, Equatable, Hashable, Sendable {
    public var sourceName: String?
    public var cameraMake: String?
    public var cameraModel: String?

    public init(
        sourceName: String? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil
    ) {
        self.sourceName = sourceName
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
    }
}

public enum RawRenderDiagnosticCode: String, Codable, Equatable, Hashable, Sendable {
    case rendererNotCalibrated
    case recipeResolutionFallback
    case rawDecoderVersionFallback
    case rawOptionUnavailable
    case metadataFallback
}

public struct RawRenderDiagnostic: Codable, Equatable, Hashable, Sendable {
    public let code: RawRenderDiagnosticCode
    public let detail: String?

    public init(code: RawRenderDiagnosticCode, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }
}

public struct RawRendererFeatureFlags: Codable, Equatable, Hashable, Sendable {
    public var adobeProcess2012V1Enabled: Bool

    /// Gate 2 owns the Adobe-compatible renderer. Until that gate is passed,
    /// every default render must remain on the native pipeline even when an
    /// imported sidecar asks for Lightroom/Adobe Process 2012.
    public init(adobeProcess2012V1Enabled: Bool = false) {
        self.adobeProcess2012V1Enabled = adobeProcess2012V1Enabled
    }
}

public struct RawDecoderCapabilities: Codable, Equatable, Hashable, Sendable {
    public var decoderIdentifier: DecoderIdentifier
    public var supportsAutomaticLensCorrection: Bool
    public var supportsAdobeProcess2012V1: Bool

    public init(
        decoderIdentifier: DecoderIdentifier = DecoderIdentifier(kind: "coreImage", version: "system-default"),
        supportsAutomaticLensCorrection: Bool = true,
        supportsAdobeProcess2012V1: Bool = true
    ) {
        self.decoderIdentifier = decoderIdentifier
        self.supportsAutomaticLensCorrection = supportsAutomaticLensCorrection
        self.supportsAdobeProcess2012V1 = supportsAdobeProcess2012V1
    }
}

public struct RawDecoderRecipe: Codable, Equatable, Hashable, Sendable {
    public let decoderIdentifier: DecoderIdentifier
    public let maximumPixelDimension: Int?
    public let draftModeEnabled: Bool

    public init(
        decoderIdentifier: DecoderIdentifier,
        maximumPixelDimension: Int?,
        draftModeEnabled: Bool
    ) {
        self.decoderIdentifier = decoderIdentifier
        self.maximumPixelDimension = maximumPixelDimension
        self.draftModeEnabled = draftModeEnabled
    }
}

public struct RawWhiteBalanceRecipe: Codable, Equatable, Hashable, Sendable {
    public let temperatureOffsetKelvin: Double
    public let tintOffset: Double

    public init(temperatureOffsetKelvin: Double = 0, tintOffset: Double = 0) {
        self.temperatureOffsetKelvin = temperatureOffsetKelvin
        self.tintOffset = tintOffset
    }
}

public struct RawLensRecipe: Codable, Equatable, Hashable, Sendable {
    public let mode: LensCorrectionMode
    public let profileID: String?
    public let decoderEnabled: Bool

    public init(mode: LensCorrectionMode, profileID: String?, decoderEnabled: Bool) {
        self.mode = mode
        self.profileID = profileID
        self.decoderEnabled = decoderEnabled
    }
}

public struct ResolvedRawCameraProfile: Codable, Equatable, Hashable, Sendable {
    public let requestedName: String?
    public let appliedName: String?
    public let fallbackID: String?
    public let fallbackVersion: Int?
    public let compatibility: RawCameraProfileCompatibility?
    public let provenance: String?

    public init(
        requestedName: String? = nil,
        appliedName: String? = nil,
        fallbackID: String? = nil,
        fallbackVersion: Int? = nil,
        compatibility: RawCameraProfileCompatibility? = nil,
        provenance: String? = nil
    ) {
        self.requestedName = requestedName
        self.appliedName = appliedName
        self.fallbackID = fallbackID
        self.fallbackVersion = fallbackVersion
        self.compatibility = compatibility
        self.provenance = provenance
    }
}

public struct RawRenderRecipeInput: Codable, Equatable, Hashable, Sendable {
    public var policy: RawRenderingCompatibility
    public var quality: DecodeQuality
    public var whiteBalance: RawWhiteBalance
    public var lensCorrection: LensCorrectionAdjustments
    public var cameraProfileRequest: RawCameraProfileRequest?
    public var featureFlags: RawRendererFeatureFlags

    public init(
        policy: RawRenderingCompatibility = .native,
        quality: DecodeQuality = .full,
        whiteBalance: RawWhiteBalance = .asShot,
        lensCorrection: LensCorrectionAdjustments = .neutral,
        cameraProfileRequest: RawCameraProfileRequest? = nil,
        featureFlags: RawRendererFeatureFlags = RawRendererFeatureFlags()
    ) {
        self.policy = policy
        self.quality = quality
        self.whiteBalance = whiteBalance
        self.lensCorrection = lensCorrection
        self.cameraProfileRequest = cameraProfileRequest
        self.featureFlags = featureFlags
    }
}

public struct ResolvedRawRenderRecipe: Codable, Equatable, Hashable, Sendable {
    public let policy: RawRenderingCompatibility
    /// The policy persisted in the sidecar is intentionally separate from the
    /// policy that this build is allowed to execute. A disabled/unavailable
    /// Adobe renderer therefore remains observable without changing user data.
    public let effectivePolicy: RawRenderingCompatibility
    public let decoder: RawDecoderRecipe
    public let whiteBalance: RawWhiteBalanceRecipe
    public let lensCorrection: RawLensRecipe
    public let cameraProfile: ResolvedRawCameraProfile
    public let decoderOptionVectorID: String
    public let workingColorSpaceID: String
    public let outputTransformID: String
    public let diagnostics: [RawRenderDiagnostic]

    public init(
        policy: RawRenderingCompatibility,
        effectivePolicy: RawRenderingCompatibility? = nil,
        decoder: RawDecoderRecipe,
        whiteBalance: RawWhiteBalanceRecipe,
        lensCorrection: RawLensRecipe,
        cameraProfile: ResolvedRawCameraProfile,
        decoderOptionVectorID: String,
        workingColorSpaceID: String,
        outputTransformID: String,
        diagnostics: [RawRenderDiagnostic] = []
    ) {
        let requestedEffectivePolicy = effectivePolicy ?? (policy == .adobeProcess2012V1 ? .native : policy)
        let resolvedEffectivePolicy = policy == .adobeProcess2012V1
            ? requestedEffectivePolicy
            : .native
        self.policy = policy
        self.effectivePolicy = resolvedEffectivePolicy
        self.decoder = decoder
        self.whiteBalance = whiteBalance
        self.lensCorrection = lensCorrection
        self.cameraProfile = Self.canonicalCameraProfile(
            cameraProfile,
            effectivePolicy: resolvedEffectivePolicy
        )
        self.decoderOptionVectorID = Self.canonicalDecoderOptionVectorID(
            decoderOptionVectorID,
            decoder: decoder,
            effectivePolicy: resolvedEffectivePolicy
        )
        self.workingColorSpaceID = Self.canonicalWorkingColorSpaceID(
            workingColorSpaceID,
            effectivePolicy: resolvedEffectivePolicy
        )
        self.outputTransformID = Self.canonicalOutputTransformID(
            outputTransformID,
            effectivePolicy: resolvedEffectivePolicy
        )
        self.diagnostics = diagnostics
    }

    private static func canonicalDecoderOptionVectorID(
        _ existingID: String,
        decoder: RawDecoderRecipe,
        effectivePolicy: RawRenderingCompatibility
    ) -> String {
        guard effectivePolicy == .native else { return existingID }
        let qualityID = existingID.split(separator: "/").last.map(String.init) ?? "full"
        return "\(decoder.decoderIdentifier.kind)/native-v1/\(qualityID)"
    }

    private static func canonicalWorkingColorSpaceID(
        _ existingID: String,
        effectivePolicy: RawRenderingCompatibility
    ) -> String {
        guard effectivePolicy == .native else { return existingID }
        return RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue
    }

    private static func canonicalOutputTransformID(
        _ existingID: String,
        effectivePolicy: RawRenderingCompatibility
    ) -> String {
        guard effectivePolicy == .native else { return existingID }
        if RawOutputTransformID(rawValue: existingID) == .referenceTIFFSRGB16V1 {
            return RawOutputTransformID.referenceTIFFSRGB16V1.rawValue
        }
        return RawOutputTransformID.displaySRGBV1.rawValue
    }

    private static func canonicalCameraProfile(
        _ profile: ResolvedRawCameraProfile,
        effectivePolicy: RawRenderingCompatibility
    ) -> ResolvedRawCameraProfile {
        guard effectivePolicy == .native else { return profile }
        guard let requestedName = profile.requestedName else {
            return ResolvedRawCameraProfile()
        }
        return ResolvedRawCameraProfile(
            requestedName: requestedName,
            compatibility: .preservedNotApplied,
            provenance: profile.provenance ?? "Adobe renderer disabled until Gate 2"
        )
    }

    private enum CodingKeys: String, CodingKey {
        case policy
        case effectivePolicy
        case decoder
        case whiteBalance
        case lensCorrection
        case cameraProfile
        case decoderOptionVectorID
        case workingColorSpaceID
        case outputTransformID
        case diagnostics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let policy = try container.decode(RawRenderingCompatibility.self, forKey: .policy)
        // A serialized effective policy is not an authorization token. Adobe
        // recipes must be re-resolved against the current release gate and
        // admitted artifact after reopening; decoding alone always fails
        // closed to Native.
        self.init(
            policy: policy,
            effectivePolicy: .native,
            decoder: try container.decode(RawDecoderRecipe.self, forKey: .decoder),
            whiteBalance: try container.decode(RawWhiteBalanceRecipe.self, forKey: .whiteBalance),
            lensCorrection: try container.decode(RawLensRecipe.self, forKey: .lensCorrection),
            cameraProfile: try container.decode(ResolvedRawCameraProfile.self, forKey: .cameraProfile),
            decoderOptionVectorID: try container.decode(String.self, forKey: .decoderOptionVectorID),
            workingColorSpaceID: try container.decode(String.self, forKey: .workingColorSpaceID),
            outputTransformID: try container.decode(String.self, forKey: .outputTransformID),
            diagnostics: try container.decodeIfPresent([RawRenderDiagnostic].self, forKey: .diagnostics) ?? []
        )
    }

    public func addingDiagnostics(_ additional: [RawRenderDiagnostic]) -> Self {
        guard !additional.isEmpty else { return self }
        var merged = diagnostics
        for diagnostic in additional where !merged.contains(diagnostic) {
            merged.append(diagnostic)
        }
        return Self(
            policy: policy,
            effectivePolicy: effectivePolicy,
            decoder: decoder,
            whiteBalance: whiteBalance,
            lensCorrection: lensCorrection,
            cameraProfile: cameraProfile,
            decoderOptionVectorID: decoderOptionVectorID,
            workingColorSpaceID: workingColorSpaceID,
            outputTransformID: outputTransformID,
            diagnostics: merged
        )
    }

    public func replacingOutputTransform(_ outputTransformID: String) -> Self {
        Self(
            policy: policy,
            effectivePolicy: effectivePolicy,
            decoder: decoder,
            whiteBalance: whiteBalance,
            lensCorrection: lensCorrection,
            cameraProfile: cameraProfile,
            decoderOptionVectorID: decoderOptionVectorID,
            workingColorSpaceID: workingColorSpaceID,
            outputTransformID: outputTransformID,
            diagnostics: diagnostics
        )
    }

    /// Reverts only the executable renderer decision while preserving the
    /// persisted policy and all user adjustment values.
    public func replacingEffectivePolicy(_ effectivePolicy: RawRenderingCompatibility) -> Self {
        let optionVectorID = CoreImageRawPolicy.optionVector(for: effectivePolicy)?.id
            ?? "native-v1"
        let qualityID = decoderOptionVectorID.split(separator: "/").last.map(String.init) ?? "full"
        let workingColorSpaceID = effectivePolicy == .adobeProcess2012V1
            ? RawWorkingColorSpaceID.adobeCompatibleLinearWideGamutV1.rawValue
            : RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue
        return Self(
            policy: policy,
            effectivePolicy: effectivePolicy,
            decoder: decoder,
            whiteBalance: whiteBalance,
            lensCorrection: lensCorrection,
            cameraProfile: cameraProfile,
            decoderOptionVectorID: "\(decoder.decoderIdentifier.kind)/\(optionVectorID)/\(qualityID)",
            workingColorSpaceID: workingColorSpaceID,
            outputTransformID: outputTransformID,
            diagnostics: diagnostics
        )
    }

    public func replacingCameraProfile(_ cameraProfile: ResolvedRawCameraProfile) -> Self {
        Self(
            policy: policy,
            effectivePolicy: effectivePolicy,
            decoder: decoder,
            whiteBalance: whiteBalance,
            lensCorrection: lensCorrection,
            cameraProfile: cameraProfile,
            decoderOptionVectorID: decoderOptionVectorID,
            workingColorSpaceID: workingColorSpaceID,
            outputTransformID: outputTransformID,
            diagnostics: diagnostics
        )
    }
}

public protocol RawRenderRecipeResolving: Sendable {
    func resolve(
        _ input: RawRenderRecipeInput,
        capabilities: RawDecoderCapabilities
    ) -> ResolvedRawRenderRecipe
}
