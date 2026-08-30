import Foundation
import PhotoLibraryCore

/// Everything `LibraryBrowserSession` needs from the outside world, seamed
/// so every I/O-adjacent piece — source lifecycle, paged queries, scanning,
/// and resolving a photo into something the editor can open — can be
/// replaced with a test double. `.live(service:)` below is the real,
/// production dependency graph.
///
/// Every closure is `@Sendable`: `LibraryBrowserSession` is `@MainActor`,
/// but the work these closures do (SQLite queries, folder scans, bookmark
/// I/O) must not run pinned to the main actor, so each one is awaited from
/// `LibraryBrowserSession` and free to hop off it internally.
public struct LibraryBrowserDependencies: Sendable {
    /// Restores every previously-authorised source (Task 2's bookmark-backed
    /// lifecycle) — mirrors `PhotoLibraryService.restoreLibraries()`. Called
    /// once, at startup.
    public var restoreSources: @Sendable () async throws -> [LibraryFolder]
    /// Task 1's stable, keyset-paged cross-source query.
    public var fetchPage: @Sendable (LibraryQuery, PhotoPageCursor?, Int) async throws -> PhotoPage
    /// Task 1's lazy folder-tree expansion for the sidebar.
    public var childDirectories: @Sendable (LibraryID, String) async throws -> [LibraryDirectoryNode]
    public var addSource: @Sendable (URL, LibrarySourceKind) async throws -> LibraryFolder
    public var relinkSource: @Sendable (LibraryID, URL) async throws -> LibraryFolder
    /// Task 3's bounded, coordinated scan for one source. The handler is
    /// invoked once per `LibraryScanEvent`, awaited before the next one is
    /// produced — the production implementation must preserve that
    /// backpressure (see `.live(service:)`), never buffer events of its own.
    public var runScan: @Sendable (
        LibraryID,
        @escaping @Sendable (LibraryScanEvent) async -> Void
    ) async -> Void
    public var removeSource: @Sendable (LibraryID) async throws -> Void
    /// Resolves an indexed photo into Task 4's `LibraryOpenAsset` — an
    /// already-indexed external photo becomes `.external`, a projected App
    /// copy becomes `.appCopy(documentID:)`. The caller (not this session)
    /// hands the result to `PhotoDocumentEditor.openLibraryAsset(_:)`.
    public var resolveOpenAsset: @Sendable (PhotoID) async throws -> LibraryOpenAsset

    public init(
        restoreSources: @escaping @Sendable () async throws -> [LibraryFolder],
        fetchPage: @escaping @Sendable (LibraryQuery, PhotoPageCursor?, Int) async throws -> PhotoPage,
        childDirectories: @escaping @Sendable (LibraryID, String) async throws -> [LibraryDirectoryNode],
        addSource: @escaping @Sendable (URL, LibrarySourceKind) async throws -> LibraryFolder,
        relinkSource: @escaping @Sendable (LibraryID, URL) async throws -> LibraryFolder,
        runScan: @escaping @Sendable (LibraryID, @escaping @Sendable (LibraryScanEvent) async -> Void) async -> Void,
        removeSource: @escaping @Sendable (LibraryID) async throws -> Void,
        resolveOpenAsset: @escaping @Sendable (PhotoID) async throws -> LibraryOpenAsset
    ) {
        self.restoreSources = restoreSources
        self.fetchPage = fetchPage
        self.childDirectories = childDirectories
        self.addSource = addSource
        self.relinkSource = relinkSource
        self.runScan = runScan
        self.removeSource = removeSource
        self.resolveOpenAsset = resolveOpenAsset
    }
}

/// Thrown by `.live(service:)`'s `resolveOpenAsset` when a `PhotoID` no
/// longer names anything the index (or the source it belongs to) knows
/// about — e.g. the row was pruned by a rescan, or its library was removed,
/// between the browser showing it and the user tapping it.
public enum LibraryBrowserResolutionError: Error, Equatable, Sendable {
    case photoNotFound
    case sourceUnavailable
}

extension LibraryBrowserDependencies {
    /// The real dependency graph: every closure delegates directly to
    /// `service` (Task 1-4's `PhotoLibraryCore` facade), with no seam of its
    /// own — this is a composition detail, not additional logic to test
    /// independently of `PhotoLibraryService`'s own, already-covered tests.
    public static func live(service: PhotoLibraryService) -> LibraryBrowserDependencies {
        LibraryBrowserDependencies(
            restoreSources: {
                try await service.restoreLibraries()
            },
            fetchPage: { query, cursor, limit in
                let indexStore = await service.indexStore
                return try indexStore.page(matching: query, after: cursor, limit: limit)
            },
            childDirectories: { libraryID, parent in
                let indexStore = await service.indexStore
                return try indexStore.childDirectories(libraryID: libraryID, parent: parent)
            },
            addSource: { url, sourceKind in
                try await service.addLibrary(at: url, sourceKind: sourceKind)
            },
            relinkSource: { libraryID, url in
                try await service.relink(libraryID: libraryID, to: url)
            },
            runScan: { libraryID, handler in
                // Iterates the existing acknowledged `LibraryScanSequence`
                // directly and awaits `handler` for every event before the
                // next one is produced -- the same backpressure chain a
                // single-source scan already provides, reused verbatim
                // rather than bridged through a buffering `AsyncStream`.
                for await event in service.scan(libraryID: libraryID) {
                    await handler(event)
                }
            },
            removeSource: { libraryID in
                try await service.removeLibrary(id: libraryID)
            },
            resolveOpenAsset: { photoID in
                let indexStore = await service.indexStore
                guard let photo = try indexStore.photo(id: photoID) else {
                    throw LibraryBrowserResolutionError.photoNotFound
                }
                guard let folder = await service.library(id: photo.libraryID) else {
                    throw LibraryBrowserResolutionError.photoNotFound
                }
                // A projected App copy (Task 4) always reuses its
                // `PhotoDocumentStore` document UUID as its `PhotoID` --
                // see `PhotoLibraryService.refreshAppStorageProjection(from:)`.
                if folder.sourceKind == .appStorage {
                    return .appCopy(documentID: photoID.rawValue)
                }
                guard let url = await service.sourceURL(for: photo) else {
                    throw LibraryBrowserResolutionError.sourceUnavailable
                }
                return .external(url: url, scopeURL: folder.rootURL, sourceKind: folder.sourceKind)
            }
        )
    }
}
