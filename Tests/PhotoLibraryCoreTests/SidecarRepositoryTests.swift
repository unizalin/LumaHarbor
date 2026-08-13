import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Spec §8.2 and §10: portable sidecars, atomic writes, a newer schema is
/// refused rather than half-read, and damaged JSON is set aside — never
/// silently overwritten.
final class SidecarRepositoryTests: TemporaryDirectoryTestCase {
    private var libraryRoot: URL!
    private var repository: FileSidecarRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        libraryRoot = try makeSubdirectory("Photos")
        repository = FileSidecarRepository(libraryRootURL: libraryRoot)
    }

    private func makeSidecar(
        photoID: PhotoID = PhotoID(),
        adjustments: PhotoAdjustments = PhotoAdjustments(exposure: 1.5, contrast: 20)
    ) -> PhotoSidecar {
        PhotoSidecar(
            photoID: photoID,
            sourceRelativePath: "Trip/DSC0001.ARW",
            sourceFingerprint: .stub("abc", size: 25_000_000),
            adjustments: adjustments,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    // MARK: - Layout

    func testUsesTheDocumentedDirectoryLayout() {
        // Spec §8.1 fixes these paths; a future iPad build reads the same ones.
        XCTAssertEqual(repository.containerURL.lastPathComponent, ".lumaharbor")
        XCTAssertEqual(repository.manifestURL.lastPathComponent, "library.json")
        XCTAssertEqual(repository.editsDirectoryURL.lastPathComponent, "edits")

        let photoID = PhotoID()
        XCTAssertEqual(
            repository.sidecarURL(for: photoID).lastPathComponent,
            "\(photoID.rawValue.uuidString).json"
        )
    }

    // MARK: - Round trips

    func testSidecarRoundTrips() throws {
        let sidecar = makeSidecar()
        try repository.write(sidecar: sidecar)

        let loaded = try XCTUnwrap(try repository.loadSidecar(for: sidecar.photoID))
        XCTAssertEqual(loaded, sidecar)
    }

    func testMissingSidecarIsNilNotAnError() throws {
        let loaded = try repository.loadSidecar(for: PhotoID())
        XCTAssertNil(loaded)
    }

    func testSidecarJSONMatchesTheDocumentedShape() throws {
        let sidecar = makeSidecar()
        try repository.write(sidecar: sidecar)

        let data = try Data(contentsOf: repository.sidecarURL(for: sidecar.photoID))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Spec §8.2's field list.
        for key in [
            "schemaVersion", "photoID", "sourceRelativePath", "sourceFingerprint",
            "decoder", "adjustments", "createdAt", "modifiedAt"
        ] {
            XCTAssertNotNil(object[key], "Missing \(key)")
        }
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["photoID"] as? String, sidecar.photoID.rawValue.uuidString)

        let fingerprint = try XCTUnwrap(object["sourceFingerprint"] as? [String: Any])
        XCTAssertNotNil(fingerprint["fileSize"])
        XCTAssertNotNil(fingerprint["edgeDigest"])

        let decoder = try XCTUnwrap(object["decoder"] as? [String: Any])
        XCTAssertEqual(decoder["kind"] as? String, "coreImage")
    }

    func testManifestRoundTrips() throws {
        var manifest = LibraryManifest()
        manifest.upsert(PhotoRecord.stub(relativePath: "Trip/B.ARW", fingerprint: .stub("b")))
        manifest.upsert(PhotoRecord.stub(relativePath: "Trip/A.ARW", fingerprint: .stub("a")))
        manifest.lastSuccessfulScanAt = Date(timeIntervalSince1970: 1_700_000_000)

        try repository.write(manifest: manifest)
        let loaded = try XCTUnwrap(try repository.loadManifest())
        XCTAssertEqual(loaded, manifest)
        XCTAssertEqual(
            loaded.photos.map(\.relativePath),
            ["Trip/A.ARW", "Trip/B.ARW"],
            "Records are sorted so the file stays stable across scans"
        )
    }

    func testRewritingIdenticalContentProducesIdenticalBytes() throws {
        let sidecar = makeSidecar()
        try repository.write(sidecar: sidecar)
        let first = try Data(contentsOf: repository.sidecarURL(for: sidecar.photoID))
        try repository.write(sidecar: sidecar)
        let second = try Data(contentsOf: repository.sidecarURL(for: sidecar.photoID))
        XCTAssertEqual(first, second)
    }

    // MARK: - Schema version

    func testANewerSchemaIsRefusedRatherThanPartiallyRead() throws {
        // Spec §12.1: an unknown newer major version must be rejected.
        let photoID = PhotoID()
        let json = """
        {
          "schemaVersion": 99,
          "photoID": "\(photoID.rawValue.uuidString)",
          "sourceRelativePath": "Trip/DSC0001.ARW",
          "sourceFingerprint": { "fileSize": 100, "edgeDigest": "abc" },
          "decoder": { "kind": "coreImage", "version": "system-default" },
          "adjustments": { "exposure": 1 },
          "createdAt": "2026-08-13T00:00:00Z",
          "modifiedAt": "2026-08-13T00:00:00Z"
        }
        """
        try writeFile(Data(json.utf8), at: repository.sidecarURL(for: photoID))

        XCTAssertThrowsError(try repository.loadSidecar(for: photoID)) { error in
            guard case SidecarError.unsupportedSchemaVersion(let found, let supported) = error else {
                return XCTFail("Expected .unsupportedSchemaVersion, got \(error)")
            }
            XCTAssertEqual(found, 99)
            XCTAssertEqual(supported, PhotoSidecar.currentSchemaVersion)
        }
    }

    func testANewerSchemaFileIsLeftWhereItIs() throws {
        // Quarantining it would destroy edits made on another device.
        let photoID = PhotoID()
        let json = """
        {
          "schemaVersion": 99, "photoID": "\(photoID.rawValue.uuidString)",
          "sourceRelativePath": "a.ARW",
          "sourceFingerprint": { "fileSize": 1, "edgeDigest": "a" },
          "decoder": { "kind": "coreImage", "version": "system-default" },
          "adjustments": {},
          "createdAt": "2026-08-13T00:00:00Z", "modifiedAt": "2026-08-13T00:00:00Z"
        }
        """
        let url = repository.sidecarURL(for: photoID)
        try writeFile(Data(json.utf8), at: url)

        XCTAssertThrowsError(try repository.loadSidecar(for: photoID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testANewerManifestIsRefused() throws {
        let json = """
        { "schemaVersion": 99, "libraryID": "\(UUID().uuidString)", "photos": [] }
        """
        try writeFile(Data(json.utf8), at: repository.manifestURL)

        XCTAssertThrowsError(try repository.loadManifest()) { error in
            guard case SidecarError.unsupportedSchemaVersion = error else {
                return XCTFail("Expected .unsupportedSchemaVersion, got \(error)")
            }
        }
    }

    // MARK: - Corruption

    func testCorruptSidecarIsQuarantinedNotOverwritten() throws {
        let photoID = PhotoID()
        let url = repository.sidecarURL(for: photoID)
        try writeFile(Data("{ this is not json".utf8), at: url)

        XCTAssertThrowsError(try repository.loadSidecar(for: photoID)) { error in
            guard case SidecarError.corruptSidecar(let id, let quarantinedAt, _) = error else {
                return XCTFail("Expected .corruptSidecar, got \(error)")
            }
            XCTAssertEqual(id, photoID)
            XCTAssertNotNil(quarantinedAt, "The damaged file should have been preserved")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let quarantined = try FileManager.default.contentsOfDirectory(
            atPath: repository.quarantineDirectoryURL.path
        )
        XCTAssertEqual(quarantined.count, 1)
        XCTAssertTrue(quarantined[0].contains(photoID.rawValue.uuidString))
    }

    func testQuarantinedContentIsPreservedVerbatim() throws {
        let photoID = PhotoID()
        let damaged = Data("{ broken but precious".utf8)
        try writeFile(damaged, at: repository.sidecarURL(for: photoID))

        XCTAssertThrowsError(try repository.loadSidecar(for: photoID)) { error in
            guard case SidecarError.corruptSidecar(_, let path?, _) = error else {
                return XCTFail("Expected a quarantine path, got \(error)")
            }
            XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: path)), damaged)
        }
    }

    func testAfterQuarantineTheEditorCanStartFresh() throws {
        let photoID = PhotoID()
        try writeFile(Data("nonsense".utf8), at: repository.sidecarURL(for: photoID))
        XCTAssertThrowsError(try repository.loadSidecar(for: photoID))

        // Spec §10: the RAW is untouched and the user can simply edit again.
        let replacement = makeSidecar(photoID: photoID)
        try repository.write(sidecar: replacement)
        let reloaded = try repository.loadSidecar(for: photoID)
        XCTAssertEqual(reloaded, replacement)
    }

    func testCorruptManifestIsQuarantined() throws {
        try writeFile(Data("<<<not json>>>".utf8), at: repository.manifestURL)

        XCTAssertThrowsError(try repository.loadManifest()) { error in
            guard case SidecarError.corruptManifest(let quarantinedAt, _) = error else {
                return XCTFail("Expected .corruptManifest, got \(error)")
            }
            XCTAssertNotNil(quarantinedAt)
        }
    }

    // MARK: - Availability

    func testOfflineLibraryReportsUnavailableRatherThanEmpty() throws {
        let missing = temporaryDirectory.appendingPathComponent("NotMounted", isDirectory: true)
        let offline = FileSidecarRepository(libraryRootURL: missing)

        XCTAssertFalse(offline.isAvailable)
        XCTAssertFalse(offline.isWritable)
        XCTAssertThrowsError(try offline.loadManifest()) { error in
            guard case SidecarError.libraryUnavailable = error else {
                return XCTFail("Expected .libraryUnavailable, got \(error)")
            }
        }
    }

    func testReadOnlyLibraryIsBrowsableButNotWritable() throws {
        try XCTSkipUnless(canSimulateReadOnlyDirectory, "Test must not run as root")

        // Spec §10: browsing is allowed; saving is refused up front.
        let sidecar = makeSidecar()
        try repository.write(sidecar: sidecar)

        try setPosixPermissions(0o555, at: libraryRoot)
        defer { try? setPosixPermissions(0o755, at: libraryRoot) }

        XCTAssertTrue(repository.isAvailable)
        XCTAssertFalse(repository.isWritable)
        let stillReadable = try repository.loadSidecar(for: sidecar.photoID)
        XCTAssertEqual(stillReadable, sidecar)

        XCTAssertThrowsError(try repository.write(sidecar: sidecar)) { error in
            guard case SidecarError.notWritable = error else {
                return XCTFail("Expected .notWritable, got \(error)")
            }
        }
    }

    func testCorruptSidecarOnAReadOnlyDriveStillReportsCorruptionWithoutQuarantine() throws {
        try XCTSkipUnless(canSimulateReadOnlyDirectory, "Test must not run as root")

        let photoID = PhotoID()
        try writeFile(Data("broken".utf8), at: repository.sidecarURL(for: photoID))
        try setPosixPermissions(0o555, at: libraryRoot)
        defer { try? setPosixPermissions(0o755, at: libraryRoot) }

        XCTAssertThrowsError(try repository.loadSidecar(for: photoID)) { error in
            guard case SidecarError.corruptSidecar(_, let quarantinedAt, _) = error else {
                return XCTFail("Expected .corruptSidecar, got \(error)")
            }
            // It couldn't be moved, and the error says so rather than pretending.
            XCTAssertNil(quarantinedAt)
        }
    }

    // MARK: - Rebuild support

    func testStoredSidecarIDsListsWhatIsOnDisk() throws {
        let first = makeSidecar()
        let second = makeSidecar()
        try repository.write(sidecar: first)
        try repository.write(sidecar: second)
        // A stray non-sidecar file must be ignored, not crash the rebuild.
        try writeFile(
            Data("x".utf8),
            at: repository.editsDirectoryURL.appendingPathComponent("notes.txt")
        )

        let storedIDs = try repository.storedSidecarIDs()
        XCTAssertEqual(Set(storedIDs), [first.photoID, second.photoID])
    }

    func testRemoveSidecarIsIdempotent() throws {
        let sidecar = makeSidecar()
        try repository.write(sidecar: sidecar)
        try repository.removeSidecar(for: sidecar.photoID)
        let removed = try repository.loadSidecar(for: sidecar.photoID)
        XCTAssertNil(removed)
        XCTAssertNoThrow(try repository.removeSidecar(for: sidecar.photoID))
    }

    func testEverySidecarErrorOffersANextStep() {
        let errors: [SidecarError] = [
            .unsupportedSchemaVersion(found: 2, supported: 1),
            .corruptSidecar(photoID: PhotoID(), quarantinedAt: nil, reason: "x"),
            .corruptManifest(quarantinedAt: nil, reason: "x"),
            .libraryUnavailable(path: "/Volumes/SSD"),
            .notWritable(path: "/Volumes/SSD"),
            .write(.insufficientDiskSpace)
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error)")
            XCTAssertNotNil(error.recoverySuggestion, "\(error)")
        }
    }
}
