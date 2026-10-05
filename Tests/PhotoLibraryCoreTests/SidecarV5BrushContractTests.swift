import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

final class SidecarV5BrushContractTests: TemporaryDirectoryTestCase {
    private var repository: FileSidecarRepository!
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try makeSubdirectory("Photos")
        repository = FileSidecarRepository(libraryRootURL: root)
    }

    private func sidecar(photoID: PhotoID = PhotoID()) -> PhotoSidecar {
        PhotoSidecar(
            photoID: photoID,
            sourceRelativePath: "RAW/image.ARW",
            sourceFingerprint: .stub("edge"),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    func testCurrentSchemaIsV5AndBrushMasksRoundTrip() throws {
        XCTAssertEqual(PhotoSidecar.currentSchemaVersion, 5)
        let stroke = BrushMaskStroke(path: BrushMaskPath(points: [BrushMaskPoint(x: 0.1, y: 0.2)]))
        var adjustments = PhotoAdjustments.neutral
        adjustments.brushMasks = [BrushMask(strokes: [stroke], adjustments: BrushMaskPatch(exposure: 1))]
        let original = sidecar().updating(
            adjustments: adjustments,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try repository.write(sidecar: original)
        let loaded = try XCTUnwrap(try repository.loadSidecar(for: original.photoID))
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded.adjustments.brushMasks.count, 1)
    }

    func testV1ThroughV4MissingBrushMasksDecodeAsEmpty() throws {
        for version in 1...4 {
            let original = sidecar()
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: SidecarCoding.encode(original)) as? [String: Any])
            var legacy = object
            legacy["schemaVersion"] = version
            var adjustments = try XCTUnwrap(legacy["adjustments"] as? [String: Any])
            adjustments.removeValue(forKey: "brushMasks")
            legacy["adjustments"] = adjustments
            let data = try JSONSerialization.data(withJSONObject: legacy)
            let decoded = try SidecarCoding.decode(PhotoSidecar.self, from: data)
            XCTAssertTrue(decoded.adjustments.brushMasks.isEmpty, "v\(version)")
        }
    }

    func testNoOpLoadDoesNotUpgradeLegacyBytesOrModificationDate() throws {
        let original = sidecar()
        let url = repository.sidecarURL(for: original.photoID)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: SidecarCoding.encode(original)) as? [String: Any]
        )
        object["schemaVersion"] = 4
        var adjustments = try XCTUnwrap(object["adjustments"] as? [String: Any])
        adjustments.removeValue(forKey: "brushMasks")
        object["adjustments"] = adjustments
        let legacyBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try writeFile(legacyBytes, at: url)
        let fixedDate = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)

        XCTAssertNotNil(try repository.loadSidecar(for: original.photoID))
        XCTAssertEqual(try Data(contentsOf: url), legacyBytes)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
            fixedDate
        )
    }

    func testValidEditUpgradesLegacySidecarAtSaveBoundary() throws {
        let original = sidecar()
        let url = repository.sidecarURL(for: original.photoID)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: SidecarCoding.encode(original)) as? [String: Any]
        )
        object["schemaVersion"] = 4
        let legacyBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try writeFile(legacyBytes, at: url)

        let loaded = try XCTUnwrap(try repository.loadSidecar(for: original.photoID))
        try repository.write(sidecar: loaded.updating(adjustments: .neutral.setting(.exposure, to: 1)))
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(persisted["schemaVersion"] as? Int, PhotoSidecar.currentSchemaVersion)
    }

    func testNewerSchemaPreservesBytesAndModificationDate() throws {
        let original = sidecar()
        let url = repository.sidecarURL(for: original.photoID)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: SidecarCoding.encode(original)) as? [String: Any])
        var newer = object
        newer["schemaVersion"] = 6
        let bytes = try JSONSerialization.data(withJSONObject: newer, options: [.sortedKeys])
        try writeFile(bytes, at: url)
        let before = try Data(contentsOf: url)
        let beforeDate = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertThrowsError(try repository.loadSidecar(for: original.photoID))
        XCTAssertEqual(try Data(contentsOf: url), before)
        let afterDate = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(afterDate, beforeDate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testDeletingLastSnapshotRemovesKnownKeyAndUnknownKeysSurvive() throws {
        let original = sidecar()
        let url = repository.sidecarURL(for: original.photoID)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: SidecarCoding.encode(original.updating(snapshots: [EditSnapshot(name: "one", adjustments: .neutral)]))) as? [String: Any])
        object["vendorState"] = ["opaque": true]
        try writeFile(try JSONSerialization.data(withJSONObject: object), at: url)
        let loaded = try XCTUnwrap(try repository.loadSidecar(for: original.photoID))
        try repository.write(sidecar: loaded.updating(snapshots: []))
        let reopened = try XCTUnwrap(try repository.loadSidecar(for: original.photoID))
        XCTAssertTrue(reopened.snapshots.isEmpty)
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNil(persisted["snapshots"])
        XCTAssertNotNil(persisted["vendorState"])
    }
}
