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
                    GeometryAdjustmentPanel(editor: editor)
                        .padding()
                }
            case .local:
                ScrollView {
                    LocalAdjustmentsPanel(editor: editor)
                        .padding()
                }
            case .info:
                ScrollView {
                    HistogramPanel(histogram: editor.histogram)
                        .padding()
                }
            }
        }
    }

    // MARK: - Compact domain bar (Compact/Standard layouts)

    private struct DomainBarItem: Identifiable {
        let id: PadInspectorDomain
        let symbol: String
        let labelKey: String
    }

    private static let domainBarItems: [DomainBarItem] = [
        DomainBarItem(id: .adjust,   symbol: "slider.horizontal.3", labelKey: "Adjust"),
        DomainBarItem(id: .preset,   symbol: "sparkles",            labelKey: "Presets"),
        DomainBarItem(id: .geometry, symbol: "crop.rotate",         labelKey: "Geometry"),
        DomainBarItem(id: .local,    symbol: "paintbrush.pointed",  labelKey: "Local"),
        DomainBarItem(id: .info,     symbol: "info.circle",         labelKey: "Info"),
    ]

    private var compactDomainBar: some View {
        HStack(spacing: 0) {
            ForEach(Self.domainBarItems) { item in
                let isSelected = inspector.activeDomain == item.id
                Button {
                    inspector.selectDomain(item.id)
                } label: {
                    Image(systemName: item.symbol)
                        .imageScale(.medium)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
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
        Picker(L10n.t("Adjust"), selection: Binding(
            get: { inspector.adjustSubmode },
            set: { inspector.selectAdjustSubmode($0) }
        )) {
            Text(L10n.t("Light")).tag(PadAdjustSubmode.light)
            Text(L10n.t("Color")).tag(PadAdjustSubmode.color)
            Text(L10n.t("Detail")).tag(PadAdjustSubmode.detail)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel(Text(L10n.t("Adjust submode")))
    }

    /// P2 (`2026-09-10-shared-professional-inspector-catalog.md`): field
    /// vocabulary comes from the shared `InspectorCatalog`, matching the
    /// inlined `PadInspectorHost` in `PadEditorView.swift` and Mac's
    /// `InspectorView`.
    @ViewBuilder
    private var adjustContent: some View {
        switch inspector.adjustSubmode {
        case .light:
            BasicAdjustmentPanel(editor: editor, kinds: InspectorCatalog.section(.basic).adjustmentKinds)
            CurveAdjustmentPanel(editor: editor)
        case .color:
            BasicAdjustmentPanel(editor: editor, kinds: InspectorCatalog.section(.whiteBalance).adjustmentKinds)
            ColorAdjustmentPanel(editor: editor)
        case .detail:
            DetailAdjustmentPanel(editor: editor)
            EffectsAdjustmentPanel(editor: editor)
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
