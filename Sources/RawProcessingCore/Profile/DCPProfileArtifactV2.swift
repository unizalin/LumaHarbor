import Foundation

/// Atomic Gate 2 admission unit. A coefficient payload and its runtime
/// binding must travel together; a resolver must never pair a fallback with a
/// different manifest by matching IDs independently.
public struct DCPProfileArtifactV2: Codable, Equatable, Hashable, Sendable {
    public static let schemaVersion = 2

    public let fallback: CameraProfileFallback
    public let manifest: ProfileCalibrationArtifactManifest

    public enum ValidationError: Error, Equatable, Sendable {
        case unsupportedSchemaVersion
        case invalidManifest
    }

    public init(
        fallback: CameraProfileFallback,
        manifest: ProfileCalibrationArtifactManifest
    ) throws {
        self.fallback = fallback
        self.manifest = manifest
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case fallback
        case manifest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else {
            throw ValidationError.unsupportedSchemaVersion
        }
        self.fallback = try container.decode(CameraProfileFallback.self, forKey: .fallback)
        self.manifest = try container.decode(ProfileCalibrationArtifactManifest.self, forKey: .manifest)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(fallback, forKey: .fallback)
        try container.encode(manifest, forKey: .manifest)
    }

    public func validate() throws {
        guard manifest.policy == .adobeProcess2012V1 else {
            throw ValidationError.invalidManifest
        }
        do {
            try manifest.validate(fallback: fallback)
        } catch {
            throw ValidationError.invalidManifest
        }
    }

    public func validateRuntimeBinding(
        decoderIdentifier: DecoderIdentifier,
        decoderOptionVectorID: String,
        workingColorSpaceID: String,
        outputTransformID: String
    ) throws {
        do {
            try manifest.validateRuntimeBinding(
                fallback: fallback,
                decoderIdentifier: decoderIdentifier,
                decoderOptionVectorID: decoderOptionVectorID,
                workingColorSpaceID: workingColorSpaceID,
                outputTransformID: outputTransformID
            )
        } catch {
            throw ValidationError.invalidManifest
        }
    }
}
