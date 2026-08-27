import XCTest
@testable import PhotoLibraryCore

final class LibraryRegistryTransactionTests: TemporaryDirectoryTestCase {
    private enum InjectedFailure: Error {
        case journalSave
        case journalRemove
        case bookmarkSave
        case bookmarkRemove
        case indexMutation
    }

    private final class FailableTransactionStore: RegistryTransactionStoring, @unchecked Sendable {
        private let wrapped: FileRegistryTransactionStore
        private let lock = NSLock()
        private var _failSave = false
        private var _failRemove = false

        init(directoryURL: URL) {
            wrapped = FileRegistryTransactionStore(directoryURL: directoryURL)
        }

        var failSave: Bool {
            get { lock.withLock { _failSave } }
            set { lock.withLock { _failSave = newValue } }
        }
        var failRemove: Bool {
            get { lock.withLock { _failRemove } }
            set { lock.withLock { _failRemove = newValue } }
        }

        func load() throws -> RegistryTransactionRecord? { try wrapped.load() }
        func save(_ record: RegistryTransactionRecord) throws {
            if lock.withLock({ _failSave }) { throw InjectedFailure.journalSave }
            try wrapped.save(record)
        }
        func remove() throws {
            if lock.withLock({ _failRemove }) { throw InjectedFailure.journalRemove }
            try wrapped.remove()
        }
    }

    private final class FailableBookmarkStore: BookmarkStoring, @unchecked Sendable {
        private let wrapped: FileBookmarkStore
        private let lock = NSLock()
        private var _failRemove = false
        private var _failSavingDisplayName: String?

        init(directoryURL: URL) {
            wrapped = FileBookmarkStore(directoryURL: directoryURL)
        }

        var failRemove: Bool {
            get { lock.withLock { _failRemove } }
            set { lock.withLock { _failRemove = newValue } }
        }
        var failSavingDisplayName: String? {
            get { lock.withLock { _failSavingDisplayName } }
            set { lock.withLock { _failSavingDisplayName = newValue } }
        }

        func save(_ bookmark: StoredBookmark) throws {
            if lock.withLock({ _failSavingDisplayName == bookmark.displayName }) {
                throw InjectedFailure.bookmarkSave
            }
            try wrapped.save(bookmark)
        }
        func loadAll() throws -> [StoredBookmark] { try wrapped.loadAll() }
        func load(libraryID: LibraryID) throws -> StoredBookmark? {
            try wrapped.load(libraryID: libraryID)
        }
        func remove(libraryID: LibraryID) throws {
            if lock.withLock({ _failRemove }) { throw InjectedFailure.bookmarkRemove }
            try wrapped.remove(libraryID: libraryID)
        }
    }

    private func makeService(
        at locations: ApplicationSupportLocations,
        bookmarkStore: (any BookmarkStoring)? = nil,
        transactionStore: (any RegistryTransactionStoring)? = nil
    ) throws -> PhotoLibraryService {
        try PhotoLibraryService(
            locations: locations,
            bookmarkStore: bookmarkStore,
            registryTransactionStore: transactionStore
        )
    }

    private func addLibrary(
        _ service: PhotoLibraryService,
        at url: URL,
        displayName: String? = nil
    ) async throws -> LibraryFolder {
        do {
            return try await service.addLibrary(at: url, displayName: displayName)
        } catch let error as LibraryError {
            if case .bookmark = error {
                throw XCTSkip("This host can't create security-scoped bookmarks: \(error)")
            }
            throw error
        }
    }

