import Combine
import Foundation
import Localization
import PhotoLibraryCore
import RawProcessingCore

/// Which of the two source modes the user picked for a freshly selected
/// file. Mirrors `PhotoDocumentStorageMode`, but stays a separate type
/// because it describes a one-time user choice about *how to open*, not a
/// document's persisted storage mode.
public enum PhotoDocumentOpenMode: Equatable, Sendable {
    case inPlace
    case appCopy
}

/// A held security scope, abstracted so tests can stand in a fake for the
/// real `ScopedFolderAccess` without touching the file system or the
/// sandbox. `ScopedFolderAccess` already satisfies this shape exactly.
public protocol SecurityScopedResource: AnyObject {
    var url: URL { get }
    var isAccessing: Bool { get }
    func stop()
}

extension ScopedFolderAccess: SecurityScopedResource {}

/// The outcome of resolving a saved bookmark back into an accessible scope.
public struct ResolvedSecurityScope {
    public let resource: any SecurityScopedResource
    public let isStale: Bool

    public init(resource: any SecurityScopedResource, isStale: Bool) {
        self.resource = resource
        self.isStale = isStale
    }
}

/// Everything `PhotoDocumentEditor` needs from the outside world, seamed so
/// every I/O-adjacent piece — the store, the decoder, security scopes,
/// bookmarks, and where the active document ID is remembered — can be
/// replaced with a test double. `.live(applicationSupportURL:)` below is
/// the real, production dependency graph every app target uses.
public struct PhotoDocumentEditorDependencies {
    public let store: PhotoDocumentStore
    public let decoder: any RawDecoding
    public let previewScheduler: PreviewScheduler
    public let previewRenderer: any PreviewRendering
    /// Takes a scope for a URL the user just picked (e.g. from a Files
    /// importer). Mirrors `URL.startAccessingSecurityScopedResource()`'s own
    /// contract: a scope that could not be opened is reported via
    /// `isAccessing == false`, never by throwing.
    public let makeScope: (URL) -> any SecurityScopedResource
    /// Resolves a previously saved bookmark back into an accessible scope —
    /// used only to restore an `.inPlace` document after a relaunch.
    public let resolveScope: (Data) throws -> ResolvedSecurityScope
    public let makeBookmark: (URL) throws -> Data
    public let loadActiveDocumentID: () -> UUID?
    public let saveActiveDocumentID: (UUID?) -> Void

    public init(
        store: PhotoDocumentStore,
        decoder: any RawDecoding,
        previewScheduler: PreviewScheduler,
        previewRenderer: any PreviewRendering,
        makeScope: @escaping (URL) -> any SecurityScopedResource,
        resolveScope: @escaping (Data) throws -> ResolvedSecurityScope,
        makeBookmark: @escaping (URL) throws -> Data,
        loadActiveDocumentID: @escaping () -> UUID?,
        saveActiveDocumentID: @escaping (UUID?) -> Void
    ) {
        self.store = store
        self.decoder = decoder
        self.previewScheduler = previewScheduler
        self.previewRenderer = previewRenderer
        self.makeScope = makeScope
        self.resolveScope = resolveScope
        self.makeBookmark = makeBookmark
        self.loadActiveDocumentID = loadActiveDocumentID
        self.saveActiveDocumentID = saveActiveDocumentID
    }
}

