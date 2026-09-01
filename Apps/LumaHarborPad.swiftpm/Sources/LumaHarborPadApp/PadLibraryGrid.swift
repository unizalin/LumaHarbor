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

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.t("No RAW files found in this folder"), systemImage: "photo.on.rectangle.angled")
        } description: {
            Text(L10n.t("Add a photo folder"))
        } actions: {
            Button(L10n.t("Add Source"), action: onAddSource)
                .frame(minWidth: 44, minHeight: 44)
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
        PadThumbnailCell(
            photo: photo,
            isOnline: context.isOnline,
            sourceDisplayName: context.displayName,
            sourceStatusMessage: context.statusMessage,
            provider: services.thumbnailProvider,
            resolveSourceURL: { photo in await services.thumbnailSourceURL(for: photo) }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await open(photo) }
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