    func testFileJournalRoundTripsAndSurvivesRebuildableDataRemoval() throws {
        let locations = ApplicationSupportLocations(
            baseURL: try makeSubdirectory("AppSupport")
        )
        try locations.createDirectories()

        let libraryID = LibraryID()
        let bookmark = StoredBookmark(
            libraryID: libraryID,
            displayName: "Photos",
            lastKnownPath: "/Volumes/Photos",
            bookmarkData: Data("bookmark".utf8),
            addedAt: Date(timeIntervalSince1970: 1_234)
        )
        let folder = LibraryFolder(
            id: libraryID,
            displayName: "Photos",
            rootURL: URL(fileURLWithPath: "/Volumes/Photos", isDirectory: true)
        )
        let record = RegistryTransactionRecord(
            transactionID: UUID(),
            libraryID: libraryID,
            kind: .freshAdd,
            previousBookmark: nil,
            intendedBookmark: bookmark,
            previousLibrary: nil,
            intendedLibrary: LibraryFolderSnapshot(folder)
        )
        let store = FileRegistryTransactionStore(
            directoryURL: locations.registryTransactionsDirectoryURL
        )

        try store.save(record)
        XCTAssertEqual(try store.load(), record)

        try locations.removeRebuildableData()
        XCTAssertEqual(try store.load(), record)

        try store.remove()
        XCTAssertNil(try store.load())
    }

    func testFreshAddRejectsOrphanSQLiteLibraryAndPhotoRowsWithoutMutation() async throws {
        let support = try makeSubdirectory("OrphanLibrarySupport")
        let locations = ApplicationSupportLocations(baseURL: support)
        let service = try PhotoLibraryService(locations: locations)
        let libraryID = LibraryID()
        let orphan = LibraryFolder(
            id: libraryID,
            displayName: "Old orphan",
            rootURL: URL(fileURLWithPath: "/old/orphan", isDirectory: true),
            photoCount: 1
        )
        let photo = PhotoAsset.stub(libraryID: libraryID, relativePath: "Old.ARW")
        let index = await service.indexStore
        try index.upsert(library: orphan)
        try index.upsert(photo: photo)

        let candidate = try makeSubdirectory("OrphanLibraryCandidate")
        try FileSidecarRepository(libraryRootURL: candidate)
            .write(manifest: LibraryManifest(libraryID: libraryID))

        do {
            _ = try await service.addLibrary(at: candidate)
            XCTFail("Expected durable SQLite collision")
        } catch let error as LibraryError {
            XCTAssertEqual(error, .manifestConflict(libraryID))
        }

        XCTAssertEqual(try index.library(id: libraryID), orphan)
        XCTAssertEqual(try index.photos(inLibrary: libraryID), [photo])
    }

    func testFreshAddRejectsOrphanSQLitePhotoRowsWithoutLibraryRow() async throws {
        let support = try makeSubdirectory("OrphanPhotoSupport")
        let locations = ApplicationSupportLocations(baseURL: support)
        let service = try PhotoLibraryService(locations: locations)
        let libraryID = LibraryID()
        let photo = PhotoAsset.stub(libraryID: libraryID, relativePath: "Detached.ARW")
        let index = await service.indexStore
        try index.upsert(photo: photo)
        XCTAssertNil(try index.library(id: libraryID))

        let candidate = try makeSubdirectory("OrphanPhotoCandidate")
        try FileSidecarRepository(libraryRootURL: candidate)
            .write(manifest: LibraryManifest(libraryID: libraryID))

        do {
            _ = try await service.addLibrary(at: candidate)
            XCTFail("Expected durable SQLite photo collision")
        } catch let error as LibraryError {
            XCTAssertEqual(error, .manifestConflict(libraryID))
        }

        XCTAssertNil(try index.library(id: libraryID))
        XCTAssertEqual(try index.photos(inLibrary: libraryID), [photo])
    }

    func testJournalPrepareFailureLeavesAllLocalRegistryStateUnchanged() async throws {
        let locations = ApplicationSupportLocations(
            baseURL: try makeSubdirectory("PrepareFailureSupport")
        )
        try locations.createDirectories()
        let transactionStore = FailableTransactionStore(
            directoryURL: locations.registryTransactionsDirectoryURL
        )
        transactionStore.failSave = true
        let service = try makeService(at: locations, transactionStore: transactionStore)
        let root = try makeSubdirectory("PrepareFailureRoot")

        do {
            _ = try await addLibrary(service, at: root)
            XCTFail("Expected journal prepare failure")
        } catch InjectedFailure.journalSave {
            // expected
        }

        let knownAfterPrepareFailure = await service.knownLibraries()
        let indexAfterPrepareFailure = await service.indexStore
        XCTAssertTrue(knownAfterPrepareFailure.isEmpty)
        XCTAssertTrue(try FileBookmarkStore(directoryURL: locations.bookmarksDirectoryURL).loadAll().isEmpty)
        XCTAssertTrue(try indexAfterPrepareFailure.libraries().isEmpty)
        XCTAssertNil(try transactionStore.load())
    }

