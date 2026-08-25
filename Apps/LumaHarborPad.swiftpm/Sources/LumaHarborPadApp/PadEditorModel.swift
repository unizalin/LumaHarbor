import EditorCore
import Foundation
import Localization
import PhotoLibraryCore
import RawProcessingCore

/// Which of the two source modes the user picked for a freshly selected
/// file. Mirrors `PhotoDocumentStorageMode`, but stays a separate type
/// because it describes a one-time user choice about *how to open*, not a
/// document's persisted storage mode.
public enum PadOpenMode: Equatable, Sendable {
    case inPlace
    case appCopy
}

/// Owns the single `EditorSession` for the iPad vertical slice: wires it to
/// a real `PhotoDocumentStore`-backed persistence pipeline, and turns a URL
/// the user picked in Files into an open, editable document.
///
/// There is exactly one `EditorSession` for the lifetime of this model
/// (`editor`, set once at `init`) — `PadRootView`/`PadEditorView` must read
/// it from here rather than constructing their own, or the app would end up
/// with two independent pieces of edit state for what the user experiences
/// as one photo.
@MainActor
public final class PadEditorModel: ObservableObject {
    public let editor = EditorSession()

    /// The currently open document, or `nil` before anything has been
    /// opened / after it has been closed. Drives which screen `PadRootView`
    /// shows; it is never set until `EditorSession.open` has actually
    /// succeeded, so the canvas is never shown for a document whose editor
    /// state isn't ready yet.
    @Published public private(set) var document: PhotoDocument?

    /// True while a just-selected file is being fingerprinted or copied,
    /// before `editor.open` is called — distinct from `editor.isRendering`,
    /// which only covers preview decoding of an already-open document.
    @Published public private(set) var isPreparingDocument = false

    /// A file has been picked and is waiting for the user to choose
    /// in-place vs. copy. The security scope backing the pick lives in
    /// `pendingSelection`, not here — this is just what the view needs to
    /// decide whether to show the confirmation dialog.
    @Published public private(set) var hasPendingSelection = false

    /// Open/copy failures, and anything the launch-time reconciliation pass
    /// couldn't clean up. Kept separate from `editor.alert`, which is
    /// `EditorSession`'s own — a failure to *open* a document happens before
    /// there is an editor session to report it, and a failure *within* an
    /// open document (a render or save failure) is `EditorSession`'s to own.
    @Published public var alert: EditorAlert?

    private let store: PhotoDocumentStore
    private let decoder: any RawDecoding

    /// The scope + URL for a file the user just picked, held from the
    /// moment `fileImporter` hands it over until the confirmation dialog's
    /// choice (or cancellation) resolves it. Files-importer access is only
    /// guaranteed for the duration of that completion handler, so the scope
    /// must be taken there — it cannot wait for the user's later tap.
    private var pendingSelection: (url: URL, scope: ScopedFolderAccess)?

    /// The scope backing the currently open in-place document. `nil` for an
    /// app-copy document, which needs no external access once its verified
    /// copy has been committed to App storage.
    private var documentScope: ScopedFolderAccess?

    private var reconciliationTask: Task<Void, Never>?

    public init(applicationSupportURL: URL) {
        let storeRootURL = applicationSupportURL.appendingPathComponent("PhotoDocuments", isDirectory: true)
        let decoder = CoreImageRawDecoder()
        let pipeline = AdjustmentPipeline()
        let renderService = ImageRenderService()
        let renderer = CoreImagePreviewRenderer(decoder: decoder, pipeline: pipeline, renderService: renderService)
        let store = PhotoDocumentStore(rootURL: storeRootURL)

        self.store = store
        self.decoder = decoder

        editor.attach(dependencies: EditorDependencies(
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            loadAdjustments: { photo in
                try await store.loadAdjustments(documentID: photo.id.rawValue)
            },
            saveAdjustments: { adjustments, photo in
                try await store.saveAdjustments(adjustments, documentID: photo.id.rawValue)
            }
        ))
    }

