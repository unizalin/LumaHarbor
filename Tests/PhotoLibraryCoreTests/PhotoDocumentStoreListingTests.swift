import Foundation
import XCTest
@testable import PhotoLibraryCore

/// Task 4: `PhotoDocumentStore.committedDocuments()` and
/// `PhotoLibraryService.refreshAppStorageProjection(from:)`.
final class PhotoDocumentStoreListingTests: TemporaryDirectoryTestCase {

    // MARK: - Fixtures

    @discardableResult
    private func makeSourceFile(
        named name: String = "fixture.ARW",
        byteCount: Int = 4_096,
        pattern: UInt8 = 0x5A
    ) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try Data(repeating: pattern, count: byteCount).write(to: url)
        return url
    }

    private func makeStore(subdirectory: String = "Store") -> (store: PhotoDocumentStore, rootURL: URL) {
        let rootURL = temporaryDirectory.appendingPathComponent(subdirectory, isDirectory: true)
        return (PhotoDocumentStore(rootURL: rootURL), rootURL)
    }

    private func writeCorruptRecord(id: UUID, at rootURL: URL) throws {
        let recordURL = rootURL.appendingPathComponent("Records/\(id.uuidString).json")
        try FileManager.default.createDirectory(
            at: recordURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not valid json {".utf8).write(to: recordURL)
    }

    private func recordJSON(id: UUID, rootURL: URL) throws -> [String: Any]? {
        let recordURL = rootURL.appendingPathComponent("Records/\(id.uuidString).json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any]
    }

    // MARK: - committedDocuments()

    /// The exact scenario the Task 4 plan calls for: one committed App
    /// copy, one committed in-place record, one still-`.pending` record,
    /// and one corrupt record file. Only the two committed, readable
    /// records come back, in stable UUID order; the corrupt one is
    /// reported separately; the pending one is neither promoted nor
    /// deleted.
    func testCommittedDocumentsReturnsOnlyCommittedReadableRecordsInStableUUIDOrder() async throws {
        let (store, rootURL) = makeStore()

        let appCopySource = try makeSourceFile(named: "copy-source.ARW", pattern: 0xAA)
        let appCopyCreation = try await store.importCopy(of: appCopySource, bookmarkData: nil)
        await store.finalizeCreation(appCopyCreation)

        let inPlaceSource = try makeSourceFile(named: "in-place-source.ARW", pattern: 0xBB)
        let inPlaceCreation = try await store.openInPlace(inPlaceSource, bookmarkData: nil)
        await store.finalizeCreation(inPlaceCreation)

        // Left `.pending` on purpose -- never finalized.
        let pendingSource = try makeSourceFile(named: "pending-source.ARW", pattern: 0xCC)
        let pendingCreation = try await store.importCopy(of: pendingSource, bookmarkData: nil)

        let corruptID = UUID()
        try writeCorruptRecord(id: corruptID, at: rootURL)

        let listing = try await store.committedDocuments()

        let committedIDs = Set(listing.documents.map(\.id))
        XCTAssertEqual(committedIDs, [appCopyCreation.document.id, inPlaceCreation.document.id])
        XCTAssertEqual(
            listing.documents.map(\.id.uuidString),
            listing.documents.map(\.id.uuidString).sorted(),
            "committedDocuments() must return documents in stable ascending UUID order"
        )
        XCTAssertFalse(
            listing.documents.contains { $0.id == pendingCreation.document.id },
            "a still-pending record must never appear among committed documents"
        )

        XCTAssertEqual(Array(listing.failures.keys), [corruptID], "the corrupt record must be reported, and only it")
        XCTAssertNotNil(listing.failures[corruptID])
        XCTAssertNil(listing.failures[pendingCreation.document.id], "a pending record is skipped, not reported as a failure")

        // The pending record's data itself is untouched: still on disk,
        // still `.pending` -- neither promoted nor deleted by this listing.
        let pendingJSON = try recordJSON(id: pendingCreation.document.id, rootURL: rootURL)
        XCTAssertEqual(pendingJSON?["lifecycleState"] as? String, "pending")
        let documentsDirectory = rootURL.appendingPathComponent("Documents")
            .appendingPathComponent(pendingCreation.document.id.uuidString)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: documentsDirectory.path),
            "a pending app-copy's working file must not be deleted by committedDocuments()"
        )
    }

    /// Calling `committedDocuments()` is a pure read -- doing it (even
    /// repeatedly) must never itself change a pending record's state.
    func testCommittedDocumentsNeverPromotesOrDeletesAPendingRecordAcrossRepeatedCalls() async throws {
        let (store, rootURL) = makeStore()
        let source = try makeSourceFile()
        let pendingCreation = try await store.openInPlace(source, bookmarkData: nil)

        _ = try await store.committedDocuments()
        _ = try await store.committedDocuments()
        let listing = try await store.committedDocuments()

        XCTAssertTrue(listing.documents.isEmpty)
        XCTAssertTrue(listing.failures.isEmpty)
        let pendingJSON = try recordJSON(id: pendingCreation.document.id, rootURL: rootURL)
        XCTAssertEqual(pendingJSON?["lifecycleState"] as? String, "pending")
    }

    /// A committed App-copy record whose working file has since gone
    /// missing (disk corruption, manual tampering) must be reported as a
    /// failure, not silently dropped and not silently listed as if it were
    /// still readable.
    func testCommittedDocumentsReportsAMissingWorkingFileAsAFailureNotADocument() async throws {
        let (store, rootURL) = makeStore()
        let source = try makeSourceFile()
        let creation = try await store.importCopy(of: source, bookmarkData: nil)
        await store.finalizeCreation(creation)

        let copyDirectory = rootURL.appendingPathComponent("Documents")
            .appendingPathComponent(creation.document.id.uuidString)
        try FileManager.default.removeItem(at: copyDirectory)

        let listing = try await store.committedDocuments()

        XCTAssertTrue(listing.documents.isEmpty, "a document whose working file is gone must not be listed as readable")
        XCTAssertNotNil(listing.failures[creation.document.id])
    }

    /// A store with no `Records/` directory yet (nothing has ever been
    /// created) must report an empty listing, not throw.
    func testCommittedDocumentsReturnsEmptyBeforeAnythingHasEverBeenCreated() async throws {
        let (store, _) = makeStore()
        let listing = try await store.committedDocuments()
        XCTAssertTrue(listing.documents.isEmpty)
        XCTAssertTrue(listing.failures.isEmpty)
    }

    // MARK: - PhotoLibraryService.refreshAppStorageProjection(from:)

    private func makeService(subdirectory: String = "AppSupport") throws -> PhotoLibraryService {
        try PhotoLibraryService(locations: ApplicationSupportLocations(baseURL: try makeSubdirectory(subdirectory)))
    }

    private func makeDocument(storageMode: PhotoDocumentStorageMode, workingURL: URL) -> PhotoDocument {
        let fingerprint = FileFingerprint(fileSize: 1_024, edgeDigest: UUID().uuidString)
        return PhotoDocument(
            storageMode: storageMode,
            workingURL: workingURL,
            sourceURL: workingURL,
            sourceBookmarkData: nil,
            sourceFingerprint: fingerprint,
            workingFingerprint: fingerprint
        )
    }

    /// Only `.appCopy` documents are projected into the `.appStorage`
    /// scope -- an `.inPlace` document (already reachable through its own
    /// indexed source, if any) must never appear here.
    func testRefreshAppStorageProjectionOnlyProjectsAppCopyDocuments() async throws {
        let service = try makeService()
        let appCopyURL = try writeFile(Data("copy".utf8), at: temporaryDirectory.appendingPathComponent("Copies/copy.ARW"))
        let inPlaceURL = try writeFile(Data("external".utf8), at: temporaryDirectory.appendingPathComponent("External/external.ARW"))

        let appCopyDocument = makeDocument(storageMode: .appCopy, workingURL: appCopyURL)
        let inPlaceDocument = makeDocument(storageMode: .inPlace, workingURL: inPlaceURL)

        try await service.refreshAppStorageProjection(from: [appCopyDocument, inPlaceDocument])

        let projected = try await service.photos(inLibrary: .appStorage)
        XCTAssertEqual(projected.map(\.id), [PhotoID(appCopyDocument.id)])

        let indexStore = await service.indexStore
        let page = try indexStore.page(
            matching: LibraryQuery(scope: .appStorage, sort: .captureDateDescending),
            after: nil,
            limit: 100
        )
        XCTAssertEqual(page.photos.map(\.id), [PhotoID(appCopyDocument.id)], "the appStorage LibraryScope must find the projected copy")

        let folder = await service.library(id: .appStorage)
        XCTAssertEqual(folder?.sourceKind, .appStorage)
        XCTAssertEqual(folder?.photoCount, 1)
    }

    /// Idempotent and rebuildable: a document no longer present in a later
    /// call's `documents` (rolled back, removed, or no longer committed)
    /// must have its projected row pruned, not left stale.
    func testRefreshAppStorageProjectionPrunesDocumentsNoLongerCommitted() async throws {
        let service = try makeService()
        let firstURL = try writeFile(Data("first".utf8), at: temporaryDirectory.appendingPathComponent("Copies/first.ARW"))
        let secondURL = try writeFile(Data("second".utf8), at: temporaryDirectory.appendingPathComponent("Copies/second.ARW"))
        let first = makeDocument(storageMode: .appCopy, workingURL: firstURL)
        let second = makeDocument(storageMode: .appCopy, workingURL: secondURL)

        try await service.refreshAppStorageProjection(from: [first, second])
        let afterFirstCall = try await service.photos(inLibrary: .appStorage)
        XCTAssertEqual(Set(afterFirstCall.map(\.id)), [PhotoID(first.id), PhotoID(second.id)])

        try await service.refreshAppStorageProjection(from: [first])
        let afterSecondCall = try await service.photos(inLibrary: .appStorage)
        XCTAssertEqual(afterSecondCall.map(\.id), [PhotoID(first.id)])

        let folder = await service.library(id: .appStorage)
        XCTAssertEqual(folder?.photoCount, 1)
    }

    /// Calling with an empty (or all-pruned) set must not throw, and must
    /// leave the `.appStorage` scope empty rather than erroring on a join
    /// against a library row with no photos.
    func testRefreshAppStorageProjectionHandlesNoCommittedAppCopiesAtAll() async throws {
        let service = try makeService()
        try await service.refreshAppStorageProjection(from: [])
        let projected = try await service.photos(inLibrary: .appStorage)
        XCTAssertTrue(projected.isEmpty)
    }
}
