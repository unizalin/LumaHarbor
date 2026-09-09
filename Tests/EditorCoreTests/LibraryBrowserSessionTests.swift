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

    /// A separate gate from `fetchPage`'s (below) so a test can hold
    /// `restoreSources()` open independently of any page fetch.
    private var isRestoreSourcesGated = false
    private var isRestoreSourcesGateOpen = false
    private var restoreSourcesGateWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var restoreSourcesEntryCount = 0

    func setRestoreSourcesGated(_ gated: Bool) { isRestoreSourcesGated = gated }

    func openRestoreSourcesGate() {
        isRestoreSourcesGateOpen = true
        for waiter in restoreSourcesGateWaiters { waiter.resume() }
        restoreSourcesGateWaiters = []
    }

    func restoreSources() async throws -> [LibraryFolder] {
        if isRestoreSourcesGated, !isRestoreSourcesGateOpen {
            restoreSourcesEntryCount += 1
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                restoreSourcesGateWaiters.append(continuation)
            }
        }
        return try sourcesResult.get()
    }

    /// Gates for `addSource`/`relinkSource`/`removeSource`, each mirroring
    /// `restoreSources`'s own gate above -- a test opens the matching gate
    /// once it has observed the in-flight `operationState` it's asserting
    /// on.
    private var isAddSourceGated = false
    private var isAddSourceGateOpen = false
    private var addSourceGateWaiters: [CheckedContinuation<Void, Never>] = []

    func setAddSourceGated(_ gated: Bool) { isAddSourceGated = gated }

    func openAddSourceGate() {
        isAddSourceGateOpen = true
        for waiter in addSourceGateWaiters { waiter.resume() }
        addSourceGateWaiters = []
    }

    func addSource(_ url: URL, _ sourceKind: LibrarySourceKind) async throws -> LibraryFolder {
        addSourceCalls.append((url, sourceKind))
        if isAddSourceGated, !isAddSourceGateOpen {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                addSourceGateWaiters.append(continuation)
            }
        }
        return try addSourceResult.get()
    }

    private var isRelinkGated = false
    private var isRelinkGateOpen = false
    private var relinkGateWaiters: [CheckedContinuation<Void, Never>] = []

    func setRelinkGated(_ gated: Bool) { isRelinkGated = gated }

    func openRelinkGate() {
        isRelinkGateOpen = true
        for waiter in relinkGateWaiters { waiter.resume() }
        relinkGateWaiters = []
    }

    func relinkSource(_ libraryID: LibraryID, _ url: URL) async throws -> LibraryFolder {
        relinkCalls.append((libraryID, url))
        if isRelinkGated, !isRelinkGateOpen {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                relinkGateWaiters.append(continuation)
            }
        }
        return try relinkResult.get()
    }

    private var isRemoveGated = false
    private var isRemoveGateOpen = false
    private var removeGateWaiters: [CheckedContinuation<Void, Never>] = []

    func setRemoveGated(_ gated: Bool) { isRemoveGated = gated }

    func openRemoveGate() {
        isRemoveGateOpen = true
        for waiter in removeGateWaiters { waiter.resume() }
        removeGateWaiters = []
    }

    func removeSource(_ libraryID: LibraryID) async throws {
        removeCalls.append(libraryID)
        if isRemoveGated, !isRemoveGateOpen {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                removeGateWaiters.append(continuation)
            }
        }
        if let removeError { throw removeError }
    }

    // MARK: Paging

    /// Every `fetchPage` call this environment has actually seen, in order,
    /// query paired with the exact `cursor` it was called with -- so a test
    /// can assert not just *which* query was fetched but whether it was
    /// correctly paired with a `nil` (first-page) cursor or a specific
    /// prior page's cursor, never one query's cursor handed in alongside a
    /// *different* query's scope/search/sort.
    private(set) var fetchCalls: [(query: LibraryQuery, cursor: PhotoPageCursor?)] = []
    /// Scripted pages, keyed by a query's own string description (stable
    /// and distinct per distinct scope/search/sort/filter combination). Which page
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

    var fetchQueries: [LibraryQuery] { fetchCalls.map(\.query) }
    var fetchCallCount: Int { fetchCalls.count }

    func fetchPage(_ query: LibraryQuery, _ cursor: PhotoPageCursor?, _ limit: Int) async throws -> PhotoPage {
        fetchCalls.append((query, cursor))
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
        String(describing: query)
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

    /// Suspends before any scripted event is delivered -- a test can
    /// observe the session's `operationState` while a scan is stuck here,
    /// then open the gate to let the scripted events (including
    /// `.finished`) run to completion.
    private var isScanGated = false
    private var isScanGateOpen = false
    private var scanGateWaiters: [CheckedContinuation<Void, Never>] = []

    func setScanGated(_ gated: Bool) { isScanGated = gated }

    func openScanGate() {
        isScanGateOpen = true
        for waiter in scanGateWaiters { waiter.resume() }
        scanGateWaiters = []
    }

    func runScan(_ libraryID: LibraryID, _ handler: @Sendable (LibraryScanEvent) async -> Void) async {
        runScanCalls.append(libraryID)
        if isScanGated, !isScanGateOpen {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                scanGateWaiters.append(continuation)
            }
        }
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
    name: String = "IMG_0001.ARW",
    hasEdits: Bool = false,
    lastEditAt: Date? = nil
) -> PhotoAsset {
    PhotoAsset(
        id: id,
        libraryID: libraryID,
        relativePath: name,
        fingerprint: FileFingerprint(fileSize: 1_024, edgeDigest: UUID().uuidString),
        status: .ready,
        lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
        hasEdits: hasEdits,
        lastEditAt: lastEditAt
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

private func makeScanResult(libraryID: LibraryID, indexedCount: Int = 0, failedCount: Int = 0) -> LibraryScanResult {
    LibraryScanResult(
        libraryID: libraryID,
        indexedCount: indexedCount,
        failedCount: failedCount,
        ambiguousCount: 0,
        movedCount: 0,
        wasCancelled: false,
        manifestWriteFailure: nil,
        manifestWriteRecoverySuggestion: nil,
        completedAt: Date(timeIntervalSince1970: 1_700_000_000)
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

    /// Codex pre-landing re-review, finding 1 (P1, blocking): `sources`
    /// must never be dropped just because the user acted (selected a
    /// different scope) before `restoreSources()` itself returned. Since
    /// `start()` is a one-shot no-op after its first call, gating `sources`
    /// on the same `queryGeneration` check used for page results could
    /// leave it permanently empty -- with nothing left to ever populate it.
    func testStartupPublishesSourcesEvenWhenAQueryChangeArrivesWhileRestoringSources() async throws {
        let environment = FakeLibraryEnvironment()
        let sourceID = LibraryID()
        await environment.setSourcesResult(.success([makeFolder(id: sourceID, name: "Trip")]))
        await environment.setRestoreSourcesGated(true)
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        let sourceScopedQuery = LibraryQuery(scope: .source(sourceID), sort: .captureDateDescending)
        let sourcePhoto = makePhoto(libraryID: sourceID)
        await environment.setPages(for: sourceScopedQuery, pages: [[sourcePhoto]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntilAsync { await environment.restoreSourcesEntryCount >= 1 }
        XCTAssertTrue(session.sources.isEmpty, "restoreSources() is still stuck -- nothing to publish yet")

        // The user acts before restoreSources() ever returns.
        session.select(.source(sourceID))
        try await waitUntil { session.photos.map(\.id) == [sourcePhoto.id] }
        XCTAssertEqual(session.selection, .source(sourceID))

        // restoreSources() finally resolves -- its sources must still
        // publish, and must not resurrect the stale default-query page over
        // the selection the user already made in the meantime.
        await environment.openRestoreSourcesGate()
        try await waitUntil { !session.sources.isEmpty }

        XCTAssertEqual(session.sources.map(\.id), [sourceID], "a delayed restoreSources() must still publish its sources")
        XCTAssertEqual(session.selection, .source(sourceID), "the newer selection must not be clobbered by the delayed startup load")
        XCTAssertEqual(session.photos.map(\.id), [sourcePhoto.id], "the newer query's own results must survive")
        XCTAssertEqual(session.loadState, .loaded)

        // The stale default query must never even have been fetched, since
        // a newer query had already taken over by the time restoreSources()
        // resolved.
        let defaultQueryFetchCount = await environment.fetchQueries.filter { $0.scope == .all }.count
        XCTAssertEqual(defaultQueryFetchCount, 0, "the superseded default first page must never be fetched at all")
    }

    /// Same finding: a startup *failure* that resolves after being
    /// superseded must not overwrite the newer query's own (successful)
    /// `loadState` either.
    func testStartupRestorationFailureAfterBeingSupersededDoesNotOverwriteTheNewerLoadState() async throws {
        struct FakeRestoreError: Error {}
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.failure(FakeRestoreError()))
        await environment.setRestoreSourcesGated(true)
        let sourceID = LibraryID()
        let sourceQuery = LibraryQuery(scope: .source(sourceID), sort: .captureDateDescending)
        let photo = makePhoto(libraryID: sourceID)
        await environment.setPages(for: sourceQuery, pages: [[photo]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntilAsync { await environment.restoreSourcesEntryCount >= 1 }

        session.select(.source(sourceID))
        try await waitUntil { session.photos.map(\.id) == [photo.id] }

        await environment.openRestoreSourcesGate()
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(session.loadState, .loaded, "a stale startup failure must not overwrite the newer query's successful loadState")
        XCTAssertEqual(session.photos.map(\.id), [photo.id])
        XCTAssertTrue(session.sources.isEmpty, "the failed restore still produced no sources")
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

    /// Codex pre-landing re-review, finding 2 (P1, blocking): a stale fetch
    /// already in flight when `updateSearchText(_:)` is called must be
    /// invalidated *immediately* -- not only once the 250 ms debounce timer
    /// itself fires `beginNewQuery()`. Otherwise, if that stale fetch
    /// resolves during the debounce window, it still carries the
    /// (unchanged, until debounce fires) generation and can commit its
    /// result even though `searchText` has already visibly moved on.
    func testUpdatingSearchTextDuringAnOutstandingFirstPageFetchDiscardsItEvenBeforeDebounceFires() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        let sourceID = LibraryID()
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        // A fresh selection's first-page fetch is stuck in flight.
        await environment.setGated(true)
        let staleSourceQuery = LibraryQuery(scope: .source(sourceID), sort: .captureDateDescending)
        let stalePhoto = makePhoto(libraryID: sourceID, name: "stale.ARW")
        await environment.setPages(for: staleSourceQuery, pages: [[stalePhoto]])
        session.select(.source(sourceID))
        try await waitUntilAsync { await environment.gatedEntryCount >= 1 }

        // The user types a search query before that stuck fetch -- or the
        // debounce timer -- has had any chance to resolve.
        let finalQuery = LibraryQuery(scope: .source(sourceID), filenameSearch: "final", sort: .captureDateDescending)
        let finalPhoto = makePhoto(libraryID: sourceID, name: "final-match.ARW")
        await environment.setPages(for: finalQuery, pages: [[finalPhoto]])
        session.updateSearchText("final")

        // Release the stale, stuck first-page fetch well *before* the
        // 250 ms debounce could possibly have fired -- it must never be
        // allowed to commit, even though it's the only thing released.
        await environment.openGate()
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertNotEqual(session.photos.map(\.id), [stalePhoto.id], "the stale pre-search-text fetch must never commit its result")

        // Once the debounce actually fires, the *new* search's own fetch
        // must still apply normally.
        try await waitUntil(timeout: 3) { session.photos.map(\.id) == [finalPhoto.id] }
    }

    /// Same finding, for a *next*-page fetch in flight rather than a first
    /// page one.
    func testUpdatingSearchTextDuringAnOutstandingNextPageFetchDiscardsItEvenBeforeDebounceFires() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        let sourceID = LibraryID()
        let query = LibraryQuery(scope: .all, sort: .captureDateDescending)
        let pageOne = [makePhoto(libraryID: sourceID, name: "p1.ARW")]
        let pageTwoStale = [makePhoto(libraryID: sourceID, name: "p2-stale.ARW")]
        await environment.setPages(for: query, pages: [pageOne, pageTwoStale])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }
        XCTAssertEqual(session.photos.map(\.id), pageOne.map(\.id))

        await environment.setGated(true)
        session.loadNextPage()
        try await waitUntilAsync { await environment.gatedEntryCount >= 1 }

        let finalQuery = LibraryQuery(scope: .all, filenameSearch: "final", sort: .captureDateDescending)
        let finalPhoto = makePhoto(libraryID: sourceID, name: "final-match.ARW")
        await environment.setPages(for: finalQuery, pages: [[finalPhoto]])
        session.updateSearchText("final")

        await environment.openGate()
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(session.photos.map(\.id), pageOne.map(\.id), "the stale next-page fetch must never append to photos")
        XCTAssertFalse(session.photos.contains { $0.id == pageTwoStale[0].id })

        try await waitUntil(timeout: 3) { session.photos.map(\.id) == [finalPhoto.id] }
    }

    /// Codex pre-landing re-review round 2, finding 1 (P1, blocking): the
    /// round-1 fix bumped `queryGeneration` synchronously on a search-text
    /// change, but left `nextCursor` (the *outgoing* query's paging
    /// position) sitting there, still non-nil, until the debounce fired.
    /// `PhotoPageCursor` is only valid for the exact query shape that
    /// produced it -- if `loadNextPage()` is called during that window, its
    /// own guards would both pass (`nextCursor != nil`, `loadState ==
    /// .loaded`), and it would fetch the *new* query (already reflecting
    /// the new search text) paired with the *old* query's cursor: a
    /// malformed keyset request that generation-checking alone cannot
    /// catch, since it starts under the already-bumped generation. This
    /// proves the cursor (and paging capability) is invalidated
    /// synchronously too, not just the generation counter.
    func testUpdatingSearchTextImmediatelyInvalidatesTheCursorSoLoadNextPageCannotMixQueries() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        let sourceID = LibraryID()
        let queryA = LibraryQuery(scope: .all, sort: .captureDateDescending)
        let pageOneA = [makePhoto(libraryID: sourceID, name: "a1.ARW")]
        let pageTwoA = [makePhoto(libraryID: sourceID, name: "a2.ARW")]
        await environment.setPages(for: queryA, pages: [pageOneA, pageTwoA])
        let finalQuery = LibraryQuery(scope: .all, filenameSearch: "final", sort: .captureDateDescending)
        let finalPhoto = makePhoto(libraryID: sourceID, name: "final-match.ARW")
        await environment.setPages(for: finalQuery, pages: [[finalPhoto]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }
        XCTAssertEqual(session.photos.map(\.id), pageOneA.map(\.id))
        XCTAssertNotNil(session.nextCursor, "premise: query A has a next page to paginate into")

        session.updateSearchText("final")

        // Immediately -- before the 250 ms debounce has had any chance to
        // fire -- the outgoing query's cursor must already be gone, and
        // loadState must already read as a pending first-page load (which
        // blocks loadNextPage() on its own).
        XCTAssertNil(session.nextCursor, "the outgoing query's cursor must never survive a search-text change")
        XCTAssertEqual(session.loadState, .loadingFirstPage, "a pending first-page load must block loadNextPage() immediately")

        // A caller (scroll/prefetch) tries to page during the debounce
        // window anyway -- must be a complete no-op, not a malformed
        // request mixing the new query with the old cursor.
        session.loadNextPage()
        try? await Task.sleep(for: .milliseconds(80))

        let callsSoFar = await environment.fetchCalls
        XCTAssertFalse(
            callsSoFar.contains { $0.query.filenameSearch == "final" },
            "no fetch for the new search text may have gone out yet, still within the debounce window"
        )
        XCTAssertFalse(
            callsSoFar.contains { $0.cursor != nil && $0.query.filenameSearch == "final" },
            "fetchPage must never be called with the new search query paired with the old query's cursor"
        )

        // Once the debounce actually fires, exactly one first-page (cursor
        // == nil) request for the new search text must go out.
        try await waitUntil(timeout: 3) { session.photos.map(\.id) == [finalPhoto.id] }
        let finalCalls = await environment.fetchCalls.filter { $0.query.filenameSearch == "final" }
        XCTAssertEqual(finalCalls.count, 1)
        XCTAssertNil(finalCalls.first?.cursor, "the new search's first fetch must use a nil cursor, never the old query's")
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
        await environment.setResolveResult(for: photo.id, .success(.external(url: resolvedURL, scopeURL: resolvedURL.deletingLastPathComponent(), sourceKind: .externalFolder)))

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        let result = await session.openAsset(for: photo)
        guard case .external(let url, _, let sourceKind) = result else {
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
        await environment.setResolveResult(for: photo.id, .success(.external(url: url, scopeURL: url.deletingLastPathComponent(), sourceKind: .externalFolder)))

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

    /// Codex pre-landing review, Task 6 blocking finding: a source added and
    /// scanned while `.smart(.all)` is showing must not sit permanently
    /// empty -- the scan actually indexed a photo into the store, so once it
    /// finishes, the currently showing `.all` query must be reloaded and
    /// pick that photo up, with no further user action required.
    func testScanFinishingRefreshesTheCurrentAllQueryFromEmptyToVisible() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        let allQuery = LibraryQuery(scope: .all, sort: .captureDateDescending)
        await environment.setPages(for: allQuery, pages: [[]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }
        XCTAssertTrue(session.photos.isEmpty, "premise: nothing indexed yet")

        let sourceID = LibraryID()
        let indexedPhoto = makePhoto(libraryID: sourceID, name: "fresh.ARW")
        // The scan itself is what would have written this photo into the
        // index -- simulating that here by re-scripting the same `.all`
        // query's page to now include it, exactly as a real re-fetch after
        // an actual SQLite write would see.
        await environment.setPages(for: allQuery, pages: [[indexedPhoto]])
        await environment.setScanScript(for: sourceID, events: [
            .started(sourceID),
            .photosIndexed([indexedPhoto]),
            .finished(makeScanResult(libraryID: sourceID, indexedCount: 1)),
        ])

        session.scanSource(sourceID)
        try await waitUntil { session.photos.map(\.id) == [indexedPhoto.id] }

        XCTAssertEqual(session.loadState, .loaded)
        XCTAssertEqual(session.selection, .smart(.all), "the reload must not itself change the selection")
        let allQueryFetchCount = await environment.fetchQueries.filter { $0.scope == .all }.count
        XCTAssertEqual(allQueryFetchCount, 2, "startup's first page plus exactly one reload after the scan finished")
    }

    /// Codex re-review round 2, blocking finding: a scan doesn't only index
    /// new photos -- it also re-reads each photo's sidecar and rewrites
    /// `hasEdits`/`lastEditAt` on the indexed row (`PhotoLibraryService`'s
    /// rescan path treats those SQLite columns as a rebuildable projection
    /// of the sidecar). `.recentlyEdited` filters/sorts on exactly those two
    /// columns, so a source with pre-existing sidecar edits can turn
    /// `.recentlyEdited` from empty to populated purely by finishing a scan
    /// -- round 1's fix wrongly excluded this scope from the reload.
    func testScanFinishingRefreshesTheCurrentRecentlyEditedQueryFromEmptyToVisible() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        let recentlyEditedQuery = LibraryQuery(scope: .recentlyEdited, sort: .captureDateDescending)
        await environment.setPages(for: recentlyEditedQuery, pages: [[]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }
        session.select(.smart(.recentlyEdited))
        try await waitUntil { session.selection == .smart(.recentlyEdited) && session.loadState == .loaded }
        XCTAssertTrue(session.photos.isEmpty, "premise: no edited photo surfaces yet")

        let sourceID = LibraryID()
        let editedPhoto = makePhoto(
            libraryID: sourceID,
            name: "edited.ARW",
            hasEdits: true,
            lastEditAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        // The scan's edit-state rebuild (from the sidecar) is what would
        // have written this row's hasEdits/lastEditAt -- simulated here by
        // re-scripting the same `.recentlyEdited` query's page to now
        // include it.
        await environment.setPages(for: recentlyEditedQuery, pages: [[editedPhoto]])
        await environment.setScanScript(for: sourceID, events: [
            .started(sourceID),
            .finished(makeScanResult(libraryID: sourceID, indexedCount: 0)),
        ])

        session.scanSource(sourceID)
        try await waitUntil { session.photos.map(\.id) == [editedPhoto.id] }

        XCTAssertEqual(session.loadState, .loaded)
        XCTAssertEqual(session.selection, .smart(.recentlyEdited), "the reload must not itself change the selection")
        let recentlyEditedFetchCount = await environment.fetchQueries.filter { $0.scope == .recentlyEdited }.count
        XCTAssertEqual(recentlyEditedFetchCount, 2, "the initial select(_:)'s fetch plus exactly one reload after the scan finished")
    }

    /// Same finding: a scope the scan does not affect -- `.appStorage`,
    /// populated only by app-copy imports, never by an external source's
    /// scan -- must never be disrupted by that scan's completion.
    func testScanFinishingDoesNotDisruptAnUnaffectedSelection() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        let appStorageQuery = LibraryQuery(scope: .appStorage, sort: .captureDateDescending)
        let appCopyPhoto = makePhoto(libraryID: .appStorage, name: "copy.ARW")
        await environment.setPages(for: appStorageQuery, pages: [[appCopyPhoto]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }
        session.select(.smart(.appStorage))
        try await waitUntil { session.photos.map(\.id) == [appCopyPhoto.id] }

        let sourceID = LibraryID()
        await environment.setScanScript(for: sourceID, events: [
            .started(sourceID),
            .finished(makeScanResult(libraryID: sourceID, indexedCount: 0)),
        ])
        session.scanSource(sourceID)
        try await waitUntil {
            if case .finished = session.sourceProgress[sourceID]?.phase { return true }
            return false
        }
        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(session.selection, .smart(.appStorage))
        XCTAssertEqual(session.photos.map(\.id), [appCopyPhoto.id], "an unaffected selection must survive an unrelated source's scan completion")
        let appStorageFetchCount = await environment.fetchQueries.filter { $0.scope == .appStorage }.count
        XCTAssertEqual(appStorageFetchCount, 1, "no reload must have been triggered for a scope the scan doesn't affect")
    }

    /// Same finding: a scan's completion reload racing against the user
    /// switching selection must lose exactly like any other superseded
    /// query -- the scan-triggered reload of the outgoing scope must never
    /// overwrite the newer selection's own result.
    func testUserSwitchingSelectionDuringAScanCompletionReloadDiscardsTheStaleResult() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        let sourceID = LibraryID()
        let otherSourceID = LibraryID()
        let otherQuery = LibraryQuery(scope: .source(otherSourceID), sort: .captureDateDescending)
        let otherPhoto = makePhoto(libraryID: otherSourceID, name: "other.ARW")
        await environment.setPages(for: otherQuery, pages: [[otherPhoto]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }
        XCTAssertEqual(session.selection, .smart(.all))

        await environment.setScanScript(for: sourceID, events: [
            .started(sourceID),
            .finished(makeScanResult(libraryID: sourceID, indexedCount: 1)),
        ])
        await environment.setGated(true)
        session.scanSource(sourceID)
        try await waitUntilAsync { await environment.gatedEntryCount >= 1 }

        // The user switches away from `.all` before the scan's own reload
        // fetch has resolved.
        session.select(.source(otherSourceID))
        await environment.openGate()
        try await waitUntil { session.photos.map(\.id) == [otherPhoto.id] }

        XCTAssertEqual(session.selection, .source(otherSourceID))
        XCTAssertEqual(session.photos.map(\.id), [otherPhoto.id], "the stale scan-triggered reload of .all must never overwrite the newer selection's result")
        XCTAssertEqual(session.loadState, .loaded)
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
            .success(.external(url: URL(fileURLWithPath: "/tmp/anchor.ARW"), scopeURL: URL(fileURLWithPath: "/tmp", isDirectory: true), sourceKind: .externalFolder))
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
        await environment.setResolveResult(for: onlyPhoto.id, .success(.external(url: URL(fileURLWithPath: "/tmp/only.ARW"), scopeURL: URL(fileURLWithPath: "/tmp", isDirectory: true), sourceKind: .externalFolder)))

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

    // MARK: 9. Operation state

    func testAddSourcePublishesAddingSourceWhileDependencyIsSuspended() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        let newFolder = makeFolder(name: "New Drive")
        await environment.setAddSourceResult(.success(newFolder))
        await environment.setAddSourceGated(true)

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }
        XCTAssertEqual(session.operationState, .idle)

        let addTask = Task { await session.addSource(at: URL(fileURLWithPath: "/Volumes/NewDrive"), sourceKind: .externalFolder) }
        try await waitUntil { session.operationState == .addingSource }

        await environment.openAddSourceGate()
        await addTask.value
        XCTAssertEqual(session.operationState, .idle)
        XCTAssertEqual(session.sources.map(\.id), [newFolder.id])
    }

    func testAddSourceReturnsToIdleAfterFailure() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        await environment.setAddSourceResult(.failure(FakeEnvironmentError.unconfigured))

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        await session.addSource(at: URL(fileURLWithPath: "/Volumes/NewDrive"), sourceKind: .externalFolder)

        XCTAssertEqual(session.operationState, .idle)
        XCTAssertNotNil(session.alert)
    }

    func testRelinkAndRemovePublishDistinctOperationStates() async throws {
        let environment = FakeLibraryEnvironment()
        let sourceID = LibraryID()
        let source = makeFolder(id: sourceID, connectionState: .needsAuthorization)
        await environment.setSourcesResult(.success([source]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        await environment.setRelinkResult(.success(makeFolder(id: sourceID, connectionState: .ready)))
        await environment.setRelinkGated(true)
        await environment.setRemoveGated(true)

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.sources.count == 1 }

        let relinkTask = Task { await session.relinkSource(sourceID, to: source.rootURL) }
        try await waitUntil { session.operationState == .reconnectingSource(sourceID) }
        await environment.openRelinkGate()
        await relinkTask.value
        XCTAssertEqual(session.operationState, .idle)

        let removeTask = Task { await session.removeSource(sourceID) }
        try await waitUntil { session.operationState == .removingSource(sourceID) }
        await environment.openRemoveGate()
        await removeTask.value
        XCTAssertEqual(session.operationState, .idle)
        XCTAssertTrue(session.sources.isEmpty)
    }

    func testRelinkAndRemoveReturnToIdleAfterFailure() async throws {
        let environment = FakeLibraryEnvironment()
        let sourceID = LibraryID()
        await environment.setSourcesResult(.success([makeFolder(id: sourceID)]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        await environment.setRelinkResult(.failure(FakeEnvironmentError.unconfigured))
        await environment.setRemoveError(FakeEnvironmentError.unconfigured)

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.sources.count == 1 }

        await session.relinkSource(sourceID, to: URL(fileURLWithPath: "/Volumes/Drive"))
        XCTAssertEqual(session.operationState, .idle)
        XCTAssertNotNil(session.alert)

        session.alert = nil
        await session.removeSource(sourceID)
        XCTAssertEqual(session.operationState, .idle)
        XCTAssertNotNil(session.alert)
    }

    func testScanPublishesScanningSourceOperationState() async throws {
        let environment = FakeLibraryEnvironment()
        let sourceID = LibraryID()
        await environment.setSourcesResult(.success([makeFolder(id: sourceID)]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        await environment.setScanScript(for: sourceID, events: [.started(sourceID), .finished(makeScanResult(libraryID: sourceID))])
        await environment.setScanGated(true)

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.sources.count == 1 }
        XCTAssertEqual(session.operationState, .idle)

        session.scanSource(sourceID)
        try await waitUntil { session.operationState == .scanningSource(sourceID) }

        await environment.openScanGate()
        try await waitUntil { session.operationState == .idle }
        XCTAssertEqual(session.sourceProgress[sourceID]?.phase, .finished)
    }

    func testScanReturnsToIdleAfterFailure() async throws {
        let environment = FakeLibraryEnvironment()
        let sourceID = LibraryID()
        await environment.setSourcesResult(.success([makeFolder(id: sourceID)]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        await environment.setScanScript(for: sourceID, events: [.failed(.indexUnavailable("fixture"))])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.sources.count == 1 }

        session.scanSource(sourceID)
        try await waitUntil { session.operationState == .idle }

        guard case .failed = session.sourceProgress[sourceID]?.phase else {
            return XCTFail("expected a failed scan phase")
        }
    }

    /// Reproduces the stale-`defer` bug: `addSource` and `relinkSource` used
    /// to unconditionally reset `operationState = .idle` when they finished,
    /// even if a newer operation (started after them) had already
    /// overwritten `operationState` with its own value. This asserts that an
    /// `addSource` call that finishes late does not clobber a
    /// `relinkSource` call for a different source that started later and is
    /// still in flight -- only the operation that actually set the current
    /// state may clear it, mirroring `scanSource(_:)`'s own completion
    /// guard.
    func testAddSourceCompletionDoesNotClobberNewerReconnectOperationState() async throws {
        let environment = FakeLibraryEnvironment()
        let existingSourceID = LibraryID()
        let existingSource = makeFolder(id: existingSourceID, connectionState: .needsAuthorization)
        await environment.setSourcesResult(.success([existingSource]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        let newFolder = makeFolder(name: "New Drive")
        await environment.setAddSourceResult(.success(newFolder))
        await environment.setAddSourceGated(true)
        await environment.setRelinkResult(.success(makeFolder(id: existingSourceID, connectionState: .ready)))
        await environment.setRelinkGated(true)

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.sources.count == 1 }

        let addTask = Task { await session.addSource(at: URL(fileURLWithPath: "/Volumes/NewDrive"), sourceKind: .externalFolder) }
        try await waitUntil { session.operationState == .addingSource }

        let relinkTask = Task { await session.relinkSource(existingSourceID, to: existingSource.rootURL) }
        try await waitUntil { session.operationState == .reconnectingSource(existingSourceID) }

        await environment.openAddSourceGate()
        await addTask.value
        XCTAssertEqual(
            session.operationState,
            .reconnectingSource(existingSourceID),
            "addSource finishing must not clobber the still in-flight relinkSource's operation state"
        )

        await environment.openRelinkGate()
        await relinkTask.value
        XCTAssertEqual(session.operationState, .idle)
    }

    func testOperationStateDoesNotChangeSourceProgressSemantics() async throws {
        let environment = FakeLibraryEnvironment()
        let sourceID = LibraryID()
        await environment.setSourcesResult(.success([makeFolder(id: sourceID)]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        await environment.setScanScript(
            for: sourceID,
            events: [.started(sourceID), .photosIndexed([makePhoto(libraryID: sourceID)]), .finished(makeScanResult(libraryID: sourceID))]
        )

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.sources.count == 1 }

        session.scanSource(sourceID)
        try await waitUntil { session.operationState == .idle }

        XCTAssertEqual(session.sourceProgress[sourceID]?.indexedCount, 1)
        XCTAssertEqual(session.sourceProgress[sourceID]?.phase, .finished)
    }

    // MARK: 8. iPad curation and touch selection

    func testCatalogFiltersReloadThroughTheSharedLibraryQuery() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))

        let defaultQuery = LibraryQuery(scope: .all, sort: .captureDateDescending)
        await environment.setPages(for: defaultQuery, pages: [[]])

        let captureDate = PhotoDateRange(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_100_000)
        )
        let filteredQuery = LibraryQuery(
            scope: .all,
            sort: .captureDateDescending,
            rating: .exact(4),
            flag: .pick,
            hasEdits: true,
            format: "arw",
            camera: "Sony",
            lens: "35mm",
            captureDate: captureDate,
            keyword: "Selects"
        )
        let filteredPhoto = makePhoto(libraryID: LibraryID(), name: "Select.ARW", hasEdits: true)
        await environment.setPages(for: filteredQuery, pages: [[filteredPhoto]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.loadState == .loaded }

        session.setCatalogFilters(
            rating: .exact(4),
            flag: .pick,
            hasEdits: true,
            format: "arw",
            camera: "Sony",
            lens: "35mm",
            captureDate: captureDate,
            keyword: " Selects "
        )

        try await waitUntil { session.photos.map(\.id) == [filteredPhoto.id] }
        XCTAssertEqual(session.currentQuery, filteredQuery)
        XCTAssertEqual(session.keywordFilter, "Selects")
    }

    func testCatalogFilterClearRestoresUnfilteredQuery() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))

        let defaultQuery = LibraryQuery(scope: .all, sort: .captureDateDescending)
        let photo = makePhoto(libraryID: LibraryID(), name: "All.ARW")
        await environment.setPages(for: defaultQuery, pages: [[photo]])

        let filteredQuery = LibraryQuery(scope: .all, sort: .captureDateDescending, rating: .unrated)
        await environment.setPages(for: filteredQuery, pages: [[]])

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.photos.map(\.id) == [photo.id] }

        session.setCatalogFilters(rating: .unrated)
        try await waitUntil { session.currentQuery == filteredQuery }
        session.clearCatalogFilters()
        try await waitUntil { session.currentQuery == defaultQuery && session.photos.map(\.id) == [photo.id] }

        XCTAssertNil(session.ratingFilter)
        XCTAssertNil(session.keywordFilter)
    }

    func testQuickFilterUpdatesPreserveTheOtherCatalogFilters() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))

        session.setCatalogFilters(
            rating: .exact(2),
            flag: .pick,
            hasEdits: true,
            format: "ARW",
            camera: "ILCE",
            lens: "35mm",
            captureDate: PhotoDateRange(
                start: Date(timeIntervalSince1970: 1_700_000_000),
                end: Date(timeIntervalSince1970: 1_700_100_000)
            ),
            keyword: "Trip"
        )

        session.setRatingFilter(.exact(5))
        session.setFlagFilter(.reject)
        session.setHasEditsFilter(nil)

        XCTAssertEqual(session.ratingFilter, .exact(5))
        XCTAssertEqual(session.flagFilter, .reject)
        XCTAssertNil(session.hasEditsFilter)
        XCTAssertEqual(session.formatFilter, "ARW")
        XCTAssertEqual(session.cameraFilter, "ILCE")
        XCTAssertEqual(session.lensFilter, "35mm")
        XCTAssertEqual(session.keywordFilter, "Trip")
        XCTAssertNotNil(session.captureDateFilter)
    }

    func testTouchSelectionSupportsToggleSelectAllAndClear() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        let first = makePhoto(libraryID: LibraryID(), name: "First.ARW")
        let second = makePhoto(libraryID: LibraryID(), name: "Second.ARW")
        await environment.setPages(
            for: LibraryQuery(scope: .all, sort: .captureDateDescending),
            pages: [[first, second]]
        )

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.photos.count == 2 }

        session.togglePhotoSelection(first.id)
        XCTAssertEqual(session.selectedPhotoIDs, [first.id])
        session.selectAllVisiblePhotos()
        XCTAssertEqual(session.selectedPhotoIDs, Set([first.id, second.id]))
        session.togglePhotoSelection(second.id)
        XCTAssertEqual(session.selectedPhotoIDs, [first.id])
        session.clearPhotoSelection()
        XCTAssertTrue(session.selectedPhotoIDs.isEmpty)
    }

    func testMarkPhotoEditedUpdatesLoadedBadgeWithoutClearingSelection() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        let photo = makePhoto(libraryID: LibraryID(), name: "Edited.ARW")
        await environment.setPages(
            for: LibraryQuery(scope: .all, sort: .captureDateDescending),
            pages: [[photo]]
        )

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.photos.map(\.id) == [photo.id] }
        session.togglePhotoSelection(photo.id)

        session.markPhotoHasEdits(photo.id, hasEdits: true)

        XCTAssertTrue(session.photos[0].hasEdits)
        XCTAssertEqual(session.selectedPhotoIDs, [photo.id])
    }

    func testUpdatePhotoCurationPreservesSelectionAndUpdatesLoadedProjection() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        let photo = makePhoto(libraryID: LibraryID(), name: "Curation.ARW")
        await environment.setPages(
            for: LibraryQuery(scope: .all, sort: .captureDateDescending),
            pages: [[photo]]
        )

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.photos.map(\.id) == [photo.id] }
        session.togglePhotoSelection(photo.id)

        let keyword = PhotoKeyword.make(from: "Trip")!
        session.updatePhotoCuration(
            photoID: photo.id,
            rating: 4,
            flag: .pick,
            keywords: [keyword]
        )

        XCTAssertEqual(session.photos[0].rating, 4)
        XCTAssertEqual(session.photos[0].flag, .pick)
        XCTAssertEqual(session.photos[0].keywords, [keyword])
        XCTAssertEqual(session.selectedPhotoIDs, [photo.id])
    }

    func testRefreshRequeriesCurrentPageAndClearsSelection() async throws {
        let environment = FakeLibraryEnvironment()
        await environment.setSourcesResult(.success([]))
        let photo = makePhoto(libraryID: LibraryID(), name: "Refresh.ARW")
        await environment.setPages(
            for: LibraryQuery(scope: .all, sort: .captureDateDescending),
            pages: [[photo]]
        )

        let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
        session.start()
        try await waitUntil { session.photos.map(\.id) == [photo.id] }
        session.togglePhotoSelection(photo.id)
        let callsBeforeRefresh = await environment.fetchCallCount

        session.refresh()
        try await waitUntilAsync { await environment.fetchCallCount >= callsBeforeRefresh + 1 }
        try await waitUntil { session.loadState == .loaded && session.photos.map(\.id) == [photo.id] }

        XCTAssertTrue(session.selectedPhotoIDs.isEmpty)
        let callsAfterRefresh = await environment.fetchCallCount
        XCTAssertEqual(callsAfterRefresh, callsBeforeRefresh + 1)
    }
}
