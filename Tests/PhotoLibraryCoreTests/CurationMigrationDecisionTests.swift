import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Pure, no-I/O tests for the exact migration state machine defined in
/// `docs/superpowers/plans/2026-09-10-curation-sidecar-v3-and-migration.md`
/// (gap G1). `CurationMigration.decide` is the single place this repository
/// resolves a conflict between a sidecar's curation and SQLite's cached
/// projection of it.
final class CurationMigrationDecisionTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSidecar(
        photoID: PhotoID = PhotoID(),
        schemaVersion: Int = PhotoSidecar.currentSchemaVersion,
        adjustments: PhotoAdjustments = .neutral,
        curation: PhotoCuration = .neutral
    ) -> PhotoSidecar {
        PhotoSidecar(
            schemaVersion: schemaVersion,
            photoID: photoID,
            sourceRelativePath: "Trip/DSC0001.ARW",
            sourceFingerprint: .stub("abc"),
            adjustments: adjustments,
            curation: curation,
            createdAt: fixedNow,
            modifiedAt: fixedNow
        )
    }

    // Row 1: v3 sidecar always wins, even when SQLite disagrees.
    func testSchemaV3SidecarWinsEvenWhenSQLiteDisagrees() {
        let sidecar = makeSidecar(curation: PhotoCuration(rating: 2))
        let decision = CurationMigration.decide(
            existingSidecar: sidecar,
            existingSQLiteCuration: PhotoCuration(rating: 5, flag: .pick),
            photoID: sidecar.photoID,
            sourceRelativePath: sidecar.sourceRelativePath,
            sourceFingerprint: sidecar.sourceFingerprint,
            decoder: sidecar.decoder,
            now: fixedNow
        )
        XCTAssertEqual(decision, .sidecarAuthoritative(PhotoCuration(rating: 2)))
    }

    func testSchemaV3SidecarWithNeutralCurationWinsOverNonNeutralSQLite() {
        let sidecar = makeSidecar(curation: .neutral)
        let decision = CurationMigration.decide(
            existingSidecar: sidecar,
            existingSQLiteCuration: PhotoCuration(rating: 5),
            photoID: sidecar.photoID,
            sourceRelativePath: sidecar.sourceRelativePath,
            sourceFingerprint: sidecar.sourceFingerprint,
            decoder: sidecar.decoder,
            now: fixedNow
        )
        XCTAssertEqual(decision, .sidecarAuthoritative(.neutral))
    }

    // Row 2: legacy sidecar, nothing worth migrating.
    func testLegacySidecarWithNilSQLiteCurationIsUnchanged() {
        let legacy = makeSidecar(schemaVersion: 2)
        let decision = CurationMigration.decide(
            existingSidecar: legacy,
            existingSQLiteCuration: nil,
            photoID: legacy.photoID,
            sourceRelativePath: legacy.sourceRelativePath,
            sourceFingerprint: legacy.sourceFingerprint,
            decoder: legacy.decoder,
            now: fixedNow
        )
        XCTAssertEqual(decision, .unchanged(.neutral))
    }

    func testLegacySidecarWithNeutralSQLiteCurationIsUnchanged() {
        let legacy = makeSidecar(schemaVersion: 1)
        let decision = CurationMigration.decide(
            existingSidecar: legacy,
            existingSQLiteCuration: .neutral,
            photoID: legacy.photoID,
            sourceRelativePath: legacy.sourceRelativePath,
            sourceFingerprint: legacy.sourceFingerprint,
            decoder: legacy.decoder,
            now: fixedNow
        )
        XCTAssertEqual(decision, .unchanged(.neutral))
    }

    // Row 3: legacy sidecar, non-neutral SQLite -> migrate, preserving the
    // sidecar's own adjustments/createdAt/decoder/variantOf untouched.
    func testLegacySidecarWithNonNeutralSQLiteMigratesPreservingAdjustments() {
        let legacy = makeSidecar(schemaVersion: 2, adjustments: PhotoAdjustments(exposure: 1.0))
        let decision = CurationMigration.decide(
            existingSidecar: legacy,
            existingSQLiteCuration: PhotoCuration(rating: 3, flag: .reject),
            photoID: legacy.photoID,
            sourceRelativePath: legacy.sourceRelativePath,
            sourceFingerprint: legacy.sourceFingerprint,
            decoder: legacy.decoder,
            now: fixedNow
        )
        guard case .migrate(let migrated, let curation) = decision else {
            return XCTFail("expected .migrate, got \(decision)")
        }
        XCTAssertEqual(migrated.schemaVersion, PhotoSidecar.currentSchemaVersion)
        XCTAssertEqual(migrated.adjustments, legacy.adjustments)
        XCTAssertEqual(migrated.createdAt, legacy.createdAt)
        XCTAssertEqual(migrated.photoID, legacy.photoID)
        XCTAssertEqual(curation, PhotoCuration(rating: 3, flag: .reject))
        XCTAssertEqual(migrated.curation, curation)
    }

    // Row 4: no sidecar, no SQLite curation -> unchanged neutral.
    func testNoSidecarNoSQLiteCurationIsUnchangedNeutral() {
        let decision = CurationMigration.decide(
            existingSidecar: nil,
            existingSQLiteCuration: nil,
            photoID: PhotoID(),
            sourceRelativePath: "Trip/DSC0009.ARW",
            sourceFingerprint: .stub("xyz"),
            decoder: .coreImageDefault,
            now: fixedNow
        )
        XCTAssertEqual(decision, .unchanged(.neutral))
    }

    func testNoSidecarNeutralSQLiteCurationIsUnchangedNeutral() {
        let decision = CurationMigration.decide(
            existingSidecar: nil,
            existingSQLiteCuration: .neutral,
            photoID: PhotoID(),
            sourceRelativePath: "Trip/DSC0009.ARW",
            sourceFingerprint: .stub("xyz"),
            decoder: .coreImageDefault,
            now: fixedNow
        )
        XCTAssertEqual(decision, .unchanged(.neutral))
    }

    // Row 5: no sidecar, non-neutral SQLite -> create a brand-new v3
    // sidecar with neutral adjustments, never requiring a prior edit.
    func testNoSidecarNonNeutralSQLiteCreatesNewSidecarWithNeutralAdjustments() {
        let photoID = PhotoID()
        let decision = CurationMigration.decide(
            existingSidecar: nil,
            existingSQLiteCuration: PhotoCuration(rating: 5),
            photoID: photoID,
            sourceRelativePath: "Trip/DSC0009.ARW",
            sourceFingerprint: .stub("xyz"),
            decoder: .coreImageDefault,
            now: fixedNow
        )
        guard case .migrate(let created, let curation) = decision else {
            return XCTFail("expected .migrate, got \(decision)")
        }
        XCTAssertEqual(created.adjustments, .neutral)
        XCTAssertEqual(created.schemaVersion, PhotoSidecar.currentSchemaVersion)
        XCTAssertEqual(created.photoID, photoID)
        XCTAssertEqual(created.sourceRelativePath, "Trip/DSC0009.ARW")
        XCTAssertEqual(created.createdAt, fixedNow)
        XCTAssertEqual(curation, PhotoCuration(rating: 5))
    }
}
