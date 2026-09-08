import XCTest
@testable import PhotoLibraryCore

/// Spec §8: migrations happen inside one transaction. Genuine failures roll
/// back every change, while a legacy database with a stale version marker but
/// an already-complete physical schema can repair the marker without losing
/// its rebuildable index data.
final class PhotoIndexMigrationTests: TemporaryDirectoryTestCase {
    private let fixtureLibraryID = LibraryID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private enum TestError: Error {
        case injected
    }

    func testOpeningV1DatabaseMigratesAtomicallyToTheLatestSchema() throws {
        let url = temporaryDirectory.appendingPathComponent("library.sqlite")
        try makeSchemaV1Database(at: url, photoCount: 2)

        let store = try PhotoIndexStore(databaseURL: url)
        defer { store.close() }

        XCTAssertEqual(PhotoIndexStore.schemaVersion, 4)
        XCTAssertEqual(try readSchemaVersion(at: url), 4)
        XCTAssertTrue(try columnExists("photo", "variant_of", at: url))
        XCTAssertTrue(try columnExists("photo", "variant_name", at: url))
        XCTAssertTrue(try columnExists("photo", "rating", at: url))
        XCTAssertTrue(try columnExists("photo", "flag", at: url))
        XCTAssertTrue(try columnExists("photo", "format_normalized", at: url))
        XCTAssertEqual(try store.photoCount(inLibrary: fixtureLibraryID), 2)
        XCTAssertEqual(try store.page(
            matching: LibraryQuery(scope: .all, sort: .captureDateDescending),
            after: nil,
            limit: 100
        ).photos.count, 2)
    }

    func testMigrationFailureRollsBackEveryChange() throws {
        let url = temporaryDirectory.appendingPathComponent("library.sqlite")
        try makeSchemaV1Database(at: url, photoCount: 1)

        XCTAssertThrowsError(try PhotoIndexStore(
            databaseURL: url,
            migrationHook: { throw TestError.injected }
        ))

        XCTAssertEqual(try readSchemaVersion(at: url), 1)
        XCTAssertFalse(try columnExists("photo", "filename_normalized", at: url))
        XCTAssertFalse(try columnExists("photo", "relative_directory", at: url))
        XCTAssertFalse(try columnExists("photo", "last_edit_at", at: url))
        XCTAssertFalse(try columnExists("library", "source_kind", at: url))
        XCTAssertFalse(try columnExists("photo", "variant_of", at: url))
        XCTAssertFalse(try columnExists("photo", "variant_name", at: url))
    }

    /// Phase 3 Task 3.5: the realistic upgrade path for an existing
    /// installation -- a database already fully migrated to v2 (the shape
    /// every released version up to this one produces) must pick up only
    /// the new v3 columns, never re-run the v1 -> v2 `ALTER TABLE`s (which
    /// would fail with "duplicate column name" against a database that
    /// already has them).
    func testOpeningV2DatabaseMigratesToV3WithoutTouchingExistingData() throws {
        let url = temporaryDirectory.appendingPathComponent("library.sqlite")
        try makeSchemaV2Database(at: url, photoCount: 2)

        let store = try PhotoIndexStore(databaseURL: url)
        defer { store.close() }

        XCTAssertEqual(try readSchemaVersion(at: url), 4)
        XCTAssertTrue(try columnExists("photo", "variant_of", at: url))
        XCTAssertTrue(try columnExists("photo", "variant_name", at: url))
        XCTAssertTrue(try columnExists("photo", "rating", at: url))
        XCTAssertTrue(try columnExists("photo", "flag", at: url))
        // Untouched v2 data must survive exactly as it was.
        XCTAssertEqual(try store.photoCount(inLibrary: fixtureLibraryID), 2)
        let page = try store.page(
            matching: LibraryQuery(scope: .all, sort: .captureDateDescending),
            after: nil,
            limit: 100
        )
        XCTAssertEqual(page.photos.count, 2)
        XCTAssertTrue(page.photos.allSatisfy { $0.variantOf == nil })
    }

