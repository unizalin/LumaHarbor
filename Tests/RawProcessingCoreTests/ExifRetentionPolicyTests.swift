import Foundation
import XCTest
@testable import RawProcessingCore

/// AwayPhotoRawEditor parity Phase 1 Task 4: EXIF retention policy for
/// single-photo export -- preserve, remove, or partially strip metadata
/// before it reaches the exported file. Pure `RawMetadata -> RawMetadata`
/// transform, so it's testable with no decoder, no CGImageDestination, and
/// no real file.
final class ExifRetentionPolicyTests: XCTestCase {
    private let fullMetadata = RawMetadata(
        pixelWidth: 6_000,
        pixelHeight: 4_000,
        captureDate: Date(timeIntervalSince1970: 1_700_000_000),
        cameraMake: "SONY",
        cameraModel: "ILCE-7M4",
        lensModel: "FE 24-70mm F2.8 GM",
        isoSpeed: 400,
        shutterSpeed: 1.0 / 250,
        aperture: 4.0,
        orientation: 1,
        focalLengthMillimeters: 50
    )

    func testPreserveAllReturnsEveryFieldUnchanged() {
        let result = ExifRetentionPolicy.preserveAll.apply(to: fullMetadata)
        XCTAssertEqual(result, fullMetadata)
    }

    /// Pixel dimensions are never metadata the user is trying to strip --
    /// they're what the file *is* -- so they survive even `.removeAll`.
    func testRemoveAllKeepsOnlyPixelDimensions() {
        let result = ExifRetentionPolicy.removeAll.apply(to: fullMetadata)
        XCTAssertEqual(result.pixelWidth, fullMetadata.pixelWidth)
        XCTAssertEqual(result.pixelHeight, fullMetadata.pixelHeight)
        XCTAssertNil(result.captureDate)
        XCTAssertNil(result.cameraMake)
        XCTAssertNil(result.cameraModel)
        XCTAssertNil(result.lensModel)
        XCTAssertNil(result.isoSpeed)
        XCTAssertNil(result.shutterSpeed)
        XCTAssertNil(result.aperture)
        XCTAssertNil(result.orientation)
        XCTAssertNil(result.focalLengthMillimeters)
    }

    /// Partial: strips what's traceable to *when and with what* the photo
    /// was taken (capture date, camera, lens) while keeping the generic
    /// exposure/technical fields (ISO, shutter, aperture, focal length,
    /// orientation) -- a defensible reading of the design spec's "partial"
    /// EXIF policy given that `RawMetadata` has no GPS field to strip.
    func testPartialStripsCaptureDateAndCameraIdentityButKeepsExposureFields() {
        let result = ExifRetentionPolicy.partial.apply(to: fullMetadata)
        XCTAssertNil(result.captureDate)
        XCTAssertNil(result.cameraMake)
        XCTAssertNil(result.cameraModel)
        XCTAssertNil(result.lensModel)
        XCTAssertEqual(result.isoSpeed, fullMetadata.isoSpeed)
        XCTAssertEqual(result.shutterSpeed, fullMetadata.shutterSpeed)
        XCTAssertEqual(result.aperture, fullMetadata.aperture)
        XCTAssertEqual(result.focalLengthMillimeters, fullMetadata.focalLengthMillimeters)
        XCTAssertEqual(result.orientation, fullMetadata.orientation)
        XCTAssertEqual(result.pixelWidth, fullMetadata.pixelWidth)
        XCTAssertEqual(result.pixelHeight, fullMetadata.pixelHeight)
    }

    func testApplyingToAlreadyEmptyMetadataNeverCrashes() {
        let empty = RawMetadata()
        for policy in ExifRetentionPolicy.allCases {
            let result = policy.apply(to: empty)
            XCTAssertEqual(result.pixelWidth, 0, "\(policy)")
        }
    }

    func testEveryPolicyHasAVisibleDisplayName() {
        for policy in ExifRetentionPolicy.allCases {
            XCTAssertFalse(policy.displayName.isEmpty, "\(policy)")
        }
    }
}