extension PhotoDocumentEditorDependencies {
    /// The real dependency graph: a `PhotoDocumentStore` rooted under
    /// `applicationSupportURL`, the production Core Image decode/preview
    /// pipeline, real security-scoped bookmarks (`ScopedFolderAccess`/
    /// `SecurityScopedBookmark`), and `UserDefaults` for remembering the
    /// active document across a relaunch.
    public static func live(
        applicationSupportURL: URL,
        userDefaults: UserDefaults = .standard
    ) -> PhotoDocumentEditorDependencies {
        let storeRootURL = applicationSupportURL.appendingPathComponent("PhotoDocuments", isDirectory: true)
        let decoder = CoreImageRawDecoder()
        let pipeline = AdjustmentPipeline()
        let renderService = ImageRenderService()
        let renderer = CoreImagePreviewRenderer(decoder: decoder, pipeline: pipeline, renderService: renderService)
        let activeDocumentDefaultsKey = "PhotoDocumentEditor.activeDocumentID"

        return PhotoDocumentEditorDependencies(
            store: PhotoDocumentStore(rootURL: storeRootURL),
            decoder: decoder,
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            makeScope: { url in ScopedFolderAccess(url: url, startAccessing: true) },
            resolveScope: { data in
                let access = try ScopedFolderAccess(resolving: data)
                return ResolvedSecurityScope(resource: access, isStale: access.isStale)
            },
            makeBookmark: { url in try SecurityScopedBookmark.makeBookmarkData(for: url) },
            loadActiveDocumentID: {
                guard let string = userDefaults.string(forKey: activeDocumentDefaultsKey) else { return nil }
                return UUID(uuidString: string)
            },
            saveActiveDocumentID: { id in
                if let id {
                    userDefaults.set(id.uuidString, forKey: activeDocumentDefaultsKey)
                } else {
                    userDefaults.removeObject(forKey: activeDocumentDefaultsKey)
                }
            }
        )
    }
}

/// Owns the single `EditorSession` for a single-photo document workflow
/// (the iPad vertical slice today; platform-neutral by construction): wires
/// it to a real `PhotoDocumentStore`-backed persistence pipeline, turns a
/// URL the user picked in Files into an open, editable document, and
/// restores the most recently open document after a relaunch.
///
/// There is exactly one `EditorSession` for the lifetime of this object
/// (`editor`, set once at `init`) — callers must read it from here rather
/// than constructing their own.
///
/// **Serialization.** Every state-changing operation (a fresh open, a
/// restore, a close) claims a new `generation` before doing any `await`.
/// Only the operation whose generation is still current when its async work
/// finishes is allowed to touch `document`/`documentScope`/
/// `isPreparingDocument`/`editor` — an operation that finishes after being
/// superseded discards whatever it produced (stopping any scope it opened,
/// and rolling back any document it newly created) instead of clobbering
/// whatever the newer operation already committed. This is what makes
/// overlapping opens, and a close racing an open, resolve to exactly one
/// consistent outcome instead of a data race.
@MainActor
public final class PhotoDocumentEditor: ObservableObject {
    public let editor = EditorSession()

    /// The currently open document, or `nil` before anything has been
    /// opened / after it has been closed. Never set until the editor is
    /// actually ready to show it.
    @Published public private(set) var document: PhotoDocument?

    /// True while a selection or restore is being prepared — a copy or
    /// fingerprint in flight, a bookmark being resolved, metadata being
    /// read — before `editor.open` is called. Distinct from
    /// `editor.isRendering`, which only covers preview decoding of an
    /// already-open document.
    @Published public private(set) var isPreparingDocument = false

    /// A file has been picked and is waiting for the user to choose
    /// in-place vs. copy. The security scope backing the pick lives in
    /// `pendingSelection`, not here.
    @Published public private(set) var hasPendingSelection = false

    /// Open/restore/copy failures, and anything the launch-time
    /// reconciliation pass couldn't clean up. Kept separate from
    /// `editor.alert`, which is `EditorSession`'s own — a failure to *open*
    /// a document happens before there is an editor session to report it,
    /// and a failure *within* an open document (a render or save failure)
    /// is `EditorSession`'s to own.
    @Published public var alert: EditorAlert?

