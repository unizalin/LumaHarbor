import EditorCore
import Foundation
import PhotoLibraryCore
import RawProcessingCore

/// Everything the iPad app needs, wired exactly once at launch (Task 6) —
/// the iPad counterpart to the Mac app's own `AppServices`.
///
/// Owns exactly one `PhotoLibraryService` and one `PhotoDocumentStore`, and
/// builds both `PadLibraryModel` (the multi-source browser, Task 5) and
/// `PadEditorModel` (the single-document editor, Task 4) from that same
/// pair — never two independent copies of either. This is what lets a
/// committed App copy, created through the single-photo `Open RAW…` flow,
/// actually show up through the library browser: both sides read and write
/// the same underlying index and document store.
///
/// Constructed once, synchronously, in `LumaHarborPadApp.init` — never from
/// a SwiftUI `body`, which would silently rebuild the whole service graph
/// (a second SQLite connection, a second `PhotoDocumentStore` root lock
/// contender) on every view re-evaluation.
@MainActor
final class PadAppServices {
    let locations: ApplicationSupportLocations
    let libraryService: PhotoLibraryService
    let documentStore: PhotoDocumentStore
    let thumbnailProvider: ThumbnailProvider
    let library: PadLibraryModel
    let editor: PadEditorModel
    /// Injected so `PadLibrarySettingsView` (Task 7 Step 5) can be handed
    /// the exact same store this instance used to resolve its initial
    /// cache budget, rather than each independently defaulting to
    /// `.standard` and risking the two silently diverging for a caller
    /// that injects a custom store.
    let userDefaults: UserDefaults

    /// iPad default cache budget (global constraint: 2 GiB default, 512 MiB
    /// through 10 GiB configurable range for Task 7's settings screen) —
    /// deliberately its own constant, never reusing the Mac's own
    /// `CacheBudget` values (global constraint: "Existing Mac defaults do
    /// not change").
    static let defaultThumbnailCacheByteBudget: Int64 = 2 * 1_024 * 1_024 * 1_024

    init(applicationSupportURL: URL, userDefaults: UserDefaults = .standard) throws {
        let locations = ApplicationSupportLocations(
            baseURL: applicationSupportURL.appendingPathComponent("LumaHarbor", isDirectory: true)
        )
        try locations.createDirectories()

        let decoder = CoreImageRawDecoder()
        let renderService = ImageRenderService()
        let pipeline = AdjustmentPipeline()
        let previewRenderer = CoreImagePreviewRenderer(
            decoder: decoder, pipeline: pipeline, renderService: renderService
        )

        let libraryService = try PhotoLibraryService(locations: locations, decoder: decoder)

        // Honors a cache-budget preference persisted by an earlier launch
        // (Task 7's `PadLibrarySettingsView`) rather than always
        // re-constructing the disk cache at the hardcoded 2 GiB default —
        // `PadThumbnailCacheBudget.resolvingPersisted` already clamps an
        // absent or invalid value back to that same default.
        let thumbnailCache = try DiskCache(
            directoryURL: locations.thumbnailCacheURL,
            byteBudget: PadThumbnailCacheBudget.resolvingPersisted(userDefaults).rawValue
        )

        // Deliberately not `PhotoDocumentEditorDependencies.live(applicationSupportURL:)`
        // -- that convenience mints its *own* private `PhotoDocumentStore`,
        // which would leave the library side (below) with no way to reach
        // committed App-copy records for `refreshAppStorageProjection()`.
        // Everything else here mirrors `.live` exactly; only `store` is
        // injected instead of freshly constructed.
        let documentStore = PhotoDocumentStore(
            rootURL: applicationSupportURL.appendingPathComponent("PhotoDocuments", isDirectory: true)
        )
        let editorDependencies = PhotoDocumentEditorDependencies(
            store: documentStore,
            decoder: decoder,
            previewScheduler: PreviewScheduler(renderer: previewRenderer),
            previewRenderer: previewRenderer,
            makeScope: { url in ScopedFolderAccess(url: url, startAccessing: true) },
            resolveScope: { data in
                let access = try ScopedFolderAccess(resolving: data)
                return ResolvedSecurityScope(resource: access, isStale: access.isStale)
            },
            makeBookmark: { url in try SecurityScopedBookmark.makeBookmarkData(for: url) }
        )

        self.locations = locations
        self.libraryService = libraryService
        self.documentStore = documentStore
        self.thumbnailProvider = ThumbnailProvider(
            cache: thumbnailCache, decoder: decoder, renderService: renderService
        )
        self.library = PadLibraryModel(dependencies: .live(service: libraryService))
        self.editor = PadEditorModel(dependencies: editorDependencies)
        self.userDefaults = userDefaults
    }

    /// Resolves the file URL a thumbnail should be decoded from for `photo`
    /// -- the read-only counterpart, for grid thumbnails, to
    /// `LibraryBrowserDependencies.live(service:)`'s own `resolveOpenAsset`
    /// split between an indexed external photo and a projected App copy.
    ///
    /// Deliberately does **not** use `PhotoLibraryService.sourceURL(for:)`
    /// for an `.appStorage` photo -- that method documents itself as unsafe
    /// to rely on for a projected App copy (its `rootURL` is a synthetic
    /// placeholder, not a real, decodable location; see
    /// `PhotoLibraryService.refreshAppStorageProjection(from:)`'s own doc
    /// comment). An App-copy `PhotoID` is always that document's UUID (same
    /// invariant `resolveOpenAsset`'s `.appCopy(documentID:)` branch
    /// relies on), so this resolves it through `documentStore.loadDocument`
    /// instead, to the document's own local `workingURL` -- always
    /// reachable, since it lives in this app's own storage.
    func thumbnailSourceURL(for photo: PhotoAsset) async -> URL? {
        if photo.libraryID == .appStorage {
            return try? await documentStore.loadDocument(id: photo.id.rawValue).workingURL
        }
        guard let folder = library.folder(for: photo.libraryID) else { return nil }
        return photo.url(inLibraryRootedAt: folder.rootURL)
    }

    /// Projects every currently-committed App copy (Task 4's
    /// `PhotoDocumentStore.committedDocuments()`) into the synthetic
    /// `.appStorage` library (Task 4's `PhotoLibraryService
    /// .refreshAppStorageProjection(from:)`) so it is actually browsable
    /// through `library` (Task 5) — the "no production caller yet" gap both
    /// tasks' own reports flagged as deferred to this one.
    ///
    /// Idempotent and cheap (Task 4's own documentation on
    /// `refreshAppStorageProjection`): safe to call repeatedly. Called once
    /// at launch alongside `library.start()`, and again whenever the
    /// editor's open document changes — see `PadRootView` — so a photo
    /// copied to this iPad during the current session shows up in the
    /// library without requiring a relaunch. Best-effort: a failure here
    /// never blocks browsing already-indexed external sources, and the
    /// projection simply stays whatever it last successfully was until the
    /// next call succeeds.
    func refreshAppStorageProjection() async {
        do {
            let listing = try await documentStore.committedDocuments()
            try await libraryService.refreshAppStorageProjection(from: listing.documents)
        } catch {
            // Best-effort by design -- see the doc comment above.
        }
    }
}
