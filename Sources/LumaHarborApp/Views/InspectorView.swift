import AdjustmentUI
import EditorCore
import PhotoLibraryCore
import Localization
import RawProcessingCore
import SwiftUI

/// Right pane: the shared five-domain Inspector used by Mac and iPad.
struct InspectorView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @State private var selectedTab: InspectorTab = .adjustments
    /// Inspector hierarchy/typography spec (2026-09-14) §5.1: "On first
    /// presentation, expand only Basic." User-driven expansion of any other
    /// group is preserved for the rest of this view's lifetime (switching
    /// tabs, resizing, or selecting an HSL band never resets this set).
    @State private var expandedGroups: Set<InspectorGroup> = [.basic]
    @StateObject private var navigation = InspectorNavigationModel()
    /// Shared hierarchy sizes are read through `@ScaledMetric` so Mac and
    /// iPad still grow with the user's text-size setting instead of using
    /// flat, unscaled literals.
    @ScaledMetric(relativeTo: .headline) private var level1TitleFontSize: CGFloat = InspectorHierarchyMetrics.level1TitleBaseSize
    @ScaledMetric(relativeTo: .caption) private var level1SummaryFontSize: CGFloat = InspectorHierarchyMetrics.level1SummaryBaseSize

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            tabBar
            Divider()

            if model.editor.photo == nil {
                ContentUnavailableMessage()
            } else {
                switch selectedTab {
                case .adjustments:
                    adjustmentContent
                case .presets:
                    PresetBrowserView()
                case .geometry:
                    ScrollView {
                        inspectorGroup(.geometry, sectionID: .geometry, title: L10n.t("Geometry")) {
                            GeometryAdjustmentPanel(editor: model.editor)
                        }
                        .padding(12)
                    }
                case .local:
                    ScrollView {
                        inspectorGroup(.local, sectionID: .local, title: L10n.t("Local Adjustments")) {
                            LocalAdjustmentsPanel(editor: model.editor)
                        }
                        .padding(12)
                    }
                case .info:
                    infoContent
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: model.editor.toolMode) { _, newValue in
            navigation.follow(toolMode: newValue)
        }
        .onChange(of: navigation.activeSectionID) { _, newValue in
            selectedTab = macTab(for: newValue)
            expandedGroups.insert(macGroup(for: newValue))
        }
        .onChange(of: selectedTab) { _, newValue in
            // Dedicated pages should open with their page-level content
            // visible, matching iPad's Geometry/Local hosts. This only
            // changes presentation state; adjustment values and history stay
            // untouched.
            switch newValue {
            case .geometry:
                expandedGroups.insert(.geometry)
            case .local:
                expandedGroups.insert(.local)
            case .adjustments, .presets, .info:
                break
            }
        }
    }

    /// The segmented control is the most compact presentation when the Mac
    /// Inspector is wide enough. In a narrow split pane it compresses the
    /// long "Local Adjustments" label into an unreadable sliver, so the
    /// fallback keeps the same five domains as full-width, scrollable buttons
    /// with the complete localized label.
    private var tabBar: some View {
        ViewThatFits(in: .horizontal) {
            Picker("", selection: $selectedTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(InspectorTab.allCases) { tab in
                        tabButton(tab)
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 8)
    }

    private func tabButton(_ tab: InspectorTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.symbol)
                    .imageScale(.small)
                Text(tab.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }
            .frame(minWidth: 112, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.secondary)
        .background(
            selectedTab == tab ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .accessibilityLabel(Text(tab.title))
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
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
        case .presence: return .presence
        case .colorGrading: return .colorGrading
        case .detail: return .detail
        case .effects: return .effects
        case .geometry: return .geometry
        case .local: return .local
        }
    }

    private func macTab(for sectionID: InspectorSectionID) -> InspectorTab {
        switch sectionID {
        case .geometry:
            return .geometry
        case .local:
            return .local
        default:
            return .adjustments
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
                        RenderingProfilePanel(editor: model.editor)
                        BasicAdjustmentPanel(editor: model.editor, kinds: MacBasicAdjustmentPanel.toneKinds)
                    }
                    inspectorGroup(
                        .color, sectionID: .whiteBalance, title: L10n.t("Color"),
                        summarySections: [.whiteBalance, .hsl]
                    ) {
                        Level2Section(L10n.t("White Balance"), trailing: {
                            WhiteBalanceEyedropperButton(editor: model.editor)
                        }) {
                            BasicAdjustmentPanel(editor: model.editor, kinds: MacBasicAdjustmentPanel.whiteBalanceKinds)
                        }
                        ColorAdjustmentPanel(editor: model.editor)
                    }
                    inspectorGroup(.curve, sectionID: .curve, title: L10n.t("Curve")) {
                        CurveAdjustmentPanel(editor: model.editor)
                    }
                    inspectorGroup(.presence, sectionID: .presence, title: L10n.t("Presence")) {
                        PresenceAdjustmentPanel(editor: model.editor)
                    }
                    inspectorGroup(.colorGrading, sectionID: .colorGrading, title: L10n.t("Color Grading")) {
                        ColorGradingAdjustmentPanel(editor: model.editor)
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

    private var infoContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HistogramPanel(histogram: model.editor.histogram)
                Divider()
                if let photo = model.editor.photo {
                    MetadataPanel(
                        snapshot: EditorMetadataSnapshot(photo: photo),
                        photo: model.selectedPhoto ?? photo,
                        model: model
                    )
                }
                Divider()
                SaveStatePanel(state: model.editor.saveState)
                Divider()
                SnapshotsPanel(editor: model.editor)
            }
            .padding(14)
        }
    }

    /// Level 1 feature group (inspector hierarchy/typography spec §5.1's
    /// hierarchy table): full-width row, an explicit scaled 18pt semibold
    /// title,
    /// a neutral/modified summary caption, and the strongest divider/
    /// leading inset of the three levels -- deliberately the most visually
    /// distinct from the Level 2 subsections a group's own content builds
    /// (`Level2DisclosureGroup`), which use a smaller custom chevron,
    /// `.callout.weight(.semibold)`, and a lighter divider.
    ///
    /// `summarySections` lets one visual group (e.g. "Color", which bundles
    /// the `.whiteBalance` and `.hsl` catalog sections) report a combined
    /// modified count while `sectionID` still targets the one section its
    /// own reset/favorite actions apply to, unchanged from before this
    /// spec.
    ///
    /// This builds its own header instead of a native `DisclosureGroup`
    /// (mirroring `Level2DisclosureGroup`) so the expanded-content leading
    /// inset, the single disclosure chevron, and the header's hit target
    /// are all under this view's own deterministic control rather than an
    /// opaque native-control layout the app cannot verify or adjust -- see
    /// `InspectorHierarchyMetrics.level1ContentLeadingInset`'s doc comment
    /// for the user-visible bug this replaced.
    @ViewBuilder
    private func inspectorGroup<Content: View>(
        _ group: InspectorGroup,
        sectionID: InspectorSectionID,
        title: String,
        summarySections: [InspectorSectionID]? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let sections = summarySections ?? [sectionID]
        let modifiedCount = sections.reduce(0) { partial, id in
            switch InspectorGroupSummary.summary(for: id, in: model.editor.adjustments) {
            case .notAdjusted: return partial
            case .adjusted(let count): return partial + count
            }
        }
        let summary: InspectorGroupSummary = modifiedCount == 0 ? .notAdjusted : .adjusted(count: modifiedCount)
        let isExpanded = expandedGroups.contains(group)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: InspectorHierarchyMetrics.level1HeaderSpacing) {
                Button {
                    if isExpanded {
                        expandedGroups.remove(group)
                    } else {
                        expandedGroups.insert(group)
                    }
                } label: {
                    HStack(spacing: InspectorHierarchyMetrics.level1HeaderSpacing) {
                        // A fixed-width column (not the glyph's own
                        // bounding box) so `InspectorHierarchyMetrics
                        // .level1TitleLeadingOffset` is an exact value the
                        // content padding below can rely on.
                        Image(systemName: "chevron.right")
                            .font(.system(size: InspectorHierarchyMetrics.level1ChevronSize, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                            .frame(width: InspectorHierarchyMetrics.level1ChevronColumnWidth, alignment: .center)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.system(size: level1TitleFontSize, weight: .semibold))
                            if !isExpanded {
                                Text(summary.localizedText)
                                    .font(.system(size: level1SummaryFontSize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // The blank gap belongs inside the button's own
                        // label so tapping anywhere in it -- not just the
                        // chevron or title text -- toggles disclosure.
                        Spacer(minLength: 8)
                    }
                    .frame(minHeight: InspectorHierarchyMetrics.level1MinRowHeight, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Favorite star and the actions menu are siblings of the
                // toggle button, not nested inside it, so tapping either
                // keeps its own independent hit target and never also
                // toggles disclosure (spec §5.1: "Clicking a group
                // title...must never reset an adjustment"; this session's
                // acceptance pass additionally requires the actions menu
                // keep an independent 44x44 hit area of its own).
                if navigation.isFavorite(sectionID) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                }
                groupActionsMenu(
                    sectionID,
                    actionSectionIDs: sections,
                    title: title
                )
            }
            .frame(minHeight: InspectorHierarchyMetrics.level1MinRowHeight)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .padding(.top, 8)
                // See `InspectorHierarchyMetrics.level1ContentLeadingInset`:
                // this is what actually moves Basic/Presence/Curve/...
                // fields (which render directly with no `Level2Section`/
                // `Level2DisclosureGroup` of their own) `level2Inset` to
                // the right of the Level 1 title text specifically, not an
                // unrelated origin. `Level2Section`/`Level2DisclosureGroup`
                // only add the further Level 3 *relative* step on top of
                // this, so they must not reapply `level2Inset` themselves
                // (see `InspectorHierarchyMetricsTests
                // .testLevel2ComponentsDoNotReapplyTheLevel1HostsLeadingInset`).
                .padding(.leading, InspectorHierarchyMetrics.level1ContentLeadingInset)
            }
        }
        // `Divider()` is deliberately a *sibling* of the header/content
        // `VStack` above, not its last child: `adjustmentContent`'s outer
        // `VStack(alignment: .leading, spacing: 12)` then supplies the same
        // 12pt rhythm on both sides of it automatically -- a consistent gap
        // between a group's own content and this divider, and between this
        // divider and the next group's header, in both the collapsed and
        // expanded state. Keeping the divider inside the `spacing: 0` stack
        // (the previous layout) glued it directly to the last content row
        // with zero gap, and could sit flush against a nested subsection's
        // own lighter `Divider().opacity(0.4)` (`Level2DisclosureGroup`/
        // `Level2Section`), reading as one doubled-up line.
        Divider()
    }

    /// Reset and favorite move into a trailing menu by default (spec §5.1);
    /// a selected favorite still shows as a filled star next to the menu
    /// (handled by the caller, above) so it stays visible without opening
    /// the menu.
    ///
    /// `.menuIndicator(.hidden)` suppresses `Menu`'s own automatic caret --
    /// without it, the borderless menu button renders both the ellipsis
    /// icon *and* a second chevron next to it, which a 2026-09-14 user
    /// acceptance pass flagged as looking like a second, competing section
    /// disclosure toggle. The left-side chevron built in `inspectorGroup`
    /// above remains the row's only disclosure indicator. The explicit
    /// `level1MinRowHeight`-square frame gives this button its own
    /// independent 44x44 hit target, distinct from the disclosure toggle
    /// button it sits beside.
    private func groupActionsMenu(
        _ sectionID: InspectorSectionID,
        actionSectionIDs: [InspectorSectionID],
        title: String
    ) -> some View {
        let isFavorite = navigation.isFavorite(sectionID)
        let isNeutral = InspectorCatalog.isNeutral(actionSectionIDs, in: model.editor.adjustments)
        return Menu {
            Button {
                navigation.toggleFavorite(sectionID)
            } label: {
                Label(
                    isFavorite ? L10n.t("Remove from Favorites") : L10n.t("Add to Favorites"),
                    systemImage: isFavorite ? "star.slash" : "star"
                )
            }
            Button {
                model.editor.updateAdjustments { adjustments in
                    adjustments = InspectorCatalog.resetting(actionSectionIDs, in: adjustments)
                }
            } label: {
                Label(L10n.t("Reset"), systemImage: "arrow.counterclockwise")
            }
            .disabled(isNeutral)
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
                .frame(
                    width: InspectorHierarchyMetrics.level1MinRowHeight,
                    height: InspectorHierarchyMetrics.level1MinRowHeight
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(String(format: L10n.t("%@ Actions"), title)))
    }

    private var header: some View {
        HStack {
            Text(selectedTab.title)
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
    case geometry
    case local
    case info

    var id: String { rawValue }

    var title: String {
        switch self {
        case .adjustments: return L10n.t("Adjustments")
        case .presets: return L10n.t("Presets")
        case .geometry: return L10n.t("Geometry")
        case .local: return L10n.t("Local Adjustments")
        case .info: return L10n.t("Info")
        }
    }

    var symbol: String {
        switch self {
        case .adjustments: return "slider.horizontal.3"
        case .presets: return "sparkles"
        case .geometry: return "crop.rotate"
        case .local: return "paintbrush.pointed"
        case .info: return "info.circle"
        }
    }
}

private enum InspectorGroup: Hashable {
    case basic, color, curve, presence, colorGrading, detail, effects, geometry, local
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
    let photo: PhotoAsset
    @ObservedObject var model: LibraryViewModel
    @State private var keywordText: String

    init(snapshot: EditorMetadataSnapshot, photo: PhotoAsset, model: LibraryViewModel) {
        self.snapshot = snapshot
        self.photo = photo
        self.model = model
        _keywordText = State(initialValue: photo.keywords.map(\.displayValue).joined(separator: ", "))
    }

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

            Divider()
            Text(L10n.t("Curation"))
                .font(.subheadline.weight(.semibold))
            ratingControls
            flagControl
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("Keywords"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                keywordEditor
            }
        }
        .onChange(of: photo.id) { _, _ in
            keywordText = photo.keywords.map(\.displayValue).joined(separator: ", ")
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

    private var keywordEditor: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                keywordField
                saveKeywordsButton
            }

            VStack(alignment: .leading, spacing: 6) {
                keywordField
                HStack {
                    Spacer(minLength: 0)
                    saveKeywordsButton
                }
            }
        }
    }

    private var keywordField: some View {
        TextField(L10n.t("Keyword"), text: $keywordText)
            .textFieldStyle(.roundedBorder)
            .disableAutocorrection(true)
    }

    private var saveKeywordsButton: some View {
        Button {
            let inputs = keywordText
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            model.setKeywordsForPhoto(photo.id, inputs: inputs)
            keywordText = inputs.joined(separator: ", ")
        } label: {
            Image(systemName: "checkmark")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .accessibilityLabel(Text(L10n.t("Save Keywords")))
    }

    private var ratingControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                Text(L10n.t("Rating"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                ratingButtons
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Rating"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ratingButtons
            }
        }
    }

    private var ratingButtons: some View {
        HStack(spacing: 0) {
            ForEach(0...5, id: \.self) { value in
                Button {
                    model.setRatingForSelectedPhoto(value)
                } label: {
                    Image(systemName: value == 0 ? "xmark.circle" : "star.fill")
                        .foregroundStyle(value > photo.rating ? Color.secondary : Color.yellow)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 30, minHeight: 30)
                .accessibilityLabel(Text("\(L10n.t("Rating")) \(value)"))
            }
        }
    }

    private var flagControl: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                Text(L10n.t("Flag"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                flagMenu
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Flag"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                flagMenu
            }
        }
    }

    private var flagMenu: some View {
        Menu {
            ForEach(PhotoFlag.allCases, id: \.self) { flag in
                Button {
                    model.setFlagForSelectedPhoto(flag)
                } label: {
                    Label(flagTitle(flag), systemImage: photo.flag == flag ? "checkmark" : "")
                }
            }
        } label: {
            Label(flagTitle(photo.flag), systemImage: flagSymbol(photo.flag))
        }
        .controlSize(.small)
    }

    private func flagTitle(_ flag: PhotoFlag) -> String {
        switch flag {
        case .none: return L10n.t("None")
        case .pick: return L10n.t("Pick")
        case .reject: return L10n.t("Reject")
        }
    }

    private func flagSymbol(_ flag: PhotoFlag) -> String {
        switch flag {
        case .none: return "flag"
        case .pick: return "flag.fill"
        case .reject: return "flag.slash"
        }
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