    private let dependencies: PhotoDocumentEditorDependencies
    private var pendingSelection: (url: URL, scope: any SecurityScopedResource)?
    private var documentScope: (any SecurityScopedResource)?
    private var startupTask: Task<Void, Never>?
    private var openingTask: Task<Void, Never>?
    /// The in-flight flush shared by whichever operations are currently
    /// racing to close the same current document. See
    /// `flushAndCloseCurrentDocument(checkingGeneration:)`.
    private var activeFlushTask: Task<Bool, Never>?
    /// Bumped by every operation that may commit `document`/`documentScope`
    /// — a fresh open, a restore attempt, or a close. See the type's doc
    /// comment.
    private var generation: UInt64 = 0

    public init(dependencies: PhotoDocumentEditorDependencies) {
        self.dependencies = dependencies
        let store = dependencies.store
        editor.attach(dependencies: EditorDependencies(
            previewScheduler: dependencies.previewScheduler,
            previewRenderer: dependencies.previewRenderer,
            loadAdjustments: { photo in
                try await store.loadAdjustments(documentID: photo.id.rawValue)
            },
            saveAdjustments: { adjustments, photo in
                try await store.saveAdjustments(adjustments, documentID: photo.id.rawValue)
            }
        ))
    }

    public convenience init(applicationSupportURL: URL, userDefaults: UserDefaults = .standard) {
        self.init(dependencies: .live(applicationSupportURL: applicationSupportURL, userDefaults: userDefaults))
    }

    deinit {
        startupTask?.cancel()
        openingTask?.cancel()
        activeFlushTask?.cancel()
    }

    // MARK: - Startup: reconcile, then restore

    /// Reclaims storage left behind by an import the app was killed in the
    /// middle of, then — only once that has finished — tries to restore the
    /// most recently open document. Safe to call once per launch.
    public func performStartupSequence() {
        guard startupTask == nil else { return }
        // `Task {}` here inherits `@MainActor` from this method, exactly
        // like `EditorSession.startObservingPreviews` — the body only
        // touches `@Published` state after each `await` has already taken
        // the actual file-system work off this actor.
        startupTask = Task { [weak self] in
            await self?.reconcileOrphanedImports()
            await self?.restoreActiveDocumentIfPossible()
        }
    }

    private func reconcileOrphanedImports() async {
        do {
            let report = try await dependencies.store.reconcileOrphanedImports()
            guard !report.failures.isEmpty else { return }
            alert = EditorAlert(
                title: L10n.t("Startup cleanup incomplete"),
                message: L10n.t("LumaHarbor couldn't finish cleaning up an earlier interrupted import."),
                nextStep: nil
            )
        } catch PhotoDocumentError.importInProgress {
            // Another import or reconciliation pass already holds the
            // lock; it will reconcile on its own next launch if needed.
        } catch {
            alert = EditorAlert(
                title: L10n.t("Startup cleanup incomplete"),
                message: L10n.t("LumaHarbor couldn't check for interrupted imports on launch."),
                nextStep: nil
            )
        }
    }