    deinit {
        reconciliationTask?.cancel()
    }

    // MARK: - Startup reconciliation

    /// Reclaims storage left behind by an import the app was killed in the
    /// middle of. Safe to call once per launch; the scan itself runs on
    /// `PhotoDocumentStore`'s own actor, so this never blocks the main
    /// actor. `.importInProgress` means another store instance (or process)
    /// is already importing or reconciling, which is an expected, harmless
    /// outcome here, not a failure to report.
    public func reconcileOrphanedImportsOnLaunch() {
        guard reconciliationTask == nil else { return }
        // `Task {}` here inherits `@MainActor` from this method, exactly
        // like `EditorSession.startObservingPreviews` — the body only
        // touches `@Published` state after the `await` on the store's own
        // actor has already taken the actual file-system scan off this one.
        reconciliationTask = Task { [store] in
            do {
                let report = try await store.reconcileOrphanedImports()
                guard !report.failures.isEmpty else { return }
                self.alert = EditorAlert(
                    title: L10n.t("Couldn't open this photo"),
                    message: L10n.t("LumaHarbor couldn't finish cleaning up an earlier interrupted import."),
                    nextStep: nil
                )
            } catch PhotoDocumentError.importInProgress {
                // Another import or reconciliation pass already holds the
                // lock; it will reconcile on its own next launch if needed.
            } catch {
                self.alert = EditorAlert(
                    title: L10n.t("Couldn't open this photo"),
                    message: L10n.t("LumaHarbor couldn't check for interrupted imports on launch."),
                    nextStep: nil
                )
            }
        }
    }

    // MARK: - Selecting a file

