import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RawProcessingCore

final class ReferenceImageMetadataValidatorTests: XCTestCase {
    func testValidatesSixteenBitEmbeddedSRGBDimensionsAndAlpha() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("valid.tiff")
        try writeSixteenBitSRGBTiff(to: url, width: 2, height: 1)

        let metadata = try ReferenceImageMetadataValidator.validate(
            imageAt: url,
            against: ReferenceImageMetadataExpectation(
                width: 2,
                height: 1,
                bitsPerComponent: 16,
                colorSpaceIdentifier: CGColorSpace.sRGB as String,
                hasAlpha: true
            )
        )

        XCTAssertEqual(metadata.width, 2)
        XCTAssertEqual(metadata.height, 1)
        XCTAssertEqual(metadata.bitsPerComponent, 16)
        XCTAssertEqual(metadata.colorSpaceIdentifier, CGColorSpace.sRGB as String)
        XCTAssertEqual(metadata.profileName, "sRGB IEC61966-2.1")
        XCTAssertTrue(metadata.hasAlpha)
    }

    func testRejectsBitDepthMismatch() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("eight-bit.tiff")
        try writeEightBitSRGBTiff(to: url)

        XCTAssertThrowsError(try ReferenceImageMetadataValidator.validate(
            imageAt: url,
            against: ReferenceImageMetadataExpectation(
                width: 2,
                height: 1,
                bitsPerComponent: 16,
                colorSpaceIdentifier: CGColorSpace.sRGB as String,
                hasAlpha: true
            )
        )) { error in
            XCTAssertEqual(error as? ReferenceImageMetadataValidationError, .invalidBitDepth)
        }
    }

    func testRejectsDimensionsAndColorSpaceMismatch() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("valid.tiff")
        try writeSixteenBitSRGBTiff(to: url, width: 2, height: 1)

        XCTAssertThrowsError(try ReferenceImageMetadataValidator.validate(
            imageAt: url,
            against: ReferenceImageMetadataExpectation(
                width: 3,
                height: 1,
                bitsPerComponent: 16,
                colorSpaceIdentifier: CGColorSpace.sRGB as String,
                hasAlpha: true
            )
        )) { error in
            XCTAssertEqual(error as? ReferenceImageMetadataValidationError, .dimensionMismatch)
        }

        XCTAssertThrowsError(try ReferenceImageMetadataValidator.validate(
            imageAt: url,
            against: ReferenceImageMetadataExpectation(
                width: 2,
                height: 1,
                bitsPerComponent: 16,
                colorSpaceIdentifier: "Display P3",
                hasAlpha: true
            )
        )) { error in
            XCTAssertEqual(error as? ReferenceImageMetadataValidationError, .colorSpaceMismatch)
        }
    }

    func testRejectsMissingReferenceWithoutExposingPath() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        XCTAssertThrowsError(try ReferenceImageMetadataValidator.validate(
            imageAt: url,
            against: ReferenceImageMetadataExpectation(
                width: 1,
                height: 1,
                bitsPerComponent: 16,
                colorSpaceIdentifier: CGColorSpace.sRGB as String,
                hasAlpha: true
            )
        )) { error in
            XCTAssertEqual(error as? ReferenceImageMetadataValidationError, .invalidSource)
            XCTAssertFalse(String(describing: error).contains(url.path))
        }
    }

    private func writeSixteenBitSRGBTiff(to url: URL, width: Int, height: Int) throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var samples = [UInt16](repeating: UInt16.max, count: width * height * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder16Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(
            data: &samples,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: width * 4 * MemoryLayout<UInt16>.size,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        try write(image: XCTUnwrap(context.makeImage()), to: url)
    }

    private func writeEightBitSRGBTiff(to url: URL) throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var samples = [UInt8](repeating: 255, count: 2 * 4)
        let context = try XCTUnwrap(CGContext(
            data: &samples,
            width: 2,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 2 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        try write(image: XCTUnwrap(context.makeImage()), to: url)
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
