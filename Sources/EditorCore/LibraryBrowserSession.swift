import Combine
import Foundation
import Localization
import PhotoLibraryCore

/// What the sidebar currently has selected — the UI-facing counterpart to
/// Task 1's `LibraryScope`, which is the *query*-facing one. `.smart`
/// covers every scope that isn't tied to one specific source (`.all`,
/// `.appStorage`, `.recentlyEdited`); `.source`/`.folder` mirror
/// `LibraryScope` exactly, since those two already name a specific place.
public enum LibrarySelection: Sendable, Equatable {
    case smart(LibraryScope)
    case source(LibraryID)
    case folder(libraryID: LibraryID, relativePath: String)

    var scope: LibraryScope {
        switch self {
        case .smart(let scope): return scope
        case .source(let libraryID): return .source(libraryID)
        case .folder(let libraryID, let relativePath): return .folder(libraryID: libraryID, relativePath: relativePath)
        }
    }

    /// Inverse of `scope`: `.source`/`.folder` map back exactly; every other
    /// `LibraryScope` case (`.all`, `.appStorage`, `.recentlyEdited`) is a
    /// smart scope with no single source of its own. Used to reconstruct a
    /// selection from a `GridRestorationState`'s saved `LibraryQuery`.
    static func matching(_ scope: LibraryScope) -> LibrarySelection {
        switch scope {
        case .source(let libraryID): return .source(libraryID)
        case .folder(let libraryID, let relativePath): return .folder(libraryID: libraryID, relativePath: relativePath)
        case .all, .appStorage, .recentlyEdited: return .smart(scope)
        }
    }
}

/// Where a page-fetch cycle currently stands. `.failed` carries the
/// `EditorAlert` itself (never a bare `Bool`) so a view can show the exact
/// safe, actionable message without reaching into a separate property.
public enum LibraryBrowserLoadState: Sendable, Equatable {
    case idle
    case loadingFirstPage
    case loadingNextPage
    case loaded
    case failed(EditorAlert)
}

/// What the grid needs to restore its scroll position after a round trip
/// through the editor: the exact query that was showing, and which photo to
/// scroll back to. Carries only a `PhotoID`, matching `PhotoPageCursor`'s
/// own "never a URL or absolute path" contract.
public struct GridRestorationState: Sendable, Equatable {
    public var query: LibraryQuery
    public var anchorPhotoID: PhotoID?

    public init(query: LibraryQuery, anchorPhotoID: PhotoID?) {
        self.query = query
        self.anchorPhotoID = anchorPhotoID
    }
}

/// One source's most recently observed scan progress (Task 3's
/// `LibraryScanEvent`s, folded into a shape a sidebar row can render
/// directly without re-deriving it from raw events itself).
public struct LibrarySourceScanProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case scanning
        case finished
        case failed(EditorAlert)
    }

    public var phase: Phase
    public var indexedCount: Int
    public var failedCount: Int

    public init(phase: Phase, indexedCount: Int = 0, failedCount: Int = 0) {
        self.phase = phase
        self.indexedCount = indexedCount
        self.failedCount = failedCount
    }
}

