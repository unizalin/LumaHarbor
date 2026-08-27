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

    /// Like `makeService`, but keeps a direct reference to the bookmark
    /// store so review-fix-round tests can inspect it before/after a
    /// rejected or failed operation to prove zero mutation.
    private func makeServiceWithExplicitBookmarkStore(
        supportName: String = "AppSupport"
    ) throws -> (service: PhotoLibraryService, bookmarkStore: FileBookmarkStore) {
        let bookmarksDirectory = try makeSubdirectory("\(supportName)-Bookmarks")
        let bookmarkStore = FileBookmarkStore(directoryURL: bookmarksDirectory)
        let service = try PhotoLibraryService(
            locations: ApplicationSupportLocations(baseURL: try makeSubdirectory(supportName)),
            bookmarkStore: bookmarkStore
        )
        return (service, bookmarkStore)
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

    // MARK: - Review fix round 1: manifest preflight must be read-only and state-distinguishing

    /// Item 1 of the fix-round regression list: a corrupt manifest must
    /// abort the add with a safe error, and must never be quarantined
    /// (moved) as a side effect of the identity preflight — `loadManifest()`
    /// quarantines corrupt files, which is correct for a real scan, but
    /// `probeManifest()` must not, since the source might not even end up
    /// being added.
    func testAddingCorruptManifestAbortsWithoutMutatingSourceOrService() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        let manifestDirectory = root.appendingPathComponent(".lumaharbor", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        let manifestURL = manifestDirectory.appendingPathComponent("library.json")
        let corruptBytes = Data("{ not valid json".utf8)
        try corruptBytes.write(to: manifestURL)

        do {
            _ = try await service.addLibrary(at: root)
            XCTFail("Expected a corrupt-manifest error")
        } catch let error as LibraryError {
            guard case .sidecar(.corruptManifest) = error else {
                return XCTFail("Expected .sidecar(.corruptManifest), got \(error)")
            }
        }

        let bytesAfter = try Data(contentsOf: manifestURL)
        XCTAssertEqual(bytesAfter, corruptBytes, "The corrupt manifest must be left byte-for-byte unchanged")

        let quarantineDirectory = manifestDirectory.appendingPathComponent("quarantine", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: quarantineDirectory.path),
            "Identity preflight must never quarantine — only a real scan/load may do that"
        )

        let knownCount = await service.knownLibraries().count
        XCTAssertEqual(knownCount, 0, "A rejected add must not register a bookmark, index row or in-memory library")
    }

    /// Item 2 of the fix-round regression list: a manifest from a newer,
    /// unsupported schema must abort the add (never silently treated as
    /// "no manifest" and overwritten with a fresh `LibraryID`).
    func testAddingNewerSchemaManifestAbortsWithoutMutatingSourceOrService() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        let manifestDirectory = root.appendingPathComponent(".lumaharbor", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        let manifestURL = manifestDirectory.appendingPathComponent("library.json")
        let newerManifest = LibraryManifest(
            schemaVersion: LibraryManifest.currentSchemaVersion + 1, libraryID: LibraryID()
        )
        let originalBytes = try SidecarCoding.encode(newerManifest)
        try originalBytes.write(to: manifestURL)

        do {
            _ = try await service.addLibrary(at: root)
            XCTFail("Expected an unsupported-schema error")
        } catch let error as LibraryError {
            guard case .sidecar(.unsupportedSchemaVersion) = error else {
                return XCTFail("Expected .sidecar(.unsupportedSchemaVersion), got \(error)")
            }
        }

        let bytesAfter = try Data(contentsOf: manifestURL)
        XCTAssertEqual(bytesAfter, originalBytes, "A newer-schema manifest must never be overwritten")

        let knownCount = await service.knownLibraries().count
        XCTAssertEqual(knownCount, 0)
    }

    /// Item 3 of the fix-round regression list: a locally-minted `LibraryID`
    /// (no manifest existed before the add) must not be reported as a
    /// *confirmed* manifest ID unless the best-effort manifest write actually
    /// succeeded — proven here by making the write fail (read-only root) and
    /// checking the persisted record, including through a Codable round trip.
    func testLocallyMintedLibraryIDIsNotConfirmedWhenTheManifestWriteFails() async throws {
        try XCTSkipUnless(canSimulateReadOnlyDirectory, "Test must not run as root")

        let (service, bookmarkStore) = try makeServiceWithExplicitBookmarkStore()
        let root = try makeSubdirectory("Photos")
        try setPosixPermissions(0o555, at: root)
        defer { try? setPosixPermissions(0o755, at: root) }

        let folder = try await addLibrary(service, at: root)

        let stored = try XCTUnwrap(try bookmarkStore.load(libraryID: folder.id))
        XCTAssertNil(
            stored.confirmedManifestLibraryID,
            "No manifest was ever actually written to disk — the minted LibraryID must not be reported as confirmed"
        )

        let data = try SidecarCoding.encode(stored)
        let decoded = try SidecarCoding.decode(StoredBookmark.self, from: data)
        XCTAssertNil(decoded.confirmedManifestLibraryID, "The Codable round trip must not invent a confirmed ID either")
    }

    /// Item 4 of the fix-round regression list: two confirmed manifest IDs
    /// that disagree must reject as a conflict, even when every other
    /// signal (live path, resource identifier) suggests the same physical
    /// folder — never silently downgraded to a reuse.
    func testDifferentConfirmedManifestIDAtTheSameLivePathIsRejectedAsConflict() async throws {
        let (service, _) = try makeServiceWithExplicitBookmarkStore()
        let root = try makeSubdirectory("Photos")
        let original = try await addLibrary(service, at: root)

        // Simulate the on-disk manifest disagreeing with what this service
        // confirmed at add time (e.g. synced from elsewhere, or tampered with).
        let manifestURL = root.appendingPathComponent(".lumaharbor/library.json")
        let conflictingManifest = LibraryManifest(libraryID: LibraryID())
        try SidecarCoding.encode(conflictingManifest).write(to: manifestURL)

        do {
            _ = try await service.addLibrary(at: root)
            XCTFail("Expected .manifestConflict")
        } catch let error as LibraryError {
            guard case .manifestConflict(let conflictingID) = error else {
                return XCTFail("Expected .manifestConflict, got \(error)")
            }
            XCTAssertEqual(conflictingID, original.id)
        }

        let knownCount = await service.knownLibraries().count
        XCTAssertEqual(knownCount, 1)
        let refetched = await service.library(id: original.id)
        XCTAssertEqual(refetched?.rootURL, root, "A rejected conflict must not re-point the existing library")
    }

    // MARK: - Review fix round 1: global, order-independent preflight

    /// Item 9 of the fix-round regression list: a candidate that is
    /// simultaneously `.same` as one known library (via a planted, matching
    /// manifest) and, on physical containment, nested inside a *different*
    /// known library must still be rejected — never silently focused on the
    /// `.same` match just because it happened to be found first.
    func testSameMatchFoundBeforeAConflictStillResultsInRejection() async throws {
        let (service, _) = try makeServiceWithExplicitBookmarkStore()
        let parentRoot = try makeSubdirectory("Photos")
        let elsewhereRoot = try makeSubdirectory("Elsewhere")

        _ = try await addLibrary(service, at: parentRoot)
        let elsewhereLibrary = try await addLibrary(service, at: elsewhereRoot)

        let candidateRoot = parentRoot.appendingPathComponent("Nested", isDirectory: true)
        let candidateManifestDirectory = candidateRoot.appendingPathComponent(".lumaharbor", isDirectory: true)
        try FileManager.default.createDirectory(at: candidateManifestDirectory, withIntermediateDirectories: true)
        try SidecarCoding.encode(LibraryManifest(libraryID: elsewhereLibrary.id))
            .write(to: candidateManifestDirectory.appendingPathComponent("library.json"))

        do {
            _ = try await service.addLibrary(at: candidateRoot)
            XCTFail("Expected .manifestConflict")
        } catch let error as LibraryError {
            // The parent-library comparison is a manifest-ID conflict
            // regardless of which known library the preflight visits first
            // — this is the invariant under test: it never silently focuses
            // on `elsewhereLibrary` just because that comparison is found
            // (or visited) before the parent's.
            guard case .manifestConflict = error else {
                return XCTFail("Expected .manifestConflict, got \(error)")
            }
        }

        let knownCount = await service.knownLibraries().count
        XCTAssertEqual(knownCount, 2, "Neither existing library may be mutated, and no third library may appear")
    }

    /// Item 10 of the fix-round regression list: more than one known library
    /// independently confirming as the same candidate is a data
    /// inconsistency, not a safe pick — reject rather than silently focus
    /// on either one.
    func testMultipleConfirmedSameMatchesAreRejectedRatherThanPickingOne() async throws {
        let (service, bookmarkStore) = try makeServiceWithExplicitBookmarkStore()
        let root = try makeSubdirectory("Photos")
        let resolved = LibrarySourceIdentity.resolve(url: root, confirmedManifestLibraryID: nil)
        let resourceIdentifier = try XCTUnwrap(resolved.resourceIdentifier)
        let volumeIdentifier = try XCTUnwrap(resolved.volumeIdentifier)

        // Two independently-registered records that both (incorrectly — a
        // data inconsistency this preflight must defend against) carry the
        // exact same resource/volume identity as `root`. This can't arise
        // through normal `addLibrary` usage; crafted directly to exercise
        // the "more than one confirmed match" branch.
        for _ in 0..<2 {
            try bookmarkStore.save(StoredBookmark(
                libraryID: LibraryID(),
                displayName: "Duplicate",
                lastKnownPath: "/Volumes/Elsewhere",
                bookmarkData: Data([0x01]),
                resourceIdentifier: resourceIdentifier,
                volumeIdentifier: volumeIdentifier
            ))
        }
        _ = try await service.restoreLibraries()

        do {
            _ = try await service.addLibrary(at: root)
            XCTFail("Expected rejection when multiple known libraries confirm as the same candidate")
        } catch let error as LibraryError {
            guard case .ambiguousSource = error else {
                return XCTFail("Expected .ambiguousSource, got \(error)")
            }
        }

        let knownCount = await service.knownLibraries().count
        XCTAssertEqual(knownCount, 2, "No new library may be added, and neither duplicate is silently focused")
    }

    // MARK: - Review fix round 1: relink uses the same global preflight

    /// Item 11 of the fix-round regression list: relinking to a folder with
    /// no relation to the library being relinked must be rejected, leaving
    /// the bookmark and in-memory state completely untouched.
    func testRelinkToAnUnrelatedFolderIsRejectedWithZeroMutation() async throws {
        let (service, bookmarkStore) = try makeServiceWithExplicitBookmarkStore()
        let root = try makeSubdirectory("Photos")
        let library = try await addLibrary(service, at: root)
        let unrelated = try makeSubdirectory("Unrelated")

        let before = try XCTUnwrap(try bookmarkStore.load(libraryID: library.id))

        do {
            _ = try await service.relink(libraryID: library.id, to: unrelated)
            XCTFail("Expected .relinkTargetMismatch")
        } catch let error as LibraryError {
            guard case .relinkTargetMismatch = error else {
                return XCTFail("Expected .relinkTargetMismatch, got \(error)")
            }
        }

        let after = try XCTUnwrap(try bookmarkStore.load(libraryID: library.id))
        XCTAssertEqual(after, before, "A rejected relink must leave the bookmark record untouched")
        let refetched = await service.library(id: library.id)
        XCTAssertEqual(refetched?.rootURL, root, "A rejected relink must leave the in-memory folder untouched")
    }

    /// Relinking to a folder that overlaps a *different* known library must
    /// also be rejected, even though it would have confirmed fine against
    /// the library actually being relinked.
    func testRelinkToAFolderThatOverlapsAnotherKnownLibraryIsRejected() async throws {
        let (service, _) = try makeServiceWithExplicitBookmarkStore()
        let root = try makeSubdirectory("Photos")
        let library = try await addLibrary(service, at: root)
        let otherRoot = try makeSubdirectory("Other")
        _ = try await addLibrary(service, at: otherRoot)
        let otherChild = otherRoot.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(at: otherChild, withIntermediateDirectories: true)

        do {
            _ = try await service.relink(libraryID: library.id, to: otherChild)
            XCTFail("Expected rejection for overlapping another known library")
        } catch is LibraryError {
            // expected
        }

        let refetched = await service.library(id: library.id)
        XCTAssertEqual(refetched?.rootURL, root, "A rejected relink must not move the library it was attempted on")
    }

    func testRelinkToAnAmbiguousProviderLikeTargetIsRejected() async throws {
        // A relink target that only offers a bounded-fingerprint match — no
        // manifest ID, no resource identifier — must never be silently
        // accepted (spec §7: `.ambiguous` always requires explicit
        // confirmation, which no relink flow currently provides).
        let (service, bookmarkStore) = try makeServiceWithExplicitBookmarkStore()
        let root = try makeSubdirectory("Photos")
        let library = try await addLibrary(service, at: root)

        // Blank the persisted identity so the *existing* library side has no
        // manifest/volume/resource signal left, forcing the fingerprint-only
        // path. Both `root` and the relink target below are freshly-created,
        // empty directories, so their bounded fingerprints (zero children)
        // match — the exact "no stronger signal, only a fingerprint" case
        // spec §7 step 3 describes.
        var stripped = try XCTUnwrap(try bookmarkStore.load(libraryID: library.id))
        stripped.confirmedManifestLibraryID = nil
        stripped.resourceIdentifier = nil
        stripped.volumeIdentifier = nil
        try bookmarkStore.save(stripped)
        _ = try await service.restoreLibraries()
        // Take the library back offline so `identity(for:)` can't recompute
        // live resource/volume data and reintroduce a stronger signal.
        try FileManager.default.removeItem(at: root)
        _ = try await service.restoreLibraries()

        let anotherRoot = try makeSubdirectory("Photos2")
        do {
            _ = try await service.relink(libraryID: library.id, to: anotherRoot)
            XCTFail("Expected .ambiguousSource")
        } catch let error as LibraryError {
            guard case .ambiguousSource(let mismatchedID) = error else {
                return XCTFail("Expected .ambiguousSource, got \(error)")
            }
            XCTAssertEqual(mismatchedID, library.id)
        }
    }

    // MARK: - Review fix round 1: focus/relink persistence rollback

    private enum InjectedTestFailure: Error {
        case saveFailed
    }

    private final class FailableBookmarkStore: BookmarkStoring, @unchecked Sendable {
        private let wrapped: FileBookmarkStore
        var failSaveForLibraryID: LibraryID?

        init(directoryURL: URL) {
            wrapped = FileBookmarkStore(directoryURL: directoryURL)
        }

        func save(_ bookmark: StoredBookmark) throws {
            if bookmark.libraryID == failSaveForLibraryID {
                throw InjectedTestFailure.saveFailed
            }
            try wrapped.save(bookmark)
        }
        func loadAll() throws -> [StoredBookmark] { try wrapped.loadAll() }
        func load(libraryID: LibraryID) throws -> StoredBookmark? { try wrapped.load(libraryID: libraryID) }
        func remove(libraryID: LibraryID) throws { try wrapped.remove(libraryID: libraryID) }
    }

    /// Item 12 of the fix-round regression list: a bookmark-save failure
    /// during focus must leave the old bookmark, in-memory folder and
    /// access scope completely untouched, and never leak a new scope (none
    /// is opened until persistence has already succeeded).
    func testFocusRollsBackCompletelyWhenBookmarkSaveFails() async throws {
        let bookmarksDirectory = try makeSubdirectory("Bookmarks")
        let failableStore = FailableBookmarkStore(directoryURL: bookmarksDirectory)
        let service = try PhotoLibraryService(
            locations: ApplicationSupportLocations(baseURL: try makeSubdirectory("AppSupport")),
            bookmarkStore: failableStore
        )
        let root = try makeSubdirectory("Photos")
        let library = try await addLibrary(service, at: root)

        let beforeStored = try XCTUnwrap(try failableStore.load(libraryID: library.id))
        let beforeFolder = await service.library(id: library.id)

        failableStore.failSaveForLibraryID = library.id
        do {
            _ = try await service.addLibrary(at: root, displayName: "Should Not Apply")
            XCTFail("Expected the injected save failure to propagate")
        } catch {
            // Expected — either the injected error or a wrapped LibraryError.
        }
        failableStore.failSaveForLibraryID = nil

        let afterStored = try XCTUnwrap(try failableStore.load(libraryID: library.id))
        XCTAssertEqual(afterStored, beforeStored, "The old bookmark must survive a failed focus untouched")
        let afterFolder = await service.library(id: library.id)
        XCTAssertEqual(afterFolder?.rootURL, beforeFolder?.rootURL)
        XCTAssertEqual(afterFolder?.displayName, beforeFolder?.displayName)

        // A subsequent, unfailing focus must still work cleanly — proving no
        // leaked scope or corrupted state blocks future use.
        let recovered = try await service.addLibrary(at: root, displayName: "Recovered")
        XCTAssertEqual(recovered.id, library.id)
        XCTAssertEqual(recovered.displayName, "Recovered")
    }

    /// Item 12: an index-upsert failure during focus must roll the bookmark
    /// back to its previous value rather than leaving the two stores
    /// disagreeing.
    func testFocusRollsBackTheBookmarkWhenIndexUpsertFails() async throws {
        let (service, bookmarkStore) = try makeServiceWithExplicitBookmarkStore()
        let root = try makeSubdirectory("Photos")
        let library = try await addLibrary(service, at: root)
        let beforeStored = try XCTUnwrap(try bookmarkStore.load(libraryID: library.id))

        // Close the live index connection so the next `upsert` fails
        // deterministically, without touching any other actor state.
        let indexStore = await service.indexStore
        indexStore.close()

        do {
            _ = try await service.addLibrary(at: root, displayName: "Should Roll Back")
            XCTFail("Expected the index failure to propagate")
        } catch {
            // expected
        }

        let afterStored = try XCTUnwrap(try bookmarkStore.load(libraryID: library.id))
        XCTAssertEqual(afterStored, beforeStored, "The bookmark must be rolled back to its previous value")
    }

    /// Item 12: the same rollback guarantee for a brand-new (not focus) add
    /// — an index failure must not leave an orphaned bookmark behind.
    func testFreshAddRollsBackTheBookmarkWhenIndexUpsertFails() async throws {
        let (service, bookmarkStore) = try makeServiceWithExplicitBookmarkStore()
        let root = try makeSubdirectory("Photos")

        let indexStore = await service.indexStore
        indexStore.close()

        do {
            _ = try await service.addLibrary(at: root)
            XCTFail("Expected the index failure to propagate")
        } catch {
            // expected
        }

        let allBookmarks = try bookmarkStore.loadAll()
        XCTAssertTrue(allBookmarks.isEmpty, "A failed fresh add must leave no orphaned bookmark behind")
        let knownCount = await service.knownLibraries().count
        XCTAssertEqual(knownCount, 0)
    }

    // MARK: - Review fix round 1: StoredBookmark full round trip and fail-safe decoding

    /// Item 15 of the fix-round regression list.
    func testStoredBookmarkRoundTripsEveryNonDefaultField() throws {
        let bookmark = StoredBookmark(
            libraryID: LibraryID(),
            displayName: "Files Provider Source",
            lastKnownPath: "/private/var/mobile/Provider/Photos",
            bookmarkData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceKind: .filesProvider,
            scanState: .partialFailure,
            confirmedManifestLibraryID: LibraryID(),
            resourceIdentifier: Data([0x01, 0x02, 0x03]),
            volumeIdentifier: Data([0xAA, 0xBB]).base64EncodedString(),
            rootFingerprint: RootFingerprint(childCount: 5, sampleNames: ["a", "b", "c"])
        )

        let data = try SidecarCoding.encode(bookmark)
        let decoded = try SidecarCoding.decode(StoredBookmark.self, from: data)

        XCTAssertEqual(decoded, bookmark)
        XCTAssertEqual(decoded.sourceKind, .filesProvider)
        XCTAssertEqual(decoded.scanState, .partialFailure)
    }

    /// Item 16 of the fix-round regression list (bookmark half): an
    /// unrecognised `sourceKind`/`scanState` raw value — a future case this
    /// build doesn't know, or a corrupted field — must never drop the whole
    /// record via `FileBookmarkStore.loadAll()`'s `compactMap`.
    func testUnknownBookmarkSourceKindAndScanStateDoNotDropTheSource() throws {
        let libraryID = LibraryID()
        let json = """
        {
            "libraryID": "\(libraryID.rawValue.uuidString)",
            "displayName": "Future Source",
            "lastKnownPath": "/Volumes/Future",
            "bookmarkData": "AAECAw==",
            "addedAt": "2026-01-01T00:00:00Z",
            "sourceKind": "cloudDriveThisBuildDoesNotKnow",
            "scanState": "someFutureBusyState"
        }
        """
        let directory = try makeSubdirectory("FutureBookmarks")
        try Data(json.utf8).write(
            to: directory.appendingPathComponent("\(libraryID.rawValue.uuidString).json")
        )

        let bookmarkStore = FileBookmarkStore(directoryURL: directory)
        let all = try bookmarkStore.loadAll()

        XCTAssertEqual(all.count, 1, "An unrecognised sourceKind/scanState must not drop the whole record")
        XCTAssertEqual(all.first?.sourceKind, .externalFolder)
        XCTAssertEqual(all.first?.scanState, .idle)
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

    /// Item 18 of the fix-round regression list: strengthened from a plain
    /// existence check to byte-for-byte content comparison of the RAW,
    /// sidecar and manifest, so a hypothetical rewrite-in-place (not just an
    /// outright delete) would also be caught.
    func testRemovingALibraryNeverTouchesSourceFiles() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        let rawURL = root.appendingPathComponent("DSC0001.ARW")
        try writeFile(Data(repeating: 0x30, count: 64), at: rawURL)

        let library = try await addLibrary(service, at: root)
        _ = try await runScan(service, libraryID: library.id)
        let seededPhotos = try await service.photos(inLibrary: library.id)
        let photo = try XCTUnwrap(seededPhotos.first)
        try await service.saveAdjustments(PhotoAdjustments(exposure: 0.5), for: photo)

        let manifestURL = root.appendingPathComponent(".lumaharbor/library.json")
        let sidecarURL = root.appendingPathComponent(".lumaharbor/edits/\(photo.id.sidecarFilename)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))

        let rawBytesBefore = try Data(contentsOf: rawURL)
        let manifestBytesBefore = try Data(contentsOf: manifestURL)
        let sidecarBytesBefore = try Data(contentsOf: sidecarURL)

        try await service.removeLibrary(id: library.id)

        XCTAssertEqual(
            try Data(contentsOf: rawURL), rawBytesBefore,
            "Removing a source must never modify the RAW file's bytes"
        )
        XCTAssertEqual(
            try Data(contentsOf: manifestURL), manifestBytesBefore,
            "Removing a source must never modify the manifest's bytes"
        )
        XCTAssertEqual(
            try Data(contentsOf: sidecarURL), sidecarBytesBefore,
            "Removing a source must never modify a sidecar's bytes"
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
