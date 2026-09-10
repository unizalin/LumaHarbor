import Foundation
import Localization
import RawProcessingCore

/// Per-photo state the browser needs to render a cell.
public enum PhotoStatus: String, Codable, Equatable, Sendable {
    case ready
    /// Indexed but not yet decoded or fingerprinted.
    case pending
    /// `CIRAWFilter` won't touch this camera's format (spec §10).
    case unsupported
    /// The bytes are damaged; the rest of the scan carried on (spec §10).
    case failed
    /// Fingerprint matched more than one existing record, so the scanner
    /// refused to merge automatically (spec §8.1).
    case needsConfirmation
}

/// One photo, as the library browser sees it.
public struct PhotoAsset: Identifiable, Equatable, Sendable {
    public var id: PhotoID
    public var libraryID: LibraryID
    /// Path relative to the library root, `/`-separated.
    public var relativePath: String
    public var fingerprint: FileFingerprint
    public var metadata: RawMetadata
    public var status: PhotoStatus
    public var failureReason: String?
    public var lastSeenAt: Date
    /// `true` when a sidecar with non-default adjustments exists.
    public var hasEdits: Bool
    /// Rebuildable projection of the sidecar's `modifiedAt`. `nil` when the
    /// photo has no edits or its adjustments are neutral.
    public var lastEditAt: Date?
    /// Phase 3 Task 3.5: `nil` for an original photo. Set to the original's
    /// own `id` for a "virtual copy" -- a distinct `PhotoID` (and therefore
    /// its own independent sidecar/adjustments) sharing the *original's*
    /// `relativePath`/`fingerprint`, so the same RAW file is never
    /// duplicated on disk. Never mutated after creation.
    public var variantOf: PhotoID?
    /// A virtual copy's user-facing name (e.g. "B&W"), shown instead of the
    /// shared filename so several copies of one RAW don't all look
    /// identical in the grid. `nil` for an original photo, or an
    /// unnamed copy.
    public var variantName: String?
    /// Curation metadata belongs to this photo identity and is independent of
    /// the scanned file facts.
    public var rating: Int
    public var flag: PhotoFlag
    public var keywords: [PhotoKeyword]
    /// `true` when this row's rating/flag/keywords were carried forward from
    /// a legacy sidecar or SQLite-only value that a migration write attempt
    /// could not yet persist to a schema-v3 sidecar (offline, read-only, or
    /// out of space). Purely observational and rebuildable: the next scan
    /// re-derives this from scratch, never from the flag's own prior value.
    public var curationMigrationPending: Bool

    public init(
        id: PhotoID,
        libraryID: LibraryID,
        relativePath: String,
        fingerprint: FileFingerprint,
        metadata: RawMetadata = RawMetadata(),
        status: PhotoStatus = .pending,
        failureReason: String? = nil,
        lastSeenAt: Date = Date(),
        hasEdits: Bool = false,
        lastEditAt: Date? = nil,
        variantOf: PhotoID? = nil,
        variantName: String? = nil,
        rating: Int = 0,
        flag: PhotoFlag = .none,
        keywords: [PhotoKeyword] = [],
        curationMigrationPending: Bool = false
    ) {
        self.id = id
        self.libraryID = libraryID
        self.relativePath = relativePath
        self.fingerprint = fingerprint
        self.metadata = metadata
        self.status = status
        self.failureReason = failureReason
        self.lastSeenAt = lastSeenAt
        self.hasEdits = hasEdits
        self.lastEditAt = lastEditAt
        self.variantOf = variantOf
        self.variantName = variantName
        self.rating = min(max(rating, 0), 5)
        self.flag = flag
        self.keywords = keywords
        self.curationMigrationPending = curationMigrationPending
    }

    /// `true` for a virtual copy (`variantOf != nil`), `false` for an
    /// original photo.
    public var isVirtualCopy: Bool { variantOf != nil }

    public var filename: String {
        relativePath.split(separator: "/").last.map(String.init) ?? relativePath
    }

    public var baseFilename: String {
        (filename as NSString).deletingPathExtension
    }

    public func url(inLibraryRootedAt root: URL) -> URL {
        root.appendingPathComponent(relativePath)
    }

    /// Message for the cell badge, or `nil` when the photo is fine.
    public var statusMessage: String? {
        switch status {
        case .ready, .pending:
            return nil
        case .unsupported:
            return L10n.t("This camera's RAW isn't supported yet")
        case .failed:
            return failureReason ?? L10n.t("This file couldn't be read")
        case .needsConfirmation:
            return L10n.t("Several files match — confirm which photo this is")
        }
    }
}
