import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import RawProcessingCore

/// AwayPhotoRawEditor parity Phase 1 Task 4: single-photo export must
/// support JPEG/PNG/TIFF/HEIC and must never claim a format works when the
/// running platform can't actually encode it (plan: "if a platform cannot
/// encode one format, show disabled/unsupported UI instead of pretending
/// success").
final class ExportFormatTests: XCTestCase {
    func testEveryFormatMapsToItsOwnFileExtension() {
        XCTAssertEqual(ExportFormat.jpeg.fileExtension, "jpg")
        XCTAssertEqual(ExportFormat.png.fileExtension, "png")
        XCTAssertEqual(ExportFormat.tiff.fileExtension, "tiff")
        XCTAssertEqual(ExportFormat.heic.fileExtension, "heic")
    }

    func testEveryFormatMapsToItsOwnUTType() {
        XCTAssertEqual(ExportFormat.jpeg.utTypeIdentifier, UTType.jpeg.identifier)
        XCTAssertEqual(ExportFormat.png.utTypeIdentifier, UTType.png.identifier)
        XCTAssertEqual(ExportFormat.tiff.utTypeIdentifier, UTType.tiff.identifier)
        XCTAssertEqual(ExportFormat.heic.utTypeIdentifier, UTType.heic.identifier)
    }

    /// Quality only means something for the two lossy formats -- PNG and
    /// TIFF are lossless in this foundation version, so a quality slider
    /// bound to either of them would be a lie.
    func testOnlyJPEGAndHEICUseAQualitySlider() {
        XCTAssertTrue(ExportFormat.jpeg.usesQuality)
        XCTAssertTrue(ExportFormat.heic.usesQuality)
        XCTAssertFalse(ExportFormat.png.usesQuality)
        XCTAssertFalse(ExportFormat.tiff.usesQuality)
    }

    /// Spec §6.11 only calls out "TIFF 8-bit / 16-bit" -- JPEG/PNG/HEIC
    /// don't get a bit-depth picker in this foundation version.
    func testOnlyTIFFSupportsABitDepthChoice() {
        XCTAssertTrue(ExportFormat.tiff.supportsBitDepthChoice)
        XCTAssertFalse(ExportFormat.jpeg.supportsBitDepthChoice)
        XCTAssertFalse(ExportFormat.png.supportsBitDepthChoice)
        XCTAssertFalse(ExportFormat.heic.supportsBitDepthChoice)
    }

    func testEveryFormatHasAVisibleDisplayName() {
        for format in ExportFormat.allCases {
            XCTAssertFalse(format.displayName.isEmpty, "\(format)")
        }
    }

    // MARK: - Capability detection

    func testIsSupportedIsTrueWhenTheEncodableSetContainsThisFormatsUTType() {
        let encodable: Set<String> = [UTType.jpeg.identifier, UTType.png.identifier]
        XCTAssertTrue(ExportFormat.jpeg.isSupported(by: encodable))
        XCTAssertTrue(ExportFormat.png.isSupported(by: encodable))
    }

    /// The exact scenario the plan calls out: a platform build with no HEIC
    /// encoder must report HEIC as unsupported, not silently succeed or
    /// silently fail later at write time.
    func testIsSupportedIsFalseWhenTheEncodableSetLacksThisFormatsUTType() {
        let encodable: Set<String> = [UTType.jpeg.identifier, UTType.png.identifier, UTType.tiff.identifier]
        XCTAssertFalse(ExportFormat.heic.isSupported(by: encodable))
    }

    func testIsSupportedDefaultsToTheRealSystemEncoderList() {
        // No fake set injected: this exercises `systemEncodableTypeIdentifiers()`
        // against the real `CGImageDestinationCopyTypeIdentifiers()` on the
        // machine running the test. JPEG/PNG/TIFF have shipped in every
        // ImageIO build since long before this app's deployment target, so
        // this is a safe floor to assert without depending on HEIC hardware.
        XCTAssertTrue(ExportFormat.jpeg.isSupported())
        XCTAssertTrue(ExportFormat.png.isSupported())
        XCTAssertTrue(ExportFormat.tiff.isSupported())
    }
}
