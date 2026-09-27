import XCTest
@testable import RawProcessingCore

final class ControlledRendererEnablementTests: XCTestCase {
    func testEnablementTableIsFailClosedUntilEveryGateMatches() throws {
        let fallback = try makeFallback()
        let validManifest = makeManifest(for: fallback)
        let validResolver = RawRenderRecipeResolver(
            cameraProfileFallbacks: [fallback],
            artifactManifests: [validManifest]
        )

        let cases: [(name: String, input: RawRenderRecipeInput, resolver: RawRenderRecipeResolver, expected: RawRenderingCompatibility)] = [
            (
                "native policy",
                RawRenderRecipeInput(policy: .native, featureFlags: .init(adobeProcess2012V1Enabled: true)),
                validResolver,
                .native
            ),
            (
                "release gate off",
                makeInput(enabled: false),
                validResolver,
                .native
            ),
            (
                "registry miss",
                makeInput(enabled: true),
                RawRenderRecipeResolver(),
                .native
            ),
            (
                "invalid artifact",
                makeInput(enabled: true),
                RawRenderRecipeResolver(
                    cameraProfileFallbacks: [fallback],
                    artifactManifests: [makeManifest(for: fallback, profileName: "Adobe Standard")]
                ),
                .native
            ),
            (
                "all gates match",
                makeInput(enabled: true),
                validResolver,
                .adobeProcess2012V1
            )
        ]

        for testCase in cases {
            let recipe = testCase.resolver.resolve(
                testCase.input,
                capabilities: RawDecoderCapabilities(supportsAdobeProcess2012V1: true)
            )
            XCTAssertEqual(recipe.effectivePolicy, testCase.expected, testCase.name)
            if testCase.expected == .native {
                XCTAssertEqual(recipe.decoderOptionVectorID, "coreImage/native-v1/full", testCase.name)
                XCTAssertEqual(recipe.workingColorSpaceID, RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue, testCase.name)
                XCTAssertNil(recipe.cameraProfile.appliedName, testCase.name)
            } else {
                XCTAssertEqual(recipe.decoderOptionVectorID, "coreImage/adobe-process-2012-v1-preserve-defaults-v1/full", testCase.name)
                XCTAssertEqual(recipe.workingColorSpaceID, RawWorkingColorSpaceID.adobeCompatibleLinearWideGamutV1.rawValue, testCase.name)
                XCTAssertEqual(recipe.cameraProfile.appliedName, "Adobe Color", testCase.name)
                XCTAssertEqual(recipe.cameraProfile.fallbackID, fallback.id, testCase.name)
                XCTAssertFalse(recipe.diagnostics.contains { $0.code == .rendererNotCalibrated }, testCase.name)
            }
        }
    }

    func testPersistedAdobePolicyStaysVisibleAcrossReopenWhileEffectivePathIsNative() throws {
        let recipe = RawRenderRecipeResolver().resolve(
            makeInput(enabled: false),
            capabilities: RawDecoderCapabilities()
        )
        let reopened = try JSONDecoder().decode(
            ResolvedRawRenderRecipe.self,
            from: JSONEncoder().encode(recipe)
        )

        XCTAssertEqual(reopened.policy, .adobeProcess2012V1)
        XCTAssertEqual(reopened.effectivePolicy, .native)
        XCTAssertEqual(reopened.decoderOptionVectorID, "coreImage/native-v1/full")
        XCTAssertEqual(reopened.workingColorSpaceID, RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue)
        XCTAssertNil(reopened.cameraProfile.appliedName)
    }

