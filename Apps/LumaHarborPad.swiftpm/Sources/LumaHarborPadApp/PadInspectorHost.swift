import AdjustmentUI
import EditorCore
import Localization
import PresetCore
import RawProcessingCore
import SwiftUI

/// Routes the inspector panel to the correct content for the active
/// `PadInspectorDomain`. The Adjust and Preset domains are fully wired.
///
/// `editor` passes through to each panel unchanged — this host never holds a
/// second copy of `PhotoAdjustments` and never touches undo/redo or autosave.
///
/// `showsDomainBar` controls whether a compact horizontal domain-selection
/// bar is shown at the top of the host. Pass `true` for Compact/Standard
/// presentations (bottom drawer, floating panel) where the vertical
/// `PadToolRail` is absent.
struct PadInspectorHost: View {
    @ObservedObject var inspector: PadInspectorCoordinator
    @ObservedObject var editor: EditorSession
    @ObservedObject var presetLibrary: PadPresetLibrary
    let showsDomainBar: Bool
    // Adjustments starts with only Basic open. Dedicated Geometry and Local
    // pages are already inside their own first-level host, so they open with
    // their page content available on first visit rather than showing a
    // seemingly empty inspector until the user taps the title.
    @State private var expandedSections = InspectorSectionExpansionPolicy.initialExpanded
        .union([.geometry, .local])

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDomainBar {
                compactDomainBar
                Divider()
            }
            switch inspector.activeDomain {
            case .adjust:
                adjustPanel
            case .preset:
                PadPresetPanel(editor: editor, presetLibrary: presetLibrary)
            case .geometry:
                ScrollView {
                    domainSection(
                        .geometry,
                        titleKey: "Geometry"
                    ) {
                        GeometryAdjustmentPanel(editor: editor)
                    }
                    .padding()
                }
            case .local:
                ScrollView {
                    domainSection(
                        .local,
                        titleKey: "Local Adjustments"
                    ) {
                        LocalAdjustmentsPanel(editor: editor)
                    }
                    .padding()
                }
            case .info:
                infoPanel
            }
        }
    }

    /// Geometry and Local are dedicated domains on iPad, but their content
    /// still needs the same Level 1 hierarchy as an Adjustments page. Without
    /// this host the panels' Level 2 groups render at the page root, so their
    /// chevrons, titles, and 16pt inset lose the cross-platform relationship.
    @ViewBuilder
    private func domainSection<Content: View>(
        _ sectionID: InspectorSectionID,
        titleKey: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let summary = InspectorGroupSummary.summary(for: sectionID, in: editor.adjustments)
        InspectorLevel1DisclosureGroup(
            L10n.t(titleKey),
            summary: summary.localizedText,
            isExpanded: Binding(
                get: { expandedSections.contains(sectionID) },
                set: { isExpanded in
                    expandedSections = isExpanded
                        ? expandedSections.union([sectionID])
                        : expandedSections.subtracting([sectionID])
                }
            ),
            content: content
        )
    }

    // MARK: - Compact domain bar (Compact/Standard layouts)

    private struct DomainBarItem: Identifiable {
        let id: PadInspectorDomain
        let symbol: String
        let labelKey: String
    }

    private static let domainBarItems: [DomainBarItem] = [
        DomainBarItem(id: .adjust,   symbol: "slider.horizontal.3", labelKey: "Adjustments"),
        DomainBarItem(id: .preset,   symbol: "sparkles",            labelKey: "Presets"),
        DomainBarItem(id: .geometry, symbol: "crop.rotate",         labelKey: "Geometry"),
        DomainBarItem(id: .local,    symbol: "paintbrush.pointed",  labelKey: "Local Adjustments"),
        DomainBarItem(id: .info,     symbol: "info.circle",         labelKey: "Info"),
    ]

    private var compactDomainBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Self.domainBarItems) { item in
                    let isSelected = inspector.activeDomain == item.id
                    Button {
                        inspector.selectDomain(item.id)
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: item.symbol)
                                .imageScale(.small)
                            Text(L10n.t(item.labelKey))
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.center)
                        }
                        .frame(minWidth: 88, minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .background(
                        isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .accessibilityLabel(Text(L10n.t(item.labelKey)))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Adjust domain

    @ViewBuilder
    private var adjustPanel: some View {
        adjustSubmodePicker
            .padding(.horizontal)
            .padding(.vertical, 8)
        Divider()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                adjustContent
            }
            .padding()
        }
    }

    private var adjustSubmodePicker: some View {
        ViewThatFits(in: .horizontal) {
            submodePicker
            submodeMenu
        }
        .accessibilityLabel(Text(L10n.t("Adjust submode")))
    }

    private var submodePicker: some View {
        Picker(L10n.t("Adjustments"), selection: Binding(
            get: { inspector.adjustSubmode },
            set: { inspector.selectAdjustSubmode($0) }
        )) {
            Text(L10n.t("Light")).tag(PadAdjustSubmode.light)
            Text(L10n.t("Color")).tag(PadAdjustSubmode.color)
            Text(L10n.t("Detail")).tag(PadAdjustSubmode.detail)
        }
        .pickerStyle(.segmented)
        .frame(minHeight: 44)
    }

    private var submodeMenu: some View {
        Picker(L10n.t("Adjustments"), selection: Binding(
            get: { inspector.adjustSubmode },
            set: { inspector.selectAdjustSubmode($0) }
        )) {
            Text(L10n.t("Light")).tag(PadAdjustSubmode.light)
            Text(L10n.t("Color")).tag(PadAdjustSubmode.color)
            Text(L10n.t("Detail")).tag(PadAdjustSubmode.detail)
        }
        .pickerStyle(.menu)
        .frame(minHeight: 44, alignment: .leading)
    }

    /// P2 (`2026-09-10-shared-professional-inspector-catalog.md`): field
    /// vocabulary comes from the shared `InspectorCatalog`, matching the
    /// inlined `PadInspectorHost` in `PadEditorView.swift` and Mac's
    /// `InspectorView`.
    @ViewBuilder
    private var adjustContent: some View {
        switch inspector.adjustSubmode {
        case .light:
            adjustmentSection(.basic, titleKey: "Basic") {
                RenderingProfilePanel(editor: editor)
                BasicAdjustmentPanel(editor: editor, kinds: InspectorCatalog.section(.basic).adjustmentKinds)
            }
            adjustmentSection(.presence, titleKey: "Presence") {
                PresenceAdjustmentPanel(editor: editor)
            }
            adjustmentSection(.curve, titleKey: "Curve") {
                CurveAdjustmentPanel(editor: editor)
            }
        case .color:
            adjustmentSection(.hsl, titleKey: "Color", summarySections: [.whiteBalance, .hsl]) {
                Level2Section(L10n.t("White Balance")) {
                    BasicAdjustmentPanel(editor: editor, kinds: InspectorCatalog.section(.whiteBalance).adjustmentKinds)
                }
                ColorAdjustmentPanel(editor: editor)
            }
            adjustmentSection(.colorGrading, titleKey: "Color Grading") {
                ColorGradingAdjustmentPanel(editor: editor)
            }
        case .detail:
            adjustmentSection(.detail, titleKey: "Detail") {
                DetailAdjustmentPanel(editor: editor)
            }
            adjustmentSection(.effects, titleKey: "Effects") {
                EffectsAdjustmentPanel(editor: editor)
            }
        }
    }

    @ViewBuilder
    private func adjustmentSection<Content: View>(
        _ sectionID: InspectorSectionID,
        titleKey: String,
        summarySections: [InspectorSectionID]? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let ids = summarySections ?? [sectionID]
        let adjustedCount = ids.reduce(0) { partial, id in
            switch InspectorGroupSummary.summary(for: id, in: editor.adjustments) {
            case .notAdjusted:
                return partial
            case .adjusted(let count):
                return partial + count
            }
        }
        let summary: InspectorGroupSummary = adjustedCount == 0 ? .notAdjusted : .adjusted(count: adjustedCount)
        InspectorLevel1DisclosureGroup(
            L10n.t(titleKey),
            summary: summary.localizedText,
            isExpanded: Binding(
                get: { expandedSections.contains(sectionID) },
                set: { isExpanded in
                    expandedSections = isExpanded
                        ? expandedSections.union([sectionID])
                        : expandedSections.subtracting([sectionID])
                }
            ),
            content: content
        )
    }

    // Keep the standalone SwiftPM host semantically aligned with the Xcode
    // host and macOS Inspector: histogram, file data, save state, snapshots.
    private var infoPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HistogramPanel(histogram: editor.histogram)
                Divider()
                if let photo = editor.photo {
                    PadStandaloneMetadataBlock(snapshot: EditorMetadataSnapshot(photo: photo))
                } else {
                    Text(L10n.t("Photo not yet loaded."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                Divider()
                PadStandaloneSaveStateBlock(saveState: editor.saveState)
                Divider()
                if editor.photo != nil {
                    SnapshotsPanel(editor: editor)
                }
            }
            .padding()
        }
    }

    // MARK: - Unavailable placeholder

    private func unavailablePlaceholder(domain: String, symbol: String, note: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: symbol)
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Text(domain)
                .font(.headline)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(domain): \(note)"))
    }
}

