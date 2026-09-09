import EditorCore
import Localization
import PhotoLibraryCore
import SwiftUI

/// The persisted grid-density preference (Task 7 Step 3): how wide each
/// thumbnail cell targets. A pure rendering choice with no state anything
/// outside this view needs to read or react to, so it's stored directly
/// via `@AppStorage` rather than threaded through `LibraryBrowserSession`
/// -- unlike `PadThumbnailCacheBudget`, which `PadAppServices` itself
/// needs at launch to size the disk cache.
enum PadLibraryGridDensity: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    /// Kept well above the 44 pt minimum hit-target constraint even at
    /// `.small`, since a cell's own tappable area is its thumbnail size.
    var minimumCellWidth: CGFloat {
        switch self {
        case .small: return 100
        case .medium: return 150
        case .large: return 220
        }
    }

    var displayName: String {
        switch self {
        case .small: return L10n.t("Small")
        case .medium: return L10n.t("Medium")
        case .large: return L10n.t("Large")
        }
    }
}

/// The paged thumbnail grid (Task 7): owns its own load-state switch (so
/// its toolbar and search field stay mounted across every `loadState`,
/// including the ~250 ms window between a keystroke and the debounced
/// fetch actually landing), search/sort/grid-density controls in the
/// toolbar, `LazyVGrid` content keyed by `PhotoAsset`'s own stable
/// `PhotoID`-backed `Identifiable` conformance, and a near-end prefetch
/// trigger over `LibraryBrowserSession.loadNextPage()` -- which already
/// deduplicates concurrent/duplicate calls on its own (see its doc
/// comment), so firing this from more than one cell's `onAppear` near the
/// end of the list is always safe.
struct PadLibraryGrid: View {
    @ObservedObject var library: PadLibraryModel
    let editor: PadEditorModel
    let services: PadAppServices
    let onAddSource: () -> Void

    @AppStorage("PadLibraryGridDensity") private var densityRawValue = PadLibraryGridDensity.medium.rawValue
    @State private var openingPhotoID: PhotoID?
    @State private var isSelectMode = false
    @State private var isShowingFilters = false
    @State private var isShowingBatchKeywords = false
    @State private var batchKeywordsText = ""
    @State private var batchMessage: String?

    /// How close to the end of `library.photos` a visible cell must be
    /// before it triggers `loadNextPage()` -- the brief's "last 20 visible
    /// items" prefetch threshold, exactly.
    private static let prefetchThreshold = 20
    private static let minimumOpeningProgressDuration: Duration = .milliseconds(450)

