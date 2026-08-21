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

final class CoreImagePreviewRendererTests: XCTestCase {
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
}
