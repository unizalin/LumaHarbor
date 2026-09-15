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

    private var selectedMaskToolMode: EditorToolMode? {
        guard let selectedID = editor.selectedLocalAdjustmentID,
              let selectedMask = masks.first(where: { $0.id == selectedID }) else {
            return nil
        }
        switch selectedMask.kind {
        case .linearGradient: return .linearGradient
        case .radialGradient: return .radialGradient
        case .brush: return .brush
        case .luminanceRange, .colorRange, .subject, .background, .spotHeal: return nil
        }
    }

    // Kept as a named predicate for the linear-gradient affordance and for
    // source-level UI contracts; radial and brush masks use the same button
    // through `selectedMaskToolMode` below.
    private var selectedMaskIsLinear: Bool {
        selectedMaskToolMode == .linearGradient
    }

    private var isLinearGradientToolActive: Bool {
        editor.toolMode == .linearGradient
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            maskToolbar

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

            spotHealToolbar

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

    private var maskToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                addMaskButton
                Spacer(minLength: 8)
                editMasksButton
            }

            VStack(alignment: .leading, spacing: 8) {
                addMaskButton
                editMasksButton
            }
        }
    }

    private var addMaskButton: some View {
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
        .frame(minHeight: 44)
    }

    private var editMasksButton: some View {
        Button {
            if let selectedMaskToolMode,
               editor.toolMode == selectedMaskToolMode {
                editor.setToolMode(.adjust)
            } else if let selectedMaskToolMode {
                editor.setToolMode(selectedMaskToolMode)
            }
        } label: {
            Text(editor.toolMode == selectedMaskToolMode ? L10n.t("Done") : L10n.t("Edit Masks"))
        }
        .disabled(
            editor.photo == nil
                || masks.isEmpty
                || (!selectedMaskIsLinear && selectedMaskToolMode == nil)
        )
        .frame(minHeight: 44)
    }

    private var spotHealToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                addSpotHealButton
                Spacer(minLength: 8)
                editSpotHealsButton
            }

            VStack(alignment: .leading, spacing: 8) {
                addSpotHealButton
                editSpotHealsButton
            }
        }
    }

    private var addSpotHealButton: some View {
        Button {
            let newHeal = LocalAdjustment(kind: .spotHeal)
            editor.updateAdjustments { $0.localAdjustments.append(newHeal) }
            editor.selectedLocalAdjustmentID = newHeal.id
            editor.setToolMode(.spotHeal)
        } label: {
            Label(L10n.t("Add Spot Heal"), systemImage: "bandage")
        }
        .disabled(editor.photo == nil)
        .frame(minHeight: 44)
    }

    private var editSpotHealsButton: some View {
        Button {
            editor.setToolMode(editor.toolMode == .spotHeal ? .adjust : .spotHeal)
        } label: {
            Text(editor.toolMode == .spotHeal ? L10n.t("Done") : L10n.t("Edit Spot Heals"))
        }
        .disabled(editor.photo == nil || spotHeals.isEmpty)
        .frame(minHeight: 44)
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
        if let mode = canvasToolMode(for: kind) {
            editor.setToolMode(mode)
        } else if canvasToolMode(for: editor.toolMode) != nil {
            editor.setToolMode(.adjust)
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
            ViewThatFits(in: .horizontal) {
                HStack {
                    maskSelectionButton(mask, title: title, symbol: symbol, isSelected: isSelected)
                    Spacer(minLength: 8)
                    maskActions(mask)
                }

                VStack(alignment: .leading, spacing: 6) {
                    maskSelectionButton(mask, title: title, symbol: symbol, isSelected: isSelected)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Spacer(minLength: 0)
                        maskActions(mask)
                    }
                }
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

                    maskGeometryControls(for: mask)

                    AdjustmentSliderRow(
                        label: L10n.t("Opacity"),
                        value: mask.opacity,
                        range: 0...100,
                        fractionDigits: 1,
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
                        },
                        onPreview: { newValue in
                            previewLocalAdjustment(mask.id) { $0.opacity = newValue }
                        },
                        onCommitPreview: { editor.commitContinuousEdit() }
                    )

                    AdjustmentSliderRow(
                        label: L10n.t("Exposure"),
                        value: mask.adjustments.exposure ?? 0,
                        range: -5...5,
                        fractionDigits: 1,
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
                        },
                        onPreview: { newValue in
                            previewLocalAdjustment(mask.id) { $0.adjustments.exposure = newValue }
                        },
                        onCommitPreview: { editor.commitContinuousEdit() }
                    )

                    AdjustmentSliderRow(
                        label: L10n.t("Contrast"),
                        value: mask.adjustments.contrast ?? 0,
                        range: -100...100,
                        fractionDigits: 1,
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
                        },
                        onPreview: { newValue in
                            previewLocalAdjustment(mask.id) { $0.adjustments.contrast = newValue }
                        },
                        onCommitPreview: { editor.commitContinuousEdit() }
                    )

                    AdjustmentSliderRow(
                        label: L10n.t("Saturation"),
                        value: mask.adjustments.saturation ?? 0,
                        range: -100...100,
                        fractionDigits: 1,
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
                        },
                        onPreview: { newValue in
                            previewLocalAdjustment(mask.id) { $0.adjustments.saturation = newValue }
                        },
                        onCommitPreview: { editor.commitContinuousEdit() }
                    )
                }
            }
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func maskSelectionButton(
        _ mask: LocalAdjustment,
        title: String,
        symbol: String,
        isSelected: Bool
    ) -> some View {
        Button {
            editor.selectedLocalAdjustmentID = mask.id
            if mask.kind == .linearGradient {
                editor.setToolMode(.linearGradient)
            } else if let mode = canvasToolMode(for: mask.kind) {
                editor.setToolMode(mode)
            } else if canvasToolMode(for: editor.toolMode) != nil {
                editor.setToolMode(.adjust)
            }
        } label: {
            Label(
                mask.isEnabled ? title : "\(title) (\(L10n.t("Off")))",
                systemImage: symbol
            )
            .fontWeight(isSelected ? .semibold : .regular)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44, alignment: .leading)
        // Keep the complete wrapped mask label row tappable in narrow iPad
        // drawers, not only the glyphs and text bounds.
        .contentShape(Rectangle())
    }

    private func maskActions(_ mask: LocalAdjustment) -> some View {
        HStack(spacing: 4) {
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
            .frame(minWidth: 44, minHeight: 44)

            Button {
                editor.updateAdjustments { $0.localAdjustments = $0.localAdjustments.duplicating(mask.id) }
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text(L10n.t("Duplicate Mask")))

            Button(role: .destructive) {
                editor.updateAdjustments { $0.localAdjustments = $0.localAdjustments.removing(mask.id) }
                if editor.selectedLocalAdjustmentID == mask.id {
                    editor.selectedLocalAdjustmentID = nil
                    if canvasToolMode(for: editor.toolMode) != nil {
                        editor.setToolMode(.adjust)
                    }
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text(L10n.t("Delete Mask")))
        }
    }

    @ViewBuilder
    private func maskGeometryControls(for mask: LocalAdjustment) -> some View {
        switch mask.kind {
        case .linearGradient:
            maskPositionControls(for: mask)

            AdjustmentSliderRow(
                label: L10n.t("Angle"),
                value: mask.geometry.angleDegrees,
                range: -180...180,
                fractionDigits: 1,
                onChange: { newValue in
                    updateMaskGeometry(mask.id) { $0.angleDegrees = newValue }
                },
                onReset: {
                    updateMaskGeometry(mask.id) { $0.angleDegrees = LocalAdjustmentGeometry.neutral.angleDegrees }
                },
                onPreview: { newValue in
                    previewMaskGeometry(mask.id) { $0.angleDegrees = newValue }
                },
                onCommitPreview: { editor.commitContinuousEdit() }
            )

            AdjustmentSliderRow(
                label: L10n.t("Range"),
                value: mask.geometry.range,
                range: 0.01...1,
                fractionDigits: 1,
                onChange: { newValue in
                    updateMaskGeometry(mask.id) { $0.range = newValue }
                },
                onReset: {
                    updateMaskGeometry(mask.id) { $0.range = LocalAdjustmentGeometry.neutral.range }
                },
                onPreview: { newValue in
                    previewMaskGeometry(mask.id) { $0.range = newValue }
                },
                onCommitPreview: { editor.commitContinuousEdit() }
            )

            featherControl(for: mask)

        case .radialGradient:
            maskPositionControls(for: mask)

            AdjustmentSliderRow(
                label: L10n.t("Radius"),
                value: mask.geometry.radius,
                range: 0.01...1,
                fractionDigits: 1,
                onChange: { newValue in
                    updateMaskGeometry(mask.id) { $0.radius = newValue }
                },
                onReset: {
                    updateMaskGeometry(mask.id) { $0.radius = LocalAdjustmentGeometry.neutral.radius }
                },
                onPreview: { newValue in
                    previewMaskGeometry(mask.id) { $0.radius = newValue }
                },
                onCommitPreview: { editor.commitContinuousEdit() }
            )

            AdjustmentSliderRow(
                label: L10n.t("Vertical Radius"),
                value: mask.geometry.radialRadiusY ?? mask.geometry.radius,
                range: 0.01...1,
                fractionDigits: 1,
                onChange: { newValue in
                    updateMaskGeometry(mask.id) { $0.radialRadiusY = newValue }
                },
                onReset: {
                    updateMaskGeometry(mask.id) { $0.radialRadiusY = nil }
                },
                onPreview: { newValue in
                    previewMaskGeometry(mask.id) { $0.radialRadiusY = newValue }
                },
                onCommitPreview: { editor.commitContinuousEdit() }
            )

            featherControl(for: mask)

        case .brush:
            maskPositionControls(for: mask)
            AdjustmentSliderRow(
                label: L10n.t("Size"),
                value: mask.geometry.radius,
                range: 0.01...1,
                fractionDigits: 1,
                onChange: { newValue in
                    updateMaskGeometry(mask.id) { $0.radius = newValue }
                },
                onReset: {
                    updateMaskGeometry(mask.id) { $0.radius = LocalAdjustmentGeometry.neutral.radius }
                },
                onPreview: { newValue in
                    previewMaskGeometry(mask.id) { $0.radius = newValue }
                },
                onCommitPreview: { editor.commitContinuousEdit() }
            )
            featherControl(for: mask)
            if mask.geometry.brushStrokes.isEmpty {
                Text(L10n.t("Brush uses a circular base until a stroke is drawn."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .luminanceRange:
            AdjustmentSliderRow(
                label: L10n.t("Minimum"),
                value: mask.geometry.luminanceMin ?? 0,
                range: 0...1,
                fractionDigits: 1,
                onChange: { newValue in
                    updateMaskGeometry(mask.id) { geometry in
                        let maximum = geometry.luminanceMax ?? 1
                        geometry.luminanceMin = Swift.min(newValue, maximum)
                    }
                },
                onReset: {
                    updateMaskGeometry(mask.id) { $0.luminanceMin = nil }
                },
                onPreview: { newValue in
                    previewMaskGeometry(mask.id) { geometry in
                        let maximum = geometry.luminanceMax ?? 1
                        geometry.luminanceMin = Swift.min(newValue, maximum)
                    }
                },
                onCommitPreview: { editor.commitContinuousEdit() }
            )

            AdjustmentSliderRow(
                label: L10n.t("Maximum"),
                value: mask.geometry.luminanceMax ?? 1,
                range: 0...1,
                fractionDigits: 1,
                onChange: { newValue in
                    updateMaskGeometry(mask.id) { geometry in
                        let minimum = geometry.luminanceMin ?? 0
                        geometry.luminanceMax = Swift.max(newValue, minimum)
                    }
                },
                onReset: {
                    updateMaskGeometry(mask.id) { $0.luminanceMax = nil }
                },
                onPreview: { newValue in
                    previewMaskGeometry(mask.id) { geometry in
                        let minimum = geometry.luminanceMin ?? 0
                        geometry.luminanceMax = Swift.max(newValue, minimum)
                    }
                },
                onCommitPreview: { editor.commitContinuousEdit() }
            )
            featherControl(for: mask)

        case .colorRange:
            AdjustmentSliderRow(
                label: L10n.t("Hue"),
                value: mask.geometry.colorTargetHue ?? 0,
                range: 0...360,
                fractionDigits: 1,
                onChange: { newValue in
                    updateMaskGeometry(mask.id) { $0.colorTargetHue = newValue }
                },
                onReset: {
                    updateMaskGeometry(mask.id) { $0.colorTargetHue = nil }
                },
                onPreview: { newValue in
                    previewMaskGeometry(mask.id) { $0.colorTargetHue = newValue }
                },
                onCommitPreview: { editor.commitContinuousEdit() }
            )

            AdjustmentSliderRow(
                label: L10n.t("Tolerance"),
                value: mask.geometry.colorHueTolerance ?? 30,
                range: 0...180,
                fractionDigits: 1,
                onChange: { newValue in
                    updateMaskGeometry(mask.id) { $0.colorHueTolerance = newValue }
                },
                onReset: {
                    updateMaskGeometry(mask.id) { $0.colorHueTolerance = nil }
                },
                onPreview: { newValue in
                    previewMaskGeometry(mask.id) { $0.colorHueTolerance = newValue }
                },
                onCommitPreview: { editor.commitContinuousEdit() }
            )
            featherControl(for: mask)

        case .subject, .background:
            Text(L10n.t("Automatic"))
                .font(.caption2)
                .foregroundStyle(.secondary)

        case .spotHeal:
            EmptyView()
        }
    }

    private func maskPositionControls(for mask: LocalAdjustment) -> some View {
        Group {
            AdjustmentSliderRow(
                label: L10n.t("Horizontal"),
                value: mask.geometry.x,
                range: 0...1,
                fractionDigits: 1,
                onChange: { newValue in
                    updateMaskGeometry(mask.id) { $0.x = newValue }
                },
                onReset: {
                    updateMaskGeometry(mask.id) { $0.x = LocalAdjustmentGeometry.neutral.x }
                },
                onPreview: { newValue in
                    previewMaskGeometry(mask.id) { $0.x = newValue }
                },
                onCommitPreview: { editor.commitContinuousEdit() }
            )

            AdjustmentSliderRow(
                label: L10n.t("Vertical"),
                value: mask.geometry.y,
                range: 0...1,
                fractionDigits: 1,
                onChange: { newValue in
                    updateMaskGeometry(mask.id) { $0.y = newValue }
                },
                onReset: {
                    updateMaskGeometry(mask.id) { $0.y = LocalAdjustmentGeometry.neutral.y }
                },
                onPreview: { newValue in
                    previewMaskGeometry(mask.id) { $0.y = newValue }
                },
                onCommitPreview: { editor.commitContinuousEdit() }
            )
        }
    }

    private func featherControl(for mask: LocalAdjustment) -> some View {
        AdjustmentSliderRow(
            label: L10n.t("Feather"),
            value: mask.geometry.feather,
            range: LocalAdjustmentGeometry.featherRange,
            fractionDigits: 1,
            onChange: { newValue in
                updateMaskGeometry(mask.id) { $0.feather = newValue }
            },
            onReset: {
                updateMaskGeometry(mask.id) { $0.feather = LocalAdjustmentGeometry.neutral.feather }
            },
            onPreview: { newValue in
                previewMaskGeometry(mask.id) { $0.feather = newValue }
            },
            onCommitPreview: { editor.commitContinuousEdit() }
        )
    }

    private func updateMaskGeometry(_ id: UUID, _ change: (inout LocalAdjustmentGeometry) -> Void) {
        editor.updateAdjustments { adjustments in
            guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == id }) else { return }
            change(&adjustments.localAdjustments[index].geometry)
        }
    }

    private func previewMaskGeometry(_ id: UUID, _ change: (inout LocalAdjustmentGeometry) -> Void) {
        editor.previewContinuousEdit { adjustments in
            guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == id }) else { return }
            change(&adjustments.localAdjustments[index].geometry)
        }
    }

    private func previewLocalAdjustment(_ id: UUID, _ change: (inout LocalAdjustment) -> Void) {
        editor.previewContinuousEdit { adjustments in
            guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == id }) else { return }
            change(&adjustments.localAdjustments[index])
        }
    }

    private func canvasToolMode(for kind: LocalAdjustmentKind) -> EditorToolMode? {
        switch kind {
        case .linearGradient: return .linearGradient
        case .radialGradient: return .radialGradient
        case .brush: return .brush
        case .luminanceRange, .colorRange, .subject, .background, .spotHeal: return nil
        }
    }

    private func canvasToolMode(for mode: EditorToolMode) -> EditorToolMode? {
        switch mode {
        case .linearGradient, .radialGradient, .brush: return mode
        case .adjust, .crop, .whiteBalance, .spotHeal: return nil
        }
    }

    private func spotHealRow(for heal: LocalAdjustment) -> some View {
        let isSelected = editor.selectedLocalAdjustmentID == heal.id
        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    spotHealSelectionButton(heal, isSelected: isSelected)
                    Spacer(minLength: 8)
                    spotHealActions(heal)
                }

                VStack(alignment: .leading, spacing: 6) {
                    spotHealSelectionButton(heal, isSelected: isSelected)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack {
                        Spacer(minLength: 0)
                        spotHealActions(heal)
                    }
                }
            }

            if isSelected {
                spotHealModePicker(for: heal)

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
                    fractionDigits: 1,
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
                    },
                    onPreview: { newValue in
                        previewMaskGeometry(heal.id) { $0.radius = newValue }
                    },
                    onCommitPreview: { editor.commitContinuousEdit() }
                )

                AdjustmentSliderRow(
                    label: L10n.t("Feather"),
                    value: heal.geometry.feather,
                    range: LocalAdjustmentGeometry.featherRange,
                    fractionDigits: 1,
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
                    },
                    onPreview: { newValue in
                        previewMaskGeometry(heal.id) { $0.feather = newValue }
                    },
                    onCommitPreview: { editor.commitContinuousEdit() }
                )

                if heal.geometry.healMode == .redEye {
                    AdjustmentSliderRow(
                        label: L10n.t("Pupil Radius"),
                        value: heal.geometry.redEyePupilRadius ?? heal.geometry.radius,
                        range: 0.01...0.3,
                        fractionDigits: 1,
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
                        },
                        onPreview: { newValue in
                            previewMaskGeometry(heal.id) { $0.redEyePupilRadius = newValue }
                        },
                        onCommitPreview: { editor.commitContinuousEdit() }
                    )
                }
            }
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func spotHealModePicker(for heal: LocalAdjustment) -> some View {
        ViewThatFits(in: .horizontal) {
            spotHealModeSegmentedPicker(for: heal)
            spotHealModeMenu(for: heal)
        }
        .labelsHidden()
        .accessibilityLabel(Text(L10n.t("Mode")))
    }

    private func spotHealModeSegmentedPicker(for heal: LocalAdjustment) -> some View {
        Picker(L10n.t("Mode"), selection: spotHealModeBinding(for: heal)) {
            Text(L10n.t("Heal")).tag(SpotHealMode.heal)
            Text(L10n.t("Clone")).tag(SpotHealMode.clone)
            Text(L10n.t("Red-Eye")).tag(SpotHealMode.redEye)
        }
        .pickerStyle(.segmented)
        .frame(minHeight: AdjustmentControlMetrics.actionMinimumHeight)
    }

    private func spotHealModeMenu(for heal: LocalAdjustment) -> some View {
        Picker(L10n.t("Mode"), selection: spotHealModeBinding(for: heal)) {
            Text(L10n.t("Heal")).tag(SpotHealMode.heal)
            Text(L10n.t("Clone")).tag(SpotHealMode.clone)
            Text(L10n.t("Red-Eye")).tag(SpotHealMode.redEye)
        }
        .pickerStyle(.menu)
        .frame(minHeight: AdjustmentControlMetrics.actionMinimumHeight, alignment: .leading)
    }

    private func spotHealModeBinding(for heal: LocalAdjustment) -> Binding<SpotHealMode> {
        Binding(
            get: { heal.geometry.healMode },
            set: { newValue in
                editor.updateAdjustments { adjustments in
                    guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == heal.id }) else { return }
                    adjustments.localAdjustments[index].geometry.healMode = newValue
                }
            }
        )
    }

    private func spotHealSelectionButton(_ heal: LocalAdjustment, isSelected: Bool) -> some View {
        Button {
            editor.selectedLocalAdjustmentID = heal.id
            editor.setToolMode(.spotHeal)
        } label: {
            Label(
                heal.isEnabled ? (heal.geometry.healMode == .redEye ? L10n.t("Red-Eye") : L10n.t("Spot Heal")) : L10n.t("Spot Heal (Off)"),
                systemImage: heal.geometry.healMode == .redEye ? "eye" : "bandage"
            )
            .fontWeight(isSelected ? .semibold : .regular)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44, alignment: .leading)
        // Match mask selection: the full wrapped Spot Heal row is a stable
        // touch target when the inspector switches to stacked layout.
        .contentShape(Rectangle())
    }

    private func spotHealActions(_ heal: LocalAdjustment) -> some View {
        HStack(spacing: 4) {
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
            .frame(minWidth: 44, minHeight: 44)

            Button(role: .destructive) {
                editor.updateAdjustments { $0.localAdjustments = $0.localAdjustments.removing(heal.id) }
                if editor.selectedLocalAdjustmentID == heal.id {
                    editor.selectedLocalAdjustmentID = nil
                    if editor.toolMode == .spotHeal {
                        editor.setToolMode(.adjust)
                    }
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text(L10n.t("Delete Spot Heal")))
        }
    }
}
