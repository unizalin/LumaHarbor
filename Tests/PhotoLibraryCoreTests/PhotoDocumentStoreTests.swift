import Foundation
import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

final class PhotoDocumentStoreTests: TemporaryDirectoryTestCase {

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

    private func makeStore(
        subdirectory: String = "Store",
        copyFile: (@Sendable (URL, URL) throws -> Void)? = nil
    ) -> (store: PhotoDocumentStore, rootURL: URL) {
        let rootURL = temporaryDirectory.appendingPathComponent(subdirectory, isDirectory: true)
        return (PhotoDocumentStore(rootURL: rootURL, copyFile: copyFile), rootURL)
    }

    // MARK: - Assertions

    /// Distinguishes "the directory doesn't exist" and "it exists and is
    /// empty" (both fine) from "listing it failed" or "it has contents"
    /// (both failures). A bare `(try? ...) ?? true` collapses all four cases
    /// into a pass, which is what let a real cleanup bug go unnoticed.
    private func assertDirectoryAbsentOrEmpty(
        _ url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return
        }
        guard isDirectory.boolValue else {
            XCTFail("Expected \(url.lastPathComponent) to be a directory or absent", file: file, line: line)
            return
        }
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
            XCTAssertTrue(
                contents.isEmpty,
                "Expected \(url.lastPathComponent) to be empty, found \(contents)",
                file: file,
                line: line
            )
        } catch {
            XCTFail("Could not list \(url.lastPathComponent): \(error)", file: file, line: line)
        }
    }

    // MARK: - Basic open / copy / persist (existing coverage)

    func testOpenInPlaceDoesNotWriteTheSource() async throws {
        let sourceURL = try makeSourceFile()
        let before = try Data(contentsOf: sourceURL)
        let (store, _) = makeStore()

        let document = try await store.openInPlace(sourceURL, bookmarkData: nil)
        try await store.saveAdjustments(.neutral.setting(.exposure, to: 1), documentID: document.id)

        XCTAssertEqual(try Data(contentsOf: sourceURL), before)
        XCTAssertEqual(document.storageMode, .inPlace)
    }

    func testImportCopyVerifiesBytesAndKeepsSourceLink() async throws {
        let sourceURL = try makeSourceFile()
        let (store, _) = makeStore()

        let document = try await store.importCopy(of: sourceURL, bookmarkData: nil)

        XCTAssertEqual(document.storageMode, .appCopy)
        XCTAssertEqual(document.sourceFingerprint, document.workingFingerprint)
        XCTAssertNotEqual(document.workingURL, sourceURL)
        XCTAssertEqual(try Data(contentsOf: document.workingURL), try Data(contentsOf: sourceURL))
    }

    func testReopeningLoadsTheSavedAdjustments() async throws {
        let sourceURL = try makeSourceFile()
        let (store, _) = makeStore()

        let document = try await store.openInPlace(sourceURL, bookmarkData: nil)
        let edited = PhotoAdjustments.neutral.setting(.contrast, to: 25)
        try await store.saveAdjustments(edited, documentID: document.id)

        let reloaded = try await store.loadAdjustments(documentID: document.id)
        XCTAssertEqual(reloaded, edited)
    }

    func testCopyVerificationFailureLeavesNoDocumentOrRecord() async throws {
        let sourceURL = try makeSourceFile()
        let (store, rootURL) = makeStore { source, destination in
            var bytes = try Data(contentsOf: source)
            bytes[0] ^= 0xff
            try bytes.write(to: destination)
        }

        do {
            _ = try await store.importCopy(of: sourceURL, bookmarkData: nil)
            XCTFail("Expected copy verification to fail")
        } catch {
            XCTAssertEqual(error as? PhotoDocumentError, .copyVerificationFailed)
        }

        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Documents"))
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Records"))
    }

    // MARK: - 1. Full content verification for large copies

    func testImportCopyRejectsMidFileCorruptionInvisibleToFingerprint() async throws {
        // Large enough that FingerprintCalculator only hashes the edges,
        // leaving a wide untouched middle.
        let byteCount = 4 * 1024 * 1024
        XCTAssertGreaterThan(byteCount, Int(FingerprintCalculator.wholeFileThreshold))
        let sourceURL = try makeSourceFile(named: "large.ARW", byteCount: byteCount)

        var corruptedMirror = try Data(contentsOf: sourceURL)
        let middleOffset = corruptedMirror.count / 2
        corruptedMirror[middleOffset] ^= 0xFF
        let corruptedMirrorURL = temporaryDirectory.appendingPathComponent("corrupted-mirror.ARW")
        try corruptedMirror.write(to: corruptedMirrorURL)

        // Demonstrates the blind spot directly: the edge-sampling fingerprint
        // cannot see this corruption, so it must not be relied on as a copy
        // checksum.
        XCTAssertEqual(
            try FingerprintCalculator.fingerprint(forFileAt: sourceURL),
            try FingerprintCalculator.fingerprint(forFileAt: corruptedMirrorURL)
        )

        let (store, rootURL) = makeStore { source, destination in
            var bytes = try Data(contentsOf: source)
            bytes[bytes.count / 2] ^= 0xFF
            try bytes.write(to: destination)
        }

        do {
            _ = try await store.importCopy(of: sourceURL, bookmarkData: nil)
            XCTFail("Expected full-content verification to reject a mid-file corrupted copy")
        } catch {
            XCTAssertEqual(error as? PhotoDocumentError, .copyVerificationFailed)
        }

        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Documents"))
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Records"))
    }

    // MARK: - 2. Container relocation

    func testAppCopyDocumentReloadsAfterStoreRootRelocates() async throws {
        let sourceURL = try makeSourceFile()
        let rootA = temporaryDirectory.appendingPathComponent("RootA", isDirectory: true)
        let storeA = PhotoDocumentStore(rootURL: rootA)

        let document = try await storeA.importCopy(of: sourceURL, bookmarkData: nil)
        try await storeA.saveAdjustments(.neutral.setting(.exposure, to: 0.5), documentID: document.id)

        let rootB = temporaryDirectory.appendingPathComponent("RootB", isDirectory: true)
        try FileManager.default.moveItem(at: rootA, to: rootB)

        let storeB = PhotoDocumentStore(rootURL: rootB)
        let reloaded = try await storeB.loadDocument(id: document.id)

        XCTAssertTrue(reloaded.workingURL.path.hasPrefix(rootB.path))
        XCTAssertFalse(reloaded.workingURL.path.hasPrefix(rootA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reloaded.workingURL.path))
        XCTAssertEqual(try Data(contentsOf: reloaded.workingURL), try Data(contentsOf: sourceURL))

        let reloadedAdjustments = try await storeB.loadAdjustments(documentID: document.id)
        XCTAssertEqual(reloadedAdjustments.exposure, 0.5)
    }

    func testLoadDocumentReadsALegacyRecordWrittenBeforeRelativePathSupport() async throws {
        let (store, rootURL) = makeStore()
        let id = UUID()
        let legacyWorkingURL = rootURL.appendingPathComponent("Documents/\(id.uuidString)/legacy.ARW")
        try FileManager.default.createDirectory(
            at: legacyWorkingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x33, count: 16).write(to: legacyWorkingURL)

        // The exact shape `PhotoDocument` itself was encoded as before
        // `workingPathComponents` existed: no such key present at all.
        let legacyDocument = PhotoDocument(
            id: id,
            storageMode: .appCopy,
            workingURL: legacyWorkingURL,
            sourceURL: rootURL.appendingPathComponent("original.ARW"),
            sourceBookmarkData: nil,
            sourceFingerprint: FileFingerprint(fileSize: 16, edgeDigest: "abc"),
            workingFingerprint: FileFingerprint(fileSize: 16, edgeDigest: "abc")
        )
        let legacyJSON = try SidecarCoding.encode(legacyDocument)
        XCTAssertFalse(String(decoding: legacyJSON, as: UTF8.self).contains("workingPathComponents"))

        let recordURL = rootURL.appendingPathComponent("Records/\(id.uuidString).json")
        try FileManager.default.createDirectory(
            at: recordURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try legacyJSON.write(to: recordURL)

        let loaded = try await store.loadDocument(id: id)
        XCTAssertEqual(loaded.id, id)
        XCTAssertEqual(loaded.workingURL, legacyWorkingURL)
    }

    // MARK: - 3. Crash / interruption reconciliation

    func testReconcileOrphanedImportsRemovesStagingLeftFromAnInterruptedCopy() async throws {
        let (store, rootURL) = makeStore()
        let orphanID = UUID()
        let orphanDirectory = rootURL.appendingPathComponent("Documents/\(orphanID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
        // Simulates a kill partway through the copy: only the staging file exists.
        try Data(repeating: 0x11, count: 128).write(to: orphanDirectory.appendingPathComponent(".importing"))

        let report = try await store.reconcileOrphanedImports()

        XCTAssertEqual(report.removedOrphanIDs, [orphanID])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanDirectory.path))
    }

    func testReconcileOrphanedImportsRemovesACompletedCopyMissingItsRecord() async throws {
        let (store, rootURL) = makeStore()
        let orphanID = UUID()
        let orphanDirectory = rootURL.appendingPathComponent("Documents/\(orphanID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
        // Simulates a kill after the rename to its final name but before the
        // record commit: the finished copy exists with no record.
        try Data(repeating: 0x22, count: 128).write(to: orphanDirectory.appendingPathComponent("fixture.ARW"))

        do {
            _ = try await store.loadDocument(id: orphanID)
            XCTFail("Expected an uncommitted copy to be invisible to loadDocument")
        } catch PhotoDocumentError.documentNotFound(orphanID) {
            // expected
        }

        let report = try await store.reconcileOrphanedImports()

        XCTAssertEqual(report.removedOrphanIDs, [orphanID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanDirectory.path))
    }

    func testReconcileOrphanedImportsNeverRemovesADocumentWithACommittedRecord() async throws {
        let sourceURL = try makeSourceFile()
        let (store, _) = makeStore()

        let document = try await store.importCopy(of: sourceURL, bookmarkData: nil)

        let report = try await store.reconcileOrphanedImports()
        XCTAssertFalse(report.removedOrphanIDs.contains(document.id))

        let reloaded = try await store.loadDocument(id: document.id)
        XCTAssertEqual(try Data(contentsOf: reloaded.workingURL), try Data(contentsOf: sourceURL))
    }

    // MARK: - 4. Real persistence across fresh store instances, with bookmark data

    func testInPlaceDocumentReloadsFromAFreshStoreWithBookmarkAndUnicodeFilename() async throws {
        let filename = "Raw Café 相片.ARW"
        let sourceURL = try makeSourceFile(named: filename, byteCount: 8_192, pattern: 0x77)
        let bookmark = Data("bookmark-fixture-bytes".utf8)
        let rootURL = temporaryDirectory.appendingPathComponent("Store", isDirectory: true)

        let documentID: UUID
        do {
            let store = PhotoDocumentStore(rootURL: rootURL)
            let document = try await store.openInPlace(sourceURL, bookmarkData: bookmark)
            try await store.saveAdjustments(.neutral.setting(.contrast, to: 10), documentID: document.id)
            documentID = document.id
        }

        let freshStore = PhotoDocumentStore(rootURL: rootURL)
        let reloaded = try await freshStore.loadDocument(id: documentID)
        let reloadedAdjustments = try await freshStore.loadAdjustments(documentID: documentID)

        XCTAssertEqual(reloaded.id, documentID)
        XCTAssertEqual(reloaded.storageMode, .inPlace)
        XCTAssertEqual(reloaded.sourceURL, sourceURL)
        XCTAssertEqual(reloaded.sourceBookmarkData, bookmark)
        XCTAssertEqual(reloaded.workingURL, sourceURL)
        XCTAssertEqual(reloaded.sourceFingerprint, reloaded.workingFingerprint)
        XCTAssertEqual(reloadedAdjustments.contrast, 10)
    }

    func testAppCopyDocumentReloadsFromAFreshStoreAndSurvivesSourceDeletion() async throws {
        let filename = "Raw Café 相片.ARW"
        let sourceURL = try makeSourceFile(named: filename, byteCount: 8_192, pattern: 0x88)
        let sourceBytes = try Data(contentsOf: sourceURL)
        let bookmark = Data("bookmark-fixture-bytes".utf8)
        let rootURL = temporaryDirectory.appendingPathComponent("Store", isDirectory: true)

        let documentID: UUID
        do {
            let store = PhotoDocumentStore(rootURL: rootURL)
            let document = try await store.importCopy(of: sourceURL, bookmarkData: bookmark)
            try await store.saveAdjustments(.neutral.setting(.saturation, to: -5), documentID: document.id)
            documentID = document.id
        }

        try FileManager.default.removeItem(at: sourceURL)

        let freshStore = PhotoDocumentStore(rootURL: rootURL)
        let reloaded = try await freshStore.loadDocument(id: documentID)
        let reloadedAdjustments = try await freshStore.loadAdjustments(documentID: documentID)

        XCTAssertEqual(reloaded.id, documentID)
        XCTAssertEqual(reloaded.storageMode, .appCopy)
        XCTAssertEqual(reloaded.sourceURL, sourceURL)
        XCTAssertEqual(reloaded.sourceBookmarkData, bookmark)
        XCTAssertTrue(reloaded.workingURL.path.hasPrefix(rootURL.path))
        XCTAssertEqual(reloaded.sourceFingerprint, reloaded.workingFingerprint)
        XCTAssertEqual(try Data(contentsOf: reloaded.workingURL), sourceBytes)
        XCTAssertEqual(reloadedAdjustments.saturation, -5)
    }

    // MARK: - 5. Error / integration coverage

    func testLoadDocumentThrowsDocumentNotFoundForUnknownID() async throws {
        let (store, _) = makeStore()
        let unknownID = UUID()

        do {
            _ = try await store.loadDocument(id: unknownID)
            XCTFail("Expected documentNotFound")
        } catch PhotoDocumentError.documentNotFound(unknownID) {
            // expected
        }
    }

    func testImportCopyLeavesNoTraceWhenCopyFileThrows() async throws {
        struct CopySeamError: Error {}
        let sourceURL = try makeSourceFile()
        let (store, rootURL) = makeStore { _, _ in throw CopySeamError() }

        do {
            _ = try await store.importCopy(of: sourceURL, bookmarkData: nil)
            XCTFail("Expected copyFile failure to propagate")
        } catch is CopySeamError {
            // expected
        }

        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Documents"))
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Records"))
    }

    func testLoadDocumentRejectsACorruptRecordFile() async throws {
        let (store, rootURL) = makeStore()
        let id = UUID()
        let recordURL = rootURL.appendingPathComponent("Records/\(id.uuidString).json")
        try FileManager.default.createDirectory(
            at: recordURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not valid json {".utf8).write(to: recordURL)

        do {
            _ = try await store.loadDocument(id: id)
            XCTFail("Expected a corrupt record to fail to decode rather than load")
        } catch is DecodingError {
            // expected
        }
    }

    func testSidecarCorruptionDuringLoadAdjustmentsIsQuarantinedNotSilentlyOverwritten() async throws {
        let sourceURL = try makeSourceFile()
        let (store, rootURL) = makeStore()
        let document = try await store.openInPlace(sourceURL, bookmarkData: nil)
        try await store.saveAdjustments(.neutral.setting(.exposure, to: 1), documentID: document.id)

        let repositoryRoot = rootURL.appendingPathComponent("Sidecars/\(document.id.uuidString)", isDirectory: true)
        let repository = FileSidecarRepository(libraryRootURL: repositoryRoot)
        let sidecarURL = repository.sidecarURL(for: PhotoID(document.id))
        try Data("not valid json {".utf8).write(to: sidecarURL)

        do {
            _ = try await store.loadAdjustments(documentID: document.id)
            XCTFail("Expected a corrupt sidecar to be reported, not silently read as neutral")
        } catch SidecarError.corruptSidecar {
            // expected — FileSidecarRepository quarantines the bad file.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
        let quarantineDirectory = repository.quarantineDirectoryURL
        let quarantined = (try? FileManager.default.contentsOfDirectory(atPath: quarantineDirectory.path)) ?? []
        XCTAssertFalse(quarantined.isEmpty)
    }

    func testSaveAdjustmentsRejectsANewerSchemaSidecarWithoutOverwriting() async throws {
        let sourceURL = try makeSourceFile()
        let (store, rootURL) = makeStore()
        let document = try await store.openInPlace(sourceURL, bookmarkData: nil)
        // Establishes the per-document sidecar directory the same way a real
        // save would, so the manual write below lands where the store expects it.
        try await store.saveAdjustments(.neutral, documentID: document.id)

        let repositoryRoot = rootURL.appendingPathComponent("Sidecars/\(document.id.uuidString)", isDirectory: true)
        let repository = FileSidecarRepository(libraryRootURL: repositoryRoot)
        guard var newerSidecar = try repository.loadSidecar(for: PhotoID(document.id)) else {
            XCTFail("Expected the sidecar just saved to be readable")
            return
        }
        newerSidecar.schemaVersion = PhotoSidecar.currentSchemaVersion + 1
        try repository.write(sidecar: newerSidecar)
        let sidecarURL = repository.sidecarURL(for: PhotoID(document.id))
        let bytesBeforeSave = try Data(contentsOf: sidecarURL)

        do {
            try await store.saveAdjustments(.neutral.setting(.exposure, to: 2), documentID: document.id)
            XCTFail("Expected a newer-schema sidecar to reject the write")
        } catch SidecarError.unsupportedSchemaVersion(let found, let supported) {
            XCTAssertEqual(found, PhotoSidecar.currentSchemaVersion + 1)
            XCTAssertEqual(supported, PhotoSidecar.currentSchemaVersion)
        }

        XCTAssertEqual(try Data(contentsOf: sidecarURL), bytesBeforeSave)
    }

    func testLoadAdjustmentsReturnsNeutralWhenNoSidecarHasBeenSaved() async throws {
        let sourceURL = try makeSourceFile()
        let (store, _) = makeStore()
        let document = try await store.openInPlace(sourceURL, bookmarkData: nil)

        let adjustments = try await store.loadAdjustments(documentID: document.id)
        XCTAssertEqual(adjustments, .neutral)
    }
}
