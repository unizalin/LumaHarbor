import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RawProcessingCore

final class ReferenceComparisonStreamingTests: XCTestCase {
    func testTileReaderPreservesHostEncodedSixteenBitSamples() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("known-samples.tiff")
        try writeSixteenBitSRGBTiff(to: url, width: 2, height: 1)

        let tile = try ReferenceImageTileReader(url: url).tile(startRow: 0, rowCount: 1)

        XCTAssertEqual(tile.rgba16[0], 31)
        XCTAssertEqual(tile.rgba16[1], 5_273)
        XCTAssertEqual(tile.rgba16[2], 10_516)
        XCTAssertEqual(tile.rgba16[3], UInt16.max)
    }

    func testTileReaderReturnsRequestedRowsWithoutChangingEncodedSamples() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tile.tiff")
        try writeSixteenBitSRGBTiff(to: url, width: 4, height: 3)

        let reader = try ReferenceImageTileReader(url: url)
        let tile = try reader.tile(startRow: 1, rowCount: 1)
        let full = try ReferenceImageBuffer.load(from: url)
        let expectedOffset = full.width
        let expected = full.pixels[expectedOffset]

        XCTAssertEqual(tile.originY, 1)
        XCTAssertEqual(tile.width, 4)
        XCTAssertEqual(tile.height, 1)
        XCTAssertEqual(tile.rgba16.count, 16)
        XCTAssertEqual(Float(tile.rgba16[0]) / Float(UInt16.max), expected.x, accuracy: 1.0 / Float(UInt16.max))
        XCTAssertEqual(Float(tile.rgba16[1]) / Float(UInt16.max), expected.y, accuracy: 1.0 / Float(UInt16.max))
        XCTAssertEqual(Float(tile.rgba16[2]) / Float(UInt16.max), expected.z, accuracy: 1.0 / Float(UInt16.max))
        XCTAssertEqual(tile.rgba16[3], UInt16.max)
    }

    func testStreamingMetricsMatchArrayMetricsForDifferentTileHeights() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try (0..<4).map { index in
            let url = directory.appendingPathComponent("image-\(index).tiff")
            try writeSixteenBitSRGBTiff(to: url, width: 19, height: 13, seed: index + 1)
            return url
        }

        let readers = try urls.map(ReferenceImageTileReader.init(url:))
        let buffers = try urls.map { try ReferenceImageBuffer.load(from: $0) }
        let expected = try ReferenceComparisonMetrics.compare(
            width: 19,
            height: 13,
            lrNeutral: buffers[0].pixels,
            lrPreset: buffers[1].pixels,
            lhNeutral: buffers[2].pixels,
            lhPreset: buffers[3].pixels
        )

        for tileHeight in [1, 4, 7] {
            let actual = try ReferenceComparisonMetrics.compareStreaming(
                mode: .presetEffect,
                lrNeutral: readers[0],
                lrPreset: readers[1],
                lhNeutral: readers[2],
                lhPreset: readers[3],
                tileHeight: tileHeight
            )
            XCTAssertEqual(actual.meanAbsoluteError, expected.meanAbsoluteError, accuracy: 1e-9)
            XCTAssertEqual(actual.p95AbsoluteError, expected.p95AbsoluteError, accuracy: 1e-9)
            XCTAssertEqual(actual.luminanceSSIM, expected.luminanceSSIM, accuracy: 1e-9)
            XCTAssertEqual(actual.highlightClippingFractionDelta, expected.highlightClippingFractionDelta, accuracy: 1e-9)
            XCTAssertEqual(actual.shadowClippingFractionDelta, expected.shadowClippingFractionDelta, accuracy: 1e-9)
        }
    }

    private func writeSixteenBitSRGBTiff(
        to url: URL,
        width: Int,
        height: Int,
        seed: Int = 1
    ) throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var samples = [UInt16](repeating: 0, count: width * height * 4)
        for pixel in 0..<(width * height) {
            let base = UInt16((pixel * 17 + seed * 31) % 65_000)
            samples[pixel * 4] = base
            samples[pixel * 4 + 1] = min(UInt16.max, base + 5_242)
            samples[pixel * 4 + 2] = min(UInt16.max, base + 10_485)
            samples[pixel * 4 + 3] = UInt16.max
        }
        let bitmapInfo = CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(
            data: &samples,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: width * 4 * MemoryLayout<UInt16>.size,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.tiff.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
