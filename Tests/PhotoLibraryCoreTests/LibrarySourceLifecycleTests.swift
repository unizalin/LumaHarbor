import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Spec §7: source identity, overlap rejection and removal safety exercised
/// end-to-end through `PhotoLibraryService`, plus the Task 1 handoff item —
/// `saveAdjustments`/rescan projecting `lastEditAt`, not just `hasEdits`.
final class LibrarySourceLifecycleTests: TemporaryDirectoryTestCase {
    private func makeService(supportName: String = "ApplicationSupport") throws -> PhotoLibraryService {
        let supportDirectory = try makeSubdirectory(supportName)
        return try PhotoLibraryService(locations: ApplicationSupportLocations(baseURL: supportDirectory))
    }

    /// Adding a library needs a real security-scoped bookmark. If the host
    /// refuses to mint one, skip rather than report a false failure — the
    /// same accommodation `LibraryLifecycleTests` makes.
    private func addLibrary(
        _ service: PhotoLibraryService,
        at url: URL,
        displayName: String? = nil,
        sourceKind: LibrarySourceKind = .externalFolder
    ) async throws -> LibraryFolder {
        do {
            return try await service.addLibrary(at: url, displayName: displayName, sourceKind: sourceKind)
        } catch let error as LibraryError {
            if case .bookmark = error {
                throw XCTSkip("This host can't create security-scoped bookmarks: \(error)")
            }
            throw error
        }
    }

    // MARK: - Exact-source reuse

    func testExactSameSourceFocusesInsteadOfDuplicating() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")

        let first = try await addLibrary(service, at: root, displayName: "Original Name")
        let second = try await addLibrary(service, at: root, displayName: "Re-picked Name")

