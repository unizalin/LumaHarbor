import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Phase 3 Task 3.5: "virtual copy" -- an independently-editable duplicate
/// of a RAW photo that shares the original's own file on disk (never
/// duplicated) but has its own identity, sidecar and adjustments.
/// End to end through `PhotoLibraryService`, a real temp directory, and the
/// real `FileSidecarRepository`/`PhotoIndexStore` -- exactly the layers a
/// scan/create/delete round trip actually touches.
final class VirtualCopyServiceTests: TemporaryDirectoryTestCase {
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

    // MARK: - Creation

    func testCreatingAVirtualCopySharesTheOriginalsFileButHasItsOwnIdentity() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("DSC0001.ARW"))
        let library = try await addLibrary(service, at: root)
        try await runScan(service, libraryID: library.id)
        let seededPhotos = try await service.photos(inLibrary: library.id)
        let original = try XCTUnwrap(seededPhotos.first)

        let copy = try await service.createVirtualCopy(of: original, named: "B&W")

        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.variantOf, original.id)
        XCTAssertEqual(copy.variantName, "B&W")
        XCTAssertEqual(copy.relativePath, original.relativePath, "a virtual copy shares the original's own file")
        XCTAssertEqual(copy.fingerprint, original.fingerprint)
        XCTAssertNil(original.variantOf, "the original itself must never look like anyone's copy")
        XCTAssertTrue(copy.isVirtualCopy)
        XCTAssertFalse(original.isVirtualCopy)

        // Never duplicated on disk: exactly one RAW file still exists.
        let rawFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".ARW") }
        XCTAssertEqual(rawFiles, ["DSC0001.ARW"])
    }

    func testTheNewCopyStartsWithTheOriginalsCurrentAdjustmentsButThenEditsIndependently() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("DSC0001.ARW"))
        let library = try await addLibrary(service, at: root)
        try await runScan(service, libraryID: library.id)
        let seededPhotos = try await service.photos(inLibrary: library.id)
        let original = try XCTUnwrap(seededPhotos.first)
        try await service.saveAdjustments(PhotoAdjustments(exposure: 1.5), for: original)

        let copy = try await service.createVirtualCopy(of: original)
        let copyAdjustmentsAfterCreate = try await service.adjustments(for: copy)
        XCTAssertEqual(copyAdjustmentsAfterCreate.exposure, 1.5, "the copy starts as an exact duplicate of the original's current edit")

        // Editing the copy afterward must never touch the original.
        try await service.saveAdjustments(PhotoAdjustments(exposure: -2.0, contrast: 30), for: copy)
        let copyAdjustmentsAfterEdit = try await service.adjustments(for: copy)
        XCTAssertEqual(copyAdjustmentsAfterEdit.exposure, -2.0)
        XCTAssertEqual(copyAdjustmentsAfterEdit.contrast, 30)
        let originalAdjustmentsAfterCopyEdit = try await service.adjustments(for: original)
        XCTAssertEqual(originalAdjustmentsAfterCopyEdit.exposure, 1.5, "editing the copy must never change the original's own adjustments")
    }

    /// Spec §6.1 rule 7: a virtual copy always starts with neutral curation,
    /// even when the original it was duplicated from is rated/flagged.
    func testVirtualCopyStartsWithNeutralCurationEvenWhenTheOriginalIsCurated() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("DSC0001.ARW"))
        let library = try await addLibrary(service, at: root)
        try await runScan(service, libraryID: library.id)
        let seededPhotos = try await service.photos(inLibrary: library.id)
        let original = try XCTUnwrap(seededPhotos.first)
        let indexStore = await service.indexStore
        try indexStore.setRating(5, for: original.id)
        try indexStore.setFlag(.pick, for: original.id)

        let copy = try await service.createVirtualCopy(of: original)

        XCTAssertEqual(copy.rating, 0)
        XCTAssertEqual(copy.flag, .none)
        XCTAssertEqual(copy.keywords, [])

        // And it survives a rescan without picking up the original's curation.
        try await runScan(service, libraryID: library.id)
        let afterRescan = try await service.photos(inLibrary: library.id)
        let reloadedCopy = try XCTUnwrap(afterRescan.first { $0.id == copy.id })
        XCTAssertEqual(reloadedCopy.rating, 0)
        XCTAssertEqual(reloadedCopy.flag, .none)
    }

    func testACopyOfACopyPointsDirectlyAtThatCopyNotAtSomeRootOriginal() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("DSC0001.ARW"))
        let library = try await addLibrary(service, at: root)
        try await runScan(service, libraryID: library.id)
        let seededPhotos = try await service.photos(inLibrary: library.id)
        let original = try XCTUnwrap(seededPhotos.first)

        let firstCopy = try await service.createVirtualCopy(of: original)
        let secondCopy = try await service.createVirtualCopy(of: firstCopy)

        XCTAssertEqual(secondCopy.variantOf, firstCopy.id)
        XCTAssertEqual(secondCopy.relativePath, original.relativePath)
    }

    // MARK: - Persistence: a copy survives a rescan

    func testAVirtualCopySurvivesARescanOfTheSameFolder() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("DSC0001.ARW"))
        let library = try await addLibrary(service, at: root)
        try await runScan(service, libraryID: library.id)
        let seededPhotos = try await service.photos(inLibrary: library.id)
        let original = try XCTUnwrap(seededPhotos.first)
        let copy = try await service.createVirtualCopy(of: original, named: "Copy 1")

        try await runScan(service, libraryID: library.id)

        let afterRescan = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(afterRescan.count, 2, "the original and its copy must both still be there after a rescan")
        let reloadedCopy = try XCTUnwrap(afterRescan.first { $0.id == copy.id })
        XCTAssertEqual(reloadedCopy.variantOf, original.id)
        XCTAssertEqual(reloadedCopy.variantName, "Copy 1")
        let reloadedOriginal = try XCTUnwrap(afterRescan.first { $0.id == original.id })
        XCTAssertNil(reloadedOriginal.variantOf)
    }

    func testEditingAVirtualCopyPreservesItsIdentityInTheSidecar() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("DSC0001.ARW"))
        let library = try await addLibrary(service, at: root)
        try await runScan(service, libraryID: library.id)
        let photos = try await service.photos(inLibrary: library.id)
        let original = try XCTUnwrap(photos.first)
        let copy = try await service.createVirtualCopy(of: original)

        try await service.saveAdjustments(PhotoAdjustments(exposure: -1.25), for: copy)

        let repository = FileSidecarRepository(libraryRootURL: root)
        let editedSidecar = try XCTUnwrap(try repository.loadSidecar(for: copy.id))
        XCTAssertEqual(editedSidecar.variantOf, original.id)
    }

    /// A copy's own sidecar is what makes it real (spec §8.1). If its
    /// `library.json` record ever outlives its sidecar -- e.g.
    /// `deleteVirtualCopy(_:)` already removed the sidecar (the
    /// correctness gate) but its own best-effort manifest cleanup happened
    /// not to land, the same tolerance `createVirtualCopy`'s own manifest
    /// write already has -- a later rescan reconciling copy records back
    /// into the index (so a copy survives an index rebuild, see
    /// `LibraryLifecycleTests.testDeletingTheLocalIndexAndCacheStillRebuildsAVirtualCopyFromTheDrive`)
    /// must never resurrect a copy whose sidecar is actually gone.
    func testRescanNeverResurrectsACopyWhoseSidecarIsGoneButWhoseManifestRecordLingers() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("DSC0001.ARW"))
        let library = try await addLibrary(service, at: root)
        try await runScan(service, libraryID: library.id)
        let seededPhotos = try await service.photos(inLibrary: library.id)
        let original = try XCTUnwrap(seededPhotos.first)
        let copy = try await service.createVirtualCopy(of: original, named: "Ghost")

        // A normal delete removes the sidecar (the correctness gate), the
        // index row, and -- here, nothing broke it -- the manifest record
        // too. Reinserting a stale manifest record afterward simulates
        // exactly the one gap `deleteVirtualCopy`'s own best-effort
        // manifest write can leave in practice: sidecar and index row
        // genuinely gone, but `library.json` still names the copy.
        try await service.deleteVirtualCopy(copy)
        let repository = FileSidecarRepository(libraryRootURL: root)
        var manifest = try XCTUnwrap(try repository.loadManifest())
        manifest.upsert(PhotoRecord(
            photoID: copy.id,
            relativePath: original.relativePath,
            fingerprint: original.fingerprint,
            variantOf: original.id,
            variantName: "Ghost"
        ))
        try repository.write(manifest: manifest)

        try await runScan(service, libraryID: library.id)

        let afterRescan = try await service.photos(inLibrary: library.id)
        XCTAssertNil(
            afterRescan.first { $0.id == copy.id },
            "a copy whose sidecar is gone must never be resurrected by a rescan just because a stale manifest record still names it"
        )
    }

    // MARK: - Deletion

    func testDeletingAVirtualCopyRemovesOnlyItsOwnSidecarAndIndexRow() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("DSC0001.ARW"))
        let library = try await addLibrary(service, at: root)
        try await runScan(service, libraryID: library.id)
        let seededPhotos = try await service.photos(inLibrary: library.id)
        let original = try XCTUnwrap(seededPhotos.first)
        try await service.saveAdjustments(PhotoAdjustments(exposure: 1.0), for: original)
        let copy = try await service.createVirtualCopy(of: original)
        let copySidecarURL = root.appendingPathComponent(".lumaharbor/edits/\(copy.id.sidecarFilename)")
        let originalSidecarURL = root.appendingPathComponent(".lumaharbor/edits/\(original.id.sidecarFilename)")
        let rawURL = root.appendingPathComponent("DSC0001.ARW")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copySidecarURL.path))

        try await service.deleteVirtualCopy(copy)

        XCTAssertFalse(FileManager.default.fileExists(atPath: copySidecarURL.path), "the copy's own sidecar must be gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalSidecarURL.path), "the original's own sidecar must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawURL.path), "the shared RAW file must never be touched")
        let remaining = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(remaining.map(\.id), [original.id])
        let originalAdjustmentsAfterDelete = try await service.adjustments(for: original)
        XCTAssertEqual(originalAdjustmentsAfterDelete.exposure, 1.0, "the original's own adjustments must be completely unaffected")
    }

    func testDeletingOneCopyNeverDeletesAnotherCopyOfTheSameOriginal() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("DSC0001.ARW"))
        let library = try await addLibrary(service, at: root)
        try await runScan(service, libraryID: library.id)
        let seededPhotos = try await service.photos(inLibrary: library.id)
        let original = try XCTUnwrap(seededPhotos.first)
        let copyA = try await service.createVirtualCopy(of: original, named: "A")
        let copyB = try await service.createVirtualCopy(of: original, named: "B")

        try await service.deleteVirtualCopy(copyA)

        let remaining = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(Set(remaining.map(\.id)), [original.id, copyB.id])
    }

    func testDeletingTheOriginalPhotoThroughThisAPIIsRefused() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("DSC0001.ARW"))
        let library = try await addLibrary(service, at: root)
        try await runScan(service, libraryID: library.id)
        let seededPhotos = try await service.photos(inLibrary: library.id)
        let original = try XCTUnwrap(seededPhotos.first)

        do {
            try await service.deleteVirtualCopy(original)
            XCTFail("must refuse to delete a photo that isn't a virtual copy")
        } catch LibraryError.notAVirtualCopy(let id) {
            XCTAssertEqual(id, original.id)
        }

        let remaining = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(remaining.map(\.id), [original.id], "the refused call must leave everything exactly as it was")
    }
}
