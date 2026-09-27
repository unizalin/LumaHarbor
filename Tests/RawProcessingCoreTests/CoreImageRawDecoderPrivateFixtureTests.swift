import CoreImage
import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import RawProcessingCore

/// Optional evidence test for the private RAW corpus. The fixture directory
/// is intentionally environment-provided and never becomes a repository
/// dependency or part of failure output.
final class CoreImageRawDecoderPrivateFixtureTests: XCTestCase {
    func testSamePrivateRAWDecodesToStableRecipeAndPixels() throws {
        let url = try fixtureURL()
        let decoder = CoreImageRawDecoder()
        let recipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(
                policy: .adobeProcess2012V1,
                quality: .full,
                featureFlags: RawRendererFeatureFlags(adobeProcess2012V1Enabled: true)
            ),
            capabilities: RawDecoderCapabilities(decoderIdentifier: decoder.identifier)
        )
        let request = RawDecodeRequest(
            url: url,
            quality: .full,
            rawRenderingCompatibility: .adobeProcess2012V1,
            rawRenderRecipe: recipe
        )

        let first = try decoder.decode(request)
        let second = try decoder.decode(request)

        XCTAssertEqual(first.rawRenderRecipe, second.rawRenderRecipe)
        let firstRecipeData = try serializedRecipe(first.rawRenderRecipe)
        let secondRecipeData = try serializedRecipe(second.rawRenderRecipe)
        XCTAssertEqual(
            firstRecipeData,
            secondRecipeData,
            "recipe bytes differ\nfirst=\(String(decoding: firstRecipeData, as: UTF8.self))\nsecond=\(String(decoding: secondRecipeData, as: UTF8.self))"
        )
        XCTAssertEqual(try pixelDigest(first.image), try pixelDigest(second.image))
    }

    func testFailClosedAdobePolicyMatchesNativeDecodePreviewAndExport() async throws {
        let url = try fixtureURL()
        let decoder = CoreImageRawDecoder()
        let capabilities = RawDecoderCapabilities(decoderIdentifier: decoder.identifier)
        let cameraProfileRequest = RawCameraProfileRequest(sourceName: "Adobe Color")

        let nativeRecipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(
                policy: .native,
                quality: .full,
                cameraProfileRequest: cameraProfileRequest
            ),
            capabilities: capabilities
        )
        let failClosedRecipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(
                policy: .adobeProcess2012V1,
                quality: .full,
                cameraProfileRequest: cameraProfileRequest
            ),
            capabilities: capabilities
        )

        XCTAssertEqual(nativeRecipe.effectivePolicy, .native)
        XCTAssertEqual(failClosedRecipe.policy, .adobeProcess2012V1)
        XCTAssertEqual(failClosedRecipe.effectivePolicy, .native)
        XCTAssertEqual(failClosedRecipe.decoderOptionVectorID, nativeRecipe.decoderOptionVectorID)
        XCTAssertEqual(failClosedRecipe.workingColorSpaceID, nativeRecipe.workingColorSpaceID)
        XCTAssertEqual(failClosedRecipe.outputTransformID, nativeRecipe.outputTransformID)
        XCTAssertEqual(failClosedRecipe.cameraProfile.compatibility, .preservedNotApplied)
        XCTAssertNil(failClosedRecipe.cameraProfile.appliedName)
        XCTAssertNil(failClosedRecipe.cameraProfile.fallbackID)

        let native = try decoder.decode(
            RawDecodeRequest(
                url: url,
                quality: .full,
                rawRenderingCompatibility: .native,
                cameraProfileRequest: cameraProfileRequest,
                rawRenderRecipe: nativeRecipe
            )
        )
        let failClosed = try decoder.decode(
            RawDecodeRequest(
                url: url,
                quality: .full,
                rawRenderingCompatibility: .adobeProcess2012V1,
                cameraProfileRequest: cameraProfileRequest,
                rawRenderRecipe: failClosedRecipe
            )
        )

        XCTAssertEqual(native.decodedPixelSize, failClosed.decodedPixelSize)
        XCTAssertEqual(try pixelDigest(native.image), try pixelDigest(failClosed.image))

        var nativeAdjustments = PhotoAdjustments.neutral
        nativeAdjustments.rawRenderingCompatibility = .native
        var failClosedAdjustments = PhotoAdjustments.neutral
        failClosedAdjustments.rawRenderingCompatibility = .adobeProcess2012V1
        let subject = PreviewSubject(UUID())
        let nativePreview = try await CoreImagePreviewRenderer(decoder: decoder).render(
            PreviewRequest(
                subject: subject,
                url: url,
                adjustments: nativeAdjustments,
                targetPixelDimension: 512,
                quality: .high,
                cameraProfileRequest: cameraProfileRequest
            )
        )
        let failClosedPreview = try await CoreImagePreviewRenderer(decoder: decoder).render(
            PreviewRequest(
                subject: subject,
                url: url,
                adjustments: failClosedAdjustments,
                targetPixelDimension: 512,
                quality: .high,
                cameraProfileRequest: cameraProfileRequest
            )
        )

        XCTAssertEqual(nativePreview.pixelSize, failClosedPreview.pixelSize)
        XCTAssertEqual(try pixelDigest(nativePreview.cgImage), try pixelDigest(failClosedPreview.cgImage))
        XCTAssertEqual(nativePreview.rawRenderRecipe?.effectivePolicy, .native)
        XCTAssertEqual(failClosedPreview.rawRenderRecipe?.policy, .adobeProcess2012V1)
        XCTAssertEqual(failClosedPreview.rawRenderRecipe?.effectivePolicy, .native)

        let outputRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FailClosedRawParity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let exporter = PhotoExporter(decoder: decoder)
        let nativeExport = try await exporter.export(
            ExportRequest(
                sourceURL: url,
                adjustments: nativeAdjustments,
                destinationDirectory: outputRoot,
                baseFilename: "native",
                format: .tiff,
                bitDepth: .eightBit,
                cameraProfileRequest: cameraProfileRequest
            )
        )
        let failClosedExport = try await exporter.export(
            ExportRequest(
                sourceURL: url,
                adjustments: failClosedAdjustments,
                destinationDirectory: outputRoot,
                baseFilename: "fail-closed",
                format: .tiff,
                bitDepth: .eightBit,
                cameraProfileRequest: cameraProfileRequest
            )
        )

        XCTAssertEqual(nativeExport.pixelSize, failClosedExport.pixelSize)
        XCTAssertEqual(try pixelDigest(at: nativeExport.url), try pixelDigest(at: failClosedExport.url))
        XCTAssertEqual(nativeExport.rawRenderRecipe?.effectivePolicy, .native)
        XCTAssertEqual(failClosedExport.rawRenderRecipe?.policy, .adobeProcess2012V1)
        XCTAssertEqual(failClosedExport.rawRenderRecipe?.effectivePolicy, .native)
    }

    func testAdmittedPreserveDefaultsVectorDoesNotReplacePerRAWDecoderDefaults() throws {
        let url = try fixtureURL()
        let decoder = CoreImageRawDecoder()
        let nativeRecipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(policy: .native, quality: .full),
            capabilities: RawDecoderCapabilities(decoderIdentifier: decoder.identifier)
        )
        let diagnosticAdobeRecipe = nativeRecipe.replacingEffectivePolicy(.adobeProcess2012V1)

        let native = try decoder.decode(RawDecodeRequest(
            url: url,
            quality: .full,
            rawRenderingCompatibility: .native,
            rawRenderRecipe: nativeRecipe
        ))
        let adobe = try decoder.decode(RawDecodeRequest(
            url: url,
            quality: .full,
            rawRenderingCompatibility: .adobeProcess2012V1,
            rawRenderRecipe: diagnosticAdobeRecipe
        ))

        XCTAssertEqual(native.decodedPixelSize, adobe.decodedPixelSize)
        XCTAssertEqual(try pixelDigest(native.image), try pixelDigest(adobe.image))
        XCTAssertFalse(adobe.rawRenderRecipe?.diagnostics.contains(where: {
            $0.code == .rawOptionUnavailable
        }) ?? true)
    }

    private func fixtureURL() throws -> URL {
        guard let rawDirectory = ProcessInfo.processInfo.environment["LUMAHARBOR_RAW_FIXTURE_DIR"] else {
            throw XCTSkip("Private RAW fixture directory is not configured")
        }
        let directory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { CoreImageRawDecoder.candidateFileExtensions.contains($0.pathExtension.lowercased()) }
        guard let first = candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first else {
            throw XCTSkip("Private RAW fixture directory has no candidate RAW")
        }
        return first
    }

    private func serializedRecipe(_ recipe: ResolvedRawRenderRecipe?) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(recipe)
    }

    private func pixelDigest(_ image: CIImage) throws -> String {
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(image, from: image.extent),
              let data = try? pixelData(cgImage) else {
            throw NSError(domain: "CoreImageRawDecoderPrivateFixtureTests", code: 1)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func pixelDigest(_ image: CGImage) throws -> String {
        SHA256.hash(data: try pixelData(image)).map { String(format: "%02x", $0) }.joined()
    }

    private func pixelDigest(at url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "CoreImageRawDecoderPrivateFixtureTests", code: 2)
        }
        return try pixelDigest(image)
    }

    private func pixelData(_ image: CGImage) throws -> Data {
        guard let provider = image.dataProvider,
              let data = provider.data as Data? else {
            throw NSError(domain: "CoreImageRawDecoderPrivateFixtureTests", code: 3)
        }
        return data
    }
}
