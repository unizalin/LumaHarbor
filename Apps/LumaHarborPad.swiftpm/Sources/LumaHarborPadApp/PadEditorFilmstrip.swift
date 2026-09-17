import EditorCore
import Localization
import PhotoLibraryCore
import SwiftUI

struct PadEditorFilmstrip: View {
        let photos: [PhotoAsset]
        let currentPhotoID: PhotoID?
        @ObservedObject var library: PadLibraryModel
        let services: PadAppServices
        let onSelect: (PhotoAsset) -> Void

        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(photos) { photo in
                        let folder = library.folder(for: photo.libraryID)
                        PadThumbnailCell(
                            photo: photo,
                            isBatchSelected: false,
                            isSelectionMode: false,
                            isOnline: photo.libraryID == .appStorage || folder?.isOnline == true,
                            sourceDisplayName: folder?.displayName ?? L10n.t("This iPad"),
                            sourceStatusMessage: filmstripStatus(for: folder),
                            provider: services.thumbnailProvider,
                            compact: true,
                            resolveSourceURL: { photo in
                                await services.thumbnailSourceURL(for: photo)
                            }
                        )
                        .frame(width: 116, height: 100)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    photo.id == currentPhotoID ? Color.accentColor : .clear,
                                    lineWidth: 3
                                )
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(photo) }
                        .accessibilityAddTraits(photo.id == currentPhotoID ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(height: 116)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Divider() }
            .accessibilityLabel(Text(L10n.t("Filmstrip")))
        }

        private func filmstripStatus(for folder: LibraryFolder?) -> String? {
            guard let folder else { return nil }
            switch folder.connectionState {
            case .ready: return nil
            case .readOnly: return L10n.t("Read-only")
            case .offline: return L10n.t("Offline")
            case .needsAuthorization: return L10n.t("Needs access")
            }
        }
    }

