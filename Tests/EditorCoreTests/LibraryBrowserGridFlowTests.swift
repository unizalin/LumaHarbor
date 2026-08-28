import Foundation
import XCTest
@testable import EditorCore
import Localization
import PhotoLibraryCore

// MARK: - Fixtures (scoped to this file only)

/// `LibraryBrowserSessionTests.swift` already has a much larger
/// `FakeLibraryEnvironment`/`makeDependencies`/`makePhoto`/`makeFolder`/
/// `waitUntil` set, but every one of them is `private` to that file, and
/// that file isn't part of this task's file list to extend or make
/// internal. This file defines its own minimal subset scoped to exactly
/// what the five grid-flow scenarios below need (gated/scripted paging,
/// offline gating, and multi-page restoration) rather than the full surface
/// (add/relink/remove source, scan events) the other file's tests exercise.
/// Worth flagging in the Task 7 report as a fixture-duplication call, not a
/// silent extraction of shared test helpers.
private actor GridFlowFakeEnvironment {
    var sourcesResult: Result<[LibraryFolder], Error> = .success([])
    func setSourcesResult(_ result: Result<[LibraryFolder], Error>) { sourcesResult = result }
    func restoreSources() async throws -> [LibraryFolder] { try sourcesResult.get() }

    private(set) var fetchCalls: [(query: LibraryQuery, cursor: PhotoPageCursor?)] = []
    private var pagesBySignature: [String: [[PhotoAsset]]] = [:]
    private var isGated = false
    private var isGateOpen = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var gatedEntryCount = 0

    func setPages(for query: LibraryQuery, pages: [[PhotoAsset]]) {
        pagesBySignature[Self.signature(for: query)] = pages
    }

    func setGated(_ gated: Bool) { isGated = gated }

    /// Permanently opens the gate, matching the level-triggered
    /// `InspectionGate` pattern this codebase's tests already use.
    func openGate() {
        isGateOpen = true
        for waiter in gateWaiters { waiter.resume() }
        gateWaiters = []
    }

    var fetchCallCount: Int { fetchCalls.count }
    var fetchQueries: [LibraryQuery] { fetchCalls.map(\.query) }

    func fetchPage(_ query: LibraryQuery, _ cursor: PhotoPageCursor?, _ limit: Int) async throws -> PhotoPage {
        fetchCalls.append((query, cursor))
        if isGated, !isGateOpen {
            gatedEntryCount += 1
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gateWaiters.append(continuation)
            }
        }
        let signature = Self.signature(for: query)
        let pages = pagesBySignature[signature] ?? []
        let index: Int
        if let cursor {
            guard let matchIndex = pages.firstIndex(where: { $0.last?.id == cursor.photoID }) else {
                return PhotoPage(photos: [], nextCursor: nil)
            }
            index = matchIndex + 1
        } else {
            index = 0
        }
        guard index < pages.count else { return PhotoPage(photos: [], nextCursor: nil) }
        let batch = pages[index]
        let hasMore = index + 1 < pages.count
        let nextCursor: PhotoPageCursor? = (hasMore && !batch.isEmpty) ? PhotoPageCursor(photoID: batch.last!.id) : nil
        return PhotoPage(photos: batch, nextCursor: nextCursor)
    }

    private static func signature(for query: LibraryQuery) -> String {
        "\(query.scope)|\(query.filenameSearch ?? "")|\(query.sort)"
    }

    private(set) var resolveOpenAssetCalls: [PhotoID] = []
    private var resolveResults: [PhotoID: Result<LibraryOpenAsset, Error>] = [:]

    func setResolveResult(for photoID: PhotoID, _ result: Result<LibraryOpenAsset, Error>) {
        resolveResults[photoID] = result
    }

    func resolveOpenAsset(_ photoID: PhotoID) throws -> LibraryOpenAsset {
        resolveOpenAssetCalls.append(photoID)
        guard let result = resolveResults[photoID] else { throw GridFlowFixtureError.unconfigured }
        return try result.get()
    }
}

private enum GridFlowFixtureError: Error { case unconfigured }

