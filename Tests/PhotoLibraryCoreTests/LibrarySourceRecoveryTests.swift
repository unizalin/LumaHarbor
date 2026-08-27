import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Review fix round 2: `PhotoLibraryService`'s confirmed-manifest-ID
/// reconciliation, `LibraryID` collision guard, staged-persistence durability
/// under compound (forward *and* rollback) failure, and the injectable
/// `FolderAccessResolving` seam that replaces `hdiutil`/a real removable
/// volume for offline/needsAuthorization/stale-refresh/scope-pairing
/// coverage.
final class LibrarySourceRecoveryTests: TemporaryDirectoryTestCase {
    private func makeService(
        supportName: String = "AppSupport",
        bookmarkStore: (any BookmarkStoring)? = nil,
        folderAccessResolver: (any FolderAccessResolving)? = nil,
        bookmarkDataCreator: (any BookmarkDataCreating)? = nil
    ) throws -> PhotoLibraryService {
        try PhotoLibraryService(
            locations: ApplicationSupportLocations(baseURL: try makeSubdirectory(supportName)),
            bookmarkStore: bookmarkStore,
            folderAccessResolver: folderAccessResolver ?? SystemFolderAccessResolver(),
            bookmarkDataCreator: bookmarkDataCreator ?? SystemBookmarkDataCreator()
        )
    }

    private struct FileSnapshot: Equatable {
        var data: Data
        var modificationDate: Date?
    }

    private func fileSnapshot(at url: URL) throws -> FileSnapshot {
        let data = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileSnapshot(data: data, modificationDate: attributes[.modificationDate] as? Date)
    }

