import AppKit
import PhotoLibraryCore
import Localization
import SwiftUI

/// The browser grid. Cells appear as the scan finds them (spec §6.1).
struct LibraryGridView: View {
    @EnvironmentObject private var model: LibraryViewModel

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 16)]

    var body: some View {
        ScrollView {
            if model.photos.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.photos) { photo in
                        PhotoGridCell(
                            photo: photo,
                            sourceURL: sourceURL(for: photo),
                            isOnline: model.selectedLibrary?.isOnline ?? false,
                            isSelected: model.selectedPhotoID == photo.id,
                            isBatchSelected: model.selectedPhotoIDs.contains(photo.id),
                            provider: model.thumbnailProvider
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Cmd-click adds/removes this photo from the
                            // batch sync target set (Phase 3 Task 3.3)
                            // without opening it; a plain click opens it as
                            // before. `.onTapGesture` reports no modifier
                            // flags of its own, so this reads them directly
                            // -- the standard AppKit way to distinguish a
                            // Cmd-click from a plain one inside a SwiftUI
                            // tap handler.
                            if NSEvent.modifierFlags.contains(.command) {
                                model.toggleMultiSelect(photo.id)
                            } else {
                                model.requestSelectPhoto(photo.id)
                            }
                        }
                        .contextMenu {
                            // Phase 3 Task 3.5: available on any photo,
                            // original or copy -- a copy of a copy still
                            // points its own `variantOf` directly at
                            // whatever was duplicated, not at some "root".
                            Button {
                                Task { await model.duplicateAsVirtualCopy(photo) }
                            } label: {
                                Label(L10n.t("Duplicate as Virtual Copy"), systemImage: "doc.on.doc")
                            }
                            if photo.isVirtualCopy {
                                Button(role: .destructive) {
                                    Task { await model.deleteVirtualCopy(photo) }
                                } label: {
                                    Label(L10n.t("Delete Virtual Copy"), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .navigationTitle(model.selectedLibrary?.displayName ?? "LumaHarbor")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    model.isShowingBatchExportSheet = true
                } label: {
                    Label(L10n.t("Batch Export…"), systemImage: "square.and.arrow.up.on.square")
                }
                .disabled(model.selectedPhotoIDs.isEmpty)
                .help(L10n.t("Export every selected photo"))
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    model.startScan()
                } label: {
                    Label(L10n.t("Rescan"), systemImage: "arrow.clockwise")
                }
                .disabled(!(model.selectedLibrary?.isOnline ?? false))
                .help(L10n.t("Scan this folder again"))
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            if let progress = model.scanProgress, !progress.isFinished {
                ProgressView()
                Text(L10n.t("Scanning for RAW files…"))
                    .foregroundStyle(.secondary)
            } else if model.selectedLibrary?.isOnline == false {
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text(L10n.t("This drive isn't connected"))
                    .font(.headline)
                Text(L10n.t("Reconnect it to browse and edit these photos."))
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.t("No RAW files found in this folder"))
                    .font(.headline)
                Text(L10n.t("LumaHarbor looks for camera RAW files such as Sony .ARW."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sourceURL(for photo: PhotoAsset) -> URL? {
        guard let root = model.selectedLibrary?.rootURL else { return nil }
        return photo.url(inLibraryRootedAt: root)
    }
}
