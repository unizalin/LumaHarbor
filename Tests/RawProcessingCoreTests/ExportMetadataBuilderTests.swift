import Foundation
import ImageIO
import XCTest
@testable import RawProcessingCore

/// AwayPhotoRawEditor parity Phase 1 Task 4: builds the ImageIO properties
/// dictionary an exported file's EXIF/TIFF block is written from. Pure and
/// offline-testable against a literal `RawMetadata`, mirroring the existing
/// `RawMetadata.from(imageProperties:)` decode-side test pattern in reverse.
final class ExportMetadataBuilderTests: XCTestCase {
    func testEmptyMetadataProducesAnEmptyPropertiesDictionary() {
        let properties = ExportMetadataBuilder.imageProperties(from: RawMetadata())
        XCTAssertTrue(properties.isEmpty)
    }

    func testCameraAndModelLandInTheTIFFDictionary() throws {
        let metadata = RawMetadata(cameraMake: "SONY", cameraModel: "ILCE-7M4")
        let properties = ExportMetadataBuilder.imageProperties(from: metadata)

        let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "SONY")
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "ILCE-7M4")
    }

    func testExposureFieldsLandInTheExifDictionary() throws {
        let metadata = RawMetadata(isoSpeed: 400, shutterSpeed: 0.004, aperture: 4.0, focalLengthMillimeters: 50)
        let properties = ExportMetadataBuilder.imageProperties(from: metadata)

        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual((exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue, 400)
        XCTAssertEqual(exif[kCGImagePropertyExifExposureTime] as? Double, 0.004)
        XCTAssertEqual(exif[kCGImagePropertyExifFNumber] as? Double, 4.0)
        XCTAssertEqual(exif[kCGImagePropertyExifFocalLength] as? Double, 50)
    }

    func testOrientationLandsAtTheTopLevel() {
        let metadata = RawMetadata(orientation: 6)
        let properties = ExportMetadataBuilder.imageProperties(from: metadata)
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6)
    }

    /// Round-trips through `RawMetadata.from(imageProperties:)` -- the
    /// decode-side parser this codebase already ships -- as a cheap sanity
    /// check that the two sides agree on the same key shapes.
    func testRoundTripsThroughTheExistingDecodeSideParser() {
        let original = RawMetadata(
            cameraMake: "SONY", cameraModel: "ILCE-7M4", lensModel: "FE 24-70mm F2.8 GM",
            isoSpeed: 400, shutterSpeed: 0.004, aperture: 4.0, focalLengthMillimeters: 50
        )
        let properties = ExportMetadataBuilder.imageProperties(from: original)
        let roundTripped = RawMetadata.from(imageProperties: properties)

        XCTAssertEqual(roundTripped.cameraMake, original.cameraMake)
        XCTAssertEqual(roundTripped.cameraModel, original.cameraModel)
        XCTAssertEqual(roundTripped.lensModel, original.lensModel)
        XCTAssertEqual(roundTripped.isoSpeed, original.isoSpeed)
        XCTAssertEqual(roundTripped.shutterSpeed, original.shutterSpeed)
        XCTAssertEqual(roundTripped.aperture, original.aperture)
        XCTAssertEqual(roundTripped.focalLengthMillimeters, original.focalLengthMillimeters)
    }
}
