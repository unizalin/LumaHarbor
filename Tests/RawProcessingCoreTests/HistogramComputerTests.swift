import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import RawProcessingCore

/// A minimal `RawDecoding` fake that always decodes to a single flat color --
/// mirrors `CoreImagePreviewRendererTests`' `BaselineReportingDecoder`, kept
/// local since that one is `private` to its own file.
private struct FlatColorDecoder: RawDecoding {
    let identifier = DecoderIdentifier(kind: "histogram-test-flat-color", version: "1")
    var color: CIColor
    var pixelSize = CGSize(width: 8, height: 8)

    func supportsFile(at url: URL) -> Bool { true }
    func readMetadata(at url: URL) throws -> RawMetadata {
        RawMetadata(pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height))
    }

    func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage {
        let image = CIImage(color: color).cropped(to: CGRect(origin: .zero, size: pixelSize))
        return DecodedRawImage(
            image: image,
            nativePixelSize: pixelSize,
            decodedPixelSize: pixelSize,
            baselineTemperature: 5_500,
            baselineTint: 0,
            metadata: RawMetadata(pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height))
        )
    }
}

/// AwayPhotoRawEditor parity Phase 1 Task 2: `HistogramComputer` is a pure
/// function over a `CGImage`'s actual rendered pixels (design spec §6.2 —
/// "must reflect the current rendered preview, not just original-file
/// statistics"). These tests exercise it two ways: deterministic bin counts
/// from tiny synthetic bitmaps with exactly known pixel values, and a
/// through-the-real-render-pipeline comparison proving an adjustment change
/// actually moves the computed histogram.
final class HistogramComputerTests: XCTestCase {

    // MARK: - Deterministic binning

    private func makeSolidImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) throws -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)
        for pixel in 0..<(width * height) {
            let offset = pixel * bytesPerPixel
            pixelData[offset] = red
            pixelData[offset + 1] = green
            pixelData[offset + 2] = blue
            pixelData[offset + 3] = 255
        }
        let context = try XCTUnwrap(CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    /// Two colored halves in one image, so binning is proven per-pixel, not
    /// just "the first pixel sampled".
    private func makeSplitImage(width: Int, height: Int) throws -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                if x < width / 2 {
                    pixelData[offset] = 200 // red-ish
                    pixelData[offset + 1] = 10
                    pixelData[offset + 2] = 10
                } else {
                    pixelData[offset] = 10
                    pixelData[offset + 1] = 10
                    pixelData[offset + 2] = 200 // blue-ish
                }
                pixelData[offset + 3] = 255
            }
        }
        let context = try XCTUnwrap(CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    func testSolidColorImageSpikesExactlyOneBinPerChannel() throws {
        let image = try makeSolidImage(width: 4, height: 4, red: 255, green: 0, blue: 128)

        let histogram = try XCTUnwrap(HistogramComputer.histogram(for: image))

        XCTAssertEqual(histogram.red[255], 16)
        XCTAssertEqual(histogram.red.reduce(0, +), 16, "every pixel must be counted exactly once")
        XCTAssertEqual(histogram.green[0], 16)
        XCTAssertEqual(histogram.blue[128], 16)
    }

    func testEachPixelIsBinnedIndependentlyNotJustTheFirstPixel() throws {
        // 4x4: left two columns red-ish, right two columns blue-ish -- 8 of each.
        let image = try makeSplitImage(width: 4, height: 4)

        let histogram = try XCTUnwrap(HistogramComputer.histogram(for: image))

        XCTAssertEqual(histogram.red[200], 8)
        XCTAssertEqual(histogram.red[10], 8)
        XCTAssertEqual(histogram.blue[200], 8)
        XCTAssertEqual(histogram.blue[10], 8)
        XCTAssertEqual(histogram.red.reduce(0, +), 16)
        XCTAssertEqual(histogram.blue.reduce(0, +), 16)
    }

    func testEmptyHistogramHasAllZeroBinsAndTheDeclaredBinCount() {
        let empty = HistogramData.empty

        XCTAssertEqual(empty.red.count, HistogramData.binCount)
        XCTAssertEqual(empty.green.count, HistogramData.binCount)
        XCTAssertEqual(empty.blue.count, HistogramData.binCount)
        XCTAssertTrue(empty.red.allSatisfy { $0 == 0 })
        XCTAssertTrue(empty.green.allSatisfy { $0 == 0 })
        XCTAssertTrue(empty.blue.allSatisfy { $0 == 0 })
    }

    // MARK: - Reflects rendered pixels, not fixed raw statistics

    /// Renders the exact same flat-color source photo twice through the real
    /// `CoreImagePreviewRenderer` -- once neutral, once with a strong
    /// exposure boost -- and proves the *computed histogram* moves with the
    /// adjustment. If the histogram were derived from the RAW file's own
    /// fixed metadata (or the original undecoded pixels) instead of the
    /// actual rendered output, this would be a false pass either way; it can
    /// only genuinely pass here because `HistogramComputer` reads whatever
    /// `CGImage` it is handed.
    func testHistogramReflectsPostAdjustmentRenderedPixelsNotFixedRawStatistics() async throws {
        let decoder = FlatColorDecoder(color: CIColor(red: 0.4, green: 0.4, blue: 0.4))
        let renderer = CoreImagePreviewRenderer(decoder: decoder)
        let url = URL(fileURLWithPath: "/tmp/lumaharbor-histogram-test.ARW")

        let neutralRequest = PreviewRequest(
            subject: PreviewSubject(UUID()),
            url: url,
            adjustments: .neutral,
            targetPixelDimension: 32,
            quality: .interactive
        )
        let brightRequest = PreviewRequest(
            subject: PreviewSubject(UUID()),
            url: url,
            adjustments: PhotoAdjustments(exposure: 3.0),
            targetPixelDimension: 32,
            quality: .interactive
        )

        let neutralImage = try await renderer.render(neutralRequest)
        let brightImage = try await renderer.render(brightRequest)

        let neutralHistogram = try XCTUnwrap(HistogramComputer.histogram(for: neutralImage.cgImage))
        let brightHistogram = try XCTUnwrap(HistogramComputer.histogram(for: brightImage.cgImage))

        XCTAssertNotEqual(
            neutralHistogram, brightHistogram,
            "an exposure change on the same source photo must move the computed histogram"
        )
        XCTAssertGreaterThan(
            Self.meanBin(brightHistogram.red), Self.meanBin(neutralHistogram.red),
            "a strong positive exposure boost must shift the histogram toward brighter bins"
        )
    }

    private static func meanBin(_ bins: [Int]) -> Double {
        let total = bins.reduce(0, +)
        guard total > 0 else { return 0 }
        let weightedSum = bins.enumerated().reduce(0) { $0 + $1.offset * $1.element }
        return Double(weightedSum) / Double(total)
    }
}
