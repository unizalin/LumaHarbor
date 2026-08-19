import PhotoLibraryCore
import Localization
import SwiftUI

/// Left pane: which folders exist and what state each one is in (spec §6.2).
struct LibrarySidebarView: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Goes through the request API so switching folders can't outrun a
            // pending sidecar write (addendum §3.1).
            List(selection: model.librarySelection) {
                Section(L10n.t("Photo Folders")) {
                    ForEach(model.libraries) { library in
                        LibraryRow(library: library)
                            .tag(library.id)
                            .contextMenu {
                                if !library.isOnline {
                                    Button(L10n.t("Reconnect…")) {
                                        model.presentRelinkPanel(for: library.id)
                                    }
                                }
                                Button(L10n.t("Rescan")) { model.startScan(libraryID: library.id) }
                                    .disabled(!library.isOnline)
                                Divider()
                                Button(L10n.t("Remove from LumaHarbor"), role: .destructive) {
                                    Task { await model.removeLibrary(library.id) }
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            statusFooter
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let library = model.selectedLibrary {
                Text(library.availability.statusMessage)
                    .font(.caption)
                    .foregroundStyle(library.availability == .ready ? .secondary : .primary)

                if !library.isOnline {
                    Button(L10n.t("Reconnect…")) {
                        model.presentRelinkPanel(for: library.id)
                    }
                    .controlSize(.small)
                }
            }

            if let progress = model.scanProgress {
                HStack(spacing: 6) {
                    if !progress.isFinished {
                        ProgressView().controlSize(.small)
                    }
                    Text(progress.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !progress.isFinished {
                        Button(L10n.t("Stop")) { model.cancelScan() }
                            .controlSize(.small)
                    }
                }
            }

            Button(L10n.t("Add Photo Folder…")) {
                model.presentAddFolderPanel()
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

private struct LibraryRow: View {
    let library: LibraryFolder

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: library.isOnline ? "externaldrive.fill" : "externaldrive.badge.xmark")
                .foregroundStyle(library.isOnline ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(library.displayName)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if library.availability == .readOnly {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(L10n.t("Read-only drive — edits can't be saved here"))
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        switch library.availability {
        case .offline: return L10n.t("Offline")
        case .readOnly, .ready:
            return library.photoCount == 1
                ? L10n.t("1 photo")
                : "\(library.photoCount) " + L10n.t("photos")
        }
    }
}
