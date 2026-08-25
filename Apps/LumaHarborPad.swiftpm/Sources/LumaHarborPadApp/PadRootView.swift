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
                    }
                }
                .fileImporter(
                    isPresented: $isImporting,
                    allowedContentTypes: [.image, .data],
                    allowsMultipleSelection: false
                ) { result in
                    guard let url = try? result.get().first else { return }
                    model.beginSelecting(url)
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
            model.reconcileOrphanedImportsOnLaunch()
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
