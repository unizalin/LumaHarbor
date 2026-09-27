import Foundation
import XCTest
@testable import RawProcessingCore

final class RawRenderRecipeResolverTests: XCTestCase {
    private let input = RawRenderRecipeInput(
        policy: .adobeProcess2012V1,
        quality: .highQuality(maximumPixelDimension: 2_048),
        whiteBalance: RawWhiteBalance(temperatureOffsetKelvin: 120, tintOffset: -3),
        lensCorrection: LensCorrectionAdjustments(mode: .automatic),
        cameraProfileRequest: RawCameraProfileRequest(sourceName: "Adobe Color"),
        featureFlags: RawRendererFeatureFlags(adobeProcess2012V1Enabled: true)
    )

    func testSameInputResolvesIdenticalRecipe() throws {
        let resolver = RawRenderRecipeResolver()
        let capabilities = RawDecoderCapabilities(decoderIdentifier: DecoderIdentifier(kind: "coreImage", version: "system-default"))

        let first = resolver.resolve(input, capabilities: capabilities)
        let second = resolver.resolve(input, capabilities: capabilities)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashValue, second.hashValue)
        XCTAssertEqual(
            try JSONDecoder().decode(ResolvedRawRenderRecipe.self, from: JSONEncoder().encode(first)),
            second
        )
    }

    func testAdobePolicyStaysPersistedButUsesNativeUntilArtifactIsAdmitted() {
        let recipe = RawRenderRecipeResolver().resolve(
            input,
            capabilities: RawDecoderCapabilities(decoderIdentifier: DecoderIdentifier(kind: "coreImage", version: "system-default"))
        )

        XCTAssertEqual(recipe.policy, .adobeProcess2012V1)
        XCTAssertEqual(recipe.effectivePolicy, .native)
        XCTAssertEqual(recipe.decoderOptionVectorID, "coreImage/native-v1/high-2048")
        XCTAssertEqual(recipe.workingColorSpaceID, RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue)
        XCTAssertEqual(recipe.outputTransformID, RawOutputTransformID.displaySRGBV1.rawValue)
        XCTAssertTrue(recipe.diagnostics.contains { $0.code == .recipeResolutionFallback })
        XCTAssertEqual(recipe.cameraProfile.requestedName, "Adobe Color")
        XCTAssertEqual(recipe.cameraProfile.compatibility, .preservedNotApplied)
    }

    func testDisabledAdobeFeatureFallsBackWithoutChangingPersistedPolicy() {
        var disabled = RawRendererFeatureFlags()
        disabled.adobeProcess2012V1Enabled = false
        var disabledInput = input
        disabledInput.featureFlags = disabled

        let recipe = RawRenderRecipeResolver().resolve(
            disabledInput,
            capabilities: RawDecoderCapabilities(
                decoderIdentifier: DecoderIdentifier(kind: "coreImage", version: "system-default"),
                supportsAdobeProcess2012V1: false
            )
        )

        XCTAssertEqual(recipe.policy, .adobeProcess2012V1)
        XCTAssertEqual(recipe.effectivePolicy, .native)
        XCTAssertEqual(recipe.decoderOptionVectorID, "coreImage/native-v1/high-2048")
        XCTAssertEqual(recipe.workingColorSpaceID, RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue)
        XCTAssertNil(recipe.cameraProfile.fallbackID)
        XCTAssertEqual(recipe.cameraProfile.compatibility, .preservedNotApplied)
        XCTAssertTrue(recipe.diagnostics.contains { $0.code == .recipeResolutionFallback })
    }

    func testAdobeRendererIsDisabledByDefaultBeforeGateTwo() {
        let recipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(policy: .adobeProcess2012V1),
            capabilities: RawDecoderCapabilities()
        )

        XCTAssertEqual(recipe.policy, .adobeProcess2012V1)
        XCTAssertEqual(recipe.effectivePolicy, .native)
        XCTAssertEqual(recipe.decoderOptionVectorID, "coreImage/native-v1/full")
        XCTAssertEqual(recipe.workingColorSpaceID, RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue)
        XCTAssertTrue(recipe.diagnostics.contains { $0.code == .recipeResolutionFallback })
    }

    func testNativeRecipeRoundTripsWithoutAFilePath() throws {
        let recipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(policy: .native),
            capabilities: RawDecoderCapabilities()
        )
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(ResolvedRawRenderRecipe.self, from: data)

        XCTAssertEqual(decoded, recipe)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("/tmp"))
    }

    func testRecipesWrittenBeforeEffectivePolicyWasAddedFailClosedOnDecode() throws {
        let recipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(policy: .adobeProcess2012V1),
            capabilities: RawDecoderCapabilities()
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any]
        )
        object.removeValue(forKey: "effectivePolicy")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ResolvedRawRenderRecipe.self, from: legacyData)

        XCTAssertEqual(decoded.policy, .adobeProcess2012V1)
        XCTAssertEqual(decoded.effectivePolicy, .native)
    }

    func testPersistedAdobePolicyReopensWithNativeEffectivePolicyBeforeGateTwo() throws {
        let recipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(policy: .adobeProcess2012V1),
            capabilities: RawDecoderCapabilities()
        )
        let reopened = try JSONDecoder().decode(
            ResolvedRawRenderRecipe.self,
            from: JSONEncoder().encode(recipe)
        )

        XCTAssertEqual(reopened.policy, .adobeProcess2012V1)
        XCTAssertEqual(reopened.effectivePolicy, .native)
        XCTAssertEqual(reopened.decoderOptionVectorID, recipe.decoderOptionVectorID)
        XCTAssertEqual(reopened.workingColorSpaceID, RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue)
        XCTAssertEqual(reopened.outputTransformID, recipe.outputTransformID)
    }

    func testKnownCameraProfileStaysPreservedUntilAValidatedFallbackExists() {
        let recipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(
                policy: .adobeProcess2012V1,
                cameraProfileRequest: RawCameraProfileRequest(
                    sourceName: "Adobe Color",
                    cameraMake: "Sony",
                    cameraModel: "ILCE-6400"
                )
            ),
            capabilities: RawDecoderCapabilities()
        )

        XCTAssertEqual(recipe.cameraProfile.requestedName, "Adobe Color")
        XCTAssertNil(recipe.cameraProfile.appliedName)
        XCTAssertNil(recipe.cameraProfile.fallbackID)
        XCTAssertEqual(recipe.cameraProfile.compatibility, .preservedNotApplied)
        XCTAssertTrue(recipe.diagnostics.contains { $0.code == .rendererNotCalibrated })
    }
}
