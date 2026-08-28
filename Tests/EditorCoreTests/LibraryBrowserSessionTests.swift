import Foundation
import XCTest
@testable import EditorCore
import Localization
import PhotoLibraryCore

// MARK: - Fakes

/// A configurable, in-memory stand-in for every `LibraryBrowserDependencies`
/// closure. An actor so it's safe to call from `LibraryBrowserSession`'s
/// off-main-actor `Task`s while still being freely inspectable from a
/// test's `await`-driven assertions.
private actor FakeLibraryEnvironment {
    // MARK: Sources

    var sourcesResult: Result<[LibraryFolder], Error> = .success([])
    private(set) var addSourceCalls: [(url: URL, sourceKind: LibrarySourceKind)] = []
    var addSourceResult: Result<LibraryFolder, Error> = .failure(FakeEnvironmentError.unconfigured)
    private(set) var relinkCalls: [(libraryID: LibraryID, url: URL)] = []
    var relinkResult: Result<LibraryFolder, Error> = .failure(FakeEnvironmentError.unconfigured)
    private(set) var removeCalls: [LibraryID] = []
    var removeError: Error?

    func setSourcesResult(_ result: Result<[LibraryFolder], Error>) { sourcesResult = result }
    func setAddSourceResult(_ result: Result<LibraryFolder, Error>) { addSourceResult = result }
    func setRelinkResult(_ result: Result<LibraryFolder, Error>) { relinkResult = result }
    func setRemoveError(_ error: Error?) { removeError = error }

    func restoreSources() throws -> [LibraryFolder] { try sourcesResult.get() }

    func addSource(_ url: URL, _ sourceKind: LibrarySourceKind) throws -> LibraryFolder {
        addSourceCalls.append((url, sourceKind))
        return try addSourceResult.get()
    }

    func relinkSource(_ libraryID: LibraryID, _ url: URL) throws -> LibraryFolder {
        relinkCalls.append((libraryID, url))
        return try relinkResult.get()
    }

    func removeSource(_ libraryID: LibraryID) throws {
        removeCalls.append(libraryID)
        if let removeError { throw removeError }
    }

    // MARK: Paging

    private(set) var fetchCalls: [LibraryQuery] = []
    /// Scripted pages, keyed by a query's own string description (stable
    /// and distinct per distinct scope/search/sort combination). Which page
    /// a call serves is decided by the `cursor` it passes, exactly like the
    /// real index -- not by how many times that signature has been queried.
    private var pagesBySignature: [String: [[PhotoAsset]]] = [:]
    var fetchError: Error?
    private var isGated = false
    private var isGateOpen = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var gatedEntryCount = 0

    func setPages(for query: LibraryQuery, pages: [[PhotoAsset]]) {
        pagesBySignature[Self.signature(for: query)] = pages
    }

    func setFetchError(_ error: Error?) { fetchError = error }

    func setGated(_ gated: Bool) { isGated = gated }

    /// Permanently opens the gate -- every already-waiting and every future
    /// call proceeds immediately from then on, matching the level-triggered
    /// `InspectionGate` pattern already used elsewhere in this codebase's
    /// tests.
    func openGate() {
        isGateOpen = true
        for waiter in gateWaiters { waiter.resume() }
        gateWaiters = []
    }

    var fetchQueries: [LibraryQuery] { fetchCalls }
    var fetchCallCount: Int { fetchCalls.count }

    func fetchPage(_ query: LibraryQuery, _ cursor: PhotoPageCursor?, _ limit: Int) async throws -> PhotoPage {
        fetchCalls.append(query)
        if isGated, !isGateOpen {
            gatedEntryCount += 1
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gateWaiters.append(continuation)
            }
        }
        if let fetchError {
            self.fetchError = nil
            throw fetchError
        }
        let signature = Self.signature(for: query)
        let pages = pagesBySignature[signature] ?? []
        // Keyed by the cursor itself, like the real
        // `PhotoIndexStore.page(matching:after:limit:)` -- never a running
        // "how many times has this signature been queried" counter, which
        // would wrongly treat a *repeated* query against the same
        // scope/search/sort (a sort round-trip, a restoration re-query) as
        // continuing pagination instead of correctly restarting at page one.
        let index: Int
        if let cursor {
            guard let matchIndex = pages.firstIndex(where: { $0.last?.id == cursor.photoID }) else {
                return PhotoPage(photos: [], nextCursor: nil)
            }
            index = matchIndex + 1
        } else {
            index = 0
        }
        guard index < pages.count else {
            return PhotoPage(photos: [], nextCursor: nil)
        }
        let batch = pages[index]
        let hasMore = index + 1 < pages.count
        let nextCursor: PhotoPageCursor? = (hasMore && !batch.isEmpty) ? PhotoPageCursor(photoID: batch.last!.id) : nil
        return PhotoPage(photos: batch, nextCursor: nextCursor)
    }

    private static func signature(for query: LibraryQuery) -> String {
        "\(query.scope)|\(query.filenameSearch ?? "")|\(query.sort)"
    }

    // MARK: Child directories

    var childDirectoriesResult: Result<[LibraryDirectoryNode], Error> = .success([])
    func setChildDirectoriesResult(_ result: Result<[LibraryDirectoryNode], Error>) { childDirectoriesResult = result }
    func childDirectories(_ libraryID: LibraryID, _ parent: String) throws -> [LibraryDirectoryNode] {
        try childDirectoriesResult.get()
    }

    // MARK: Scanning

    private(set) var runScanCalls: [LibraryID] = []
    private var scanScripts: [LibraryID: [LibraryScanEvent]] = [:]

    func setScanScript(for libraryID: LibraryID, events: [LibraryScanEvent]) {
        scanScripts[libraryID] = events
    }

    func runScan(_ libraryID: LibraryID, _ handler: @Sendable (LibraryScanEvent) async -> Void) async {
        runScanCalls.append(libraryID)
        for event in scanScripts[libraryID] ?? [] {
            await handler(event)
        }
    }

    // MARK: Resolving an open asset

    private(set) var resolveOpenAssetCalls: [PhotoID] = []
    private var resolveResults: [PhotoID: Result<LibraryOpenAsset, Error>] = [:]

    func setResolveResult(for photoID: PhotoID, _ result: Result<LibraryOpenAsset, Error>) {
        resolveResults[photoID] = result
    }

    func resolveOpenAsset(_ photoID: PhotoID) throws -> LibraryOpenAsset {
        resolveOpenAssetCalls.append(photoID)
        guard let result = resolveResults[photoID] else { throw FakeEnvironmentError.unconfigured }
        return try result.get()
    }
}