    /// Restores the document remembered by `loadActiveDocumentID`, if any.
    /// Never touches `document`/`documentScope` if the user has already
    /// opened something else in the meantime (a fresh selection always
    /// wins), and never deletes anything on failure — unlike a fresh open,
    /// there is no newly created document here to roll back, only a
    /// pointer to an existing one.
    private func restoreActiveDocumentIfPossible() async {
        guard document == nil else { return }
        guard let activeID = dependencies.loadActiveDocumentID() else { return }

        openingTask?.cancel()
        let myGeneration = beginNewGeneration()
        isPreparingDocument = true

        do {
            let existingDocument = try await dependencies.store.loadDocument(id: activeID)
            let ownedScope: (any SecurityScopedResource)?

            switch existingDocument.storageMode {
            case .appCopy:
                ownedScope = nil
            case .inPlace:
                guard let bookmarkData = existingDocument.sourceBookmarkData else {
                    throw RestoreError.missingBookmark
                }
                let resolved = try dependencies.resolveScope(bookmarkData)
                guard resolved.resource.isAccessing else {
                    resolved.resource.stop()
                    throw RestoreError.accessDenied
                }
                if resolved.isStale, let refreshed = try? dependencies.makeBookmark(resolved.resource.url) {
                    // Best-effort: a failure to persist the refresh just
                    // means the *next* restore may hit the same staleness
                    // again, not that this one fails.
                    try? await dependencies.store.updateSourceBookmark(refreshed, documentID: existingDocument.id)
                }
                ownedScope = resolved.resource
            }

            let (photo, adjustments) = try await loadEditorState(for: existingDocument)
            guard commitOpenedDocument(
                generation: myGeneration,
                document: existingDocument,
                scope: ownedScope,
                photo: photo,
                adjustments: adjustments
            ) else {
                ownedScope?.stop()
                return
            }
        } catch {
            guard generation == myGeneration else { return }
            isPreparingDocument = false
            // Never retry forever against the same broken pointer, and
            // never claim success it didn't achieve.
            dependencies.saveActiveDocumentID(nil)
            alert = SafeErrorPresentation.alert(title: L10n.t("Couldn't reopen your last photo"), for: error)
        }
    }

    private enum RestoreError: Error {
        case missingBookmark
        case accessDenied
    }

    // MARK: - Selecting a file

    /// Called right after `fileImporter` hands back a URL. Takes the
    /// security scope immediately — the system only guarantees access for
    /// the duration of that completion handler, so acquiring it here is not
    /// optional, even though the user's in-place/copy choice comes later.
    public func beginSelecting(_ url: URL) {
        cancelPendingSelection()
        let scope = dependencies.makeScope(url)
        guard scope.isAccessing else {
            scope.stop()
            alert = EditorAlert(
                title: L10n.t("Couldn't open this photo"),
                message: L10n.t("LumaHarbor couldn't get permission to read this file."),
                nextStep: L10n.t("Choose the file again from Files.")
            )
            return
        }
        pendingSelection = (url, scope)
        hasPendingSelection = true
    }

    /// The user dismissed the confirmation dialog without choosing a mode.
    public func cancelPendingSelection() {
        pendingSelection?.scope.stop()
        pendingSelection = nil
        hasPendingSelection = false
    }

    /// A `fileImporter` call failed for a reason other than the user
    /// cancelling. Never forwards the underlying error's own text — a
    /// provider failure can carry a path in its description just like the
    /// errors `SafeErrorPresentation` already guards against.
    public func reportFileImporterFailure(_ error: Error) {
        alert = EditorAlert(
            title: L10n.t("Couldn't open this photo"),
            message: L10n.t("Couldn't read the file."),
            nextStep: L10n.t("Choose the file again from Files.")
        )
    }

    /// The user tapped a mode button for the pending selection.
    ///
    /// Claims and clears `pendingSelection` synchronously, before this
    /// method returns — a confirmation dialog's own dismissal bookkeeping
    /// runs right after the button's action closure returns and calls back
    /// into `cancelPendingSelection()`. Doing the claim here, synchronously,
    /// means there is nothing left for that callback to race.
    public func beginOpeningPendingSelection(mode: PhotoDocumentOpenMode) {
        guard let selection = pendingSelection else { return }
        pendingSelection = nil
        hasPendingSelection = false
        openFreshSelection(url: selection.url, scope: selection.scope, mode: mode)
    }

    // MARK: - Opening a fresh selection

