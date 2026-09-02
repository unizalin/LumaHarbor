import ImageIO
import XCTest
@testable import RawProcessingCore

/// AwayPhotoRawEditor parity Phase 1 Task 1: the Mac editor's metadata/EXIF
/// panel needs a focal length field `RawMetadata` doesn't carry yet. Since
/// `RawMetadata` is cached in the SQLite index (spec: "old sidecar reading
/// with missing fields must default to neutral values, never crash"), the
/// new field must decode safely from JSON written before it existed.
final class RawMetadataTests: XCTestCase {
    func testDecodingOldJSONWithoutFocalLengthYieldsNilNotACrash() throws {
        let oldJSON = """
        {
            "pixelWidth": 6000,
            "pixelHeight": 4000,
            "cameraMake": "SONY",
            "cameraModel": "ILCE-7M4"
        }
        """.data(using: .utf8)!

        let metadata = try JSONDecoder().decode(RawMetadata.self, from: oldJSON)

        XCTAssertEqual(metadata.pixelWidth, 6000)
        XCTAssertEqual(metadata.cameraMake, "SONY")
        XCTAssertNil(metadata.focalLengthMillimeters, "metadata cached before this field existed must decode as nil")
    }

    func testFocalLengthRoundTripsThroughCodable() throws {
        var metadata = RawMetadata()
        metadata.focalLengthMillimeters = 50

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(RawMetadata.self, from: data)

        XCTAssertEqual(decoded.focalLengthMillimeters, 50)
    }

    func testFromImagePropertiesParsesFocalLengthFromExif() {
        let exif: [CFString: Any] = [
            kCGImagePropertyExifFocalLength: NSNumber(value: 85.0)
        ]
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: exif
        ]

        let metadata = RawMetadata.from(imageProperties: properties)

        XCTAssertEqual(metadata.focalLengthMillimeters, 85.0)
    }

    func testFromImagePropertiesWithoutExifLeavesFocalLengthNil() {
        let metadata = RawMetadata.from(imageProperties: [:])

        XCTAssertNil(metadata.focalLengthMillimeters)
    }
}
