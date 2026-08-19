import Foundation
import Localization

/// A photo folder the user has authorised, as the app sees it at runtime.
public struct LibraryFolder: Identifiable, Equatable, Sendable {
    public let id: LibraryID
    public var displayName: String
    public var rootURL: URL
    /// Path recorded when the folder was added, shown when it goes missing.
    public var lastKnownPath: String
    /// `false` when the SSD is unplugged. Spec §10: stay browsable from cache.
    public var isOnline: Bool
    /// `false` for a locked or read-only volume — browsing is allowed, saving
    /// is not (spec §10).
    public var isWritable: Bool
    public var lastScanAt: Date?
    public var photoCount: Int

    public init(
        id: LibraryID = LibraryID(),
        displayName: String,
        rootURL: URL,
        lastKnownPath: String? = nil,
        isOnline: Bool = true,
        isWritable: Bool = true,
        lastScanAt: Date? = nil,
        photoCount: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.rootURL = rootURL
        self.lastKnownPath = lastKnownPath ?? rootURL.path
        self.isOnline = isOnline
        self.isWritable = isWritable
        self.lastScanAt = lastScanAt
        self.photoCount = photoCount
    }

    /// What the user is allowed to do right now.
    public var availability: LibraryAvailability {
        switch (isOnline, isWritable) {
        case (false, _): return .offline
        case (true, false): return .readOnly
        case (true, true): return .ready
        }
    }
}

public enum LibraryAvailability: Equatable, Sendable {
    case ready
    /// Drive unplugged: cached thumbnails still show, originals are unreachable.
    case offline
    /// Mounted but not writable: browsing and previewing work, saving doesn't.
    case readOnly

    public var allowsEditing: Bool { self == .ready }
    public var allowsDecoding: Bool { self != .offline }

    public var statusMessage: String {
        switch self {
        case .ready: return L10n.t("Ready")
        case .offline: return L10n.t("Offline — reconnect the drive to edit or export")
        case .readOnly: return L10n.t("Read-only — edits can't be saved to this drive")
        }
    }
}
