import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Spec §12.2's end-to-end path: authorise a folder, scan it, index it, save an
/// edit, then prove a relaunch — and a deleted local index — recover.
///
/// The RAW files here are deliberately not real. `CIRAWFilter` can't decode
/// them, which is exactly the "damaged file" case spec §10 requires the scan to
/// survive; decoding a genuine Sony `.ARW` is covered by the fixture-gated tests
/// and by manual acceptance on Apple Silicon.
final class LibraryLifecycleTests: TemporaryDirectoryTestCase {
    private var supportDirectory: URL!
    private var libraryRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        supportDirectory = try makeSubdirectory("ApplicationSupport")
        libraryRoot = try makeSubdirectory("Photos")
    }

    private var locations: ApplicationSupportLocations {
        ApplicationSupportLocations(baseURL: supportDirectory)
    }

    private func makeService() throws -> PhotoLibraryService {
        try PhotoLibraryService(locations: locations)
    }

    private func seedPhotos(_ names: [String]) throws {
        for (index, name) in names.enumerated() {
            // Distinct bytes so each file gets its own fingerprint.
            var data = Data(repeating: 0x30, count: 512)
            data[0] = UInt8(index)
            try writeFile(data, at: libraryRoot.appendingPathComponent(name))
        }
    }

    /// Adding a library needs a real security-scoped bookmark. If the host
    /// refuses to mint one, skip rather than report a false failure — the
    /// bookmark path itself is on the manual acceptance list.
    private func addLibrary(
        _ service: PhotoLibraryService
    ) async throws -> LibraryFolder {
        do {
            return try await service.addLibrary(at: libraryRoot, displayName: "Test Drive")
        } catch let error as LibraryError {
            if case .bookmark = error {
                throw XCTSkip("This host can't create security-scoped bookmarks: \(error)")
            }
            throw error
        }
    }

    @discardableResult
    private func runScan(
        _ service: PhotoLibraryService,
        libraryID: LibraryID
    ) async -> LibraryScanResult? {
        var result: LibraryScanResult?
        for await event in service.scan(libraryID: libraryID) {
            if case .finished(let finished) = event { result = finished }
        }
        return result
    }

    // MARK: - Add, scan, index

    func testAddingAFolderCreatesThePortableLibraryFile() async throws {
        let service = try makeService()
        let library = try await addLibrary(service)

        let repository = FileSidecarRepository(libraryRootURL: libraryRoot)
        let manifest = try XCTUnwrap(try repository.loadManifest())
        XCTAssertEqual(manifest.libraryID, library.id)
        XCTAssertEqual(manifest.schemaVersion, LibraryManifest.currentSchemaVersion)
    }

    func testScanIndexesEveryRawAndRecordsThemInTheManifest() async throws {
        try seedPhotos(["DSC0001.ARW", "Trip/DSC0002.ARW", "Trip/DSC0003.ARW"])
        let service = try makeService()
        let library = try await addLibrary(service)

        let scan = await runScan(service, libraryID: library.id)
        let result = try XCTUnwrap(scan)
        XCTAssertEqual(result.indexedCount, 3)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertNil(result.manifestWriteFailure)

        let photos = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(photos.count, 3)

        let manifest = try XCTUnwrap(
            try FileSidecarRepository(libraryRootURL: libraryRoot).loadManifest()
        )
        XCTAssertEqual(manifest.photos.count, 3)
        XCTAssertNotNil(manifest.lastSuccessfulScanAt)
    }

    func testUndecodableFilesAreFlaggedAndTheScanKeepsGoing() async throws {
        // Spec §10: mark the single failure, don't abort the folder.
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW"])
        let service = try makeService()
        let library = try await addLibrary(service)
        _ = await runScan(service, libraryID: library.id)

        let photos = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(photos.count, 2)
        for photo in photos {
            XCTAssertNotEqual(photo.status, .ready)
            XCTAssertNotNil(photo.statusMessage, "A failed photo must explain itself")
        }
    }

    func testRescanIsStableAndKeepsPhotoIdentities() async throws {
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW"])
        let service = try makeService()
        let library = try await addLibrary(service)

        _ = await runScan(service, libraryID: library.id)
        let firstPass = try await service.photos(inLibrary: library.id)

        _ = await runScan(service, libraryID: library.id)
        let secondPass = try await service.photos(inLibrary: library.id)

        XCTAssertEqual(
            Set(firstPass.map(\.id)),
            Set(secondPass.map(\.id)),
            "A rescan must not mint new identities — edits are keyed on them"
        )
        XCTAssertEqual(secondPass.count, 2)
    }

    func testDeletedFilesLeaveTheIndexOnRescan() async throws {
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW"])
        let service = try makeService()
        let library = try await addLibrary(service)
        _ = await runScan(service, libraryID: library.id)

        try FileManager.default.removeItem(
            at: libraryRoot.appendingPathComponent("DSC0002.ARW")
        )
        _ = await runScan(service, libraryID: library.id)

        let photos = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(photos.map(\.relativePath), ["DSC0001.ARW"])
    }

    // MARK: - Edits

    func testAdjustmentsSurviveARelaunch() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let service = try makeService()
        let library = try await addLibrary(service)
        _ = await runScan(service, libraryID: library.id)

        let indexed = try await service.photos(inLibrary: library.id)
        let photo = try XCTUnwrap(indexed.first)
        let edit = PhotoAdjustments(exposure: 1.25, contrast: 30, shadows: -20)
        try await service.saveAdjustments(edit, for: photo)

        // "Relaunch": a brand new service reading the same Application Support.
        let relaunched = try makeService()
        let restored = try await relaunched.restoreLibraries()
        let restoredLibrary = try XCTUnwrap(restored.first)
        XCTAssertEqual(restoredLibrary.id, library.id)

        let restoredPhotos = try await relaunched.photos(inLibrary: library.id)
        let restoredPhoto = try XCTUnwrap(restoredPhotos.first)
        let restoredEdit = try await relaunched.adjustments(for: restoredPhoto)
        XCTAssertEqual(restoredEdit, edit)
    }

    func testAnUneditedPhotoOpensAtNeutral() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let service = try makeService()
        let library = try await addLibrary(service)
        _ = await runScan(service, libraryID: library.id)

        let indexed = try await service.photos(inLibrary: library.id)
        let photo = try XCTUnwrap(indexed.first)
        let adjustments = try await service.adjustments(for: photo)
        XCTAssertEqual(adjustments, .neutral)
    }

    func testSavingWritesAPortableSidecarBesideThePhotos() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let service = try makeService()
        let library = try await addLibrary(service)
        _ = await runScan(service, libraryID: library.id)

        let indexed = try await service.photos(inLibrary: library.id)
        let photo = try XCTUnwrap(indexed.first)
        try await service.saveAdjustments(PhotoAdjustments(exposure: 2), for: photo)

        let repository = FileSidecarRepository(libraryRootURL: libraryRoot)
        let sidecar = try XCTUnwrap(try repository.loadSidecar(for: photo.id))
        XCTAssertEqual(sidecar.adjustments.exposure, 2)
        XCTAssertEqual(sidecar.sourceRelativePath, "DSC0001.ARW")
        XCTAssertEqual(sidecar.decoder.kind, "coreImage")
    }

    func testTheOriginalRawIsNeverModified() async throws {
        // Spec §13.6: content and modification time of the .ARW must not change.
        try seedPhotos(["DSC0001.ARW"])
        let rawURL = libraryRoot.appendingPathComponent("DSC0001.ARW")
        let before = try Data(contentsOf: rawURL)
        let beforeAttributes = try FileManager.default.attributesOfItem(atPath: rawURL.path)

        let service = try makeService()
        let library = try await addLibrary(service)
        _ = await runScan(service, libraryID: library.id)
        let indexed = try await service.photos(inLibrary: library.id)
        let photo = try XCTUnwrap(indexed.first)
        try await service.saveAdjustments(PhotoAdjustments(exposure: 3), for: photo)

        let afterAttributes = try FileManager.default.attributesOfItem(atPath: rawURL.path)
        let after = try Data(contentsOf: rawURL)
        XCTAssertEqual(after, before)
        XCTAssertEqual(
            afterAttributes[.modificationDate] as? Date,
            beforeAttributes[.modificationDate] as? Date
        )
    }

    // MARK: - Rebuilding local data

    func testDeletingTheLocalIndexAndCacheStillRebuildsFromTheDrive() async throws {
        // Spec §13.9 — the whole point of keeping the SSD authoritative.
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW"])
        let service = try makeService()
        let library = try await addLibrary(service)
        _ = await runScan(service, libraryID: library.id)

        let indexed = try await service.photos(inLibrary: library.id)
        let photo = try XCTUnwrap(indexed.first)
        let edit = PhotoAdjustments(exposure: -1, vibrance: 40)
        try await service.saveAdjustments(edit, for: photo)
        let originalPhotos = try await service.photos(inLibrary: library.id)
        let originalIDs = Set(originalPhotos.map(\.id))

        // The product-owned reset: closes the live SQLite connection before
        // deleting library.sqlite and its sidecars, then recreates a fresh,
        // empty database in place — never a manual `indexStore.close()`.
        try await service.resetRebuildableLocalData()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: locations.databaseURL.path),
            "The reset must recreate the database, not just delete it"
        )
        let emptiedRows = try await service.photos(inLibrary: library.id)
        XCTAssertTrue(emptiedRows.isEmpty, "Photo rows must stay empty until the next scan")

        // Bookmarks survive the reset: the library is still known, no relink
        // needed, and the normal service path rebuilds the index.
        let stillKnown = await service.library(id: library.id)
        XCTAssertNotNil(stillKnown)
        _ = await runScan(service, libraryID: library.id)

        let rebuiltPhotos = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(rebuiltPhotos.count, 2)
        XCTAssertEqual(
            Set(rebuiltPhotos.map(\.id)),
            originalIDs,
            "Identities come from library.json, so edits must survive the rebuild"
        )

        let rebuiltPhoto = try XCTUnwrap(rebuiltPhotos.first { $0.id == photo.id })
        let rebuiltEdit = try await service.adjustments(for: rebuiltPhoto)
        XCTAssertEqual(rebuiltEdit, edit)
    }

    func testResettingIsRefusedWhileAScanIsActiveAndSucceedsOnceItEnds() async throws {
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW"])
        let gate = InspectionGate()
        let decoder = GatedScanDecoder()
        decoder.gate = gate
        let service = try PhotoLibraryService(
            locations: locations,
            decoder: decoder,
            scanner: FolderScanner(batchSize: 1)
        )
        let library = try await addLibrary(service)

        let consumer = Task {
            for await _ in service.scan(libraryID: library.id) {}
        }

        let deadline = Date().addingTimeInterval(5)
        while gate.started == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(gate.started, 0, "The scan never reached the gate")

        do {
            try await service.resetRebuildableLocalData()
            XCTFail("Resetting while a scan is active should have been refused")
        } catch let error as LibraryError {
            guard case .resetRefusedWhileScanning = error else {
                return XCTFail("Expected .resetRefusedWhileScanning, got \(error)")
            }
        }

        // The live index must still be usable — the refused reset must not
        // have closed it out from under the active scan.
        _ = try await service.photos(inLibrary: library.id)

        consumer.cancel()
        gate.release()
        await consumer.value

        // The consumer's `for await` loop can finish slightly before the
        // producer-side `performScan` actor method has itself returned and
        // decremented the active-scan count, so poll rather than assume it
        // has already reached zero.
        var resetSucceeded = false
        let resetDeadline = Date().addingTimeInterval(5)
        while Date() < resetDeadline {
            do {
                try await service.resetRebuildableLocalData()
                resetSucceeded = true
                break
            } catch LibraryError.resetRefusedWhileScanning {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        XCTAssertTrue(resetSucceeded, "Reset never succeeded after the scan ended")
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.databaseURL.path))
    }

    // MARK: - Offline and read-only

    func testAnOfflineLibraryIsReportedRatherThanForgotten() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let service = try makeService()
        let library = try await addLibrary(service)
        _ = await runScan(service, libraryID: library.id)

        // Simulate the SSD being unplugged.
        try FileManager.default.removeItem(at: libraryRoot)

        let refreshed = try await service.refreshAvailability(libraryID: library.id)
        XCTAssertFalse(refreshed.isOnline)
        XCTAssertEqual(refreshed.availability, .offline)
        XCTAssertFalse(refreshed.availability.allowsEditing)
        XCTAssertFalse(refreshed.availability.allowsDecoding)

        // Spec §10: the index and its cached thumbnails stay put.
        let cached = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(cached.count, 1)
    }

    func testScanningAnOfflineLibraryFailsWithSomethingActionable() async throws {
        let service = try makeService()
        let library = try await addLibrary(service)
        try FileManager.default.removeItem(at: libraryRoot)

        var failure: LibraryError?
        for await event in service.scan(libraryID: library.id) {
            if case .failed(let error) = event { failure = error }
        }
        let error = try XCTUnwrap(failure)
        guard case .offline = error else {
            return XCTFail("Expected .offline, got \(error)")
        }
        XCTAssertNotNil(error.errorDescription)
        XCTAssertNotNil(error.recoverySuggestion)
    }

    func testReconnectingKeepsTheLibraryIdentityAndItsEdits() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let service = try makeService()
        let library = try await addLibrary(service)
        _ = await runScan(service, libraryID: library.id)

        let indexed = try await service.photos(inLibrary: library.id)
        let photo = try XCTUnwrap(indexed.first)
        let edit = PhotoAdjustments(exposure: 0.75)
        try await service.saveAdjustments(edit, for: photo)

        // The drive comes back at a different mount point, which is the whole
        // reason spec §7 refuses to guess and asks the user to re-pick.
        let newRoot = try makeSubdirectory("PhotosRemounted")
        try FileManager.default.removeItem(at: newRoot)
        try FileManager.default.moveItem(at: libraryRoot, to: newRoot)

        let relinked: LibraryFolder
        do {
            relinked = try await service.relink(libraryID: library.id, to: newRoot)
        } catch let error as LibraryError {
            if case .bookmark = error {
                throw XCTSkip("This host can't create security-scoped bookmarks")
            }
            throw error
        }

        XCTAssertEqual(relinked.id, library.id, "Relinking must not fork the library")
        XCTAssertTrue(relinked.isOnline)

        _ = await runScan(service, libraryID: library.id)
        let reconnectedPhotos = try await service.photos(inLibrary: library.id)
        let reconnected = try XCTUnwrap(reconnectedPhotos.first { $0.id == photo.id })
        let reconnectedEdit = try await service.adjustments(for: reconnected)
        XCTAssertEqual(reconnectedEdit, edit)
    }

    func testReadOnlyLibraryBrowsesButRefusesToSave() async throws {
        try XCTSkipUnless(canSimulateReadOnlyDirectory, "Test must not run as root")

        try seedPhotos(["DSC0001.ARW"])
        let service = try makeService()
        let library = try await addLibrary(service)
        _ = await runScan(service, libraryID: library.id)
        let indexed = try await service.photos(inLibrary: library.id)
        let photo = try XCTUnwrap(indexed.first)

        try setPosixPermissions(0o555, at: libraryRoot)
        defer { try? setPosixPermissions(0o755, at: libraryRoot) }

        let refreshed = try await service.refreshAvailability(libraryID: library.id)
        XCTAssertEqual(refreshed.availability, .readOnly)
        XCTAssertFalse(refreshed.availability.allowsEditing)
        XCTAssertTrue(refreshed.availability.allowsDecoding, "Browsing must still work")

        // Spec §10: saving is refused with an explanation, not silently dropped.
        do {
            try await service.saveAdjustments(PhotoAdjustments(exposure: 1), for: photo)
            XCTFail("Saving to a read-only drive should have thrown")
        } catch let error as LibraryError {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertNotNil(error.recoverySuggestion)
        }
    }

    func testScanningAReadOnlyLibraryStillIndexesAndSaysWhyTheManifestIsStale() async throws {
        try XCTSkipUnless(canSimulateReadOnlyDirectory, "Test must not run as root")

        try seedPhotos(["DSC0001.ARW"])
        let service = try makeService()
        let library = try await addLibrary(service)

        try setPosixPermissions(0o555, at: libraryRoot)
        defer { try? setPosixPermissions(0o755, at: libraryRoot) }

        let scan = await runScan(service, libraryID: library.id)
        let result = try XCTUnwrap(scan)
        XCTAssertEqual(result.indexedCount, 1, "A locked drive must still be browsable")
        XCTAssertNotNil(
            result.manifestWriteFailure,
            "The user needs to know the portable copy wasn't updated"
        )
    }
}
