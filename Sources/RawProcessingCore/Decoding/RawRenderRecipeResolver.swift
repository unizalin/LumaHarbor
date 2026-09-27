import Foundation

/// Resolves persisted edit intent into an executable render recipe.
///
/// Adobe Process 2012 remains a persisted compatibility marker, but the
/// executable policy is fail-closed until the calibrated Gate 2 renderer is
/// explicitly enabled and the decoder advertises support.
public struct RawRenderRecipeResolver: RawRenderRecipeResolving {
    private let cameraProfileFallbacks: [CameraProfileFallback]
    private let artifactManifests: [ProfileCalibrationArtifactManifest]
    private let admittedArtifacts: [DCPProfileArtifactV2]

    public init() {
        self.init(
            cameraProfileFallbacks: AdobeCompatibleProfileFallbacksV1.all,
            artifactManifests: ProfileCalibrationArtifactManifestsV1.all,
            admittedArtifacts: []
        )
    }

    public init(
        cameraProfileFallbacks: [CameraProfileFallback],
        artifactManifests: [ProfileCalibrationArtifactManifest]
    ) {
        self.init(
            cameraProfileFallbacks: cameraProfileFallbacks,
            artifactManifests: artifactManifests,
            admittedArtifacts: []
        )
    }

    public init(admittedArtifacts: [DCPProfileArtifactV2]) {
        self.init(
            cameraProfileFallbacks: [],
            artifactManifests: [],
            admittedArtifacts: admittedArtifacts
        )
    }

    private init(
        cameraProfileFallbacks: [CameraProfileFallback],
        artifactManifests: [ProfileCalibrationArtifactManifest],
        admittedArtifacts: [DCPProfileArtifactV2]
    ) {
        self.cameraProfileFallbacks = cameraProfileFallbacks
        self.artifactManifests = artifactManifests
        self.admittedArtifacts = admittedArtifacts
    }

    public func resolve(
        _ input: RawRenderRecipeInput,
        capabilities: RawDecoderCapabilities
    ) -> ResolvedRawRenderRecipe {
        let adobeRequested = input.policy == .adobeProcess2012V1
        let artifactIsAdmitted = admittedArtifact(
            for: input.cameraProfileRequest,
            decoderIdentifier: capabilities.decoderIdentifier,
            decoderOptionVectorID: CoreImageRawPolicy.optionVector(for: .adobeProcess2012V1)?.id
                ?? "adobe-process-2012-v1-preserve-defaults-v1",
            workingColorSpaceID: RawWorkingColorSpaceID.adobeCompatibleLinearWideGamutV1.rawValue,
            outputTransformID: RawOutputTransformID.displaySRGBV1.rawValue
        ) != nil
        let adobeEnabled = adobeRequested
            && input.featureFlags.adobeProcess2012V1Enabled
            && capabilities.supportsAdobeProcess2012V1
            && artifactIsAdmitted
        let effectivePolicy: RawRenderingCompatibility = adobeEnabled
            ? .adobeProcess2012V1
            : .native
        let decoderRecipe = RawDecoderRecipe(
            decoderIdentifier: capabilities.decoderIdentifier,
            maximumPixelDimension: input.quality.maximumPixelDimension,
            draftModeEnabled: input.quality.allowsDraftMode
        )
        let decoderLensEnabled = input.lensCorrection.decoderShouldEnableLensCorrection
            && capabilities.supportsAutomaticLensCorrection
        let lensRecipe = RawLensRecipe(
            mode: input.lensCorrection.mode,
            profileID: input.lensCorrection.profileID,
            decoderEnabled: decoderLensEnabled
        )
        let cameraProfile = Self.resolveCameraProfile(
            input.cameraProfileRequest,
            allowAdobeApplication: effectivePolicy == .adobeProcess2012V1,
            cameraProfileFallbacks: cameraProfileFallbacks,
            artifactManifests: artifactManifests,
            admittedArtifacts: admittedArtifacts,
            decoderIdentifier: capabilities.decoderIdentifier,
            decoderOptionVectorID: optionVectorID(for: effectivePolicy),
            workingColorSpaceID: workingColorSpaceID(for: effectivePolicy),
            outputTransformID: RawOutputTransformID.displaySRGBV1.rawValue
        )

        var diagnostics: [RawRenderDiagnostic] = []
        if adobeRequested, !adobeEnabled {
            diagnostics.append(RawRenderDiagnostic(code: .recipeResolutionFallback))
        }
        if input.cameraProfileRequest?.sourceName != nil, !adobeEnabled {
            diagnostics.append(RawRenderDiagnostic(code: .rendererNotCalibrated, detail: "cameraProfile"))
        }

        let policyID = effectivePolicy == .adobeProcess2012V1 ? "adobe-process-2012-v1" : "native-v1"
        let optionVectorID = CoreImageRawPolicy.optionVector(for: effectivePolicy)?.id ?? policyID
        let workingColorSpaceID = effectivePolicy == .adobeProcess2012V1
            ? RawWorkingColorSpaceID.adobeCompatibleLinearWideGamutV1.rawValue
            : RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue
        return ResolvedRawRenderRecipe(
            policy: input.policy,
            effectivePolicy: effectivePolicy,
            decoder: decoderRecipe,
            whiteBalance: RawWhiteBalanceRecipe(
                temperatureOffsetKelvin: input.whiteBalance.temperatureOffsetKelvin,
                tintOffset: input.whiteBalance.tintOffset
            ),
            lensCorrection: lensRecipe,
            cameraProfile: cameraProfile,
            decoderOptionVectorID: "\(capabilities.decoderIdentifier.kind)/\(optionVectorID)/\(input.quality.recipeID)",
            workingColorSpaceID: workingColorSpaceID,
            outputTransformID: RawOutputTransformID.displaySRGBV1.rawValue,
            diagnostics: diagnostics
        )
    }