private enum FakeEnvironmentError: Error, Equatable {
    case unconfigured
}

private func makeDependencies(_ environment: FakeLibraryEnvironment) -> LibraryBrowserDependencies {
    LibraryBrowserDependencies(
        restoreSources: { try await environment.restoreSources() },
        fetchPage: { query, cursor, limit in try await environment.fetchPage(query, cursor, limit) },
        childDirectories: { libraryID, parent in try await environment.childDirectories(libraryID, parent) },
        addSource: { url, sourceKind in try await environment.addSource(url, sourceKind) },
        relinkSource: { libraryID, url in try await environment.relinkSource(libraryID, url) },
        runScan: { libraryID, handler in await environment.runScan(libraryID, handler) },
        removeSource: { libraryID in try await environment.removeSource(libraryID) },
        resolveOpenAsset: { photoID in try await environment.resolveOpenAsset(photoID) }
    )
}

// MARK: - Fixtures

private func makePhoto(
    id: PhotoID = PhotoID(),
    libraryID: LibraryID,
    name: String = "IMG_0001.ARW"
) -> PhotoAsset {
    PhotoAsset(
        id: id,
        libraryID: libraryID,
        relativePath: name,
        fingerprint: FileFingerprint(fileSize: 1_024, edgeDigest: UUID().uuidString),
        status: .ready,
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func makeFolder(
    id: LibraryID = LibraryID(),
    name: String = "Source",
    connectionState: LibraryConnectionState = .ready,
    sourceKind: LibrarySourceKind = .externalFolder
) -> LibraryFolder {
    LibraryFolder(
        id: id,
        displayName: name,
        rootURL: URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true),
        sourceKind: sourceKind,
        connectionState: connectionState
    )
}

private func waitUntil(
    timeout: TimeInterval = 3,
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for condition")
}

private func waitUntilAsync(
    timeout: TimeInterval = 3,
    _ condition: () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for condition")
}

// MARK: - Tests

@MainActor
final class LibraryBrowserSessionTests: XCTestCase {

    // MARK: 1. Startup restoration

    func testStartupRestoresSourcesAndLoadsFirstPage() async throws {
        let environment = FakeLibraryEnvironment()
        let sourceID = LibraryID()
        await environment.setSourcesResult(.success([makeFolder(id: sourceID, name: "Trip")]))
        let photo = makePhoto(libraryID: sourceID)
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[photo]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        XCTAssertEqual(session.sources.map(\.id), [sourceID])
        XCTAssertEqual(session.photos.map(\.id), [photo.id])
        XCTAssertEqual(session.selection, .smart(.all), "the default selection loads first")
    }

    func testStartupRestorationFailureSetsFailedLoadStateWithAPathFreeAlert() async throws {
        struct FakeRestoreError: Error {}
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.failure(FakeRestoreError()))

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil {
            if case .failed = session.loadState { return true }
            return false
        }

        guard case .failed(let alert) = session.loadState else {
            return XCTFail("expected .failed load state")
        }
        XCTAssertFalse(alert.title.contains("/"))
        XCTAssertFalse(alert.message.contains("/"))
        XCTAssertTrue(session.photos.isEmpty)
        XCTAssertTrue(session.sources.isEmpty)
    }

    func testCallingStartTwiceOnlyRestoresOnce() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        session.start()
        try await waitUntil { session.loadState == .loaded }
        try? await Task.sleep(for: .milliseconds(50))

        let fetchCount = await environment.fetchCallCount
        XCTAssertEqual(fetchCount, 1, "a second start() must be a no-op")
    }

    // MARK: 2. Paging

    func testLoadNextPageAppendsToPhotos() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        let sourceID = LibraryID()
        let query = LibraryQuery(scope: .all, sort: .captureDateDescending)
        let pageOne = [makePhoto(libraryID: sourceID, name: "a.ARW")]
        let pageTwo = [makePhoto(libraryID: sourceID, name: "b.ARW")]
        await environment.setPages(for: query, pages: [pageOne, pageTwo])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }
        XCTAssertEqual(session.photos.map(\.id), pageOne.map(\.id))
        XCTAssertNotNil(session.nextCursor)

        session.loadNextPage()
        try await waitUntil { session.photos.count == pageOne.count + pageTwo.count }

        XCTAssertEqual(session.photos.map(\.id), (pageOne + pageTwo).map(\.id))
        XCTAssertNil(session.nextCursor, "the second (last) page has no further cursor")
    }

    func testDuplicateConcurrentLoadNextPageCallsFetchOnlyOnce() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        let sourceID = LibraryID()
        let query = LibraryQuery(scope: .all, sort: .captureDateDescending)
        let pageOne = [makePhoto(libraryID: sourceID, name: "a.ARW")]
        let pageTwo = [makePhoto(libraryID: sourceID, name: "b.ARW")]
        await environment.setPages(for: query, pages: [pageOne, pageTwo])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        await environment.setGated(true)
        session.loadNextPage()
        session.loadNextPage() // duplicate, while the first is still in flight
        session.loadNextPage() // duplicate again
        try await waitUntilAsync { await environment.gatedEntryCount >= 1 }
        try? await Task.sleep(for: .milliseconds(50))
        let gatedEntriesWhileStuck = await environment.gatedEntryCount
        await environment.openGate()
        try await waitUntil { session.photos.count == pageOne.count + pageTwo.count }

        XCTAssertEqual(gatedEntriesWhileStuck, 1, "duplicate concurrent loadNextPage() calls must never start a second fetch")
        let fetchCount = await environment.fetchCallCount
        XCTAssertEqual(fetchCount, 2, "exactly one first-page fetch and one next-page fetch")
    }

    func testLoadNextPageIsANoOpWhenThereIsNoNextCursor() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        let query = LibraryQuery(scope: .all, sort: .captureDateDescending)
        let onlyPage = [makePhoto(libraryID: LibraryID())]
        await environment.setPages(for: query, pages: [onlyPage])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }
        XCTAssertNil(session.nextCursor)

        session.loadNextPage()
        try? await Task.sleep(for: .milliseconds(100))

        let fetchCount = await environment.fetchCallCount
        XCTAssertEqual(fetchCount, 1, "loadNextPage() must not fetch again once there is no nextCursor")
    }

    // MARK: 3. Query generation / stale response discard

    func testSwitchingSelectionDuringAnOutstandingFetchDiscardsTheStaleResult() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        let sourceA = LibraryID()
        let sourceB = LibraryID()
        let queryA = LibraryQuery(scope: .source(sourceA), sort: .captureDateDescending)
        let queryB = LibraryQuery(scope: .source(sourceB), sort: .captureDateDescending)
        let photoA = makePhoto(libraryID: sourceA)
        let photoB = makePhoto(libraryID: sourceB)
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        await environment.setPages(for: queryA, pages: [[photoA]])
        await environment.setPages(for: queryB, pages: [[photoB]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        await environment.setGated(true)
        session.select(.source(sourceA))
        try await waitUntilAsync { await environment.gatedEntryCount >= 1 }

        // Supersede A before its stuck fetch ever resolves.
        session.select(.source(sourceB))
        await environment.openGate()
        try await waitUntil { session.photos.map(\.id) == [photoB.id] }

        XCTAssertEqual(session.selection, .source(sourceB))
        XCTAssertEqual(session.photos.map(\.id), [photoB.id], "A's stale result must never overwrite B's")
        XCTAssertEqual(session.loadState, .loaded)
    }

    func testChangingSortDuringAnOutstandingFetchDiscardsTheStaleResult() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        let sourceID = LibraryID()
        let queryAscending = LibraryQuery(scope: .all, sort: .captureDateAscending)
        let queryDescending = LibraryQuery(scope: .all, sort: .captureDateDescending)
        let photoAscending = makePhoto(libraryID: sourceID, name: "ascending.ARW")
        let photoDescending = makePhoto(libraryID: sourceID, name: "descending.ARW")
        await environment.setPages(for: queryDescending, pages: [[photoDescending]])
        await environment.setPages(for: queryAscending, pages: [[photoAscending]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }
        XCTAssertEqual(session.photos.map(\.id), [photoDescending.id])

        await environment.setGated(true)
        session.setSort(.captureDateAscending)
        try await waitUntilAsync { await environment.gatedEntryCount >= 1 }

        // A second sort change supersedes the first before it resolves.
        session.setSort(.captureDateDescending)
        await environment.openGate()
        try await waitUntil { session.sort == .captureDateDescending && session.loadState == .loaded }

        XCTAssertEqual(session.photos.map(\.id), [photoDescending.id], "the superseded ascending fetch must never apply")
    }

    // MARK: 4. Search debounce cancellation

    func testSearchDebounceOnlyLetsTheLastUpdateReachTheIndex() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        let finalQuery = LibraryQuery(scope: .all, filenameSearch: "final", sort: .captureDateDescending)
        let matched = [makePhoto(libraryID: LibraryID(), name: "final-match.ARW")]
        await environment.setPages(for: finalQuery, pages: [matched])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        session.updateSearchText("f")
        session.updateSearchText("fi")
        session.updateSearchText("fin")
        session.updateSearchText("final")
        XCTAssertEqual(session.searchText, "final", "the text itself updates immediately, even though the query is debounced")

        try await waitUntil(timeout: 3) { session.photos.map(\.id) == matched.map(\.id) }

        let searchTermsFetched = await environment.fetchQueries.compactMap(\.filenameSearch)
        XCTAssertEqual(searchTermsFetched, ["final"], "only the last debounced search must ever reach fetchPage")
    }

    func testUpdatingSearchTextToTheSameValueDoesNotRequery() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        session.updateSearchText("")
        try? await Task.sleep(for: .milliseconds(350))

        let fetchCount = await environment.fetchCallCount
        XCTAssertEqual(fetchCount, 1, "re-setting the same (empty) search text must not trigger a second fetch")
    }

    // MARK: 5. Page window bound

    func testPageSizeDefaultsToOneHundredAndNeverExceedsTwoHundred() {
        XCTAssertEqual(LibraryBrowserSession.pageSize, 100)
        XCTAssertLessThanOrEqual(LibraryBrowserSession.pageSize, 200)
    }

    func testPhotosArrayStaysBoundedToTheCurrentWindowPlusTwoPrefetchedPages() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        let query = LibraryQuery(scope: .all, sort: .captureDateDescending)
        // 5 pages of `pageSize` rows each -- the window must cap at 3 pages.
        let pages: [[PhotoAsset]] = (0..<5).map { pageIndex in
            (0..<LibraryBrowserSession.pageSize).map { rowIndex in
                makePhoto(libraryID: LibraryID(), name: "p\(pageIndex)-r\(rowIndex).ARW")
            }
        }
        await environment.setPages(for: query, pages: pages)

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        for _ in 0..<4 {
            session.loadNextPage()
            try await waitUntil { session.loadState == .loaded }
        }

        XCTAssertLessThanOrEqual(session.photos.count, LibraryBrowserSession.pageSize * 3, "must never accumulate every fetched row")
        XCTAssertTrue(session.photos.contains { $0.id == pages[4].last!.id }, "the most recently fetched page must still be present")
        XCTAssertFalse(session.photos.contains { $0.id == pages[0].first!.id }, "the oldest page must have been evicted")
    }

    // MARK: 6. openAsset(for:)

    func testOpenAssetForAnOnlineExternalSourceResolvesViaTheDependency() async throws {
        let environment = FakeLibraryEnvironment()
        let sourceID = LibraryID()
        await environment.setSourcesResult(.success([makeFolder(id: sourceID, connectionState: .ready, sourceKind: .externalFolder)]))
        let photo = makePhoto(libraryID: sourceID)
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[photo]])
        let resolvedURL = URL(fileURLWithPath: "/Volumes/Drive/photo.ARW")
        await environment.setResolveResult(for: photo.id, .success(.external(url: resolvedURL, sourceKind: .externalFolder)))

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        let result = await session.openAsset(for: photo)
        guard case .external(let url, let sourceKind) = result else {
            return XCTFail("expected .external, got \(String(describing: result))")
        }
        XCTAssertEqual(url, resolvedURL)
        XCTAssertEqual(sourceKind, .externalFolder)
        let calls = await environment.resolveOpenAssetCalls
        XCTAssertEqual(calls, [photo.id])
        XCTAssertEqual(session.restorationAnchor?.anchorPhotoID, photo.id, "a successful open records a restoration anchor")
    }

    func testOpenAssetForAnAppStorageAssetResolvesToAnAppCopy() async throws {
        let environment = FakeLibraryEnvironment()
        // `.appStorage` is a synthetic library `restoreSources()` (bookmark-
        // backed) never returns -- deliberately left out of `sourcesResult`.
        await environment.setSourcesResult(.success([]))
        let appStorageID = LibraryID.appStorage
        let photo = makePhoto(libraryID: appStorageID)
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[photo]])
        let documentID = photo.id.rawValue
        await environment.setResolveResult(for: photo.id, .success(.appCopy(documentID: documentID)))

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        let result = await session.openAsset(for: photo)
        guard case .appCopy(let resolvedID) = result else {
            return XCTFail("expected .appCopy, got \(String(describing: result))")
        }
        XCTAssertEqual(resolvedID, documentID)
    }

    func testOpenAssetGatesAnOfflineSourceWithoutCallingResolveOpenAsset() async throws {
        let environment = FakeLibraryEnvironment()
        let sourceID = LibraryID()
        await environment.setSourcesResult(.success([makeFolder(id: sourceID, connectionState: .offline)]))
        let photo = makePhoto(libraryID: sourceID)
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[photo]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        let result = await session.openAsset(for: photo)
        XCTAssertNil(result)
        XCTAssertNotNil(session.alert)
        XCTAssertEqual(session.alert?.nextStep, L10n.t("Reconnect the source, then try again."))
        let calls = await environment.resolveOpenAssetCalls
        XCTAssertTrue(calls.isEmpty, "an offline source must never even call resolveOpenAsset")
        XCTAssertNil(session.restorationAnchor)
    }

    func testOpenAssetGatesANeedsAuthorizationSourceWithoutCallingResolveOpenAsset() async throws {
        let environment = FakeLibraryEnvironment()
        let sourceID = LibraryID()
        await environment.setSourcesResult(.success([makeFolder(id: sourceID, connectionState: .needsAuthorization)]))
        let photo = makePhoto(libraryID: sourceID)
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[photo]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        let result = await session.openAsset(for: photo)
        XCTAssertNil(result)
        XCTAssertNotNil(session.alert)
        let calls = await environment.resolveOpenAssetCalls
        XCTAssertTrue(calls.isEmpty, "a needsAuthorization source must never even call resolveOpenAsset")
    }

    /// Bounded concern (see the Task 5 report): `LibraryOpenAsset` has no
    /// read-only case, so a read-only source's photos are still allowed to
    /// open -- this session cannot invent a way to carry that intent
    /// through Task 4's existing interface.
    func testOpenAssetAllowsAReadOnlySourceThrough() async throws {
        let environment = FakeLibraryEnvironment()
        let sourceID = LibraryID()
        await environment.setSourcesResult(.success([makeFolder(id: sourceID, connectionState: .readOnly)]))
        let photo = makePhoto(libraryID: sourceID)
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[photo]])
        let url = URL(fileURLWithPath: "/Volumes/ReadOnlyDrive/photo.ARW")
        await environment.setResolveResult(for: photo.id, .success(.external(url: url, sourceKind: .externalFolder)))

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        let result = await session.openAsset(for: photo)
        XCTAssertNotNil(result, "a read-only source must still be allowed to open")
        let calls = await environment.resolveOpenAssetCalls
        XCTAssertEqual(calls, [photo.id])
    }

    func testOpenAssetSurfacesASafeAlertWhenResolutionFails() async throws {
        struct FakeResolveError: Error {}
        let environment = FakeLibraryEnvironment()
        let sourceID = LibraryID()
        await environment.setSourcesResult(.success([makeFolder(id: sourceID, connectionState: .ready)]))
        let photo = makePhoto(libraryID: sourceID)
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[photo]])
        await environment.setResolveResult(for: photo.id, .failure(FakeResolveError()))

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        let result = await session.openAsset(for: photo)
        XCTAssertNil(result)
        XCTAssertNotNil(session.alert)
        XCTAssertFalse(session.alert?.message.contains("/") ?? true)
        XCTAssertNil(session.restorationAnchor, "a failed resolution must never record a restoration anchor")
    }

    // MARK: 7. Per-source progress

    func testScanEventsUpdatePerSourceProgress() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        let sourceID = LibraryID()
        let batch = [makePhoto(libraryID: sourceID, name: "a.ARW"), makePhoto(libraryID: sourceID, name: "b.ARW")]
        await environment.setScanScript(for: sourceID, events: [
            .started(sourceID),
            .photosIndexed(batch),
            .photoFailed(relativePath: "bad.ARW", reason: "corrupt"),
        ])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        session.scanSource(sourceID)
        try await waitUntil { session.sourceProgress[sourceID]?.indexedCount == 2 }

        let progress = try XCTUnwrap(session.sourceProgress[sourceID])
        XCTAssertEqual(progress.indexedCount, 2)
        XCTAssertEqual(progress.failedCount, 1)
        XCTAssertEqual(progress.phase, .scanning)
        let calls = await environment.runScanCalls
        XCTAssertEqual(calls, [sourceID])
    }

    func testScanFailureUpdatesProgressWithASafeAlertAndPathFreeMessage() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        let sourceID = LibraryID()
        await environment.setScanScript(for: sourceID, events: [
            .started(sourceID),
            .failed(.offline(path: "/private/var/some/absolute/path")),
        ])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        session.scanSource(sourceID)
        try await waitUntil {
            if case .failed = session.sourceProgress[sourceID]?.phase { return true }
            return false
        }

        guard case .failed(let alert) = session.sourceProgress[sourceID]?.phase else {
            return XCTFail("expected .failed phase")
        }
        XCTAssertFalse(alert.message.contains("/private"))
        XCTAssertFalse(alert.message.contains("/"))
    }

    func testScanningAnAlreadyScanningSourceIsANoOp() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        let sourceID = LibraryID()
        await environment.setScanScript(for: sourceID, events: [.started(sourceID)])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        session.scanSource(sourceID)
        session.scanSource(sourceID)
        try? await Task.sleep(for: .milliseconds(50))

        let calls = await environment.runScanCalls
        XCTAssertEqual(calls, [sourceID], "a duplicate scanSource(_:) call for an already-scanning source must be a no-op")
    }

    // MARK: 8. Restoration anchor

    func testRestoreGridPositionFindsTheAnchorAcrossMultiplePages() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        let sourceID = LibraryID()
        let query = LibraryQuery(scope: .source(sourceID), sort: .captureDateDescending)
        let pageOne = [makePhoto(libraryID: sourceID, name: "p1.ARW")]
        let anchorPhoto = makePhoto(libraryID: sourceID, name: "anchor.ARW")
        let pageTwo = [anchorPhoto]
        let pageThree = [makePhoto(libraryID: sourceID, name: "p3.ARW")]
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        await environment.setPages(for: query, pages: [pageOne, pageTwo, pageThree])
        await environment.setResolveResult(
            for: anchorPhoto.id,
            .success(.external(url: URL(fileURLWithPath: "/tmp/anchor.ARW"), sourceKind: .externalFolder))
        )

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }
        session.select(.source(sourceID))
        try await waitUntil { session.photos.map(\.id) == pageOne.map(\.id) }

        // "Enter the editor" on the anchor photo -- still on page one, so
        // this also proves `openAsset(for:)` records the anchor before the
        // grid has ever paged past it.
        _ = await session.openAsset(for: anchorPhoto)
        XCTAssertEqual(session.restorationAnchor?.anchorPhotoID, anchorPhoto.id)

        // Simulate having navigated away (e.g. into the editor) by resetting
        // the visible state, then restoring.
        session.select(.smart(.all))
        try await waitUntil { session.loadState == .loaded }

        session.restoreGridPosition()
        try await waitUntil { session.photos.contains { $0.id == anchorPhoto.id } }

        XCTAssertEqual(session.selection, .source(sourceID))
        XCTAssertTrue(session.photos.contains { $0.id == pageOne[0].id })
        XCTAssertTrue(session.photos.contains { $0.id == anchorPhoto.id })
        XCTAssertFalse(session.photos.contains { $0.id == pageThree[0].id }, "must stop at the page containing the anchor, not walk further")
    }

    /// The genuinely-not-found case: the anchor query has fewer pages than
    /// the restoration budget and never contains the anchor id at all --
    /// must fall back to page one without ever reporting an error.
    func testRestoreGridPositionFallsBackToPageOneWhenQueryRunsOutOfPages() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        let sourceID = LibraryID()
        let query = LibraryQuery(scope: .source(sourceID), sort: .captureDateDescending)
        let onlyPhoto = makePhoto(libraryID: sourceID, name: "only.ARW")
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        await environment.setPages(for: query, pages: [[onlyPhoto]])
        await environment.setResolveResult(for: onlyPhoto.id, .success(.external(url: URL(fileURLWithPath: "/tmp/only.ARW"), sourceKind: .externalFolder)))

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }
        session.select(.source(sourceID))
        try await waitUntil { session.photos.map(\.id) == [onlyPhoto.id] }
        _ = await session.openAsset(for: onlyPhoto)

        // Re-script the same query to no longer contain the anchor at all
        // (as if the photo had been removed from the index while the
        // editor was open), then restore.
        await environment.setPages(for: query, pages: [[makePhoto(libraryID: sourceID, name: "different.ARW")]])
        session.select(.smart(.all))
        try await waitUntil { session.loadState == .loaded }

        session.restoreGridPosition()
        try await waitUntil { session.loadState == .loaded && !session.photos.isEmpty }

        XCTAssertNotEqual(session.photos.map(\.id), [onlyPhoto.id], "the anchor is gone -- page one of the same query must show instead")
        if case .failed = session.loadState {
            XCTFail("an anchor that can't be found must never be surfaced as an error")
        }
    }

    func testRestoreGridPositionIsANoOpWithNoRecordedAnchor() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        session.restoreGridPosition()
        try? await Task.sleep(for: .milliseconds(50))

        let fetchCount = await environment.fetchCallCount
        XCTAssertEqual(fetchCount, 1, "with no restoration anchor, restoreGridPosition() must not re-query at all")
    }

    // MARK: Source lifecycle (light coverage)

    func testAddSourceAppendsToSourcesOnSuccess() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        let newFolder = makeFolder(name: "New Drive")
        await environment.setAddSourceResult(.success(newFolder))

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        await session.addSource(at: URL(fileURLWithPath: "/Volumes/NewDrive"), sourceKind: .externalFolder)

        XCTAssertEqual(session.sources.map(\.id), [newFolder.id])
    }

    func testRemoveSourceClearsSelectionWhenTheRemovedSourceWasSelected() async throws {
        let environment = FakeLibraryEnvironment()
        let sourceID = LibraryID()
        await environment.setSourcesResult(.success([makeFolder(id: sourceID)]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        await environment.setPages(for: LibraryQuery(scope: .source(sourceID), sort: .captureDateDescending), pages: [[]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }
        session.select(.source(sourceID))
        try await waitUntil { session.selection == .source(sourceID) }

        await session.removeSource(sourceID)
        try await waitUntil { session.selection == .smart(.all) }

        XCTAssertTrue(session.sources.isEmpty)
    }
}
