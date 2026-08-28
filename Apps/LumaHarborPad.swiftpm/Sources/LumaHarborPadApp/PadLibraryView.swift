import EditorCore
import Localization
import PhotoLibraryCore
import SwiftUI

/// The adaptive multi-source library container (Task 6): a permanently
/// visible `PadLibrarySidebar` at regular width, the same sidebar
/// presented from a toolbar button at compact width.
///
/// The content area here is deliberately minimal -- a plain, alphabetical
/// filename list, not the paged thumbnail grid. That grid
/// (`PadLibraryGrid`), along with search, sorting and restoring the exact
/// scroll position on return from the editor, is Task 7's own deliverable.
/// What this view does prove, end to end, is the thing Task 6 is actually
/// about: picking a photo here opens it in `PadEditorModel`, and
/// `PadRootView`'s routing correctly switches back once it's closed.
struct PadLibraryView: View {
    @ObservedObject var library: PadLibraryModel
    @ObservedObject var editor: PadEditorModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isSidebarPresented = false

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
                            PadLibrarySidebar(library: library)
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
                    PadLibrarySidebar(library: library)
                        .frame(width: 280)
                    Divider()
                    content
                }
            }
        }
        .task {
            library.start()
            library.restoreGridPosition()
        }
    }

    @ViewBuilder
    private var content: some View {
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
                ContentUnavailableView(
                    L10n.t("No RAW files found in this folder"),
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(L10n.t("Add a photo folder"))
                )
            } else {
                photoList
            }
        }
    }

    private var photoList: some View {
        List(library.photos) { photo in
            Button {
                Task { await open(photo) }
            } label: {
                Text(photo.filename)
            }
            .onAppear {
                if photo.id == library.photos.last?.id {
                    library.loadNextPage()
                }
            }
        }
        .alert(item: $library.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alertBody(alert)),
                dismissButton: .default(Text(L10n.t("OK")))
            )
        }
    }

    /// Resolves `photo` through `library` (Task 5's gating for offline /
    /// needs-authorization sources) and, only once that succeeds, hands the
    /// result to `editor` -- this is what actually drives `PadRootView`'s
    /// route switch to `PadEditorView`.
    private func open(_ photo: PhotoAsset) async {
        guard let asset = await library.openAsset(for: photo) else { return }
        editor.openLibraryAsset(asset)
    }

    private func alertBody(_ alert: EditorAlert) -> String {
        [alert.message, alert.nextStep].compactMap { $0 }.joined(separator: "\n\n")
    }
}