    /// Re-resolves the camera profile after the decoder has read EXIF camera
    /// make/model. The first recipe is still deterministic before decode; this
    /// second pass is what prevents a Sony fallback being applied to an unknown
    /// camera when a sidecar only carries a profile name.
    public func resolvingCameraProfile(
        in recipe: ResolvedRawRenderRecipe,
        request: RawCameraProfileRequest,
        cameraMake: String?,
        cameraModel: String?
    ) -> ResolvedRawRenderRecipe {
        let enriched = RawCameraProfileRequest(
            sourceName: request.sourceName,
            cameraMake: cameraMake,
            cameraModel: cameraModel
        )
        let profile = Self.resolveCameraProfile(
            enriched,
            allowAdobeApplication: recipe.effectivePolicy == .adobeProcess2012V1,
            cameraProfileFallbacks: cameraProfileFallbacks,
            artifactManifests: artifactManifests,
            admittedArtifacts: admittedArtifacts,
            decoderIdentifier: recipe.decoder.decoderIdentifier,
            decoderOptionVectorID: recipe.decoderOptionVectorID.split(separator: "/").dropFirst().first.map(String.init)
                ?? recipe.decoderOptionVectorID,
            workingColorSpaceID: recipe.workingColorSpaceID,
            outputTransformID: recipe.outputTransformID
        )
        var updated = recipe.replacingCameraProfile(profile)
        if recipe.effectivePolicy == .adobeProcess2012V1,
           profile.compatibility != .approximate || profile.fallbackID == nil {
            updated = updated
                .replacingEffectivePolicy(.native)
                .replacingCameraProfile(profile)
                .addingDiagnostics([
                    RawRenderDiagnostic(code: .recipeResolutionFallback, detail: "cameraProfile")
                ])
        }
        if recipe.effectivePolicy == .native, request.sourceName != nil {
            updated = updated.addingDiagnostics([
                RawRenderDiagnostic(code: .recipeResolutionFallback, detail: "cameraProfile")
            ])
        }
        if request.sourceName != nil,
           profile.compatibility != .approximate || profile.fallbackID == nil {
            updated = updated.addingDiagnostics([
                RawRenderDiagnostic(code: .rendererNotCalibrated, detail: "cameraProfile")
            ])
        }
        return updated
    }

