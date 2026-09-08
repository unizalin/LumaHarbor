import AdjustmentUI
import EditorCore
import Localization
import PhotoLibraryCore
import SwiftUI

/// The adaptive multi-source library container (Task 6): a permanently
/// visible `PadLibrarySidebar` at regular width, the same sidebar
/// presented from a toolbar button at compact width.
///
/// The content area is `PadLibraryGrid` (Task 7): the paged thumbnail
/// grid, with its own toolbar (search, sort, grid-density) mounted across
/// every `LibraryBrowserSession.loadState`, and `restoreGridPosition()`
/// scrolling back to the exact photo the user opened once the editor
/// closes.
struct PadLibraryView: View {
    @ObservedObject var library: PadLibraryModel
    @ObservedObject var editor: PadEditorModel
    let services: PadAppServices
    /// Scene-scoped, owned by `PadRootView` -- see that type's own comment
    /// on why this lives above the library/editor route switch instead of
    /// as `@State` here. Only `isSidebarVisible` has a wired effect so far:
    /// whether the persistent source column (Expanded/Wide) is currently
    /// collapsed. Compact/Standard's sidebar sheet stays view-local
    /// (`isSidebarPresented` below), since a modal's momentary presentation
    /// isn't a workspace preference worth remembering across a route switch.
    @Binding var workspaceState: PadWorkspaceState
    @State private var isSidebarPresented = false
    @State private var isAddingSource = false

    var body: some View {
        GeometryReader { proxy in
            workspace(forWidth: proxy.size.width)
        }
        .overlay {
            if let overlay = activeLibraryOverlay {
                PadLibraryProgressOverlay(
                    title: overlay.title,
                    message: overlay.message
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: activeLibraryOverlay != nil)
        .task {
            library.start()
            library.restoreGridPosition()
        }
        .sheet(isPresented: $isAddingSource) {
            FolderDocumentPicker(
                onPick: { url in
                    isAddingSource = false
                    Task {
                        await addSourceFromPickedFolder(at: url)
                    }
                },
                onCancel: {
                    isAddingSource = false
                }
            )
        }
        .alert(item: $library.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alertBody(alert)),
                dismissButton: .default(Text(L10n.t("OK")))
            )
        }
    }

