import Foundation
import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

final class RawRenderingCompatibilityPersistenceTests: TemporaryDirectoryTestCase {
    private func makeService() throws -> PhotoLibraryService {
        try PhotoLibraryService(
            locations: ApplicationSupportLocations(baseURL: try makeSubdirectory("ApplicationSupport")),
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

    private func scan(_ service: PhotoLibraryService, libraryID: LibraryID) async throws {
        for await _ in service.scan(libraryID: libraryID) {}
    }

    func testPersistenceMatrixUsesTheRequiredRuntimeDefaults() async throws {
        struct PolicyCase {
            let name: String
            let actual: RawRenderingCompatibility
            let expected: RawRenderingCompatibility
        }

        let legacyRecord = PhotoRecord(
            photoID: PhotoID(),
            relativePath: "Legacy.ARW",
            fingerprint: .stub("legacy"),
            lastSeenAt: .distantPast
        )
        let migratedRecord = PhotoRecord(
            photoID: PhotoID(),
            relativePath: "Migrated.ARW",
            fingerprint: .stub("migrated"),
            lastSeenAt: .distantPast,
            rawRenderingCompatibility: .native
        )

        let (store, _) = makeStore()
        let rawURL = try writeFile(Data(repeating: 0x01, count: 32), at: temporaryDirectory.appendingPathComponent("New.ARW"))
        let jpegURL = try writeFile(Data(repeating: 0x02, count: 32), at: temporaryDirectory.appendingPathComponent("New.jpg"))
        let rawDocument = try await store.openInPlace(rawURL, bookmarkData: nil).document
        let jpegDocument = try await store.openInPlace(jpegURL, bookmarkData: nil).document
        let rawAdjustments = try await store.loadAdjustments(documentID: rawDocument.id)
        let jpegAdjustments = try await store.loadAdjustments(documentID: jpegDocument.id)

        let cases = [
            PolicyCase(name: "schema 1 record without field", actual: legacyRecord.effectiveRawRenderingCompatibility, expected: .native),
            PolicyCase(name: "schema 2 legacy-migrated record", actual: migratedRecord.effectiveRawRenderingCompatibility, expected: .native),
            PolicyCase(name: "iPad new RAW document", actual: rawAdjustments.rawRenderingCompatibility, expected: .adobeProcess2012V1),
            PolicyCase(name: "iPad new JPEG document", actual: jpegAdjustments.rawRenderingCompatibility, expected: .native)
        ]
        for policyCase in cases {
            XCTAssertEqual(policyCase.actual, policyCase.expected, policyCase.name)
        }
    }

    func testNewRawRecordUsesAdobePolicyAndSidecarStillWins() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("New.ARW"))
        let library = try await addLibrary(service, at: root)
        try await scan(service, libraryID: library.id)

        let photos = try await service.photos(inLibrary: library.id)
        let photo = try XCTUnwrap(photos.first(where: { $0.relativePath == "New.ARW" }))
        let manifest = try XCTUnwrap(try FileSidecarRepository(libraryRootURL: root).loadManifest())
        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.record(for: photo.id)?.rawRenderingCompatibility, .adobeProcess2012V1)
        let defaultAdjustments = try await service.adjustments(for: photo)
        XCTAssertEqual(defaultAdjustments.rawRenderingCompatibility, .adobeProcess2012V1)