    /// Called right after `fileImporter` hands back a URL. Takes the
    /// security scope immediately — the system only guarantees access for
    /// the duration of that completion handler, so acquiring it here is not
    /// optional, even though the user's in-place/copy choice comes later.
    public func beginSelecting(_ url: URL) {
        cancelPendingSelection()
        let scope = ScopedFolderAccess(url: url, startAccessing: true)
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

    /// The user tapped a mode button for the pending selection.
    ///
    /// Claims and clears `pendingSelection` synchronously, before this
    /// method returns — `confirmationDialog`'s own dismissal bookkeeping
    /// runs right after the button's action closure returns, and calls back
    /// into `cancelPendingSelection()` (see the dialog's `isPresented`
    /// binding in `PadRootView`). If the claim happened only after an
    /// `await`, that dismissal callback could run first, stop the scope and
    /// clear `pendingSelection` out from under the in-flight open. Doing the
    /// claim here — synchronously, inside the same action closure — means
    /// there is nothing left for that callback to race.
    public func beginOpeningPendingSelection(mode: PadOpenMode) {
        guard let selection = pendingSelection else { return }
        pendingSelection = nil
        hasPendingSelection = false
        Task { await open(url: selection.url, scope: selection.scope, mode: mode) }
    }

    // MARK: - Opening

    private func open(url: URL, scope: ScopedFolderAccess, mode: PadOpenMode) async {
        guard await closeCurrentDocument() else {
            // The document that was open still has edits it couldn't save;
            // EditorSession has already surfaced that failure. Abandoning it
            // for a new selection would silently lose those edits, so the
            // new pick is dropped instead — only its own, just-acquired
            // scope needs stopping.
            scope.stop()
            return
        }

        isPreparingDocument = true
        defer { isPreparingDocument = false }

        do {
            // Best-effort: a document can still be opened without a
            // reusable bookmark, it just can't be relinked after this
            // session ends. Not fatal to the open itself.
            let bookmarkData = try? SecurityScopedBookmark.makeBookmarkData(for: url)

            let document: PhotoDocument
            switch mode {
            case .inPlace:
                document = try await store.openInPlace(url, bookmarkData: bookmarkData)
                // Kept open for as long as the document is: every preview
                // decode and the final export all read `workingURL`, which
                // *is* `url` in this mode.
                documentScope = scope
            case .appCopy:
                document = try await store.importCopy(of: url, bookmarkData: bookmarkData)
                // The verified copy is committed to App storage; the
                // external source is no longer read from, so its scope is
                // released right away rather than held for the rest of the
                // editing session.
                scope.stop()
                documentScope = nil
            }

            try await openEditor(for: document)
            self.document = document
        } catch {
            scope.stop()
            documentScope = nil
            self.document = nil
            alert = openFailureAlert(for: error)
        }
    }

    private func openEditor(for document: PhotoDocument) async throws {
        // RAW metadata decoding is synchronous, non-actor-isolated work —
        // `runOffActor` (the same seam `CoreImagePreviewRenderer` uses) is
        // what keeps it off the main actor.
        let decoder = self.decoder
        let workingURL = document.workingURL
        let metadata = try await runOffActor(priority: .userInitiated) {
            try decoder.readMetadata(at: workingURL)
        }
        let adjustments = try await store.loadAdjustments(documentID: document.id)
        let photo = PhotoAsset(
            id: PhotoID(document.id),
            libraryID: LibraryID(),
            relativePath: document.workingURL.lastPathComponent,
            fingerprint: document.workingFingerprint,
            metadata: metadata,
            status: .ready
        )
        // `sourceURL` is always the working copy — the source LumaHarbor
        // actually decodes and previews from — never the external RAW in
        // app-copy mode. That keeps every preview, save and export reading
        // from the file this document's identity and fingerprint describe.
        editor.open(photo: photo, sourceURL: document.workingURL, adjustments: adjustments, isReadOnly: false)
    }

    // MARK: - Closing

    /// Flushes pending edits and tears the editor down. Returns `false` —
    /// leaving the document, editor and scope untouched — when something
    /// unsaved could not be written; `EditorSession.flushPendingEdits()` has
    /// already surfaced that failure through `editor.alert`. Callers must
    /// not proceed with switching or closing when this returns `false`.
    @discardableResult
    public func closeCurrentDocument() async -> Bool {
        guard document != nil else { return true }
        guard await editor.flushPendingEdits() else { return false }
        editor.close()
        document = nil
        documentScope?.stop()
        documentScope = nil
        return true
    }

    // MARK: - Errors

    /// Never forwards an underlying error's own message: several of the
    /// errors this can see (`RawDecodingError.fileUnavailable`, arbitrary
    /// `NSError`s from `FileManager`) carry the file's absolute path in
    /// their `localizedDescription`, which must not reach the UI. Every
    /// branch here is a fixed, safe, localized string instead.
    private func openFailureAlert(for error: Error) -> EditorAlert {
        let title = L10n.t("Couldn't open this photo")
        switch error {
        case PhotoDocumentError.copyVerificationFailed:
            return EditorAlert(
                title: title,
                message: L10n.t("The copy didn't match the original file, so nothing was saved."),
                nextStep: L10n.t("Try copying this photo again.")
            )
        case PhotoDocumentError.sourceModifiedDuringImport:
            return EditorAlert(
                title: title,
                message: L10n.t("The original file changed while LumaHarbor was copying it, so nothing was saved."),
                nextStep: L10n.t("Make sure the file isn't being modified, then try again.")
            )
        case PhotoDocumentError.importInProgress:
            return EditorAlert(
                title: title,
                message: L10n.t("LumaHarbor is already importing or cleaning up another photo."),
                nextStep: L10n.t("Wait a moment, then try again.")
            )
        case PhotoDocumentError.documentNotFound:
            return EditorAlert(
                title: title,
                message: L10n.t("LumaHarbor couldn't find this photo's saved document."),
                nextStep: L10n.t("Choose the file again from Files.")
            )
        default:
            return EditorAlert(
                title: title,
                message: L10n.t("LumaHarbor couldn't open this photo."),
                nextStep: L10n.t("Choose the file again from Files.")
            )
        }
    }
}
