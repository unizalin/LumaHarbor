import XCTest
@testable import PhotoLibraryCore

/// Spec Gate C: `FileBookmarkStore` had no direct coverage before this file —
/// bookmark persistence was only exercised indirectly through
/// `LibraryLifecycleTests`, which skips whenever the host can't mint a real
/// security-scoped bookmark. These tests avoid that runtime dependency
/// entirely: they drive the store with plain `StoredBookmark` values and
/// synthetic `bookmarkData`, so they're deterministic on any host.
final class FileBookmarkStoreTests: TemporaryDirectoryTestCase {
    private final class DirectoryReadFailingFileManager: FileManager, @unchecked Sendable {
        override func contentsOfDirectory(
            at url: URL,
            includingPropertiesForKeys keys: [URLResourceKey]?,
            options mask: FileManager.DirectoryEnumerationOptions = []
        ) throws -> [URL] {
            throw CocoaError(.fileReadNoPermission)
        }
    }

    private final class FalseNegativeDirectoryFileManager: FileManager, @unchecked Sendable {
        override func fileExists(atPath path: String) -> Bool {
            false
        }

        override func contentsOfDirectory(
            at url: URL,
            includingPropertiesForKeys keys: [URLResourceKey]?,
            options mask: FileManager.DirectoryEnumerationOptions = []
        ) throws -> [URL] {
            throw CocoaError(.fileReadNoPermission)
        }
    }

    private final class WrappedPermissionDirectoryFileManager: FileManager, @unchecked Sendable {
        override func contentsOfDirectory(
            at url: URL,
            includingPropertiesForKeys keys: [URLResourceKey]?,
            options mask: FileManager.DirectoryEnumerationOptions = []
        ) throws -> [URL] {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.Code.fileReadNoPermission.rawValue,
                userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOENT)]
            )
        }
    }

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

    // MARK: - Fail-closed registry loading

    func testAnyInvalidJSONRecordMakesLoadAllThrow() throws {
        let invalidRecords: [Data] = [
            Data("{ not valid json".utf8),
            Data(),
            Data(#"{"unrelated":"shape"}"#.utf8)
        ]

        for (index, invalidRecord) in invalidRecords.enumerated() {
            let directory = try makeSubdirectory("Invalid-\(index)")
            let store = FileBookmarkStore(directoryURL: directory)
            try store.save(stubBookmark(displayName: "Good"))
            try invalidRecord.write(
                to: directory.appendingPathComponent("\(LibraryID().rawValue.uuidString).json")
            )

            XCTAssertThrowsError(try store.loadAll(), "Invalid record at index \(index) must fail the registry")
        }
    }

    func testDirectoryReadFailurePropagates() {
        let store = FileBookmarkStore(
            directoryURL: temporaryDirectory,
            fileManager: DirectoryReadFailingFileManager()
        )

        XCTAssertThrowsError(try store.loadAll())
    }

    func testFileExistsFalseDoesNotHideDirectoryListingPermissionFailure() {
        let store = FileBookmarkStore(
            directoryURL: temporaryDirectory,
            fileManager: FalseNegativeDirectoryFileManager()
        )

        XCTAssertThrowsError(try store.loadAll()) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoPermission)
        }
    }

    func testJSONRecordDataReadFailureMakesLoadAllThrow() throws {
        let recordDirectory = temporaryDirectory.appendingPathComponent(
            "\(LibraryID().rawValue.uuidString).json",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: recordDirectory,
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(try makeStore().loadAll())
    }

    func testNoSuchFileClassificationMatrixDoesNotLetKnownPermissionErrorsInheritENOENT() {
        let cocoaNoSuchFile = CocoaError(.fileReadNoSuchFile)
        let posixNoSuchFile = POSIXError(.ENOENT)
        let unknownWrapper = NSError(
            domain: "LumaHarborTests.UnknownWrapper",
            code: 1,
            userInfo: [NSUnderlyingErrorKey: posixNoSuchFile]
        )
        let cocoaPermissionWrappingENOENT = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileReadNoPermission.rawValue,
            userInfo: [NSUnderlyingErrorKey: posixNoSuchFile]
        )
        let posixPermissionWrappingENOENT = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EACCES),
            userInfo: [NSUnderlyingErrorKey: posixNoSuchFile]
        )

        XCTAssertTrue(FileSystemError.isNoSuchFile(cocoaNoSuchFile))
        XCTAssertTrue(FileSystemError.isNoSuchFile(posixNoSuchFile))
        XCTAssertTrue(FileSystemError.isNoSuchFile(unknownWrapper))
        XCTAssertFalse(FileSystemError.isNoSuchFile(cocoaPermissionWrappingENOENT))
        XCTAssertFalse(FileSystemError.isNoSuchFile(posixPermissionWrappingENOENT))
    }

    func testWrappedCocoaPermissionErrorStillMakesLoadAllThrow() {
        let store = FileBookmarkStore(
            directoryURL: temporaryDirectory,
            fileManager: WrappedPermissionDirectoryFileManager()
        )

        XCTAssertThrowsError(try store.loadAll()) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSCocoaErrorDomain)
            XCTAssertEqual(nsError.code, CocoaError.Code.fileReadNoPermission.rawValue)
        }
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
