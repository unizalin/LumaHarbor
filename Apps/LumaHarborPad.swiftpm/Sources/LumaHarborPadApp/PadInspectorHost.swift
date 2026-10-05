import AdjustmentUI
import EditorCore
import Localization
import PresetCore
import RawProcessingCore
import SwiftUI

/// Routes the inspector panel to the correct content for the active domain.
/// The Adjust and Preset domains are fully wired. Never holds a second copy
/// of `PhotoAdjustments`.
///
/// `showsDomainBar`: pass `true` for bottom-drawer / floating-panel
/// presentations where the vertical `PadToolRail` is absent.
struct PadInspectorHost: View {
    @ObservedObject var inspector: PadInspectorCoordinator
    @ObservedObject var navigation: InspectorNavigationModel
    @ObservedObject var editor: EditorSession
    @ObservedObject var presetLibrary: PadPresetLibrary
    @ObservedObject var library: PadLibraryModel
    @ObservedObject var batchCoordinator: PadBatchAdjustmentCoordinator
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
            if showsCatalogNavigation {
                catalogToolbar
                Divider()
            }
            if showsCatalogNavigation,
               !navigation.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResultsList
            } else {
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
        .onChange(of: inspector.activeDomain) { _, _ in
            // A domain switch is an explicit navigation action. Do not leave
            // an old catalog query intercepting the newly selected page; the
            // Preset page owns its own search field and Info has none.
            navigation.clearSearch()
        }
    }

    /// The shared catalog only describes editable adjustment domains. Presets
    /// and Info have their own page-specific controls and must not inherit a
    /// misleading "Search Adjustments" field or catalog result list.
    private var showsCatalogNavigation: Bool {
        switch inspector.activeDomain {
        case .adjust, .geometry, .local:
            return true
        case .preset, .info:
            return false
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

    // MARK: - Shared catalog toolbar (search, favorite, pin, reset)

    /// P2: the same search/favorite/pin/reset affordances Mac's
    /// `InspectorView` exposes, all driven by the shared `InspectorCatalog`/
    /// `InspectorNavigationModel` -- no iPad-only reimplementation.
    /// `currentSectionID`/`currentResetDomain` are `nil` for the Preset and
    /// Info domains, which are not part of the field catalog: favorite/reset
    /// simply hide rather than show a control with nothing to act on.
    private var catalogToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                catalogSearchField
                Spacer(minLength: 4)
                catalogToolbarActions
            }

            VStack(alignment: .leading, spacing: 4) {
                catalogSearchField
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Spacer(minLength: 0)
                    catalogToolbarActions
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var catalogSearchField: some View {
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
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(Text(L10n.t("Clear Search")))
            }
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var catalogToolbarActions: some View {
        if let sectionID = currentSectionID {
            Button {
                navigation.toggleFavorite(sectionID)
            } label: {
                Image(systemName: navigation.isFavorite(sectionID) ? "star.fill" : "star")
                    .foregroundStyle(navigation.isFavorite(sectionID) ? .yellow : .secondary)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text(navigation.isFavorite(sectionID) ? L10n.t("Remove from Favorites") : L10n.t("Add to Favorites")))
        }
        Button {
            navigation.togglePin()
        } label: {
            Image(systemName: navigation.isPinned ? "pin.fill" : "pin")
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(Text(navigation.isPinned ? L10n.t("Unpin Section") : L10n.t("Pin Section")))
        .accessibilityAddTraits(navigation.isPinned ? .isSelected : [])
        if let domain = currentResetDomain {
            Button {
                editor.updateAdjustments { adjustments in
                    adjustments = InspectorCatalog.resetting(domain: domain, in: adjustments)
                }
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .frame(minWidth: 44, minHeight: 44)
            .disabled(editor.photo == nil || InspectorCatalog.isNeutral(domain: domain, in: editor.adjustments))
            .accessibilityLabel(Text(L10n.t("Reset")))
        }
    }

    /// A representative catalog section for the currently active
    /// domain/submode, used only for the favorite star (reset uses the whole
    /// domain, not one section). `nil` for Preset/Info, which the shared
    /// catalog does not cover.
    private var currentSectionID: InspectorSectionID? {
        switch inspector.activeDomain {
        case .adjust:
            switch inspector.adjustSubmode {
            case .light: return .basic
            case .color: return .whiteBalance
            case .detail: return .detail
            }
        case .geometry: return .geometry
        case .local: return .local
        case .preset, .info: return nil
        }
    }

    private var currentResetDomain: PadInspectorDomain? {
        switch inspector.activeDomain {
        case .adjust, .geometry, .local: return inspector.activeDomain
        case .preset, .info: return nil
        }
    }

    private var searchResultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                let results = navigation.searchResults
                if results.isEmpty {
                    Text(L10n.t("No matching tools"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding()
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
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: Compact domain bar

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
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
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

    // MARK: Adjust domain

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

    /// P2 (`2026-09-10-shared-professional-inspector-catalog.md` §2): field
    /// vocabulary for every submode comes from `InspectorCatalog`, the same
    /// declaration point Mac's `InspectorView` reads. The `.color` case now
    /// also mounts the White Balance panel -- previously
    /// `PadAdjustSubmodeKinds.color` declared `basic.temperature`/
    /// `basic.tint` in its vocabulary but no panel ever rendered them; this
    /// closes that gap and brings iPad to parity with Mac's `.color`
    /// `DisclosureGroup` (White Balance + HSL together).
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
                    Button {
                        if editor.toolMode == .whiteBalance {
                            editor.cancelEyedropperPreview()
                            editor.setToolMode(.adjust)
                        } else {
                            editor.setToolMode(.whiteBalance)
                        }
                    } label: {
                        Label(
                            editor.toolMode == .whiteBalance
                                ? L10n.t("Cancel Eyedropper")
                                : L10n.t("White Balance Eyedropper"),
                            systemImage: "eyedropper"
                        )
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(editor.photo == nil || (editor.toolMode != .whiteBalance && editor.whiteBalanceCapability != .valid))
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

    // MARK: Info domain

    @ViewBuilder
    private var infoPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PadHistogramBlock(histogram: editor.histogram)
                Divider()
                if let photo = editor.photo {
                    let curationPhoto = library.photos.first(where: { $0.id == photo.id }) ?? photo
                    PadMetadataBlock(
                        snapshot: EditorMetadataSnapshot(photo: curationPhoto),
                        photo: curationPhoto,
                        batchCoordinator: batchCoordinator,
                        recipe: editor.latestRawRenderRecipe
                    )
                } else {
                    Text(L10n.t("Photo not yet loaded."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }
                Divider()
                PadSaveStateBlock(saveState: editor.saveState)
                Divider()
                if editor.photo != nil {
                    SnapshotsPanel(editor: editor)
                }
            }
            .padding()
        }
    }

    // MARK: Unavailable placeholder

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
