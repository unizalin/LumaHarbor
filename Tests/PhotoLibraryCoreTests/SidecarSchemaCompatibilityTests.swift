import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Spec §11.1 #1/#2: existing v1/v2 sidecars must keep decoding unchanged as
/// the schema evolves. These fixtures are hand-built JSON strings, not
/// round-tripped through the current encoder, so a test failure here means
/// the on-disk *file format* regressed, not just today's in-memory model.
final class SidecarSchemaCompatibilityTests: XCTestCase {
    func testSchemaV1JSONDecodesWithoutVariantOf() throws {
        let id = PhotoID()
        let sidecar = try SidecarCoding.decode(
            PhotoSidecar.self,
            from: LegacySidecarFixture.schemaV1JSON(photoID: id)
        )
        XCTAssertEqual(sidecar.schemaVersion, 1)
        XCTAssertNil(sidecar.variantOf)
        XCTAssertEqual(sidecar.adjustments.exposure, 1.5)
        XCTAssertEqual(sidecar.sourceRelativePath, "Trip/DSC0001.ARW")
        XCTAssertEqual(sidecar.curation, .neutral, "a v1 sidecar has no curation field; it must decode as neutral, not fail")
    }

    func testSchemaV2JSONDecodesWithVariantOf() throws {
        let id = PhotoID()
        let original = PhotoID()
        let sidecar = try SidecarCoding.decode(
            PhotoSidecar.self,
            from: LegacySidecarFixture.schemaV2JSON(photoID: id, variantOf: original)
        )
        XCTAssertEqual(sidecar.schemaVersion, 2)
        XCTAssertEqual(sidecar.variantOf, original)
        XCTAssertEqual(sidecar.adjustments.exposure, -0.5)
        XCTAssertEqual(sidecar.curation, .neutral, "a v2 sidecar has no curation field; it must decode as neutral, not fail")
    }

    func testSidecarFromNewerSchemaIsRejectedByTheRepositoryNotByBareDecoding() throws {
        // Bare `SidecarCoding.decode` never rejects a newer schema by
        // itself -- only `FileSidecarRepository.loadSidecar` enforces that
        // gate (spec §13 "新版 sidecar" -> "拒絕覆寫，顯示版本不支援"). This
        // pins that division of responsibility so a future change to either
        // layer is caught here.
        let id = PhotoID()
        let sidecar = try SidecarCoding.decode(
            PhotoSidecar.self,
            from: LegacySidecarFixture.newerSchemaJSON(photoID: id, schemaVersion: 99)
        )
        XCTAssertEqual(sidecar.schemaVersion, 99)
        XCTAssertTrue(sidecar.isFromNewerSchema)
    }
}
