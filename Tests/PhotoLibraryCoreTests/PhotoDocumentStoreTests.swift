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
        copyFile: (@Sendable (URL, URL) throws -> Void)? = nil,
        now: (@Sendable () -> Date)? = nil,
        checkCancellation: (@Sendable () throws -> Void)? = nil,
        writeRecordData: (@Sendable (Data, URL, FileManager) throws -> Void)? = nil
    ) -> (store: PhotoDocumentStore, rootURL: URL) {
        let rootURL = temporaryDirectory.appendingPathComponent(subdirectory, isDirectory: true)
        let store = PhotoDocumentStore(
            rootURL: rootURL,
            copyFile: copyFile,
            now: now ?? { Date() },
            checkCancellation: checkCancellation ?? { try Task.checkCancellation() },
            writeRecordData: writeRecordData
        )
        return (store, rootURL)
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

    // MARK: - 1b. Source mutation during import (TOCTOU)

    /// Mutates the source once a specific `checkCancellation` call has been
    /// reached, then behaves like real cancellation checking (a no-op)
    /// afterward. Used to land a write in a precise window of `importCopy`'s
    /// sequence that no other seam reaches: strictly after full-content
    /// verification has already passed (its `FileHandle`s are closed by
    /// then, so this can't be confused with a mutation the comparison loop
    /// itself would already have caught) and strictly before the source is
    /// fingerprinted for the record.
    private final class MutateSourceOnCallTrigger: @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
        private let mutateAtCall: Int
        private let mutate: () throws -> Void

        init(mutateAtCall: Int, mutate: @escaping () throws -> Void) {
            self.mutateAtCall = mutateAtCall
            self.mutate = mutate
        }

        func checkCancellation() throws {
            lock.lock()
            callCount += 1
            let shouldMutate = callCount == mutateAtCall
            lock.unlock()
            if shouldMutate { try mutate() }
        }
    }

    func testImportCopyRejectsASourceModifiedAfterVerification() async throws {
        let sourceURL = try makeSourceFile(byteCount: 4_096)
        // For a file under the chunk size the fixed call sequence is: #1
        // pre-copyFile, #2 post-copyFile, #3/#4 comparison chunks, #5 right
        // after the comparison passes (see importCopy's documentation) —
        // exactly the window the review's TOCTOU report describes.
        let trigger = MutateSourceOnCallTrigger(mutateAtCall: 5) {
            // A different size guarantees the size-based TOCTOU check
            // catches it regardless of filesystem modification-date
            // granularity.
            try Data(repeating: 0x99, count: 5_000).write(to: sourceURL)
        }
        let (store, rootURL) = makeStore(checkCancellation: { try trigger.checkCancellation() })

        do {
            _ = try await store.importCopy(of: sourceURL, bookmarkData: nil)
            XCTFail("Expected a source modified during import to be rejected")
        } catch {
            XCTAssertEqual(error as? PhotoDocumentError, .sourceModifiedDuringImport)
        }

        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Documents"))
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Records"))
    }

    func testImportCopyWorkingFingerprintMatchesTheWorkingURLItself() async throws {
        let sourceURL = try makeSourceFile()
        let (store, _) = makeStore()

        let document = try await store.importCopy(of: sourceURL, bookmarkData: nil)

        // The persisted fingerprint must describe the file actually kept —
        // recomputing it straight from `workingURL` must agree.
        let recomputedWorking = try FingerprintCalculator.fingerprint(forFileAt: document.workingURL)
        XCTAssertEqual(recomputedWorking, document.workingFingerprint)

        let recomputedSource = try FingerprintCalculator.fingerprint(forFileAt: sourceURL)
        XCTAssertEqual(recomputedSource, document.sourceFingerprint)
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

    /// Builds the exact on-disk shape a pre-`workingPathComponents` record
    /// would have (b39471c / 6a30c1d): a `Records/<id>.json` with only an
    /// absolute `workingURL`, no relative-path key at all.
    @discardableResult
    private func writeLegacyAppCopyRecord(
        id: UUID,
        workingBytes: Data,
        workingFilename: String = "fixture.ARW",
        rootURL: URL
    ) throws -> URL {
        let workingURL = rootURL.appendingPathComponent("Documents/\(id.uuidString)/\(workingFilename)")
        try FileManager.default.createDirectory(
            at: workingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try workingBytes.write(to: workingURL)

        let legacyDocument = PhotoDocument(
            id: id,
            storageMode: .appCopy,
            workingURL: workingURL,
            sourceURL: rootURL.appendingPathComponent("original.ARW"),
            sourceBookmarkData: nil,
            sourceFingerprint: FileFingerprint(fileSize: Int64(workingBytes.count), edgeDigest: "abc"),
            workingFingerprint: FileFingerprint(fileSize: Int64(workingBytes.count), edgeDigest: "abc")
        )
        let legacyJSON = try SidecarCoding.encode(legacyDocument)
        XCTAssertFalse(String(decoding: legacyJSON, as: UTF8.self).contains("workingPathComponents"))

        let recordURL = rootURL.appendingPathComponent("Records/\(id.uuidString).json")
        try FileManager.default.createDirectory(
            at: recordURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try legacyJSON.write(to: recordURL)
        return recordURL
    }

    func testLoadDocumentMigratesALegacyAppCopyRecordAfterContainerRelocation() async throws {
        let workingBytes = Data(repeating: 0x33, count: 16)
        let rootA = temporaryDirectory.appendingPathComponent("RootA", isDirectory: true)
        let id = UUID()
        try writeLegacyAppCopyRecord(id: id, workingBytes: workingBytes, rootURL: rootA)

        let rootB = temporaryDirectory.appendingPathComponent("RootB", isDirectory: true)
        try FileManager.default.moveItem(at: rootA, to: rootB)

        let store = PhotoDocumentStore(rootURL: rootB)
        let loaded = try await store.loadDocument(id: id)

        XCTAssertEqual(loaded.id, id)
        XCTAssertTrue(loaded.workingURL.path.hasPrefix(rootB.path))
        XCTAssertFalse(loaded.workingURL.path.hasPrefix(rootA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: loaded.workingURL.path))
        XCTAssertEqual(try Data(contentsOf: loaded.workingURL), workingBytes)

        // The record on disk (under the new root) has been atomically
        // upgraded so future loads don't need to migrate again.
        let migratedRecordURL = rootB.appendingPathComponent("Records/\(id.uuidString).json")
        let migratedJSON = try Data(contentsOf: migratedRecordURL)
        XCTAssertTrue(String(decoding: migratedJSON, as: UTF8.self).contains("workingPathComponents"))
    }

    func testLoadDocumentFallsBackToTheLegacyAbsolutePathWhenNoMigrationCandidateExists() async throws {
        let (store, rootURL) = makeStore()
        let id = UUID()
        let legacyWorkingURL = rootURL.appendingPathComponent("Documents/\(id.uuidString)/legacy.ARW")
        // Deliberately no file at legacyWorkingURL or anywhere under
        // Documents/<id>/ — there is nothing on disk to migrate to.
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
        let recordURL = rootURL.appendingPathComponent("Records/\(id.uuidString).json")
        try FileManager.default.createDirectory(
            at: recordURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try legacyJSON.write(to: recordURL)

        let loaded = try await store.loadDocument(id: id)
        XCTAssertEqual(loaded.id, id)
        XCTAssertEqual(loaded.workingURL, legacyWorkingURL)

        // Nothing to migrate to, so the record is left exactly as it was.
        let unchangedJSON = try Data(contentsOf: recordURL)
        XCTAssertEqual(unchangedJSON, legacyJSON)
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

    /// The reconciliation contract is defined entirely by what's on disk — a
    /// transaction marker and, separately, a record — never by any in-memory
    /// actor state. A store instance that fabricates a marker directly is
    /// therefore behaviorally indistinguishable, for this purpose, from a
    /// second, genuinely concurrent `PhotoDocumentStore` instance that wrote
    /// it while importing against the same root: either way,
    /// `reconcileOrphanedImports()` reasons about it purely from the marker
    /// and record it finds, never from any shared memory with whatever
    /// process produced them.
    func testReconcileOrphanedImportsProtectsAnImportStillActiveFromAnotherStoreInstance() async throws {
        let rootURL = temporaryDirectory.appendingPathComponent("Store", isDirectory: true)
        let importStartedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let id = UUID()
        let directory = rootURL.appendingPathComponent("Documents/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SidecarCoding.encode(ImportTransactionMarker(startedAt: importStartedAt))
            .write(to: directory.appendingPathComponent(PhotoDocumentStore.transactionMarkerFilename))
        try Data(repeating: 0x44, count: 64).write(to: directory.appendingPathComponent(".importing"))

        // A second, independent instance checking in shortly after the
        // transaction began — well inside the "still active" window.
        let (reconciler, _) = makeStore(now: { importStartedAt.addingTimeInterval(5) })
        let report = try await reconciler.reconcileOrphanedImports()

        XCTAssertTrue(report.removedOrphanIDs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testReconcileOrphanedImportsRemovesATransactionAbandonedByAnotherStoreInstance() async throws {
        let rootURL = temporaryDirectory.appendingPathComponent("Store", isDirectory: true)
        let importStartedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let id = UUID()
        let directory = rootURL.appendingPathComponent("Documents/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SidecarCoding.encode(ImportTransactionMarker(startedAt: importStartedAt))
            .write(to: directory.appendingPathComponent(PhotoDocumentStore.transactionMarkerFilename))
        try Data(repeating: 0x44, count: 64).write(to: directory.appendingPathComponent(".importing"))

        // Long past any reasonable "still running" window.
        let (reconciler, _) = makeStore(now: { importStartedAt.addingTimeInterval(3_600) })
        let report = try await reconciler.reconcileOrphanedImports()

        XCTAssertEqual(report.removedOrphanIDs, [id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testReconcileOrphanedImportsReportsFailuresWithoutSilentlyDiscardingThem() async throws {
        try XCTSkipUnless(canSimulateReadOnlyDirectory, "Cannot simulate a read-only directory while running as root")

        let (store, rootURL) = makeStore()
        let orphanID = UUID()
        let documentsDirectory = rootURL.appendingPathComponent("Documents", isDirectory: true)
        let orphanDirectory = documentsDirectory.appendingPathComponent(orphanID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x11, count: 64).write(to: orphanDirectory.appendingPathComponent(".importing"))

        // A read-only parent directory blocks removal of the orphan inside it.
        try setPosixPermissions(0o555, at: documentsDirectory)
        defer { try? setPosixPermissions(0o755, at: documentsDirectory) }

        let report = try await store.reconcileOrphanedImports()

        XCTAssertTrue(report.removedOrphanIDs.isEmpty)
        XCTAssertNotNil(report.failures[orphanID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanDirectory.path))
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

    // MARK: - 6. Cancellation checkpoints

    /// A `Bool` set from inside a `@Sendable` closure, without the compiler
    /// flagging an unsynchronized capture.
    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        func set() {
            lock.lock()
            flag = true
            lock.unlock()
        }

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
    }

    /// Throws `CancellationError` from the first call once `arm()` has been
    /// invoked. Used where the exact call site to interrupt is controlled by
    /// a side effect (e.g. inside the `copyFile` seam) rather than a call
    /// count, so the test doesn't depend on how many checkpoints exist
    /// elsewhere in the sequence.
    private final class FlagCancellationTrigger: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false

        func arm() {
            lock.lock()
            armed = true
            lock.unlock()
        }

        func checkCancellation() throws {
            lock.lock()
            let shouldCancel = armed
            lock.unlock()
            if shouldCancel { throw CancellationError() }
        }
    }

    /// Throws `CancellationError` starting at the `cancelAtCall`-th call.
    /// Used to target a specific checkpoint by its fixed position in
    /// `importCopy`'s call sequence for a given, known input size (see each
    /// call site for the reasoning behind its chosen index).
    private final class CountingCancellationTrigger: @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
        private let cancelAtCall: Int

        init(cancelAtCall: Int) {
            self.cancelAtCall = cancelAtCall
        }

        func checkCancellation() throws {
            lock.lock()
            callCount += 1
            let shouldCancel = callCount >= cancelAtCall
            lock.unlock()
            if shouldCancel { throw CancellationError() }
        }
    }

    func testImportCopyCancelledBeforeCopyFileLeavesNoTrace() async throws {
        let sourceURL = try makeSourceFile()
        let trigger = FlagCancellationTrigger()
        trigger.arm() // cancelled before the very first checkpoint runs

        let copyFileWasCalled = LockedFlag()
        let (store, rootURL) = makeStore(
            copyFile: { source, destination in
                copyFileWasCalled.set()
                try FileManager.default.copyItem(at: source, to: destination)
            },
            checkCancellation: { try trigger.checkCancellation() }
        )

        do {
            _ = try await store.importCopy(of: sourceURL, bookmarkData: nil)
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // expected
        }

        XCTAssertFalse(copyFileWasCalled.value, "copyFile must not run once cancellation is observed beforehand")
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Documents"))
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Records"))
    }

    func testImportCopyCancelledAfterCopyFileReturnsLeavesNoTrace() async throws {
        let sourceURL = try makeSourceFile()
        let trigger = FlagCancellationTrigger()
        let (store, rootURL) = makeStore(
            copyFile: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
                trigger.arm() // the checkpoint right after this return must see it
            },
            checkCancellation: { try trigger.checkCancellation() }
        )

        do {
            _ = try await store.importCopy(of: sourceURL, bookmarkData: nil)
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // expected — not converted into copyVerificationFailed.
        }

        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Documents"))
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Records"))
    }

    func testImportCopyCancelledDuringContentVerificationLeavesNoTrace() async throws {
        // Large enough for the comparison loop to run several full-size
        // chunks: call #1 is the pre-copyFile checkpoint, #2 is
        // post-copyFile, and #3, #4, ... are one per comparison chunk.
        // Cancelling at #4 interrupts the *second* data chunk — genuinely
        // mid-verification, not the first or the final EOF check.
        let sourceURL = try makeSourceFile(named: "large.ARW", byteCount: Int(2.5 * 1024 * 1024))
        let trigger = CountingCancellationTrigger(cancelAtCall: 4)
        let (store, rootURL) = makeStore(checkCancellation: { try trigger.checkCancellation() })

        do {
            _ = try await store.importCopy(of: sourceURL, bookmarkData: nil)
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // expected
        }

        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Documents"))
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Records"))
    }

    func testImportCopyCancelledBeforeMovingToFinalNameLeavesNoTrace() async throws {
        // A file under the chunk size makes the comparison loop run exactly
        // twice (one data chunk, one EOF check), so the full sequence is:
        // #1 pre-copyFile, #2 post-copyFile, #3/#4 comparison, #5 right
        // after the comparison passes, #6 before the move, #7 before the
        // record commit. This targets #6.
        let sourceURL = try makeSourceFile(byteCount: 4_096)
        let trigger = CountingCancellationTrigger(cancelAtCall: 6)
        let (store, rootURL) = makeStore(checkCancellation: { try trigger.checkCancellation() })

        do {
            _ = try await store.importCopy(of: sourceURL, bookmarkData: nil)
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // expected
        }

        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Documents"))
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Records"))
    }

    func testImportCopyCancelledBeforeRecordCommitLeavesNoTrace() async throws {
        // Same reasoning as above; this targets #7, right before the record
        // is written — after the copy has already been moved to its final
        // name, which the cleanup must still undo.
        let sourceURL = try makeSourceFile(byteCount: 4_096)
        let trigger = CountingCancellationTrigger(cancelAtCall: 7)
        let (store, rootURL) = makeStore(checkCancellation: { try trigger.checkCancellation() })

        do {
            _ = try await store.importCopy(of: sourceURL, bookmarkData: nil)
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // expected
        }

        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Documents"))
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Records"))
    }

    // MARK: - 7. Record commit failure

    func testImportCopyCleansUpWhenRecordCommitFails() async throws {
        struct RecordWriteError: Error {}
        let sourceURL = try makeSourceFile()
        let (store, rootURL) = makeStore(writeRecordData: { _, _, _ in throw RecordWriteError() })

        do {
            _ = try await store.importCopy(of: sourceURL, bookmarkData: nil)
            XCTFail("Expected the record write failure to propagate")
        } catch is RecordWriteError {
            // expected — the original error reaches the caller unwrapped.
        }

        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Documents"))
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Records"))
    }

    func testOpenInPlaceCleansUpNothingButPropagatesRecordCommitFailure() async throws {
        struct RecordWriteError: Error {}
        let sourceURL = try makeSourceFile()
        let before = try Data(contentsOf: sourceURL)
        let (store, _) = makeStore(writeRecordData: { _, _, _ in throw RecordWriteError() })

        do {
            _ = try await store.openInPlace(sourceURL, bookmarkData: nil)
            XCTFail("Expected the record write failure to propagate")
        } catch is RecordWriteError {
            // expected
        }

        // openInPlace never touches the source regardless of outcome.
        XCTAssertEqual(try Data(contentsOf: sourceURL), before)
    }

    func testImportCopyCleansUpWhenCopyFileWritesPartialContentThenThrows() async throws {
        struct PartialCopyError: Error {}
        let sourceURL = try makeSourceFile(byteCount: 8_192)
        let (store, rootURL) = makeStore { source, destination in
            let partial = try Data(contentsOf: source).prefix(1_024)
            try Data(partial).write(to: destination)
            throw PartialCopyError()
        }

        do {
            _ = try await store.importCopy(of: sourceURL, bookmarkData: nil)
            XCTFail("Expected the copy failure to propagate")
        } catch is PartialCopyError {
            // expected
        }

        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Documents"))
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Records"))
    }
}