    /// `content` (`PadLibraryGrid`, holding its own Select-mode, filter-sheet,
    /// and photo-opening `@State`) must render at the *same* position in the
    /// view tree across every width profile and every sidebar toggle --
    /// never nested separately inside more than one branch of a `switch`.
    /// SwiftUI gives every branch of a `switch`/`if-else` its own distinct
    /// identity path (`_ConditionalContent`'s `.first`/`.second`), so a
    /// `content` built inside the `.overlay` case and a *different*
    /// `content` built inside a `.persistent` case are, to SwiftUI, two
    /// unrelated views -- crossing a width breakpoint (rotation, Stage
    /// Manager resize) would tear the first down and mount the second fresh,
    /// silently dropping `isSelectMode`/`isShowingFilters`/`openingPhotoID`
    /// even though `library`'s own selection and scroll-anchor state (an
    /// `@ObservedObject`, not view-local) survives regardless. Building
    /// `content` exactly once, as the trailing element of one `HStack`, with
    /// only its *leading sidebar sibling* appearing/disappearing via `if`,
    /// keeps `content` at one stable position no matter which profile or
    /// sidebar-visibility state produced this render.
    @ViewBuilder
    private func workspace(forWidth width: CGFloat) -> some View {
        let layout = PadWorkspaceLayoutPolicy.layout(forWidth: width)
        let showsPersistentSidebar = self.showsPersistentSidebar(for: layout.librarySidebar)

        HStack(spacing: 0) {
            if showsPersistentSidebar && workspaceState.isSidebarVisible {
                PadLibrarySidebar(
                    library: library,
                    onAddSource: presentAddSourcePicker,
                    showsOperationOverlay: false
                )
                .frame(width: sidebarWidth(for: layout.profile))
                Divider()
            }
            content
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    if showsPersistentSidebar {
                        workspaceState.isSidebarVisible.toggle()
                    } else {
                        isSidebarPresented = true
                    }
                } label: {
                    Label(L10n.t("Sources"), systemImage: "sidebar.left")
                }
                .frame(minWidth: 44, minHeight: 44)
            }
        }
        .sheet(isPresented: $isSidebarPresented) {
            sidebarSheet
        }
    }

    /// A plain (non-`@ViewBuilder`) function -- inlining this `switch` back
    /// into `workspace(forWidth:)` would make the Swift compiler try to
    /// interpret each `Bool`-assigning case as its own view-producing
    /// branch (result builders apply to every statement in an
    /// `@ViewBuilder` function body, not just its trailing expression),
    /// which fails to type-check since `Bool` doesn't conform to `View`.
    private func showsPersistentSidebar(for sidebar: PadLibrarySidebarPresentation) -> Bool {
        switch sidebar {
        case .overlay:
            return false
        case .persistent:
            return true
        case .persistentWithDetails:
            return true
        }
    }

    private var sidebarSheet: some View {
        NavigationStack {
            PadLibrarySidebar(
                library: library,
                onAddSource: presentAddSourcePicker,
                showsOperationOverlay: true
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Close")) {
                        isSidebarPresented = false
                    }
                }
            }
        }
    }

    private func sidebarWidth(for profile: PadWorkspaceWidthProfile) -> CGFloat {
        profile == .wide ? 300 : 280
    }

    private var content: some View {
        PadLibraryGrid(library: library, editor: editor, services: services, onAddSource: presentAddSourcePicker)
    }

    private var hasActiveSourceScan: Bool {
        library.sourceProgress.values.contains { progress in
            switch progress.phase {
            case .scanning: return true
            case .finished, .failed: return false
            }
        }
    }

    /// The single global operation overlay, derived from `library
    /// .operationState` (Task 1) first -- a non-idle `operationState` always
    /// wins and gets its own distinct title/message, never a shared generic
    /// "Loading…" string. `sourceProgress` is only consulted as a fallback
    /// while `operationState` is `.idle`, so a rescan kicked off from the
    /// sidebar's context menu (which doesn't go through `addSource`, the
    /// only producer of `.addingSource`) still shows visible scan feedback
    /// here.
    private var activeLibraryOverlay: (title: String, message: String)? {
        switch library.operationState {
        case .addingSource:
            return (
                L10n.t("Adding source…"),
                L10n.t("LumaHarbor is registering this folder without moving or changing your RAW files.")
            )
        case .scanningSource:
            return (
                L10n.t("Scanning source…"),
                L10n.t("Refreshing the library index without changing your RAW files.")
            )
        case .reconnectingSource:
            return (
                L10n.t("Reconnecting source…"),
                L10n.t("Checking this folder matches the original source.")
            )
        case .removingSource:
            return (
                L10n.t("Removing source…"),
                L10n.t("RAW files and sidecars stay exactly where they are.")
            )
        case .idle:
            guard hasActiveSourceScan else { return nil }
            return (
                L10n.t("Scanning source…"),
                L10n.t("Refreshing the library index without changing your RAW files.")
            )
        }
    }

    private func presentAddSourcePicker() {
        isSidebarPresented = false
        isAddingSource = true
    }

    /// Adds `url` as a new source, then -- if it actually landed in
    /// `library.sources` (an error leaves it unchanged) -- kicks off one
    /// scan for it, so the folder just picked doesn't sit permanently
    /// empty until some later, unrelated trigger scans it.
    private func addSourceFromPickedFolder(at url: URL) async {
        let scope = ScopedFolderAccess(url: url, startAccessing: true)
        defer { scope.stop() }
        await addSource(at: url)
    }

    private func addSource(at url: URL) async {
        let idsBefore = Set(library.sources.map(\.id))
        await library.addSource(at: url, sourceKind: .externalFolder)
        guard let newSource = library.sources.first(where: { !idsBefore.contains($0.id) }) else { return }
        library.scanSource(newSource.id)
    }

    private func alertBody(_ alert: EditorAlert) -> String {
        [alert.message, alert.nextStep].compactMap { $0 }.joined(separator: "\n\n")
    }
}
