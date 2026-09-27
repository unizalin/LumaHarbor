import Foundation

/// Admission metadata for one camera/profile-scoped Adobe-compatible artifact.
///
/// The manifest is deliberately separate from the coefficient payload. It is
/// the auditable contract that binds a fallback to one camera, one canonical
/// profile name, one renderer policy and one versioned color pipeline.
public struct ProfileCalibrationArtifactManifest: Codable, Equatable, Hashable, Sendable {
    public let policy: RawRenderingCompatibility
    public let cameraMatch: CameraMatch
    public let canonicalProfileName: String
    public let artifactID: String
    public let artifactVersion: Int
    public let decoderOptionVectorID: String
    public let workingColorSpaceID: String
    public let outputTransformID: String
    public let provenance: String
    public let decoderIdentifier: DecoderIdentifier
    public let coefficientDigest: String
    public let provenanceSchemaVersion: Int

    public init(
        policy: RawRenderingCompatibility,
        cameraMatch: CameraMatch,
        canonicalProfileName: String,
        artifactID: String,
        artifactVersion: Int,
        decoderOptionVectorID: String,
        workingColorSpaceID: String,
        outputTransformID: String,
        provenance: String,
        decoderIdentifier: DecoderIdentifier = DecoderIdentifier(kind: "coreImage", version: "system-default"),
        coefficientDigest: String = "",
        provenanceSchemaVersion: Int = 1
    ) {
        self.policy = policy
        self.cameraMatch = cameraMatch
        self.canonicalProfileName = canonicalProfileName
        self.artifactID = artifactID
        self.artifactVersion = artifactVersion
        self.decoderOptionVectorID = decoderOptionVectorID
        self.workingColorSpaceID = workingColorSpaceID
        self.outputTransformID = outputTransformID
        self.provenance = provenance
        self.decoderIdentifier = decoderIdentifier
        self.coefficientDigest = coefficientDigest
        self.provenanceSchemaVersion = provenanceSchemaVersion
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case unsupportedPolicy
        case emptyProfileName
        case emptyArtifactID
        case invalidVersion
        case emptyDecoderOptionVectorID
        case emptyWorkingColorSpaceID
        case emptyOutputTransformID
        case emptyProvenance
        case emptyCoefficientDigest
        case invalidProvenanceSchemaVersion
        case fallbackMismatch
        case runtimeBindingMismatch
    }

    /// Validates both the manifest and the generated coefficient payload before
    /// a resolver is allowed to select the Adobe renderer.
    public func validate(fallback: CameraProfileFallback) throws {
        guard policy == .adobeProcess2012V1 else { throw ValidationError.unsupportedPolicy }
        guard !canonicalProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyProfileName
        }
        guard !artifactID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyArtifactID
        }
        guard artifactVersion > 0 else { throw ValidationError.invalidVersion }
        guard !decoderOptionVectorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyDecoderOptionVectorID
        }
        guard !workingColorSpaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyWorkingColorSpaceID
        }
        guard !outputTransformID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyOutputTransformID
        }
        guard !provenance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyProvenance
        }
        guard !coefficientDigest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyCoefficientDigest
        }
        guard provenanceSchemaVersion > 0 else {
            throw ValidationError.invalidProvenanceSchemaVersion
        }
        try fallback.validate()
        guard fallback.id == artifactID,
              fallback.version == artifactVersion,
              fallback.cameraMatch == cameraMatch,
              fallback.sourceProfileName == canonicalProfileName,
              fallback.coefficientDigest == coefficientDigest else {
            throw ValidationError.fallbackMismatch
        }
    }

    public func validateRuntimeBinding(
        fallback: CameraProfileFallback,
        decoderIdentifier: DecoderIdentifier,
        decoderOptionVectorID: String,
        workingColorSpaceID: String,
        outputTransformID: String
    ) throws {
        try validate(fallback: fallback)
        guard self.decoderIdentifier == decoderIdentifier,
              self.decoderOptionVectorID == decoderOptionVectorID,
              self.workingColorSpaceID == workingColorSpaceID,
              self.outputTransformID == outputTransformID else {
            throw ValidationError.runtimeBindingMismatch
        }
    }
}
