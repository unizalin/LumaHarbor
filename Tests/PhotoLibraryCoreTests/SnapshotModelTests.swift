import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

final class SnapshotModelTests: XCTestCase {
    func testSnapshotModelInitializationAndNameDefault() {
        let snapshotWithDefaultName = EditSnapshot(
            name: "   ",
            adjustments: .neutral
        )
        XCTAssertEqual(snapshotWithDefaultName.name, "Snapshot")

        let customSnapshot = EditSnapshot(
            name: "B&W High Contrast",
            adjustments: .neutral
        )
        XCTAssertEqual(customSnapshot.name, "B&W High Contrast")
        XCTAssertNotNil(customSnapshot.id)
    }

    func testSnapshotCodableRoundTrip() throws {
        var adjustments = PhotoAdjustments.neutral
        adjustments.exposure = 1.25
        adjustments.contrast = 25
        adjustments.temperature = 25
        adjustments.tint = 12

        let id = UUID()
        let now = Date(timeIntervalSince1970: 1726000000)
        let original = EditSnapshot(
            id: id,
            name: "Sunset Warmth",
            adjustments: adjustments,
            createdAt: now
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(EditSnapshot.self, from: data)

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.name, "Sunset Warmth")
        XCTAssertEqual(decoded.adjustments.exposure, 1.25)
        XCTAssertEqual(decoded.adjustments.contrast, 25)
        XCTAssertEqual(decoded.adjustments.temperature, 25)
        XCTAssertEqual(decoded.adjustments.tint, 12)
        XCTAssertEqual(decoded.createdAt, now)
    }

    func testPhotoSidecarV4RoundTripWithSnapshots() throws {
        let photoID = PhotoID()
        let snapshot1 = EditSnapshot(name: "Version 1", adjustments: .neutral)
        var adj2 = PhotoAdjustments.neutral
        adj2.exposure = -0.75
        let snapshot2 = EditSnapshot(name: "Version 2 Moody", adjustments: adj2)

        let sidecar = PhotoSidecar(
            photoID: photoID,
            sourceRelativePath: "RAW/DSC_1234.NEF",
            sourceFingerprint: FileFingerprint(fileSize: 1024, edgeDigest: "abc"),
            snapshots: [snapshot1, snapshot2]
        )

        XCTAssertEqual(sidecar.schemaVersion, 4)
        XCTAssertEqual(sidecar.snapshots.count, 2)

        let encoded = try SidecarCoding.encode(sidecar)
        let decoded = try SidecarCoding.decode(PhotoSidecar.self, from: encoded)

        XCTAssertEqual(decoded.schemaVersion, 4)
        XCTAssertEqual(decoded.photoID, photoID)
        XCTAssertEqual(decoded.snapshots.count, 2)
        XCTAssertEqual(decoded.snapshots[0].name, "Version 1")
        XCTAssertEqual(decoded.snapshots[1].name, "Version 2 Moody")
        XCTAssertEqual(decoded.snapshots[1].adjustments.exposure, -0.75)
    }

    func testPhotoSidecarUpdatingSnapshots() {
        let photoID = PhotoID()
        let sidecar = PhotoSidecar(
            photoID: photoID,
            sourceRelativePath: "RAW/DSC_1234.NEF",
            sourceFingerprint: FileFingerprint(fileSize: 1024, edgeDigest: "abc")
        )
        XCTAssertTrue(sidecar.snapshots.isEmpty)

        let newSnapshot = EditSnapshot(name: "Test", adjustments: .neutral)
        let updated = sidecar.updating(snapshots: [newSnapshot])

        XCTAssertEqual(updated.snapshots.count, 1)
        XCTAssertEqual(updated.snapshots.first?.name, "Test")
    }
}
