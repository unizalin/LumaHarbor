import PhotoLibraryCore
import Localization
import RawProcessingCore
import SwiftUI

/// Right pane: the ten MVP adjustments, grouped and driven entirely by
/// `AdjustmentCatalog` so no range or default is ever written in a view.
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
                        ForEach(AdjustmentGroup.allCases, id: \.self) { group in
                            AdjustmentSection(group: group)
                        }
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

private struct AdjustmentSection: View {
    @EnvironmentObject private var model: LibraryViewModel
    let group: AdjustmentGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: group.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(AdjustmentCatalog.definitions(in: group), id: \.kind) { definition in
                AdjustmentSliderRow(definition: definition)
            }
        }
    }
}

/// One slider. Reads and writes through the editor so every change goes through
/// the undo history rather than mutating state behind its back.
private struct AdjustmentSliderRow: View {
    @EnvironmentObject private var model: LibraryViewModel
    let definition: AdjustmentDefinition

    private var value: Double {
        model.editor.adjustments[definition.kind]
    }

    private var isModified: Bool {
        value != definition.defaultValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: definition.kind.displayName)
                    .font(.callout)
                Spacer()
                Text(formatted)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(isModified ? .primary : .secondary)
            }

            Slider(
                value: Binding(
                    get: { value },
                    set: { model.editor.setAdjustment(definition.kind, to: $0) }
                ),
                in: definition.range
            )
            .controlSize(.small)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Double-click to reset, the standard photo-editor gesture.
            model.editor.resetAdjustment(definition.kind)
        }
        .contextMenu {
            Button("\(L10n.t("Reset")) \(definition.kind.displayName)") {
                model.editor.resetAdjustment(definition.kind)
            }
            .disabled(!isModified)
        }
        .help(L10n.t("Double-click the row to reset"))
    }

    private var formatted: String {
        let text = String(format: "%.\(definition.fractionDigits)f", value)
        return value > 0 ? "+\(text)" : text
    }
}
