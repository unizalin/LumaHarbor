import Foundation
import XCTest
@testable import EditorCore
import Localization
import PhotoLibraryCore
import RawProcessingCore

/// AwayPhotoRawEditor parity Phase 1 Task 1: `EditorMetadataSnapshot` is the
/// view-facing model the Mac editor's metadata/EXIF panel renders. It must
/// format every optional `RawMetadata` field without crashing when metadata
/// is missing, and it must never expose anything beyond the photo's
/// basename -- the plan's own acceptance criteria explicitly forbids leaking
/// a private absolute source path into the UI.
final class EditorMetadataSnapshotTests: XCTestCase {
    private func makePhoto(
        relativePath: String = "IMG_0001.ARW",
        fileSize: Int64 = 24_000_000,
        metadata: RawMetadata = RawMetadata()
    ) -> PhotoAsset {
        PhotoAsset(
            id: PhotoID(),
            libraryID: LibraryID(),
            relativePath: relativePath,
            fingerprint: FileFingerprint(fileSize: fileSize, edgeDigest: "deadbeef"),
            metadata: metadata,
            status: .ready
        )
    }

    func testFilenameIsTheBasenameNeverANestedOrAbsolutePath() {
        let photo = makePhoto(relativePath: "SubFolder/Nested/IMG_0002.ARW")

        let snapshot = EditorMetadataSnapshot(photo: photo)

        XCTAssertEqual(snapshot.filename, "IMG_0002.ARW")
        XCTAssertFalse(snapshot.filename.contains("/"), "the displayed filename must never carry a path separator")
    }

    func testFormatDescriptionIsTheUppercasedExtension() {
        let photo = makePhoto(relativePath: "IMG_0001.arw")

        let snapshot = EditorMetadataSnapshot(photo: photo)

        XCTAssertEqual(snapshot.formatDescription, "ARW")
    }

    func testMissingExtensionFallsBackToUnknownFormat() {
        let photo = makePhoto(relativePath: "IMG_0001")

        let snapshot = EditorMetadataSnapshot(photo: photo)

        // Routed through L10n.t (not a hard-coded literal) since this
        // process's resolved locale is whatever the test machine's system
        // locale happens to be, not necessarily English.
        XCTAssertEqual(snapshot.formatDescription, L10n.t("Unknown"))
    }

    /// Acceptance: "missing EXIF never crashes the editor." A photo with the
    /// default, all-nil `RawMetadata` must produce safe nils throughout, not
    /// a force-unwrap crash or a nonsensical "0 × 0" dimension.
    func testMissingMetadataProducesSafeNilFieldsNotACrash() {
        let photo = makePhoto(metadata: RawMetadata())

        let snapshot = EditorMetadataSnapshot(photo: photo)

        XCTAssertNil(snapshot.pixelDimensions, "pixelWidth/Height default to 0, which must not render as a real dimension")
        XCTAssertNil(snapshot.cameraDescription)
        XCTAssertNil(snapshot.lensDescription)
        XCTAssertNil(snapshot.focalLengthDescription)
        XCTAssertNil(snapshot.apertureDescription)
        XCTAssertNil(snapshot.shutterSpeedDescription)
        XCTAssertNil(snapshot.isoDescription)
        XCTAssertNil(snapshot.captureDateDescription)
        XCTAssertNil(snapshot.orientationDescription)
    }

    func testZeroByteFileSizeIsTreatedAsUnavailableNotZeroBytes() {
        let photo = makePhoto(fileSize: 0)

        let snapshot = EditorMetadataSnapshot(photo: photo)

        XCTAssertNil(snapshot.fileSizeDescription)
    }

    func testFullMetadataFormatsEveryVisibleField() {
        var metadata = RawMetadata()
        metadata.pixelWidth = 6000
        metadata.pixelHeight = 4000
        metadata.cameraMake = "SONY"
        metadata.cameraModel = "ILCE-7M4"
        metadata.lensModel = "FE 24-70mm F2.8 GM"
        metadata.isoSpeed = 400
        metadata.shutterSpeed = 1.0 / 125.0
        metadata.aperture = 2.8
        metadata.focalLengthMillimeters = 50
        metadata.orientation = 1
        metadata.captureDate = Date(timeIntervalSince1970: 1_700_000_000)

        let photo = makePhoto(metadata: metadata)
        let snapshot = EditorMetadataSnapshot(photo: photo)

        XCTAssertEqual(snapshot.pixelDimensions, "6000 × 4000")
        // Sony writes "SONY" into Make and "ILCE-7M4" into Model -- this must
        // route through RawMetadata.cameraDisplayName's own de-duplication,
        // not re-derive camera text independently.
        XCTAssertEqual(snapshot.cameraDescription, "SONY ILCE-7M4")
        XCTAssertEqual(snapshot.lensDescription, "FE 24-70mm F2.8 GM")
        XCTAssertEqual(snapshot.isoDescription, "ISO 400")
        XCTAssertEqual(snapshot.apertureDescription, "f/2.8")
        XCTAssertEqual(snapshot.shutterSpeedDescription, "1/125 s")
        XCTAssertEqual(snapshot.focalLengthDescription, "50 mm")
        XCTAssertEqual(snapshot.orientationDescription, "1")
        XCTAssertNotNil(snapshot.captureDateDescription)
        XCTAssertNotNil(snapshot.fileSizeDescription)
    }

    func testLongExposureShutterSpeedFormatsInWholeSecondsNotAFraction() {
        var metadata = RawMetadata()
        metadata.shutterSpeed = 2.0

        let photo = makePhoto(metadata: metadata)
        let snapshot = EditorMetadataSnapshot(photo: photo)

        XCTAssertEqual(snapshot.shutterSpeedDescription, "2 s")
    }
}
