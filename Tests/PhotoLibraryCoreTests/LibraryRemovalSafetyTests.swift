import XCTest
@testable import PhotoLibraryCore

/// Task 8 Step 1 (destructive safety): `PhotoLibraryService.removeLibrary(id:)`'s
/// own doc comment already says it "must never touch the source root itself"
/// -- these tests are what actually proves that, with a recording `FileManager`
/// standing in for every file-system call the removal path could make, rather
/// than trusting the doc comment on its own.
///
/// Every fake `FileManager` elsewhere in this test target (`FileBookmarkStoreTests`,
/// `SidecarRepositoryTests`) fails one specific call to prove an error path.
/// This one instead *records* every call it sees and never fails anything --
/// the thing under test is which paths `removeLibrary` touches, not how it
/// reacts to a failure.
final class LibraryRemovalSafetyTests: TemporaryDirectoryTestCase {
    private final class RecordingFileManager: FileManager, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(selector: String, path: String)] = []

        var recordedCalls: [(selector: String, path: String)] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        func clear() {
            lock.lock()
            calls.removeAll()
            lock.unlock()
        }

        private func record(_ selector: String, _ path: String) {
            lock.lock()
            calls.append((selector, path))
            lock.unlock()
        }

        override func fileExists(atPath path: String) -> Bool {
            record("fileExists(atPath:)", path)
            return super.fileExists(atPath: path)
        }

        override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            record("fileExists(atPath:isDirectory:)", path)
            return super.fileExists(atPath: path, isDirectory: isDirectory)
        }

        override func removeItem(at url: URL) throws {
            record("removeItem(at:)", url.path)
            try super.removeItem(at: url)
        }

        override func removeItem(atPath path: String) throws {
            record("removeItem(atPath:)", path)
            try super.removeItem(atPath: path)
        }

        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            record("moveItem(at:to:)", srcURL.path)
            try super.moveItem(at: srcURL, to: dstURL)
        }

        override func contentsOfDirectory(
            at url: URL,
            includingPropertiesForKeys keys: [URLResourceKey]?,
            options mask: FileManager.DirectoryEnumerationOptions = []
        ) throws -> [URL] {
            record("contentsOfDirectory(at:...)", url.path)
            return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        }
    }

    private var supportDirectory: URL!
    private var libraryRoot: URL!
    private var rawFileURL: URL!
    private var recordingFileManager: RecordingFileManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        supportDirectory = try makeSubdirectory("ApplicationSupport")
        libraryRoot = try makeSubdirectory("Photos")
        rawFileURL = libraryRoot.appendingPathComponent("DSC0001.ARW")
        try writeFile(Data(repeating: 0x2A, count: 4_096), at: rawFileURL)
        recordingFileManager = RecordingFileManager()
    }

    private var locations: ApplicationSupportLocations {
        ApplicationSupportLocations(baseURL: supportDirectory)
    }

    private func makeService() throws -> PhotoLibraryService {
        let bookmarkStore = FileBookmarkStore(
            directoryURL: locations.bookmarksDirectoryURL,
            fileManager: recordingFileManager
        )
        return try PhotoLibraryService(locations: locations, bookmarkStore: bookmarkStore)
    }

    private func addLibrary(
        _ service: PhotoLibraryService,
        at url: URL,
        displayName: String
    ) async throws -> LibraryFolder {
        do {
            return try await service.addLibrary(at: url, displayName: displayName)
        } catch let error as LibraryError {
            if case .bookmark = error {
                throw XCTSkip("This host can't create security-scoped bookmarks: \(error)")
            }
            throw error
        }
    }

    // MARK: - Never touches the source root

    func testRemoveLibraryNeverInvokesFileManagerAgainstTheSourceRoot() async throws {
        let service = try makeService()
        let library = try await addLibrary(service, at: libraryRoot, displayName: "Removal Test")
        let sourceRootPath = libraryRoot.standardizedFileURL.path

        recordingFileManager.clear()
        try await service.removeLibrary(id: library.id)

        let offendingCalls = recordingFileManager.recordedCalls.filter { $0.path.hasPrefix(sourceRootPath) }
        XCTAssertTrue(
            offendingCalls.isEmpty,
            "removeLibrary touched the source root: \(offendingCalls)"
        )
    }

    // MARK: - Only touches its own bookmark root

    func testRemoveLibraryOnlyTouchesTheBookmarkRoot() async throws {
        let service = try makeService()
        let library = try await addLibrary(service, at: libraryRoot, displayName: "Removal Test")
        let bookmarksPath = locations.bookmarksDirectoryURL.standardizedFileURL.path

        recordingFileManager.clear()
        try await service.removeLibrary(id: library.id)

        let calls = recordingFileManager.recordedCalls
        XCTAssertFalse(calls.isEmpty, "Expected removeLibrary to touch its own bookmark record")
        for call in calls {
            XCTAssertTrue(
                call.path.hasPrefix(bookmarksPath),
                "removeLibrary made a file call outside its bookmark root: \(call)"
            )
        }
    }

    // MARK: - The source itself is provably untouched

    func testRemoveLibraryLeavesTheRawFileAndItsBytesUntouched() async throws {
        let service = try makeService()
        let library = try await addLibrary(service, at: libraryRoot, displayName: "Removal Test")
        let originalBytes = try Data(contentsOf: rawFileURL)

        try await service.removeLibrary(id: library.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: rawFileURL.path), "The RAW file was deleted")
        let bytesAfter = try Data(contentsOf: rawFileURL)
        XCTAssertEqual(bytesAfter, originalBytes, "removeLibrary altered the source RAW file's bytes")
    }

    func testRemoveLibraryLeavesThePortableManifestContainerUntouched() async throws {
        let service = try makeService()
        let library = try await addLibrary(service, at: libraryRoot, displayName: "Removal Test")
        let repository = FileSidecarRepository(libraryRootURL: libraryRoot)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: repository.containerURL.path),
            "Test setup didn't actually write a manifest to check against"
        )

        try await service.removeLibrary(id: library.id)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: repository.containerURL.path),
            "removeLibrary deleted the source's .lumaharbor container"
        )
    }

    // MARK: - Only the removed library's local state is affected

    func testRemoveLibraryDoesNotDisturbAnUnrelatedLibrary() async throws {
        let service = try makeService()
        let removed = try await addLibrary(service, at: libraryRoot, displayName: "Removed")

        let otherRoot = try makeSubdirectory("PhotosOther")
        try writeFile(Data(repeating: 0x07, count: 128), at: otherRoot.appendingPathComponent("DSC0002.ARW"))
        let kept = try await addLibrary(service, at: otherRoot, displayName: "Kept")

        try await service.removeLibrary(id: removed.id)

        let afterRemoved = await service.library(id: removed.id)
        XCTAssertNil(afterRemoved, "The removed library must be gone from the in-memory registry")
        let afterKept = await service.library(id: kept.id)
        XCTAssertNotNil(afterKept, "removeLibrary must not disturb an unrelated library")
    }
}
