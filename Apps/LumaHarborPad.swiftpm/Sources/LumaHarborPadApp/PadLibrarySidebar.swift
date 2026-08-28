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
/// Per-source scan progress display, and periodically re-scanning an
/// already-known source, are deliberately not part of this task — the
/// sidebar's own row here only triggers `library.scanSource(_:)` once,
/// immediately after a source is newly added, so the folder the user just
/// picked doesn't sit permanently empty. A richer progress UI belongs with
/// Task 7's own grid work.
struct PadLibrarySidebar: View {
    @ObservedObject var library: PadLibraryModel
    @State private var isAddingSource = false

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
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(L10n.t("Library"))
        .toolbar {
            ToolbarItem {
                Button {
                    isAddingSource = true
                } label: {
                    Label(L10n.t("Add Source"), systemImage: "plus")
                }
            }
        }
        .fileImporter(
            isPresented: $isAddingSource,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await addSource(at: url) }
            case .failure(let error):
                // A plain user cancellation must stay silent; any other
                // provider failure needs a safe, actionable alert instead
                // of being swallowed.
                let nsError = error as NSError
                guard nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError else {
                    library.alert = EditorAlert(
                        title: L10n.t("Couldn't add this source"),
                        message: L10n.t("Couldn't read the file."),
                        nextStep: nil
                    )
                    return
                }
            }
        }
    }

    /// Adds `url` as a new source, then -- if it actually landed in
    /// `library.sources` (an error leaves it unchanged) -- kicks off one
    /// scan for it, so the folder just picked doesn't sit permanently
    /// empty until some later, unrelated trigger scans it.
    private func addSource(at url: URL) async {
        let idsBefore = Set(library.sources.map(\.id))
        await library.addSource(at: url, sourceKind: .externalFolder)
        guard let newSource = library.sources.first(where: { !idsBefore.contains($0.id) }) else { return }
        library.scanSource(newSource.id)
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
