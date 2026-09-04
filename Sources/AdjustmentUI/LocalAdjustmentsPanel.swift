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
/// Spot heal (Task 4.5) is the second section below, mirroring this same
/// panel's own "add / list / select / delete, plus the selected entry's own
/// controls" structure.
public struct LocalAdjustmentsPanel: View {
    @ObservedObject private var editor: EditorSession

    public init(editor: EditorSession) {
        self.editor = editor
    }

    private var gradients: [LocalAdjustment] {
        editor.adjustments.localAdjustments.filter { $0.kind == .linearGradient }
    }

    private var spotHeals: [LocalAdjustment] {
        editor.adjustments.localAdjustments.filter { $0.kind == .spotHeal }
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

            Divider()

            HStack {
                Button {
                    let newHeal = LocalAdjustment(kind: .spotHeal)
                    editor.updateAdjustments { $0.localAdjustments.append(newHeal) }
                    editor.selectedLocalAdjustmentID = newHeal.id
                    editor.setToolMode(.spotHeal)
                } label: {
                    Label(L10n.t("Add Spot Heal"), systemImage: "bandage")
                }
                .disabled(editor.photo == nil)

                Spacer()

                Button {
                    editor.setToolMode(editor.toolMode == .spotHeal ? .adjust : .spotHeal)
                } label: {
                    Text(editor.toolMode == .spotHeal ? L10n.t("Done") : L10n.t("Edit Spot Heals"))
                }
                .disabled(editor.photo == nil || spotHeals.isEmpty)
            }

            if spotHeals.isEmpty {
                Text(L10n.t("No spot heals yet."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(spotHeals) { heal in
                    spotHealRow(for: heal)
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

    private func spotHealRow(for heal: LocalAdjustment) -> some View {
        let isSelected = editor.selectedLocalAdjustmentID == heal.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    editor.selectedLocalAdjustmentID = heal.id
                    editor.setToolMode(.spotHeal)
                } label: {
                    Label(
                        heal.isEnabled ? L10n.t("Spot Heal") : L10n.t("Spot Heal (Off)"),
                        systemImage: "bandage"
                    )
                    .fontWeight(isSelected ? .semibold : .regular)
                }
                .buttonStyle(.plain)

                Spacer()

                Toggle(L10n.t("Enabled"), isOn: Binding(
                    get: { heal.isEnabled },
                    set: { newValue in
                        editor.updateAdjustments { adjustments in
                            if let index = adjustments.localAdjustments.firstIndex(where: { $0.id == heal.id }) {
                                adjustments.localAdjustments[index].isEnabled = newValue
                            }
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

                Button(role: .destructive) {
                    editor.updateAdjustments { $0.localAdjustments = $0.localAdjustments.removing(heal.id) }
                    if editor.selectedLocalAdjustmentID == heal.id {
                        editor.selectedLocalAdjustmentID = nil
                    }
                } label: {
                    Label(L10n.t("Delete Spot Heal"), systemImage: "trash")
                }
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
            }

            if isSelected {
                Picker(L10n.t("Mode"), selection: Binding(
                    get: { heal.geometry.healMode },
                    set: { newValue in
                        editor.updateAdjustments { adjustments in
                            guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == heal.id }) else { return }
                            adjustments.localAdjustments[index].geometry.healMode = newValue
                        }
                    }
                )) {
                    Text(L10n.t("Heal")).tag(SpotHealMode.heal)
                    Text(L10n.t("Clone")).tag(SpotHealMode.clone)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // Roadmap Task 4.5: "record quality limitations honestly" --
                // heal mode is a fixed, deterministic auto-sample (see
                // `LocalAdjustmentRenderer.autoSourcePoint`'s own doc
                // comment), not content-aware fill. Shown only for heal
                // mode -- clone with an explicit source point is the
                // reliable path this caption points the user toward.
                if heal.geometry.healMode == .heal {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("Heal samples nearby texture automatically."))
                        Text(L10n.t("For reliable results on busy backgrounds, use Clone instead."))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                AdjustmentSliderRow(
                    label: L10n.t("Radius"),
                    value: heal.geometry.radius,
                    range: 0.01...0.3,
                    fractionDigits: 2,
                    onChange: { newValue in
                        editor.updateAdjustments { adjustments in
                            guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == heal.id }) else { return }
                            adjustments.localAdjustments[index].geometry.radius = newValue
                        }
                    },
                    onReset: {
                        editor.updateAdjustments { adjustments in
                            guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == heal.id }) else { return }
                            adjustments.localAdjustments[index].geometry.radius = LocalAdjustmentGeometry.neutral.radius
                        }
                    }
                )

                AdjustmentSliderRow(
                    label: L10n.t("Feather"),
                    value: heal.geometry.feather,
                    range: LocalAdjustmentGeometry.featherRange,
                    fractionDigits: 0,
                    onChange: { newValue in
                        editor.updateAdjustments { adjustments in
                            guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == heal.id }) else { return }
                            adjustments.localAdjustments[index].geometry.feather = newValue
                        }
                    },
                    onReset: {
                        editor.updateAdjustments { adjustments in
                            guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == heal.id }) else { return }
                            adjustments.localAdjustments[index].geometry.feather = LocalAdjustmentGeometry.neutral.feather
                        }
                    }
                )
            }
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
