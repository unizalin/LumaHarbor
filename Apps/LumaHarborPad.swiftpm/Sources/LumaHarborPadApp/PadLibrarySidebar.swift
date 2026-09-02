import EditorCore
import Localization
import PhotoLibraryCore
import SwiftUI
import UniformTypeIdentifiers

/// The library's source/scope picker (Task 6): every smart scope (`.all`,
/// `.recentlyEdited`, `.appStorage`) plus every known source, bound
/// directly to `PadLibraryModel.selection`. Shown as a permanently visible
/// column at regular width and presented from a toolbar button at compact
/// width — see `PadLibraryView` for which.
///
/// Per-source scan progress display is deliberately not part of this task —
/// that belongs with Task 7's own grid work. Task 8 adds the other
/// per-source lifecycle commands (remove/reconnect/rescan), every one of
/// them calling straight into `library` (an `EditorCore.LibraryBrowserSession`)
/// rather than any filesystem API of this view's own: removing only ever
/// forgets the source locally (`LibraryBrowserSession.removeSource(_:)` →
/// `PhotoLibraryService.removeLibrary(id:)`, which never touches the source
/// root), reconnecting re-verifies the folder's identity server-side
/// (`relinkSource(_:to:)` → `PhotoLibraryService.relink(libraryID:to:)`), and
/// rescanning reuses the exact same bounded scan (`scanSource(_:)`) the
/// "just added" sweep already used.
struct PadLibrarySidebar: View {
    @ObservedObject var library: PadLibraryModel
    let onAddSource: () -> Void
    /// The source a remove confirmation is currently pending for. Non-nil
    /// drives `.confirmationDialog` below; set back to `nil` on every path
    /// out (confirm, cancel, or the dialog's own dismiss).
    @State private var pendingRemoval: LibraryFolder?
    /// The source currently being removed from LumaHarbor's local library
    /// records. Non-nil keeps a visible progress overlay mounted after the
    /// destructive confirmation so the UI never looks inert while the
    /// bookmark/index store is being updated.
    @State private var removingSourceID: LibraryID?
    /// The source currently being reconnected after the user picked a new
    /// folder. Non-nil keeps progress visible while core validates the
    /// selected folder's identity before attaching it to the existing
    /// `LibraryID`.
    @State private var reconnectingSourceID: LibraryID?
    /// The source a folder picker was opened to reconnect. Non-nil drives
    /// its own `.fileImporter`, distinct from `isAddingSource`'s.
    @State private var relinkTarget: LibraryFolder?