private func makeGridFlowDependencies(_ environment: GridFlowFakeEnvironment) -> LibraryBrowserDependencies {
    LibraryBrowserDependencies(
        restoreSources: { try await environment.restoreSources() },
        fetchPage: { query, cursor, limit in try await environment.fetchPage(query, cursor, limit) },
        childDirectories: { _, _ in [] },
        addSource: { _, _ in throw GridFlowFixtureError.unconfigured },
        relinkSource: { _, _ in throw GridFlowFixtureError.unconfigured },
        runScan: { _, _ in },
        removeSource: { _ in },
        resolveOpenAsset: { photoID in try await environment.resolveOpenAsset(photoID) }
    )
}

private func makeGridFlowPhoto(
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

private func makeGridFlowFolder(
    id: LibraryID = LibraryID(),
    name: String = "Source",
    connectionState: LibraryConnectionState = .ready
) -> LibraryFolder {
    LibraryFolder(
        id: id,
        displayName: name,
        rootURL: URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true),
        connectionState: connectionState
    )
}

private func waitUntilGridFlow(
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

private func waitUntilGridFlowAsync(
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

/// Task 7's own contract tests over `LibraryBrowserSession`: the two small
/// grid-support additions this task makes (`folder(for:)`,
/// `isSortFixedByScope`), plus the five scenarios the task brief calls out
/// by name -- near-end prefetch, a rapid scope/search/sort burst, editor
/// return restoring by `PhotoID`, a missing anchor falling back to page
/// one, and an offline selection's alert. Most of the underlying guarantees
/// already exist and are covered from a different angle in
/// `LibraryBrowserSessionTests.swift`; these tests exercise them the way
/// `PadLibraryGrid`/`PadThumbnailCell` actually call this session, so they
/// double as a regression contract for that UI layer, which has no test
/// target of its own that `swift test` can compile.
@MainActor
final class LibraryBrowserGridFlowTests: XCTestCase {

    // MARK: 1. folder(for:) -- grid/cell source lookup (new, Task 7)

    func testFolderForReturnsTheMatchingSourceOrNilForAppStorage() async throws {
        let environment = GridFlowFakeEnvironment()
        let sourceID = LibraryID()
        let folder = makeGridFlowFolder(id: sourceID, name: "Trip")
        await environment.setSourcesResult(.success([folder]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])

        let session = LibraryBrowserSession(dependencies: makeGridFlowDependencies(environment))
        session.start()
        try await waitUntilGridFlow { session.loadState == .loaded }

        XCTAssertEqual(session.folder(for: sourceID)?.id, sourceID)
        XCTAssertNil(session.folder(for: .appStorage), "the synthetic App Copies library never appears in sources")
    }

    // MARK: 2. isSortFixedByScope (new, Task 7)

    func testIsSortFixedByScopeIsTrueOnlyForRecentlyEdited() async throws {
        let environment = GridFlowFakeEnvironment()
        await environment.setSourcesResult(.success([]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        await environment.setPages(for: LibraryQuery(scope: .recentlyEdited, sort: .captureDateDescending), pages: [[]])

        let session = LibraryBrowserSession(dependencies: makeGridFlowDependencies(environment))
        session.start()
        try await waitUntilGridFlow { session.loadState == .loaded }
        XCTAssertFalse(session.isSortFixedByScope)

        session.select(.smart(.recentlyEdited))
        try await waitUntilGridFlow { session.selection == .smart(.recentlyEdited) && session.loadState == .loaded }
        XCTAssertTrue(session.isSortFixedByScope)
    }

    // MARK: 3. Near-end sentinel prefetch (brief Step 1 / Step 2)

    func testNearEndSentinelLoadsExactlyOneNextPage() async throws {
        let environment = GridFlowFakeEnvironment()
        await environment.setSourcesResult(.success([]))
        let sourceID = LibraryID()
        let query = LibraryQuery(scope: .all, sort: .captureDateDescending)
        let pageOne = (0..<LibraryBrowserSession.pageSize).map { makeGridFlowPhoto(libraryID: sourceID, name: "p1-\($0).ARW") }
        let pageTwo = [makeGridFlowPhoto(libraryID: sourceID, name: "p2.ARW")]
        await environment.setPages(for: query, pages: [pageOne, pageTwo])

        let session = LibraryBrowserSession(dependencies: makeGridFlowDependencies(environment))
        session.start()
        try await waitUntilGridFlow { session.loadState == .loaded }

        // Simulate the grid's own "last 20 visible items" trigger firing
        // once per cell as the user scrolls near the end of page one --
        // exactly the burst `PadLibraryGrid`'s per-cell `onAppear` produces.
        for _ in (session.photos.count - 20)..<session.photos.count {
            session.loadNextPage()
        }
        try await waitUntilGridFlow { session.photos.count == pageOne.count + pageTwo.count }

        let fetchCount = await environment.fetchCallCount
        XCTAssertEqual(fetchCount, 2, "a burst of near-end sentinel calls must still only fetch page two once")
    }

    // MARK: 4. Rapid scope/search/sort burst shows only the final generation

    func testRapidScopeSearchAndSortChangesShowOnlyTheFinalGeneration() async throws {
        let environment = GridFlowFakeEnvironment()
        let sourceA = LibraryID()
        let sourceB = LibraryID()
        await environment.setSourcesResult(.success([makeGridFlowFolder(id: sourceA), makeGridFlowFolder(id: sourceB)]))
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        await environment.setGated(true)

        let session = LibraryBrowserSession(dependencies: makeGridFlowDependencies(environment))
        session.start()
        try await waitUntilGridFlowAsync { await environment.gatedEntryCount >= 1 }

        // A rapid burst -- scope, then sort, then a search -- all before the
        // very first (startup) fetch has even resolved.
        session.select(.source(sourceA))
        session.setSort(.filenameAscending)
        session.select(.source(sourceB))
        session.updateSearchText("final")

        let finalQuery = LibraryQuery(scope: .source(sourceB), filenameSearch: "final", sort: .filenameAscending)
        let finalPhoto = makeGridFlowPhoto(libraryID: sourceB, name: "final-match.ARW")
        await environment.setPages(for: finalQuery, pages: [[finalPhoto]])

        await environment.openGate()
        try await waitUntilGridFlow(timeout: 3) { session.photos.map(\.id) == [finalPhoto.id] }

        XCTAssertEqual(session.selection, .source(sourceB), "only the final scope of the burst must be showing")
        XCTAssertEqual(session.sort, .filenameAscending, "only the final sort of the burst must be showing")
        XCTAssertEqual(session.searchText, "final", "only the final search text of the burst must be showing")
        XCTAssertEqual(session.loadState, .loaded)
    }

    // MARK: 5. Editor return restores by PhotoID

    func testEditorReturnRestoresByPhotoIDAcrossPages() async throws {
        let environment = GridFlowFakeEnvironment()
        await environment.setSourcesResult(.success([]))
        let sourceID = LibraryID()
        let query = LibraryQuery(scope: .source(sourceID), sort: .captureDateDescending)
        let pageOne = [makeGridFlowPhoto(libraryID: sourceID, name: "p1.ARW")]
        let anchorPhoto = makeGridFlowPhoto(libraryID: sourceID, name: "anchor.ARW")
        let pageTwo = [anchorPhoto]
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        await environment.setPages(for: query, pages: [pageOne, pageTwo])
        await environment.setResolveResult(
            for: anchorPhoto.id,
            .success(.external(url: URL(fileURLWithPath: "/tmp/anchor.ARW"), sourceKind: .externalFolder))
        )

        let session = LibraryBrowserSession(dependencies: makeGridFlowDependencies(environment))
        session.start()
        try await waitUntilGridFlow { session.loadState == .loaded }
        session.select(.source(sourceID))
        try await waitUntilGridFlow { session.photos.map(\.id) == pageOne.map(\.id) }

        // The grid's own near-end prefetch would have paged this in before
        // the user ever reached the anchor on page two.
        session.loadNextPage()
        try await waitUntilGridFlow { session.photos.map(\.id) == (pageOne + pageTwo).map(\.id) }

        _ = await session.openAsset(for: anchorPhoto)
        XCTAssertEqual(session.restorationAnchor?.anchorPhotoID, anchorPhoto.id)

        // Simulate returning from the editor: the grid resets to a
        // different scope, then restores.
        session.select(.smart(.all))
        try await waitUntilGridFlow { session.loadState == .loaded }

        session.restoreGridPosition()
        try await waitUntilGridFlow { session.photos.contains { $0.id == anchorPhoto.id } }

        XCTAssertEqual(session.selection, .source(sourceID))
        XCTAssertTrue(
            session.photos.contains { $0.id == anchorPhoto.id },
            "restoration must land on the exact PhotoID that was open, not just page one"
        )
    }

    // MARK: 6. Missing anchor falls back to page one

    func testMissingAnchorFallsBackToPageOne() async throws {
        let environment = GridFlowFakeEnvironment()
        await environment.setSourcesResult(.success([]))
        let sourceID = LibraryID()
        let query = LibraryQuery(scope: .source(sourceID), sort: .captureDateDescending)
        let onlyPhoto = makeGridFlowPhoto(libraryID: sourceID, name: "only.ARW")
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[]])
        await environment.setPages(for: query, pages: [[onlyPhoto]])
        await environment.setResolveResult(
            for: onlyPhoto.id,
            .success(.external(url: URL(fileURLWithPath: "/tmp/only.ARW"), sourceKind: .externalFolder))
        )

        let session = LibraryBrowserSession(dependencies: makeGridFlowDependencies(environment))
        session.start()
        try await waitUntilGridFlow { session.loadState == .loaded }
        session.select(.source(sourceID))
        try await waitUntilGridFlow { session.photos.map(\.id) == [onlyPhoto.id] }
        _ = await session.openAsset(for: onlyPhoto)

        // The anchor photo is gone from the index by the time the editor
        // closes (removed, moved out of scope, or a rescan pruned it).
        let replacementPhoto = makeGridFlowPhoto(libraryID: sourceID, name: "different.ARW")
        await environment.setPages(for: query, pages: [[replacementPhoto]])
        session.select(.smart(.all))
        try await waitUntilGridFlow { session.loadState == .loaded }

        session.restoreGridPosition()
        try await waitUntilGridFlow { session.loadState == .loaded && !session.photos.isEmpty }

        XCTAssertEqual(
            session.photos.map(\.id), [replacementPhoto.id],
            "a missing anchor must fall back to a fresh page one of the same query"
        )
        if case .failed = session.loadState {
            XCTFail("a missing anchor must never surface as an error")
        }
    }

    // MARK: 7. Offline selection returns a localized, actionable alert instead of opening

    func testOfflineSelectionReturnsLocalizedActionableAlertInsteadOfOpening() async throws {
        let environment = GridFlowFakeEnvironment()
        let sourceID = LibraryID()
        await environment.setSourcesResult(.success([makeGridFlowFolder(id: sourceID, connectionState: .offline)]))
        let photo = makeGridFlowPhoto(libraryID: sourceID)
        await environment.setPages(for: LibraryQuery(scope: .all, sort: .captureDateDescending), pages: [[photo]])

        let session = LibraryBrowserSession(dependencies: makeGridFlowDependencies(environment))
        session.start()
        try await waitUntilGridFlow { session.loadState == .loaded }

        let result = await session.openAsset(for: photo)

        XCTAssertNil(result, "an offline source must never actually open")
        let alert = try XCTUnwrap(session.alert, "an offline selection must surface a localized, actionable alert")
        XCTAssertFalse(alert.title.isEmpty)
        XCTAssertNotNil(alert.nextStep, "the alert must give the user an actionable next step, not just a bare failure")
        XCTAssertEqual(alert.nextStep, L10n.t("Reconnect the source, then try again."))
        let calls = await environment.resolveOpenAssetCalls
        XCTAssertTrue(calls.isEmpty, "an offline source must never even attempt to resolve the asset")
    }
}
