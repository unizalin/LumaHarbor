import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Spec §11.1 #4 and the design's §3 "已驗證現況" gap: rating/flag/keyword
/// must survive a deleted-and-rebuilt local SQLite index. This file starts
/// (Task 0, P0) by pinning today's known gap as an explicit, named baseline;
/// Task 5 (P1) then flips these same assertions once the sidecar becomes the
/// curation authority, so the diff is a reviewable, intentional behavior
/// change rather than a silently rewritten test.
final class CurationDurabilityTests: TemporaryDirectoryTestCase {
    private func makeService(supportName: String = "ApplicationSupport") throws -> PhotoLibraryService {
        let supportDirectory = try makeSubdirectory(supportName)
        return try PhotoLibraryService(
            locations: ApplicationSupportLocations(baseURL: supportDirectory),
            resourceIdentityResolver: SystemResourceIdentityResolver()
        )
    }

    private func addLibrary(_ service: PhotoLibraryService, at url: URL) async throws -> LibraryFolder {
        do {
            return try await service.addLibrary(at: url, displayName: nil, sourceKind: .externalFolder)
        } catch let error as LibraryError {
            if case .bookmark = error {
                throw XCTSkip("This host can't create security-scoped bookmarks: \(error)")
            }
            throw error
        }
    }

    @discardableResult
    private func runScan(_ service: PhotoLibraryService, libraryID: LibraryID) async throws -> LibraryScanResult {
        var result: LibraryScanResult?
        for await event in service.scan(libraryID: libraryID) {
            if case .finished(let scanResult) = event { result = scanResult }
        }
        return try XCTUnwrap(result)
    }

    private func makeLibraryWithOnePhoto() async throws -> (service: PhotoLibraryService, libraryID: LibraryID, photoID: PhotoID, root: URL) {
        let service = try makeService()
        let photosRoot = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: photosRoot.appendingPathComponent("DSC0001.ARW"))
        let library = try await addLibrary(service, at: photosRoot)
        try await runScan(service, libraryID: library.id)
        let seeded = try await service.photos(inLibrary: library.id)
        let photo = try XCTUnwrap(seeded.first)
        return (service, library.id, photo.id, photosRoot)
    }

    /// Task 5 (P1): flips the Task 0 (P0) baseline. Rating/flag/keywords set
    /// through the legacy SQLite-only API (what `LibraryViewModel` called
    /// directly before Task 6 of this plan) must now migrate onto a schema
    /// v3 sidecar on the very next scan, and therefore survive a full index
    /// rebuild -- unlike the pre-Task-5 gap this same test used to document.
    func testIndexRebuildRestoresRatingFlagAndKeywordsFromSidecar() async throws {
        let (service, libraryID, photoID, root) = try await makeLibraryWithOnePhoto()
        let indexStore = await service.indexStore
        try indexStore.setRating(5, for: photoID)
        try indexStore.setFlag(.pick, for: photoID)
        try indexStore.setKeywords(["Sunset"], for: photoID)

        // The migration itself happens on a scan, before any reset.
        try await runScan(service, libraryID: libraryID)
        let sidecarAfterMigration = try FileSidecarRepository(libraryRootURL: root).loadSidecar(for: photoID)
        XCTAssertEqual(sidecarAfterMigration?.schemaVersion, PhotoSidecar.currentSchemaVersion)
        XCTAssertEqual(sidecarAfterMigration?.curation.rating, 5)

        try await service.resetRebuildableLocalData()
        try await runScan(service, libraryID: libraryID)

        let photo = try await service.indexStore.photo(id: photoID)
        XCTAssertEqual(photo?.rating, 5)
        XCTAssertEqual(photo?.flag, PhotoFlag.pick)
        XCTAssertEqual(photo?.keywords.map(\.displayValue), ["Sunset"])
        XCTAssertEqual(photo?.curationMigrationPending, false)
    }

    func testLegacySQLiteOnlyCurationMigratesOnNextScanWithoutARebuild() async throws {
        let (service, libraryID, photoID, root) = try await makeLibraryWithOnePhoto()
        let indexStore = await service.indexStore
        try indexStore.setRating(4, for: photoID)

        try await runScan(service, libraryID: libraryID)

        let photo = try await service.indexStore.photo(id: photoID)
        XCTAssertEqual(photo?.rating, 4)
        XCTAssertEqual(photo?.curationMigrationPending, false)
        let sidecar = try FileSidecarRepository(libraryRootURL: root).loadSidecar(for: photoID)
        XCTAssertEqual(sidecar?.schemaVersion, PhotoSidecar.currentSchemaVersion)
        XCTAssertEqual(sidecar?.curation.rating, 4)
    }

    func testReadOnlySourceKeepsSQLiteValuesAndMarksPendingThenRetriesAfterReconnect() async throws {
        guard canSimulateReadOnlyDirectory else {
            throw XCTSkip("Running as root; read-only simulation is meaningless.")
        }
        let (service, libraryID, photoID, root) = try await makeLibraryWithOnePhoto()
        let indexStore = await service.indexStore
        try indexStore.setRating(3, for: photoID)

        try setPosixPermissions(0o555, at: root)
        try await runScan(service, libraryID: libraryID)

        var photo = try await service.indexStore.photo(id: photoID)
        XCTAssertEqual(photo?.rating, 3, "old SQLite value must never be lost while the sidecar can't be written")
        XCTAssertEqual(photo?.curationMigrationPending, true)
        XCTAssertNil(
            try? FileSidecarRepository(libraryRootURL: root).loadSidecar(for: photoID),
            "a read-only source must not end up with a half-written sidecar"
        )

        try setPosixPermissions(0o755, at: root)
        try await runScan(service, libraryID: libraryID)

        photo = try await service.indexStore.photo(id: photoID)
        XCTAssertEqual(photo?.rating, 3)
        XCTAssertEqual(photo?.curationMigrationPending, false)
        let sidecar = try FileSidecarRepository(libraryRootURL: root).loadSidecar(for: photoID)
        XCTAssertEqual(sidecar?.schemaVersion, PhotoSidecar.currentSchemaVersion)
        XCTAssertEqual(sidecar?.curation.rating, 3)
    }
}