    var body: some View {
        List {
            Section(L10n.t("Library")) {
                smartScopeRow(L10n.t("All"), scope: .all, systemImage: "photo.on.rectangle")
                smartScopeRow(L10n.t("Recently Edited"), scope: .recentlyEdited, systemImage: "clock")
                smartScopeRow(L10n.t("App Copies"), scope: .appStorage, systemImage: "square.and.arrow.down.on.square")
            }

            Section(L10n.t("Sources")) {
                if library.sources.isEmpty {
                    Text(L10n.t("No sources yet"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(library.sources) { source in
                        sourceRow(source)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingRemoval = source
                                } label: {
                                    Label(L10n.t("Remove from LumaHarbor"), systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                sourceContextMenuItems(for: source)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(L10n.t("Library"))
        .overlay {
            if let progress = activeLifecycleProgress {
                PadLibraryProgressOverlay(
                    title: progress.title,
                    message: progress.message
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: removingSourceID)
        .animation(.easeInOut(duration: 0.2), value: reconnectingSourceID)
        .toolbar {
            ToolbarItem {
                Button {
                    onAddSource()
                } label: {
                    Label(L10n.t("Add Source"), systemImage: "plus")
                }
                .frame(minWidth: 44, minHeight: 44)
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { relinkTarget != nil },
                set: { isPresented in if !isPresented { relinkTarget = nil } }
            ),
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard let target = relinkTarget else { return }
            relinkTarget = nil
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                reconnectingSourceID = target.id
                Task {
                    await library.relinkSource(target.id, to: url)
                    await MainActor.run {
                        reconnectingSourceID = nil
                    }
                }
            case .failure(let error):
                let nsError = error as NSError
                guard nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError else {
                    library.alert = EditorAlert(
                        title: L10n.t("Couldn't reconnect this source"),
                        message: L10n.t("Couldn't read the file."),
                        nextStep: nil
                    )
                    return
                }
            }
        }
        // Spec/plan requirement: this text must say the RAW files and
        // sidecars remain untouched -- removal only ever forgets the source
        // locally (`PhotoLibraryService.removeLibrary(id:)`'s own doc
        // comment: it "must never touch the source root itself").
        .confirmationDialog(
            L10n.t("Remove this source?"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { isPresented in if !isPresented { pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { source in
            Button(L10n.t("Remove from LumaHarbor"), role: .destructive) {
                pendingRemoval = nil
                removingSourceID = source.id
                Task {
                    await library.removeSource(source.id)
                    await MainActor.run {
                        removingSourceID = nil
                    }
                }
            }
            Button(L10n.t("Cancel"), role: .cancel) {
                pendingRemoval = nil
            }
        } message: { _ in
            Text(
                L10n.t("LumaHarbor only forgets this source here. The RAW files and sidecars stay exactly where they are.")
                    + " " + L10n.t("The source's .lumaharbor manifest is not deleted either.")
            )
        }
    }

    private var activeLifecycleProgress: (title: String, message: String)? {
        if reconnectingSourceID != nil {
            return (
                L10n.t("Reconnecting source…"),
                L10n.t("Checking this folder matches the original source.")
            )
        }
        if removingSourceID != nil {
            return (
                L10n.t("Removing source…"),
                L10n.t("RAW files stay exactly where they are.")
            )
        }
        return nil
    }

    @ViewBuilder
    private func sourceContextMenuItems(for source: LibraryFolder) -> some View {
        Button {
            library.scanSource(source.id)
        } label: {
            Label(L10n.t("Rescan"), systemImage: "arrow.clockwise")
        }
        if needsReconnection(source) {
            Button {
                relinkTarget = source
            } label: {
                Label(L10n.t("Reconnect…"), systemImage: "arrow.triangle.2.circlepath")
            }
        }
        Button(role: .destructive) {
            pendingRemoval = source
        } label: {
            Label(L10n.t("Remove from LumaHarbor"), systemImage: "trash")
        }
    }

    private func needsReconnection(_ source: LibraryFolder) -> Bool {
        switch source.connectionState {
        case .offline, .needsAuthorization: return true
        case .ready, .readOnly: return false
        }
    }

    private func smartScopeRow(_ title: String, scope: LibraryScope, systemImage: String) -> some View {
        let selection = LibrarySelection.smart(scope)
        return Button {
            library.select(selection)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .listRowBackground(library.selection == selection ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    private func sourceRow(_ source: LibraryFolder) -> some View {
        let selection = LibrarySelection.source(source.id)
        return Button {
            library.select(selection)
        } label: {
            HStack {
                Label(source.displayName, systemImage: sourceIcon(for: source))
                Spacer()
                if let message = statusMessage(for: source) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(library.selection == selection ? Color.accentColor.opacity(0.15) : Color.clear)
        .accessibilityLabel(Text(accessibilityLabel(for: source)))
    }

    private func sourceIcon(for source: LibraryFolder) -> String {
        switch source.connectionState {
        case .ready, .readOnly: return "externaldrive"
        case .offline: return "externaldrive.badge.xmark"
        case .needsAuthorization: return "lock"
        }
    }

    private func statusMessage(for source: LibraryFolder) -> String? {
        if let progress = library.sourceProgress[source.id] {
            switch progress.phase {
            case .scanning: return L10n.t("Scanning…")
            case .failed:
                // A scan that already indexed or individually failed some
                // photos left usable, partial results behind -- distinct
                // from a scan that never got anywhere, which the sidebar
                // must not soften into the same "partial" wording.
                return progress.indexedCount > 0 || progress.failedCount > 0
                    ? L10n.t("Partial issue")
                    : L10n.t("Scan problem")
            case .finished: break
            }
        }
        switch source.connectionState {
        case .ready: return nil
        case .readOnly: return L10n.t("Read-only")
        case .offline: return L10n.t("Offline")
        case .needsAuthorization: return L10n.t("Needs Access")
        }
    }

    private func accessibilityLabel(for source: LibraryFolder) -> String {
        [source.displayName, statusMessage(for: source)].compactMap { $0 }.joined(separator: ", ")
    }
}