    private func openFreshSelection(url: URL, scope: any SecurityScopedResource, mode: PhotoDocumentOpenMode) {
        openingTask?.cancel()
        isPreparingDocument = true

        openingTask = Task { [weak self, dependencies] in
            guard let self else { return }
            // Whatever is currently open must be flushed and closed first,
            // under the *same* generation this operation will use for its
            // own commit -- so, from `editor`'s point of view, the old
            // document's close and the new one's open are one continuous
            // hand-off with nothing else able to touch `editor` in between,
            // never a moment where a still-resolving flush and a fresh
            // `editor.open` could interleave.
            let myGeneration = self.beginNewGeneration()
            guard await self.flushAndCloseCurrentDocument(checkingGeneration: myGeneration) else {
                // A real flush failure (not a supersede) -- `EditorSession`
                // has already surfaced why through its own `alert`. Not
                // this operation's place to retry; just stop the scope it
                // otherwise would have used.
                scope.stop()
                if self.generation == myGeneration { self.isPreparingDocument = false }
                return
            }
            guard self.generation == myGeneration else {
                // Superseded while closing the previous document -- some
                // other operation now owns `document`/`documentScope`.
                scope.stop()
                return
            }

            var createdDocument: PhotoDocument?
            do {
                let bookmarkData: Data?
                switch mode {
                case .inPlace:
                    // Restorability after a relaunch depends entirely on
                    // this bookmark; a document that silently opened
                    // without one could never be found again, so a failure
                    // here fails the whole open instead of quietly
                    // proceeding as though nothing were lost.
                    bookmarkData = try dependencies.makeBookmark(url)
                case .appCopy:
                    // Best-effort only: an app-copy document's restore
                    // never needs the source scope again, so losing this
                    // bookmark only affects a future relink/reveal-source
                    // affordance, never restorability.
                    bookmarkData = try? dependencies.makeBookmark(url)
                }

                let newDocument: PhotoDocument
                let ownedScope: (any SecurityScopedResource)?
                switch mode {
                case .inPlace:
                    newDocument = try await dependencies.store.openInPlace(url, bookmarkData: bookmarkData)
                    ownedScope = scope
                case .appCopy:
                    newDocument = try await dependencies.store.importCopy(of: url, bookmarkData: bookmarkData)
                    // The verified copy is committed to App storage; the
                    // external source is no longer read from, so its scope
                    // is released right away.
                    scope.stop()
                    ownedScope = nil
                }
                createdDocument = newDocument

                let (photo, adjustments) = try await self.loadEditorState(for: newDocument)

                guard self.commitOpenedDocument(
                    generation: myGeneration, document: newDocument, scope: ownedScope,
                    photo: photo, adjustments: adjustments
                ) else {
                    // Superseded before this could land -- nothing here has
                    // been shown to the user, so undo it exactly as if the
                    // open had failed.
                    ownedScope?.stop()
                    _ = await dependencies.store.rollbackDocument(newDocument)
                    return
                }
            } catch is CancellationError {
                // A newer selection or a close pre-empted this one. For an
                // in-flight `importCopy`, the store's own cancellation
                // cleanup has already removed the partial copy; this only
                // needs to release the scope and roll back a document that
                // *fully* committed before the cancellation was observed.
                scope.stop()
                if let createdDocument {
                    _ = await dependencies.store.rollbackDocument(createdDocument)
                }
            } catch {
                scope.stop()
                if let createdDocument {
                    _ = await dependencies.store.rollbackDocument(createdDocument)
                }
                guard self.generation == myGeneration else { return }
                self.isPreparingDocument = false
                self.alert = SafeErrorPresentation.alert(title: L10n.t("Couldn't open this photo"), for: error)
            }
        }
    }

    // MARK: - Shared open machinery

    private func loadEditorState(for document: PhotoDocument) async throws -> (photo: PhotoAsset, adjustments: PhotoAdjustments) {
        let decoder = dependencies.decoder
        let workingURL = document.workingURL
        // RAW metadata decoding is synchronous, non-actor-isolated work —
        // `runOffActor` (the same seam `CoreImagePreviewRenderer` uses) is
        // what keeps it off the main actor.
        let metadata = try await runOffActor(priority: .userInitiated) {
            try decoder.readMetadata(at: workingURL)
        }
        let adjustments = try await dependencies.store.loadAdjustments(documentID: document.id)
        let photo = PhotoAsset(
            id: PhotoID(document.id),
            libraryID: LibraryID(),
            relativePath: document.workingURL.lastPathComponent,
            fingerprint: document.workingFingerprint,
            metadata: metadata,
            status: .ready
        )
        return (photo, adjustments)
    }