    func testForgedSerializedAdobeEffectivePolicyCannotBypassGate() throws {
        let recipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(policy: .adobeProcess2012V1),
            capabilities: RawDecoderCapabilities()
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any]
        )
        object["effectivePolicy"] = RawRenderingCompatibility.adobeProcess2012V1.rawValue
        let forged = try JSONSerialization.data(withJSONObject: object)

        let reopened = try JSONDecoder().decode(ResolvedRawRenderRecipe.self, from: forged)

        XCTAssertEqual(reopened.policy, .adobeProcess2012V1)
        XCTAssertEqual(reopened.effectivePolicy, .native)
        XCTAssertEqual(reopened.decoderOptionVectorID, "coreImage/native-v1/full")
    }

    func testNativeEffectivePolicyCanonicalizesForgedAdobeExecutionState() throws {
        let recipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(policy: .adobeProcess2012V1),
            capabilities: RawDecoderCapabilities()
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any]
        )
        object["effectivePolicy"] = RawRenderingCompatibility.adobeProcess2012V1.rawValue
        object["decoderOptionVectorID"] = "coreImage/adobe-process-2012-v1-preserve-defaults-v1/full"
        object["workingColorSpaceID"] = RawWorkingColorSpaceID.adobeCompatibleLinearWideGamutV1.rawValue
        object["outputTransformID"] = "adobe-display-p3-v1"
        object["cameraProfile"] = [
            "requestedName": "Adobe Color",
            "appliedName": "Adobe Color",
            "fallbackID": "forged-profile",
            "fallbackVersion": 1,
            "compatibility": "approximate",
            "provenance": "forged"
        ]

        let reopened = try JSONDecoder().decode(
            ResolvedRawRenderRecipe.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(reopened.policy, .adobeProcess2012V1)
        XCTAssertEqual(reopened.effectivePolicy, .native)
        XCTAssertEqual(reopened.decoderOptionVectorID, "coreImage/native-v1/full")
        XCTAssertEqual(reopened.workingColorSpaceID, RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue)
        XCTAssertEqual(reopened.outputTransformID, RawOutputTransformID.displaySRGBV1.rawValue)
        XCTAssertNil(reopened.cameraProfile.appliedName)
        XCTAssertNil(reopened.cameraProfile.fallbackID)
        XCTAssertEqual(reopened.cameraProfile.compatibility, .preservedNotApplied)
    }

    func testCameraMetadataMismatchRollsAnAdobeRecipeBackToNative() throws {
        let fallback = try makeFallback()
        let resolver = RawRenderRecipeResolver(
            cameraProfileFallbacks: [fallback],
            artifactManifests: [makeManifest(for: fallback)]
        )
        let recipe = resolver.resolve(
            makeInput(enabled: true),
            capabilities: RawDecoderCapabilities()
        )
        XCTAssertEqual(recipe.effectivePolicy, .adobeProcess2012V1)

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
        XCTAssertNil(rolledBack.cameraProfile.appliedName)
    }

    func testNativePolicyRejectsSerializedAdobeExecutionState() throws {
        let fallback = try makeFallback()
        let recipe = RawRenderRecipeResolver(
            cameraProfileFallbacks: [fallback],
            artifactManifests: [makeManifest(for: fallback)]
        ).resolve(makeInput(enabled: true), capabilities: RawDecoderCapabilities())
        XCTAssertEqual(recipe.effectivePolicy, .adobeProcess2012V1)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any]
        )
        object["policy"] = RawRenderingCompatibility.native.rawValue

        let reopened = try JSONDecoder().decode(
            ResolvedRawRenderRecipe.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(reopened.policy, .native)
        XCTAssertEqual(reopened.effectivePolicy, .native)
        XCTAssertEqual(reopened.decoderOptionVectorID, "coreImage/native-v1/full")
        XCTAssertEqual(reopened.workingColorSpaceID, RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue)
        XCTAssertNil(reopened.cameraProfile.appliedName)
        XCTAssertNil(reopened.cameraProfile.fallbackID)
    }

    func testMatchingArtifactIDCannotAdmitWrongCamera() throws {
        try assertScopeMismatchRejected(makeFallback(
            cameraMatch: CameraMatch(make: "Synthetic", model: "Other")
        ))
    }

    func testMatchingArtifactIDCannotAdmitWrongProfile() throws {
        try assertScopeMismatchRejected(makeFallback(profileName: "Adobe Standard"))
    }

    func testMatchingArtifactIDCannotAdmitWrongVersion() throws {
        try assertScopeMismatchRejected(makeFallback(version: 2))
    }

    func testNativePolicyCannotConstructAdobeEffectiveRecipeInMemory() throws {
        let fallback = try makeFallback()
        let admitted = RawRenderRecipeResolver(
            cameraProfileFallbacks: [fallback],
            artifactManifests: [makeManifest(for: fallback)]
        ).resolve(makeInput(enabled: true), capabilities: RawDecoderCapabilities())
        XCTAssertEqual(admitted.effectivePolicy, .adobeProcess2012V1)

        let recipe = ResolvedRawRenderRecipe(
            policy: .native,
            effectivePolicy: .adobeProcess2012V1,
            decoder: admitted.decoder,
            whiteBalance: admitted.whiteBalance,
            lensCorrection: admitted.lensCorrection,
            cameraProfile: admitted.cameraProfile,
            decoderOptionVectorID: admitted.decoderOptionVectorID,
            workingColorSpaceID: admitted.workingColorSpaceID,
            outputTransformID: admitted.outputTransformID
        )

        XCTAssertEqual(recipe.policy, .native)
        XCTAssertEqual(recipe.effectivePolicy, .native)
        XCTAssertEqual(recipe.decoderOptionVectorID, "coreImage/native-v1/full")
        XCTAssertEqual(recipe.workingColorSpaceID, RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue)
        XCTAssertEqual(recipe.outputTransformID, RawOutputTransformID.displaySRGBV1.rawValue)
        XCTAssertNil(recipe.cameraProfile.appliedName)
        XCTAssertNil(recipe.cameraProfile.fallbackID)
    }

    private func assertScopeMismatchRejected(
        _ fallback: CameraProfileFallback,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let manifest = makeManifest(for: fallback)
        let resolvers = [
            RawRenderRecipeResolver(cameraProfileFallbacks: [fallback], artifactManifests: [manifest]),
            RawRenderRecipeResolver(admittedArtifacts: [try DCPProfileArtifactV2(fallback: fallback, manifest: manifest)])
        ]
        let validFallback = try makeFallback()
        let admittedRecipe = RawRenderRecipeResolver(
            cameraProfileFallbacks: [validFallback],
            artifactManifests: [makeManifest(for: validFallback)]
        ).resolve(makeInput(enabled: true), capabilities: RawDecoderCapabilities())
        XCTAssertEqual(admittedRecipe.effectivePolicy, .adobeProcess2012V1, file: file, line: line)

        for resolver in resolvers {
            let initial = resolver.resolve(makeInput(enabled: true), capabilities: RawDecoderCapabilities())
            let afterMetadata = resolver.resolvingCameraProfile(
                in: admittedRecipe,
                request: RawCameraProfileRequest(sourceName: "Adobe Color"),
                cameraMake: "Sony",
                cameraModel: "ILCE-6400"
            )
            for recipe in [initial, afterMetadata] {
                XCTAssertEqual(recipe.policy, .adobeProcess2012V1, file: file, line: line)
                XCTAssertEqual(recipe.effectivePolicy, .native, file: file, line: line)
                XCTAssertEqual(recipe.decoderOptionVectorID, "coreImage/native-v1/full", file: file, line: line)
                XCTAssertEqual(recipe.workingColorSpaceID, RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue, file: file, line: line)
                XCTAssertNil(recipe.cameraProfile.appliedName, file: file, line: line)
                XCTAssertNil(recipe.cameraProfile.fallbackID, file: file, line: line)
            }
        }
    }

    private func makeInput(enabled: Bool) -> RawRenderRecipeInput {
        RawRenderRecipeInput(
            policy: .adobeProcess2012V1,
            cameraProfileRequest: RawCameraProfileRequest(
                sourceName: "Adobe Color",
                cameraMake: "Sony",
                cameraModel: "ILCE-6400"
            ),
            featureFlags: .init(adobeProcess2012V1Enabled: enabled)
        )
    }

    private func makeFallback(
        cameraMatch: CameraMatch = CameraMatch(make: "Sony", model: "ILCE-6400"),
        profileName: String = "Adobe Color",
        version: Int = 1
    ) throws -> CameraProfileFallback {
        try CameraProfileFallback(
            id: "adobe-color-sony-ilce-6400",
            version: version,
            cameraMatch: cameraMatch,
            sourceProfileName: profileName,
            matrix3x3: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            redToneLUT: [0, 1],
            greenToneLUT: [0, 1],
            blueToneLUT: [0, 1],
            provenance: "sanitized test artifact"
        )
    }

    private func makeManifest(
        for fallback: CameraProfileFallback,
        profileName: String? = nil
    ) -> ProfileCalibrationArtifactManifest {
        ProfileCalibrationArtifactManifest(
            policy: .adobeProcess2012V1,
            cameraMatch: fallback.cameraMatch,
            canonicalProfileName: profileName ?? fallback.sourceProfileName,
            artifactID: fallback.id,
            artifactVersion: fallback.version,
            decoderOptionVectorID: "adobe-process-2012-v1-preserve-defaults-v1",
            workingColorSpaceID: RawWorkingColorSpaceID.adobeCompatibleLinearWideGamutV1.rawValue,
            outputTransformID: RawOutputTransformID.displaySRGBV1.rawValue,
            provenance: fallback.provenance,
            coefficientDigest: fallback.coefficientDigest
        )
    }
}
