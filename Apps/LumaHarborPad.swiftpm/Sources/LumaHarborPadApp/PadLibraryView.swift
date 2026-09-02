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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isSidebarPresented = false
    @State private var isAddingSource = false

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                content
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                isSidebarPresented = true
                            } label: {
                                Label(L10n.t("Sources"), systemImage: "sidebar.left")
                            }
                        }
                    }
                    .sheet(isPresented: $isSidebarPresented) {
                        NavigationStack {
                            PadLibrarySidebar(library: library, onAddSource: presentAddSourcePicker, showsOperationOverlay: true)
                                .toolbar {
                                    ToolbarItem(placement: .confirmationAction) {
                                        Button(L10n.t("Close")) {
                                            isSidebarPresented = false
                                        }
                                    }
                                }
                        }
                    }
            } else {
                HStack(spacing: 0) {
                    PadLibrarySidebar(library: library, onAddSource: presentAddSourcePicker, showsOperationOverlay: false)
                        .frame(width: 280)
                    Divider()
                    content
                }
            }
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
