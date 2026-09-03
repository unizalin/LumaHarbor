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
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var photoID: PhotoID
    /// Path relative to the library root, using `/` separators.
    public var sourceRelativePath: String
    public var sourceFingerprint: FileFingerprint
    public var decoder: DecoderDescriptor
    public var adjustments: PhotoAdjustments
    public var createdAt: Date
    public var modifiedAt: Date
    /// Phase 3 Task 3.5: `nil` for an original photo's sidecar; the
    /// original's own `photoID` for a virtual copy's sidecar. Embedded here
    /// too, redundant with `LibraryManifest`'s own `PhotoRecord.variantOf`,
    /// the same way `sourceRelativePath`/`sourceFingerprint` already
    /// duplicate manifest data -- this is what lets a sidecar found on disk
    /// (e.g. rebuilding a lost index/manifest) still say whose copy it is,
    /// not just whose photo. A plain `Optional` stored property, not a
    /// custom decoder: missing on an older sidecar decodes to `nil`
    /// automatically, same as every other addition here.
    public var variantOf: PhotoID?

    public init(
        schemaVersion: Int = PhotoSidecar.currentSchemaVersion,
        photoID: PhotoID,
        sourceRelativePath: String,
        sourceFingerprint: FileFingerprint,
        decoder: DecoderDescriptor = .coreImageDefault,
        adjustments: PhotoAdjustments = .neutral,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        variantOf: PhotoID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.photoID = photoID
        self.sourceRelativePath = sourceRelativePath
        self.sourceFingerprint = sourceFingerprint
        self.decoder = decoder
        self.adjustments = adjustments
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.variantOf = variantOf
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
