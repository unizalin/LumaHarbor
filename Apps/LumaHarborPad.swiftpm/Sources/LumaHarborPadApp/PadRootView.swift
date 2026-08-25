import EditorCore
import Localization
import SwiftUI
import UniformTypeIdentifiers

struct PadRootView: View {
    @ObservedObject var model: PadEditorModel
    @State private var isImporting = false

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
                        // pre-empted by the model's own generation check,
                        // so disabling this is a UX nicety, not a
                        // correctness requirement.
                        .disabled(model.isPreparingDocument)
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
                        model.beginSelecting(url)
                    case .failure(let error):
                        // A plain user cancellation must stay silent; any
                        // other provider failure needs a safe, actionable
                        // alert instead of being swallowed.
                        let nsError = error as NSError
                        guard nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError else {
                            model.reportFileImporterFailure(error)
                            return
                        }
                    }
                }
                .confirmationDialog(
                    L10n.t("How should LumaHarbor use this photo?"),
                    isPresented: Binding(
                        get: { model.hasPendingSelection },
                        set: { isPresented in
                            if !isPresented { model.cancelPendingSelection() }
                        }
                    ),
                    titleVisibility: .visible
                ) {
                    // In-place is listed first: it is the default source
                    // mode (spec §5.1).
                    Button(L10n.t("Edit in Place")) {
                        model.beginOpeningPendingSelection(mode: .inPlace)
                    }
                    Button(L10n.t("Copy to This iPad")) {
                        model.beginOpeningPendingSelection(mode: .appCopy)
                    }
                    Button(L10n.t("Cancel"), role: .cancel) {
                        model.cancelPendingSelection()
                    }
                } message: {
                    Text(L10n.t("The RAW original is never modified."))
                }
                .alert(item: $model.alert) { alert in
                    Alert(
                        title: Text(alert.title),
                        message: Text(alertBody(alert)),
                        dismissButton: .default(Text(L10n.t("OK")))
                    )
                }
        }
        .task {
            model.performStartupSequence()
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.document != nil {
            PadEditorView(model: model)
        } else if model.isPreparingDocument {
            ProgressView(L10n.t("Opening photo…"))
        } else {
            ContentUnavailableView(
                L10n.t("Open a RAW photo"),
                systemImage: "photo.badge.plus",
                description: Text(L10n.t("Choose a photo from Files or an external drive."))
            )
        }
    }

    private func alertBody(_ alert: EditorAlert) -> String {
        [alert.message, alert.nextStep].compactMap { $0 }.joined(separator: "\n\n")
    }
}
