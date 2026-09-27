import Foundation
import XCTest
@testable import RawProcessingCore

final class DCPProfileFailClosedTests: XCTestCase {
    func testV2ArtifactRoundTripsAsOneAtomicFallbackAndManifest() throws {
        let fallback = try makeFallback()
        let manifest = makeManifest(for: fallback)
        let artifact = try DCPProfileArtifactV2(fallback: fallback, manifest: manifest)

        let data = try JSONEncoder().encode(artifact)
        let reopened = try JSONDecoder().decode(DCPProfileArtifactV2.self, from: data)

        XCTAssertEqual(reopened, artifact)
        XCTAssertEqual(reopened.fallback.coefficientDigest, reopened.manifest.coefficientDigest)
    }

    func testV2ArtifactRejectsMismatchedFallbackAndManifest() throws {
        let fallback = try makeFallback()
        let manifest = ProfileCalibrationArtifactManifest(
            policy: .adobeProcess2012V1,
            cameraMatch: fallback.cameraMatch,
            canonicalProfileName: fallback.sourceProfileName,
            artifactID: fallback.id,
            artifactVersion: fallback.version,
            decoderOptionVectorID: adobeOptionVectorID,
            workingColorSpaceID: RawWorkingColorSpaceID.adobeCompatibleLinearWideGamutV1.rawValue,
            outputTransformID: RawOutputTransformID.displaySRGBV1.rawValue,
            provenance: fallback.provenance,
            coefficientDigest: "mismatched-synthetic-digest"
        )

        XCTAssertThrowsError(try DCPProfileArtifactV2(fallback: fallback, manifest: manifest))
    }

    func testResolverRequiresExactV2ArtifactBeforeAdmittingAdobeExecution() throws {
        let fallback = try makeFallback()
        let artifact = try DCPProfileArtifactV2(
            fallback: fallback,
            manifest: makeManifest(for: fallback)
        )
        let resolver = RawRenderRecipeResolver(admittedArtifacts: [artifact])

        let recipe = resolver.resolve(
            makeInput(enabled: true),
            capabilities: RawDecoderCapabilities(supportsAdobeProcess2012V1: true)
        )

        XCTAssertEqual(recipe.policy, .adobeProcess2012V1)
        XCTAssertEqual(recipe.effectivePolicy, .adobeProcess2012V1)
        XCTAssertEqual(recipe.cameraProfile.fallbackID, fallback.id)
    }

    func testPersistedAdobePolicyWithoutEffectivePolicyReopensNative() throws {
        let recipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(policy: .adobeProcess2012V1),
            capabilities: RawDecoderCapabilities()
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any]
        )
        object.removeValue(forKey: "effectivePolicy")

        let reopened = try JSONDecoder().decode(
            ResolvedRawRenderRecipe.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(reopened.policy, .adobeProcess2012V1)
        XCTAssertEqual(reopened.effectivePolicy, .native)
        XCTAssertEqual(reopened.decoderOptionVectorID, "coreImage/native-v1/full")
        XCTAssertEqual(reopened.workingColorSpaceID, RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue)
    }

    func testCameraScopeMismatchRollsBackCompleteRecipeToNative() throws {
        let fallback = try makeFallback()
        let artifact = try DCPProfileArtifactV2(
            fallback: fallback,
            manifest: makeManifest(for: fallback)
        )
        let resolver = RawRenderRecipeResolver(admittedArtifacts: [artifact])
        let recipe = resolver.resolve(
            makeInput(enabled: true),
            capabilities: RawDecoderCapabilities(supportsAdobeProcess2012V1: true)
        )

        let rolledBack = resolver.resolvingCameraProfile(
            in: recipe,
            request: RawCameraProfileRequest(sourceName: "Adobe Color"),
            cameraMake: "Unknown",
            cameraModel: "Unknown"
        )

        XCTAssertEqual(rolledBack.policy, .adobeProcess2012V1)
        XCTAssertEqual(rolledBack.effectivePolicy, .native)
        XCTAssertEqual(rolledBack.decoderOptionVectorID, "coreImage/native-v1/full")
        XCTAssertEqual(rolledBack.workingColorSpaceID, RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue)
        XCTAssertEqual(rolledBack.outputTransformID, RawOutputTransformID.displaySRGBV1.rawValue)
        XCTAssertNil(rolledBack.cameraProfile.appliedName)
        XCTAssertNil(rolledBack.cameraProfile.fallbackID)
    }

    private var adobeOptionVectorID: String {
        CoreImageRawPolicy.optionVector(for: .adobeProcess2012V1)?.id
            ?? "adobe-process-2012-v1-preserve-defaults-v1"
    }

    private func makeInput(enabled: Bool) -> RawRenderRecipeInput {
        RawRenderRecipeInput(
            policy: .adobeProcess2012V1,
            cameraProfileRequest: RawCameraProfileRequest(
                sourceName: "Adobe Color",
                cameraMake: "Sony",
                cameraModel: "ILCE-6400"
            ),
            featureFlags: RawRendererFeatureFlags(adobeProcess2012V1Enabled: enabled)
        )
    }

    private func makeFallback() throws -> CameraProfileFallback {
        try CameraProfileFallback(
            id: "adobe-color-sony-ilce-6400",
            version: 1,
            cameraMatch: CameraMatch(make: "Sony", model: "ILCE-6400"),
            sourceProfileName: "Adobe Color",
            matrix3x3: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            redToneLUT: [0, 1],
            greenToneLUT: [0, 1],
            blueToneLUT: [0, 1],
            provenance: "synthetic gate2 test artifact"
        )
    }

    private func makeManifest(for fallback: CameraProfileFallback) -> ProfileCalibrationArtifactManifest {
        ProfileCalibrationArtifactManifest(
            policy: .adobeProcess2012V1,
            cameraMatch: fallback.cameraMatch,
            canonicalProfileName: fallback.sourceProfileName,
            artifactID: fallback.id,
            artifactVersion: fallback.version,
            decoderOptionVectorID: adobeOptionVectorID,
            workingColorSpaceID: RawWorkingColorSpaceID.adobeCompatibleLinearWideGamutV1.rawValue,
            outputTransformID: RawOutputTransformID.displaySRGBV1.rawValue,
            provenance: fallback.provenance,
            coefficientDigest: fallback.coefficientDigest
        )
    }
}
