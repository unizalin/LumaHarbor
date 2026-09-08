import AdjustmentUI
import EditorCore
import Localization
import SwiftUI
import UniformTypeIdentifiers

struct PadRootView: View {
    let services: PadAppServices
    @ObservedObject var editor: PadEditorModel
    @ObservedObject var library: PadLibraryModel
    @State private var isImporting = false
    @State private var isRelinking = false
    @State private var isShowingSettings = false

    /// Scene-scoped presentation preferences (sidebar visibility, inspector
    /// tab, filmstrip, handedness) -- never an adjustment, undo entry, or
    /// sidecar write. Held here, at the top of the scene, rather than inside
    /// `PadLibraryView`/`PadEditorView` themselves, so it survives the route
    /// switch between library and editor: `content` below recreates whichever
    /// of those two views isn't currently showing every time the route
    /// changes, which would otherwise reset any `@State` scoped to the
    /// discarded view.
    @State private var workspaceState = PadWorkspaceState.initial

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("LumaHarbor")
                .toolbar {
                    ToolbarItem {
                        Button(L10n.t("Open RAW…")) {
                            isImporting = true
                        }
                        // A selection or restore already in flight owns
                        // `document`/`editor` until it settles; starting a
                        // second one here would just be immediately
                        // pre-empted by the editor's own generation check,
                        // so disabling this is a UX nicety, not a
                        // correctness requirement.
                        .disabled(editor.isPreparingDocument)
                    }
                    ToolbarItem {
                        Button {
                            isShowingSettings = true
                        } label: {
                            Label(L10n.t("Settings"), systemImage: "gearshape")
                        }
                        .frame(minWidth: 44, minHeight: 44)
                    }
                }
                .sheet(isPresented: $isShowingSettings) {
                    NavigationStack {
                        PadLibrarySettingsView(services: services, userDefaults: services.userDefaults)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button(L10n.t("Close")) {
                                        isShowingSettings = false
                                    }
                                }
                            }
                    }
                }
                .fileImporter(
                    isPresented: $isImporting,
                    allowedContentTypes: [.image, .data],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        editor.beginSelecting(url)
                    case .failure(let error):
                        // A plain user cancellation must stay silent; any
                        // other provider failure needs a safe, actionable
                        // alert instead of being swallowed.
                        let nsError = error as NSError
                        guard nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError else {
                            editor.reportFileImporterFailure(error)
                            return
                        }
                    }
                }
                .confirmationDialog(
                    L10n.t("How should LumaHarbor use this photo?"),
                    isPresented: Binding(
                        get: { editor.hasPendingSelection },
                        set: { isPresented in
                            if !isPresented { editor.cancelPendingSelection() }
                        }
                    ),
                    titleVisibility: .visible
                ) {
                    // In-place is listed first: it is the default source
                    // mode (spec §5.1).
                    Button(L10n.t("Edit in Place")) {
                        editor.beginOpeningPendingSelection(mode: .inPlace)
                    }
                    Button(L10n.t("Copy to This iPad")) {
                        editor.beginOpeningPendingSelection(mode: .appCopy)
                    }
                    Button(L10n.t("Cancel"), role: .cancel) {
                        editor.cancelPendingSelection()
                    }
                } message: {
                    Text(L10n.t("The RAW original is never modified."))
                }
                .alert(item: $editor.alert) { alert in
                    Alert(
                        title: Text(alert.title),
                        message: Text(alertBody(alert)),
                        dismissButton: .default(Text(L10n.t("OK")))
                    )
                }
                // Separate from the normal `fileImporter` above: picking a
                // file here goes through `beginRelinkSelection`, which
                // verifies it against the existing document's fingerprint
                // before touching anything, rather than starting a brand
                // new document under a new ID.
                .fileImporter(
                    isPresented: $isRelinking,
                    allowedContentTypes: [.image, .data],
                    allowsMultipleSelection: false
                ) { result in
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        editor.beginRelinkSelection(url)
                    case .failure(let error):
                        // Same distinction as the main fileImporter above:
                        // a plain cancellation stays silent, but any other
                        // provider failure needs a safe alert rather than
                        // being swallowed by `try?`.
                        let nsError = error as NSError
                        guard nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError else {
                            editor.reportFileImporterFailure(error)
                            return
                        }
                    }
                }
        }
        .task {
            editor.performStartupSequence()
            await services.refreshAppStorageProjection()
        }
        .onChange(of: editor.document?.id) { _, _ in
            Task { await services.refreshAppStorageProjection() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if editor.document != nil {
            PadEditorView(model: editor, exporter: services.exporter)
        } else if editor.pendingRelink != nil {
            // No "Cancel" here, deliberately: this prompt is the only way
            // back to this specific document, and dismissing the file
            // picker it opens (handled below) already leaves it exactly as
            // it was, ready to try again. Opening a different photo from
            // the toolbar above works too, and is what supersedes this
            // prompt if the user doesn't want to deal with it right now.
            ContentUnavailableView {
                Label(L10n.t("Couldn't reopen your last photo"), systemImage: "questionmark.folder")
            } description: {
                Text(L10n.t("LumaHarbor no longer has access to this file."))
            } actions: {
                Button(L10n.t("Choose the file again from Files.")) {
                    isRelinking = true
                }
            }
        } else if editor.isPreparingDocument {
            ProgressView(L10n.t("Opening photo…"))
        } else {
            PadLibraryView(library: library, editor: editor, services: services, workspaceState: $workspaceState)
        }
    }

    private func alertBody(_ alert: EditorAlert) -> String {
        [alert.message, alert.nextStep].compactMap { $0 }.joined(separator: "\n\n")
    }
}
