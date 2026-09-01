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
/// every I/O-adjacent piece — the store, the decoder, security scopes, and
/// bookmarks — can be replaced with a test double. `.live
/// (applicationSupportURL:)` below is the real, production dependency
/// graph every app target uses.
///
/// The active-document pointer is deliberately *not* a seam here: it is
/// read and written directly through `store.loadActiveDocumentID()`/
/// `store.saveActiveDocumentID(_:)`, which persist it durably under the
/// store's own `rootURL` — the same domain document records live in — so
/// every caller, test included, observes the one real, crash-durable
/// pointer rather than a separate in-memory or `UserDefaults`-backed
/// stand-in that could drift from what `reconcileOrphanedImports` actually
/// sees on the next launch.
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

    public init(
        store: PhotoDocumentStore,
        decoder: any RawDecoding,
        previewScheduler: PreviewScheduler,
        previewRenderer: any PreviewRendering,
        makeScope: @escaping (URL) -> any SecurityScopedResource,
        resolveScope: @escaping (Data) throws -> ResolvedSecurityScope,
        makeBookmark: @escaping (URL) throws -> Data
    ) {
        self.store = store
        self.decoder = decoder
        self.previewScheduler = previewScheduler
        self.previewRenderer = previewRenderer
        self.makeScope = makeScope
        self.resolveScope = resolveScope
        self.makeBookmark = makeBookmark
    }
}

