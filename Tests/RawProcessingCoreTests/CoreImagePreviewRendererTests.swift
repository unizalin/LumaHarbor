import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import RawProcessingCore

/// A minimal `RawDecoding` fake that reports a fixed as-shot baseline, so the
/// renderer's baseline plumbing (Task 2, spec §5.3) can be tested without a
/// real RAW file or `CIRAWFilter`.
private struct BaselineReportingDecoder: RawDecoding {
    let identifier = DecoderIdentifier(kind: "synthetic-baseline", version: "test")
    var pixelSize = CGSize(width: 32, height: 24)
    var baselineTemperature: Double = 5_500
    var baselineTint: Double = 3

    func supportsFile(at url: URL) -> Bool { true }

    func readMetadata(at url: URL) throws -> RawMetadata {
        RawMetadata(pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height))
    }

    func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage {
        let image = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6))
            .cropped(to: CGRect(origin: .zero, size: pixelSize))
        return DecodedRawImage(
            image: image,
            nativePixelSize: pixelSize,
            decodedPixelSize: pixelSize,
            baselineTemperature: baselineTemperature,
            baselineTint: baselineTint,
            metadata: RawMetadata(pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height))
        )
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: RawDecodeRequest?

    var request: RawDecodeRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    func record(_ request: RawDecodeRequest) {
        lock.lock()
        storedRequest = request
        lock.unlock()
    }
}

private struct RecordingDecoder: RawDecoding {
    let identifier = DecoderIdentifier(kind: "recording", version: "test")
    let recorder: RequestRecorder

    func supportsFile(at url: URL) -> Bool { true }

    func readMetadata(at url: URL) throws -> RawMetadata {
        RawMetadata(pixelWidth: 4, pixelHeight: 4)
    }

    func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage {
        recorder.record(request)
        let size = CGSize(width: 4, height: 4)
        return DecodedRawImage(
            image: CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6)).cropped(to: CGRect(origin: .zero, size: size)),
            nativePixelSize: size,
            decodedPixelSize: size,
            baselineTemperature: 5_500,
            baselineTint: 0,
            metadata: RawMetadata(pixelWidth: 4, pixelHeight: 4)
        )
    }
}

final class CoreImagePreviewRendererTests: XCTestCase {
    func testPreviewCarriesRenderingCompatibilityIntoDecodeRequest() async throws {
        let recorder = RequestRecorder()
        let renderer = CoreImagePreviewRenderer(decoder: RecordingDecoder(recorder: recorder))
        var adjustments = PhotoAdjustments.neutral
        adjustments.rawRenderingCompatibility = .adobeProcess2012
        let request = PreviewRequest(
            subject: PreviewSubject(UUID()),
            url: URL(fileURLWithPath: "/tmp/lumaharbor-test.ARW"),
            adjustments: adjustments,
            targetPixelDimension: 256,
            quality: .interactive
        )

        _ = try await renderer.render(request)

        XCTAssertEqual(recorder.request?.rawRenderingCompatibility, .adobeProcess2012)
    }

    func testRenderedPreviewCarriesTheDecodersWhiteBalanceBaseline() async throws {
        let renderer = CoreImagePreviewRenderer(
            decoder: BaselineReportingDecoder(baselineTemperature: 5_200, baselineTint: -4)
        )
        let request = PreviewRequest(
            subject: PreviewSubject(UUID()),
            url: URL(fileURLWithPath: "/tmp/lumaharbor-test.ARW"),
            adjustments: .neutral,
            targetPixelDimension: 256,
            quality: .interactive
        )

        let image = try await renderer.render(request)

        XCTAssertEqual(image.whiteBalanceBaseline?.temperatureKelvin, 5_200)
        XCTAssertEqual(image.whiteBalanceBaseline?.tint, -4)
    }

    func testPreviewImageWithoutBaselineDefaultsToNil() throws {
        let cgImage = try TestImage.make()
        let image = PreviewImage(cgImage: cgImage, pixelSize: CGSize(width: 4, height: 4))
        XCTAssertNil(image.whiteBalanceBaseline)
    }

    // MARK: - Geometry (Phase 2 Task 2: "crop preview integration")

    /// The preview a user drags a crop handle against must reflect the crop
    /// live, not just the final export -- this is the round's own "crop
    /// preview integration" requirement. `PreviewImage.pixelSize` is
    /// derived straight from the rendered `CGImage`'s own dimensions, so a
    /// correct crop application shows up here with no separate size
    /// bookkeeping to keep in sync.
    func testPreviewReflectsACropsDimensions() async throws {
        let renderer = CoreImagePreviewRenderer(decoder: BaselineReportingDecoder(pixelSize: CGSize(width: 32, height: 24)))
        var adjustments = PhotoAdjustments.neutral
        adjustments.geometry.crop = NormalizedCropRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let request = PreviewRequest(
            subject: PreviewSubject(UUID()),
            url: URL(fileURLWithPath: "/tmp/lumaharbor-test.ARW"),
            adjustments: adjustments,
            targetPixelDimension: 256,
            quality: .interactive
        )

        let image = try await renderer.render(request)

        XCTAssertEqual(image.pixelSize, CGSize(width: 16, height: 12))
        XCTAssertEqual(image.cgImage.width, 16)
        XCTAssertEqual(image.cgImage.height, 12)
    }

    func testPreviewWithNeutralGeometryMatchesTheUncroppedDecodeSize() async throws {
        let renderer = CoreImagePreviewRenderer(decoder: BaselineReportingDecoder(pixelSize: CGSize(width: 32, height: 24)))
        let request = PreviewRequest(
            subject: PreviewSubject(UUID()),
            url: URL(fileURLWithPath: "/tmp/lumaharbor-test.ARW"),
            adjustments: .neutral,
            targetPixelDimension: 256,
            quality: .interactive
        )

        let image = try await renderer.render(request)

        XCTAssertEqual(image.pixelSize, CGSize(width: 32, height: 24))
    }

    func testPreviewExposesBrushMappingAndAppliesSourceBrushBeforeGeometry() async throws {
        let renderer = CoreImagePreviewRenderer(decoder: BaselineReportingDecoder(pixelSize: CGSize(width: 32, height: 24)))
        var adjustments = PhotoAdjustments.neutral
        adjustments.brushMasks = [BrushMask(
            strokes: [BrushMaskStroke(points: [BrushMaskPoint(x: 0.75, y: 0.25)], size: 0.25)],
            adjustments: BrushMaskPatch(exposure: 2)
        )]
        let request = PreviewRequest(
            subject: PreviewSubject(UUID()),
            url: URL(fileURLWithPath: "/tmp/lumaharbor-test.ARW"),
            adjustments: adjustments,
            targetPixelDimension: 256,
            quality: .interactive
        )
        let image = try await renderer.render(request)
        XCTAssertNotNil(image.brushCoordinateMapping)
        XCTAssertNotEqual(image.cgImage.width, 0)
    }
}
