import AppKit
import Localization
import PhotoLibraryCore
import SwiftUI

/// One cached thumbnail.
///
/// Loading lives in the cell rather than the view model so scrolling only ever
/// decodes what is actually on screen (spec §11).
struct ThumbnailView: View {
    let photo: PhotoAsset
    let sourceURL: URL?
    let isOnline: Bool
    let provider: ThumbnailProvider?

    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .quaternarySystemFill))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if didFail {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: photo.id) {
            await load()
        }
    }

    private func load() async {
        guard let provider else { return }
        image = nil
        didFail = false

        // Spec §6.1: an offline library still shows whatever is already cached.
        if let cached = await provider.cachedThumbnailData(for: photo.id),
           let decoded = NSImage(data: cached) {
            image = decoded
            return
        }
        guard isOnline, let sourceURL, photo.status != .unsupported else {
            didFail = photo.status == .unsupported || photo.status == .failed
            return
        }

        do {
            let data = try await provider.thumbnailData(
                for: photo.id,
                sourceURL: sourceURL,
                isOnline: isOnline
            )
            guard !Task.isCancelled else { return }
            image = NSImage(data: data)
            didFail = image == nil
        } catch {
            guard !Task.isCancelled else { return }
            didFail = true
        }
    }
}

/// Grid cell: preview, filename, capture time and failure state (spec §6.1).
struct PhotoGridCell: View {
    let photo: PhotoAsset
    let sourceURL: URL?
    let isOnline: Bool
    let isSelected: Bool
    /// Phase 3 Task 3.3: part of the current batch sync target set (a
    /// Cmd-click), distinct from `isSelected` (the one actually open in the
    /// editor) -- a photo can be both at once.
    let isBatchSelected: Bool
    let provider: ThumbnailProvider?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ThumbnailView(
                photo: photo,
                sourceURL: sourceURL,
                isOnline: isOnline,
                provider: provider
            )
            .frame(height: 150)
            .overlay(alignment: .topTrailing) {
                if photo.hasEdits {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption2)
                        .padding(4)
                        .background(.thinMaterial, in: Circle())
                        .padding(4)
                        .help(L10n.t("This photo has saved adjustments"))
                }
            }
            .overlay(alignment: .topLeading) {
                if isBatchSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(4)
                        .help(L10n.t("Included in the current batch selection"))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // Phase 3 Task 3.5: distinct from the two badges above --
                // this is about the photo's own identity (a virtual copy of
                // some original, sharing its RAW file), not a transient
                // selection/edit state, hence its own corner.
                if photo.isVirtualCopy {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.caption2)
                        .padding(4)
                        .background(.thinMaterial, in: Circle())
                        .padding(4)
                        .help(L10n.t("Virtual copy"))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.clear,
                        lineWidth: 3
                    )
            }

            // Phase 3 Task 3.5: an unnamed copy still falls back to the
            // shared filename -- true, but disambiguated on screen by the
            // badge above, not by a synthesized name this scope doesn't ask
            // for.
            Text(photo.variantName ?? photo.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(statusColor)
                .lineLimit(1)
        }
        .help(photo.statusMessage ?? photo.relativePath)
    }

    private var subtitle: String {
        if let message = photo.statusMessage { return message }
        guard let date = photo.metadata.captureDate else {
            return L10n.t("No capture time")
        }
        return Self.dateFormatter.string(from: date)
    }

    private var statusColor: Color {
        switch photo.status {
        case .unsupported, .needsConfirmation: return .orange
        case .failed: return .red
        case .ready, .pending: return .secondary
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
