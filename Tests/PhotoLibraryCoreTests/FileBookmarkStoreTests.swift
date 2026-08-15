import XCTest
@testable import PhotoLibraryCore

/// Spec Gate C: `FileBookmarkStore` had no direct coverage before this file —
/// bookmark persistence was only exercised indirectly through
/// `LibraryLifecycleTests`, which skips whenever the host can't mint a real
/// security-scoped bookmark. These tests avoid that runtime dependency
/// entirely: they drive the store with plain `StoredBookmark` values and
/// synthetic `bookmarkData`, so they're deterministic on any host.
final class FileBookmarkStoreTests: TemporaryDirectoryTestCase {
    private func makeStore() -> FileBookmarkStore {
        FileBookmarkStore(directoryURL: temporaryDirectory)
    }

    private func stubBookmark(
        libraryID: LibraryID = LibraryID(),
        displayName: String = "Trip Photos",
        lastKnownPath: String = "/Volumes/SSD/Trip",
        bookmarkData: Data = Data([0x01, 0x02, 0x03]),
        addedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> StoredBookmark {
        StoredBookmark(
            libraryID: libraryID,
            displayName: displayName,
            lastKnownPath: lastKnownPath,
            bookmarkData: bookmarkData,
            addedAt: addedAt
        )
    }

    // MARK: - Round-trip

    func testSaveThenLoadRoundTripsAllFields() throws {
        let store = makeStore()
        let bookmark = stubBookmark(
            displayName: "Summer Trip",
            lastKnownPath: "/Volumes/SSD/Summer",
            bookmarkData: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            addedAt: Date(timeIntervalSince1970: 1_650_000_000)
        )

        try store.save(bookmark)
        let loaded = try store.load(libraryID: bookmark.libraryID)

        XCTAssertEqual(loaded, bookmark)
    }

    func testLoadOfAnUnknownLibraryIDReturnsNil() throws {
        let store = makeStore()
        let loaded = try store.load(libraryID: LibraryID())
        XCTAssertNil(loaded)
    }

    func testSaveOverwritesAnExistingBookmarkForTheSameLibraryID() throws {
        let store = makeStore()
        let libraryID = LibraryID()
        try store.save(stubBookmark(libraryID: libraryID, displayName: "Old Name"))
        try store.save(stubBookmark(libraryID: libraryID, displayName: "New Name"))

        let loaded = try store.load(libraryID: libraryID)
        XCTAssertEqual(loaded?.displayName, "New Name")

        let all = try store.loadAll()
        XCTAssertEqual(all.count, 1)
    }

    // MARK: - loadAll ordering

    func testLoadAllReturnsBookmarksSortedByAddedAt() throws {
        let store = makeStore()
        let middle = stubBookmark(displayName: "Middle", addedAt: Date(timeIntervalSince1970: 200))
        let earliest = stubBookmark(displayName: "Earliest", addedAt: Date(timeIntervalSince1970: 100))
        let latest = stubBookmark(displayName: "Latest", addedAt: Date(timeIntervalSince1970: 300))

        // Saved out of order on purpose: ordering must come from `addedAt`,
        // not insertion or filename order.
        try store.save(middle)
        try store.save(latest)
        try store.save(earliest)

        let all = try store.loadAll()
        XCTAssertEqual(all.map(\.displayName), ["Earliest", "Middle", "Latest"])
    }

    func testLoadAllOnAMissingDirectoryReturnsEmptyRatherThanThrowing() throws {
        let missingDirectory = temporaryDirectory.appendingPathComponent("does-not-exist")
        let store = FileBookmarkStore(directoryURL: missingDirectory)
        try XCTAssertEqual(store.loadAll(), [])
    }

    // MARK: - Corruption isolation

    func testACorruptBookmarkFileIsSkippedWhileOthersStillLoad() throws {
        let store = makeStore()
        let good1 = stubBookmark(displayName: "Good One", addedAt: Date(timeIntervalSince1970: 100))
        let good2 = stubBookmark(displayName: "Good Two", addedAt: Date(timeIntervalSince1970: 200))
        try store.save(good1)
        try store.save(good2)

        // Drop a malformed JSON file directly into the bookmarks directory —
        // this is the "one unreadable bookmark can't cost the user access to
        // their other folders" guarantee documented on the type.
        let corruptURL = temporaryDirectory
            .appendingPathComponent("\(LibraryID().rawValue.uuidString).json")
        try Data("{ not valid json".utf8).write(to: corruptURL)

        let all = try store.loadAll()
        XCTAssertEqual(Set(all.map(\.displayName)), Set(["Good One", "Good Two"]))
    }

    func testAnEmptyFileIsSkippedWhileOthersStillLoad() throws {
        let store = makeStore()
        let good = stubBookmark(displayName: "Good")
        try store.save(good)

        let emptyURL = temporaryDirectory
            .appendingPathComponent("\(LibraryID().rawValue.uuidString).json")
        try Data().write(to: emptyURL)

        let all = try store.loadAll()
        XCTAssertEqual(all.map(\.displayName), ["Good"])
    }

    // MARK: - Ignoring unrelated files

    func testLoadAllIgnoresNonJSONFiles() throws {
        let store = makeStore()
        try store.save(stubBookmark(displayName: "Good"))

        try Data("not a bookmark".utf8).write(
            to: temporaryDirectory.appendingPathComponent("notes.txt")
        )
        try Data([0x00]).write(
            to: temporaryDirectory.appendingPathComponent(".DS_Store")
        )

        let all = try store.loadAll()
        XCTAssertEqual(all.map(\.displayName), ["Good"])
    }

    func testLoadAllIgnoresAJSONFileThatDoesNotDecodeAsAStoredBookmark() throws {
        let store = makeStore()
        try store.save(stubBookmark(displayName: "Good"))

        let unrelatedURL = temporaryDirectory
            .appendingPathComponent("\(LibraryID().rawValue.uuidString).json")
        try Data(#"{"unrelated":"shape"}"#.utf8).write(to: unrelatedURL)

        let all = try store.loadAll()
        XCTAssertEqual(all.map(\.displayName), ["Good"])
    }

    // MARK: - Remove

    func testRemoveDeletesTheBookmarkFile() throws {
        let store = makeStore()
        let bookmark = stubBookmark()
        try store.save(bookmark)

        try store.remove(libraryID: bookmark.libraryID)

        try XCTAssertNil(store.load(libraryID: bookmark.libraryID))
        try XCTAssertEqual(store.loadAll(), [])
    }

    func testRemoveOnlyDeletesTheMatchingLibrary() throws {
        let store = makeStore()
        let toRemove = stubBookmark(displayName: "Remove Me")
        let toKeep = stubBookmark(displayName: "Keep Me")
        try store.save(toRemove)
        try store.save(toKeep)

        try store.remove(libraryID: toRemove.libraryID)

        let all = try store.loadAll()
        XCTAssertEqual(all.map(\.displayName), ["Keep Me"])
    }

    func testRemoveIsIdempotentForAnUnknownLibraryID() throws {
        let store = makeStore()
        // Never saved; removing it must be a silent no-op, not a throw.
        XCTAssertNoThrow(try store.remove(libraryID: LibraryID()))
    }

    func testRemovingTwiceInARowDoesNotThrow() throws {
        let store = makeStore()
        let bookmark = stubBookmark()
        try store.save(bookmark)

        try store.remove(libraryID: bookmark.libraryID)
        XCTAssertNoThrow(try store.remove(libraryID: bookmark.libraryID))
    }
}
