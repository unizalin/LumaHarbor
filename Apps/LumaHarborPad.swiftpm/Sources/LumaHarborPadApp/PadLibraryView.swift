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
        .alert(item: $library.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alertBody(alert)),
                dismissButton: .default(Text(L10n.t("OK")))
            )
        }
    }

    private var content: some View {
        PadLibraryGrid(library: library, editor: editor, services: services)
    }

    private func alertBody(_ alert: EditorAlert) -> String {
        [alert.message, alert.nextStep].compactMap { $0 }.joined(separator: "\n\n")
    }
}
