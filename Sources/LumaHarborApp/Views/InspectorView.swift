import AdjustmentUI
import EditorCore
import PhotoLibraryCore
import Localization
import RawProcessingCore
import SwiftUI

/// Right pane: the shared basic adjustments alongside Mac-only preset controls.
struct InspectorView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @State private var selectedTab: InspectorTab = .adjustments
    @State private var expandedGroups: Set<InspectorGroup> = [.basic, .color]
    @StateObject private var navigation = InspectorNavigationModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Picker("", selection: $selectedTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if model.editor.photo == nil {
                ContentUnavailableMessage()
            } else {
                switch selectedTab {
                case .adjustments:
                    adjustmentContent
                case .presets:
                    PresetBrowserView()
                case .metadata:
                    metadataContent
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: model.editor.toolMode) { _, newValue in
            navigation.follow(toolMode: newValue)
        }
        .onChange(of: navigation.activeSectionID) { _, newValue in
            selectedTab = .adjustments
            expandedGroups.insert(macGroup(for: newValue))
        }
    }

    /// P2 (`2026-09-10-shared-professional-inspector-catalog.md` §5): Mac keeps
    /// its existing seven `DisclosureGroup`s (unchanged headers/panels, so the
    /// pre-existing `InspectorAdjustmentGroupsContractTests` literal-text
    /// contract still holds) but every group's field vocabulary, search
    /// hit-testing, favorite state, and reset behavior now come from the
    /// shared `InspectorCatalog` -- a `.whiteBalance`/`.hsl` catalog hit still
    /// maps onto the single `.color` `DisclosureGroup`, since Mac visually
    /// keeps White Balance and HSL together (unchanged from before P2).
    private func macGroup(for sectionID: InspectorSectionID) -> InspectorGroup {
        switch sectionID {
        case .basic: return .basic
        case .whiteBalance, .hsl: return .color
        case .curve: return .curve
        case .detail: return .detail
        case .effects: return .effects
        case .geometry: return .geometry
        case .local: return .local
        }
    }

    private var adjustmentContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                searchField
                if !navigation.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    searchResultsList
                } else {
                    HistogramPanel(histogram: model.editor.histogram)
                    inspectorGroup(.basic, sectionID: .basic, title: L10n.t("Basic")) {
                        BasicAdjustmentPanel(editor: model.editor, kinds: MacBasicAdjustmentPanel.toneKinds)
                    }
                    inspectorGroup(.color, sectionID: .whiteBalance, title: L10n.t("Color")) {
                        HStack {
                            Text(L10n.t("White Balance")).font(.headline)
                            Spacer()
                            WhiteBalanceEyedropperButton(editor: model.editor)
                        }
                        BasicAdjustmentPanel(editor: model.editor, kinds: MacBasicAdjustmentPanel.whiteBalanceKinds)
                        ColorAdjustmentPanel(editor: model.editor)
                    }
                    inspectorGroup(.curve, sectionID: .curve, title: L10n.t("Curve")) {
                        CurveAdjustmentPanel(editor: model.editor)
                    }
                    inspectorGroup(.detail, sectionID: .detail, title: L10n.t("Detail")) {
                        DetailAdjustmentPanel(editor: model.editor)
                    }
                    inspectorGroup(.effects, sectionID: .effects, title: L10n.t("Effects")) {
                        EffectsAdjustmentPanel(editor: model.editor)
                    }
                    inspectorGroup(.geometry, sectionID: .geometry, title: L10n.t("Geometry")) {
                        GeometryAdjustmentPanel(editor: model.editor)
                    }
                    inspectorGroup(.local, sectionID: .local, title: L10n.t("Local Adjustments")) {
                        LocalAdjustmentsPanel(editor: model.editor)
                    }
                }
            }
            .padding(14)
        }
    }

    /// P2: the search field lives at the top of the Adjustments tab (not the
    /// shared header) since it only makes sense to search tools while that
    /// tab is showing -- Presets and Metadata already have their own
    /// search/browse affordances.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.t("Search Adjustments"), text: $navigation.searchQuery)
                .textFieldStyle(.plain)
            if !navigation.searchQuery.isEmpty {
                Button {
                    navigation.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.t("Clear Search")))
            }
        }
        .padding(6)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel(Text(L10n.t("Search Adjustments")))
    }

    private var searchResultsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            let results = navigation.searchResults
            if results.isEmpty {
                Text(L10n.t("No matching tools"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(results) { section in
                    Button {
                        navigation.select(section.id)
                        navigation.clearSearch()
                    } label: {
                        HStack {
                            Image(systemName: section.symbol)
                            Text(L10n.t(section.titleKey))
                            Spacer()
                            if navigation.isFavorite(section.id) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var metadataContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let photo = model.editor.photo {
                    MetadataPanel(snapshot: EditorMetadataSnapshot(photo: photo))
                }
                Divider()
                SaveStatePanel(state: model.editor.saveState)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func inspectorGroup<Content: View>(
        _ group: InspectorGroup,
        sectionID: InspectorSectionID,
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedGroups.contains(group) },
                set: { isExpanded in
                    if isExpanded {
                        expandedGroups.insert(group)
                    } else {
                        expandedGroups.remove(group)
                    }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text(title).font(.headline)
                Spacer()
                sectionResetButton(sectionID)
                favoriteButton(sectionID)
            }
        }
    }

    /// P2: per-section favorite toggle, stored device-local via
    /// `InspectorNavigationModel`/`InspectorFavoritesModel`.
    private func favoriteButton(_ sectionID: InspectorSectionID) -> some View {
        let isFavorite = navigation.isFavorite(sectionID)
        return Button {
            navigation.toggleFavorite(sectionID)
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? .yellow : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isFavorite ? L10n.t("Remove from Favorites") : L10n.t("Add to Favorites")))
    }

    /// P2: resets only this section's own fields (`InspectorCatalog
    /// .resetting(_:in:)`), disabled once already neutral -- same
    /// disabled-when-nothing-to-reset convention every other panel's own
    /// Reset button already follows.
    private func sectionResetButton(_ sectionID: InspectorSectionID) -> some View {
        let isNeutral = InspectorCatalog.isNeutral(sectionID, in: model.editor.adjustments)
        return Button {
            model.editor.updateAdjustments { adjustments in
                adjustments = InspectorCatalog.resetting(sectionID, in: adjustments)
            }
        } label: {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.plain)
        .disabled(isNeutral)
        .accessibilityLabel(Text(L10n.t("Reset")))
    }

    private var header: some View {
        HStack {
            Text(L10n.t("Adjustments"))
                .font(.headline)
            Spacer()
            pinButton
            adjustmentActionsMenu
            Button(L10n.t("Reset All")) {
                model.editor.resetAll()
            }
            .controlSize(.small)
            .disabled(selectedTab != .adjustments || model.editor.photo == nil || !model.editor.hasEdits)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// P2: pinning suspends Smart Follow (`InspectorNavigationModel.follow`)
    /// so the user can keep working in one section while trying different
    /// canvas tools without the Inspector jumping away underneath them.
    private var pinButton: some View {
        Button {
            navigation.togglePin()
        } label: {
            Image(systemName: navigation.isPinned ? "pin.fill" : "pin")
        }
        .controlSize(.small)
        .disabled(selectedTab != .adjustments)
        .accessibilityLabel(Text(navigation.isPinned ? L10n.t("Unpin Section") : L10n.t("Pin Section")))
        .accessibilityAddTraits(navigation.isPinned ? .isSelected : [])
    }

    /// Phase 2.2 (spec §6.2): "Copy Adjustments" / "Paste Adjustments" /
    /// "Sync to Selected Photos", plus the two opt-in toggles that decide
    /// whether the *next* copy also captures Geometry/Local Adjustments
    /// (off by default -- global adjustments are always copied).
    private var adjustmentActionsMenu: some View {
        Menu {
            Toggle(L10n.t("Include Geometry"), isOn: $model.copyIncludesGeometry)
            Toggle(L10n.t("Include Local Adjustments"), isOn: $model.copyIncludesLocalAdjustments)
            Divider()
            Button(L10n.t("Copy Adjustments")) {
                model.copyAdjustments()
            }
            .disabled(model.editor.photo == nil)
            Button(L10n.t("Paste Adjustments")) {
                model.pasteAdjustments()
            }
            .disabled(model.editor.photo == nil || model.adjustmentClipboard == nil)
            Button(L10n.t("Sync to Selected Photos")) {
                Task { await model.syncAdjustmentsToSelectedPhotos() }
            }
            .disabled(model.adjustmentClipboard == nil || model.selectedPhotoIDs.count <= 1)
            Divider()
            domainResetButton(.adjust, title: L10n.t("Reset Adjust"))
            domainResetButton(.geometry, title: L10n.t("Reset Geometry"))
            domainResetButton(.local, title: L10n.t("Reset Local Adjustments"))
        } label: {
            Label(L10n.t("Adjustments Actions"), systemImage: "doc.on.doc")
        }
        .controlSize(.small)
        .disabled(selectedTab != .adjustments)
    }

    /// P2: domain-wide reset (design spec §7.1 "domain reset"), distinct from
    /// both a single section's reset and "Reset All" -- resets every section
    /// in `domain` (`InspectorCatalog.resetting(domain:in:)`) and leaves the
    /// other two domains alone.
    private func domainResetButton(_ domain: PadInspectorDomain, title: String) -> some View {
        Button(title) {
            model.editor.updateAdjustments { adjustments in
                adjustments = InspectorCatalog.resetting(domain: domain, in: adjustments)
            }
        }
        .disabled(model.editor.photo == nil || InspectorCatalog.isNeutral(domain: domain, in: model.editor.adjustments))
    }
}

private enum InspectorTab: String, CaseIterable, Identifiable {
    case adjustments
    case presets
    case metadata

    var id: String { rawValue }

    var title: String {
        switch self {
        case .adjustments: return L10n.t("Adjustments")
        case .presets: return L10n.t("Presets")
        case .metadata: return L10n.t("Metadata")
        }
    }
}

private enum InspectorGroup: Hashable {
    case basic, color, curve, detail, effects, geometry, local
}

/// P2 (`2026-09-10-shared-professional-inspector-catalog.md`): both arrays are
/// derived from `InspectorCatalog`, the single declaration point shared with
/// iPad's `PadAdjustSubmodeKinds` -- neither platform hand-duplicates this
/// vocabulary anymore.
private enum MacBasicAdjustmentPanel {
    static var toneKinds: [AdjustmentKind] { InspectorCatalog.section(.basic).adjustmentKinds }
    static var whiteBalanceKinds: [AdjustmentKind] { InspectorCatalog.section(.whiteBalance).adjustmentKinds }
}

private struct SaveStatePanel: View {
    let state: SaveState

    var body: some View {
        switch state {
        case .unchanged:
            Label(L10n.t("Saved"), systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .pending:
            Label(L10n.t("Unsaved"), systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .saving:
            Label(L10n.t("Saving…"), systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .saved:
            Label(L10n.t("Saved"), systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(L10n.t("Not saved"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(message)
        }
    }
}

/// AwayPhotoRawEditor parity Phase 1 Task 1: the metadata/EXIF block (design
/// spec §6.2, §8.1). Every value comes from `EditorMetadataSnapshot`, which
/// already formats or nils out each field -- this view only lays the rows
/// out and labels them, so a missing EXIF field never crashes the panel and
/// nothing here ever reads a raw source URL.
private struct MetadataPanel: View {
    let snapshot: EditorMetadataSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("Metadata"))
                .font(.headline)
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
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—")
        }
        .font(.caption)
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
