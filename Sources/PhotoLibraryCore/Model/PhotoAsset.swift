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

    public init(
        id: PhotoID,
        libraryID: LibraryID,
        relativePath: String,
        fingerprint: FileFingerprint,
        metadata: RawMetadata = RawMetadata(),
        status: PhotoStatus = .pending,
        failureReason: String? = nil,
        lastSeenAt: Date = Date(),
        hasEdits: Bool = false
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
    }

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
