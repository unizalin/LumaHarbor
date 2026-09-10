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
    ///
    /// v3 (professional editing completion spec §6.1) adds `curation`. A v1/v2
    /// sidecar has no such key at all -- not merely a neutral value for it --
    /// so decoding it as `.neutral` (below) is what lets `CurationMigration`
    /// tell "genuinely v3 with neutral curation" apart from "pre-v3, migrate
    /// from SQLite if it has anything worth migrating" purely from
    /// `schemaVersion`, never from whether `curation` happens to be neutral.
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var photoID: PhotoID
    /// Path relative to the library root, using `/` separators.
    public var sourceRelativePath: String
    public var sourceFingerprint: FileFingerprint
    public var decoder: DecoderDescriptor
    public var adjustments: PhotoAdjustments
    /// Portable rating/flag/keyword record (spec §6.1). Missing on a v1/v2
    /// sidecar; decodes to `.neutral` rather than failing.
    public var curation: PhotoCuration
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
        curation: PhotoCuration = .neutral,
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
        self.curation = curation
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.variantOf = variantOf
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, photoID, sourceRelativePath, sourceFingerprint
        case decoder, adjustments, curation, createdAt, modifiedAt, variantOf
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        photoID = try container.decode(PhotoID.self, forKey: .photoID)
        sourceRelativePath = try container.decode(String.self, forKey: .sourceRelativePath)
        sourceFingerprint = try container.decode(FileFingerprint.self, forKey: .sourceFingerprint)
        self.decoder = try container.decodeIfPresent(DecoderDescriptor.self, forKey: .decoder) ?? .coreImageDefault
        adjustments = try container.decodeIfPresent(PhotoAdjustments.self, forKey: .adjustments) ?? .neutral
        curation = try container.decodeIfPresent(PhotoCuration.self, forKey: .curation) ?? .neutral
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        variantOf = try container.decodeIfPresent(PhotoID.self, forKey: .variantOf)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(photoID, forKey: .photoID)
        try container.encode(sourceRelativePath, forKey: .sourceRelativePath)
        try container.encode(sourceFingerprint, forKey: .sourceFingerprint)
        try container.encode(decoder, forKey: .decoder)
        try container.encode(adjustments, forKey: .adjustments)
        try container.encode(curation, forKey: .curation)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encodeIfPresent(variantOf, forKey: .variantOf)
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

    /// Curation is not an "edit" -- `modifiedAt` elsewhere in this codebase
    /// means "adjustments changed" (see `PhotoAsset.lastEditAt`), so this
    /// does not bump it unless the caller explicitly asks.
    public func updating(
        curation: PhotoCuration,
        modifiedAt: Date? = nil
    ) -> PhotoSidecar {
        var copy = self
        copy.curation = curation
        if let modifiedAt { copy.modifiedAt = modifiedAt }
        return copy
    }
}