    func testFreshAddRollbackFailureKeepsJournalThenSameSessionRecoveryRestoresAbsentState() async throws {
        let locations = ApplicationSupportLocations(
            baseURL: try makeSubdirectory("FreshRollbackSupport")
        )
        try locations.createDirectories()
        let transactionStore = FailableTransactionStore(
            directoryURL: locations.registryTransactionsDirectoryURL
        )
        let bookmarkStore = FailableBookmarkStore(directoryURL: locations.bookmarksDirectoryURL)
        let service = try makeService(
            at: locations,
            bookmarkStore: bookmarkStore,
            transactionStore: transactionStore
        )
        let index = await service.indexStore
        let root = try makeSubdirectory("FreshRollbackRoot")
        let libraryID = LibraryID()
        try FileSidecarRepository(libraryRootURL: root)
            .write(manifest: LibraryManifest(libraryID: libraryID))

        index.setLibraryMutationHook { mutation in
            if case .upsert(let id) = mutation, id == libraryID {
                throw InjectedFailure.indexMutation
            }
        }
        bookmarkStore.failRemove = true

        do {
            _ = try await addLibrary(service, at: root)
            XCTFail("Expected recovery-required failure")
        } catch let error as LibraryError {
            XCTAssertEqual(error, .registryRecoveryRequired)
        }

        let knownAfterFailure = await service.knownLibraries()
        XCTAssertTrue(knownAfterFailure.isEmpty)
        XCTAssertNotNil(try transactionStore.load())
        XCTAssertNotNil(try bookmarkStore.load(libraryID: libraryID))

        index.setLibraryMutationHook(nil)
        bookmarkStore.failRemove = false
        try await service.recoverPendingRegistryChanges()

        XCTAssertNil(try transactionStore.load())
        XCTAssertNil(try bookmarkStore.load(libraryID: libraryID))
        XCTAssertNil(try index.library(id: libraryID))
        XCTAssertEqual(try index.photoCount(inLibrary: libraryID), 0)
        let knownAfterRecovery = await service.knownLibraries()
        XCTAssertTrue(knownAfterRecovery.isEmpty)
    }

    func testFreshAddRollbackFailureRecoversToAbsentStateAfterRestartInSameApplicationSupport() async throws {
        let locations = ApplicationSupportLocations(
            baseURL: try makeSubdirectory("RestartRollbackSupport")
        )
        try locations.createDirectories()
        let transactionStore = FailableTransactionStore(
            directoryURL: locations.registryTransactionsDirectoryURL
        )
        let bookmarkStore = FailableBookmarkStore(directoryURL: locations.bookmarksDirectoryURL)
        let serviceA = try makeService(
            at: locations,
            bookmarkStore: bookmarkStore,
            transactionStore: transactionStore
        )
        let indexA = await serviceA.indexStore
        let root = try makeSubdirectory("RestartRollbackRoot")
        let libraryID = LibraryID()
        try FileSidecarRepository(libraryRootURL: root)
            .write(manifest: LibraryManifest(libraryID: libraryID))

        indexA.setLibraryMutationHook { mutation in
            if case .upsert(let id) = mutation, id == libraryID {
                throw InjectedFailure.indexMutation
            }
        }
        bookmarkStore.failRemove = true
        do {
            _ = try await addLibrary(serviceA, at: root)
            XCTFail("Expected recovery-required failure")
        } catch let error as LibraryError {
            XCTAssertEqual(error, .registryRecoveryRequired)
        }
        XCTAssertNotNil(try transactionStore.load())

        // A brand-new service uses the same exact Application Support. Its
        // first restore must roll the failed add back, never register it.
        let serviceB = try PhotoLibraryService(locations: locations)
        let restored = try await serviceB.restoreLibraries()
        let knownAfterRestart = await serviceB.knownLibraries()
        XCTAssertTrue(restored.isEmpty)
        XCTAssertTrue(knownAfterRestart.isEmpty)
        XCTAssertTrue(try FileBookmarkStore(directoryURL: locations.bookmarksDirectoryURL).loadAll().isEmpty)
        let indexB = await serviceB.indexStore
        XCTAssertNil(try indexB.library(id: libraryID))
        XCTAssertEqual(try indexB.photoCount(inLibrary: libraryID), 0)
        XCTAssertNil(try FileRegistryTransactionStore(
            directoryURL: locations.registryTransactionsDirectoryURL
        ).load())
    }

