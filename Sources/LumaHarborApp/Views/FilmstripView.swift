import PhotoLibraryCore
import Localization
import SwiftUI

/// The strip under the preview. Selecting here is what exercises the
/// stale-preview rules in spec §9, so it stays a plain list of cheap cells.
struct FilmstripView: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 0) {
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
                                model.requestSelectPhoto(photo.id)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .onAppear {
                    scrollToSelection(with: proxy, animated: false)
                }
                .onChange(of: model.photos.map(\.id)) { _, _ in
                    scrollToSelection(with: proxy, animated: false)
                }
                .onChange(of: model.selectedPhotoID) { _, _ in
                    scrollToSelection(with: proxy, animated: true)
                }
            }

            if let selectionSummary {
                Text(selectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 5)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var selectionSummary: String? {
        guard let selectedID = model.selectedPhotoID else { return nil }
        guard let index = model.photos.firstIndex(where: { $0.id == selectedID }) else {
            return L10n.t("Current photo is not in the filtered results")
        }
        let photo = model.photos[index]
        return "\(photo.variantName ?? photo.filename) · \(index + 1)/\(model.photos.count)"
    }

    private func scrollToSelection(with proxy: ScrollViewProxy, animated: Bool) {
        guard
            let selectedID = model.selectedPhotoID,
            model.photos.contains(where: { $0.id == selectedID })
        else { return }

        let scroll = {
            proxy.scrollTo(selectedID, anchor: .center)
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.2), scroll)
        } else {
            scroll()
        }
    }

    private func sourceURL(for photo: PhotoAsset) -> URL? {
        guard let root = model.selectedLibrary?.rootURL else { return nil }
        return photo.url(inLibraryRootedAt: root)
    }
}
