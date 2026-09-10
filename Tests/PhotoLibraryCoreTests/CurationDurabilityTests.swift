import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Spec §11.1 #4 and the design's §3 "已驗證現況" gap: rating/flag/keyword
/// must survive a deleted-and-rebuilt local SQLite index. This file starts
/// (Task 0, P0) by pinning today's known gap as an explicit, named baseline;
/// Task 5 (P1) then flips these same assertions once the sidecar becomes the
/// curation authority, so the diff is a reviewable, intentional behavior
/// change rather than a silently rewritten test.
final class CurationDurabilityTests: TemporaryDirectoryTestCase {
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

    private func makeLibraryWithOnePhoto() async throws -> (service: PhotoLibraryService, libraryID: LibraryID, photoID: PhotoID) {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("DSC0001.ARW"))
        let library = try await addLibrary(service, at: root)
        try await runScan(service, libraryID: library.id)
        let seeded = try await service.photos(inLibrary: library.id)
        let photo = try XCTUnwrap(seeded.first)
        return (service, library.id, photo.id)
    }

    func testTodayIndexRebuildLosesRatingFlagAndKeywords() async throws {
        let (service, libraryID, photoID) = try await makeLibraryWithOnePhoto()
        let indexStore = await service.indexStore
        try indexStore.setRating(5, for: photoID)
        try indexStore.setFlag(.pick, for: photoID)
        try indexStore.setKeywords(["Sunset"], for: photoID)

        try await service.resetRebuildableLocalData()
        try await runScan(service, libraryID: libraryID)

        let photo = try await service.indexStore.photo(id: photoID)
        XCTAssertEqual(photo?.rating, 0, "documents today's known gap: SQLite-only curation does not survive a rebuild")
        XCTAssertEqual(photo?.flag, PhotoFlag.none)
        XCTAssertEqual(photo?.keywords, [])
    }
}