    func testReopeningAnAlreadyV3MigratedDatabaseDoesNotReapplyTheV3Migration() throws {
        let url = temporaryDirectory.appendingPathComponent("library.sqlite")
        try makeSchemaV2Database(at: url, photoCount: 1)
        let store = try PhotoIndexStore(databaseURL: url)
        store.close()

        // Reopening a v3 database must not attempt to add the v3 columns a
        // second time (which would throw "duplicate column name").
        let reopened = try PhotoIndexStore(databaseURL: url)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.photoCount(inLibrary: fixtureLibraryID), 1)
    }

    func testOpeningLatestSchemaShapeWithStaleVersionRepairsTheVersionAndPreservesData() throws {
        let url = temporaryDirectory.appendingPathComponent("library.sqlite")
        try makeSchemaV2Database(at: url, photoCount: 2)
        let migrated = try PhotoIndexStore(databaseURL: url)
        migrated.close()

        let raw = try SQLiteDatabase(url: url)
        try raw.run("UPDATE schema_info SET value = '1' WHERE key = 'schemaVersion';")
        raw.close()

        let repaired = try PhotoIndexStore(databaseURL: url)
        defer { repaired.close() }

        XCTAssertEqual(try readSchemaVersion(at: url), PhotoIndexStore.schemaVersion)
        XCTAssertEqual(try repaired.photoCount(inLibrary: fixtureLibraryID), 2)
        XCTAssertTrue(try columnExists("photo", "variant_of", at: url))
        XCTAssertTrue(try columnExists("photo", "variant_name", at: url))
        XCTAssertTrue(try columnExists("photo", "rating", at: url))
        XCTAssertTrue(try columnExists("photo", "flag", at: url))
    }

    func testMigrationBackfillsNormalizedFilenameAndDirectory() throws {
        let url = temporaryDirectory.appendingPathComponent("library.sqlite")
        try makeSchemaV1Database(at: url, photoCount: 0)
        try seedV1Photo(
            at: url, libraryID: fixtureLibraryID, relativePath: "Trip/Sub/Café.ARW"
        )

        let store = try PhotoIndexStore(databaseURL: url)
        defer { store.close() }

        let page = try store.page(
            matching: LibraryQuery(scope: .all, sort: .captureDateDescending),
            after: nil,
            limit: 10
        )
        XCTAssertEqual(page.photos.first?.relativePath, "Trip/Sub/Café.ARW")

        // Backfilled relative_directory must support folder-scope queries.
        let folderPage = try store.page(
            matching: LibraryQuery(
                scope: .folder(libraryID: fixtureLibraryID, relativePath: "Trip"),
                sort: .captureDateDescending
            ),
            after: nil,
            limit: 10
        )
        XCTAssertEqual(folderPage.photos.count, 1)

        // The normalized/decomposed spelling of "Café" must still be found,
        // proving the backfill applied NFC + locale-independent lowercasing.
        let searched = try store.page(
            matching: LibraryQuery(
                scope: .all, filenameSearch: "cafe\u{0301}", sort: .filenameAscending
            ),
            after: nil,
            limit: 10
        )
        XCTAssertEqual(searched.photos.count, 1)
    }

    func testReopeningAnAlreadyMigratedDatabaseIsANoOp() throws {
        let url = temporaryDirectory.appendingPathComponent("library.sqlite")
        try makeSchemaV1Database(at: url, photoCount: 1)
        let store = try PhotoIndexStore(databaseURL: url)
        store.close()

        // Reopening a v2 database must not attempt to add the v2 columns a
        // second time (which would throw "duplicate column name").
        let reopened = try PhotoIndexStore(databaseURL: url)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.photoCount(inLibrary: fixtureLibraryID), 1)
    }

    func testFreshlyCreatedDatabaseIsTheLatestSchema() throws {
        let url = temporaryDirectory.appendingPathComponent("fresh.sqlite")
        let store = try PhotoIndexStore(databaseURL: url)
        defer { store.close() }

        XCTAssertEqual(try readSchemaVersion(at: url), 4)
        XCTAssertTrue(try columnExists("photo", "filename_normalized", at: url))
        XCTAssertTrue(try columnExists("library", "source_kind", at: url))
        XCTAssertTrue(try columnExists("photo", "variant_of", at: url))
        XCTAssertTrue(try columnExists("photo", "variant_name", at: url))
        XCTAssertTrue(try tableExists("photo_keyword", at: url))
        XCTAssertTrue(try columnExists("photo", "rating", at: url))
        XCTAssertTrue(try columnExists("photo", "flag", at: url))
    }

    // MARK: - Fixture helpers

    /// Builds a database matching the pre-Task-1 schema exactly, bypassing
    /// `PhotoIndexStore` (whose `init` now always migrates), so the migration
    /// path itself has something real to exercise.
    private func makeSchemaV1Database(at url: URL, photoCount: Int) throws {
        let db = try SQLiteDatabase(url: url)
        defer { db.close() }
        try db.execute("""
            CREATE TABLE schema_info (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE library (
                id           TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                root_path    TEXT NOT NULL,
                is_online    INTEGER NOT NULL DEFAULT 1,
                is_writable  INTEGER NOT NULL DEFAULT 1,
                last_scan_at REAL
            );

            CREATE TABLE photo (
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

            CREATE INDEX photo_library_path ON photo (library_id, relative_path);
            CREATE INDEX photo_fingerprint ON photo (edge_digest, file_size);
            CREATE INDEX photo_capture_date ON photo (library_id, capture_date);
            """)
        try db.run(
            "INSERT INTO schema_info (key, value) VALUES ('schemaVersion', '1');"
        )
        try db.run(
            """
            INSERT INTO library (id, display_name, root_path, is_online, is_writable, last_scan_at)
            VALUES (?, 'Fixture', '/tmp/fixture', 1, 1, NULL);
            """,
            [.text(fixtureLibraryID.description)]
        )
        for index in 0..<photoCount {
            try insertV1Photo(
                into: db,
                libraryID: fixtureLibraryID,
                relativePath: String(format: "DSC%04d.ARW", index),
                captureDate: 1_700_000_000 + Double(index)
            )
        }
    }

    /// Builds a database matching the pre-Task-3.5 schema exactly (v1 shape
    /// plus every v1 -> v2 `ALTER TABLE`, stamped `schemaVersion = 2`) --
    /// what every released version up to this one actually produces.
    private func makeSchemaV2Database(at url: URL, photoCount: Int) throws {
        try makeSchemaV1Database(at: url, photoCount: photoCount)
        let db = try SQLiteDatabase(url: url)
        defer { db.close() }
        try db.execute("""
            ALTER TABLE library ADD COLUMN source_kind TEXT NOT NULL DEFAULT 'externalFolder';
            ALTER TABLE library ADD COLUMN connection_state TEXT NOT NULL DEFAULT 'ready';
            ALTER TABLE library ADD COLUMN scan_state TEXT NOT NULL DEFAULT 'idle';
            ALTER TABLE photo ADD COLUMN filename_normalized TEXT NOT NULL DEFAULT '';
            ALTER TABLE photo ADD COLUMN relative_directory TEXT NOT NULL DEFAULT '';
            ALTER TABLE photo ADD COLUMN last_edit_at REAL;

            CREATE INDEX photo_all_capture_desc ON photo (capture_date DESC, photo_id);
            CREATE INDEX photo_library_capture_desc ON photo (library_id, capture_date DESC, photo_id);
            CREATE INDEX photo_library_directory_capture_desc
                ON photo (library_id, relative_directory, capture_date DESC, photo_id);
            CREATE INDEX photo_filename_normalized ON photo (filename_normalized, photo_id);
            CREATE INDEX photo_last_edit_desc ON photo (last_edit_at DESC, photo_id)
                WHERE last_edit_at IS NOT NULL;
            """)
        try db.run("UPDATE schema_info SET value = '2' WHERE key = 'schemaVersion';")
    }

    private func seedV1Photo(at url: URL, libraryID: LibraryID, relativePath: String) throws {
        let db = try SQLiteDatabase(url: url)
        defer { db.close() }
        try insertV1Photo(
            into: db, libraryID: libraryID, relativePath: relativePath, captureDate: 1_700_000_000
        )
    }

    private func insertV1Photo(
        into db: SQLiteDatabase,
        libraryID: LibraryID,
        relativePath: String,
        captureDate: Double
    ) throws {
        try db.run(
            """
            INSERT INTO photo (
                photo_id, library_id, relative_path, file_size, edge_digest,
                capture_date, pixel_width, pixel_height, status, has_edits, last_seen_at
            ) VALUES (?, ?, ?, 1024, ?, ?, 6000, 4000, 'ready', 0, ?);
            """,
            [
                .text(PhotoID().description),
                .text(libraryID.description),
                .text(relativePath),
                .text("digest-\(relativePath)"),
                .real(captureDate),
                .real(1_700_000_000)
            ]
        )
    }

    private func readSchemaVersion(at url: URL) throws -> Int {
        let db = try SQLiteDatabase(url: url)
        defer { db.close() }
        let rows = try db.query(
            "SELECT value FROM schema_info WHERE key = 'schemaVersion';"
        ) { Int($0.string(0)) ?? -1 }
        return rows.first ?? -1
    }

    private func columnExists(_ table: String, _ column: String, at url: URL) throws -> Bool {
        let db = try SQLiteDatabase(url: url)
        defer { db.close() }
        let rows = try db.query("PRAGMA table_info(\(table));") { $0.string(1) }
        return rows.contains(column)
    }

    private func tableExists(_ table: String, at url: URL) throws -> Bool {
        let db = try SQLiteDatabase(url: url)
        defer { db.close() }
        let rows = try db.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?;",
            [.text(table)]
        ) { $0.string(0) }
        return !rows.isEmpty
    }
}
