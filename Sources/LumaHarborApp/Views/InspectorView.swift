import AdjustmentUI
import PhotoLibraryCore
import Localization
import SwiftUI

/// Right pane: the shared basic adjustments alongside Mac-only preset controls.
struct InspectorView: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.editor.photo == nil {
                ContentUnavailableMessage()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        PresetBrowserView()
                        Divider()
                        BasicAdjustmentPanel(editor: model.editor)
                    }
                    .padding(14)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text(L10n.t("Adjustments"))
                .font(.headline)
            Spacer()
            Button(L10n.t("Reset All")) {
                model.editor.resetAll()
            }
            .controlSize(.small)
            .disabled(model.editor.photo == nil || !model.editor.hasEdits)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct ContentUnavailableMessage: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L10n.t("Select a photo to start editing"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
