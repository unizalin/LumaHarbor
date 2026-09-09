import XCTest
@testable import AdjustmentUI
import PresetCore
import RawProcessingCore

final class PadAdjustmentClipboardTests: XCTestCase {
    func testCopyIncludesOnlySelectedAdjustmentFieldsAndOptionalSpatialEdits() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.exposure = 1
        adjustments.geometry.rotationDegrees = 90
        adjustments.localAdjustments = [LocalAdjustment(kind: .linearGradient)]

        let clipboard = PadAdjustmentClipboard.copying(
            from: adjustments,
            fields: [.basicExposure],
            includeGeometry: true,
            includeLocalAdjustments: false
        )

        XCTAssertTrue(clipboard.patch.contains(.basicExposure))
        XCTAssertFalse(clipboard.patch.contains(.basicContrast))
        XCTAssertEqual(clipboard.geometry?.rotationDegrees, 90)
        XCTAssertNil(clipboard.localAdjustments)
    }

    func testClipboardNeverCarriesPhotoIdentityOrCatalogMetadata() {
        let clipboard = PadAdjustmentClipboard.copying(
            from: .neutral,
            fields: [],
            includeGeometry: false,
            includeLocalAdjustments: false
        )
        let mirror = Mirror(reflecting: clipboard)
        XCTAssertFalse(mirror.children.contains { $0.label == "photoID" })
        XCTAssertFalse(mirror.children.contains { $0.label == "keyword" })
        XCTAssertFalse(mirror.children.contains { $0.label == "sourceURL" })
    }
}
