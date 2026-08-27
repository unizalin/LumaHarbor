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
    public static let schemaVersion = 2

    private let database: SQLiteDatabase
    /// Recursive because `transaction` re-enters through `upsertPhoto`.
    private let lock = NSRecursiveLock()
    public let databaseURL: URL
    /// Test seam: when set, receives the exact row count the immediate-child
    /// SQL query in `childDirectories` returned — the SQL/Swift boundary
    /// cardinality — so a test can assert it's bounded by the number of
    /// immediate children, not by however many distinct descendant
    /// directories exist under `parent`.
    private let childDirectoriesRawRowCountHook: ((Int) -> Void)?

    public convenience init(databaseURL: URL) throws {
        try self.init(databaseURL: databaseURL, migrationHook: {})
    }

    /// Test seam: `migrationHook` runs inside the v1->v2 migration transaction,
    /// right before the schema-version record is updated, so a test can force
    /// a mid-migration failure and prove the whole transaction rolls back.
    init(
        databaseURL: URL,
        migrationHook: @escaping () throws -> Void,
        childDirectoriesRawRowCountHook: ((Int) -> Void)? = nil
    ) throws {
        self.databaseURL = databaseURL
        self.database = try SQLiteDatabase(url: databaseURL)
        self.childDirectoriesRawRowCountHook = childDirectoriesRawRowCountHook
        try createBaseSchemaIfNeeded()
        try migrateToLatestSchemaIfNeeded(migrationHook: migrationHook)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Creates the pre-v2 (schema v1) shape if it doesn't exist yet. Safe to
    /// run against an already-migrated v2 database: every statement is
    /// `IF NOT EXISTS`, and `schemaVersion` is seeded only when absent, so an
    /// existing v1 or v2 database is left exactly as it was.
    private func createBaseSchemaIfNeeded() throws {
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
            "INSERT OR IGNORE INTO schema_info (key, value) VALUES ('schemaVersion', '1');"
        )
    }

    private func currentSchemaVersion() throws -> Int {
        let rows = try database.query(
            "SELECT value FROM schema_info WHERE key = 'schemaVersion';"
        ) { Int($0.string(0)) ?? 1 }
        return rows.first ?? 1
    }

    /// Spec §8: v1 -> v2 happens inside one transaction. `ALTER TABLE`,
    /// `CREATE INDEX` and the backfill all run under the same `BEGIN
    /// IMMEDIATE`/`COMMIT` pair as the version bump, so a thrown error at any
    /// point — including from `migrationHook` — rolls every change back and
    /// leaves the database exactly as it was opened.
    private func migrateToLatestSchemaIfNeeded(migrationHook: () throws -> Void) throws {
        let version = try currentSchemaVersion()
        guard version < Self.schemaVersion else { return }

        try withLock {
            try database.transaction {
                try database.execute("""
                    ALTER TABLE library ADD COLUMN source_kind TEXT NOT NULL DEFAULT 'externalFolder';
                    ALTER TABLE library ADD COLUMN connection_state TEXT NOT NULL DEFAULT 'ready';
                    ALTER TABLE library ADD COLUMN scan_state TEXT NOT NULL DEFAULT 'idle';
                    ALTER TABLE photo ADD COLUMN filename_normalized TEXT NOT NULL DEFAULT '';
                    ALTER TABLE photo ADD COLUMN relative_directory TEXT NOT NULL DEFAULT '';
                    ALTER TABLE photo ADD COLUMN last_edit_at REAL;
                    """)

                try backfillFilenameNormalizedAndDirectory()

                try database.execute("""
                    CREATE INDEX photo_all_capture_desc ON photo (capture_date DESC, photo_id);
                    CREATE INDEX photo_library_capture_desc ON photo (library_id, capture_date DESC, photo_id);
                    CREATE INDEX photo_library_directory_capture_desc
                        ON photo (library_id, relative_directory, capture_date DESC, photo_id);
                    CREATE INDEX photo_filename_normalized ON photo (filename_normalized, photo_id);
                    CREATE INDEX photo_last_edit_desc ON photo (last_edit_at DESC, photo_id)
                        WHERE last_edit_at IS NOT NULL;
                    """)

                try migrationHook()

                try database.run(
                    "UPDATE schema_info SET value = ? WHERE key = 'schemaVersion';",
                    [.text(String(Self.schemaVersion))]
                )
            }
        }
    }

    /// `filename_normalized`/`relative_directory` can't be computed in SQL —
    /// NFC composition and locale-independent lowercasing need Foundation —
    /// so existing v1 rows are backfilled here, one `UPDATE` per row, inside
    /// the same migration transaction.
    private func backfillFilenameNormalizedAndDirectory() throws {
        let rows = try database.query(
            "SELECT photo_id, relative_path FROM photo;"
        ) { (id: $0.string(0), relativePath: $0.string(1)) }

        for row in rows {
            try database.run(
                "UPDATE photo SET filename_normalized = ?, relative_directory = ? WHERE photo_id = ?;",
                [
                    .text(Self.normalizeForSearch(Self.filenameComponent(of: row.relativePath))),
                    .text(Self.directoryComponent(of: row.relativePath)),
                    .text(row.id)
                ]
            )
        }
    }

    private static let photoColumnList = [
        "photo_id", "library_id", "relative_path", "file_size", "edge_digest",
        "capture_date", "camera_make", "camera_model", "lens_model",
        "pixel_width", "pixel_height", "iso_speed", "shutter_speed", "aperture", "orientation",
        "status", "failure_reason", "has_edits", "last_seen_at", "last_edit_at"
    ]
    private static let photoColumns = photoColumnList.joined(separator: ", ")
    private static let qualifiedPhotoColumns = photoColumnList.map { "p.\($0)" }.joined(separator: ", ")

    /// Directory portion of a `/`-separated relative path, or `""` for a file
    /// directly under the library root.
    private static func directoryComponent(of relativePath: String) -> String {
        guard let slashIndex = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[relativePath.startIndex..<slashIndex])
    }

    private static func filenameComponent(of relativePath: String) -> String {
        relativePath.split(separator: "/").last.map(String.init) ?? relativePath
    }

    /// NFC composition plus `String.lowercased()` (Unicode default case
    /// folding, not locale-sensitive) so "Café" matches whichever spelling —
    /// precomposed or combining-mark — the search string uses.
    private static func normalizeForSearch(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Escapes `\`, `%` and `_` so a user-supplied string can be bound into a
    /// `LIKE ... ESCAPE '\'` pattern and matched as literal text.
    private static func escapeForLike(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "\\", "%", "_":
                result.append("\\")
                result.append(character)
            default:
                result.append(character)
            }
        }
        return result
    }

    // MARK: - Libraries

    public func upsert(library: LibraryFolder) throws {
        // SQLite is a rebuildable cache of what the bookmark store already
        // knows (spec §8.3), so an in-flight `.queued`/`.scanning` value
        // must never land here — only `.idle`/`.partialFailure` survive a
        // reopen (spec §7).
        let persistedScanState = library.scanState.normalizedForRestore
        try withLock {
            try database.run("""
                INSERT INTO library (
                    id, display_name, root_path, is_online, is_writable, last_scan_at,
                    source_kind, connection_state, scan_state
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    display_name     = excluded.display_name,
                    root_path        = excluded.root_path,
                    is_online        = excluded.is_online,
                    is_writable      = excluded.is_writable,
                    last_scan_at     = excluded.last_scan_at,
                    source_kind      = excluded.source_kind,
                    connection_state = excluded.connection_state,
                    scan_state       = excluded.scan_state;
                """, [
                    .text(library.id.description),
                    .text(library.displayName),
                    .text(library.rootURL.path),
                    .integer(library.isOnline ? 1 : 0),
                    .integer(library.isWritable ? 1 : 0),
                    library.lastScanAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                    .text(library.sourceKind.rawValue),
                    .text(library.connectionState.rawValue),
                    .text(persistedScanState.rawValue)
                ])
        }
    }

    public func libraries() throws -> [LibraryFolder] {
        try withLock {
            try database.query("""
                SELECT l.id, l.display_name, l.root_path, l.is_online, l.is_writable, l.last_scan_at,
                       l.source_kind, l.connection_state, l.scan_state,
                       (SELECT COUNT(*) FROM photo p WHERE p.library_id = l.id)
                FROM library l
                ORDER BY l.display_name COLLATE NOCASE;
                """) { row in
                let scanState = LibraryScanState(rawValue: row.string(8)) ?? .idle
                return LibraryFolder(
                    id: LibraryID(uuidString: row.string(0)) ?? LibraryID(),
                    displayName: row.string(1),
                    rootURL: URL(fileURLWithPath: row.string(2), isDirectory: true),
                    lastKnownPath: row.string(2),
                    sourceKind: LibrarySourceKind(rawValue: row.string(6)) ?? .externalFolder,
                    // `is_online`/`is_writable` predate `connection_state`
                    // (schema v1) and are kept only for readers of the raw
                    // table; a v2+ row's `connection_state` is authoritative.
                    // An unrecognized raw value (a future case, or a
                    // corrupted row) must never default to `.ready` — this
                    // index is a rebuildable cache, not authoritative, so
                    // the safe default is `.offline` until `restoreLibraries()`
                    // re-derives the real state from the bookmark.
                    connectionState: LibraryConnectionState(rawValue: row.string(7)) ?? .offline,
                    scanState: scanState.normalizedForRestore,
                    lastScanAt: row.date(5),
                    photoCount: Int(row.int(9))
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

    /// Legacy two-bool availability update, predating `LibraryConnectionState`
    /// (spec §7). Kept for callers that only know online/writable; derives and
    /// writes `connection_state` too, so `LibraryFolder.availability` — now
    /// computed purely from `connectionState` — still reflects the change.
    /// This path can only ever produce `.ready`/`.readOnly`/`.offline`, never
    /// `.needsAuthorization`; callers that need to report a revoked
    /// authorization must go through the source lifecycle APIs instead.
    public func setLibraryAvailability(
        id: LibraryID,
        isOnline: Bool,
        isWritable: Bool
    ) throws {
        let connectionState: LibraryConnectionState
        switch (isOnline, isWritable) {
        case (false, _): connectionState = .offline
        case (true, false): connectionState = .readOnly
        case (true, true): connectionState = .ready
        }
        try withLock {
            try database.run(
                "UPDATE library SET is_online = ?, is_writable = ?, connection_state = ? WHERE id = ?;",
                [
                    .integer(isOnline ? 1 : 0),
                    .integer(isWritable ? 1 : 0),
                    .text(connectionState.rawValue),
                    .text(id.description)
                ]
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
            INSERT INTO photo (
                \(Self.photoColumns), filename_normalized, relative_directory
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(photo_id) DO UPDATE SET
                library_id          = excluded.library_id,
                relative_path       = excluded.relative_path,
                file_size           = excluded.file_size,
                edge_digest         = excluded.edge_digest,
                capture_date        = excluded.capture_date,
                camera_make         = excluded.camera_make,
                camera_model        = excluded.camera_model,
                lens_model          = excluded.lens_model,
                pixel_width         = excluded.pixel_width,
                pixel_height        = excluded.pixel_height,
                iso_speed           = excluded.iso_speed,
                shutter_speed       = excluded.shutter_speed,
                aperture            = excluded.aperture,
                orientation         = excluded.orientation,
                status              = excluded.status,
                failure_reason      = excluded.failure_reason,
                has_edits           = excluded.has_edits,
                last_seen_at        = excluded.last_seen_at,
                last_edit_at        = excluded.last_edit_at,
                filename_normalized = excluded.filename_normalized,
                relative_directory  = excluded.relative_directory;
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
                .real(photo.lastSeenAt.timeIntervalSince1970),
                photo.lastEditAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .text(Self.normalizeForSearch(Self.filenameComponent(of: photo.relativePath))),
                .text(Self.directoryComponent(of: photo.relativePath))
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

    /// Sets both edit-state columns together. A neutral save passes
    /// `hasEdits: false, lastEditAt: nil` to clear both; a successful
    /// non-neutral save passes `hasEdits: true` with the sidecar's
    /// `modifiedAt` so `.recentlyEdited` has something to sort by.
    ///
    /// The two columns can never disagree: `hasEdits: false` always clears
    /// `last_edit_at`, even if the caller passed a stale non-nil date, and
    /// `hasEdits: true` with no date is rejected outright rather than
    /// written as a row the edit badge and `.recentlyEdited` would read
    /// differently.
    public func setEditState(for photoID: PhotoID, hasEdits: Bool, lastEditAt: Date?) throws {
        if hasEdits, lastEditAt == nil {
            throw LibraryQueryError.missingEditDate
        }
        let normalizedLastEditAt = hasEdits ? lastEditAt : nil
        try withLock {
            try database.run(
                "UPDATE photo SET has_edits = ?, last_edit_at = ? WHERE photo_id = ?;",
                [
                    .integer(hasEdits ? 1 : 0),
                    normalizedLastEditAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                    .text(photoID.description)
                ]
            )
        }
    }

    // MARK: - Paged multi-source queries

    /// production page limit (spec §11): callers may request at most 200
    /// rows so the browser never materialises an entire drive.
    private static let maximumPageLimit = 200

    /// Sort key actually driving `ORDER BY`/the keyset predicate for one
    /// `page(matching:after:limit:)` call. `.recentlyEdited` overrides
    /// whatever `PhotoSort` the query asked for.
    private enum EffectiveSortKey {
        case captureDate(descending: Bool)
        case filename(ascending: Bool)
        case lastEditDate
    }

    /// Stable, cross-source paging over the index. Filtering, ordering and
    /// limiting all happen in SQL — no page ever loads more than
    /// `limit + 1` rows into Swift.
    public func page(
        matching query: LibraryQuery,
        after cursor: PhotoPageCursor?,
        limit: Int
    ) throws -> PhotoPage {
        guard (1...Self.maximumPageLimit).contains(limit) else {
            throw LibraryQueryError.invalidLimit(limit)
        }

        return try withLock {
            var conditions: [String] = []
            var parameters: [SQLiteValue] = []
            var joinsLibrary = false
            let isRecentlyEdited: Bool

            switch query.scope {
            case .all:
                isRecentlyEdited = false
            case .source(let libraryID):
                isRecentlyEdited = false
                conditions.append("p.library_id = ?")
                parameters.append(.text(libraryID.description))
            case .folder(let libraryID, let relativePath):
                isRecentlyEdited = false
                conditions.append("p.library_id = ?")
                parameters.append(.text(libraryID.description))
                if !relativePath.isEmpty {
                    // Exact, case-sensitive prefix equality — not LIKE — so
                    // e.g. "Trip" never matches "trip/..." (SQLite's default
                    // LIKE is ASCII case-insensitive) or "Trip2/..." (no
                    // wildcard is involved at all). `length()`/`substr()`
                    // count Unicode characters, matching `childDirectories`.
                    let prefix = relativePath + "/"
                    conditions.append(
                        "(p.relative_directory = ? OR substr(p.relative_directory, 1, length(?)) = ?)"
                    )
                    parameters.append(.text(relativePath))
                    parameters.append(.text(prefix))
                    parameters.append(.text(prefix))
                }
            case .appStorage:
                isRecentlyEdited = false
                joinsLibrary = true
                conditions.append("l.source_kind = 'appStorage'")
            case .recentlyEdited:
                isRecentlyEdited = true
                conditions.append("p.last_edit_at IS NOT NULL")
            }

            if let search = query.filenameSearch, !search.isEmpty {
                let escapedSearch = Self.escapeForLike(Self.normalizeForSearch(search))
                conditions.append("p.filename_normalized LIKE ? ESCAPE '\\'")
                parameters.append(.text("%" + escapedSearch + "%"))
            }

            let sortKey: EffectiveSortKey
            if isRecentlyEdited {
                sortKey = .lastEditDate
            } else {
                switch query.sort {
                case .captureDateDescending: sortKey = .captureDate(descending: true)
                case .captureDateAscending: sortKey = .captureDate(descending: false)
                case .filenameAscending: sortKey = .filename(ascending: true)
                case .filenameDescending: sortKey = .filename(ascending: false)
                }
            }

            let orderClause: String
            switch sortKey {
            case .captureDate(let descending):
                orderClause =
                    "(p.capture_date IS NULL) ASC, p.capture_date \(descending ? "DESC" : "ASC"), p.photo_id ASC"
            case .filename(let ascending):
                orderClause = "p.filename_normalized \(ascending ? "ASC" : "DESC"), p.photo_id ASC"
            case .lastEditDate:
                orderClause = "p.last_edit_at DESC, p.photo_id ASC"
            }

            if let cursor {
                let (predicate, cursorParameters) = try Self.keysetPredicate(
                    for: sortKey, cursor: cursor
                )
                // The predicate contains a top-level OR (NULL dates always
                // sort last), so it must be parenthesized before joining
                // with the scope/search conditions via " AND " — otherwise
                // AND's tighter precedence would let the OR branch escape
                // the scope filter entirely.
                conditions.append("(" + predicate + ")")
                parameters.append(contentsOf: cursorParameters)
            }

            var sql = "SELECT \(Self.qualifiedPhotoColumns), p.filename_normalized FROM photo p"
            if joinsLibrary {
                sql += " JOIN library l ON p.library_id = l.id"
            }
            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }
            sql += " ORDER BY \(orderClause) LIMIT ?;"
            parameters.append(.integer(Int64(limit + 1)))

            let rows = try database.query(sql, parameters) { row -> (asset: PhotoAsset, filenameNormalized: String) in
                (Self.photoAsset(from: row), row.string(20))
            }

            let hasMore = rows.count > limit
            let pageRows = Array(rows.prefix(limit))
            var nextCursor: PhotoPageCursor?
            if hasMore, let last = pageRows.last {
                switch sortKey {
                case .captureDate:
                    nextCursor = PhotoPageCursor(
                        dateKey: last.asset.metadata.captureDate, photoID: last.asset.id
                    )
                case .filename:
                    nextCursor = PhotoPageCursor(
                        filenameKey: last.filenameNormalized, photoID: last.asset.id
                    )
                case .lastEditDate:
                    nextCursor = PhotoPageCursor(
                        dateKey: last.asset.lastEditAt, photoID: last.asset.id
                    )
                }
            }

            return PhotoPage(photos: pageRows.map(\.asset), nextCursor: nextCursor)
        }
    }

    /// Builds the keyset ("seek") predicate that selects exactly the rows
    /// strictly after `cursor` in the ordering `sortKey` implies. NULL dates
    /// always sort last (in both directions), so a cursor sitting on a dated
    /// row must also admit every NULL-dated row, while a cursor already on a
    /// NULL-dated row only admits later NULL-dated rows by `photo_id`.
    ///
    /// Every branch validates the cursor's key *shape* against `sortKey`
    /// before touching its values: a capture-date cursor's `dateKey == nil`
    /// is a legitimate "NULL-capture" position, so the capture branch can't
    /// just pattern-match on `dateKey` the way the other two do — it must
    /// also reject a non-nil `filenameKey`, or a filename cursor replayed
    /// against a capture-date sort would be silently misread as a
    /// NULL-capture cursor and skip every dated row instead of failing.
    private static func keysetPredicate(
        for sortKey: EffectiveSortKey,
        cursor: PhotoPageCursor
    ) throws -> (sql: String, parameters: [SQLiteValue]) {
        switch sortKey {
        case .captureDate(let descending):
            guard cursor.filenameKey == nil else { throw LibraryQueryError.invalidCursor }
            let comparisonOperator = descending ? "<" : ">"
            if let dateKey = cursor.dateKey {
                let value = dateKey.timeIntervalSince1970
                let sql = """
                    (p.capture_date IS NOT NULL AND \
                    (p.capture_date \(comparisonOperator) ? OR (p.capture_date = ? AND p.photo_id > ?))) \
                    OR p.capture_date IS NULL
                    """
                return (sql, [.real(value), .real(value), .text(cursor.photoID.description)])
            } else {
                return (
                    "p.capture_date IS NULL AND p.photo_id > ?",
                    [.text(cursor.photoID.description)]
                )
            }
        case .filename(let ascending):
            guard let filenameKey = cursor.filenameKey, cursor.dateKey == nil else {
                throw LibraryQueryError.invalidCursor
            }
            let comparisonOperator = ascending ? ">" : "<"
            let sql = """
                p.filename_normalized \(comparisonOperator) ? \
                OR (p.filename_normalized = ? AND p.photo_id > ?)
                """
            return (sql, [.text(filenameKey), .text(filenameKey), .text(cursor.photoID.description)])
        case .lastEditDate:
            guard let dateKey = cursor.dateKey, cursor.filenameKey == nil else {
                throw LibraryQueryError.invalidCursor
            }
            let value = dateKey.timeIntervalSince1970
            let sql = "p.last_edit_at < ? OR (p.last_edit_at = ? AND p.photo_id > ?)"
            return (sql, [.real(value), .real(value), .text(cursor.photoID.description)])
        }
    }

    /// Immediate child directories of `parent` that contain at least one
    /// indexed photo (directly or in a deeper descendant), for lazily
    /// expanding the folder sidebar one level at a time. `childCount` sums
    /// photos across the whole subtree under each child.
    ///
    /// The immediate-child segment is extracted and grouped entirely in
    /// SQL — via `length`/`substr`/`instr` on `relative_directory`, bound
    /// against the same `prefix` parameter used to compute their
    /// lengths — so a deep, wide subtree never returns one row per
    /// descendant directory to Swift, only one row per immediate child.
    /// `prefix` and `relative_directory` are both plain `String`s (never
    /// byte-sliced), and SQLite's `length`/`substr` count Unicode
    /// characters, not bytes, so multi-byte names split correctly.
    public func childDirectories(
        libraryID: LibraryID,
        parent: String
    ) throws -> [LibraryDirectoryNode] {
        try withLock {
            let prefix = parent.isEmpty ? "" : parent + "/"

            let rows = try database.query(
                """
                WITH bounds AS (
                    SELECT ? AS lib, ? AS excl_dir, ? AS prefix
                ),
                scored AS (
                    SELECT
                        CASE
                            WHEN instr(substr(photo.relative_directory, length(bounds.prefix) + 1), '/') > 0
                                THEN substr(
                                    photo.relative_directory, 1,
                                    length(bounds.prefix)
                                        + instr(substr(photo.relative_directory, length(bounds.prefix) + 1), '/')
                                        - 1
                                )
                            ELSE photo.relative_directory
                        END AS child_path,
                        bounds.prefix AS prefix
                    FROM photo, bounds
                    WHERE photo.library_id = bounds.lib
                      AND photo.relative_directory <> bounds.excl_dir
                      AND (
                        bounds.prefix = ''
                        OR substr(photo.relative_directory, 1, length(bounds.prefix)) = bounds.prefix
                      )
                )
                SELECT child_path, substr(child_path, length(prefix) + 1), COUNT(*)
                FROM scored
                GROUP BY child_path
                ORDER BY child_path;
                """,
                [
                    .text(libraryID.description),
                    .text(parent),
                    .text(prefix)
                ]
            ) { (path: $0.string(0), displayName: $0.string(1), count: Int($0.int(2))) }
            childDirectoriesRawRowCountHook?(rows.count)

            return rows.map { row in
                LibraryDirectoryNode(
                    libraryID: libraryID,
                    relativePath: row.path,
                    displayName: row.displayName,
                    childCount: row.count
                )
            }
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
            hasEdits: row.bool(17),
            lastEditAt: row.date(19)
        )
    }
}
