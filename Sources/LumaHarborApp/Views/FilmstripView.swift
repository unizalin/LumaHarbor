import PhotoLibraryCore
import SwiftUI

/// The strip under the preview. Selecting here is what exercises the
/// stale-preview rules in spec §9, so it stays a plain list of cheap cells.
struct FilmstripView: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 8) {
                    ForEach(model.photos) { photo in
                        ThumbnailView(
                            photo: photo,
                            sourceURL: sourceURL(for: photo),
                            isOnline: model.selectedLibrary?.isOnline ?? false,
                            provider: model.thumbnailProvider
                        )
                        .frame(width: 120, height: 84)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(
                                    model.selectedPhotoID == photo.id
                                        ? Color.accentColor
                                        : Color.clear,
                                    lineWidth: 3
                                )
                        }
                        .id(photo.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.selectedPhotoID = photo.id
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: model.selectedPhotoID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func sourceURL(for photo: PhotoAsset) -> URL? {
        guard let root = model.selectedLibrary?.rootURL else { return nil }
        return photo.url(inLibraryRootedAt: root)
    }
}
