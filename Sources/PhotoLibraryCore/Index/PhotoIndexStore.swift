import Foundation
import RawProcessingCore

/// The Mac-local, rebuildable index.
///
/// Spec §8.3: everything here is a cache of what the SSD already knows. Deleting
/// `library.sqlite` must cost the user nothing but a rescan, which is why no
/// column in this schema is authoritative — `library.json` and the sidecars are.
///
/// A lock-guarded class rather than an actor: every method is a short
/// synchronous SQLite call, and making callers `await` each row would push
/// suspension points into the middle of scan batches for no benefit.
public final class PhotoIndexStore: @unchecked Sendable {
    public static let schemaVersion = 1

    private let database: SQLiteDatabase
    /// Recursive because `transaction` re-enters through `upsertPhoto`.
    private let lock = NSRecursiveLock()
    public let databaseURL: URL

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        self.database = try SQLiteDatabase(url: databaseURL)
        try createSchema()
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func createSchema() throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS schema_info (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS library (
                id           TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                root_path    TEXT NOT NULL,
                is_online    INTEGER NOT NULL DEFAULT 1,
                is_writable  INTEGER NOT NULL DEFAULT 1,
                last_scan_at REAL
            );

            CREATE TABLE IF NOT EXISTS photo (
                photo_id           TEXT PRIMARY KEY,
                library_id         TEXT NOT NULL,
                relative_path      TEXT NOT NULL,
                file_size          INTEGER NOT NULL,
                edge_digest        TEXT NOT NULL,
                capture_date       REAL,
                camera_make        TEXT,
                camera_model       TEXT,
                lens_model         TEXT,
                pixel_width        INTEGER NOT NULL DEFAULT 0,
                pixel_height       INTEGER NOT NULL DEFAULT 0,
                iso_speed          INTEGER,
                shutter_speed      REAL,
                aperture           REAL,
                orientation        INTEGER,
                status             TEXT NOT NULL,
                failure_reason     TEXT,
                has_edits          INTEGER NOT NULL DEFAULT 0,
                last_seen_at       REAL NOT NULL
            );

            CREATE INDEX IF NOT EXISTS photo_library_path
                ON photo (library_id, relative_path);
            CREATE INDEX IF NOT EXISTS photo_fingerprint
                ON photo (edge_digest, file_size);
            CREATE INDEX IF NOT EXISTS photo_capture_date
                ON photo (library_id, capture_date);
            """)

        try database.run(
            "INSERT OR REPLACE INTO schema_info (key, value) VALUES (?, ?);",
            [.text("schemaVersion"), .text(String(Self.schemaVersion))]
        )
    }

    private static let photoColumns = """
        photo_id, library_id, relative_path, file_size, edge_digest,
        capture_date, camera_make, camera_model, lens_model,
        pixel_width, pixel_height, iso_speed, shutter_speed, aperture, orientation,
        status, failure_reason, has_edits, last_seen_at
        """

    // MARK: - Libraries

    public func upsert(library: LibraryFolder) throws {
        try withLock {
            try database.run("""
                INSERT INTO library (id, display_name, root_path, is_online, is_writable, last_scan_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    root_path    = excluded.root_path,
                    is_online    = excluded.is_online,
                    is_writable  = excluded.is_writable,
                    last_scan_at = excluded.last_scan_at;
                """, [
                    .text(library.id.description),
                    .text(library.displayName),
                    .text(library.rootURL.path),
                    .integer(library.isOnline ? 1 : 0),
                    .integer(library.isWritable ? 1 : 0),
                    library.lastScanAt.map { .real($0.timeIntervalSince1970) } ?? .null
                ])
        }
    }

    public func libraries() throws -> [LibraryFolder] {
        try withLock {
            try database.query("""
                SELECT l.id, l.display_name, l.root_path, l.is_online, l.is_writable, l.last_scan_at,
                       (SELECT COUNT(*) FROM photo p WHERE p.library_id = l.id)
                FROM library l
                ORDER BY l.display_name COLLATE NOCASE;
                """) { row in
                LibraryFolder(
                    id: LibraryID(uuidString: row.string(0)) ?? LibraryID(),
                    displayName: row.string(1),
                    rootURL: URL(fileURLWithPath: row.string(2), isDirectory: true),
                    lastKnownPath: row.string(2),
                    isOnline: row.bool(3),
                    isWritable: row.bool(4),
                    lastScanAt: row.date(5),
                    photoCount: Int(row.int(6))
                )
            }
        }
    }

    public func library(id: LibraryID) throws -> LibraryFolder? {
        try libraries().first { $0.id == id }
    }

    public func removeLibrary(id: LibraryID) throws {
        try withLock {
            try database.transaction {
                try database.run(
                    "DELETE FROM photo WHERE library_id = ?;", [.text(id.description)]
                )
                try database.run("DELETE FROM library WHERE id = ?;", [.text(id.description)])
            }
        }
    }

    public func setLibraryAvailability(
        id: LibraryID,
        isOnline: Bool,
        isWritable: Bool
    ) throws {
        try withLock {
            try database.run(
                "UPDATE library SET is_online = ?, is_writable = ? WHERE id = ?;",
                [.integer(isOnline ? 1 : 0), .integer(isWritable ? 1 : 0), .text(id.description)]
            )
        }
    }

    // MARK: - Photos

    /// Batched insert so an incremental scan commits a page at a time.
    public func upsert(photos: [PhotoAsset]) throws {
        guard !photos.isEmpty else { return }
        try withLock {
            try database.transaction {
                for photo in photos {
                    try upsertPhoto(photo)
                }
            }
        }
    }

    public func upsert(photo: PhotoAsset) throws {
        try withLock { try upsertPhoto(photo) }
    }

    private func upsertPhoto(_ photo: PhotoAsset) throws {
        try database.run("""
            INSERT INTO photo (\(Self.photoColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(photo_id) DO UPDATE SET
                library_id     = excluded.library_id,
                relative_path  = excluded.relative_path,
                file_size      = excluded.file_size,
                edge_digest    = excluded.edge_digest,
                capture_date   = excluded.capture_date,
                camera_make    = excluded.camera_make,
                camera_model   = excluded.camera_model,
                lens_model     = excluded.lens_model,
                pixel_width    = excluded.pixel_width,
                pixel_height   = excluded.pixel_height,
                iso_speed      = excluded.iso_speed,
                shutter_speed  = excluded.shutter_speed,
                aperture       = excluded.aperture,
                orientation    = excluded.orientation,
                status         = excluded.status,
                failure_reason = excluded.failure_reason,
                has_edits      = excluded.has_edits,
                last_seen_at   = excluded.last_seen_at;
            """, [
                .text(photo.id.description),
                .text(photo.libraryID.description),
                .text(photo.relativePath),
                .integer(photo.fingerprint.fileSize),
                .text(photo.fingerprint.edgeDigest),
                photo.metadata.captureDate.map { .real($0.timeIntervalSince1970) } ?? .null,
                photo.metadata.cameraMake.map { .text($0) } ?? .null,
                photo.metadata.cameraModel.map { .text($0) } ?? .null,
                photo.metadata.lensModel.map { .text($0) } ?? .null,
                .integer(Int64(photo.metadata.pixelWidth)),
                .integer(Int64(photo.metadata.pixelHeight)),
                photo.metadata.isoSpeed.map { .integer(Int64($0)) } ?? .null,
                photo.metadata.shutterSpeed.map { .real($0) } ?? .null,
                photo.metadata.aperture.map { .real($0) } ?? .null,
                photo.metadata.orientation.map { .integer(Int64($0)) } ?? .null,
                .text(photo.status.rawValue),
                photo.failureReason.map { .text($0) } ?? .null,
                .integer(photo.hasEdits ? 1 : 0),
                .real(photo.lastSeenAt.timeIntervalSince1970)
            ])
    }

    /// Paged so the browser never materialises an entire drive (spec §11).
    public func photos(
        inLibrary libraryID: LibraryID,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [PhotoAsset] {
        try withLock {
            var sql = """
                SELECT \(Self.photoColumns)
                FROM photo
                WHERE library_id = ?
                ORDER BY COALESCE(capture_date, last_seen_at), relative_path
                """
            var parameters: [SQLiteValue] = [.text(libraryID.description)]
            if let limit {
                sql += "\nLIMIT ? OFFSET ?"
                parameters.append(.integer(Int64(limit)))
                parameters.append(.integer(Int64(offset)))
            }
            sql += ";"
            return try database.query(sql, parameters, transform: Self.photoAsset(from:))
        }
    }

    public func photo(id: PhotoID) throws -> PhotoAsset? {
        try withLock {
            try database.query(
                "SELECT \(Self.photoColumns) FROM photo WHERE photo_id = ?;",
                [.text(id.description)],
                transform: Self.photoAsset(from:)
            ).first
        }
    }

    public func photoCount(inLibrary libraryID: LibraryID) throws -> Int {
        try withLock {
            let rows = try database.query(
                "SELECT COUNT(*) FROM photo WHERE library_id = ?;",
                [.text(libraryID.description)]
            ) { Int($0.int(0)) }
            return rows.first ?? 0
        }
    }

    public func removePhotos(ids: [PhotoID]) throws {
        guard !ids.isEmpty else { return }
        try withLock {
            try database.transaction {
                for id in ids {
                    try database.run(
                        "DELETE FROM photo WHERE photo_id = ?;", [.text(id.description)]
                    )
                }
            }
        }
    }

    /// Drops photos not seen by the latest scan, so deletions on the SSD show up.
    public func removePhotos(inLibrary libraryID: LibraryID, notSeenSince cutoff: Date) throws {
        try withLock {
            try database.run(
                "DELETE FROM photo WHERE library_id = ? AND last_seen_at < ?;",
                [.text(libraryID.description), .real(cutoff.timeIntervalSince1970)]
            )
        }
    }

    public func setHasEdits(_ hasEdits: Bool, for photoID: PhotoID) throws {
        try withLock {
            try database.run(
                "UPDATE photo SET has_edits = ? WHERE photo_id = ?;",
                [.integer(hasEdits ? 1 : 0), .text(photoID.description)]
            )
        }
    }

    /// Wipes indexed content but keeps the file. Used by the rebuild path.
    public func removeAllPhotos(inLibrary libraryID: LibraryID) throws {
        try withLock {
            try database.run(
                "DELETE FROM photo WHERE library_id = ?;", [.text(libraryID.description)]
            )
        }
    }

    public func close() {
        withLock { database.close() }
    }

    private static func photoAsset(from row: SQLiteRow) -> PhotoAsset {
        PhotoAsset(
            id: PhotoID(uuidString: row.string(0)) ?? PhotoID(),
            libraryID: LibraryID(uuidString: row.string(1)) ?? LibraryID(),
            relativePath: row.string(2),
            fingerprint: FileFingerprint(fileSize: row.int(3), edgeDigest: row.string(4)),
            metadata: RawMetadata(
                pixelWidth: Int(row.int(9)),
                pixelHeight: Int(row.int(10)),
                captureDate: row.date(5),
                cameraMake: row.optionalString(6),
                cameraModel: row.optionalString(7),
                lensModel: row.optionalString(8),
                isoSpeed: row.optionalInt(11).map(Int.init),
                shutterSpeed: row.optionalDouble(12),
                aperture: row.optionalDouble(13),
                orientation: row.optionalInt(14).map(Int.init)
            ),
            status: PhotoStatus(rawValue: row.string(15)) ?? .pending,
            failureReason: row.optionalString(16),
            lastSeenAt: row.date(18) ?? Date(),
            hasEdits: row.bool(17)
        )
    }
}
