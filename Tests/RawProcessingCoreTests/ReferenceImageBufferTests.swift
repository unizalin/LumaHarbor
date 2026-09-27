import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RawProcessingCore

final class ReferenceImageBufferTests: XCTestCase {
    func testLoadsSixteenBitEmbeddedSRGBTiffWithoutQuantizingSamples() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("reference.tiff")
        try writeSixteenBitSRGBTiff(to: url)

        let buffer = try ReferenceImageBuffer.load(from: url)

        XCTAssertEqual(buffer.width, 2)
        XCTAssertEqual(buffer.height, 1)
        XCTAssertEqual(buffer.bitsPerComponent, 16)
        XCTAssertEqual(buffer.colorSpaceIdentifier, CGColorSpace.sRGB as String)
        XCTAssertTrue(buffer.hasAlpha)
        XCTAssertEqual(buffer.pixels.count, 2)
        XCTAssertEqual(buffer.pixels[0].x, Float(0x1234) / Float(UInt16.max), accuracy: 1.0 / Float(UInt16.max))
        XCTAssertEqual(buffer.pixels[0].y, Float(0x5678) / Float(UInt16.max), accuracy: 1.0 / Float(UInt16.max))
        XCTAssertEqual(buffer.pixels[0].z, Float(0x9ABC) / Float(UInt16.max), accuracy: 1.0 / Float(UInt16.max))
    }

    func testRejectsEightBitTiffBeforeComparison() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("eight-bit.tiff")
        try writeEightBitSRGBTiff(to: url)

        XCTAssertThrowsError(try ReferenceImageBuffer.load(from: url)) { error in
            XCTAssertEqual(error as? ReferenceImageBufferError, .invalidBitDepth(8))
        }
    }

    func testRejectsNonSRGBColorSpace() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("device-rgb.tiff")
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        try writeSixteenBitTiff(to: url, colorSpace: displayP3)

        XCTAssertThrowsError(try ReferenceImageBuffer.load(from: url)) { error in
            XCTAssertEqual(error as? ReferenceImageBufferError, .unsupportedColorSpace)
        }
    }

    func testRejectsNonTiffInput() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("reference.png")
        try Data("not-an-image".utf8).write(to: url)

        XCTAssertThrowsError(try ReferenceImageBuffer.load(from: url)) { error in
            XCTAssertEqual(error as? ReferenceImageBufferError, .unsupportedFormat)
        }
    }

    func testRepeatedLoadsProduceIdenticalMetadataAndSamples() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("reference.tiff")
        try writeSixteenBitSRGBTiff(to: url)

        let first = try ReferenceImageBuffer.load(from: url)
        let second = try ReferenceImageBuffer.load(from: url)

        XCTAssertEqual(first, second)
    }

    private func writeSixteenBitSRGBTiff(to url: URL) throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try writeSixteenBitTiff(to: url, colorSpace: colorSpace)
    }

    private func writeSixteenBitTiff(to url: URL, colorSpace: CGColorSpace) throws {
        var samples: [UInt16] = [
            0x1234, 0x5678, 0x9ABC, UInt16.max,
            UInt16.max, 0x1357, 0x2468, UInt16.max
        ]
        // Encode the fixture from host-order UInt16 values so the reader cannot
        // pass by mirroring the same byte-order mistake on both sides.
        let bitmapInfo = CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(
            data: &samples,
            width: 2,
            height: 1,
            bitsPerComponent: 16,
            bytesPerRow: 2 * 4 * MemoryLayout<UInt16>.size,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        let image = try XCTUnwrap(context.makeImage())
        try write(image: image, to: url)
    }

    private func writeEightBitSRGBTiff(to url: URL) throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var samples: [UInt8] = [32, 96, 160, 255, 255, 64, 128, 255]
        let context = try XCTUnwrap(CGContext(
            data: &samples,
            width: 2,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 2 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        try write(image: image, to: url)
    }

    private func write(image: CGImage, to url: URL) throws {
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