        try await service.saveAdjustments(.neutral(using: .native), for: photo)
        let sidecarAdjustments = try await service.adjustments(for: photo)
        XCTAssertEqual(sidecarAdjustments.rawRenderingCompatibility, .native)
    }

    func testExistingRecordAndVirtualCopyRetainTheirOriginalPolicyAcrossRescan() async throws {
        let service = try makeService()
        let root = try makeSubdirectory("Photos")
        try writeFile(Data(repeating: 0x30, count: 64), at: root.appendingPathComponent("Existing.ARW"))
        let library = try await addLibrary(service, at: root)
        try await scan(service, libraryID: library.id)
        let photos = try await service.photos(inLibrary: library.id)
        let original = try XCTUnwrap(photos.first)

        let repository = FileSidecarRepository(libraryRootURL: root)
        var manifest = try XCTUnwrap(try repository.loadManifest())
        var legacy = try XCTUnwrap(manifest.record(for: original.id))
        legacy.rawRenderingCompatibility = .native
        manifest.upsert(legacy)
        try repository.write(manifest: manifest)

        try await scan(service, libraryID: library.id)
        let copy = try await service.createVirtualCopy(of: original)
        let reloaded = try XCTUnwrap(try repository.loadManifest())
        XCTAssertEqual(reloaded.record(for: original.id)?.rawRenderingCompatibility, .native)
        XCTAssertEqual(reloaded.record(for: copy.id)?.rawRenderingCompatibility, .native)
    }

    func testManifestPolicyMigrationIsIdempotentAndInterruptedWritesLeaveTheOriginalUntouched() throws {
        let root = try makeSubdirectory("Migration")
        let repository = FileSidecarRepository(libraryRootURL: root)
        let legacy = PhotoRecord(
            photoID: PhotoID(),
            relativePath: "Legacy.ARW",
            fingerprint: .stub("legacy"),
            lastSeenAt: .distantPast
        )
        let original = LibraryManifest(schemaVersion: 1, photos: [legacy])
        try repository.write(manifest: original)
        let bytesBeforeMigration = try Data(contentsOf: repository.manifestURL)

        var interruptedMigration = try XCTUnwrap(try repository.loadManifest())
        XCTAssertTrue(interruptedMigration.migrateRawRenderingCompatibilityIfNeeded())
        XCTAssertEqual(try Data(contentsOf: repository.manifestURL), bytesBeforeMigration)

        var migrated = try XCTUnwrap(try repository.loadManifest())
        XCTAssertTrue(migrated.migrateRawRenderingCompatibilityIfNeeded())
        try repository.write(manifest: migrated)
        let persistedMigration = try XCTUnwrap(try repository.loadManifest())
        XCTAssertEqual(persistedMigration.schemaVersion, LibraryManifest.currentSchemaVersion)
        XCTAssertEqual(persistedMigration.photos.first?.rawRenderingCompatibility, .native)

        var rerun = persistedMigration
        XCTAssertFalse(rerun.migrateRawRenderingCompatibilityIfNeeded())
        XCTAssertEqual(rerun, persistedMigration)
    }

    func testReadOnlyLibraryDoesNotPartiallyPersistPolicyMigration() async throws {
        guard canSimulateReadOnlyDirectory else {
            throw XCTSkip("This test host can bypass directory permissions")
        }

        let service = try makeService()
        let root = try makeSubdirectory("ReadOnlyMigration")
        let sourceURL = try writeFile(Data(repeating: 0x42, count: 64), at: root.appendingPathComponent("Legacy.ARW"))
        let library = try await addLibrary(service, at: root)
        let fingerprint = try FingerprintCalculator.fingerprint(forFileAt: sourceURL)
        let repository = FileSidecarRepository(libraryRootURL: root)
        try repository.write(manifest: LibraryManifest(
            schemaVersion: 1,
            libraryID: library.id,
            photos: [PhotoRecord(
                photoID: PhotoID(),
                relativePath: "Legacy.ARW",
                fingerprint: fingerprint,
                lastSeenAt: .distantPast
            )]
        ))
        let bytesBeforeScan = try Data(contentsOf: repository.manifestURL)
        let manifestDirectory = repository.manifestURL.deletingLastPathComponent()
        try setPosixPermissions(0o555, at: manifestDirectory)
        defer { try? setPosixPermissions(0o755, at: manifestDirectory) }

        try await scan(service, libraryID: library.id)

        XCTAssertEqual(try Data(contentsOf: repository.manifestURL), bytesBeforeScan)
    }

    private func makeStore() -> (store: PhotoDocumentStore, rootURL: URL) {
        let rootURL = temporaryDirectory.appendingPathComponent("Store", isDirectory: true)
        return (PhotoDocumentStore(rootURL: rootURL), rootURL)
    }
}