    private func assertFileUnchanged(
        at url: URL,
        matches expected: FileSnapshot,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(try fileSnapshot(at: url), expected, message, file: file, line: line)
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

    // MARK: - Test doubles

    private enum InjectedTestFailure: Error {
        case saveFailed, loadFailed, removeFailed
    }

    /// A `BookmarkStoring` wrapper whose save/load/remove can each be made to
    /// fail on demand via a predicate over the call's own arguments, so a
    /// test can distinguish "the forward write" from "the rollback write" to
    /// the same `LibraryID` without needing separate stores.
    private final class FailableBookmarkStore: BookmarkStoring, @unchecked Sendable {
        private let wrapped: FileBookmarkStore
        private let lock = NSLock()
        private var _saveInterceptor: (@Sendable (StoredBookmark) -> Bool)?
        private var _loadInterceptor: (@Sendable (LibraryID) -> Bool)?
        private var _removeInterceptor: (@Sendable (LibraryID) -> Bool)?

        init(directoryURL: URL) {
            wrapped = FileBookmarkStore(directoryURL: directoryURL)
        }

        var saveInterceptor: (@Sendable (StoredBookmark) -> Bool)? {
            get { lock.lock(); defer { lock.unlock() }; return _saveInterceptor }
            set { lock.lock(); _saveInterceptor = newValue; lock.unlock() }
        }
        var loadInterceptor: (@Sendable (LibraryID) -> Bool)? {
            get { lock.lock(); defer { lock.unlock() }; return _loadInterceptor }
            set { lock.lock(); _loadInterceptor = newValue; lock.unlock() }
        }
        var removeInterceptor: (@Sendable (LibraryID) -> Bool)? {
            get { lock.lock(); defer { lock.unlock() }; return _removeInterceptor }
            set { lock.lock(); _removeInterceptor = newValue; lock.unlock() }
        }

        func save(_ bookmark: StoredBookmark) throws {
            if saveInterceptor?(bookmark) == true { throw InjectedTestFailure.saveFailed }
            try wrapped.save(bookmark)
        }
        func loadAll() throws -> [StoredBookmark] { try wrapped.loadAll() }
        func load(libraryID: LibraryID) throws -> StoredBookmark? {
            if loadInterceptor?(libraryID) == true { throw InjectedTestFailure.loadFailed }
            return try wrapped.load(libraryID: libraryID)
        }
        func remove(libraryID: LibraryID) throws {
            if removeInterceptor?(libraryID) == true { throw InjectedTestFailure.removeFailed }
            try wrapped.remove(libraryID: libraryID)
        }
    }

    private enum FakeFolderAccessError: Error {
        case resolveFailed
    }

    /// A `BookmarkDataCreating` wrapper that lets a test make refreshed
    /// bookmark-data creation fail deterministically for one specific URL,
    /// without depending on the real security-scoped bookmark API's own
    /// (unreliably reproducible) failure modes.
    private final class FakeBookmarkDataCreator: BookmarkDataCreating, @unchecked Sendable {
        private let wrapped = SystemBookmarkDataCreator()
        private let lock = NSLock()
        private var failingURLs: Set<URL> = []
        /// Fires immediately before the injected failure is thrown for a
        /// failing URL, so a test can prove the staged access handle for
        /// that URL already exists (creation is only ever attempted after
        /// resolving access) and can inject a second, compound failure —
        /// e.g. closing the index — at that exact moment.
        private var onFailureAttempt: (@Sendable (URL) -> Void)?

        func failBookmarkCreation(for url: URL) {
            lock.lock(); failingURLs.insert(url); lock.unlock()
        }

        func setOnFailureAttempt(_ callback: @escaping @Sendable (URL) -> Void) {
            lock.lock(); onFailureAttempt = callback; lock.unlock()
        }

        /// Fixed synthetic values only -- never `url.path` or anything else
        /// filesystem-derived. This fake stands in for a real bookmark-API
        /// failure, and a real failure's payload can carry a private
        /// absolute path; the injected test double must not.
        static let injectedErrorPath = "<injected-test-path>"
        static let injectedErrorReason = "injected bookmark creation failure"

        func makeBookmarkData(for url: URL) throws -> Data {
            lock.lock()
            let shouldFail = failingURLs.contains(url)
            var callback: (@Sendable (URL) -> Void)?
            if shouldFail {
                // Consumed exactly once: cleared under the same lock
                // acquisition that reads it, so a second failing call for
                // the same (or another) URL finds no callback left to fire.
                callback = onFailureAttempt
                onFailureAttempt = nil
            }
            lock.unlock()
            if shouldFail {
                callback?(url)
                throw BookmarkError.couldNotCreate(
                    path: Self.injectedErrorPath,
                    reason: Self.injectedErrorReason
                )
            }
            return try wrapped.makeBookmarkData(for: url)
        }
    }

    private final class FakeFolderAccessHandle: FolderAccessHandle, @unchecked Sendable {
        let url: URL
        let isStale: Bool
        let isReachable: Bool
        private let lock = NSLock()
        private var _stopCallCount = 0
        var stopCallCount: Int {
            lock.lock(); defer { lock.unlock() }; return _stopCallCount
        }

        init(url: URL, isStale: Bool, isReachable: Bool) {
            self.url = url
            self.isStale = isStale
            self.isReachable = isReachable
        }

        func stop() {
            lock.lock(); defer { lock.unlock() }
            _stopCallCount += 1
        }
    }

    /// Deterministic stand-in for the real bookmark/access system: a test
    /// configures exactly what `resolve(bookmarkData:)` should do for a
    /// given opaque "token" (encoded as the bookmark's raw bytes), so
    /// resolve-throws, resolve-succeeds-but-unreachable and stale-but-
    /// reachable are all reproducible without real hardware.
    private final class FakeFolderAccessResolver: FolderAccessResolving, @unchecked Sendable {
        struct Canned {
            var url: URL
            var isStale: Bool = false
            var isReachable: Bool = true
        }

        private let lock = NSLock()
        private var cannedByToken: [String: Canned] = [:]
        private var failTokens: Set<String> = []
        private var _createdHandles: [FakeFolderAccessHandle] = []
        private var _grantedHandles: [FakeFolderAccessHandle] = []

        var createdHandles: [FakeFolderAccessHandle] {
            lock.lock(); defer { lock.unlock() }; return _createdHandles
        }
        var grantedHandles: [FakeFolderAccessHandle] {
            lock.lock(); defer { lock.unlock() }; return _grantedHandles
        }

        func makeBookmarkData(token: String) -> Data { Data(token.utf8) }

        func setCanned(_ canned: Canned, forToken token: String) {
            lock.lock(); defer { lock.unlock() }
            cannedByToken[token] = canned
        }

        func setShouldFailResolve(forToken token: String) {
            lock.lock(); defer { lock.unlock() }
            failTokens.insert(token)
        }

        func resolve(bookmarkData: Data) throws -> any FolderAccessHandle {
            let token = String(decoding: bookmarkData, as: UTF8.self)
            lock.lock()
            let shouldFail = failTokens.contains(token)
            let canned = cannedByToken[token]
            lock.unlock()

            if shouldFail || canned == nil {
                throw FakeFolderAccessError.resolveFailed
            }
            let handle = FakeFolderAccessHandle(
                url: canned!.url, isStale: canned!.isStale, isReachable: canned!.isReachable
            )
            lock.lock(); _createdHandles.append(handle); lock.unlock()
            return handle
        }

        func grant(url: URL) -> any FolderAccessHandle {
            let handle = FakeFolderAccessHandle(url: url, isStale: false, isReachable: true)
            lock.lock(); _grantedHandles.append(handle); lock.unlock()
            return handle
        }
    }

    private func makeRestoreScopeFixture(
        name: String,
        withManifest: Bool = false
    ) throws -> (
        service: PhotoLibraryService,
        bookmarkStore: FailableBookmarkStore,
        resolver: FakeFolderAccessResolver,
        root: URL,
        libraryID: LibraryID,
        token: String
    ) {
        let root = try makeSubdirectory("\(name)-Root")
        let bookmarkStore = FailableBookmarkStore(
            directoryURL: try makeSubdirectory("\(name)-Bookmarks")
        )
        let resolver = FakeFolderAccessResolver()
        let libraryID = LibraryID()
        if withManifest {
            try FileSidecarRepository(libraryRootURL: root)
                .write(manifest: LibraryManifest(libraryID: libraryID))
        }
        let token = "\(name)-token"
        resolver.setCanned(.init(url: root), forToken: token)
        try bookmarkStore.save(StoredBookmark(
            libraryID: libraryID,
            displayName: name,
            lastKnownPath: root.path,
            bookmarkData: resolver.makeBookmarkData(token: token),
            confirmedManifestLibraryID: withManifest ? libraryID : nil
        ))
        let service = try makeService(
            supportName: "\(name)-Support",
            bookmarkStore: bookmarkStore,
            folderAccessResolver: resolver
        )
        return (service, bookmarkStore, resolver, root, libraryID, token)
    }

    // MARK: - Critical 2, item 1: reachable restore safely backfills an unconfirmed manifest ID

    func testReachableRestoreSafelyBackfillsAnUnconfirmedManifestIDThatAgreesWithItself() async throws {
        let bookmarksDirectory = try makeSubdirectory("Bookmarks")
        let bookmarkStore = FileBookmarkStore(directoryURL: bookmarksDirectory)
        let service = try makeService(bookmarkStore: bookmarkStore)
        let root = try makeSubdirectory("Photos")
        let libraryID = LibraryID()

        // A manifest already agreeing with this library's own LibraryID,
        // written directly (not through `addLibrary`) to simulate a legacy
        // bookmark record that predates `confirmedManifestLibraryID`.
        let manifestDirectory = root.appendingPathComponent(".lumaharbor", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        try SidecarCoding.encode(LibraryManifest(libraryID: libraryID))
            .write(to: manifestDirectory.appendingPathComponent("library.json"))

        guard let bookmarkData = try? SecurityScopedBookmark.makeBookmarkData(for: root) else {
            throw XCTSkip("This host can't create security-scoped bookmarks")
        }
        try bookmarkStore.save(StoredBookmark(
            libraryID: libraryID,
            displayName: "Legacy",
            lastKnownPath: root.path,
            bookmarkData: bookmarkData
            // confirmedManifestLibraryID defaults to nil.
        ))

        _ = try await service.restoreLibraries()

        let reloaded = try XCTUnwrap(try bookmarkStore.load(libraryID: libraryID))
        XCTAssertEqual(
            reloaded.confirmedManifestLibraryID, libraryID,
            "A self-consistent, actually-on-disk manifest must be safely adopted on restore"
        )
    }

    func testReachableRestoreBlocksAnAlreadyConfirmedIDWhenDiskDisagreesWithoutMutatingManifest() async throws {
        let bookmarksDirectory = try makeSubdirectory("Bookmarks")
        let bookmarkStore = FileBookmarkStore(directoryURL: bookmarksDirectory)
        let service = try makeService(bookmarkStore: bookmarkStore)
        let root = try makeSubdirectory("Photos")
        let confirmedID = LibraryID()
        let diskID = LibraryID()

        let manifestDirectory = root.appendingPathComponent(".lumaharbor", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        let manifestURL = manifestDirectory.appendingPathComponent("library.json")
        try SidecarCoding.encode(LibraryManifest(libraryID: diskID)).write(to: manifestURL)
        let bytesBefore = try Data(contentsOf: manifestURL)
        let modifiedBefore = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.modificationDate] as? Date
        )

        guard let bookmarkData = try? SecurityScopedBookmark.makeBookmarkData(for: root) else {
            throw XCTSkip("This host can't create security-scoped bookmarks")
        }
        try bookmarkStore.save(StoredBookmark(
            libraryID: confirmedID,
            displayName: "Already Confirmed",
            lastKnownPath: root.path,
            bookmarkData: bookmarkData,
            confirmedManifestLibraryID: confirmedID
        ))

        let restored = try await service.restoreLibraries()

        let reloaded = try XCTUnwrap(try bookmarkStore.load(libraryID: confirmedID))
        XCTAssertEqual(reloaded.confirmedManifestLibraryID, confirmedID)
        XCTAssertEqual(restored.first?.connectionState, .needsAuthorization)
        let diagnostic = await service.restoreDiagnostic(for: confirmedID)
        XCTAssertEqual(diagnostic, .manifestConflict)

        let refreshed = try await service.refreshAvailability(libraryID: confirmedID)
        XCTAssertEqual(
            refreshed.connectionState,
            .needsAuthorization,
            "Availability refresh must not bypass a blocked restore diagnostic"
        )

        var scanStarted = false
        var scanFailed = false
        for await event in service.scan(libraryID: confirmedID) {
            if case .started = event { scanStarted = true }
            if case .failed = event { scanFailed = true }
        }
        XCTAssertFalse(scanStarted, "A blocked source must not start scanning")
        XCTAssertTrue(scanFailed)

        XCTAssertEqual(try Data(contentsOf: manifestURL), bytesBefore)
        let modifiedAfter = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.modificationDate] as? Date
        )
        XCTAssertEqual(modifiedAfter, modifiedBefore)
    }

    func testRestoreManifestValidationMatrixReportsPreciseDiagnostics() async throws {
        enum DiskState {
            case absent
            case validOwn
            case validForeign
            case valid(LibraryID)
            case corrupt
            case unsupported
            case unavailable
        }
        struct Case {
            let name: String
            let persistedID: (LibraryID) -> LibraryID?
            let diskState: DiskState
            let failSave: Bool
            let expectedConnection: LibraryConnectionState
            let expectedDiagnostic: LibraryRestoreDiagnostic?
            let expectsBackfill: Bool
        }

        let sharedForeignID = LibraryID()
        let cases: [Case] = [
            Case(
                name: "confirmed ID equals disk manifest",
                persistedID: { _ in sharedForeignID }, diskState: .valid(sharedForeignID),
                failSave: false, expectedConnection: .ready, expectedDiagnostic: nil,
                expectsBackfill: false
            ),
            Case(
                name: "unconfirmed manifest agrees with bookmark library ID",
                persistedID: { _ in nil }, diskState: .validOwn,
                failSave: false, expectedConnection: .ready, expectedDiagnostic: nil,
                expectsBackfill: true
            ),
            Case(
                name: "legacy source has no manifest",
                persistedID: { _ in nil }, diskState: .absent,
                failSave: false, expectedConnection: .ready, expectedDiagnostic: nil,
                expectsBackfill: false
            ),
            Case(
                name: "confirmed manifest disappeared",
                persistedID: { id in id }, diskState: .absent,
                failSave: false, expectedConnection: .needsAuthorization,
                expectedDiagnostic: .manifestMissing, expectsBackfill: false
            ),
            Case(
                name: "unconfirmed source presents foreign manifest",
                persistedID: { _ in nil }, diskState: .validForeign,
                failSave: false, expectedConnection: .needsAuthorization,
                expectedDiagnostic: .manifestConflict, expectsBackfill: false
            ),
            Case(
                name: "corrupt manifest",
                persistedID: { _ in nil }, diskState: .corrupt,
                failSave: false, expectedConnection: .needsAuthorization,
                expectedDiagnostic: .corruptManifest, expectsBackfill: false
            ),
            Case(
                name: "newer manifest",
                persistedID: { _ in nil }, diskState: .unsupported,
                failSave: false, expectedConnection: .needsAuthorization,
                expectedDiagnostic: .unsupportedManifest, expectsBackfill: false
            ),
            Case(
                name: "manifest probe unavailable",
                persistedID: { _ in nil }, diskState: .unavailable,
                failSave: false, expectedConnection: .needsAuthorization,
                expectedDiagnostic: .manifestUnavailable, expectsBackfill: false
            ),
            Case(
                name: "required backfill cannot be saved",
                persistedID: { _ in nil }, diskState: .validOwn,
                failSave: true, expectedConnection: .needsAuthorization,
                expectedDiagnostic: .persistenceFailure, expectsBackfill: false
            )
        ]

        for (caseIndex, testCase) in cases.enumerated() {
            let root = try makeSubdirectory("RestoreMatrix-\(caseIndex)-Root")
            let bookmarksDirectory = try makeSubdirectory("RestoreMatrix-\(caseIndex)-Bookmarks")
            let bookmarkStore = FailableBookmarkStore(directoryURL: bookmarksDirectory)
            let resolver = FakeFolderAccessResolver()
            let libraryID = LibraryID()
            let manifestDirectory = root.appendingPathComponent(".lumaharbor", isDirectory: true)
            let manifestURL = manifestDirectory.appendingPathComponent("library.json")

            switch testCase.diskState {
            case .absent:
                break
            case .validOwn:
                try FileSidecarRepository(libraryRootURL: root)
                    .write(manifest: LibraryManifest(libraryID: libraryID))
            case .validForeign:
                try FileSidecarRepository(libraryRootURL: root)
                    .write(manifest: LibraryManifest(libraryID: LibraryID()))
            case .valid(let diskID):
                try FileSidecarRepository(libraryRootURL: root)
                    .write(manifest: LibraryManifest(libraryID: diskID))
            case .corrupt:
                try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
                try Data("not-json".utf8).write(to: manifestURL)
            case .unsupported:
                try FileSidecarRepository(libraryRootURL: root).write(manifest: LibraryManifest(
                    schemaVersion: LibraryManifest.currentSchemaVersion + 1,
                    libraryID: libraryID
                ))
            case .unavailable:
                try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: true)
            }

            var isManifestDirectory: ObjCBool = false
            let hasManifestFile = FileManager.default.fileExists(
                atPath: manifestURL.path,
                isDirectory: &isManifestDirectory
            ) && !isManifestDirectory.boolValue
            let manifestBytesBefore = hasManifestFile ? try Data(contentsOf: manifestURL) : nil
            let manifestModifiedBefore = hasManifestFile
                ? try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.modificationDate] as? Date
                : nil

            let token = "restore-matrix-\(caseIndex)"
            resolver.setCanned(.init(url: root), forToken: token)
            try bookmarkStore.save(StoredBookmark(
                libraryID: libraryID,
                displayName: testCase.name,
                lastKnownPath: root.path,
                bookmarkData: resolver.makeBookmarkData(token: token),
                confirmedManifestLibraryID: testCase.persistedID(libraryID)
            ))
            if testCase.failSave {
                // Fail only the intended backfill. The transaction rollback
                // must still be allowed to restore the original nil-confirmed
                // bookmark.
                bookmarkStore.saveInterceptor = { $0.confirmedManifestLibraryID != nil }
            }

            let service = try makeService(
                supportName: "RestoreMatrix-\(caseIndex)-Support",
                bookmarkStore: bookmarkStore,
                folderAccessResolver: resolver
            )
            let restored = try await service.restoreLibraries()
            let folder = try XCTUnwrap(restored.first, testCase.name)
            XCTAssertEqual(folder.connectionState, testCase.expectedConnection, testCase.name)
            let diagnostic = await service.restoreDiagnostic(for: libraryID)
            XCTAssertEqual(diagnostic, testCase.expectedDiagnostic, testCase.name)

            let handle = try XCTUnwrap(resolver.createdHandles.last, testCase.name)
            XCTAssertEqual(
                handle.stopCallCount,
                testCase.expectedConnection == .needsAuthorization ? 1 : 0,
                testCase.name
            )

            bookmarkStore.saveInterceptor = nil
            let persisted = try XCTUnwrap(try bookmarkStore.load(libraryID: libraryID))
            XCTAssertEqual(
                persisted.confirmedManifestLibraryID,
                testCase.expectsBackfill ? libraryID : testCase.persistedID(libraryID),
                testCase.name
            )
            if let manifestBytesBefore, let manifestModifiedBefore {
                XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBytesBefore, testCase.name)
                let manifestModifiedAfter = try FileManager.default
                    .attributesOfItem(atPath: manifestURL.path)[.modificationDate] as? Date
                XCTAssertEqual(manifestModifiedAfter, manifestModifiedBefore, testCase.name)
            }
        }
    }

    func testUnavailableManifestProbeBlocksRestoreAndBothEditAPIsWithoutTouchingRAWBytes() async throws {
        let root = try makeSubdirectory("UnavailableManifestRoot")
        let rawURL = root.appendingPathComponent("DSC0001.ARW")
        let originalRAW = Data([0x52, 0x41, 0x57, 0x00, 0xFF])
        try originalRAW.write(to: rawURL)

        let manifestURL = root
            .appendingPathComponent(FileSidecarRepository.directoryName, isDirectory: true)
            .appendingPathComponent(FileSidecarRepository.manifestFilename, isDirectory: true)
        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: true)

        let resolver = FakeFolderAccessResolver()
        let token = "unavailable-manifest"
        resolver.setCanned(.init(url: root), forToken: token)
        let libraryID = LibraryID()
        let bookmarkStore = FileBookmarkStore(
            directoryURL: try makeSubdirectory("UnavailableManifestBookmarks")
        )
        try bookmarkStore.save(StoredBookmark(
            libraryID: libraryID,
            displayName: "Unavailable Manifest",
            lastKnownPath: root.path,
            bookmarkData: resolver.makeBookmarkData(token: token),
            confirmedManifestLibraryID: nil
        ))
        let service = try makeService(
            supportName: "UnavailableManifestSupport",
            bookmarkStore: bookmarkStore,
            folderAccessResolver: resolver
        )

        let restored = try await service.restoreLibraries()
        XCTAssertEqual(restored.first?.connectionState, .needsAuthorization)
        let diagnostic = await service.restoreDiagnostic(for: libraryID)
        XCTAssertEqual(diagnostic, .manifestUnavailable)

        let photo = PhotoAsset.stub(
            libraryID: libraryID,
            relativePath: rawURL.lastPathComponent
        )
        do {
            _ = try await service.adjustments(for: photo)
            XCTFail("A manifest-blocked restore must reject adjustment reads")
        } catch let error as LibraryError {
            guard case .offline = error else {
                return XCTFail("Expected blocked adjustment read to report .offline, got \(error)")
            }
        } catch {
            XCTFail("Expected LibraryError, got \(error)")
        }
        do {
            try await service.saveAdjustments(PhotoAdjustments(exposure: 1), for: photo)
            XCTFail("A manifest-blocked restore must reject adjustment writes")
        } catch let error as LibraryError {
            guard case .offline = error else {
                return XCTFail("Expected blocked adjustment write to report .offline, got \(error)")
            }
        } catch {
            XCTFail("Expected LibraryError, got \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: rawURL), originalRAW)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: manifestURL.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "The unavailable manifest path must remain untouched"
        )
    }

    // MARK: - Critical 2, items 2-4: LibraryID collision, and restart-safe recovery

    /// Item 2: the local registry never reports success while it disagrees
    /// with what's actually on disk. A bookmark-save failure — even after
    /// the manifest write itself already succeeded — must propagate, must
    /// not register a library, and a retry at the same URL must still work.
    func testManifestWriteSucceedsButBookmarkPersistenceFailureDoesNotReportSuccess() async throws {
        let bookmarksDirectory = try makeSubdirectory("Bookmarks")
        let failableStore = FailableBookmarkStore(directoryURL: bookmarksDirectory)
        let service = try makeService(bookmarkStore: failableStore)
        let root = try makeSubdirectory("Photos")

        failableStore.saveInterceptor = { _ in true }
        do {
            _ = try await addLibrary(service, at: root)
            XCTFail("Expected the bookmark save failure to propagate")
        } catch {
            // expected
        }
        failableStore.saveInterceptor = nil

        let knownCount = await service.knownLibraries().count
        XCTAssertEqual(knownCount, 0, "A failed add must never report success by registering a library")

        // A retry at the same URL, now unblocked, must succeed cleanly and
        // register exactly one library — the earlier failed attempt must
        // not have left anything behind that blocks or duplicates it.
        _ = try await addLibrary(service, at: root)
        let afterRetryCount = await service.knownLibraries().count
        XCTAssertEqual(afterRetryCount, 1)
    }

    /// Item 3: a candidate whose (confirmed, on-disk) manifest ID collides
    /// with an already-registered `LibraryID` — while the preflight found no
    /// `.same` relationship proving it's really that same source — must be
    /// rejected with zero mutation, never silently overwrite the existing
    /// registration. This simulates a drifted confirmed-ID record (the
    /// existing library's own stored confirmation never completed) plus a
    /// duplicated/corrupted manifest at an unrelated physical location.
    func testCandidateManifestIDCollisionWithRegistryKeyIsRejectedWithZeroMutation() async throws {
        let bookmarksDirectory = try makeSubdirectory("Bookmarks")
        let bookmarkStore = FileBookmarkStore(directoryURL: bookmarksDirectory)
        let service = try makeService(bookmarkStore: bookmarkStore)

        let existingLibraryID = LibraryID()
        try bookmarkStore.save(StoredBookmark(
            libraryID: existingLibraryID,
            displayName: "Original",
            lastKnownPath: "/Volumes/Original/Photos",
            // Deliberately unresolvable: the existing library restores
            // offline/needsAuthorization, so no live evidence can rescue
            // the comparison either way.
            bookmarkData: Data([0x00, 0x01])
            // confirmedManifestLibraryID left nil: the drift.
        ))
        _ = try await service.restoreLibraries()

        let unrelatedRoot = try makeSubdirectory("Unrelated")
        let manifestDirectory = unrelatedRoot.appendingPathComponent(".lumaharbor", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        try SidecarCoding.encode(LibraryManifest(libraryID: existingLibraryID))
            .write(to: manifestDirectory.appendingPathComponent("library.json"))

        do {
            _ = try await service.addLibrary(at: unrelatedRoot)
            XCTFail("Expected rejection on LibraryID collision")
        } catch let error as LibraryError {
            guard case .manifestConflict(let collidingID) = error else {
                return XCTFail("Expected .manifestConflict, got \(error)")
            }
            XCTAssertEqual(collidingID, existingLibraryID)
        }

        let afterCount = await service.knownLibraries().count
        XCTAssertEqual(afterCount, 1, "No new library may be minted for the unrelated folder")
        let stillOriginal = await service.library(id: existingLibraryID)
        XCTAssertEqual(stillOriginal?.lastKnownPath, "/Volumes/Original/Photos")
    }

    /// Item 4: the same collision scenario, replayed after a simulated
    /// restart (a fresh `PhotoLibraryService`/bookmark-store instance over
    /// the same on-disk state), still rejects and still never overwrites
    /// the original source.
    func testRestartAndRetryOfTheCollisionScenarioStillDoesNotOverwriteTheOriginalSource() async throws {
        let bookmarksDirectory = try makeSubdirectory("Bookmarks")
        let appSupportDirectory = try makeSubdirectory("AppSupport")
        let existingLibraryID = LibraryID()

        let bookmarkStoreA = FileBookmarkStore(directoryURL: bookmarksDirectory)
        try bookmarkStoreA.save(StoredBookmark(
            libraryID: existingLibraryID,
            displayName: "Original",
            lastKnownPath: "/Volumes/Original/Photos",
            bookmarkData: Data([0x00, 0x01])
        ))

        let unrelatedRoot = try makeSubdirectory("Unrelated")
        let manifestDirectory = unrelatedRoot.appendingPathComponent(".lumaharbor", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        try SidecarCoding.encode(LibraryManifest(libraryID: existingLibraryID))
            .write(to: manifestDirectory.appendingPathComponent("library.json"))

        let serviceA = try PhotoLibraryService(
            locations: ApplicationSupportLocations(baseURL: appSupportDirectory),
            bookmarkStore: bookmarkStoreA
        )
        _ = try await serviceA.restoreLibraries()
        do {
            _ = try await serviceA.addLibrary(at: unrelatedRoot)
            XCTFail("Expected rejection")
        } catch is LibraryError {
            // expected
        }

        // Simulated restart: fresh service, fresh bookmark-store handle,
        // same on-disk state.
        let bookmarkStoreB = FileBookmarkStore(directoryURL: bookmarksDirectory)
        let serviceB = try PhotoLibraryService(
            locations: ApplicationSupportLocations(baseURL: appSupportDirectory),
            bookmarkStore: bookmarkStoreB
        )
        let restoredB = try await serviceB.restoreLibraries()
        XCTAssertEqual(restoredB.count, 1, "Only the original source may exist after restart")
        XCTAssertEqual(restoredB.first?.id, existingLibraryID)
        XCTAssertEqual(restoredB.first?.lastKnownPath, "/Volumes/Original/Photos")

        do {
            _ = try await serviceB.addLibrary(at: unrelatedRoot)
            XCTFail("Expected rejection again after restart")
        } catch let error as LibraryError {
            guard case .manifestConflict(let collidingID) = error else {
                return XCTFail("Expected .manifestConflict, got \(error)")
            }
            XCTAssertEqual(collidingID, existingLibraryID)
        }

        let finalCount = await serviceB.knownLibraries().count
        XCTAssertEqual(finalCount, 1)
        let stillOriginal = await serviceB.library(id: existingLibraryID)
        XCTAssertEqual(stillOriginal?.lastKnownPath, "/Volumes/Original/Photos")
    }

    // MARK: - Critical 3: baseline-read and rollback failure durability

    /// Item 1: a baseline `bookmarkStore.load` failure during preflight must
    /// fail the whole operation closed immediately — never be swallowed and
    /// read as "no identity"/`.distinct` — and must leave zero mutation.
    /// `focusExistingLibrary`'s own baseline read shares this exact
    /// `bookmarkStore.load` call for the same `LibraryID`, so this proves
    /// the fail-closed guarantee for both call sites at once.
    func testBaselineLoadFailureDuringPreflightFailsClosedWithZeroMutation() async throws {
        let bookmarksDirectory = try makeSubdirectory("Bookmarks")
        let failableStore = FailableBookmarkStore(directoryURL: bookmarksDirectory)
        let service = try makeService(bookmarkStore: failableStore)
        let root = try makeSubdirectory("Photos")
        let library = try await addLibrary(service, at: root)

        failableStore.loadInterceptor = { $0 == library.id }
        do {
            _ = try await service.addLibrary(at: root, displayName: "Should Not Apply")
            XCTFail("Expected the load failure to propagate")
        } catch {
            // expected — a raw load error, not silently read as `.distinct`
        }
        failableStore.loadInterceptor = nil

        let stillOriginal = await service.library(id: library.id)
        XCTAssertEqual(stillOriginal?.displayName, library.displayName)
        XCTAssertEqual(stillOriginal?.rootURL, root)
        let knownCount = await service.knownLibraries().count
        XCTAssertEqual(knownCount, 1)
    }

    /// Item 5: `relink` must have its own end-to-end bookmark/index failure
    /// coverage, not just inherited (untested) behaviour from
    /// `focusExistingLibrary`.
    func testRelinkBookmarkSaveFailureRollsBackWithZeroMutation() async throws {
        let bookmarksDirectory = try makeSubdirectory("Bookmarks")
        let failableStore = FailableBookmarkStore(directoryURL: bookmarksDirectory)
        let service = try makeService(bookmarkStore: failableStore)
        let root = try makeSubdirectory("Photos")
        let library = try await addLibrary(service, at: root)
        let newRoot = try makeSubdirectory("PhotosRelinked")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent(".lumaharbor", isDirectory: true),
            to: newRoot.appendingPathComponent(".lumaharbor", isDirectory: true)
        )

        let before = try XCTUnwrap(try failableStore.load(libraryID: library.id))
        failableStore.saveInterceptor = { _ in true }

        do {
            _ = try await service.relink(libraryID: library.id, to: newRoot)
            XCTFail("Expected the bookmark save failure to propagate")
        } catch {
            // expected
        }
        failableStore.saveInterceptor = nil

        let after = try XCTUnwrap(try failableStore.load(libraryID: library.id))
        XCTAssertEqual(after, before, "A rejected relink save must leave the bookmark record untouched")
        let stillOriginal = await service.library(id: library.id)
        XCTAssertEqual(stillOriginal?.rootURL, root)
    }

    func testRelinkIndexUpsertFailureRollsBackTheBookmark() async throws {
        let bookmarksDirectory = try makeSubdirectory("Bookmarks")
        let bookmarkStore = FileBookmarkStore(directoryURL: bookmarksDirectory)
        let service = try makeService(bookmarkStore: bookmarkStore)
        let root = try makeSubdirectory("Photos")
        let library = try await addLibrary(service, at: root)
        let newRoot = try makeSubdirectory("PhotosRelinked")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent(".lumaharbor", isDirectory: true),
            to: newRoot.appendingPathComponent(".lumaharbor", isDirectory: true)
        )

        let before = try XCTUnwrap(try bookmarkStore.load(libraryID: library.id))
        let indexStore = await service.indexStore
        indexStore.close()

        do {
            _ = try await service.relink(libraryID: library.id, to: newRoot)
            XCTFail("Expected the index failure to propagate")
        } catch {
            // expected
        }

        let after = try XCTUnwrap(try bookmarkStore.load(libraryID: library.id))
        XCTAssertEqual(after, before, "The bookmark must be rolled back to its previous value")
    }

    // MARK: - Important 4: deterministic offline/needsAuthorization/stale/scope-pairing seam

    func testBookmarkResolveSuccessButUnreachableBecomesOffline() async throws {
        let resolver = FakeFolderAccessResolver()
        let bookmarkStore = FileBookmarkStore(directoryURL: try makeSubdirectory("Bookmarks"))
        let service = try makeService(bookmarkStore: bookmarkStore, folderAccessResolver: resolver)

        let token = "unreachable-token"
        let fakeURL = URL(fileURLWithPath: "/Volumes/NotMounted/Photos", isDirectory: true)
        resolver.setCanned(.init(url: fakeURL, isStale: false, isReachable: false), forToken: token)

        let libraryID = LibraryID()
        try bookmarkStore.save(StoredBookmark(
            libraryID: libraryID,
            displayName: "Unmounted Drive",
            lastKnownPath: fakeURL.path,
            bookmarkData: resolver.makeBookmarkData(token: token)
        ))

        let restored = try await service.restoreLibraries()
        let folder = try XCTUnwrap(restored.first)
        XCTAssertEqual(folder.connectionState, .offline)
    }

    func testBookmarkResolutionThrowBecomesNeedsAuthorization() async throws {
        let resolver = FakeFolderAccessResolver()
        let bookmarkStore = FileBookmarkStore(directoryURL: try makeSubdirectory("Bookmarks"))
        let service = try makeService(bookmarkStore: bookmarkStore, folderAccessResolver: resolver)

        let token = "throwing-token"
        resolver.setShouldFailResolve(forToken: token)

        let libraryID = LibraryID()
        try bookmarkStore.save(StoredBookmark(
            libraryID: libraryID,
            displayName: "Revoked",
            lastKnownPath: "/Volumes/Whatever",
            bookmarkData: resolver.makeBookmarkData(token: token)
        ))

        let restored = try await service.restoreLibraries()
        let folder = try XCTUnwrap(restored.first)
        XCTAssertEqual(folder.connectionState, .needsAuthorization)
        let diagnostic = await service.restoreDiagnostic(for: libraryID)
        XCTAssertEqual(diagnostic, .authorizationFailure)
    }

    func testStaleReachableBookmarkRefreshesBookmarkAndIdentity() async throws {
        let resolver = FakeFolderAccessResolver()
        let bookmarksDirectory = try makeSubdirectory("Bookmarks")
        let bookmarkStore = FileBookmarkStore(directoryURL: bookmarksDirectory)
        let service = try makeService(bookmarkStore: bookmarkStore, folderAccessResolver: resolver)

        // A real directory, so the identity/bookmark-refresh real system
        // calls succeed; only resolve success/staleness/reachability are
        // deterministically injected.
        let realRoot = try makeSubdirectory("RealPhotos")
        let token = "stale-token"
        resolver.setCanned(.init(url: realRoot, isStale: true, isReachable: true), forToken: token)

        let libraryID = LibraryID()
        let originalBookmarkData = resolver.makeBookmarkData(token: token)
        try bookmarkStore.save(StoredBookmark(
            libraryID: libraryID,
            displayName: "Stale Bookmark",
            lastKnownPath: realRoot.path,
            bookmarkData: originalBookmarkData
        ))

        _ = try await service.restoreLibraries()

        let reloaded = try XCTUnwrap(try bookmarkStore.load(libraryID: libraryID))
        XCTAssertNotEqual(reloaded.bookmarkData, originalBookmarkData, "A stale bookmark must be refreshed")
        XCTAssertNotNil(reloaded.resourceIdentifier, "The refresh must also recompute identity")
        XCTAssertNotNil(reloaded.volumeIdentifier)
    }

    func testScopeStopStartPairingReplaceAndFailurePathsDoNotLeak() async throws {
        let resolver = FakeFolderAccessResolver()
        let service = try makeService(folderAccessResolver: resolver)
        let root = try makeSubdirectory("Photos")

        let first = try await addLibrary(service, at: root)
        XCTAssertEqual(resolver.grantedHandles.count, 1)
        XCTAssertEqual(resolver.grantedHandles[0].stopCallCount, 0)

        // Re-adding the same folder focuses it, replacing the access
        // handle: the OLD one must be stopped exactly once, and a NEW one
        // granted.
        _ = try await service.addLibrary(at: root, displayName: "Renamed")
        XCTAssertEqual(resolver.grantedHandles.count, 2)
        XCTAssertEqual(resolver.grantedHandles[0].stopCallCount, 1, "The replaced handle must be stopped exactly once")
        XCTAssertEqual(resolver.grantedHandles[1].stopCallCount, 0, "The new handle must still be live")

        // Failure path: close the index so the next focus attempt fails
        // after the bookmark save but before commit — no new handle may be
        // granted, and the still-live handle must not be stopped either.
        let indexStore = await service.indexStore
        indexStore.close()
        do {
            _ = try await service.addLibrary(at: root, displayName: "Should Fail")
            XCTFail("Expected the index failure to propagate")
        } catch {
            // expected
        }
        XCTAssertEqual(resolver.grantedHandles.count, 2, "A failed focus must not grant a new access handle")
        XCTAssertEqual(resolver.grantedHandles[1].stopCallCount, 0, "A failed focus must not stop the still-active handle")

        _ = first
    }

    func testRepeatedRestorePairsEveryStagedAndReplacedScopeExactlyOnce() async throws {
        let success = try makeRestoreScopeFixture(name: "RepeatedSuccess")
        _ = try await success.service.restoreLibraries()
        _ = try await success.service.restoreLibraries()
        XCTAssertEqual(success.resolver.createdHandles.count, 2)
        XCTAssertEqual(success.resolver.createdHandles[0].stopCallCount, 1)
        XCTAssertEqual(success.resolver.createdHandles[1].stopCallCount, 0)

        let resolutionFailure = try makeRestoreScopeFixture(name: "ResolutionFailure")
        _ = try await resolutionFailure.service.restoreLibraries()
        resolutionFailure.resolver.setShouldFailResolve(forToken: resolutionFailure.token)
        let resolutionBlocked = try await resolutionFailure.service.restoreLibraries()
        XCTAssertEqual(resolutionBlocked.first?.connectionState, .needsAuthorization)
        XCTAssertEqual(resolutionFailure.resolver.createdHandles[0].stopCallCount, 1)

        let offline = try makeRestoreScopeFixture(name: "Offline")
        _ = try await offline.service.restoreLibraries()
        offline.resolver.setCanned(
            .init(url: offline.root, isReachable: false),
            forToken: offline.token
        )
        let offlineRestored = try await offline.service.restoreLibraries()
        XCTAssertEqual(offlineRestored.first?.connectionState, .offline)
        XCTAssertEqual(offline.resolver.createdHandles[0].stopCallCount, 1)
        XCTAssertEqual(offline.resolver.createdHandles[1].stopCallCount, 1)
        let offlineRefresh = try await offline.service.refreshAvailability(libraryID: offline.libraryID)
        XCTAssertEqual(
            offlineRefresh.connectionState,
            .offline,
            "A path becoming reachable cannot restore readiness without a committed access handle"
        )

        let conflict = try makeRestoreScopeFixture(name: "Conflict", withManifest: true)
        _ = try await conflict.service.restoreLibraries()
        try FileSidecarRepository(libraryRootURL: conflict.root)
            .write(manifest: LibraryManifest(libraryID: LibraryID()))
        let conflictRestored = try await conflict.service.restoreLibraries()
        XCTAssertEqual(conflictRestored.first?.connectionState, .needsAuthorization)
        let conflictDiagnostic = await conflict.service.restoreDiagnostic(for: conflict.libraryID)
        XCTAssertEqual(conflictDiagnostic, .manifestConflict)
        XCTAssertEqual(conflict.resolver.createdHandles[0].stopCallCount, 1)
        XCTAssertEqual(conflict.resolver.createdHandles[1].stopCallCount, 1)

        let saveFailure = try makeRestoreScopeFixture(name: "SaveFailure")
        _ = try await saveFailure.service.restoreLibraries()
        let saveIndex = await saveFailure.service.indexStore
        let oldIndexedFolder = try XCTUnwrap(saveIndex.library(id: saveFailure.libraryID))
        let oldBookmark = try XCTUnwrap(
            saveFailure.bookmarkStore.load(libraryID: saveFailure.libraryID)
        )
        let relocatedRoot = try makeSubdirectory("SaveFailure-RelocatedRoot")
        try FileSidecarRepository(libraryRootURL: relocatedRoot)
            .write(manifest: LibraryManifest(libraryID: saveFailure.libraryID))
        saveFailure.resolver.setCanned(
            .init(url: relocatedRoot, isStale: true),
            forToken: saveFailure.token
        )
        let originalBookmarkData = saveFailure.resolver.makeBookmarkData(token: saveFailure.token)
        // Fail the stale refresh, but allow journal rollback to restore the
        // original bookmark bytes.
        saveFailure.bookmarkStore.saveInterceptor = { $0.bookmarkData != originalBookmarkData }
        let saveBlocked = try await saveFailure.service.restoreLibraries()
        XCTAssertEqual(saveBlocked.first?.connectionState, .needsAuthorization)
        let saveDiagnostic = await saveFailure.service.restoreDiagnostic(for: saveFailure.libraryID)
        XCTAssertEqual(saveDiagnostic, .persistenceFailure)
        XCTAssertEqual(
            try saveFailure.bookmarkStore.load(libraryID: saveFailure.libraryID),
            oldBookmark
        )
        XCTAssertEqual(try saveIndex.library(id: saveFailure.libraryID), oldIndexedFolder)
        XCTAssertEqual(saveFailure.resolver.createdHandles[0].stopCallCount, 1)
        XCTAssertEqual(saveFailure.resolver.createdHandles[1].stopCallCount, 1)

        let indexFailure = try makeRestoreScopeFixture(name: "IndexFailure")
        _ = try await indexFailure.service.restoreLibraries()
        let indexStore = await indexFailure.service.indexStore
        indexStore.close()
        do {
            _ = try await indexFailure.service.restoreLibraries()
            XCTFail("Expected index persistence failure to propagate")
        } catch {
            // expected
        }
        XCTAssertEqual(indexFailure.resolver.createdHandles[0].stopCallCount, 0)
        XCTAssertEqual(indexFailure.resolver.createdHandles[1].stopCallCount, 1)
        let retained = await indexFailure.service.library(id: indexFailure.libraryID)
        XCTAssertEqual(retained?.connectionState, .ready)

        let removed = try makeRestoreScopeFixture(name: "RemovedBookmark")
        _ = try await removed.service.restoreLibraries()
        try removed.bookmarkStore.remove(libraryID: removed.libraryID)
        let afterRemoval = try await removed.service.restoreLibraries()
        XCTAssertTrue(afterRemoval.isEmpty)
        XCTAssertEqual(removed.resolver.createdHandles[0].stopCallCount, 1)
        let removedKnownCount = await removed.service.knownLibraries().count
        XCTAssertEqual(removedKnownCount, 0)
    }

    /// Independent review fix round 2: a stale bookmark resolves from the old
    /// durable root A to a reachable root B with the identical manifest
    /// identity, but *creating refreshed bookmark data for B itself fails* —
    /// before any registry transaction is ever prepared, so there is nothing
    /// for a journal to roll back. The fix must rebuild the blocked result
    /// from the last known-good durable projection (A) instead of the
    /// already-repointed-at-B in-memory `folder`, so B can never reach SQLite,
    /// actor memory, or the bookmark record.
    func testStaleBookmarkDataCreationFailureBeforeJournalPreparePreservesOldDurableState() async throws {
        let resolver = FakeFolderAccessResolver()
        let bookmarkDataCreator = FakeBookmarkDataCreator()
        let bookmarkStore = FileBookmarkStore(directoryURL: try makeSubdirectory("Bookmarks"))
        let locations = ApplicationSupportLocations(baseURL: try makeSubdirectory("AppSupport"))
        let service = try PhotoLibraryService(
            locations: locations,
            bookmarkStore: bookmarkStore,
            folderAccessResolver: resolver,
            bookmarkDataCreator: bookmarkDataCreator
        )

        let libraryID = LibraryID()
        let rootA = try makeSubdirectory("RootA")
        try FileSidecarRepository(libraryRootURL: rootA)
            .write(manifest: LibraryManifest(libraryID: libraryID))
        let sentinelA = rootA.appendingPathComponent("sentinel-a.raw")
        try Data("root A sentinel bytes".utf8).write(to: sentinelA)

        let token = "stale-creation-failure-token"
        resolver.setCanned(.init(url: rootA), forToken: token)
        try bookmarkStore.save(StoredBookmark(
            libraryID: libraryID,
            displayName: "Stale Creation Failure",
            lastKnownPath: rootA.path,
            bookmarkData: resolver.makeBookmarkData(token: token),
            confirmedManifestLibraryID: libraryID
        ))

        // Restore once so access ownership at A is real, not synthetic.
        _ = try await service.restoreLibraries()
        let indexStore = await service.indexStore
        let oldBookmark = try XCTUnwrap(bookmarkStore.load(libraryID: libraryID))
        let oldIndexedFolder = try XCTUnwrap(indexStore.library(id: libraryID))
        XCTAssertEqual(resolver.createdHandles.count, 1)
        XCTAssertEqual(resolver.createdHandles[0].stopCallCount, 0)

        // Root B claims the identical manifest identity, so identity
        // validation accepts it; the resolver reports it stale, and
        // bookmark-data creation for B specifically is made to fail.
        let rootB = try makeSubdirectory("RootB")
        try FileSidecarRepository(libraryRootURL: rootB)
            .write(manifest: LibraryManifest(libraryID: libraryID))
        let sentinelB = rootB.appendingPathComponent("sentinel-b.raw")
        try Data("root B sentinel bytes".utf8).write(to: sentinelB)

        let manifestASnapshot = try fileSnapshot(at: FileSidecarRepository(libraryRootURL: rootA).manifestURL)
        let manifestBSnapshot = try fileSnapshot(at: FileSidecarRepository(libraryRootURL: rootB).manifestURL)
        let sentinelASnapshot = try fileSnapshot(at: sentinelA)
        let sentinelBSnapshot = try fileSnapshot(at: sentinelB)

        resolver.setCanned(.init(url: rootB, isStale: true), forToken: token)
        bookmarkDataCreator.failBookmarkCreation(for: rootB)

        let restored = try await service.restoreLibraries()
        let folder = try XCTUnwrap(restored.first)

        XCTAssertEqual(folder.connectionState, .needsAuthorization)
        XCTAssertEqual(folder.rootURL, rootA, "The blocked result must stay based on old root A, never B")
        let diagnostic = await service.restoreDiagnostic(for: libraryID)
        XCTAssertEqual(diagnostic, .persistenceFailure)

        let actorVisible = await service.library(id: libraryID)
        XCTAssertEqual(actorVisible?.rootURL, rootA, "The actor-visible folder must stay based on A, never B")
        XCTAssertEqual(actorVisible?.connectionState, .needsAuthorization)

        XCTAssertEqual(
            try bookmarkStore.load(libraryID: libraryID), oldBookmark,
            "The bookmark record must remain exactly the old A record"
        )
        XCTAssertEqual(
            try indexStore.library(id: libraryID), oldIndexedFolder,
            "SQLite must remain exactly the old A projection; B must never be written"
        )

        XCTAssertEqual(resolver.createdHandles.count, 2)
        XCTAssertEqual(
            resolver.createdHandles[0].stopCallCount, 1,
            "The previously retained A access must stop exactly once"
        )
        XCTAssertEqual(
            resolver.createdHandles[1].stopCallCount, 1,
            "The staged B access must stop exactly once"
        )

        let journalStore = FileRegistryTransactionStore(
            directoryURL: locations.registryTransactionsDirectoryURL
        )
        XCTAssertNil(
            try journalStore.load(),
            "No journal may exist: failure occurred before prepare was ever reached"
        )

        let rootAManifest = FileSidecarRepository(libraryRootURL: rootA).probeManifest()
        if case .valid(let manifest) = rootAManifest {
            XCTAssertEqual(manifest.libraryID, libraryID, "Source manifests must remain untouched")
        } else {
            XCTFail("Root A's manifest must remain a valid, unchanged manifest")
        }
        try assertFileUnchanged(
            at: FileSidecarRepository(libraryRootURL: rootA).manifestURL, matches: manifestASnapshot,
            "Root A's manifest bytes/mtime must be untouched"
        )
        try assertFileUnchanged(
            at: FileSidecarRepository(libraryRootURL: rootB).manifestURL, matches: manifestBSnapshot,
            "Root B's manifest bytes/mtime must be untouched"
        )
        try assertFileUnchanged(
            at: sentinelA, matches: sentinelASnapshot, "Root A's source file must be byte-for-byte unchanged"
        )
        try assertFileUnchanged(
            at: sentinelB, matches: sentinelBSnapshot, "Root B's source file must be byte-for-byte unchanged"
        )
    }

    /// Independent review fix round 3: `index.library(id:)` — read to rebuild
    /// the blocked-restore projection after bookmark-data creation for B
    /// fails — can *itself* throw (e.g. the index becomes unavailable at
    /// exactly that moment). At that point the staged B access handle
    /// already exists. The service cannot safely construct a blocked
    /// projection, so the index error must propagate untouched: the newly
    /// staged B handle must still be stopped exactly once (never leaked),
    /// but the previously valid A actor/access state, bookmark, SQLite,
    /// journal and every source file must be left completely alone.
    func testCompoundBookmarkCreationAndIndexReadFailureStopsStagedHandleAndPreservesA() async throws {
        let resolver = FakeFolderAccessResolver()
        let bookmarkDataCreator = FakeBookmarkDataCreator()
        let bookmarkStore = FileBookmarkStore(directoryURL: try makeSubdirectory("CompoundBookmarks"))
        let locations = ApplicationSupportLocations(baseURL: try makeSubdirectory("CompoundAppSupport"))
        let service = try PhotoLibraryService(
            locations: locations,
            bookmarkStore: bookmarkStore,
            folderAccessResolver: resolver,
            bookmarkDataCreator: bookmarkDataCreator
        )

        let libraryID = LibraryID()
        let rootA = try makeSubdirectory("CompoundRootA")
        try FileSidecarRepository(libraryRootURL: rootA)
            .write(manifest: LibraryManifest(libraryID: libraryID))
        let sentinelA = rootA.appendingPathComponent("sentinel-a.raw")
        try Data("compound root A sentinel bytes".utf8).write(to: sentinelA)

        let token = "compound-failure-token"
        resolver.setCanned(.init(url: rootA), forToken: token)
        try bookmarkStore.save(StoredBookmark(
            libraryID: libraryID,
            displayName: "Compound Failure",
            lastKnownPath: rootA.path,
            bookmarkData: resolver.makeBookmarkData(token: token),
            confirmedManifestLibraryID: libraryID
        ))

        // Restore once so access ownership at A is real, not synthetic.
        _ = try await service.restoreLibraries()
        let indexStore = await service.indexStore
        let oldBookmark = try XCTUnwrap(bookmarkStore.load(libraryID: libraryID))
        let oldIndexedFolder = try XCTUnwrap(indexStore.library(id: libraryID))
        XCTAssertEqual(resolver.createdHandles.count, 1)
        XCTAssertEqual(resolver.createdHandles[0].stopCallCount, 0)

        let rootB = try makeSubdirectory("CompoundRootB")
        try FileSidecarRepository(libraryRootURL: rootB)
            .write(manifest: LibraryManifest(libraryID: libraryID))
        let sentinelB = rootB.appendingPathComponent("sentinel-b.raw")
        try Data("compound root B sentinel bytes".utf8).write(to: sentinelB)

        let manifestASnapshot = try fileSnapshot(at: FileSidecarRepository(libraryRootURL: rootA).manifestURL)
        let manifestBSnapshot = try fileSnapshot(at: FileSidecarRepository(libraryRootURL: rootB).manifestURL)
        let sentinelASnapshot = try fileSnapshot(at: sentinelA)
        let sentinelBSnapshot = try fileSnapshot(at: sentinelB)

        resolver.setCanned(.init(url: rootB, isStale: true), forToken: token)
        bookmarkDataCreator.failBookmarkCreation(for: rootB)
        // Fires only once bookmark-data creation for B is actually
        // attempted -- i.e. only after the B access handle already exists
        // (it was resolved earlier in the same restore pass) -- and closes
        // the index at that exact moment, so the service's own recovery
        // read (`index.library(id:)`) is what fails, not the initial probe.
        bookmarkDataCreator.setOnFailureAttempt { _ in
            XCTAssertEqual(resolver.createdHandles.count, 2, "The B handle must already exist when creation is attempted")
            indexStore.close()
        }

        do {
            _ = try await service.restoreLibraries()
            XCTFail("Expected the index read failure to propagate")
        } catch let error as SQLiteError {
            // The exact structural error from the deliberately closed
            // database's `library(id:)` lookup -- not merely "some Error
            // was thrown", which would also pass for a regression that
            // rethrows the original (unrelated) `BookmarkError` instead.
            guard case .prepareFailed(let sql, let message) = error else {
                XCTFail("Expected SQLiteError.prepareFailed, got SQLiteError.\(error)")
                return
            }
            XCTAssertEqual(message, "database is closed")
            XCTAssertTrue(
                sql.contains("FROM library"),
                "The failing statement must be the library lookup, not some other query"
            )
        } catch {
            XCTFail("Expected SQLiteError.prepareFailed, got \(type(of: error))")
        }

        XCTAssertEqual(resolver.createdHandles.count, 2)
        XCTAssertEqual(
            resolver.createdHandles[0].stopCallCount, 0,
            "The previously retained A access must not be touched when the blocked projection can't be built"
        )
        XCTAssertEqual(
            resolver.createdHandles[1].stopCallCount, 1,
            "The newly staged B access must still be stopped exactly once, never leaked"
        )

        let actorVisible = await service.library(id: libraryID)
        XCTAssertEqual(actorVisible?.rootURL, rootA, "Actor-visible state must remain the previous ready A folder")
        XCTAssertEqual(actorVisible?.connectionState, .ready)
        let diagnostic = await service.restoreDiagnostic(for: libraryID)
        XCTAssertNil(diagnostic, "The restore diagnostic must not change: the failed restore never committed")

        XCTAssertEqual(
            try bookmarkStore.load(libraryID: libraryID), oldBookmark,
            "The bookmark record must remain exactly the old A record"
        )

        // Reopen a fresh store against the same on-disk database, since the
        // in-process `indexStore` was deliberately closed above.
        let reopenedIndex = try PhotoIndexStore(databaseURL: locations.databaseURL)
        XCTAssertEqual(
            try reopenedIndex.library(id: libraryID), oldIndexedFolder,
            "SQLite must remain exactly the old A projection; B must never be written"
        )

        let journalStore = FileRegistryTransactionStore(
            directoryURL: locations.registryTransactionsDirectoryURL
        )
        XCTAssertNil(
            try journalStore.load(),
            "No journal may exist: failure occurred before prepare was ever reached"
        )

        try assertFileUnchanged(
            at: FileSidecarRepository(libraryRootURL: rootA).manifestURL, matches: manifestASnapshot,
            "Root A's manifest bytes/mtime must be untouched"
        )
        try assertFileUnchanged(
            at: FileSidecarRepository(libraryRootURL: rootB).manifestURL, matches: manifestBSnapshot,
            "Root B's manifest bytes/mtime must be untouched"
        )
        try assertFileUnchanged(
            at: sentinelA, matches: sentinelASnapshot, "Root A's source file must be byte-for-byte unchanged"
        )
        try assertFileUnchanged(
            at: sentinelB, matches: sentinelBSnapshot, "Root B's source file must be byte-for-byte unchanged"
        )
    }

    /// Independent review evidence fix round 4, Important 2: the compound
    /// test above never observes `FakeBookmarkDataCreator`'s thrown
    /// `BookmarkError` directly (production catches and discards it, only
    /// propagating the later `SQLiteError`), so this asserts against the
    /// fake in isolation that its injected payload is the fixed synthetic
    /// marker, never the real (private) URL passed to it.
    func testFakeBookmarkDataCreatorInjectedFailurePayloadIsSyntheticAndPathFree() throws {
        let creator = FakeBookmarkDataCreator()
        let realURL = try makeSubdirectory("PathFreePayloadCheck")
        creator.failBookmarkCreation(for: realURL)

        do {
            _ = try creator.makeBookmarkData(for: realURL)
            XCTFail("Expected the injected failure to throw")
        } catch let error as BookmarkError {
            guard case .couldNotCreate(let path, let reason) = error else {
                XCTFail("Expected BookmarkError.couldNotCreate, got BookmarkError.\(error)")
                return
            }
            XCTAssertEqual(path, "<injected-test-path>")
            XCTAssertEqual(reason, "injected bookmark creation failure")
            XCTAssertFalse(path.contains(realURL.path), "The payload must never contain the real URL's path")
            for forbiddenPrefix in ["/Users/", "/Volumes/", "/private/var/", "/private/tmp/"] {
                XCTAssertFalse(
                    path.hasPrefix(forbiddenPrefix),
                    "The payload must never carry a real absolute path prefix (\(forbiddenPrefix))"
                )
            }
        } catch {
            XCTFail("Expected BookmarkError.couldNotCreate, got \(type(of: error))")
        }
    }

    /// Independent review evidence fix round 4, Minor: proves
    /// `onFailureAttempt` is genuinely one-shot -- two separate failing
    /// `makeBookmarkData` calls for the same URL must invoke the installed
    /// callback exactly once between them, not once per call.
    func testFakeBookmarkDataCreatorOnFailureAttemptCallbackFiresExactlyOnceAcrossRepeatedFailingCalls() throws {
        let creator = FakeBookmarkDataCreator()
        let url = try makeSubdirectory("OneShotCallbackCheck")
        creator.failBookmarkCreation(for: url)

        let callbackCount = LockedCounter()
        creator.setOnFailureAttempt { _ in callbackCount.increment() }

        XCTAssertThrowsError(try creator.makeBookmarkData(for: url))
        XCTAssertThrowsError(try creator.makeBookmarkData(for: url))

        XCTAssertEqual(
            callbackCount.value, 1,
            "The callback must fire exactly once across two failing attempts, not once per attempt"
        )
    }

    /// Plain `NSLock`-protected counter, so a test callback captured by an
    /// `@Sendable` closure can record how many times it ran without
    /// capturing a mutable `var` across a concurrency boundary.
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock(); count += 1; lock.unlock()
        }

        var value: Int {
            lock.lock(); defer { lock.unlock() }; return count
        }
    }
}
