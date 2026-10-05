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

    func testLocalOptInClipboardCarriesLegacyAndNewBrushCollectionsIndependently() {
        var adjustments = PhotoAdjustments.neutral
        let legacy = LocalAdjustment(kind: .brush)
        let brushMask = BrushMask(name: "new")
        adjustments.localAdjustments = [legacy]
        adjustments.brushMasks = [brushMask]

        let clipboard = PadAdjustmentClipboard.copying(
            from: adjustments,
            fields: [],
            includeGeometry: false,
            includeLocalAdjustments: true
        )

        XCTAssertEqual(clipboard.localAdjustments, [legacy])
        XCTAssertEqual(clipboard.brushMasks, [brushMask])
    }
}
