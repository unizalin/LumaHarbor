import Foundation
import RawProcessingCore

/// Which decoder produced the edit, recorded so a later decoder swap is visible.
public struct DecoderDescriptor: Codable, Equatable, Sendable {
    public var kind: String
    public var version: String

    public init(kind: String, version: String) {
        self.kind = kind
        self.version = version
    }

    public init(_ identifier: DecoderIdentifier) {
        self.kind = identifier.kind
        self.version = identifier.version
    }

    public static let coreImageDefault = DecoderDescriptor(
        kind: "coreImage",
        version: "system-default"
    )
}

/// One photo's portable edit record: `.lumaharbor/edits/<photo-id>.json`.
///
/// Spec §8.2. This type is the contract between this Mac and a future iPad on
/// the same SSD, so field names are load-bearing.
public struct PhotoSidecar: Codable, Equatable, Sendable {
    /// Bumped only for breaking changes. A sidecar carrying a *higher* value is
    /// rejected rather than partially read (spec §12.1).
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var photoID: PhotoID
    /// Path relative to the library root, using `/` separators.
    public var sourceRelativePath: String
    public var sourceFingerprint: FileFingerprint
    public var decoder: DecoderDescriptor
    public var adjustments: PhotoAdjustments
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        schemaVersion: Int = PhotoSidecar.currentSchemaVersion,
        photoID: PhotoID,
        sourceRelativePath: String,
        sourceFingerprint: FileFingerprint,
        decoder: DecoderDescriptor = .coreImageDefault,
        adjustments: PhotoAdjustments = .neutral,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.photoID = photoID
        self.sourceRelativePath = sourceRelativePath
        self.sourceFingerprint = sourceFingerprint
        self.decoder = decoder
        self.adjustments = adjustments
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// `true` when this file was written by a version that changed the format in
    /// a way this build cannot understand.
    public var isFromNewerSchema: Bool { schemaVersion > Self.currentSchemaVersion }

    public func updating(
        adjustments: PhotoAdjustments,
        modifiedAt: Date = Date()
    ) -> PhotoSidecar {
        var copy = self
        copy.adjustments = adjustments
        copy.modifiedAt = modifiedAt
        return copy
    }
}