/// Main-actor query, paging, selection, restoration and per-source progress
/// state machine for the multi-source library browser (Task 5) — the
/// counterpart, on the browsing side, to `PhotoDocumentEditor` on the
/// open/document side. Every dependency is seamed through
/// `LibraryBrowserDependencies`, so this type is fully testable without SQLite,
/// a real folder scan, or the sandbox.
///
/// **Generations.** `queryGeneration` increments on every scope, search or
/// sort change; every in-flight page fetch captures it before its first
/// `await` and discards its result if the generation has since moved on --
/// the same pattern `PhotoDocumentEditor.OperationToken` already
/// establishes for document opens, applied here to queries instead.
///
/// **Bounded memory.** `photos` never grows without limit: it holds at most
/// the current page window plus two prefetched pages (`pageWindowCount`,
/// pages of `pageSize` rows each) — a long scroll session drops its oldest
/// rows rather than accumulating every page it has ever shown.
@MainActor
public final class LibraryBrowserSession: ObservableObject {
    /// Production page size (global constraint: default 100, never exceeds
    /// 200 -- `PhotoIndexStore.page(matching:after:limit:)`'s own hard cap).
    public static let pageSize = 100
    /// Pages of `pageSize` rows kept in `photos` at once: the current page
    /// plus two prefetched ones.
    static let pageWindowCount = 3
    /// Restoring the grid position after returning from the editor queries
    /// at most this many pages looking for the anchor before giving up and
    /// falling back to page one -- never an unbounded walk of the index.
    static let maximumRestorationPages = 20
    /// How long a burst of `updateSearchText(_:)` calls waits before the
    /// last one actually reaches the index -- not part of
    /// `LibraryBrowserDependencies` (Task 7 builds the toolbar around this,
    /// but the debounce itself belongs to this session, not the UI layer).
    static let searchDebounceDelay: Duration = .milliseconds(250)

    @Published public private(set) var sources: [LibraryFolder] = []
    @Published public private(set) var selection: LibrarySelection = .smart(.all)
    @Published public private(set) var sort: PhotoSort = .captureDateDescending
    @Published public private(set) var searchText: String = ""
    @Published public private(set) var photos: [PhotoAsset] = []
    @Published public private(set) var nextCursor: PhotoPageCursor?
    @Published public private(set) var loadState: LibraryBrowserLoadState = .idle
    /// Keyed by `LibraryID`, present only for a source this session has
    /// actually scanned (via `scanSource(_:)`) since it launched.
    @Published public private(set) var sourceProgress: [LibraryID: LibrarySourceScanProgress] = [:]
    /// One-off action failures (add/relink/remove a source, open gated by
    /// an offline source, resolving an asset) -- distinct from
    /// `loadState`'s `.failed`, which is specifically a page-fetch failure.
    @Published public var alert: EditorAlert?
    /// Saved the moment `openAsset(for:)` successfully hands a photo off to
    /// the editor; consumed by `restoreGridPosition()` on return.
    @Published public private(set) var restorationAnchor: GridRestorationState?

    private let dependencies: LibraryBrowserDependencies
    private var queryGeneration: UInt64 = 0
    private var startupTask: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?
    private var scanTasks: [LibraryID: Task<Void, Never>] = [:]

    public init(dependencies: LibraryBrowserDependencies) {
        self.dependencies = dependencies
    }

    deinit {
        startupTask?.cancel()
        pageTask?.cancel()
        searchDebounceTask?.cancel()
        for task in scanTasks.values { task.cancel() }
    }

    /// The query the current `selection`/`searchText`/`sort` describe --
    /// always read live, never cached, so it reflects exactly what a page
    /// fetch started right now would ask for.
    public var currentQuery: LibraryQuery {
        LibraryQuery(scope: selection.scope, filenameSearch: searchText.isEmpty ? nil : searchText, sort: sort)
    }

    // MARK: - Startup

    /// Restores every known source, then loads the first page of the
    /// default selection (`.smart(.all)`, unless `select(_:)`/`setSort(_:)`
    /// already ran first — see the ordering note on
    /// `PhotoDocumentEditor.performStartupSequence`'s own baseline-generation
    /// guard for the same reasoning, mirrored here via `queryGeneration`).
    /// Safe to call once per session lifetime; a second call is a no-op.
    public func start() {
        guard startupTask == nil else { return }
        startupTask = Task { [weak self] in
            await self?.restoreSourcesAndLoadFirstPage()
        }
    }

    private func restoreSourcesAndLoadFirstPage() async {
        let generation = queryGeneration
        do {
            let restored = try await dependencies.restoreSources()
            guard generation == queryGeneration else { return }
            sources = restored
        } catch {
            guard generation == queryGeneration else { return }
            loadState = .failed(SafeErrorPresentation.alert(title: L10n.t("Couldn't load your library"), for: error))
            return
        }
        loadState = .loadingFirstPage
        await loadFirstPage(generation: generation)
    }

