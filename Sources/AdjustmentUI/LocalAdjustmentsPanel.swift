import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// Linear gradients (design spec §6.6, roadmap Phase 4 Task 4.3 -- first
/// Mac UI). "Add Gradient" appends a new centered `LocalAdjustment` and
/// enters `.linearGradient` tool mode, which arms `LinearGradientOverlayView`
/// on the photo itself for dragging its position/angle/range -- the same
/// "list row here, canvas gesture there" split `GeometryAdjustmentPanel`
/// already established for crop. Every list row's own controls (exposure,
/// delete) write straight through `EditorSession.updateAdjustments(_:)`,
/// the same undo/autosave path every other adjustment uses.
///
/// Spot heal (Task 4.4/4.5) is deliberately out of scope here -- this panel
/// only ever lists/creates `.linearGradient` entries.
public struct LocalAdjustmentsPanel: View {
    @ObservedObject private var editor: EditorSession

    public init(editor: EditorSession) {
        self.editor = editor
    }

    private var gradients: [LocalAdjustment] {
        editor.adjustments.localAdjustments.filter { $0.kind == .linearGradient }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    let newGradient = LocalAdjustment(
                        kind: .linearGradient,
                        adjustments: LocalAdjustmentPatch(exposure: 0.5)
                    )
                    editor.updateAdjustments { $0.localAdjustments.append(newGradient) }
                    editor.selectedLocalAdjustmentID = newGradient.id
                    editor.setToolMode(.linearGradient)
                } label: {
                    Label(L10n.t("Add Gradient"), systemImage: "plus")
                }
                .disabled(editor.photo == nil)

                Spacer()

                Button {
                    editor.setToolMode(editor.toolMode == .linearGradient ? .adjust : .linearGradient)
                } label: {
                    Text(editor.toolMode == .linearGradient ? L10n.t("Done") : L10n.t("Edit Gradients"))
                }
                .disabled(editor.photo == nil || gradients.isEmpty)
            }

            if gradients.isEmpty {
                Text(L10n.t("No gradients yet."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(gradients) { gradient in
                    row(for: gradient)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("Local adjustments are non-destructive."))
                Text(L10n.t("Your RAW original was not changed."))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func row(for gradient: LocalAdjustment) -> some View {
        let isSelected = editor.selectedLocalAdjustmentID == gradient.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    editor.selectedLocalAdjustmentID = gradient.id
                    editor.setToolMode(.linearGradient)
                } label: {
                    Label(
                        gradient.isEnabled ? L10n.t("Gradient") : L10n.t("Gradient (Off)"),
                        systemImage: "rectangle.lefthalf.filled"
                    )
                    .fontWeight(isSelected ? .semibold : .regular)
                }
                .buttonStyle(.plain)

                Spacer()

                Toggle(L10n.t("Enabled"), isOn: Binding(
                    get: { gradient.isEnabled },
                    set: { newValue in
                        editor.updateAdjustments { adjustments in
                            if let index = adjustments.localAdjustments.firstIndex(where: { $0.id == gradient.id }) {
                                adjustments.localAdjustments[index].isEnabled = newValue
                            }
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

                Button(role: .destructive) {
                    editor.updateAdjustments { $0.localAdjustments = $0.localAdjustments.removing(gradient.id) }
                    if editor.selectedLocalAdjustmentID == gradient.id {
                        editor.selectedLocalAdjustmentID = nil
                    }
                } label: {
                    Label(L10n.t("Delete Gradient"), systemImage: "trash")
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
            }

            if isSelected {
                AdjustmentSliderRow(
                    label: L10n.t("Exposure"),
                    value: gradient.adjustments.exposure ?? 0,
                    range: -5...5,
                    fractionDigits: 2,
                    onChange: { newValue in
                        editor.updateAdjustments { adjustments in
                            guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == gradient.id }) else { return }
                            adjustments.localAdjustments[index].adjustments.exposure = newValue
                        }
                    },
                    onReset: {
                        editor.updateAdjustments { adjustments in
                            guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == gradient.id }) else { return }
                            adjustments.localAdjustments[index].adjustments.exposure = nil
                        }
                    }
                )
            }
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
