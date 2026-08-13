import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Spec §8.3: the local index is a disposable cache. These tests cover what it
/// must store faithfully and that throwing it away is survivable.
final class PhotoIndexStoreTests: TemporaryDirectoryTestCase {
    private var databaseURL: URL!
    private var store: PhotoIndexStore!
    private var library: LibraryFolder!

    override func setUpWithError() throws {
        try super.setUpWithError()
        databaseURL = temporaryDirectory.appendingPathComponent("library.sqlite")
        store = try PhotoIndexStore(databaseURL: databaseURL)
        library = LibraryFolder(
            displayName: "SSD Photos",
            rootURL: URL(fileURLWithPath: "/Volumes/SSD/Photos", isDirectory: true)
        )
        try store.upsert(library: library)
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try super.tearDownWithError()
    }

    func testCreatesTheDatabaseFile() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
    }

    func testLibraryRoundTrips() throws {
        let loaded = try XCTUnwrap(try store.library(id: library.id))
        XCTAssertEqual(loaded.id, library.id)
        XCTAssertEqual(loaded.displayName, "SSD Photos")
        XCTAssertEqual(loaded.rootURL.path, "/Volumes/SSD/Photos")
    }

    func testUpsertingALibraryTwiceUpdatesRatherThanDuplicates() throws {
        var renamed = library!
        renamed.displayName = "Trip Drive"
        try store.upsert(library: renamed)

        let libraries = try store.libraries()
        XCTAssertEqual(libraries.count, 1)
        XCTAssertEqual(libraries.first?.displayName, "Trip Drive")
    }

    func testPhotoRoundTripsWithItsMetadata() throws {
        var photo = PhotoAsset.stub(libraryID: library.id)
        photo.metadata = RawMetadata(
            pixelWidth: 6_000,
            pixelHeight: 4_000,
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            cameraMake: "SONY",
            cameraModel: "ILCE-7M4",
            lensModel: "FE 35mm F1.8",
            isoSpeed: 400,
            shutterSpeed: 0.005,
            aperture: 1.8,
            orientation: 1
        )
        try store.upsert(photo: photo)

        let loaded = try XCTUnwrap(try store.photo(id: photo.id))
        XCTAssertEqual(loaded.relativePath, photo.relativePath)
        XCTAssertEqual(loaded.fingerprint, photo.fingerprint)
        XCTAssertEqual(loaded.metadata.cameraModel, "ILCE-7M4")
        XCTAssertEqual(loaded.metadata.isoSpeed, 400)
        XCTAssertEqual(loaded.metadata.aperture, 1.8)
        XCTAssertEqual(
            loaded.metadata.captureDate?.timeIntervalSince1970,
            1_700_000_000,
            accuracy: 0.001
        )
    }

    func testFailureStateSurvivesTheRoundTrip() throws {
        // Spec §10: an unsupported camera stays visible with its reason.
        var photo = PhotoAsset.stub(libraryID: library.id, status: .unsupported)
        photo.failureReason = "This camera's RAW format isn't supported yet."
        try store.upsert(photo: photo)

        let loaded = try XCTUnwrap(try store.photo(id: photo.id))
        XCTAssertEqual(loaded.status, .unsupported)
        XCTAssertEqual(loaded.failureReason, photo.failureReason)
    }

    func testBatchUpsertStoresEverything() throws {
        let photos = (0..<25).map { index in
            PhotoAsset.stub(
                libraryID: library.id,
                relativePath: String(format: "Trip/DSC%04d.ARW", index),
                fingerprint: .stub("digest-\(index)")
            )
        }
        try store.upsert(photos: photos)
        XCTAssertEqual(try store.photoCount(inLibrary: library.id), 25)
    }

    func testUpsertingTheSamePhotoUpdatesInPlace() throws {
        var photo = PhotoAsset.stub(libraryID: library.id)
        try store.upsert(photo: photo)

        photo.relativePath = "Moved/DSC0001.ARW"
        photo.status = .ready
        try store.upsert(photo: photo)

        XCTAssertEqual(try store.photoCount(inLibrary: library.id), 1)
        XCTAssertEqual(try store.photo(id: photo.id)?.relativePath, "Moved/DSC0001.ARW")
    }

    func testPhotosAreOrderedByCaptureTime() throws {
        func photo(_ path: String, capturedAt: TimeInterval) -> PhotoAsset {
            var asset = PhotoAsset.stub(
                libraryID: library.id, relativePath: path, fingerprint: .stub(path)
            )
            asset.metadata.captureDate = Date(timeIntervalSince1970: capturedAt)
            return asset
        }
        try store.upsert(photos: [
            photo("c.ARW", capturedAt: 300),
            photo("a.ARW", capturedAt: 100),
            photo("b.ARW", capturedAt: 200)
        ])

        XCTAssertEqual(
            try store.photos(inLibrary: library.id).map(\.relativePath),
            ["a.ARW", "b.ARW", "c.ARW"]
        )
    }

    func testPagingReturnsAWindow() throws {
        // Spec §11: the browser must never materialise a whole drive.
        let photos = (0..<10).map { index in
            PhotoAsset.stub(
                libraryID: library.id,
                relativePath: String(format: "DSC%04d.ARW", index),
                fingerprint: .stub("d\(index)")
            )
        }
        try store.upsert(photos: photos)

        let page = try store.photos(inLibrary: library.id, limit: 3, offset: 3)
        XCTAssertEqual(page.count, 3)
    }

    func testSweepingRemovesPhotosNotSeenByTheLatestScan() throws {
        var stale = PhotoAsset.stub(libraryID: library.id, relativePath: "Deleted.ARW")
        stale.lastSeenAt = Date(timeIntervalSince1970: 1_000)
        var fresh = PhotoAsset.stub(
            libraryID: library.id, relativePath: "Kept.ARW", fingerprint: .stub("kept")
        )
        fresh.lastSeenAt = Date(timeIntervalSince1970: 9_000)
        try store.upsert(photos: [stale, fresh])

        try store.removePhotos(
            inLibrary: library.id,
            notSeenSince: Date(timeIntervalSince1970: 5_000)
        )
        XCTAssertEqual(
            try store.photos(inLibrary: library.id).map(\.relativePath),
            ["Kept.ARW"]
        )
    }

    func testEditFlagCanBeToggled() throws {
        let photo = PhotoAsset.stub(libraryID: library.id)
        try store.upsert(photo: photo)
        XCTAssertEqual(try store.photo(id: photo.id)?.hasEdits, false)

        try store.setHasEdits(true, for: photo.id)
        XCTAssertEqual(try store.photo(id: photo.id)?.hasEdits, true)
    }

    func testAvailabilityCanBeUpdatedWhenTheDriveGoesAway() throws {
        try store.setLibraryAvailability(id: library.id, isOnline: false, isWritable: false)
        let loaded = try XCTUnwrap(try store.library(id: library.id))
        XCTAssertEqual(loaded.availability, .offline)
    }

    func testRemovingALibraryTakesItsPhotosWithIt() throws {
        try store.upsert(photo: PhotoAsset.stub(libraryID: library.id))
        try store.removeLibrary(id: library.id)

        XCTAssertTrue(try store.libraries().isEmpty)
        XCTAssertEqual(try store.photoCount(inLibrary: library.id), 0)
    }

    func testDataSurvivesReopeningTheDatabase() throws {
        let photo = PhotoAsset.stub(libraryID: library.id)
        try store.upsert(photo: photo)
        store.close()

        let reopened = try PhotoIndexStore(databaseURL: databaseURL)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.photo(id: photo.id)?.relativePath, photo.relativePath)
    }

    func testDeletingTheDatabaseFileLeavesARebuildableEmptyIndex() throws {
        // Spec §13.9: throwing the local index away must be recoverable.
        try store.upsert(photo: PhotoAsset.stub(libraryID: library.id))
        store.close()
        try FileManager.default.removeItem(at: databaseURL)

        let rebuilt = try PhotoIndexStore(databaseURL: databaseURL)
        defer { rebuilt.close() }
        XCTAssertTrue(try rebuilt.libraries().isEmpty)

        // And it accepts the same data again, which is what a rescan replays.
        try rebuilt.upsert(library: library)
        try rebuilt.upsert(photo: PhotoAsset.stub(libraryID: library.id))
        XCTAssertEqual(try rebuilt.photoCount(inLibrary: library.id), 1)
    }

    func testConcurrentWritesAreSerialisedSafely() async throws {
        let store = self.store!
        let libraryID = library.id
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try? store.upsert(photo: PhotoAsset.stub(
                        libraryID: libraryID,
                        relativePath: "DSC\(index).ARW",
                        fingerprint: .stub("d\(index)")
                    ))
                }
            }
        }
        XCTAssertEqual(try store.photoCount(inLibrary: libraryID), 20)
    }
}