    private static func resolveCameraProfile(
        _ request: RawCameraProfileRequest?,
        allowAdobeApplication: Bool,
        cameraProfileFallbacks: [CameraProfileFallback],
        artifactManifests: [ProfileCalibrationArtifactManifest],
        admittedArtifacts: [DCPProfileArtifactV2],
        decoderIdentifier: DecoderIdentifier,
        decoderOptionVectorID: String,
        workingColorSpaceID: String,
        outputTransformID: String
    ) -> ResolvedRawCameraProfile {
        guard let request, let sourceName = request.sourceName else {
            return ResolvedRawCameraProfile()
        }
        guard allowAdobeApplication else {
            return ResolvedRawCameraProfile(
                requestedName: sourceName,
                compatibility: .preservedNotApplied,
                provenance: "Adobe renderer disabled until Gate 2"
            )
        }
        let selection = RawCameraProfileSelection(requestedName: sourceName)
        let descriptor = AdobeCompatibleProfileRegistry.descriptor(
            for: selection,
            cameraMake: request.cameraMake,
            cameraModel: request.cameraModel
        )
        guard let descriptor else {
            return ResolvedRawCameraProfile(requestedName: sourceName)
        }
        let atomicArtifact = admittedArtifacts.first { artifact in
            guard descriptor.compatibility == .approximate,
                  matchesScope(artifact.fallback, descriptor: descriptor) else {
                return false
            }
            return (try? artifact.validateRuntimeBinding(
                decoderIdentifier: decoderIdentifier,
                decoderOptionVectorID: decoderOptionVectorID,
                workingColorSpaceID: workingColorSpaceID,
                outputTransformID: outputTransformID
            )) != nil
        }
        let fallback = atomicArtifact?.fallback ?? (descriptor.compatibility == .approximate
            ? cameraProfileFallbacks.first(where: { matchesScope($0, descriptor: descriptor) })
            : nil)
        let manifest = atomicArtifact?.manifest ?? fallback.flatMap { fallback in
            artifactManifests.first {
                $0.artifactID == fallback.id && $0.artifactVersion == fallback.version
            }
        }
        let isAdmitted: Bool
        if let fallback, let manifest {
            isAdmitted = (try? manifest.validateRuntimeBinding(
                fallback: fallback,
                decoderIdentifier: decoderIdentifier,
                decoderOptionVectorID: decoderOptionVectorID,
                workingColorSpaceID: workingColorSpaceID,
                outputTransformID: outputTransformID
            )) != nil
        } else {
            isAdmitted = false
        }
        return ResolvedRawCameraProfile(
            requestedName: sourceName,
            appliedName: isAdmitted ? descriptor.sourceName : nil,
            fallbackID: isAdmitted ? fallback?.id : nil,
            fallbackVersion: isAdmitted ? fallback?.version : nil,
            compatibility: isAdmitted ? descriptor.compatibility : .preservedNotApplied,
            provenance: isAdmitted ? descriptor.provenance : "Artifact not admitted for Gate 2"
        )
    }

    private func admittedArtifact(
        for request: RawCameraProfileRequest?,
        decoderIdentifier: DecoderIdentifier,
        decoderOptionVectorID: String,
        workingColorSpaceID: String,
        outputTransformID: String
    ) ->
        (fallback: CameraProfileFallback, manifest: ProfileCalibrationArtifactManifest)? {
        guard let request,
              let sourceName = request.sourceName,
              let cameraMake = request.cameraMake,
              let cameraModel = request.cameraModel,
              let descriptor = AdobeCompatibleProfileRegistry.descriptor(
                  for: RawCameraProfileSelection(requestedName: sourceName),
                  cameraMake: cameraMake,
                  cameraModel: cameraModel
              ),
              descriptor.compatibility == .approximate else {
            return nil
        }
        if let artifact = admittedArtifacts.first(where: {
            Self.matchesScope($0.fallback, descriptor: descriptor)
                && (try? $0.validateRuntimeBinding(
                    decoderIdentifier: decoderIdentifier,
                    decoderOptionVectorID: decoderOptionVectorID,
                    workingColorSpaceID: workingColorSpaceID,
                    outputTransformID: outputTransformID
                )) != nil
        }) {
            return (artifact.fallback, artifact.manifest)
        }
        guard let fallback = cameraProfileFallbacks.first(where: { Self.matchesScope($0, descriptor: descriptor) }),
              let manifest = artifactManifests.first(where: {
                  $0.artifactID == fallback.id && $0.artifactVersion == fallback.version
              }),
              (try? manifest.validateRuntimeBinding(
                  fallback: fallback,
                  decoderIdentifier: decoderIdentifier,
                  decoderOptionVectorID: decoderOptionVectorID,
                  workingColorSpaceID: workingColorSpaceID,
                  outputTransformID: outputTransformID
              )) != nil else {
            return nil
        }
        return (fallback, manifest)
    }

    private static func matchesScope(
        _ fallback: CameraProfileFallback,
        descriptor: AdobeCompatibleProfileDescriptor
    ) -> Bool {
        fallback.id == descriptor.fallbackID
            && fallback.version == descriptor.fallbackVersion
            && fallback.cameraMatch == descriptor.cameraMatch
            && fallback.sourceProfileName == descriptor.sourceName
    }

    private func optionVectorID(for policy: RawRenderingCompatibility) -> String {
        CoreImageRawPolicy.optionVector(for: policy)?.id ?? "native-v1"
    }

    private func workingColorSpaceID(for policy: RawRenderingCompatibility) -> String {
        policy == .adobeProcess2012V1
            ? RawWorkingColorSpaceID.adobeCompatibleLinearWideGamutV1.rawValue
            : RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue
    }
}

private extension DecodeQuality {
    var recipeID: String {
        switch self {
        case .thumbnail(let dimension): return "thumbnail-\(dimension)"
        case .interactive(let dimension): return "interactive-\(dimension)"
        case .highQuality(let dimension): return "high-\(dimension)"
        case .full: return "full"
        }
    }
}
