import AppKit
import PhotoLibraryCore
import Localization
import SwiftUI

/// The browser grid. Cells appear as the scan finds them (spec §6.1).
struct LibraryGridView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @State private var isShowingAdvancedFilters = false
    @State private var editingKeywordsPhoto: PhotoAsset?

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: model.gridDensity.minimumWidth, maximum: model.gridDensity.maximumWidth),
            spacing: 16
        )]
    }

    var body: some View {
        ScrollView {
            if model.visiblePhotos.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.visiblePhotos) { photo in
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
                            if model.isSelecting {
                                if NSEvent.modifierFlags.contains(.shift) {
                                    model.selectRange(to: photo.id)
                                } else {
                                    model.toggleMultiSelect(photo.id)
                                }
                            } else if NSEvent.modifierFlags.contains(.command) {
                                model.toggleMultiSelect(photo.id)
                            } else {
                                model.requestSelectPhoto(photo.id)
                            }
                        }
                        .contextMenu {
                            Button {
                                editingKeywordsPhoto = photo
                            } label: {
                                Label(L10n.t("Edit Keywords"), systemImage: "tag")
                            }

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
        .searchable(text: $model.searchText, placement: .toolbar, prompt: Text(L10n.t("Search by filename")))
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if model.isSelecting {
                    Button {
                        model.selectAllVisible()
                    } label: {
                        Label(L10n.t("All"), systemImage: "checkmark.circle")
                    }
                    .help(L10n.t("Select all visible photos"))

                    Text(selectionSummary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    Button {
                        model.editSelectedPhotos()
                    } label: {
                        Label(L10n.t("Edit Selected"), systemImage: "slider.horizontal.3")
                    }
                    .disabled(model.selectedPhotoIDs.isEmpty)

                    Button(role: .destructive) {
                        model.clearSelection()
                    } label: {
                        Label(L10n.t("Clear"), systemImage: "xmark.circle")
                    }
                    .disabled(model.selectedPhotoIDs.isEmpty)

                    Button(L10n.t("Done")) {
                        model.finishSelection()
                    }
                } else {
                    Button {
                        model.beginSelection()
                    } label: {
                        Label(L10n.t("Select"), systemImage: "checkmark.circle")
                    }
                }
            }

            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker(L10n.t("Sort"), selection: $model.sort) {
                        Text(L10n.t("Newest First")).tag(PhotoSort.captureDateDescending)
                        Text(L10n.t("Oldest First")).tag(PhotoSort.captureDateAscending)
                        Text(L10n.t("Filename A-Z")).tag(PhotoSort.filenameAscending)
                        Text(L10n.t("Filename Z-A")).tag(PhotoSort.filenameDescending)
                    }
                } label: {
                    Label(L10n.t("Sort"), systemImage: "arrow.up.arrow.down")
                }
            }

            ToolbarItem(placement: .automatic) {
                Menu {
                    Button {
                        model.clearCatalogFilters()
                    } label: {
                        Label(L10n.t("All Photos"), systemImage: "line.3.horizontal.decrease.circle")
                    }
                    Divider()
                    Menu(L10n.t("Rating")) {
                        Button(L10n.t("Any Rating")) { model.ratingFilter = nil }
                        Button(L10n.t("Unrated")) { model.ratingFilter = .unrated }
                        ForEach(1...5, id: \.self) { value in
                            Button {
                                model.ratingFilter = .exact(value)
                            } label: {
                                Label("\(value)", systemImage: "star.fill")
                            }
                        }
                    }
                    Menu(L10n.t("Flag")) {
                        Button(L10n.t("Any Flag")) { model.flagFilter = nil }
                        Button(L10n.t("Pick")) { model.flagFilter = .pick }
                        Button(L10n.t("Reject")) { model.flagFilter = .reject }
                        Button(L10n.t("No Flag")) { model.flagFilter = PhotoFlag.none }
                    }
                    Menu(L10n.t("Edits")) {
                        Button(L10n.t("Any Edit State")) { model.hasEditsFilter = nil }
                        Button(L10n.t("Has Edits")) { model.hasEditsFilter = true }
                        Button(L10n.t("No Edits")) { model.hasEditsFilter = false }
                    }
                    Divider()
                    Button {
                        isShowingAdvancedFilters = true
                    } label: {
                        Label(L10n.t("Advanced Filters"), systemImage: "slider.horizontal.3")
                    }
                } label: {
                    Label(filterLabel, systemImage: "line.3.horizontal.decrease.circle")
                }
                .help(L10n.t("Filter photos by curation state"))
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    editingKeywordsPhoto = model.selectedPhoto
                } label: {
                    Label(L10n.t("Edit Keywords"), systemImage: "tag")
                }
                .disabled(model.selectedPhoto == nil)
                .help(L10n.t("Edit keywords for the selected photo"))
            }

            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker(L10n.t("Thumbnail Size"), selection: $model.gridDensity) {
                        Text(L10n.t("Compact")).tag(MacGridDensity.compact)
                        Text(L10n.t("Default")).tag(MacGridDensity.standard)
                        Text(L10n.t("Large")).tag(MacGridDensity.large)
                    }
                } label: {
                    Label(L10n.t("Thumbnail Size"), systemImage: "square.grid.2x2")
                }
            }

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
        .sheet(isPresented: $isShowingAdvancedFilters) {
            LibraryFilterSheet()
                .environmentObject(model)
        }
        .sheet(item: $editingKeywordsPhoto) { photo in
            PhotoKeywordEditorSheet(photo: photo) { inputs in
                model.setKeywordsForPhoto(photo.id, inputs: inputs)
            }
        }
    }

    private var selectionSummary: String {
        "\(model.selectedPhotoIDs.count) " + L10n.t("selected")
    }

    private var filterLabel: String {
        let count = [
            model.ratingFilter != nil,
            model.flagFilter != nil,
            model.hasEditsFilter != nil,
            model.formatFilter != nil,
            model.cameraFilter != nil,
            model.lensFilter != nil,
            model.captureDateStartFilter != nil || model.captureDateEndFilter != nil,
            model.keywordFilter != nil
        ].filter { $0 }.count
        return count == 0 ? L10n.t("Filter") : "\(L10n.t("Filter")) (\(count))"
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            if !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text(L10n.t("No photos match this search"))
                    .font(.headline)
                Text(L10n.t("Try a different filename, or clear the search to see all photos."))
                    .foregroundStyle(.secondary)
            } else if let progress = model.scanProgress, !progress.isFinished {
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
