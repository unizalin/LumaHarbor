import AdjustmentUI
import EditorCore
import Localization
import SwiftUI

/// The minimal editing surface for Task 6: a fixed black canvas plus the ten
/// basic sliders in a trailing panel. The adaptive dock/drawer/floating
/// layout is Task 7's job — this view deliberately does not anticipate it.
struct PadEditorView: View {
    @ObservedObject var model: PadEditorModel
    @ObservedObject private var editor: EditorSession

    init(model: PadEditorModel) {
        self.model = model
        self.editor = model.editor
    }

    var body: some View {
        HStack(spacing: 0) {
            canvas
            Divider()
            controlPanel
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.t("Close")) {
                    Task { await model.closeCurrentDocument() }
                }
            }
        }
        .alert(item: $editor.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alertBody(alert)),
                dismissButton: .default(Text(L10n.t("OK")))
            )
        }
    }

    @ViewBuilder
    private var canvas: some View {
        ZStack {
            Color.black
            if let image = editor.displayedImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding()
            } else if editor.decodeFailed {
                ContentUnavailableView(
                    L10n.t("Couldn't show this photo"),
                    systemImage: "exclamationmark.triangle"
                )
            } else {
                ProgressView(L10n.t("Decoding RAW…"))
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                undoRedoControls
                Divider()
                BasicAdjustmentPanel(editor: editor)
            }
            .padding()
        }
        .frame(width: 320)
        .background(.thickMaterial)
    }

    private var undoRedoControls: some View {
        HStack {
            Button {
                editor.undo()
            } label: {
                Label(L10n.t("Undo"), systemImage: "arrow.uturn.backward")
            }
            .disabled(!editor.canUndo)

            Button {
                editor.redo()
            } label: {
                Label(L10n.t("Redo"), systemImage: "arrow.uturn.forward")
            }
            .disabled(!editor.canRedo)

            Spacer()
        }
    }

    private func alertBody(_ alert: EditorAlert) -> String {
        [alert.message, alert.nextStep].compactMap { $0 }.joined(separator: "\n\n")
    }
}