        XCTAssertEqual(second.id, first.id, "Re-adding the same folder must not fork the library")
        let knownCount = await service.knownLibraries().count
        XCTAssertEqual(knownCount, 1)
        // Focusing an existing source keeps its identity but does adopt the
        // freshly-supplied display name, mirroring `relink`.
        XCTAssertEqual(second.displayName, "Re-picked Name")
    }

    func testReAddingWithNoDisplayNameKeepsTheExistingName() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")

        _ = try await addLibrary(service, at: root, displayName: "Kept Name")
        let second = try await service.addLibrary(at: root)

        XCTAssertEqual(second.displayName, "Kept Name")
    }

    // MARK: - Parent/child overlap

    func testParentChildSourceOverlapIsRejectedWithoutWriting() async throws {
        let service = try makeService()
        let parentRoot = try makeSubdirectory("Photos")
        let childRoot = try makeSubdirectory("Photos/Trip")

        _ = try await addLibrary(service, at: parentRoot)

        do {
            _ = try await service.addLibrary(at: childRoot, sourceKind: .externalFolder)
            XCTFail("Expected .overlappingSource")
        } catch let error as LibraryError {
            XCTAssertEqual(error, .overlappingSource)
        }

        let knownCount = await service.knownLibraries().count
        XCTAssertEqual(knownCount, 1)
    }

    func testChildThenParentSourceOverlapIsAlsoRejected() async throws {
        let service = try makeService()
        let parentRoot = try makeSubdirectory("Photos")
        let childRoot = try makeSubdirectory("Photos/Trip")

        _ = try await addLibrary(service, at: childRoot)

        do {
            _ = try await service.addLibrary(at: parentRoot, sourceKind: .externalFolder)
            XCTFail("Expected .overlappingSource")
        } catch let error as LibraryError {
            XCTAssertEqual(error, .overlappingSource)
        }

        let knownCount = await service.knownLibraries().count
        XCTAssertEqual(knownCount, 1)
    }

    func testSiblingFoldersAreNotTreatedAsOverlapping() async throws {
        let service = try makeService()
        let tripA = try makeSubdirectory("Photos/TripA")
        let tripB = try makeSubdirectory("Photos/TripB")

        _ = try await addLibrary(service, at: tripA)
        _ = try await addLibrary(service, at: tripB)

        let knownCount = await service.knownLibraries().count
        XCTAssertEqual(knownCount, 2)
    }

    // MARK: - Manifest identity

    func testManifestIdentityWinsWhenTheSameManifestAppearsAtADifferentPath() async throws {
        let service = try makeService()
        let originalRoot = try makeSubdirectory("Original")
        let original = try await addLibrary(service, at: originalRoot)

        // Simulate the same portable `.lumaharbor` directory turning up
        // somewhere else — e.g. the user copied the whole folder tree —
        // without touching the already-known library's own root.
        let copyRoot = try makeSubdirectory("Copy")
        let manifestSource = originalRoot.appendingPathComponent(".lumaharbor", isDirectory: true)
        let manifestDestination = copyRoot.appendingPathComponent(".lumaharbor", isDirectory: true)
        try FileManager.default.copyItem(at: manifestSource, to: manifestDestination)

        let focused = try await service.addLibrary(at: copyRoot, sourceKind: .externalFolder)

        XCTAssertEqual(focused.id, original.id, "A matching manifest LibraryID must win over path/volume signals")
        let knownCount = await service.knownLibraries().count
        XCTAssertEqual(knownCount, 1)
        let refetched = await service.library(id: original.id)
        XCTAssertEqual(refetched?.rootURL, copyRoot)
    }

    // MARK: - Bookmark resolution failure vs. missing volume

    func testCorruptBookmarkDataBecomesNeedsAuthorizationRatherThanOffline() async throws {
        let libraryID = LibraryID()
        let bookmarkStore = FileBookmarkStore(
            directoryURL: try makeSubdirectory("Bookmarks")
        )
        try bookmarkStore.save(StoredBookmark(
            libraryID: libraryID,
            displayName: "Unresolvable",
            lastKnownPath: "/Volumes/Nonexistent/Photos",
            bookmarkData: Data([0x00, 0x01, 0x02, 0x03])
        ))

        let supportDirectory = try makeSubdirectory("AppSupportWithBadBookmark")
        let serviceWithBadBookmark = try PhotoLibraryService(
            locations: ApplicationSupportLocations(baseURL: supportDirectory),
            bookmarkStore: bookmarkStore
        )

        let restored = try await serviceWithBadBookmark.restoreLibraries()
        let folder = try XCTUnwrap(restored.first)

        XCTAssertEqual(folder.connectionState, .needsAuthorization)
        XCTAssertFalse(folder.isOnline)
        XCTAssertEqual(folder.availability, .offline)
    }

    func testExistingBookmarkWithoutSourceKindFieldRestoresAsExternalFolder() async throws {
        let bookmarksDirectory = try makeSubdirectory("LegacyBookmarks")
        let libraryID = LibraryID()
        // A schema-v1-era bookmark file: only the fields that existed before
        // Task 2, written directly as JSON rather than through `StoredBookmark`.
        let legacyJSON = """
        {
            "libraryID": "\(libraryID.rawValue.uuidString)",
            "displayName": "Legacy Drive",
            "lastKnownPath": "/Volumes/Legacy/Photos",
            "bookmarkData": "AAECAw==",
            "addedAt": "1992-03-08T04:26:40Z"
        }
        """
        try Data(legacyJSON.utf8).write(
            to: bookmarksDirectory.appendingPathComponent("\(libraryID.rawValue.uuidString).json")
        )

        let bookmarkStore = FileBookmarkStore(directoryURL: bookmarksDirectory)
        let loaded = try XCTUnwrap(try bookmarkStore.load(libraryID: libraryID))

        XCTAssertEqual(loaded.sourceKind, .externalFolder)
        XCTAssertEqual(loaded.scanState, .idle)
        XCTAssertNil(loaded.resourceIdentifier)
        XCTAssertNil(loaded.volumeIdentifier)
    }

    // MARK: - Scan-state normalization

    func testInterruptedScanStateNormalizesToIdleOnRestore() async throws {
        let bookmarksDirectory = try makeSubdirectory("Bookmarks")
        let bookmarkStore = FileBookmarkStore(directoryURL: bookmarksDirectory)
        let libraryID = LibraryID()

        try bookmarkStore.save(StoredBookmark(
            libraryID: libraryID,
            displayName: "Mid Scan",
            lastKnownPath: "/Volumes/Whatever",
            bookmarkData: Data([0x00]),
            // Constructed directly to simulate a value that predates the
            // guarantee this normalization now provides.
            scanState: .scanning
        ))

        let reloaded = try XCTUnwrap(try bookmarkStore.load(libraryID: libraryID))
        XCTAssertEqual(reloaded.scanState, .idle, "Only .idle/.partialFailure may ever be persisted")
    }

    // MARK: - Removal safety

    func testRemovingALibraryNeverTouchesSourceFiles() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("DSC0001.ARW"))

        let library = try await addLibrary(service, at: root)
        let manifestURL = root.appendingPathComponent(".lumaharbor/library.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))

        try await service.removeLibrary(id: library.id)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("DSC0001.ARW").path),
            "Removing a source must never delete the RAW file"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: manifestURL.path),
            "Removing a source must never delete the manifest"
        )
        let knownCount = await service.knownLibraries().count
        XCTAssertEqual(knownCount, 0)
    }

    // MARK: - Task 1 handoff: lastEditAt projection

    func testSavingNonNeutralAdjustmentsProjectsHasEditsAndLastEditAt() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("DSC0001.ARW"))
        let library = try await addLibrary(service, at: root)
        _ = try await runScan(service, libraryID: library.id)

        let indexed = try await service.photos(inLibrary: library.id)
        let photo = try XCTUnwrap(indexed.first)
        XCTAssertFalse(photo.hasEdits)
        XCTAssertNil(photo.lastEditAt)

        try await service.saveAdjustments(PhotoAdjustments(exposure: 0.5), for: photo)

        let afterSavePhotos = try await service.photos(inLibrary: library.id)
        let afterSave = try XCTUnwrap(afterSavePhotos.first)
        XCTAssertTrue(afterSave.hasEdits)
        XCTAssertNotNil(afterSave.lastEditAt)
    }

    func testSavingNeutralAdjustmentsClearsHasEditsAndLastEditAt() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("DSC0001.ARW"))
        let library = try await addLibrary(service, at: root)
        _ = try await runScan(service, libraryID: library.id)

        let seededPhotos = try await service.photos(inLibrary: library.id)
        let photo = try XCTUnwrap(seededPhotos.first)
        try await service.saveAdjustments(PhotoAdjustments(exposure: 0.5), for: photo)

        let afterEditPhotos = try await service.photos(inLibrary: library.id)
        let afterEdit = try XCTUnwrap(afterEditPhotos.first)
        XCTAssertTrue(afterEdit.hasEdits)

        // Editing back to neutral must clear both columns, not just `hasEdits`.
        try await service.saveAdjustments(.neutral, for: photo)

        let clearedPhotos = try await service.photos(inLibrary: library.id)
        let cleared = try XCTUnwrap(clearedPhotos.first)
        XCTAssertFalse(cleared.hasEdits)
        XCTAssertNil(cleared.lastEditAt)
    }

    func testRescanReconstructsLastEditAtFromTheExistingSidecar() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("DSC0001.ARW"))
        let library = try await addLibrary(service, at: root)
        _ = try await runScan(service, libraryID: library.id)

        let seededPhotos = try await service.photos(inLibrary: library.id)
        let photo = try XCTUnwrap(seededPhotos.first)
        try await service.saveAdjustments(PhotoAdjustments(exposure: 0.5), for: photo)

        let afterSavePhotos = try await service.photos(inLibrary: library.id)
        let afterSave = try XCTUnwrap(afterSavePhotos.first)
        let savedModifiedAt = try XCTUnwrap(afterSave.lastEditAt)

        // Reopen a fresh service against the same on-disk state, so the
        // rescan has to reconstruct `lastEditAt` purely from the sidecar —
        // not from whatever the still-open SQLite connection remembers.
        let secondService = try makeService(supportName: "ApplicationSupport2")
        let restoredLibrary = try await addLibrary(secondService, at: root)
        _ = try await runScan(secondService, libraryID: restoredLibrary.id)

        let rescannedPhotos = try await secondService.photos(inLibrary: restoredLibrary.id)
        let rescanned = try XCTUnwrap(rescannedPhotos.first)
        XCTAssertTrue(rescanned.hasEdits)
        // The sidecar round-trips `modifiedAt` through ISO 8601 (whole
        // seconds only), so this compares at the sidecar's own precision
        // rather than asserting sub-second equality the format can't carry.
        XCTAssertEqual(
            rescanned.lastEditAt?.timeIntervalSince1970 ?? -1,
            savedModifiedAt.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    func testRescanReconstructsNeutralAsNoEdits() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("DSC0001.ARW"))
        let library = try await addLibrary(service, at: root)
        _ = try await runScan(service, libraryID: library.id)

        // No edits ever saved — rescanning must keep reporting neutral.
        _ = try await runScan(service, libraryID: library.id)

        let rescannedPhotos = try await service.photos(inLibrary: library.id)
        let photo = try XCTUnwrap(rescannedPhotos.first)
        XCTAssertFalse(photo.hasEdits)
        XCTAssertNil(photo.lastEditAt)
    }

    // MARK: - Fixtures

    @discardableResult
    private func runScan(
        _ service: PhotoLibraryService,
        libraryID: LibraryID
    ) async throws -> LibraryScanResult {
        var result: LibraryScanResult?
        for await event in service.scan(libraryID: libraryID) {
            if case .finished(let scanResult) = event { result = scanResult }
        }
        return try XCTUnwrap(result)
    }
}