    func testFocusRollbackFailureRecoversOldBookmarkIndexAndExactPhotos() async throws {
        let locations = ApplicationSupportLocations(
            baseURL: try makeSubdirectory("FocusRollbackSupport")
        )
        try locations.createDirectories()
        let transactionStore = FailableTransactionStore(
            directoryURL: locations.registryTransactionsDirectoryURL
        )
        let bookmarkStore = FailableBookmarkStore(directoryURL: locations.bookmarksDirectoryURL)
        let service = try makeService(
            at: locations,
            bookmarkStore: bookmarkStore,
            transactionStore: transactionStore
        )
        let root = try makeSubdirectory("FocusRollbackRoot")
        let original = try await addLibrary(service, at: root, displayName: "Original")
        let index = await service.indexStore
        let photo = PhotoAsset.stub(libraryID: original.id, relativePath: "KeepMe.ARW")
        try index.upsert(photo: photo)

        bookmarkStore.failSavingDisplayName = "Original"
        index.setLibraryMutationHook { mutation in
            if case .upsert(let id) = mutation, id == original.id {
                throw InjectedFailure.indexMutation
            }
        }
        do {
            _ = try await addLibrary(service, at: root, displayName: "New Name")
            XCTFail("Expected recovery-required failure")
        } catch let error as LibraryError {
            XCTAssertEqual(error, .registryRecoveryRequired)
        }

        let inMemoryAfterFailure = await service.library(id: original.id)
        XCTAssertEqual(inMemoryAfterFailure?.displayName, "Original")
        XCTAssertEqual(try bookmarkStore.load(libraryID: original.id)?.displayName, "New Name")
        XCTAssertNotNil(try transactionStore.load())

        for operation in ["focus", "relink", "restore", "read edit", "write edit"] {
            do {
                switch operation {
                case "focus":
                    _ = try await service.addLibrary(at: root, displayName: "Blocked")
                case "relink":
                    _ = try await service.relink(libraryID: original.id, to: root)
                case "restore":
                    _ = try await service.restoreLibraries()
                case "read edit":
                    _ = try await service.adjustments(for: photo)
                default:
                    try await service.saveAdjustments(.neutral, for: photo)
                }
                XCTFail("\(operation) must be blocked by pending recovery")
            } catch let error as LibraryError {
                XCTAssertEqual(error, .registryRecoveryRequired, operation)
            }
        }

        var scanWasBlocked = false
        for await event in service.scan(libraryID: original.id) {
            if case .failed(.registryRecoveryRequired) = event {
                scanWasBlocked = true
            }
        }
        XCTAssertTrue(scanWasBlocked)

        bookmarkStore.failSavingDisplayName = nil
        index.setLibraryMutationHook(nil)
        try await service.recoverPendingRegistryChanges()

        XCTAssertEqual(try bookmarkStore.load(libraryID: original.id)?.displayName, "Original")
        XCTAssertEqual(try index.library(id: original.id)?.displayName, "Original")
        XCTAssertEqual(try index.photos(inLibrary: original.id), [photo])
        XCTAssertNil(try transactionStore.load())
    }

