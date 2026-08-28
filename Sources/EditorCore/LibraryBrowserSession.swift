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

    /// `sources` is deliberately published unconditionally, never gated on
    /// `queryGeneration`: it describes what sources exist, not the result of
    /// any particular query, so a `select(_:)`/`setSort(_:)`/
    /// `updateSearchText(_:)` call that arrives while `restoreSources()` is
    /// still in flight must never cause this restoration's sources to be
    /// silently dropped. Codex review: the previous version gated the
    /// `sources` assignment on the same generation check used for page
    /// results, which — since `start()` is a one-shot no-op after its first
    /// call — could leave `sources` permanently empty if the user acted
    /// before restoration finished, with nothing left to ever populate it.
    ///
    /// Only the *default first page* this call would otherwise load is
    /// still generation-gated: if a newer query has already begun while
    /// `restoreSources()` was in flight, that query's own task already
    /// owns `photos`/`nextCursor`/`loadState`, and this call must not
    /// clobber it with the stale default query's page one.
    private func restoreSourcesAndLoadFirstPage() async {
        let startupGeneration = queryGeneration
        do {
            let restored = try await dependencies.restoreSources()
            sources = restored
        } catch {
            if startupGeneration == queryGeneration {
                loadState = .failed(SafeErrorPresentation.alert(title: L10n.t("Couldn't load your library"), for: error))
            }
            return
        }
        guard startupGeneration == queryGeneration else { return }
        loadState = .loadingFirstPage
        await loadFirstPage(generation: startupGeneration)
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
    /// responsive, and so does invalidating whatever query is currently
    /// outstanding -- only *starting the new fetch* is debounced by
    /// `searchDebounceDelay`, so a burst of keystrokes fetches once, not
    /// once per character.
    ///
    /// Codex review: an earlier version left `queryGeneration` unchanged
    /// until the debounce timer itself fired `beginNewQuery()`. That left a
    /// window, for the full debounce delay, where a fetch already in flight
    /// for the *previous* search text still carried the current generation
    /// and could commit its (now stale) result to `photos`/`loadState`/
    /// `nextCursor` even though `searchText` had already visibly moved on.
    /// `invalidateCurrentQuery()` below closes that window immediately,
    /// synchronously, on every actual text change -- debouncing only ever
    /// delays *issuing* the new fetch, never *invalidating* the old one.
    public func updateSearchText(_ text: String) {
        guard searchText != text else { return }
        searchText = text
        invalidateCurrentQuery()
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounceDelay)
            guard !Task.isCancelled else { return }
            self?.beginNewQuery()
        }
    }

    /// Bumps `queryGeneration` and cancels `pageTask` immediately, without
    /// starting a replacement fetch -- so anything already in flight (a
    /// first-page or next-page fetch, or another still-pending debounce)
    /// can never commit its result once this call returns, no matter how
    /// much later it actually resolves. `beginNewQuery()` below is the
    /// counterpart that both invalidates *and* immediately starts the new
    /// fetch; this one only does the first half, for callers (the search
    /// debounce) that must invalidate now but delay issuing the new fetch.
    ///
    /// Codex review: bumping the generation alone is not enough while a
    /// stale `nextCursor` is still sitting there. `PhotoPageCursor` is only
    /// valid for the exact `LibraryQuery` shape (scope/search/sort) that
    /// produced it -- it is not just "the boundary between page N and
    /// N+1," it *is* page N's position within that specific query. A call
    /// to `loadNextPage()` made during the debounce window (before
    /// `beginNewQuery()` has run) reads `queryGeneration` and `nextCursor`
    /// fresh at that moment: with only the generation bumped, `nextCursor`
    /// still non-nil, and `loadState` still `.loaded`, `loadNextPage()`'s
    /// own guards would both pass, and it would start a *new* fetch --
    /// under the *already-bumped* generation -- pairing the outgoing
    /// query's cursor with the incoming query's scope/search/sort. That
    /// fetch's own generation check would then pass too (nothing bumped it
    /// again yet), so a keyset request built from two different queries
    /// could actually reach `fetchPage` and commit its result. Clearing
    /// `nextCursor` and marking `loadState` as a pending first-page load
    /// here, synchronously, is what makes `loadNextPage()` a no-op for the
    /// rest of the debounce window: its own "is there a next cursor" and
    /// "is a first page already loading" guards both cover this on their
    /// own, with no extra state introduced.
    ///
    /// `photos` is deliberately left untouched here -- the outgoing query's
    /// rows may keep showing during the debounce gap; only *paging past
    /// them* is what must never be possible until the new first page has
    /// actually loaded.
    private func invalidateCurrentQuery() {
        queryGeneration += 1
        pageTask?.cancel()
        nextCursor = nil
        loadState = .loadingFirstPage
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
    ///
    /// Once the scan actually finishes, `handle(_:for:)` below also reloads
    /// the current query -- via the ordinary `beginNewQuery()` generation
    /// bump -- if `selection` draws from `libraryID` (see
    /// `isSelectionAffected(byScanOf:)`), so a freshly added source's photos
    /// don't sit behind a stale, already-fetched empty page.
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

        // Codex pre-landing review: a scan indexes photos into SQLite, but
        // nothing about that write itself invalidates whatever query this
        // session already has loaded. Without this, a source added and
        // scanned while `.all` (or that same source/folder) is showing
        // leaves the grid stuck on the empty/partial page it fetched before
        // the scan ever wrote anything -- "no RAW files found" forever,
        // until the user manually changes scope/sort/search. Only run this
        // once the scan has actually finished (not on every incremental
        // `.photosIndexed` batch): `beginNewQuery()` fully resets `photos`
        // and re-fetches from page one, which would otherwise make the grid
        // visibly flicker/reset on every batch of a large scan.
        //
        // Codex re-review round 2: which scopes actually need this reload is
        // not just "does this scan touch that source's photos" -- see
        // `isSelectionAffected(byScanOf:)` for why `.recentlyEdited` also
        // qualifies, alongside `.all`/`.source`/`.folder`.
        if case .finished = event, isSelectionAffected(byScanOf: libraryID) {
            beginNewQuery()
        }
    }

    /// Whether `selection`'s current query draws from `libraryID` (directly,
    /// or transitively via a cross-source smart scope) and so must be
    /// reloaded once that source finishes scanning.
    ///
    /// `.all` and `.recentlyEdited` both qualify: a scan doesn't only index
    /// new photos, it also re-reads each photo's sidecar and rewrites
    /// `hasEdits`/`lastEditAt` on the indexed row from it (`PhotoLibraryService`'s
    /// own rescan path -- SQLite's edit-state columns are a rebuildable
    /// projection of the sidecar, not the source of truth), and
    /// `.recentlyEdited` is exactly the query that filters/sorts on those two
    /// columns. A source with pre-existing sidecar edits can therefore turn
    /// `.recentlyEdited` from empty to populated purely by finishing a scan,
    /// with no new photo ever appearing -- the same stale-UI failure mode
    /// `.all` has, just triggered by edit-state rebuild instead of indexing.
    ///
    /// `.appStorage` is the one cross-source smart scope that does *not*
    /// qualify: it's populated only by `refreshAppStorageProjection(from:)`
    /// projecting App-copy commits out of `PhotoDocumentStore`, a path an
    /// external source's scan never touches -- so a scan completion must
    /// never force-reload it.
    private func isSelectionAffected(byScanOf libraryID: LibraryID) -> Bool {
        switch selection {
        case .smart(.all), .smart(.recentlyEdited): return true
        case .smart: return false
        case .source(let id): return id == libraryID
        case .folder(let id, _): return id == libraryID
        }
    }
}
