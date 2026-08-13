import Foundation

/// One photo's entry in `library.json`.
public struct PhotoRecord: Codable, Equatable, Sendable {
    public var photoID: PhotoID
    /// Path relative to the library root, `/`-separated.
    public var relativePath: String
    public var fingerprint: FileFingerprint
    public var lastSeenAt: Date
    /// Set when several records share this fingerprint, so the scanner refuses
    /// to guess which one a moved file belongs to (spec §8.1).
    public var needsConfirmation: Bool

    public init(
        photoID: PhotoID,
        relativePath: String,
        fingerprint: FileFingerprint,
        lastSeenAt: Date = Date(),
        needsConfirmation: Bool = false
    ) {
        self.photoID = photoID
        self.relativePath = relativePath
        self.fingerprint = fingerprint
        self.lastSeenAt = lastSeenAt
        self.needsConfirmation = needsConfirmation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.photoID = try container.decode(PhotoID.self, forKey: .photoID)
        self.relativePath = try container.decode(String.self, forKey: .relativePath)
        self.fingerprint = try container.decode(FileFingerprint.self, forKey: .fingerprint)
        self.lastSeenAt = try container.decode(Date.self, forKey: .lastSeenAt)
        self.needsConfirmation = try container.decodeIfPresent(
            Bool.self, forKey: .needsConfirmation
        ) ?? false
    }
}

/// `.lumaharbor/library.json` — the portable index of what lives in this folder.
///
/// Spec §8.1: schema version, library identifier, per-photo UUID, relative path,
/// fingerprint and last successful scan time. The Mac's SQLite database is a
/// disposable cache of exactly this, which is what makes "delete the database
/// and rebuild" work.
public struct LibraryManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var libraryID: LibraryID
    public var photos: [PhotoRecord]
    public var lastSuccessfulScanAt: Date?

    public init(
        schemaVersion: Int = LibraryManifest.currentSchemaVersion,
        libraryID: LibraryID = LibraryID(),
        photos: [PhotoRecord] = [],
        lastSuccessfulScanAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.libraryID = libraryID
        self.photos = photos
        self.lastSuccessfulScanAt = lastSuccessfulScanAt
    }

    public var isFromNewerSchema: Bool { schemaVersion > Self.currentSchemaVersion }

    public func record(for photoID: PhotoID) -> PhotoRecord? {
        photos.first { $0.photoID == photoID }
    }

    public func record(atRelativePath path: String) -> PhotoRecord? {
        photos.first { $0.relativePath == path }
    }

    /// Inserts or replaces by `photoID`, keeping the array sorted by path so the
    /// serialised file stays stable across scans.
    public mutating func upsert(_ record: PhotoRecord) {
        if let index = photos.firstIndex(where: { $0.photoID == record.photoID }) {
            photos[index] = record
        } else {
            photos.append(record)
        }
        photos.sort { $0.relativePath < $1.relativePath }
    }

    public mutating func remove(photoID: PhotoID) {
        photos.removeAll { $0.photoID == photoID }
    }
}