    // MARK: - Selection / query changes

    public func select(_ selection: LibrarySelection) {
        guard self.selection != selection else { return }
        self.selection = selection
        beginNewQuery()
    }

    public func setSort(_ sort: PhotoSort) {
        guard self.sort != sort else { return }
        self.sort = sort
        beginNewQuery()
    }

    /// `searchText` itself updates immediately, so a bound text field stays
    /// responsive; the actual re-query is debounced by
    /// `searchDebounceDelay` so a burst of keystrokes fetches once, not
    /// once per character. Only the last call in a burst ever reaches the
    /// index -- every earlier one's debounce task is cancelled outright.
    public func updateSearchText(_ text: String) {
        guard searchText != text else { return }
        searchText = text
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounceDelay)
            guard !Task.isCancelled else { return }
            self?.beginNewQuery()
        }
    }

    private func beginNewQuery() {
        queryGeneration += 1
        let generation = queryGeneration
        photos = []
        nextCursor = nil
        loadState = .loadingFirstPage
        pageTask?.cancel()
        pageTask = Task { [weak self] in
            await self?.loadFirstPage(generation: generation)
        }
    }

    private func loadFirstPage(generation: UInt64) async {
        do {
            let page = try await dependencies.fetchPage(currentQuery, nil, Self.pageSize)
            guard generation == queryGeneration else { return }
            photos = Self.trimmedWindow(appending: page.photos, to: [])
            nextCursor = page.nextCursor
            loadState = .loaded
        } catch {
            guard generation == queryGeneration else { return }
            loadState = .failed(SafeErrorPresentation.alert(title: L10n.t("Couldn't load photos"), for: error))
        }
    }

    // MARK: - Paging

    /// No-op if a page is already loading (first or next) or there is no
    /// `nextCursor` to fetch -- the two things that make a duplicate,
    /// concurrent, or past-the-end request impossible: this check runs
    /// synchronously before anything is awaited, so two calls in the same
    /// synchronous burst can never both start a fetch.
    public func loadNextPage() {
        guard nextCursor != nil else { return }
        guard loadState != .loadingNextPage, loadState != .loadingFirstPage else { return }
        let generation = queryGeneration
        loadState = .loadingNextPage
        pageTask?.cancel()
        pageTask = Task { [weak self] in
            await self?.fetchNextPage(generation: generation)
        }
    }

    private func fetchNextPage(generation: UInt64) async {
        guard let cursor = nextCursor else { return }
        do {
            let page = try await dependencies.fetchPage(currentQuery, cursor, Self.pageSize)
            guard generation == queryGeneration else { return }
            photos = Self.trimmedWindow(appending: page.photos, to: photos)
            nextCursor = page.nextCursor
            loadState = .loaded
        } catch {
            guard generation == queryGeneration else { return }
            loadState = .failed(SafeErrorPresentation.alert(title: L10n.t("Couldn't load photos"), for: error))
        }
    }

    /// Appends `newPhotos`, then drops rows from the front until at most
    /// `pageWindowCount` pages' worth remain -- the "current window plus two
    /// prefetched pages" bound. A single page is always far under the cap,
    /// so this only ever actually trims once several `loadNextPage()` calls
    /// have accumulated past it.
    private static func trimmedWindow(appending newPhotos: [PhotoAsset], to existing: [PhotoAsset]) -> [PhotoAsset] {
        var combined = existing
        combined.append(contentsOf: newPhotos)
        let maximumCount = pageSize * pageWindowCount
        if combined.count > maximumCount {
            combined.removeFirst(combined.count - maximumCount)
        }
        return combined
    }

    // MARK: - Opening a photo

    /// Resolves `photo` into Task 4's `LibraryOpenAsset` for the caller to
    /// hand to `PhotoDocumentEditor.openLibraryAsset(_:)` -- this session
    /// never references `PhotoDocumentEditor` itself, keeping the browser
    /// and the editor composed by their caller (Task 6) rather than coupled
    /// to each other directly.
    ///
    /// Gated on the photo's source connection state, read from `sources`
    /// (never re-derived from `photo` itself): `.offline`/
    /// `.needsAuthorization` never even calls `resolveOpenAsset` -- there is
    /// nothing reachable to resolve -- and instead sets `alert` to a safe,
    /// actionable message. `.readOnly` is allowed through unchanged: Task 4's
    /// `LibraryOpenAsset` has no read-only case to carry that intent
    /// through, and this session does not invent one on its own -- see the
    /// Task 5 report's bounded-concern note on this.
    ///
    /// A photo whose `libraryID` isn't present in `sources` at all (the
    /// synthetic `.appStorage` library, which `restoreSources` -- a
    /// bookmark-backed lifecycle -- never returns) is never gated: an App
    /// copy is always locally reachable by construction.
    ///
    /// On success, also records `restorationAnchor` -- the current query
    /// plus `photo.id` -- so `restoreGridPosition()` can scroll back to it
    /// after the editor closes.
    @discardableResult
    public func openAsset(for photo: PhotoAsset) async -> LibraryOpenAsset? {
        if let folder = sources.first(where: { $0.id == photo.libraryID }) {
            switch folder.connectionState {
            case .offline, .needsAuthorization:
                alert = EditorAlert(
                    title: L10n.t("Can't open this photo"),
                    message: L10n.t("This source isn't currently reachable."),
                    nextStep: L10n.t("Reconnect the source, then try again.")
                )
                return nil
            case .ready, .readOnly:
                break
            }
        }

        do {
            let asset = try await dependencies.resolveOpenAsset(photo.id)
            restorationAnchor = GridRestorationState(query: currentQuery, anchorPhotoID: photo.id)
            return asset
        } catch {
            alert = SafeErrorPresentation.alert(title: L10n.t("Couldn't open this photo"), for: error)
            return nil
        }
    }

    // MARK: - Restoring the grid position after the editor closes

    /// Re-runs `restorationAnchor`'s saved query, page by page (capped at
    /// `maximumRestorationPages`), until the page containing its
    /// `anchorPhotoID` is found -- `selection`/`sort`/`searchText` are
    /// restored from the saved query first, so the grid reflects it
    /// immediately even before the anchor page arrives. If the anchor is
    /// never found (deleted, moved out of scope, or simply more than 20
    /// pages deep), this is not treated as an error -- it falls back to a
    /// fresh page one of that same restored query. A `nil`
    /// `restorationAnchor` (nothing was ever opened this session) is a
    /// no-op.
    public func restoreGridPosition() {
        guard let anchor = restorationAnchor else { return }
        selection = LibrarySelection.matching(anchor.query.scope)
        sort = anchor.query.sort
        searchText = anchor.query.filenameSearch ?? ""

        queryGeneration += 1
        let generation = queryGeneration
        photos = []
        nextCursor = nil
        loadState = .loadingFirstPage
        pageTask?.cancel()
        let query = anchor.query
        let targetID = anchor.anchorPhotoID
        pageTask = Task { [weak self] in
            await self?.restore(generation: generation, query: query, anchor: targetID)
        }
    }

    private func restore(generation: UInt64, query: LibraryQuery, anchor targetID: PhotoID?) async {
        var cursor: PhotoPageCursor?
        var accumulated: [PhotoAsset] = []

        for _ in 0..<Self.maximumRestorationPages {
            let page: PhotoPage
            do {
                page = try await dependencies.fetchPage(query, cursor, Self.pageSize)
            } catch {
                guard generation == queryGeneration else { return }
                loadState = .failed(SafeErrorPresentation.alert(title: L10n.t("Couldn't load photos"), for: error))
                return
            }
            guard generation == queryGeneration else { return }

            accumulated = Self.trimmedWindow(appending: page.photos, to: accumulated)
            if let targetID, page.photos.contains(where: { $0.id == targetID }) {
                photos = accumulated
                nextCursor = page.nextCursor
                loadState = .loaded
                return
            }
            cursor = page.nextCursor
            guard cursor != nil else { break }
        }

        // Not found within the page budget (or the query ran out of pages
        // first): fall back to a fresh page one of the same restored query,
        // never surfaced as an error.
        guard generation == queryGeneration else { return }
        photos = []
        nextCursor = nil
        await loadFirstPage(generation: generation)
    }

    // MARK: - Source lifecycle

    public func addSource(at url: URL, sourceKind: LibrarySourceKind) async {
        do {
            let folder = try await dependencies.addSource(url, sourceKind)
            sources.append(folder)
            sources.sort { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        } catch {
            alert = SafeErrorPresentation.alert(title: L10n.t("Couldn't add this source"), for: error)
        }
    }

    public func relinkSource(_ libraryID: LibraryID, to url: URL) async {
        do {
            let folder = try await dependencies.relinkSource(libraryID, url)
            if let index = sources.firstIndex(where: { $0.id == libraryID }) {
                sources[index] = folder
            }
        } catch {
            alert = SafeErrorPresentation.alert(title: L10n.t("Couldn't reconnect this source"), for: error)
        }
    }

    public func removeSource(_ libraryID: LibraryID) async {
        do {
            try await dependencies.removeSource(libraryID)
        } catch {
            alert = SafeErrorPresentation.alert(title: L10n.t("Couldn't remove this source"), for: error)
            return
        }
        sources.removeAll { $0.id == libraryID }
        sourceProgress.removeValue(forKey: libraryID)
        scanTasks.removeValue(forKey: libraryID)?.cancel()
        if isSelectionWithin(libraryID) {
            select(.smart(.all))
        }
    }

    private func isSelectionWithin(_ libraryID: LibraryID) -> Bool {
        switch selection {
        case .source(let id): return id == libraryID
        case .folder(let id, _): return id == libraryID
        case .smart: return false
        }
    }

    // MARK: - Folder tree

    public func childDirectories(libraryID: LibraryID, parent: String) async -> [LibraryDirectoryNode] {
        (try? await dependencies.childDirectories(libraryID, parent)) ?? []
    }

    // MARK: - Per-source scan progress

    /// Runs a bounded scan for `libraryID` (Task 3), folding its events
    /// into `sourceProgress[libraryID]`. A no-op if this source is already
    /// being scanned by this session. Not part of `select(_:)` -- selecting
    /// a source does not implicitly start scanning it; a caller (a sidebar
    /// "rescan" action, or an app-launch sweep) decides when to call this.
    public func scanSource(_ libraryID: LibraryID) {
        guard scanTasks[libraryID] == nil else { return }
        sourceProgress[libraryID] = LibrarySourceScanProgress(phase: .scanning)
        scanTasks[libraryID] = Task { [weak self] in
            guard let self else { return }
            await self.dependencies.runScan(libraryID) { [weak self] event in
                await self?.handle(event, for: libraryID)
            }
            self.scanTasks.removeValue(forKey: libraryID)
        }
    }

    private func handle(_ event: LibraryScanEvent, for libraryID: LibraryID) {
        var progress = sourceProgress[libraryID] ?? LibrarySourceScanProgress(phase: .scanning)
        switch event {
        case .started:
            progress.phase = .scanning
        case .photosIndexed(let batch):
            progress.indexedCount += batch.count
        case .photoFailed:
            progress.failedCount += 1
        case .finished:
            progress.phase = .finished
        case .failed(let error):
            progress.phase = .failed(SafeErrorPresentation.alert(title: L10n.t("This source couldn't finish scanning."), for: error))
        }
        sourceProgress[libraryID] = progress
    }
}
