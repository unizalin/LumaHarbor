import XCTest
@testable import RawProcessingCore

final class ProfileCalibrationArtifactManifestTests: XCTestCase {
    func testManifestAdmitsMatchingValidatedFallback() throws {
        let fallback = try makeFallback()
        let manifest = makeManifest(for: fallback)

        XCTAssertNoThrow(try manifest.validate(fallback: fallback))
    }

    func testManifestRejectsFallbackWithDifferentCameraOrProfile() throws {
        let fallback = try makeFallback()
        let manifest = ProfileCalibrationArtifactManifest(
            policy: .adobeProcess2012V1,
            cameraMatch: CameraMatch(make: "Sony", model: "ILCE-6400"),
            canonicalProfileName: "Adobe Standard",
            artifactID: fallback.id,
            artifactVersion: fallback.version,
            decoderOptionVectorID: "adobe-process-2012-v1-preserve-defaults-v1",
            workingColorSpaceID: RawWorkingColorSpaceID.adobeCompatibleLinearWideGamutV1.rawValue,
            outputTransformID: RawOutputTransformID.displaySRGBV1.rawValue,
            provenance: "sanitized test artifact",
            coefficientDigest: fallback.coefficientDigest
        )

        XCTAssertThrowsError(try manifest.validate(fallback: fallback)) { error in
            XCTAssertEqual(error as? ProfileCalibrationArtifactManifest.ValidationError, .fallbackMismatch)
        }
    }

    func testManifestRejectsNativePolicyAndMissingProvenance() throws {
        let fallback = try makeFallback()
        let manifest = ProfileCalibrationArtifactManifest(
            policy: .native,
            cameraMatch: fallback.cameraMatch,
            canonicalProfileName: fallback.sourceProfileName,
            artifactID: fallback.id,
            artifactVersion: fallback.version,
            decoderOptionVectorID: "native-v1",
            workingColorSpaceID: RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue,
            outputTransformID: RawOutputTransformID.displaySRGBV1.rawValue,
            provenance: ""
        )

        XCTAssertThrowsError(try manifest.validate(fallback: fallback)) { error in
            XCTAssertEqual(error as? ProfileCalibrationArtifactManifest.ValidationError, .unsupportedPolicy)
        }
    }

    func testManifestRejectsRuntimePipelineMismatch() throws {
        let fallback = try makeFallback()
        let manifest = makeManifest(for: fallback)

        XCTAssertThrowsError(
            try manifest.validateRuntimeBinding(
                fallback: fallback,
                decoderIdentifier: DecoderIdentifier(kind: "other", version: "1"),
                decoderOptionVectorID: manifest.decoderOptionVectorID,
                workingColorSpaceID: manifest.workingColorSpaceID,
                outputTransformID: manifest.outputTransformID
            )
        ) { error in
            XCTAssertEqual(error as? ProfileCalibrationArtifactManifest.ValidationError, .runtimeBindingMismatch)
        }
    }

    func testEmptyGeneratedRegistryRemainsFailClosed() {
        XCTAssertTrue(AdobeCompatibleProfileFallbacksV1.all.isEmpty)
    }

    private func makeManifest(for fallback: CameraProfileFallback) -> ProfileCalibrationArtifactManifest {
        ProfileCalibrationArtifactManifest(
            policy: .adobeProcess2012V1,
            cameraMatch: fallback.cameraMatch,
            canonicalProfileName: fallback.sourceProfileName,
            artifactID: fallback.id,
            artifactVersion: fallback.version,
            decoderOptionVectorID: "adobe-process-2012-v1-preserve-defaults-v1",
            workingColorSpaceID: RawWorkingColorSpaceID.adobeCompatibleLinearWideGamutV1.rawValue,
            outputTransformID: RawOutputTransformID.displaySRGBV1.rawValue,
            provenance: fallback.provenance,
            coefficientDigest: fallback.coefficientDigest
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
            provenance: "sanitized test artifact"
        )
    }
}