private struct PadStandaloneSaveStateBlock: View {
    let saveState: SaveState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("Save State"))
                .font(.subheadline.weight(.semibold))
            switch saveState {
            case .unchanged, .saved:
                Label(L10n.t("Saved"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            case .pending:
                Label(L10n.t("Unsaved changes"), systemImage: "clock")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            case .saving:
                Label(L10n.t("Saving…"), systemImage: "arrow.clockwise")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            case .failed(let message):
                Label(L10n.t("Save failed"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PadStandaloneMetadataBlock: View {
    let snapshot: EditorMetadataSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("File Info"))
                .font(.subheadline.weight(.semibold))
            row(L10n.t("Filename"), snapshot.filename)
            row(L10n.t("Format"), snapshot.formatDescription)
            row(L10n.t("Dimensions"), snapshot.pixelDimensions)
            row(L10n.t("File Size"), snapshot.fileSizeDescription)
            row(L10n.t("Camera"), snapshot.cameraDescription)
            row(L10n.t("Lens"), snapshot.lensDescription)
            row(L10n.t("Focal Length"), snapshot.focalLengthDescription)
            row(L10n.t("Aperture"), snapshot.apertureDescription)
            row(L10n.t("Shutter Speed"), snapshot.shutterSpeedDescription)
            row(L10n.t("ISO"), snapshot.isoDescription)
            row(L10n.t("Capture Date"), snapshot.captureDateDescription)
            row(L10n.t("Orientation"), snapshot.orientationDescription)
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                Text(value ?? "—")
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .foregroundStyle(.secondary)
                Text(value ?? "—")
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
    }
}