    func testJournalCleanupFailureRollsBackAndBlocksMutationsUntilRecovery() async throws {
        let locations = ApplicationSupportLocations(
            baseURL: try makeSubdirectory("CleanupFailureSupport")
        )
        try locations.createDirectories()
        let transactionStore = FailableTransactionStore(
            directoryURL: locations.registryTransactionsDirectoryURL
        )
        transactionStore.failRemove = true
        let service = try makeService(at: locations, transactionStore: transactionStore)
        let root = try makeSubdirectory("CleanupFailureRoot")

        do {
            _ = try await addLibrary(service, at: root)
            XCTFail("Expected cleanup failure")
        } catch let error as LibraryError {
            XCTAssertEqual(error, .registryRecoveryRequired)
        }
        XCTAssertNotNil(try transactionStore.load())
        let knownAfterCleanupFailure = await service.knownLibraries()
        XCTAssertTrue(knownAfterCleanupFailure.isEmpty)

        let blockedRoot = try makeSubdirectory("BlockedWhilePending")
        do {
            _ = try await addLibrary(service, at: blockedRoot)
            XCTFail("Pending recovery must block another add")
        } catch let error as LibraryError {
            XCTAssertEqual(error, .registryRecoveryRequired)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: blockedRoot.appendingPathComponent(".lumaharbor/library.json").path
        ))

