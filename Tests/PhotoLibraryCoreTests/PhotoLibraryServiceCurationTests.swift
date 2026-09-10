import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Spec §6.1 rule 5: only a successful sidecar write may update SQLite and
/// the UI. `PhotoLibraryService.setRating/setFlag/setKeywords` are the
/// sidecar-first mutation API this plan's Task 6 wires the Mac UI onto,
/// replacing the pre-existing direct `PhotoIndexStore.setRating/setFlag/
/// setKeywords` calls that never touched a sidecar at all.
final class PhotoLibraryServiceCurationTests: TemporaryDirectoryTestCase {
    private func makeService(supportName: String = "ApplicationSupport") throws -> PhotoLibraryService {
        let supportDirectory = try makeSubdirectory(supportName)
        return try PhotoLibraryService(
            locations: ApplicationSupportLocations(baseURL: supportDirectory),
            resourceIdentityResolver: SystemResourceIdentityResolver()
        )
    }

    private func addLibrary(_ service: PhotoLibraryService, at url: URL) async throws -> LibraryFolder {
        do {
            return try await service.addLibrary(at: url, displayName: nil, sourceKind: .externalFolder)
        } catch let error as LibraryError {
            if case .bookmark = error {
                throw XCTSkip("This host can't create security-scoped bookmarks: \(error)")
            }
            throw error
        }
    }

    @discardableResult
    private func runScan(_ service: PhotoLibraryService, libraryID: LibraryID) async throws -> LibraryScanResult {
        var result: LibraryScanResult?
        for await event in service.scan(libraryID: libraryID) {
            if case .finished(let scanResult) = event { result = scanResult }
        }
        return try XCTUnwrap(result)
    }

    private func makeLibraryWithOnePhoto() async throws -> (service: PhotoLibraryService, root: URL, photo: PhotoAsset) {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("DSC0001.ARW"))
        let library = try await addLibrary(service, at: root)
        try await runScan(service, libraryID: library.id)
        let seeded = try await service.photos(inLibrary: library.id)
        let photo = try XCTUnwrap(seeded.first)
        return (service, root, photo)
    }

    func testSetRatingWritesSidecarFirstThenProjectsIntoSQLite() async throws {
        let (service, root, photo) = try await makeLibraryWithOnePhoto()

        try await service.setRating(5, for: photo)

        let sidecar = try FileSidecarRepository(libraryRootURL: root).loadSidecar(for: photo.id)
        XCTAssertEqual(sidecar?.curation.rating, 5)
        XCTAssertEqual(sidecar?.schemaVersion, PhotoSidecar.currentSchemaVersion)
        let projected = try await service.indexStore.photo(id: photo.id)
        XCTAssertEqual(projected?.rating, 5)
    }

    func testSetRatingRejectsOutOfRangeValue() async throws {
        let (service, _, photo) = try await makeLibraryWithOnePhoto()

        do {
            try await service.setRating(9, for: photo)
            XCTFail("must reject an out-of-range rating")
        } catch LibraryQueryError.invalidRating(let value) {
            XCTAssertEqual(value, 9)
        }

        let projected = try await service.indexStore.photo(id: photo.id)
        XCTAssertEqual(projected?.rating, 0, "a rejected mutation must not have written anything")
    }

    func testSetFlagPreservesRatingAndKeywordsAlreadySet() async throws {
        let (service, root, photo) = try await makeLibraryWithOnePhoto()
        try await service.setRating(3, for: photo)
        try await service.setKeywords(["Dog"], for: photo)

        try await service.setFlag(.pick, for: photo)

        let sidecar = try FileSidecarRepository(libraryRootURL: root).loadSidecar(for: photo.id)
        XCTAssertEqual(sidecar?.curation.rating, 3)
        XCTAssertEqual(sidecar?.curation.flag, .pick)
        XCTAssertEqual(sidecar?.curation.keywords.map(\.displayValue), ["Dog"])
    }

    func testSetKeywordsRejectsABlankKeyword() async throws {
        let (service, _, photo) = try await makeLibraryWithOnePhoto()

        do {
            try await service.setKeywords([""], for: photo)
            XCTFail("must reject a blank keyword")
        } catch LibraryQueryError.invalidKeyword {
            // expected
        }
    }

    func testSetKeywordsReplacesThePreviousSet() async throws {
        let (service, root, photo) = try await makeLibraryWithOnePhoto()
        try await service.setKeywords(["Dog", "Beach"], for: photo)

        try await service.setKeywords(["Sunset"], for: photo)

        let sidecar = try FileSidecarRepository(libraryRootURL: root).loadSidecar(for: photo.id)
        XCTAssertEqual(sidecar?.curation.keywords.map(\.displayValue), ["Sunset"])
        let projected = try await service.indexStore.photo(id: photo.id)
        XCTAssertEqual(projected?.keywords.map(\.displayValue), ["Sunset"])
    }

    func testCurationForPhotoReadsSidecarNotSQLite() async throws {
        let (service, _, photo) = try await makeLibraryWithOnePhoto()
        // Write a mismatched value directly through the SQLite-only API,
        // bypassing the sidecar entirely -- the legacy path this plan
        // replaces. `curation(for:)` must not be fooled by it.
        let indexStore = await service.indexStore
        try indexStore.setRating(5, for: photo.id)

        let curation = try await service.curation(for: photo)

        XCTAssertEqual(curation.rating, 0, "the sidecar (absent -> neutral) is authoritative, not the SQLite-only value")
    }

    func testCurationMutationsNeverChangeAdjustmentsOrLastEditAt() async throws {
        let (service, _, photo) = try await makeLibraryWithOnePhoto()

        try await service.setRating(4, for: photo)

        let adjustments = try await service.adjustments(for: photo)
        XCTAssertEqual(adjustments, .neutral, "a curation-only mutation must never create a fake edit")
        let projected = try await service.indexStore.photo(id: photo.id)
        XCTAssertEqual(projected?.hasEdits, false)
        XCTAssertNil(projected?.lastEditAt)
    }

    func testSavingAdjustmentsPreservesExistingCuration() async throws {
        let (service, root, photo) = try await makeLibraryWithOnePhoto()
        try await service.setRating(4, for: photo)

        try await service.saveAdjustments(PhotoAdjustments(exposure: 1.0), for: photo)

        let sidecar = try FileSidecarRepository(libraryRootURL: root).loadSidecar(for: photo.id)
        XCTAssertEqual(sidecar?.curation.rating, 4, "an adjustment save must never silently reset curation to neutral")
        XCTAssertEqual(sidecar?.adjustments.exposure, 1.0)
    }

    func testSetRatingThrowsForAPhotoWhoseLibraryIsNotRegistered() async throws {
        let (service, _, _) = try await makeLibraryWithOnePhoto()
        let unknownPhoto = PhotoAsset.stub(libraryID: LibraryID(), relativePath: "Ghost.ARW")

        do {
            try await service.setRating(5, for: unknownPhoto)
            XCTFail("must throw for a library this service never registered")
        } catch let error as LibraryError {
            guard case .notFound = error else {
                return XCTFail("expected .notFound, got \(error)")
            }
        }
    }
}
