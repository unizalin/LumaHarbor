import PhotoLibraryCore
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
                            provider: model.thumbnailProvider
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selectedPhotoID = photo.id
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
                    model.startScan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(!(model.selectedLibrary?.isOnline ?? false))
                .help("Scan this folder again")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            if let progress = model.scanProgress, !progress.isFinished {
                ProgressView()
                Text("Scanning for RAW files…")
                    .foregroundStyle(.secondary)
            } else if model.selectedLibrary?.isOnline == false {
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text("This drive isn't connected")
                    .font(.headline)
                Text("Reconnect it to browse and edit these photos.")
                    .foregroundStyle(.secondary)
            } else {
                Text("No RAW files found in this folder")
                    .font(.headline)
                Text("LumaHarbor looks for camera RAW files such as Sony .ARW.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sourceURL(for photo: PhotoAsset) -> URL? {
        guard let root = model.selectedLibrary?.rootURL else { return nil }
        return photo.url(inLibraryRootedAt: root)
    }
}
