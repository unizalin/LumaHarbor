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

    private var masks: [LocalAdjustment] {
        editor.adjustments.localAdjustments.filter { $0.kind != .spotHeal }
    }

    private var spotHeals: [LocalAdjustment] {
        editor.adjustments.localAdjustments.filter { $0.kind == .spotHeal }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Menu {
                    Button(L10n.t("Linear Gradient")) { addMask(kind: .linearGradient) }
                    Button(L10n.t("Radial Gradient")) { addMask(kind: .radialGradient) }
                    Button(L10n.t("Brush")) { addMask(kind: .brush) }
                    Button(L10n.t("Luminance Range")) { addMask(kind: .luminanceRange) }
                    Button(L10n.t("Color Range")) { addMask(kind: .colorRange) }
                    Button(L10n.t("Subject")) { addMask(kind: .subject) }
                    Button(L10n.t("Background")) { addMask(kind: .background) }
                } label: {
                    Label(L10n.t("Add Mask"), systemImage: "plus")
                }
                .disabled(editor.photo == nil)

                Spacer()

                Button {
                    editor.setToolMode(editor.toolMode == .linearGradient ? .adjust : .linearGradient)
                } label: {
                    Text(editor.toolMode == .linearGradient ? L10n.t("Done") : L10n.t("Edit Masks"))
                }
                .disabled(editor.photo == nil || masks.isEmpty)
            }

            if masks.isEmpty {
                Text(L10n.t("No masks yet."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(masks) { mask in
                    maskRow(for: mask)
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

    private func addMask(kind: LocalAdjustmentKind) {
        let defaultPatch: LocalAdjustmentPatch
        switch kind {
        case .linearGradient, .radialGradient, .brush:
            defaultPatch = LocalAdjustmentPatch(exposure: 0.5)
        case .luminanceRange, .colorRange, .subject, .background:
            defaultPatch = LocalAdjustmentPatch(exposure: 0.3, contrast: 5)
        case .spotHeal:
            defaultPatch = LocalAdjustmentPatch()
        }

        let newMask = LocalAdjustment(
            kind: kind,
            adjustments: defaultPatch
        )
        editor.updateAdjustments { $0.localAdjustments.append(newMask) }
        editor.selectedLocalAdjustmentID = newMask.id
        if kind == .linearGradient {
            editor.setToolMode(.linearGradient)
        }
    }

    private func maskRow(for mask: LocalAdjustment) -> some View {
        let isSelected = editor.selectedLocalAdjustmentID == mask.id
        let title: String = {
            if !mask.name.isEmpty { return mask.name }
            switch mask.kind {
            case .linearGradient: return L10n.t("Linear Gradient")
            case .radialGradient: return L10n.t("Radial Gradient")
            case .brush: return L10n.t("Brush")
            case .luminanceRange: return L10n.t("Luminance Range")
            case .colorRange: return L10n.t("Color Range")
            case .subject: return L10n.t("Subject")
            case .background: return L10n.t("Background")
            case .spotHeal: return L10n.t("Spot Heal")
            }
        }()

        let symbol: String = {
            switch mask.kind {
            case .linearGradient: return "rectangle.lefthalf.filled"
            case .radialGradient: return "circle.circle"
            case .brush: return "paintbrush"
            case .luminanceRange: return "sun.max"
            case .colorRange: return "paintpalette"
            case .subject: return "person.crop.circle"
            case .background: return "photo"
            case .spotHeal: return "bandage"
            }
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    editor.selectedLocalAdjustmentID = mask.id
                    if mask.kind == .linearGradient {
                        editor.setToolMode(.linearGradient)
                    }
                } label: {
                    Label(
                        mask.isEnabled ? title : "\(title) (\(L10n.t("Off")))",
                        systemImage: symbol
                    )
                    .fontWeight(isSelected ? .semibold : .regular)
                }
                .buttonStyle(.plain)

                Spacer()

                Toggle(L10n.t("Enabled"), isOn: Binding(
                    get: { mask.isEnabled },
                    set: { newValue in
                        editor.updateAdjustments { adjustments in
                            if let index = adjustments.localAdjustments.firstIndex(where: { $0.id == mask.id }) {
                                adjustments.localAdjustments[index].isEnabled = newValue
                            }
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

                Button {
                    editor.updateAdjustments { $0.localAdjustments = $0.localAdjustments.duplicating(mask.id) }
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.t("Duplicate Mask")))

                Button(role: .destructive) {
                    editor.updateAdjustments { $0.localAdjustments = $0.localAdjustments.removing(mask.id) }
                    if editor.selectedLocalAdjustmentID == mask.id {
                        editor.selectedLocalAdjustmentID = nil
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.t("Delete Mask")))
            }

            if isSelected {
                VStack(spacing: 8) {
                    HStack {
                        Toggle(L10n.t("Invert Mask"), isOn: Binding(
                            get: { mask.isInverted },
                            set: { newValue in
                                editor.updateAdjustments { adjustments in
                                    guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == mask.id }) else { return }
                                    adjustments.localAdjustments[index].isInverted = newValue
                                }
                            }
                        ))
#if os(macOS)
                        .toggleStyle(.checkbox)
#endif

                        Spacer()
                    }

                    AdjustmentSliderRow(
                        label: L10n.t("Opacity"),
                        value: mask.opacity,
                        range: 0...100,
                        fractionDigits: 0,
                        onChange: { newValue in
                            editor.updateAdjustments { adjustments in
                                guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == mask.id }) else { return }
                                adjustments.localAdjustments[index].opacity = newValue
                            }
                        },
                        onReset: {
                            editor.updateAdjustments { adjustments in
                                guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == mask.id }) else { return }
                                adjustments.localAdjustments[index].opacity = 100
                            }
                        }
                    )

                    AdjustmentSliderRow(
                        label: L10n.t("Exposure"),
                        value: mask.adjustments.exposure ?? 0,
                        range: -5...5,
                        fractionDigits: 2,
                        onChange: { newValue in
                            editor.updateAdjustments { adjustments in
                                guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == mask.id }) else { return }
                                adjustments.localAdjustments[index].adjustments.exposure = newValue
                            }
                        },
                        onReset: {
                            editor.updateAdjustments { adjustments in
                                guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == mask.id }) else { return }
                                adjustments.localAdjustments[index].adjustments.exposure = nil
                            }
                        }
                    )

                    AdjustmentSliderRow(
                        label: L10n.t("Contrast"),
                        value: mask.adjustments.contrast ?? 0,
                        range: -100...100,
                        fractionDigits: 0,
                        onChange: { newValue in
                            editor.updateAdjustments { adjustments in
                                guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == mask.id }) else { return }
                                adjustments.localAdjustments[index].adjustments.contrast = newValue
                            }
                        },
                        onReset: {
                            editor.updateAdjustments { adjustments in
                                guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == mask.id }) else { return }
                                adjustments.localAdjustments[index].adjustments.contrast = nil
                            }
                        }
                    )

                    AdjustmentSliderRow(
                        label: L10n.t("Saturation"),
                        value: mask.adjustments.saturation ?? 0,
                        range: -100...100,
                        fractionDigits: 0,
                        onChange: { newValue in
                            editor.updateAdjustments { adjustments in
                                guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == mask.id }) else { return }
                                adjustments.localAdjustments[index].adjustments.saturation = newValue
                            }
                        },
                        onReset: {
                            editor.updateAdjustments { adjustments in
                                guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == mask.id }) else { return }
                                adjustments.localAdjustments[index].adjustments.saturation = nil
                            }
                        }
                    )
                }
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
                        heal.isEnabled ? (heal.geometry.healMode == .redEye ? L10n.t("Red-Eye") : L10n.t("Spot Heal")) : L10n.t("Spot Heal (Off)"),
                        systemImage: heal.geometry.healMode == .redEye ? "eye" : "bandage"
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
                    Text(L10n.t("Red-Eye")).tag(SpotHealMode.redEye)
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

                if heal.geometry.healMode == .redEye {
                    AdjustmentSliderRow(
                        label: L10n.t("Pupil Radius"),
                        value: heal.geometry.redEyePupilRadius ?? heal.geometry.radius,
                        range: 0.01...0.3,
                        fractionDigits: 2,
                        onChange: { newValue in
                            editor.updateAdjustments { adjustments in
                                guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == heal.id }) else { return }
                                adjustments.localAdjustments[index].geometry.redEyePupilRadius = newValue
                            }
                        },
                        onReset: {
                            editor.updateAdjustments { adjustments in
                                guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == heal.id }) else { return }
                                adjustments.localAdjustments[index].geometry.redEyePupilRadius = nil
                            }
                        }
                    )
                }
            }
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
