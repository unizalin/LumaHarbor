import CoreGraphics
import CoreImage
import XCTest
@testable import RawProcessingCore

final class CameraProfileRendererTests: XCTestCase {
    private let renderer = CameraProfileRenderer()

    func testIdentityFallbackDoesNotChangePixels() throws {
        let fallback = try makeFallback(
            matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            red: [0, 1], green: [0, 1], blue: [0, 1]
        )
        let source = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.7))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let recipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(policy: .adobeProcess2012V1),
            capabilities: RawDecoderCapabilities()
        )

        let output = try renderer.apply(fallback, to: source, recipe: recipe)
        XCTAssertTrue(output === source, "identity profile should remain a passthrough")
    }

    func testMatrixUsesRowMajorRGBChannelMapping() throws {
        let fallback = try makeFallback(
            matrix: [0, 1, 0, 0, 0, 1, 1, 0, 0],
            red: [0, 1], green: [0, 1], blue: [0, 1]
        )
        let source = CIImage(color: CIColor(red: 0.1, green: 0.3, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let recipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(policy: .adobeProcess2012V1),
            capabilities: RawDecoderCapabilities()
        )

        let output = try renderer.apply(fallback, to: source, recipe: recipe)
        let pixel = try sample(output)
        XCTAssertEqual(pixel.red, 0.3, accuracy: 0.02)
        XCTAssertEqual(pixel.green, 0.8, accuracy: 0.02)
        XCTAssertEqual(pixel.blue, 0.1, accuracy: 0.02)
    }

    func testMonotonicPerChannelLUTIsAppliedAfterTheMatrix() throws {
        let fallback = try makeFallback(
            matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            red: [0, 0.8, 1], green: [0, 0.5, 1], blue: [0, 0.25, 1]
        )
        let source = CIImage(color: CIColor(red: 0.25, green: 0.25, blue: 0.25))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        let recipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(policy: .adobeProcess2012V1),
            capabilities: RawDecoderCapabilities()
        )

        let output = try renderer.apply(fallback, to: source, recipe: recipe)
        let pixel = try sample(output)
        XCTAssertGreaterThan(pixel.red, pixel.green)
        XCTAssertGreaterThan(pixel.green, pixel.blue)
    }

    func testInvalidCoefficientsAreRejected() {
        XCTAssertThrowsError(try makeFallback(
            matrix: [1, 0, .nan, 0, 1, 0, 0, 0, 1],
            red: [0, 1], green: [0, 1], blue: [0, 1]
        ))
        XCTAssertThrowsError(try makeFallback(
            matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            red: [0, 0.8, 0.7, 1], green: [0, 1], blue: [0, 1]
        ))
        XCTAssertThrowsError(try makeFallback(
            matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1],
            red: [0, 1], green: [0, 1], blue: [0, 1.1]
        ))
    }

    func testPipelineAppliesProfileBeforeExposure() throws {
        let fallback = try makeFallback(
            id: "adobe-color-sony-ilce-6400",
            cameraMatch: CameraMatch(make: "Sony", model: "ILCE-6400"),
            sourceProfileName: "Adobe Color",
            matrix: [2, 0, 0, 0, 1, 0, 0, 0, 1],
            red: [0, 1], green: [0, 1], blue: [0, 1]
        )
        let recipe = RawRenderRecipeResolver(
            cameraProfileFallbacks: [fallback],
            artifactManifests: [makeManifest(for: fallback)]
        ).resolve(
            RawRenderRecipeInput(
                policy: .adobeProcess2012V1,
                cameraProfileRequest: RawCameraProfileRequest(
                    sourceName: "Adobe Color",
                    cameraMake: "Sony",
                    cameraModel: "ILCE-6400"
                ),
                featureFlags: RawRendererFeatureFlags(adobeProcess2012V1Enabled: true)
            ),
            capabilities: RawDecoderCapabilities()
        )
        let source = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

        let baseline = AdjustmentPipeline().apply(
            PhotoAdjustments(exposure: 1),
            to: source
        )
        let output = AdjustmentPipeline(
            cameraProfileRenderer: renderer,
            cameraProfileFallbacks: [fallback]
        ).apply(
            PhotoAdjustments(exposure: 1),
            to: source,
            recipe: recipe
        )
        let baselinePixel = try sample(baseline)
        let pixel = try sample(output)
        XCTAssertGreaterThan(pixel.red, baselinePixel.red + 0.08)
    }

    func testPipelineDoesNotApplyAdobeProfileWhenEffectivePolicyFallsBackToNative() throws {
        let fallback = try makeFallback(
            matrix: [2, 0, 0, 0, 1, 0, 0, 0, 1],
            red: [0, 1], green: [0, 1], blue: [0, 1]
        )
        let recipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(policy: .adobeProcess2012V1),
            capabilities: RawDecoderCapabilities()
        ).replacingCameraProfile(
            ResolvedRawCameraProfile(
                requestedName: "Adobe Color",
                appliedName: "Adobe Color",
                fallbackID: fallback.id,
                fallbackVersion: fallback.version,
                compatibility: .approximate,
                provenance: fallback.provenance
            )
        )
        let source = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

        let baseline = AdjustmentPipeline().apply(PhotoAdjustments.neutral, to: source)
        let output = AdjustmentPipeline(
            cameraProfileRenderer: renderer,
            cameraProfileFallbacks: [fallback]
        ).apply(PhotoAdjustments.neutral, to: source, recipe: recipe)

        let baselinePixel = try sample(baseline)
        let pixel = try sample(output)
        XCTAssertEqual(pixel.red, baselinePixel.red, accuracy: 0.01)
        XCTAssertEqual(pixel.green, baselinePixel.green, accuracy: 0.01)
        XCTAssertEqual(pixel.blue, baselinePixel.blue, accuracy: 0.01)
    }

    private func makeFallback(
        id: String = "synthetic-profile-v1",
        cameraMatch: CameraMatch = CameraMatch(make: "Synthetic", model: "Test"),
        sourceProfileName: String = "Synthetic",
        matrix: [Float], red: [Float], green: [Float], blue: [Float]
    ) throws -> CameraProfileFallback {
        try CameraProfileFallback(
            id: id,
            version: 1,
            cameraMatch: cameraMatch,
            sourceProfileName: sourceProfileName,
            matrix3x3: matrix,
            redToneLUT: red,
            greenToneLUT: green,
            blueToneLUT: blue,
            provenance: "unit-test"
        )
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

    private func sample(_ image: CIImage) throws -> (red: Double, green: Double, blue: Double) {
        let renderer = ImageRenderService()
        let cgImage = try renderer.makeCGImage(image)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }
}
