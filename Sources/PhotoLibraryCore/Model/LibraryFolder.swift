import Foundation
import Localization

/// What kind of source a `LibraryFolder` wraps (spec §7). Distinct from
/// `LibraryConnectionState` and `LibraryScanState`: what a source *is* never
/// changes, while how reachable it is and what its last scan did both do.
public enum LibrarySourceKind: String, Codable, Sendable {
    case externalFolder
    case filesProvider
    case appStorage
}

/// What the user is allowed to do with a source right now (spec §7).
///
/// Kept independent of `LibraryScanState`: a source mid-`partialFailure` scan
/// must not read as unavailable, and a source that just went `offline` must
/// not be mistaken for a scan outcome.
public enum LibraryConnectionState: String, Codable, Sendable {
    case ready
    case readOnly
    case offline
    case needsAuthorization
}

/// The last thing a source's scan did (spec §7). Only `.idle` and
/// `.partialFailure` are ever persisted — `.queued`/`.scanning` describe a
/// scan actually in flight and are normalized back to `.idle` on restore,
/// since nothing was left running to resume.
public enum LibraryScanState: String, Codable, Sendable {
    case idle
    case queued
    case scanning
    case partialFailure
}

extension LibraryScanState {
    /// SQLite and the bookmark file only ever persist `.idle` or
    /// `.partialFailure` (spec §7). An interrupted `.queued`/`.scanning`
    /// read back from either store is normalized to `.idle` — the scan that
    /// set it is gone, so there is nothing in flight to resume.
    public var normalizedForRestore: LibraryScanState {
        switch self {
        case .idle, .partialFailure: return self
        case .queued, .scanning: return .idle
        }
    }
}

/// A photo folder the user has authorised, as the app sees it at runtime.
public struct LibraryFolder: Identifiable, Equatable, Sendable {
    public let id: LibraryID
    public var displayName: String
    public var rootURL: URL
    /// Path recorded when the folder was added, shown when it goes missing.
    public var lastKnownPath: String
    public var sourceKind: LibrarySourceKind
    public var connectionState: LibraryConnectionState
    public var scanState: LibraryScanState
    public var lastScanAt: Date?
    public var photoCount: Int

    public init(
        id: LibraryID = LibraryID(),
        displayName: String,
        rootURL: URL,
        lastKnownPath: String? = nil,
        sourceKind: LibrarySourceKind = .externalFolder,
        connectionState: LibraryConnectionState = .ready,
        scanState: LibraryScanState = .idle,
        lastScanAt: Date? = nil,
        photoCount: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.rootURL = rootURL
        self.lastKnownPath = lastKnownPath ?? rootURL.path
        self.sourceKind = sourceKind
        self.connectionState = connectionState
        self.scanState = scanState
        self.lastScanAt = lastScanAt
        self.photoCount = photoCount
    }

    /// `false` when the SSD is unplugged, or authorization was revoked.
    /// Spec §10: stay browsable from cache either way. Compatibility
    /// accessor over `connectionState`, kept read-only — every mutation now
    /// goes through `connectionState` so the two can never disagree.
    public var isOnline: Bool {
        connectionState == .ready || connectionState == .readOnly
    }

    /// `false` for a locked or read-only volume, an offline drive, or a
    /// source that needs re-authorization — browsing may still be allowed,
    /// saving is not (spec §10). Compatibility accessor over `connectionState`.
    public var isWritable: Bool {
        connectionState == .ready
    }

    /// What the user is allowed to do right now.
    public var availability: LibraryAvailability {
        switch connectionState {
        case .ready: return .ready
        case .readOnly: return .readOnly
        case .offline, .needsAuthorization: return .offline
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