    /// Commits a freshly produced document if — and only if — `generation`
    /// is still current. Returns whether the commit happened; a caller that
    /// gets back `false` must undo anything it produced instead of touching
    /// shared state.
    private func commitOpenedDocument(
        generation: UInt64,
        document: PhotoDocument,
        scope: (any SecurityScopedResource)?,
        photo: PhotoAsset,
        adjustments: PhotoAdjustments
    ) -> Bool {
        guard self.generation == generation else { return false }
        documentScope = scope
        self.document = document
        // `sourceURL` is always the working copy — the file LumaHarbor
        // actually decodes and previews from — never the external RAW in
        // app-copy mode.
        editor.open(photo: photo, sourceURL: document.workingURL, adjustments: adjustments, isReadOnly: false)
        dependencies.saveActiveDocumentID(document.id)
        isPreparingDocument = false
        return true
    }

    private func beginNewGeneration() -> UInt64 {
        generation += 1
        return generation
    }

    // MARK: - Closing

    /// Flushes pending edits and tears the editor down. Returns `false` —
    /// leaving the document, editor and scope untouched — when something
    /// unsaved could not be written; `EditorSession.flushPendingEdits()` has
    /// already surfaced that failure through `editor.alert`. Callers must
    /// not proceed with switching or closing when this returns `false`.
    ///
    /// Claims its own generation before the flush's `await`, exactly like
    /// an open — if a new open lands while this is still flushing, this
    /// call finds itself superseded afterward and leaves the *new*
    /// document and scope alone rather than closing them.
    @discardableResult
    public func closeCurrentDocument() async -> Bool {
        guard document != nil else { return true }
        openingTask?.cancel()
        isPreparingDocument = true
        let myGeneration = beginNewGeneration()

        let result = await flushAndCloseCurrentDocument(checkingGeneration: myGeneration)
        if generation == myGeneration {
            isPreparingDocument = false
        }
        return result
    }

    /// Flushes and closes whatever document is currently open, if any,
    /// honoring `myGeneration`: if a newer operation has taken over by the
    /// time the flush finishes, `document`/`documentScope`/`editor` are
    /// left alone — they belong to that newer operation now — and only
    /// whether the flush itself succeeded is reported.
    ///
    /// Safe to call from two places "at once" — a direct user close, and a
    /// fresh open's own "replace whatever was already open" step, both do.
    /// Concurrent callers share the *same* underlying flush via
    /// `activeFlushTask` rather than each calling `EditorSession
    /// .flushPendingEdits()` independently: two concurrent flushes of the
    /// same session is not something `EditorSession` is built to tolerate,
    /// and without sharing, a fresh open's `editor.open()` could otherwise
    /// land in the middle of a still-resolving close's flush and corrupt
    /// what it was flushing.
    private func flushAndCloseCurrentDocument(checkingGeneration myGeneration: UInt64) async -> Bool {
        guard document != nil else { return true }

        let flushTask: Task<Bool, Never>
        if let existing = activeFlushTask {
            flushTask = existing
        } else {
            let task = Task { [editor] in await editor.flushPendingEdits() }
            activeFlushTask = task
            flushTask = task
        }
        let flushed = await flushTask.value
        activeFlushTask = nil

        guard generation == myGeneration else {
            // Superseded while the flush was in flight -- whatever is
            // current now owns `document`/`documentScope`/`editor`.
            return flushed
        }
        guard flushed else { return false }
        editor.close()
        document = nil
        documentScope?.stop()
        documentScope = nil
        dependencies.saveActiveDocumentID(nil)
        return true
    }
}
