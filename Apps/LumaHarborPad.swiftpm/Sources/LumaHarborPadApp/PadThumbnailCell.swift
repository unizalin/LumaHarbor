import Localization
import PhotoLibraryCore
import SwiftUI
import UIKit

/// One grid cell: neutral thumbnail, edited badge, filename, capture date —
/// the iPad counterpart to the Mac app's `PhotoGridCell`/`ThumbnailView`
/// (`Sources/LumaHarborApp/Views/ThumbnailView.swift`), using `UIImage`/
/// `Image(uiImage:)` instead of AppKit's `NSImage`. Follows the same
/// cached-then-live-fetch pattern: `provider.cachedThumbnailData(for:)`
/// first (works even while offline), then `provider.thumbnailData(for:
/// sourceURL:isOnline:)` only when a source URL actually resolves.
///
/// The fetch task runs only while the cell is part of the view tree --
/// `.task(id:)` is cancelled by SwiftUI itself once a `LazyVGrid` scrolls
/// the cell out and `ForEach`'s `Identifiable` conformance drops it -- and
/// the cache entry stays pinned for that entire visible lifetime, not just
/// while `load()` itself is in flight. `provider.withVisiblePin(photoID:operation:)`
/// owns the whole pin/load/unpin ordering as one atomic contract, matching
/// the "protect what's on screen, not what's off it" cache contract
/// `ThumbnailProvider.pin(photoID:)` documents, so this cell never composes
/// pin/load/unpin by hand (Codex pre-landing review, Task 7 round -- twice:
/// an earlier version unpinned the moment `load()` returned, via a separate
/// `.onDisappear`-triggered task with no ordering guarantee against `pin`
/// at all; the next version fixed that but ran `pin` and `load` as
/// concurrent `async let` siblings with no guarantee `pin` landed before
/// `load` could decode and store, defeating `DiskCache`'s own "pin before
/// store" contract).
struct PadThumbnailCell: View {
    let photo: PhotoAsset
    let isBatchSelected: Bool
    let isSelectionMode: Bool
    /// Whether this photo's *source* is currently reachable -- `true` for
    /// every App-copy photo (always local by construction), or the
    /// resolved `LibraryFolder.isOnline` for everything else.
    let isOnline: Bool
    let sourceDisplayName: String
    /// `nil` when the source is fully ready; otherwise the same short,
    /// non-color status text the sidebar already shows for this source
    /// (e.g. "Offline", "Read-only", "Needs Access").
    let sourceStatusMessage: String?
    let provider: ThumbnailProvider
    /// Resolves the file this cell should decode from, lazily -- called
    /// only once the cell is actually visible and has no cached bytes
    /// already, not precomputed for every row up front.
    let resolveSourceURL: @Sendable (PhotoAsset) async -> URL?

    @State private var image: UIImage?
    @State private var failureKind: FailureKind?

    private enum FailureKind {
        case offline
        case error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            thumbnail
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    if photo.hasEdits {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption2)
                            .padding(4)
                            .background(.thinMaterial, in: Circle())
                            .padding(4)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isSelectionMode {
                        Image(systemName: isBatchSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(6)
                    }
                }

            Text(photo.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(captionText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        // Global constraint: every interactive element has at least a
        // 44×44 pt hit region -- a cell is always at least this size even
        // at the smallest grid-density preference.
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(isSelectionMode && isBatchSelected ? L10n.t("selected") : ""))
        .task(id: photo.id) {
            await provider.withVisiblePin(photoID: photo.id) {
                await load()
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(uiColor: .quaternarySystemFill))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let failureKind {
                // Never color alone: an icon plus caption text names the
                // exact state (offline vs. a genuine decode/read error).
                VStack(spacing: 4) {
                    Image(systemName: failureKind == .offline ? "wifi.slash" : "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text(failureKind == .offline ? L10n.t("Offline") : L10n.t("Couldn't load"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func load() async {
        image = nil
        failureKind = nil

        // Spec §6.1: an offline source still shows whatever is already
        // cached, and the cache always answers before the drive is ever
        // touched.
        if let cached = await provider.cachedThumbnailData(for: photo.id),
           let decoded = UIImage(data: cached) {
            image = decoded
            return
        }

        if photo.status == .unsupported || photo.status == .failed {
            failureKind = .error
            return
        }
        guard isOnline else {
            failureKind = .offline
            return
        }
        guard let sourceURL = await resolveSourceURL(photo) else {
            failureKind = .error
            return
        }

        do {
            let data = try await provider.thumbnailData(for: photo.id, sourceURL: sourceURL, isOnline: isOnline)
            guard !Task.isCancelled else { return }
            if let decoded = UIImage(data: data) {
                image = decoded
            } else {
                failureKind = .error
            }
        } catch {
            guard !Task.isCancelled else { return }
            failureKind = .error
        }
    }

    private var captionText: String {
        if let message = photo.statusMessage { return message }
        if let sourceStatusMessage { return sourceStatusMessage }
        guard let date = photo.metadata.captureDate else {
            return L10n.t("No capture time")
        }
        return Self.dateFormatter.string(from: date)
    }

    /// Every new visible piece of state this cell can show, joined into one
    /// label: filename, capture date when available, the source's display
    /// name, its connection/error status, and whether the photo has saved
    /// edits -- per Task 7 Step 4's accessibility contract.
    private var accessibilityLabel: String {
        var components = [photo.filename]
        if let date = photo.metadata.captureDate {
            components.append(Self.dateFormatter.string(from: date))
        }
        components.append(sourceDisplayName)
        if let message = photo.statusMessage {
            components.append(message)
        } else if let sourceStatusMessage {
            components.append(sourceStatusMessage)
        }
        if photo.hasEdits {
            components.append(L10n.t("Edited"))
        }
        if isSelectionMode && isBatchSelected {
            components.append(L10n.t("selected"))
        }
        return components.joined(separator: ", ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