        transactionStore.failRemove = false
        try await service.recoverPendingRegistryChanges()
        XCTAssertNil(try transactionStore.load())
        _ = try await addLibrary(service, at: blockedRoot)
    }

    func testSuccessfulAddFocusAndRelinkLeaveNoJournal() async throws {
        let locations = ApplicationSupportLocations(
            baseURL: try makeSubdirectory("SuccessfulTransactionsSupport")
        )
        try locations.createDirectories()
        let transactionStore = FailableTransactionStore(
            directoryURL: locations.registryTransactionsDirectoryURL
        )
        let service = try makeService(at: locations, transactionStore: transactionStore)
        let root = try makeSubdirectory("SuccessfulTransactionsRoot")

        let library = try await addLibrary(service, at: root, displayName: "Original")
        XCTAssertNil(try transactionStore.load())
        _ = try await addLibrary(service, at: root, displayName: "Focused")
        XCTAssertNil(try transactionStore.load())
        _ = try await service.relink(libraryID: library.id, to: root)
        XCTAssertNil(try transactionStore.load())
    }

    func testRestartRecoveryIsIdempotentFromEveryPersistedPartialPhase() async throws {
        enum Phase: CaseIterable, Equatable {
            case journalOnly
            case intendedBookmark
            case intendedBookmarkAndIndex
        }

        for (offset, phase) in Phase.allCases.enumerated() {
            let locations = ApplicationSupportLocations(
                baseURL: try makeSubdirectory("PartialPhaseSupport-\(offset)")
            )
            try locations.createDirectories()
            let bookmarkStore = FileBookmarkStore(directoryURL: locations.bookmarksDirectoryURL)
            let index = try PhotoIndexStore(databaseURL: locations.databaseURL)
            let transactionStore = FileRegistryTransactionStore(
                directoryURL: locations.registryTransactionsDirectoryURL
            )
            let libraryID = LibraryID()
            let oldBookmark = StoredBookmark(
                libraryID: libraryID,
                displayName: "Old",
                lastKnownPath: "/old",
                bookmarkData: Data("old".utf8),
                addedAt: Date(timeIntervalSince1970: 10)
            )
            let intendedBookmark = StoredBookmark(
                libraryID: libraryID,
                displayName: "New",
                lastKnownPath: "/new",
                bookmarkData: Data("new".utf8),
                addedAt: Date(timeIntervalSince1970: 10)
            )
            let oldFolder = LibraryFolder(
                id: libraryID,
                displayName: "Old",
                rootURL: URL(fileURLWithPath: "/old", isDirectory: true)
            )
            let intendedFolder = LibraryFolder(
                id: libraryID,
                displayName: "New",
                rootURL: URL(fileURLWithPath: "/new", isDirectory: true)
            )
            let photo = PhotoAsset.stub(libraryID: libraryID, relativePath: "Stable.ARW")
            try bookmarkStore.save(oldBookmark)
            try index.upsert(library: oldFolder)
            try index.upsert(photo: photo)
            try transactionStore.save(RegistryTransactionRecord(
                transactionID: UUID(),
                libraryID: libraryID,
                kind: .focus,
                previousBookmark: oldBookmark,
                intendedBookmark: intendedBookmark,
                previousLibrary: LibraryFolderSnapshot(oldFolder),
                intendedLibrary: LibraryFolderSnapshot(intendedFolder)
            ))
            if phase != .journalOnly {
                try bookmarkStore.save(intendedBookmark)
            }
            if phase == .intendedBookmarkAndIndex {
                try index.upsert(library: intendedFolder)
            }
            index.close()

            let restarted = try PhotoLibraryService(locations: locations)
            try await restarted.recoverPendingRegistryChanges()
            // A second pass proves recovery is idempotent after the journal
            // has already been cleared.
            try await restarted.recoverPendingRegistryChanges()

            XCTAssertEqual(try bookmarkStore.load(libraryID: libraryID), oldBookmark, "\(phase)")
            let restartedIndex = await restarted.indexStore
            XCTAssertEqual(try restartedIndex.library(id: libraryID)?.displayName, "Old", "\(phase)")
            XCTAssertEqual(try restartedIndex.photos(inLibrary: libraryID), [photo], "\(phase)")
            XCTAssertNil(try transactionStore.load(), "\(phase)")
        }
    }

    func testRestoreRefreshRollbackWithNoPriorLibraryRowPreservesOrphanPhotos() async throws {
        let locations = ApplicationSupportLocations(
            baseURL: try makeSubdirectory("RestoreOrphanPhotoSupport")
        )
        try locations.createDirectories()
        let bookmarkStore = FileBookmarkStore(directoryURL: locations.bookmarksDirectoryURL)
        let transactionStore = FileRegistryTransactionStore(
            directoryURL: locations.registryTransactionsDirectoryURL
        )
        let index = try PhotoIndexStore(databaseURL: locations.databaseURL)
        let libraryID = LibraryID()
        let oldBookmark = StoredBookmark(
            libraryID: libraryID,
            displayName: "Old",
            lastKnownPath: "/old",
            bookmarkData: Data("old".utf8),
            addedAt: Date(timeIntervalSince1970: 20)
        )
        let intendedBookmark = StoredBookmark(
            libraryID: libraryID,
            displayName: "New",
            lastKnownPath: "/new",
            bookmarkData: Data("new".utf8),
            addedAt: Date(timeIntervalSince1970: 20)
        )
        let intendedFolder = LibraryFolder(
            id: libraryID,
            displayName: "New",
            rootURL: URL(fileURLWithPath: "/new", isDirectory: true)
        )
        let photo = PhotoAsset.stub(libraryID: libraryID, relativePath: "Orphan.ARW")
        try bookmarkStore.save(intendedBookmark)
        try index.upsert(photo: photo)
        try index.upsert(library: intendedFolder)
        try transactionStore.save(RegistryTransactionRecord(
            transactionID: UUID(),
            libraryID: libraryID,
            kind: .restoreRefresh,
            previousBookmark: oldBookmark,
            intendedBookmark: intendedBookmark,
            previousLibrary: nil,
            intendedLibrary: LibraryFolderSnapshot(intendedFolder)
        ))
        index.close()

        let restarted = try PhotoLibraryService(locations: locations)
        try await restarted.recoverPendingRegistryChanges()
        let restartedIndex = await restarted.indexStore

        XCTAssertEqual(try bookmarkStore.load(libraryID: libraryID), oldBookmark)
        XCTAssertNil(try restartedIndex.library(id: libraryID))
        XCTAssertEqual(try restartedIndex.photos(inLibrary: libraryID), [photo])
        XCTAssertNil(try transactionStore.load())
    }
}