    private var density: PadLibraryGridDensity {
        PadLibraryGridDensity(rawValue: densityRawValue) ?? .medium
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: density.minimumCellWidth, maximum: density.minimumCellWidth + 80), spacing: 16)]
    }

    private var searchBinding: Binding<String> {
        Binding(get: { library.searchText }, set: { library.updateSearchText($0) })
    }

    var body: some View {
        innerContent
            .searchable(text: searchBinding, prompt: Text(L10n.t("Search by filename")))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isSelectMode.toggle()
                    } label: {
                        Label(
                            L10n.t(isSelectMode ? "Done" : "Select"),
                            systemImage: isSelectMode ? "checkmark" : "checkmark.circle"
                        )
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityHint(Text(L10n.t("Select photos for batch actions")))
                }
                ToolbarItem(placement: .primaryAction) { filterMenu }
                ToolbarItem(placement: .primaryAction) { sortMenu }
                ToolbarItem(placement: .primaryAction) { densityMenu }
            }
            .overlay {
                if openingPhotoID != nil {
                    PadLibraryProgressOverlay(
                        title: L10n.t("Preparing photo…"),
                        message: L10n.t("Checking file access before opening the editor.")
                    )
                }
            }
            .animation(.easeInOut(duration: 0.2), value: openingPhotoID)
            .sheet(isPresented: $isShowingFilters) {
                PadLibraryFilterSheet(library: library)
            }
            .sheet(isPresented: $isShowingBatchKeywords) {
                NavigationStack {
                    Form {
                        Section(L10n.t("Keywords")) {
                            TextField(L10n.t("Keyword"), text: $batchKeywordsText)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                            Text(L10n.t("Separate keywords with commas."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle(L10n.t("Keywords"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.t("Cancel")) { isShowingBatchKeywords = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.t("Save")) {
                                isShowingBatchKeywords = false
                                applyKeywordsToSelected()
                            }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !library.selectedPhotoIDs.isEmpty {
                    selectionBar
                }
            }
            .alert(
                L10n.t("Batch action"),
                isPresented: Binding(
                    get: { batchMessage != nil },
                    set: { if !$0 { batchMessage = nil } }
                )
            ) {
                Button(L10n.t("OK"), role: .cancel) { batchMessage = nil }
            } message: {
                Text(batchMessage ?? "")
            }
    }

    @ViewBuilder
    private var innerContent: some View {
        switch library.loadState {
        case .idle, .loadingFirstPage:
            ProgressView(L10n.t("Reading files…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let alert):
            ContentUnavailableView {
                Label(alert.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(alertBody(alert))
            }
        case .loaded, .loadingNextPage:
            if library.photos.isEmpty {
                emptyState
            } else {
                gridScrollView
            }
        }
    }

    /// Which empty-grid copy to show, chosen from `library.selection`'s own
    /// source first -- a specific source's `offline`/`needsAuthorization`
    /// state always wins over every other reason the grid could be empty.
    /// `.smart` (`.all`/`.recentlyEdited`/`.appStorage`) never resolves to a
    /// source here, so an aggregate scope spanning sources in different
    /// states never gets misattributed to just one of them; it falls
    /// through to the generic "no sources"/"no supported RAW" copy instead.
    private var emptyStateContent: (title: String, description: String, systemImage: String, showsAddSource: Bool) {
        if !library.searchText.isEmpty {
            return (
                L10n.t("No photos match this search"),
                L10n.t("Try a different filename, or clear the search to see all photos."),
                "magnifyingglass",
                false
            )
        }
        if let folder = selectedFolder {
            switch folder.connectionState {
            case .offline:
                return (
                    L10n.t("This source is offline"),
                    L10n.t("Connect the drive again, or make the Files location available, then reconnect the source."),
                    "externaldrive.badge.xmark",
                    false
                )
            case .needsAuthorization:
                return (
                    L10n.t("This source needs access"),
                    L10n.t("Choose the original folder again so LumaHarbor can verify it is the same source."),
                    "lock",
                    false
                )
            case .ready, .readOnly:
                return (
                    L10n.t("No supported RAW files found"),
                    L10n.t("This source doesn't contain any RAW files LumaHarbor can open yet."),
                    "photo.on.rectangle.angled",
                    false
                )
            }
        }
        if library.sources.isEmpty {
            return (
                L10n.t("Add a folder to start browsing RAW files"),
                L10n.t("LumaHarbor only reads RAW files in that folder — it never moves, overwrites, or deletes them."),
                "photo.on.rectangle.angled",
                true
            )
        }
        return (
            L10n.t("No supported RAW files found"),
            L10n.t("None of your sources currently contain RAW files LumaHarbor can open."),
            "photo.on.rectangle.angled",
            false
        )
    }

    /// The source `library.selection` currently points at -- `.source` and
    /// `.folder` both resolve to their owning source; every `.smart` scope
    /// is `nil` here, since it draws from more than one source at once.
    private var selectedFolder: LibraryFolder? {
        switch library.selection {
        case .source(let id): return library.folder(for: id)
        case .folder(let id, _): return library.folder(for: id)
        case .smart: return nil
        }
    }

    private var emptyState: some View {
        let content = emptyStateContent
        return ContentUnavailableView {
            Label(content.title, systemImage: content.systemImage)
        } description: {
            Text(content.description)
        } actions: {
            if content.showsAddSource {
                Button(L10n.t("Add Source"), action: onAddSource)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
    }

    /// Editor-return restoration (Task 7 Step 1's "editor return restores
    /// by `PhotoID`"): `ScrollViewReader` lets `scrollToAnchorIfNeeded(_:proxy:)`
    /// actually land the grid on `library.pendingScrollAnchor` once
    /// `library.restoreGridPosition()` has loaded the page containing it --
    /// `ForEach`'s own `PhotoID`-based `Identifiable` conformance is what
    /// `proxy.scrollTo` resolves against, so no extra `.id()` modifier is
    /// needed on each cell (Codex pre-landing review, Task 7 round: the
    /// session-side restoration query was already correct, but nothing
    /// here ever consumed it to actually scroll the view).
    private var gridScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(library.photos) { photo in
                        cell(for: photo)
                    }
                }
                .padding(16)

                if library.loadState == .loadingNextPage {
                    ProgressView(L10n.t("Loading more photos…"))
                        .padding()
                }
            }
            .onAppear {
                scrollToAnchorIfNeeded(photos: library.photos, proxy: proxy)
            }
            .onChange(of: library.photos) { _, photos in
                scrollToAnchorIfNeeded(photos: photos, proxy: proxy)
            }
        }
    }

    /// Scrolls to `library.pendingScrollAnchor` only once it's actually
    /// present in `photos` -- never a blind/empty scroll while the anchor's
    /// page is still loading -- and immediately acknowledges it so a later,
    /// unrelated `photos` change (paging further) never re-triggers the
    /// same scroll.
    private func scrollToAnchorIfNeeded(photos: [PhotoAsset], proxy: ScrollViewProxy) {
        guard let anchor = library.pendingScrollAnchor,
              photos.contains(where: { $0.id == anchor }) else { return }
        proxy.scrollTo(anchor, anchor: .center)
        library.acknowledgeScrollToAnchor()
    }

    @ViewBuilder
    private func cell(for photo: PhotoAsset) -> some View {
        let context = cellContext(for: photo)
        let isBatchSelected = library.selectedPhotoIDs.contains(photo.id)
        PadThumbnailCell(
            photo: photo,
            isBatchSelected: isBatchSelected,
            isSelectionMode: isSelectMode,
            isOnline: context.isOnline,
            sourceDisplayName: context.displayName,
            sourceStatusMessage: context.statusMessage,
            provider: services.thumbnailProvider,
            resolveSourceURL: { photo in await services.thumbnailSourceURL(for: photo) }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectMode {
                library.togglePhotoSelection(photo.id)
            } else {
                Task { await open(photo) }
            }
        }
        .onAppear {
            guard let index = library.photos.firstIndex(where: { $0.id == photo.id }) else { return }
            if index >= library.photos.count - Self.prefetchThreshold {
                library.loadNextPage()
            }
        }
    }

    /// Resolves `photo` through `library` (Task 5's gating for offline /
    /// needs-authorization sources) and, only once that succeeds, hands the
    /// result to `editor` -- this is what actually drives `PadRootView`'s
    /// route switch to `PadEditorView`.
    private func open(_ photo: PhotoAsset) async {
        openingPhotoID = photo.id
        async let minimumVisibleDelay: Void = sleepForMinimumOpeningProgressDuration()
        let asset = await library.openAsset(for: photo)
        await minimumVisibleDelay
        openingPhotoID = nil
        guard let asset else { return }
        editor.openLibraryAsset(asset)
    }

    private func sleepForMinimumOpeningProgressDuration() async {
        try? await Task.sleep(for: Self.minimumOpeningProgressDuration)
    }

    /// A photo's cell needs its *source's* connection state, not just its
    /// own `PhotoStatus` -- an App-copy photo has no entry in `sources` at
    /// all (see `LibraryBrowserSession.folder(for:)`'s own note on this)
    /// and is always locally reachable by construction.
    private func cellContext(for photo: PhotoAsset) -> (isOnline: Bool, displayName: String, statusMessage: String?) {
        guard let folder = library.folder(for: photo.libraryID) else {
            return (true, L10n.t("App Copies"), nil)
        }
        return (folder.isOnline, folder.displayName, sourceStatusMessage(for: folder))
    }

    private func sourceStatusMessage(for folder: LibraryFolder) -> String? {
        switch folder.connectionState {
        case .ready: return nil
        case .readOnly: return L10n.t("Read-only")
        case .offline: return L10n.t("Offline")
        case .needsAuthorization: return L10n.t("Needs Access")
        }
    }

    private var sortMenu: some View {
        Menu {
            sortButton(.captureDateDescending, title: L10n.t("Newest First"))
            sortButton(.captureDateAscending, title: L10n.t("Oldest First"))
            sortButton(.filenameAscending, title: L10n.t("Filename (A–Z)"))
            sortButton(.filenameDescending, title: L10n.t("Filename (Z–A)"))
        } label: {
            Label(L10n.t("Sort"), systemImage: "arrow.up.arrow.down")
        }
        .frame(minWidth: 44, minHeight: 44)
        .disabled(library.isSortFixedByScope)
        .accessibilityHint(
            Text(library.isSortFixedByScope ? L10n.t("Recently Edited is always sorted by most recently edited.") : "")
        )
    }

    private func sortButton(_ sort: PhotoSort, title: String) -> some View {
        Button {
            library.setSort(sort)
        } label: {
            if library.sort == sort {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var filterMenu: some View {
        Menu {
            Button {
                library.setRatingFilter(nil)
            } label: {
                Label(L10n.t("Any Rating"), systemImage: library.ratingFilter == nil ? "checkmark" : "")
            }
            Button {
                library.setRatingFilter(.unrated)
            } label: {
                Label(L10n.t("Unrated"), systemImage: library.ratingFilter == .unrated ? "checkmark" : "")
            }
            ForEach(1...5, id: \.self) { value in
                Button {
                    library.setRatingFilter(.exact(value))
                } label: {
                    Label(
                        "\(L10n.t("Rating")) \(value)",
                        systemImage: library.ratingFilter == .exact(value) ? "checkmark" : ""
                    )
                }
            }

            Divider()
            Button {
                library.setFlagFilter(nil)
            } label: {
                Label(L10n.t("Any Flag"), systemImage: library.flagFilter == nil ? "checkmark" : "")
            }
            Button {
                library.setFlagFilter(.pick)
            } label: {
                Label(L10n.t("Pick"), systemImage: library.flagFilter == .pick ? "checkmark" : "")
            }
            Button {
                library.setFlagFilter(.reject)
            } label: {
                Label(L10n.t("Reject"), systemImage: library.flagFilter == .reject ? "checkmark" : "")
            }
            Button {
                library.setFlagFilter(PhotoFlag.none)
            } label: {
                Label(L10n.t("No Flag"), systemImage: library.flagFilter == PhotoFlag.none ? "checkmark" : "")
            }

            Divider()
            Button {
                library.setHasEditsFilter(library.hasEditsFilter == true ? nil : true)
            } label: {
                Label(L10n.t("Edited"), systemImage: library.hasEditsFilter == true ? "checkmark" : "")
            }
            Button {
                isShowingFilters = true
            } label: {
                Label(L10n.t("Advanced Filters"), systemImage: "slider.horizontal.3")
            }
            Button {
                library.clearCatalogFilters()
            } label: {
                Label(L10n.t("Clear"), systemImage: "xmark.circle")
            }
        } label: {
            Label(L10n.t("Filter"), systemImage: "line.3.horizontal.decrease.circle")
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityHint(Text(L10n.t("Filter photos by curation state")))
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Label(
                "\(library.selectedPhotoIDs.count) \(L10n.t("selected"))",
                systemImage: "checkmark.circle.fill"
            )
            .lineLimit(1)

            Spacer(minLength: 8)

            Button(L10n.t("Select All")) {
                library.selectAllVisiblePhotos()
            }
            .frame(minWidth: 44, minHeight: 44)

            Button(L10n.t("Clear")) {
                library.clearPhotoSelection()
                isSelectMode = false
            }
            .frame(minWidth: 44, minHeight: 44)

            Menu {
                Menu {
                    ForEach(0...5, id: \.self) { rating in
                        Button {
                            applyRatingToSelected(rating)
                        } label: {
                            Label(
                                rating == 0 ? L10n.t("None") : "\(rating)",
                                systemImage: rating == 0 ? "xmark.circle" : "star.fill"
                            )
                        }
                    }
                } label: {
                    Label(L10n.t("Rating"), systemImage: "star")
                }

                Menu {
                    ForEach(PhotoFlag.allCases, id: \.self) { flag in
                        Button {
                            applyFlagToSelected(flag)
                        } label: {
                            Label(flagTitle(flag), systemImage: flagSymbol(flag))
                        }
                    }
                } label: {
                    Label(L10n.t("Flag"), systemImage: "flag")
                }

                Button {
                    isShowingBatchKeywords = true
                } label: {
                    Label(L10n.t("Keywords"), systemImage: "tag")
                }

                Divider()
                Button {
                    createVirtualCopies()
                } label: {
                    Label(L10n.t("Create virtual copies"), systemImage: "plus.square.on.square")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text(L10n.t("Batch actions")))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    private func createVirtualCopies() {
        let selected = library.photos.filter { library.selectedPhotoIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        Task {
            var created = 0
            for photo in selected {
                do {
                    _ = try await services.libraryService.createVirtualCopy(of: photo)
                    created += 1
                } catch {
                    // Keep the batch best-effort: one offline/read-only item
                    // must not hide copies that were already created.
                }
            }
            library.clearPhotoSelection()
            isSelectMode = false
            library.refresh()
            batchMessage = created == selected.count
                ? String(format: L10n.t("Created %d virtual copies."), created)
                : String(format: L10n.t("Created %d of %d virtual copies."), created, selected.count)
        }
    }

    private func applyRatingToSelected(_ rating: Int) {
        applyToSelected { photoID in
            await services.batchCoordinator.setRating(rating, for: photoID)
        }
    }

    private func applyFlagToSelected(_ flag: PhotoFlag) {
        applyToSelected { photoID in
            await services.batchCoordinator.setFlag(flag, for: photoID)
        }
    }

    private func applyKeywordsToSelected() {
        let inputs = batchKeywordsText
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        applyToSelected { photoID in
            await services.batchCoordinator.setKeywords(inputs, for: photoID)
        }
    }

    private func applyToSelected(
        _ operation: @escaping (PhotoID) async -> Bool
    ) {
        let selected = library.selectedPhotoIDs
        guard !selected.isEmpty else { return }
        Task {
            var succeeded = 0
            for photoID in selected {
                if await operation(photoID) {
                    succeeded += 1
                }
            }
            let key = succeeded == selected.count
                ? "Updated %d photos."
                : "Updated %d of %d photos."
            batchMessage = succeeded == selected.count
                ? String(format: L10n.t(key), succeeded)
                : String(format: L10n.t(key), succeeded, selected.count)
        }
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

    private var densityMenu: some View {
        Menu {
            ForEach(PadLibraryGridDensity.allCases) { option in
                Button {
                    densityRawValue = option.rawValue
                } label: {
                    if density == option {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            Label(L10n.t("Thumbnail Size"), systemImage: "square.grid.2x2")
        }
        .frame(minWidth: 44, minHeight: 44)
    }

    private func alertBody(_ alert: EditorAlert) -> String {
        [alert.message, alert.nextStep].compactMap { $0 }.joined(separator: "\n\n")
    }
}