extension PhotoDocumentEditorDependencies {
    /// The real dependency graph: a `PhotoDocumentStore` rooted under
    /// `applicationSupportURL`, the production Core Image decode/preview
    /// pipeline, and real security-scoped bookmarks (`ScopedFolderAccess`/
    /// `SecurityScopedBookmark`). `userDefaults` is accepted only for
    /// source compatibility with callers that still pass one — it is
    /// unused: the active-document pointer lives in `PhotoDocumentStore`
    /// now, not `UserDefaults`.
    public static func live(
        applicationSupportURL: URL,
        userDefaults: UserDefaults = .standard
    ) -> PhotoDocumentEditorDependencies {
        let storeRootURL = applicationSupportURL.appendingPathComponent("PhotoDocuments", isDirectory: true)
        let decoder = CoreImageRawDecoder()
        let pipeline = AdjustmentPipeline()
        let renderService = ImageRenderService()
        let renderer = CoreImagePreviewRenderer(decoder: decoder, pipeline: pipeline, renderService: renderService)

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
            makeBookmark: { url in try SecurityScopedBookmark.makeBookmarkData(for: url) }
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
/// **Serialization.** Every operation that may end up owning `document`/
/// `documentScope`/`editor` (a fresh open, a startup restore, a close)
/// mints an `OperationToken` *synchronously*, at its public entry point,
/// before creating any `Task` — never from inside a `Task`'s body, where
/// the order tokens get minted in could end up not matching the order the
/// operations were actually requested in. Only the operation whose token is
/// still `currentToken` when its async work finishes is allowed to touch
/// shared state; a superseded operation discards whatever it produced
/// (stopping any scope it opened, rolling back any document it newly
/// created) instead of clobbering whatever the newer operation already
/// committed.
///
/// **Switching documents is two-phase.** A fresh open never touches the
/// document already open until the *new* one is fully built and validated
/// (copied/fingerprinted, metadata decoded, adjustments loaded). Only then
/// is the old document flushed, and only after that succeeds does the
/// hand-off happen — stopping the old scope, installing the new document,
/// and moving the active-document pointer directly from the old ID to the
/// new one, never through `nil`. If building the new document or flushing
/// the old one fails, the old document is left exactly as it was: open,
/// editable, its scope untouched.
@MainActor
public final class PhotoDocumentEditor: ObservableObject {
    public let editor = EditorSession()

    /// The currently open document, or `nil` before anything has been
    /// opened / after it has been closed. Never set until the editor is
    /// actually ready to show it.
    @Published public private(set) var document: PhotoDocument?

    /// True while a selection or restore is being prepared — a copy or
    /// fingerprint in flight, a bookmark being resolved, metadata being
    /// read — before the switch to it (or the initial open) actually
    /// happens. Distinct from `editor.isRendering`, which only covers
    /// preview decoding of an already-open document.
    @Published public private(set) var isPreparingDocument = false

    /// A file has been picked and is waiting for the user to choose
    /// in-place vs. copy. The security scope backing the pick lives in
    /// `pendingSelection`, not here.
    @Published public private(set) var hasPendingSelection = false

    /// Set when restoring the last-open `.inPlace` document finds its
    /// bookmark missing or otherwise unresolvable. The document itself
    /// (record, sidecar, active pointer) is still fully intact — only the
    /// path to reach the external RAW again is gone. A view can use this to
    /// show a "Choose the file again" affordance that calls
    /// `beginRelinkSelection(_:)`, distinct from the normal "Open a new
    /// photo" flow, since picking the wrong file here must be rejected
    /// rather than silently starting a second, unrelated document.
    @Published public private(set) var pendingRelink: PendingRelink?

    public struct PendingRelink: Equatable, Sendable {
        public let documentID: UUID
        public let sourceFingerprint: FileFingerprint
    }

    /// Open/restore/copy failures, and anything the launch-time
    /// reconciliation pass couldn't clean up. Kept separate from
    /// `editor.alert`, which is `EditorSession`'s own — a failure to *open*
    /// a document happens before there is an editor session to report it,
    /// and a failure *within* an open document (a render or save failure)
    /// is `EditorSession`'s to own.
    @Published public var alert: EditorAlert?

    /// A safe (path-free), non-modal diagnostic for background cleanup
    /// that didn't fully succeed — an incomplete rollback, or a bookmark
    /// refresh that couldn't be persisted. Never blocks the user, and never
    /// affects whether the document they're looking at is valid; a caller
    /// can surface it in a diagnostics UI, or just inspect it in tests.
    @Published public private(set) var cleanupDiagnostic: String?

    private let dependencies: PhotoDocumentEditorDependencies
    private var pendingSelection: (url: URL, scope: any SecurityScopedResource)?
    private var documentScope: (any SecurityScopedResource)?
    private var startupTask: Task<Void, Never>?
    private var openingTask: Task<Void, Never>?
    /// The in-flight flush shared by whichever operations are currently
    /// racing to close/replace the same current document. See
    /// `flushCurrentDocumentIfDirty()`.
    private var activeFlushTask: Task<Bool, Never>?

    /// The currently-open document's creation, set the moment a fresh
    /// open's atomic hand-off installs it as `document`, and cleared only
    /// once `PhotoDocumentStore.finalizeCreation(_:)` durably succeeds.
    /// While this is non-`nil`, the document showing on screen is not yet
    /// proven durable on disk (still `.pending`, not `.committed`) — a
    /// crash right now relies on the next launch's reconciliation finding
    /// the durably-written active pointer already pointing at it (see
    /// `openFreshSelection`) and promoting it. `closeCurrentDocument()` and
    /// `openFreshSelection`'s own switch step both retry finalizing this
    /// (via `retryFinalizeIfNeeded()`) *before* they are allowed to move
    /// the active pointer away from this document — see those methods for
    /// why letting the pointer move first would risk an already-shown,
    /// possibly-edited document being deleted by a later reconciliation
    /// pass that no longer sees it as the active one.
    private var unfinalizedCreation: PhotoDocumentCreation?

    /// Identifies one lifecycle operation from the moment it is minted to
    /// the moment it either commits or discards itself.
    private struct OperationToken: Equatable {
        let generation: UInt64
    }

    private var currentGeneration: UInt64 = 0
    private var currentToken: OperationToken?

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

    // MARK: - Token bookkeeping

    private func mintToken() -> OperationToken {
        currentGeneration += 1
        let token = OperationToken(generation: currentGeneration)
        currentToken = token
        return token
    }

    private func isCurrent(_ token: OperationToken) -> Bool {
        currentToken == token
    }

    // MARK: - Startup: reconcile, then restore

    /// Reclaims storage left behind by an import the app was killed in the
    /// middle of, then — only once that has finished, and only if the user
    /// has not started opening or closing anything in the meantime — tries
    /// to restore the most recently open document. Safe to call once per
    /// launch.
    public func performStartupSequence() {
        guard startupTask == nil else { return }
        // Snapshotted *before* reconciliation runs: if this still matches
        // `currentGeneration` once reconciliation finishes, nothing else
        // has minted a token since startup began, so restoring is still
        // this launch's to do. A fresh selection the user makes while
        // reconciliation is still running bumps `currentGeneration` itself
        // and so invalidates this baseline — restore simply never attempts
        // anything in that case, rather than racing (let alone cancelling)
        // the user's own open.
        let startupBaselineGeneration = currentGeneration
        // `Task {}` here inherits `@MainActor` from this method, exactly
        // like `EditorSession.startObservingPreviews` — the body only
        // touches `@Published` state after each `await` has already taken
        // the actual file-system work off this actor.
        startupTask = Task { [weak self] in
            await self?.reconcileOrphanedImports()
            await self?.restoreActiveDocumentIfPossible(ifStillAtBaseline: startupBaselineGeneration)
        }
    }

    private func reconcileOrphanedImports() async {
        do {
            let pointer = await dependencies.store.loadActiveDocumentPointer()
            let report = try await dependencies.store.reconcileOrphanedImports(activePointer: pointer)
            guard !report.failures.isEmpty || report.activePointerWasUnreadable else { return }
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

    /// Restores the document remembered by `loadActiveDocumentID`, if any —
    /// but only if `baselineGeneration` (captured before reconciliation
    /// started) is still current, i.e. the user has not already started
    /// opening or closing something. Never deletes anything on failure:
    /// unlike a fresh open, there is no newly created document here to roll
    /// back, only a pointer to an existing one — see
    /// `classifyRestoreFailure(_:)` for which failures still clear that
    /// pointer.
    private func restoreActiveDocumentIfPossible(ifStillAtBaseline baselineGeneration: UInt64) async {
        guard document == nil else { return }
        guard currentGeneration == baselineGeneration else { return }
        guard let activeID = await dependencies.store.loadActiveDocumentID() else { return }

        let token = mintToken()
        isPreparingDocument = true

        // Declared *outside* the `do` block -- like `openFreshSelection`'s
        // `pendingCreation` -- so every exit path (a genuine thrown error,
        // not just the in-`do` supersede checks) can still find and stop
        // it. Ownership transfers to `documentScope` only inside
        // `commitDocument`, at the very end of the success path; every
        // other path here must stop it itself exactly once, since nothing
        // else is going to.
        var candidateScope: (any SecurityScopedResource)?
        var loadedSourceFingerprint: FileFingerprint?
        do {
            let loadedDocument = try await dependencies.store.loadDocument(id: activeID)
            loadedSourceFingerprint = loadedDocument.sourceFingerprint
            let runtimeDocument: PhotoDocument

            switch loadedDocument.storageMode {
            case .appCopy:
                runtimeDocument = loadedDocument
            case .inPlace:
                guard let bookmarkData = loadedDocument.sourceBookmarkData else {
                    throw RestoreError.missingBookmark
                }
                let resolved = try dependencies.resolveScope(bookmarkData)
                candidateScope = resolved.resource
                guard resolved.resource.isAccessing else {
                    throw RestoreError.accessDenied
                }
                // The metadata decode, preview and editor `sourceURL` below
                // must all use exactly where the bookmark resolved to, not
                // the possibly-stale `workingURL` the record last
                // persisted — those can differ (a remounted volume, a
                // renamed enclosing folder) even when `isStale` reports
                // `false`.
                runtimeDocument = await reconciledInPlaceDocument(loadedDocument, resolvedTo: resolved)
            }

            let (photo, adjustments) = try await loadEditorState(for: runtimeDocument)
            guard isCurrent(token) else {
                candidateScope?.stop()
                return
            }
            await commitDocument(token: token, document: runtimeDocument, scope: candidateScope, photo: photo, adjustments: adjustments)
        } catch RestoreError.missingBookmark {
            candidateScope?.stop()
            guard isCurrent(token) else { return }
            isPreparingDocument = false
            // Recoverable via relink, not a reason to abandon the pointer
            // or force the user to start over as a brand-new document.
            // `loadedSourceFingerprint` is always set by this point --
            // `missingBookmark` is only thrown after `loadDocument`
            // already succeeded.
            if let loadedSourceFingerprint {
                pendingRelink = PendingRelink(documentID: activeID, sourceFingerprint: loadedSourceFingerprint)
            }
            alert = restoreFailureAlert(for: RestoreError.missingBookmark)
        } catch {
            candidateScope?.stop()
            guard isCurrent(token) else { return }
            isPreparingDocument = false
            if shouldClearActiveDocumentID(after: error) {
                // Best-effort: this document is not durably `.pending`
                // (restore never creates a fresh creation, only points at
                // an existing, already-`.committed` one) — a failure to
                // clear the pointer here risks nothing worse than the
                // *next* launch retrying the same already-known-bad
                // restore, which fails the same recoverable way again.
                try? await dependencies.store.saveActiveDocumentID(nil)
            }
            alert = restoreFailureAlert(for: error)
        }
    }

    /// Reconciles a restored `.inPlace` document's persisted location with
    /// where its bookmark actually resolved. When they already match and
    /// the bookmark isn't stale, this is a no-op returning `document`
    /// unchanged. Persistence failures never fail the restore itself — the
    /// in-memory document used for *this* restore is always correct — they
    /// only surface via `cleanupDiagnostic`, since a caller must be able to
    /// tell the difference between "restored cleanly" and "restored, but
    /// the next restore may redo this work" rather than that being
    /// silently swallowed.
    private func reconciledInPlaceDocument(
        _ document: PhotoDocument,
        resolvedTo resolved: ResolvedSecurityScope
    ) async -> PhotoDocument {
        let resolvedURL = resolved.resource.url
        guard resolvedURL != document.workingURL else {
            if resolved.isStale {
                await refreshBookmark(for: resolvedURL, documentID: document.id)
            }
            return document
        }

        // The bookmark now resolves somewhere other than the last
        // persisted location -- the working/source URL and the bookmark
        // that produced it must be persisted together, never one without
        // the other (a fresh bookmark recorded against a stale URL, or
        // vice versa, would silently break the *next* restore).
        guard let bookmark = try? dependencies.makeBookmark(resolvedURL) else {
            cleanupDiagnostic = L10n.t("LumaHarbor couldn't remember access to this photo for next time.")
            return relocated(document, to: resolvedURL, bookmarkData: document.sourceBookmarkData)
        }
        do {
            try await dependencies.store.updateInPlaceLocation(newURL: resolvedURL, bookmarkData: bookmark, documentID: document.id)
            return try await dependencies.store.loadDocument(id: document.id)
        } catch {
            cleanupDiagnostic = L10n.t("LumaHarbor couldn't remember access to this photo for next time.")
            return relocated(document, to: resolvedURL, bookmarkData: bookmark)
        }
    }

    private func refreshBookmark(for url: URL, documentID: UUID) async {
        guard let refreshed = try? dependencies.makeBookmark(url) else {
            cleanupDiagnostic = L10n.t("LumaHarbor couldn't remember access to this photo for next time.")
            return
        }
        do {
            try await dependencies.store.updateSourceBookmark(refreshed, documentID: documentID)
        } catch {
            cleanupDiagnostic = L10n.t("LumaHarbor couldn't remember access to this photo for next time.")
        }
    }

    private func relocated(_ document: PhotoDocument, to newURL: URL, bookmarkData: Data?) -> PhotoDocument {
        PhotoDocument(
            id: document.id,
            storageMode: .inPlace,
            workingURL: newURL,
            sourceURL: newURL,
            sourceBookmarkData: bookmarkData,
            sourceFingerprint: document.sourceFingerprint,
            workingFingerprint: document.workingFingerprint
        )
    }

    private enum RestoreError: Error {
        case missingBookmark
        case accessDenied
    }

    /// Only a genuinely unrecoverable failure clears the remembered active
    /// document: the record itself is gone. Everything else — an offline
    /// external drive, a security scope that failed this one time, a
    /// transient decode or sidecar-read failure — leaves the pointer in
    /// place so the *next* launch (or an explicit retry) can succeed
    /// without the user having to re-pick the file from Files.
    private func shouldClearActiveDocumentID(after error: Error) -> Bool {
        switch error {
        case PhotoDocumentError.documentNotFound:
            return true
        case RestoreError.missingBookmark:
            // A record saved without ever getting a bookmark can never
            // resolve on its own; only re-selecting the file (a fresh
            // open) can recover it.
            return true
        default:
            return false
        }
    }

    /// Restore-specific failures get their own actionable text rather than
    /// falling through to a generic "something went wrong" — a retry-vs-
    /// relink distinction the user can actually act on.
    private func restoreFailureAlert(for error: Error) -> EditorAlert {
        let title = L10n.t("Couldn't reopen your last photo")
        switch error {
        case PhotoDocumentError.documentNotFound:
            return EditorAlert(
                title: title,
                message: L10n.t("LumaHarbor couldn't find this photo's saved document."),
                nextStep: L10n.t("Choose the file again from Files.")
            )
        case RestoreError.missingBookmark:
            return EditorAlert(
                title: title,
                message: L10n.t("LumaHarbor no longer has access to this file."),
                nextStep: L10n.t("Choose the file again from Files.")
            )
        case RestoreError.accessDenied:
            return EditorAlert(
                title: title,
                message: L10n.t("LumaHarbor no longer has access to this file."),
                nextStep: L10n.t("Reconnect the drive, then try again.")
            )
        default:
            return SafeErrorPresentation.alert(title: title, for: error)
        }
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

    // MARK: - Relinking a document with a missing bookmark

    /// The user dismissed the file picker `beginRelinkSelection(_:)` needs,
    /// without picking a file. The existing document (record, sidecar,
    /// active pointer) is completely untouched — and so, deliberately, is
    /// `pendingRelink` itself: for a single-photo UI, the relink prompt it
    /// drives is the *only* way back to this document, so a plain cancel
    /// must never tear it down. A caller that wants a way to actually give
    /// up on recovering this specific document needs a distinctly named
    /// action of its own that says so — conflating that with dismissing a
    /// file picker is exactly the bug this method used to have (it cleared
    /// `pendingRelink`, silently making the prompt itself the thing being
    /// cancelled).
    public func cancelRelink() {}

    /// The user picked a file in response to `pendingRelink`. Verifies
    /// `url`'s content fingerprint matches the document's original
    /// `sourceFingerprint` before touching anything — an unrelated RAW can
    /// never get attached to another document's saved sidecar/adjustments
    /// by mistake. On a mismatch, `pendingRelink` stays set (so the user
    /// can try again) and nothing on disk changes. On success, the
    /// existing document's `workingURL`/`sourceURL`/bookmark are updated in
    /// place and it is opened with its own already-saved adjustments —
    /// never a fresh, neutral document under a new ID.
    public func beginRelinkSelection(_ url: URL) {
        guard let relink = pendingRelink else { return }
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

        openingTask?.cancel()
        let token = mintToken()
        isPreparingDocument = true

        openingTask = Task { [weak self, dependencies] in
            guard let self else {
                // The controller itself is already gone -- nothing left to
                // supersede-check against, but the scope this task is
                // holding is still open and must not leak.
                scope.stop()
                return
            }
            guard !Task.isCancelled, self.isCurrent(token) else {
                scope.stop()
                return
            }
            do {
                let bookmarkData = try dependencies.makeBookmark(url)
                // Resolved immediately, transiently, purely so the store
                // can verify the fresh bookmark actually points at the
                // exact file it was just minted from -- this scope is
                // stopped right after the store call below, whether it
                // succeeds or fails; the *ongoing* scope for the document,
                // if this relink commits, is still `scope` from the
                // picker, exactly as before.
                let resolved = try dependencies.resolveScope(bookmarkData)
                defer { resolved.resource.stop() }
                let relinkedDocument = try await dependencies.store.relinkInPlaceDocument(
                    documentID: relink.documentID,
                    candidateURL: url,
                    bookmarkData: bookmarkData,
                    resolvedBookmarkURL: resolved.resource.url
                )
                guard !Task.isCancelled, self.isCurrent(token) else {
                    scope.stop()
                    return
                }
                let (photo, adjustments) = try await self.loadEditorState(for: relinkedDocument)
                guard self.isCurrent(token) else {
                    scope.stop()
                    return
                }
                await self.commitDocument(token: token, document: relinkedDocument, scope: scope, photo: photo, adjustments: adjustments)
            } catch RelinkError.fingerprintMismatch, RelinkError.contentMismatch, RelinkError.bookmarkIdentityMismatch {
                scope.stop()
                guard self.isCurrent(token) else { return }
                self.isPreparingDocument = false
                // `pendingRelink` deliberately stays set -- the existing
                // document is untouched and the user can try picking again.
                self.alert = EditorAlert(
                    title: L10n.t("That's not the same photo"),
                    message: L10n.t("This file doesn't match the photo LumaHarbor is trying to reconnect."),
                    nextStep: L10n.t("Choose the file again from Files.")
                )
            } catch RelinkError.sourceModifiedDuringRelink {
                scope.stop()
                guard self.isCurrent(token) else { return }
                self.isPreparingDocument = false
                // `pendingRelink` deliberately stays set here too -- the
                // file changed while it was being verified, so nothing was
                // touched and the user can simply try again.
                self.alert = EditorAlert(
                    title: L10n.t("That's not the same photo"),
                    message: L10n.t("This file changed while LumaHarbor was checking it."),
                    nextStep: L10n.t("Choose the file again from Files.")
                )
            } catch RelinkError.legacyFullDigestUnavailable {
                scope.stop()
                guard self.isCurrent(token) else { return }
                self.isPreparingDocument = false
                // Also stays set: refusing this file is a safety decision,
                // not proof the user picked the wrong one -- they still
                // have nothing else to try if not this same prompt again.
                self.alert = EditorAlert(
                    title: L10n.t("Can't verify this photo"),
                    message: L10n.t("This file is too large for LumaHarbor to safely confirm it's the same photo."),
                    nextStep: nil
                )
            } catch {
                scope.stop()
                guard self.isCurrent(token) else { return }
                self.isPreparingDocument = false
                self.alert = SafeErrorPresentation.alert(title: L10n.t("Couldn't open this photo"), for: error)
            }
        }
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
    /// Claims and clears `pendingSelection`, and mints this operation's
    /// token, synchronously — before this method returns and before any
    /// `Task` is created. A confirmation dialog's own dismissal bookkeeping
    /// runs right after the button's action closure returns and calls back
    /// into `cancelPendingSelection()`; doing the claim here means there is
    /// nothing left for that callback to race. Minting the token here too
    /// — rather than as the first line of the `Task` body — is what
    /// guarantees token order always matches call order: two calls to this
    /// method in sequence always mint their tokens in that same sequence,
    /// regardless of which of their `Task` bodies the scheduler happens to
    /// run first.
    public func beginOpeningPendingSelection(mode: PhotoDocumentOpenMode) {
        guard let selection = pendingSelection else { return }
        pendingSelection = nil
        hasPendingSelection = false
        openFreshSelection(url: selection.url, scope: selection.scope, mode: mode)
    }

    // MARK: - Opening a fresh selection (two-phase switch)

    private func openFreshSelection(url: URL, scope: any SecurityScopedResource, mode: PhotoDocumentOpenMode) {
        openingTask?.cancel()
        let token = mintToken()
        isPreparingDocument = true

        openingTask = Task { [weak self, dependencies] in
            guard let self else {
                // The controller itself is already gone -- nothing left to
                // supersede-check against, but the scope this task is
                // holding is still open and must not leak.
                scope.stop()
                return
            }
            guard !Task.isCancelled, self.isCurrent(token) else {
                // Superseded before this task's body got to run at all.
                scope.stop()
                return
            }

            // Declared *outside* the `do` block, unlike everything else
            // built during phase 1, so a genuine thrown error (not just a
            // supersede) can still find and roll back whatever was already
            // created -- e.g. the copy/record committed fine, but reading
            // its metadata right afterward failed.
            var pendingCreation: PhotoDocumentCreation?

            do {
                // PHASE 1: build and fully validate the new document --
                // never touches whatever is currently open.
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

                let creation: PhotoDocumentCreation
                switch mode {
                case .inPlace:
                    creation = try await dependencies.store.openInPlace(url, bookmarkData: bookmarkData)
                case .appCopy:
                    creation = try await dependencies.store.importCopy(of: url, bookmarkData: bookmarkData)
                    // The verified copy is committed to App storage; the
                    // external source is no longer read from, so its scope
                    // is released right away, independent of whether the
                    // switch this is part of ultimately succeeds.
                    scope.stop()
                }
                pendingCreation = creation

                guard !Task.isCancelled, self.isCurrent(token) else {
                    await self.discard(creation, sourceScope: mode == .inPlace ? scope : nil)
                    return
                }

                let (photo, adjustments) = try await self.loadEditorState(for: creation.document)

                guard !Task.isCancelled, self.isCurrent(token) else {
                    await self.discard(creation, sourceScope: mode == .inPlace ? scope : nil)
                    return
                }

                // PHASE 2: the new document is fully built and validated.
                // Only now is whatever was open before touched at all.
                let oldFlushed = await self.flushCurrentDocumentIfDirty()
                guard self.isCurrent(token) else {
                    await self.discard(creation, sourceScope: mode == .inPlace ? scope : nil)
                    return
                }
                guard oldFlushed else {
                    // The previously-open document couldn't be flushed --
                    // `EditorSession` has already surfaced why through its
                    // own `alert`. Abort the switch entirely: the old
                    // document remains open, valid and untouched; the new
                    // one, never shown, is rolled back.
                    await self.discard(creation, sourceScope: mode == .inPlace ? scope : nil)
                    self.isPreparingDocument = false
                    return
                }

                // The document about to be replaced must itself be
                // durably `.committed` before the active pointer is
                // allowed to move off it -- otherwise a crash right after
                // this switch would leave it `.pending` with a pointer no
                // longer pointing at it, and the next launch's
                // reconciliation would roll it back even though the user
                // had already been shown it (and may have edited it).
                guard await self.retryFinalizeIfNeeded() else {
                    await self.discard(creation, sourceScope: mode == .inPlace ? scope : nil)
                    guard self.isCurrent(token) else { return }
                    self.isPreparingDocument = false
                    self.alert = EditorAlert(
                        title: L10n.t("Couldn't switch photos"),
                        message: L10n.t("LumaHarbor couldn't finish saving the photo you had open."),
                        nextStep: L10n.t("Try again.")
                    )
                    return
                }
                guard self.isCurrent(token) else {
                    await self.discard(creation, sourceScope: mode == .inPlace ? scope : nil)
                    return
                }

                // The active pointer is durably written to the *new*
                // document *before* anything in-memory changes -- a write
                // failure here must never be treated as though the
                // hand-off became durable. If it fails, the switch is
                // aborted exactly like a flush failure above: the old
                // document remains open, valid and untouched, and the new
                // one (never actually shown) is rolled back.
                do {
                    try await self.dependencies.store.saveActiveDocumentID(creation.document.id)
                } catch {
                    await self.discard(creation, sourceScope: mode == .inPlace ? scope : nil)
                    guard self.isCurrent(token) else { return }
                    self.isPreparingDocument = false
                    self.alert = EditorAlert(
                        title: L10n.t("Couldn't switch photos"),
                        message: L10n.t("LumaHarbor couldn't remember this photo for next time."),
                        nextStep: L10n.t("Try again.")
                    )
                    return
                }
                guard self.isCurrent(token) else {
                    await self.discard(creation, sourceScope: mode == .inPlace ? scope : nil)
                    return
                }

                // Atomic hand-off: no `await` between here and the end of
                // this block, so nothing else can run on the main actor in
                // between. The active-document pointer has already moved
                // durably to the new ID above -- this is only the
                // in-memory state catching up to what disk already says.
                let previousScope = self.documentScope
                self.documentScope = mode == .inPlace ? scope : nil
                self.document = creation.document
                self.editor.open(
                    photo: photo, sourceURL: creation.document.workingURL,
                    adjustments: adjustments, isReadOnly: false
                )
                self.isPreparingDocument = false
                self.pendingRelink = nil
                previousScope?.stop()
                // After the swap above, not part of it. The creation shown
                // is not yet proven durably `.committed` on disk -- only
                // its active pointer is -- so it is tracked as this
                // controller's `unfinalizedCreation` until finalize
                // actually succeeds; `closeCurrentDocument()` and this same
                // switch step, next time either runs, retry it before
                // letting the pointer move again. This first attempt is
                // best-effort: a failure here is not shown to the user (the
                // document is already fully open and usable) and simply
                // waits for the next such retry.
                self.unfinalizedCreation = creation
                await self.retryFinalizeIfNeeded()
            } catch is CancellationError {
                // A newer selection or a close pre-empted this one before
                // it could even reach its own checks above (e.g. while
                // still awaiting `openInPlace`/`importCopy` itself). For an
                // in-flight `importCopy`, the store's own cancellation
                // cleanup has already removed the partial copy; a fully
                // committed creation (cancelled just after) still needs
                // rolling back here.
                scope.stop()
                if let pendingCreation {
                    await self.discard(pendingCreation, sourceScope: nil)
                }
            } catch {
                scope.stop()
                if let pendingCreation {
                    await self.discard(pendingCreation, sourceScope: nil)
                }
                guard self.isCurrent(token) else { return }
                self.isPreparingDocument = false
                self.alert = SafeErrorPresentation.alert(title: L10n.t("Couldn't open this photo"), for: error)
            }
        }
    }

    // MARK: - Opening a library asset (Task 4)

    /// Local control-flow errors for `openLibraryAsset(_:)`'s two private
    /// implementations.
    private enum LibraryAssetOpenError: Error {
        /// `openLibraryExternalAsset(url:)`: maps any failure to actually
        /// read/fingerprint an indexed external asset into this one,
        /// specific outcome, distinct from a genuine cancellation
        /// (superseded by a newer operation) or a later, unrelated failure
        /// (e.g. metadata decode) once the source *was* successfully read.
        case sourceUnreachable
        /// `openLibraryAppCopy(documentID:)`: the loaded record's
        /// `storageMode` is not `.appCopy`. `LibraryOpenAsset.appCopy` is a
        /// distinct case from `.external` precisely because the two need
        /// different handling (no scope, no bookmark, never re-import vs.
        /// a full external open) -- silently opening whatever
        /// `storageMode` a mismatched `documentID` actually has would
        /// erase that distinction: an `.inPlace` document's `workingURL`
        /// is an external file that needs a security scope this path never
        /// acquires.
        case notAnAppCopy
    }

    /// Opens `asset`, handed in by the multi-source library browser (Task 5)
    /// rather than produced by a Files-picker selection. Which case `asset`
    /// is already decides in-place vs. copy, so this bypasses the
    /// import-choice dialog entirely -- but otherwise reuses every other
    /// piece of this controller's existing open machinery: cancellation
    /// generation, scope acquisition, flush-before-switch, decode, rollback
    /// and alert handling. No new document ever becomes visible before it
    /// has been fully built and validated, exactly like a fresh selection
    /// or a restore.
    public func openLibraryAsset(_ asset: LibraryOpenAsset) {
        switch asset {
        case .external(let url, let scopeURL, _):
            openLibraryExternalAsset(url: url, scopeURL: scopeURL)
        case .appCopy(let documentID):
            openLibraryAppCopy(documentID: documentID)
        }
    }

    private func offlineSourceAlert() -> EditorAlert {
        EditorAlert(
            title: L10n.t("Couldn't open this photo"),
            message: L10n.t("LumaHarbor no longer has access to this file."),
            nextStep: L10n.t("Reconnect the source, then try again.")
        )
    }

    /// An indexed photo at an already-authorised external library source --
    /// opened exactly like a fresh `.inPlace` selection (same two-phase
    /// switch, same rollback-on-failure, same finalize/active-pointer
    /// gating as `openFreshSelection(url:scope:mode:)`), minus the
    /// import-choice dialog: a library-indexed source is always opened in
    /// place, never copied.
    ///
    /// A source that has gone offline since it was indexed (the drive
    /// unplugged, permission revoked) must never tear down whatever
    /// document is currently open -- there is nothing to switch to.
    /// Detected two ways, both mapped to the same actionable alert: the
    /// security scope itself failing to open, checked immediately and
    /// before anything else is touched; or -- more likely in practice,
    /// since a stale sandbox grant can still nominally "open" against a
    /// volume that is no longer actually reachable -- the attempt to read
    /// and fingerprint the file inside `PhotoDocumentStore.openInPlace`
    /// failing for any non-cancellation reason. Either way, nothing here
    /// mints a token or touches `document`/`openingTask` until the source
    /// has actually been proven reachable.
    private func openLibraryExternalAsset(url: URL, scopeURL: URL) {
        let scope = dependencies.makeScope(scopeURL)
        guard scope.isAccessing else {
            scope.stop()
            alert = offlineSourceAlert()
            return
        }

        openingTask?.cancel()
        let token = mintToken()
        isPreparingDocument = true

        openingTask = Task { [weak self, dependencies] in
            guard let self else {
                scope.stop()
                return
            }
            guard !Task.isCancelled, self.isCurrent(token) else {
                scope.stop()
                return
            }

            var pendingCreation: PhotoDocumentCreation?
            do {
                // Best-effort, exactly like `openFreshSelection`'s own
                // `.inPlace` case: restorability depends on this bookmark,
                // but a fresh library open can still proceed without one --
                // it will simply need re-picking after a relaunch, same as
                // any other bookmark-less `.inPlace` document.
                let bookmarkData = try? dependencies.makeBookmark(url)

                if let existingDocument = try? await dependencies.store.committedInPlaceDocument(matching: url) {
                    let (photo, adjustments) = try await self.loadEditorState(for: existingDocument)
                    guard !Task.isCancelled, self.isCurrent(token) else {
                        scope.stop()
                        return
                    }

                    let oldFlushed = await self.flushCurrentDocumentIfDirty()
                    guard self.isCurrent(token) else {
                        scope.stop()
                        return
                    }
                    guard oldFlushed else {
                        scope.stop()
                        self.isPreparingDocument = false
                        return
                    }

                    guard await self.retryFinalizeIfNeeded() else {
                        scope.stop()
                        guard self.isCurrent(token) else { return }
                        self.isPreparingDocument = false
                        self.alert = EditorAlert(
                            title: L10n.t("Couldn't switch photos"),
                            message: L10n.t("LumaHarbor couldn't finish saving the photo you had open."),
                            nextStep: L10n.t("Try again.")
                        )
                        return
                    }
                    guard self.isCurrent(token) else {
                        scope.stop()
                        return
                    }

                    do {
                        try await self.dependencies.store.saveActiveDocumentID(existingDocument.id)
                    } catch {
                        scope.stop()
                        guard self.isCurrent(token) else { return }
                        self.isPreparingDocument = false
                        self.alert = EditorAlert(
                            title: L10n.t("Couldn't switch photos"),
                            message: L10n.t("LumaHarbor couldn't remember this photo for next time."),
                            nextStep: L10n.t("Try again.")
                        )
                        return
                    }
                    guard self.isCurrent(token) else {
                        scope.stop()
                        return
                    }

                    if let bookmarkData {
                        do {
                            try await self.dependencies.store.updateSourceBookmark(bookmarkData, documentID: existingDocument.id)
                        } catch {
                            self.cleanupDiagnostic = L10n.t("LumaHarbor couldn't remember access to this photo for next time.")
                        }
                    }

                    let previousScope = self.documentScope
                    self.documentScope = scope
                    self.document = existingDocument
                    self.editor.open(
                        photo: photo, sourceURL: existingDocument.workingURL,
                        adjustments: adjustments, isReadOnly: false
                    )
                    self.isPreparingDocument = false
                    self.pendingRelink = nil
                    previousScope?.stop()
                    return
                }

                let creation: PhotoDocumentCreation
                do {
                    creation = try await dependencies.store.openInPlace(url, bookmarkData: bookmarkData)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw LibraryAssetOpenError.sourceUnreachable
                }
                pendingCreation = creation

                guard !Task.isCancelled, self.isCurrent(token) else {
                    await self.discard(creation, sourceScope: scope)
                    return
                }

                let (photo, adjustments) = try await self.loadEditorState(for: creation.document)
                guard !Task.isCancelled, self.isCurrent(token) else {
                    await self.discard(creation, sourceScope: scope)
                    return
                }

                // PHASE 2: same switch machinery as a fresh open.
                let oldFlushed = await self.flushCurrentDocumentIfDirty()
                guard self.isCurrent(token) else {
                    await self.discard(creation, sourceScope: scope)
                    return
                }
                guard oldFlushed else {
                    await self.discard(creation, sourceScope: scope)
                    self.isPreparingDocument = false
                    return
                }

                guard await self.retryFinalizeIfNeeded() else {
                    await self.discard(creation, sourceScope: scope)
                    guard self.isCurrent(token) else { return }
                    self.isPreparingDocument = false
                    self.alert = EditorAlert(
                        title: L10n.t("Couldn't switch photos"),
                        message: L10n.t("LumaHarbor couldn't finish saving the photo you had open."),
                        nextStep: L10n.t("Try again.")
                    )
                    return
                }
                guard self.isCurrent(token) else {
                    await self.discard(creation, sourceScope: scope)
                    return
                }

                do {
                    try await self.dependencies.store.saveActiveDocumentID(creation.document.id)
                } catch {
                    await self.discard(creation, sourceScope: scope)
                    guard self.isCurrent(token) else { return }
                    self.isPreparingDocument = false
                    self.alert = EditorAlert(
                        title: L10n.t("Couldn't switch photos"),
                        message: L10n.t("LumaHarbor couldn't remember this photo for next time."),
                        nextStep: L10n.t("Try again.")
                    )
                    return
                }
                guard self.isCurrent(token) else {
                    await self.discard(creation, sourceScope: scope)
                    return
                }

                let previousScope = self.documentScope
                self.documentScope = scope
                self.document = creation.document
                self.editor.open(
                    photo: photo, sourceURL: creation.document.workingURL,
                    adjustments: adjustments, isReadOnly: false
                )
                self.isPreparingDocument = false
                self.pendingRelink = nil
                previousScope?.stop()
                self.unfinalizedCreation = creation
                await self.retryFinalizeIfNeeded()
            } catch LibraryAssetOpenError.sourceUnreachable {
                scope.stop()
                guard self.isCurrent(token) else { return }
                self.isPreparingDocument = false
                self.alert = self.offlineSourceAlert()
            } catch is CancellationError {
                scope.stop()
                if let pendingCreation {
                    await self.discard(pendingCreation, sourceScope: nil)
                }
            } catch {
                scope.stop()
                if let pendingCreation {
                    await self.discard(pendingCreation, sourceScope: nil)
                }
                guard self.isCurrent(token) else { return }
                self.isPreparingDocument = false
                self.alert = SafeErrorPresentation.alert(title: L10n.t("Couldn't open this photo"), for: error)
            }
        }
    }

    /// An existing, already-`.committed` App-copy document -- opens the
    /// record directly and never calls `importCopy` again. Structurally
    /// parallel to `commitDocument(token:document:scope:photo:adjustments:)`
    /// (used by restore/relink), except this must *also* flush-and-replace
    /// whatever document is currently open first: unlike restore (runs only
    /// at startup, before anything is open) and relink (only reachable
    /// while `document` is already `nil`), opening a library App copy can
    /// happen at any time, including while a different document is open and
    /// dirty.
    ///
    /// `documentID` is trusted to name an `.appCopy` record only as far as
    /// `LibraryOpenAsset.appCopy`'s own contract goes -- a caller could, in
    /// error, pass an `.inPlace` document's id through this case instead of
    /// `.external`. Loading the record and checking its `storageMode`
    /// before doing anything else is what keeps that mistake from actually
    /// reading an external file with no security scope: this path never
    /// acquires one (`documentScope` is always set to `nil` on success),
    /// which is only safe because a genuine `.appCopy` document's
    /// `workingURL` always lives inside the app's own sandbox. A mismatch
    /// fails closed -- nothing here is touched, and a caller can never see
    /// this path silently reinterpret an in-place document as a copy.
    private func openLibraryAppCopy(documentID: UUID) {
        openingTask?.cancel()
        let token = mintToken()
        isPreparingDocument = true

        openingTask = Task { [weak self, dependencies] in
            guard let self else { return }
            guard !Task.isCancelled, self.isCurrent(token) else { return }

            do {
                let loadedDocument = try await dependencies.store.loadDocument(id: documentID)
                guard !Task.isCancelled, self.isCurrent(token) else { return }
                guard loadedDocument.storageMode == .appCopy else {
                    throw LibraryAssetOpenError.notAnAppCopy
                }

                let (photo, adjustments) = try await self.loadEditorState(for: loadedDocument)
                guard !Task.isCancelled, self.isCurrent(token) else { return }

                let oldFlushed = await self.flushCurrentDocumentIfDirty()
                guard self.isCurrent(token) else { return }
                guard oldFlushed else {
                    self.isPreparingDocument = false
                    return
                }

                guard await self.retryFinalizeIfNeeded() else {
                    guard self.isCurrent(token) else { return }
                    self.isPreparingDocument = false
                    self.alert = EditorAlert(
                        title: L10n.t("Couldn't switch photos"),
                        message: L10n.t("LumaHarbor couldn't finish saving the photo you had open."),
                        nextStep: L10n.t("Try again.")
                    )
                    return
                }
                guard self.isCurrent(token) else { return }

                do {
                    try await self.dependencies.store.saveActiveDocumentID(loadedDocument.id)
                } catch {
                    guard self.isCurrent(token) else { return }
                    self.isPreparingDocument = false
                    self.alert = EditorAlert(
                        title: L10n.t("Couldn't switch photos"),
                        message: L10n.t("LumaHarbor couldn't remember this photo for next time."),
                        nextStep: L10n.t("Try again.")
                    )
                    return
                }
                guard self.isCurrent(token) else { return }

                let previousScope = self.documentScope
                self.documentScope = nil
                self.document = loadedDocument
                self.editor.open(
                    photo: photo, sourceURL: loadedDocument.workingURL,
                    adjustments: adjustments, isReadOnly: false
                )
                self.isPreparingDocument = false
                self.pendingRelink = nil
                previousScope?.stop()
            } catch LibraryAssetOpenError.notAnAppCopy {
                guard self.isCurrent(token) else { return }
                self.isPreparingDocument = false
                self.alert = EditorAlert(
                    title: L10n.t("Couldn't open this photo"),
                    message: L10n.t("This isn't a saved App copy."),
                    nextStep: nil
                )
            } catch is CancellationError {
                // Superseded before committing -- this document was already
                // `.committed`, so there is nothing here to roll back.
            } catch {
                guard self.isCurrent(token) else { return }
                self.isPreparingDocument = false
                self.alert = SafeErrorPresentation.alert(title: L10n.t("Couldn't open this photo"), for: error)
            }
        }
    }

    /// Rolls back a creation that was built but must never be shown --
    /// superseded, or the switch it was part of was aborted. `sourceScope`
    /// is the `.inPlace` source scope to stop, if this creation held one
    /// (an `.appCopy` creation's source scope was already stopped right
    /// after the copy completed).
    private func discard(_ creation: PhotoDocumentCreation, sourceScope: (any SecurityScopedResource)?) async {
        sourceScope?.stop()
        let report = await dependencies.store.rollbackNewDocument(creation)
        recordIfIncomplete(report)
    }

    private func recordIfIncomplete(_ report: PhotoDocumentRollbackReport) {
        guard !report.isFullyCleaned else { return }
        cleanupDiagnostic = L10n.t("LumaHarbor couldn't finish cleaning up after a photo that failed to open.")
    }

    /// Retries durably finalizing `unfinalizedCreation`, if there is one.
    /// Returns `true` when there is nothing left to finalize (already
    /// `nil`, or this call just succeeded) — the caller may safely proceed
    /// to move the active pointer away from the current document. Returns
    /// `false` when a durable commit still could not be produced — the
    /// caller must *not* proceed: closing or switching away now would let
    /// the active pointer move off a document that is still only
    /// `.pending` on disk, which a future reconciliation pass (seeing it
    /// no longer matches the active pointer) would roll back — deleting a
    /// document already shown to, and possibly edited by, the user.
    ///
    /// `.alreadyRolledBack`/`.unknownReceipt` are treated as "nothing left
    /// to do" too: both should be unreachable for a creation this instance
    /// itself just committed and is still tracking, but neither leaves
    /// anything for a retry to accomplish if it somehow occurs.
    @discardableResult
    private func retryFinalizeIfNeeded() async -> Bool {
        guard let creation = unfinalizedCreation else { return true }
        switch await dependencies.store.finalizeCreation(creation) {
        case .committed, .alreadyFinalized:
            unfinalizedCreation = nil
            return true
        case .retryRequired:
            return false
        case .alreadyRolledBack, .unknownReceipt:
            unfinalizedCreation = nil
            return false
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

    /// Commits an already-fully-prepared *existing* document (the restore
    /// and relink paths only — a fresh open's own two-phase hand-off is
    /// inlined in `openFreshSelection`, since it also needs to flush and
    /// replace whatever was open first).
    ///
    /// Unlike a fresh open, `document` here is always already `.committed`
    /// on disk — restore only ever points at an existing document, and
    /// relink only updates an existing one's location — so there is no
    /// pending creation at stake and no `unfinalizedCreation` bookkeeping
    /// needed. The active-pointer write below is still attempted durably,
    /// but only best-effort: a failure leaves the *previous* session's
    /// pointer in place (or clears to nothing), which at worst costs a
    /// future restore, never risks this already-safe document being
    /// deleted.
    private func commitDocument(
        token: OperationToken,
        document: PhotoDocument,
        scope: (any SecurityScopedResource)?,
        photo: PhotoAsset,
        adjustments: PhotoAdjustments
    ) async {
        documentScope = scope
        self.document = document
        editor.open(photo: photo, sourceURL: document.workingURL, adjustments: adjustments, isReadOnly: false)
        do {
            try await dependencies.store.saveActiveDocumentID(document.id)
        } catch {
            cleanupDiagnostic = L10n.t("LumaHarbor couldn't remember this photo for next time.")
        }
        isPreparingDocument = false
        pendingRelink = nil
    }

    // MARK: - Closing

    /// Cancels any in-flight open (even one still building a document that
    /// has not yet committed), then flushes and tears down whatever is
    /// currently open, if anything. Returns `false` — leaving the document,
    /// editor and scope untouched — when something unsaved could not be
    /// written; `EditorSession.flushPendingEdits()` has already surfaced
    /// that failure through `editor.alert`.
    @discardableResult
    public func closeCurrentDocument() async -> Bool {
        // Mints a new token *before* anything else, synchronously -- this
        // alone guarantees a pending open (even one still stuck mid-decode,
        // with `document` still `nil`) can never commit after this call
        // starts, regardless of when its `Task` actually gets cancelled.
        openingTask?.cancel()
        openingTask = nil
        let token = mintToken()

        guard document != nil else {
            isPreparingDocument = false
            return true
        }

        isPreparingDocument = true
        let flushed = await flushCurrentDocumentIfDirty()
        guard isCurrent(token) else {
            // Superseded while flushing (e.g. a fresh open that itself
            // flushed-and-replaced this same document) -- that operation
            // owns things now.
            return flushed
        }
        guard flushed else {
            isPreparingDocument = false
            return false
        }

        // The document being closed must be durably `.committed` before
        // the active pointer can be cleared -- otherwise a crash right
        // after this close, with the pointer already gone, would leave a
        // still-`.pending` record that the next launch's reconciliation
        // (seeing it no longer matches the, now cleared, active pointer)
        // would roll back, even though the user closed it normally and it
        // may hold edits. Leaves the document open (not closed) on
        // failure -- the safest state, and the same choice a flush
        // failure above already makes.
        guard await retryFinalizeIfNeeded() else {
            guard isCurrent(token) else { return false }
            isPreparingDocument = false
            alert = EditorAlert(
                title: L10n.t("Couldn't close this photo"),
                message: L10n.t("LumaHarbor couldn't finish saving this photo."),
                nextStep: L10n.t("Try again.")
            )
            return false
        }
        guard isCurrent(token) else { return true }

        // Clearing the active pointer must itself be durable -- a failed
        // write here must not be treated as though the close became
        // durable either. On failure, the document stays open rather than
        // showing a "closed" UI backed by a pointer that, on disk, still
        // points at it.
        do {
            try await dependencies.store.saveActiveDocumentID(nil)
        } catch {
            guard isCurrent(token) else { return false }
            isPreparingDocument = false
            alert = EditorAlert(
                title: L10n.t("Couldn't close this photo"),
                message: L10n.t("LumaHarbor couldn't remember that this photo was closed."),
                nextStep: L10n.t("Try again.")
            )
            return false
        }
        guard isCurrent(token) else { return true }

        editor.close()
        let closedScope = documentScope
        document = nil
        documentScope = nil
        isPreparingDocument = false
        closedScope?.stop()
        return true
    }

    /// Flushes whatever document is currently open, if any, without
    /// touching `document`/`documentScope`/`editor`/the active-document
    /// pointer itself — callers (`closeCurrentDocument`, and a fresh open's
    /// own phase-2 hand-off) decide what to do once this resolves, using
    /// their own token to check they are still allowed to act.
    ///
    /// Safe to call from two places "at once": concurrent callers share the
    /// *same* underlying flush via `activeFlushTask` rather than each
    /// calling `EditorSession.flushPendingEdits()` independently, since two
    /// concurrent flushes of the same session is not something
    /// `EditorSession` is built to tolerate.
    private func flushCurrentDocumentIfDirty() async -> Bool {
        guard document != nil else { return true }
        if let existing = activeFlushTask {
            return await existing.value
        }
        let task = Task { [editor] in await editor.flushPendingEdits() }
        activeFlushTask = task
        let result = await task.value
        activeFlushTask = nil
        return result
    }
}
