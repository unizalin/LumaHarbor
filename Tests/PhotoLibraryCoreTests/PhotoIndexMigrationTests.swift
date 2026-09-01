import XCTest
@testable import PhotoLibraryCore

/// Spec §8: schema v1 -> v2 must happen inside one transaction. A database
/// deleted mid-migration must still be either fully v1 or fully v2, never a
/// half-applied mix — the index is disposable cache, so the fallback the app
/// offers on failure is "rescan", not "attempt a partial repair".
final class PhotoIndexMigrationTests: TemporaryDirectoryTestCase {
    private let fixtureLibraryID = LibraryID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private enum TestError: Error {
        case injected
    }

    func testOpeningV1DatabaseMigratesAtomicallyToV2() throws {
        let url = temporaryDirectory.appendingPathComponent("library.sqlite")
        try makeSchemaV1Database(at: url, photoCount: 2)

        let store = try PhotoIndexStore(databaseURL: url)
        defer { store.close() }

        XCTAssertEqual(PhotoIndexStore.schemaVersion, 2)
        XCTAssertEqual(try store.photoCount(inLibrary: fixtureLibraryID), 2)
        XCTAssertEqual(try store.page(
            matching: LibraryQuery(scope: .all, sort: .captureDateDescending),
            after: nil,
            limit: 100
        ).photos.count, 2)
    }

    func testMigrationFailureRollsBackEveryV2Change() throws {
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

    func testFreshlyCreatedDatabaseIsSchemaV2() throws {
        let url = temporaryDirectory.appendingPathComponent("fresh.sqlite")
        let store = try PhotoIndexStore(databaseURL: url)
        defer { store.close() }

        XCTAssertEqual(try readSchemaVersion(at: url), 2)
        XCTAssertTrue(try columnExists("photo", "filename_normalized", at: url))
        XCTAssertTrue(try columnExists("library", "source_kind", at: url))
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
}
