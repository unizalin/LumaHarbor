import Darwin
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
        checkCancellation: (@Sendable () throws -> Void)? = nil,
        writeRecordData: (@Sendable (Data, URL, FileManager) throws -> Void)? = nil
    ) -> (store: PhotoDocumentStore, rootURL: URL) {
        let rootURL = temporaryDirectory.appendingPathComponent(subdirectory, isDirectory: true)
        let store = PhotoDocumentStore(
            rootURL: rootURL,
            copyFile: copyFile,
            checkCancellation: checkCancellation ?? { try Task.checkCancellation() },
            writeRecordData: writeRecordData
        )
        return (store, rootURL)
    }

    /// Directly acquires the same root-level `flock` `PhotoDocumentStore`
    /// uses, bypassing the store entirely. The lock is a kernel object keyed
    /// by path, so a second `open()` of the same path genuinely contends
    /// with whatever `PhotoDocumentStore.importCopy` or
    /// `reconcileOrphanedImports` holds — this is how these tests simulate
    /// "another store instance/process is mid-import" deterministically,
    /// without any real concurrency, sleeping, or thread blocking: since
    /// acquisition is non-blocking on both sides, holding this from the test
    /// and then calling the store synchronously is enough to observe real
    /// lock contention.
    private final class RawImportLockHandle {
        private let fileDescriptor: Int32

        init?(rootURL: URL) {
            try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let lockURL = rootURL.appendingPathComponent(PhotoDocumentStore.importLockFilename)
            let fileDescriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
            guard fileDescriptor >= 0 else { return nil }
            guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(fileDescriptor)
                return nil
            }
            self.fileDescriptor = fileDescriptor
        }

        func release() {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
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

        let document = try await store.openInPlace(sourceURL, bookmarkData: nil).document
        try await store.saveAdjustments(.neutral.setting(.exposure, to: 1), documentID: document.id)

        XCTAssertEqual(try Data(contentsOf: sourceURL), before)
        XCTAssertEqual(document.storageMode, .inPlace)
    }

    func testImportCopyVerifiesBytesAndKeepsSourceLink() async throws {
        let sourceURL = try makeSourceFile()
        let (store, _) = makeStore()

        let document = try await store.importCopy(of: sourceURL, bookmarkData: nil).document

        XCTAssertEqual(document.storageMode, .appCopy)
        XCTAssertEqual(document.sourceFingerprint, document.workingFingerprint)
        XCTAssertNotEqual(document.workingURL, sourceURL)
        XCTAssertEqual(try Data(contentsOf: document.workingURL), try Data(contentsOf: sourceURL))
    }

    func testReopeningLoadsTheSavedAdjustments() async throws {
        let sourceURL = try makeSourceFile()
        let (store, _) = makeStore()

        let document = try await store.openInPlace(sourceURL, bookmarkData: nil).document
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

    func testImportCopyRejectsASourceModifiedWithDifferentSizeAfterVerification() async throws {
        let sourceURL = try makeSourceFile(byteCount: 4_096)
        // For a file under the chunk size the fixed call sequence is: #1
        // pre-copyFile, #2 post-copyFile, #3/#4 comparison chunks, #5 right
        // after the comparison passes and strictly before `finalSnapshot` is
        // captured (see importCopy's documentation) — exactly the window
        // the review's TOCTOU report describes.
        let trigger = MutateSourceOnCallTrigger(mutateAtCall: 5) {
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

    /// E (rejection half): the size-changing variant above alone wouldn't
    /// prove the check inspects more than file size. Same size, different
    /// bytes, with the modification date forced to a clearly different
    /// value so this doesn't depend on filesystem timestamp-write
    /// granularity.
    func testImportCopyRejectsASourceModifiedWithTheSameSizeAfterVerification() async throws {
        let sourceURL = try makeSourceFile(byteCount: 4_096, pattern: 0x5A)
        let trigger = MutateSourceOnCallTrigger(mutateAtCall: 5) {
            try Data(repeating: 0x99, count: 4_096).write(to: sourceURL)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(3_600)],
                ofItemAtPath: sourceURL.path
            )
        }
        let (store, rootURL) = makeStore(checkCancellation: { try trigger.checkCancellation() })

        do {
            _ = try await store.importCopy(of: sourceURL, bookmarkData: nil)
            XCTFail("Expected a same-size, different-content source modification to be rejected")
        } catch {
            XCTAssertEqual(error as? PhotoDocumentError, .sourceModifiedDuringImport)
        }

        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Documents"))
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Records"))
    }

    /// E (the actual fix): mutates the source strictly *after* the point
    /// where this design stops reading it — `finalSnapshot` has already
    /// been captured and compared, and both fingerprints below are derived
    /// from the staging copy alone from here on, never re-read from the
    /// source. A same-size, different-content mutation here (so this isn't
    /// a no-op size check passing by coincidence) must have no effect at
    /// all on the committed document: this is precisely the window the
    /// previous fix closed only partially by still re-reading the source
    /// for `sourceFingerprint` after this point.
    func testImportCopyIsUnaffectedBySourceMutationAfterFinalVerification() async throws {
        let sourceURL = try makeSourceFile(byteCount: 4_096, pattern: 0x5A)
        // Call #6 is right before the move — after `finalSnapshot` has
        // already been captured, compared, and both fingerprints computed
        // from staging (see importCopy's documentation).
        let trigger = MutateSourceOnCallTrigger(mutateAtCall: 6) {
            try Data(repeating: 0x99, count: 4_096).write(to: sourceURL)
        }
        let (store, _) = makeStore(checkCancellation: { try trigger.checkCancellation() })

        let document = try await store.importCopy(of: sourceURL, bookmarkData: nil).document

        XCTAssertEqual(document.sourceFingerprint, document.workingFingerprint)
        let recomputed = try FingerprintCalculator.fingerprint(forFileAt: document.workingURL)
        XCTAssertEqual(recomputed, document.workingFingerprint)
    }

    func testImportCopyWorkingFingerprintMatchesTheWorkingURLItself() async throws {
        let sourceURL = try makeSourceFile()
        let (store, _) = makeStore()

        let document = try await store.importCopy(of: sourceURL, bookmarkData: nil).document

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

        let document = try await storeA.importCopy(of: sourceURL, bookmarkData: nil).document
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

        let report = try await store.reconcileOrphanedImports(activePointer: .noActiveDocument)

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

        let report = try await store.reconcileOrphanedImports(activePointer: .noActiveDocument)

        XCTAssertEqual(report.removedOrphanIDs, [orphanID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanDirectory.path))
    }

    func testReconcileOrphanedImportsNeverRemovesADocumentWithACommittedRecord() async throws {
        let sourceURL = try makeSourceFile()
        let (store, _) = makeStore()

        let creation = try await store.importCopy(of: sourceURL, bookmarkData: nil)
        // A real commit -- the document has actually been shown to the
        // user -- not just a still-`.pending` creation.
        await store.finalizeCreation(creation)
        let document = creation.document

        // No active document remembered at all: a committed record must
        // survive regardless, since only `.pending` records are ever
        // subject to the active-ID promote-or-rollback decision.
        let report = try await store.reconcileOrphanedImports(activePointer: .noActiveDocument)
        XCTAssertFalse(report.removedOrphanIDs.contains(document.id))
        XCTAssertFalse(report.rolledBackPendingIDs.contains(document.id))

        let reloaded = try await store.loadDocument(id: document.id)
        XCTAssertEqual(try Data(contentsOf: reloaded.workingURL), try Data(contentsOf: sourceURL))
    }

    // MARK: - 3a. Crash-durable creation lifecycle (survives a process restart)
    //
    // Every test in this section builds its state with one `PhotoDocumentStore`
    // instance, then constructs a *brand-new* instance over the same `rootURL`
    // before calling `reconcileOrphanedImports` -- the new instance's
    // in-memory creation-state cache starts empty, exactly like a real
    // relaunch after a kill, so only the on-disk `.pending`/`.committed`
    // record state can be driving the outcome.

    func testCrashAfterAppCopyRecordButBeforeHandoffIsRolledBackOnNextLaunch() async throws {
        let sourceURL = try makeSourceFile()
        let originalSourceBytes = try Data(contentsOf: sourceURL)
        let (firstProcessStore, rootURL) = makeStore()

        // Simulates the process being killed right after `importCopy`
        // commits its `.pending` record -- `finalizeCreation` never runs.
        let creation = try await firstProcessStore.importCopy(of: sourceURL, bookmarkData: nil)
        let documentID = creation.document.id
        XCTAssertTrue(FileManager.default.fileExists(atPath: creation.document.workingURL.path))

        // Releases the per-document lease `importCopy` is still holding --
        // see `releaseAllPendingLeasesForTesting()` for why a real crash's
        // *lease-release* side effect is simulated explicitly here, rather
        // than by deallocating `firstProcessStore` and hoping its `deinit`
        // (and the cascading `PendingLock.deinit`) has actually run before
        // the "next launch" store below acts.
        await firstProcessStore.releaseAllPendingLeasesForTesting()

        let secondProcessStore = PhotoDocumentStore(rootURL: rootURL)
        let report = try await secondProcessStore.reconcileOrphanedImports(activePointer: .noActiveDocument)

        XCTAssertTrue(report.rolledBackPendingIDs.contains(documentID))
        do {
            _ = try await secondProcessStore.loadDocument(id: documentID)
            XCTFail("expected the never-finalized app-copy creation to be rolled back")
        } catch PhotoDocumentError.documentNotFound(documentID) {
            // expected
        }
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Documents").appendingPathComponent(documentID.uuidString))
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Sidecars").appendingPathComponent(documentID.uuidString))
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalSourceBytes)
    }

    func testCrashAfterInPlaceRecordButBeforeHandoffIsRolledBackWithoutTouchingTheRAW() async throws {
        let sourceURL = try makeSourceFile()
        let originalSourceBytes = try Data(contentsOf: sourceURL)
        let (firstProcessStore, rootURL) = makeStore()

        let creation = try await firstProcessStore.openInPlace(sourceURL, bookmarkData: nil)
        let documentID = creation.document.id

        // See the app-copy version of this test above for why this is
        // necessary: it is what actually releases the per-document lease
        // `openInPlace` holds, simulating the creating process dying.
        await firstProcessStore.releaseAllPendingLeasesForTesting()

        let secondProcessStore = PhotoDocumentStore(rootURL: rootURL)
        let report = try await secondProcessStore.reconcileOrphanedImports(activePointer: .noActiveDocument)

        XCTAssertTrue(report.rolledBackPendingIDs.contains(documentID))
        do {
            _ = try await secondProcessStore.loadDocument(id: documentID)
            XCTFail("expected the never-finalized in-place creation to be rolled back")
        } catch PhotoDocumentError.documentNotFound(documentID) {
            // expected
        }
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Sidecars").appendingPathComponent(documentID.uuidString))
        // The external RAW must never be touched by an in-place rollback.
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalSourceBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testCrashAfterActiveIDHandoffButBeforeFinalizeIsPromotedNotDeleted() async throws {
        let sourceURL = try makeSourceFile()
        let (firstProcessStore, rootURL) = makeStore()

        // Simulates a kill that happened *after* `PhotoDocumentEditor`
        // moved the active-document pointer to the new document, but
        // before `finalizeCreation` completed -- see
        // `PhotoDocumentEditor.openFreshSelection`'s atomic hand-off.
        let creation = try await firstProcessStore.importCopy(of: sourceURL, bookmarkData: nil)
        let documentID = creation.document.id
        try await firstProcessStore.saveAdjustments(.neutral.setting(.exposure, to: 0.8), documentID: documentID)

        // Releases the per-document lease `importCopy` is still holding --
        // see the app-copy rollback test above for why this is necessary.
        await firstProcessStore.releaseAllPendingLeasesForTesting()

        let secondProcessStore = PhotoDocumentStore(rootURL: rootURL)
        let report = try await secondProcessStore.reconcileOrphanedImports(activePointer: .active(documentID))

        XCTAssertTrue(report.promotedPendingIDs.contains(documentID))
        XCTAssertFalse(report.rolledBackPendingIDs.contains(documentID))
        let reloaded = try await secondProcessStore.loadDocument(id: documentID)
        XCTAssertEqual(reloaded.id, documentID)
        let adjustments = try await secondProcessStore.loadAdjustments(documentID: documentID)
        XCTAssertEqual(adjustments.exposure, 0.8, "the document -- and its already-autosaved edit -- must be preserved, not lost")

        // Now genuinely committed: a *later* launch with no (or a
        // different) active ID must no longer touch it.
        let thirdProcessStore = PhotoDocumentStore(rootURL: rootURL)
        let laterReport = try await thirdProcessStore.reconcileOrphanedImports(activePointer: .noActiveDocument)
        XCTAssertFalse(laterReport.rolledBackPendingIDs.contains(documentID))
        _ = try await thirdProcessStore.loadDocument(id: documentID)
    }

    /// A record written before crash-durable creation tracking existed has
    /// no `lifecycleState` key in its JSON at all -- not merely `null` --
    /// and must be treated as `.committed`, immune to the active-ID
    /// promote-or-rollback decision, regardless of what (if anything) the
    /// active document pointer says.
    func testLegacyRecordWithoutALifecycleFieldIsTreatedAsCommitted() async throws {
        let sourceURL = try makeSourceFile()
        let (store, rootURL) = makeStore()

        let creation = try await store.importCopy(of: sourceURL, bookmarkData: nil)
        let documentID = creation.document.id
        let recordURL = rootURL.appendingPathComponent("Records").appendingPathComponent("\(documentID.uuidString).json")

        // Strip the `lifecycleState` key entirely, simulating a record
        // written by a version of this store before the field existed --
        // not merely setting it to `null`, since that is also not how a
        // genuinely legacy file would look on disk.
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any]
        json?.removeValue(forKey: "lifecycleState")
        let strippedData = try JSONSerialization.data(withJSONObject: json as Any)
        try strippedData.write(to: recordURL)

        // A mismatched (or absent) active ID would roll back a genuinely
        // `.pending` record -- proving this one survives is what shows it
        // was correctly read as `.committed`.
        let report = try await store.reconcileOrphanedImports(activePointer: .noActiveDocument)
        XCTAssertFalse(report.rolledBackPendingIDs.contains(documentID))
        XCTAssertFalse(report.promotedPendingIDs.contains(documentID), "a legacy record is already committed -- there is nothing to promote")
        _ = try await store.loadDocument(id: documentID)
    }

    // MARK: - 3c. Per-document crash-released lease (Codex round-3 review)
    //
    // `importCopy`/`openInPlace` release the *root* lock as soon as they
    // return -- but the calling `PhotoDocumentEditor` still has real work
    // left (metadata decode, adjustments load, flushing whatever was open
    // before) before it can finalize. These tests prove a *second*, real
    // `PhotoDocumentStore` instance's `reconcileOrphanedImports` cannot
    // delete a creation still mid-flight in a *first* instance -- the
    // per-document lease (`PendingLocks/<id>.lock`) is what makes that
    // true, independent of any timing or sleep.

    /// Directly acquires the same per-document `flock` `PhotoDocumentStore`
    /// holds via `pendingLeases` -- bypassing the store entirely, the same
    /// way `RawImportLockHandle` above does for the root lock. Coupled to
    /// the on-disk `PendingLocks/<id>.lock` path by construction -- see
    /// `PendingLock`'s documentation.
    private final class RawPendingLockHandle {
        private let fileDescriptor: Int32

        init?(rootURL: URL, documentID: UUID) {
            let directory = rootURL.appendingPathComponent("PendingLocks", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let lockURL = directory.appendingPathComponent("\(documentID.uuidString).lock")
            let fileDescriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
            guard fileDescriptor >= 0 else { return nil }
            guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(fileDescriptor)
                return nil
            }
            self.fileDescriptor = fileDescriptor
        }

        func release() {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }

    /// A thread-safe on/off switch for failure-injection closures passed to
    /// `makeStore(writeRecordData:)`. Plain `var` capture doesn't compile
    /// under Swift 6 concurrency checking once the closure is invoked from
    /// the store's actor context (a different isolation domain than the
    /// test body that toggles it), so this exists purely to give those
    /// closures something `@Sendable`-safe to read.
    private final class FailureToggle: @unchecked Sendable {
        private let lock = NSLock()
        private var _shouldFail = true
        var shouldFail: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _shouldFail }
            set { lock.lock(); defer { lock.unlock() }; _shouldFail = newValue }
        }
    }

    /// Store A creates an app-copy document and, per the type's contract,
    /// is left holding its per-document lease (nothing has finalized or
    /// rolled it back yet -- exactly the state a real `PhotoDocumentEditor`
    /// leaves it in between `importCopy` returning and it finishing
    /// metadata decode). A completely independent Store B instance's
    /// reconciliation, with no matching active ID, must find the lease
    /// still held and leave the creation completely untouched rather than
    /// treating it as abandoned.
    func testReconciliationNeverTouchesAnAppCopyCreationWhoseLeaseIsStillHeldByAnotherInstance() async throws {
        let sourceURL = try makeSourceFile()
        let (storeA, rootURL) = makeStore()

        let creation = try await storeA.importCopy(of: sourceURL, bookmarkData: nil)
        let documentID = creation.document.id

        // Proves the lease really is held right now, independent of
        // `storeA`'s own bookkeeping -- the same direct-`flock` technique
        // `RawImportLockHandle` uses for the root lock.
        XCTAssertNil(RawPendingLockHandle(rootURL: rootURL, documentID: documentID), "the lease must still be held by storeA's in-flight creation")

        let storeB = PhotoDocumentStore(rootURL: rootURL)
        let report = try await storeB.reconcileOrphanedImports(activePointer: .noActiveDocument)

        XCTAssertFalse(report.rolledBackPendingIDs.contains(documentID), "storeA's still-in-flight creation must not be rolled back out from under it")
        XCTAssertFalse(report.promotedPendingIDs.contains(documentID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: creation.document.workingURL.path), "the copy must still be on disk")
        _ = try await storeB.loadDocument(id: documentID) // does not throw -- the record is untouched

        // Once storeA actually finalizes, the lease is released and a
        // *later* reconciliation pass correctly leaves it alone because it
        // is now `.committed`, not because the lease happened to still be
        // held.
        let outcome = await storeA.finalizeCreation(creation)
        XCTAssertEqual(outcome, .committed)
        XCTAssertNotNil(RawPendingLockHandle(rootURL: rootURL, documentID: documentID)?.release(), "the lease must be released once finalize durably succeeds")
    }

    /// Same guarantee for `.inPlace` -- the review explicitly called out
    /// that in-place creations need this lease too, not just app-copy.
    func testReconciliationNeverTouchesAnInPlaceCreationWhoseLeaseIsStillHeldByAnotherInstance() async throws {
        let sourceURL = try makeSourceFile()
        let (storeA, rootURL) = makeStore()

        let creation = try await storeA.openInPlace(sourceURL, bookmarkData: nil)
        let documentID = creation.document.id

        XCTAssertNil(RawPendingLockHandle(rootURL: rootURL, documentID: documentID), "the lease must still be held by storeA's in-flight creation")

        let storeB = PhotoDocumentStore(rootURL: rootURL)
        let report = try await storeB.reconcileOrphanedImports(activePointer: .noActiveDocument)

        XCTAssertFalse(report.rolledBackPendingIDs.contains(documentID))
        _ = try await storeB.loadDocument(id: documentID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path), "an in-place rollback must never touch the external RAW -- doubly true for one that must not even be attempted")
    }

    /// The interleaving the review specifically asked for: storeA's
    /// creation is promoted (not rolled back) by storeB because it matches
    /// the active ID -- but only *after* storeA's lease is actually
    /// released, proving the lease -- not luck -- is what gates this.
    func testReconciliationPromotesOnlyAfterTheCreatingInstancesLeaseIsReleased() async throws {
        let sourceURL = try makeSourceFile()
        let (storeA, rootURL) = makeStore()

        let creation = try await storeA.importCopy(of: sourceURL, bookmarkData: nil)
        let documentID = creation.document.id

        let storeB = PhotoDocumentStore(rootURL: rootURL)
        let tooEarly = try await storeB.reconcileOrphanedImports(activePointer: .active(documentID))
        XCTAssertFalse(tooEarly.promotedPendingIDs.contains(documentID), "must not promote while the lease is still held -- the creation might still be actively being worked on")
        XCTAssertTrue(tooEarly.rolledBackPendingIDs.isEmpty)
        XCTAssertTrue(tooEarly.failures.isEmpty, "a held lease is not a failure -- it is correctly and quietly skipped")

        // Simulates storeA's process finally dying without ever finalizing
        // -- see `releaseAllPendingLeasesForTesting()`.
        await storeA.releaseAllPendingLeasesForTesting()

        let afterCrash = try await storeB.reconcileOrphanedImports(activePointer: .active(documentID))
        XCTAssertTrue(afterCrash.promotedPendingIDs.contains(documentID), "now that the lease is free, the still-matching active ID promotes it")
        _ = try await storeB.loadDocument(id: documentID)
    }

    // MARK: - 3d. finalizeCreation is failure/retry-safe (Codex round-3 review)

    /// A `finalizeCreation` whose durable write fails must not flip the
    /// in-memory receipt to `.finalized` -- the record stays `.pending`,
    /// the receipt (and lease) stay valid, and a later retry that actually
    /// succeeds must still work.
    func testFinalizeCreationReturnsRetryRequiredOnWriteFailureAndSucceedsOnRetry() async throws {
        let sourceURL = try makeSourceFile()
        let toggle = FailureToggle()
        let (store, rootURL) = makeStore(writeRecordData: { data, url, fileManager in
            // Only the *finalize* write is made to fail -- identified by
            // its content (`lifecycleState: "committed"`), not merely its
            // path, since the initial `.pending` record commit inside
            // `importCopy` writes to the exact same path and must succeed
            // normally, or there would be nothing here to retry finalizing.
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if toggle.shouldFail, object?["lifecycleState"] as? String == "committed" {
                struct InjectedFailure: Error {}
                throw InjectedFailure()
            }
            try AtomicFileWriter.write(data, to: url, fileManager: fileManager)
        })

        let creation = try await store.importCopy(of: sourceURL, bookmarkData: nil)

        let firstAttempt = await store.finalizeCreation(creation)
        XCTAssertEqual(firstAttempt, .retryRequired)

        // The record on disk is still `.pending` -- not silently advanced.
        let recordURL = rootURL.appendingPathComponent("Records").appendingPathComponent("\(creation.document.id.uuidString).json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any]
        XCTAssertEqual(json?["lifecycleState"] as? String, "pending")

        // The lease is still held -- a concurrent reconciliation pass must
        // still treat this as alive, exactly as if finalize had never been
        // attempted at all.
        XCTAssertNil(RawPendingLockHandle(rootURL: rootURL, documentID: creation.document.id))

        // Retrying after the transient failure clears now durably commits.
        toggle.shouldFail = false
        let secondAttempt = await store.finalizeCreation(creation)
        XCTAssertEqual(secondAttempt, .committed)
        let committedJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any]
        XCTAssertEqual(committedJSON?["lifecycleState"] as? String, "committed")
        XCTAssertNotNil(RawPendingLockHandle(rootURL: rootURL, documentID: creation.document.id)?.release(), "finalize succeeding must release the lease")
    }

    /// `finalizeCreation` on an unrecognized/already-consumed receipt must
    /// report that explicitly rather than silently doing nothing that
    /// looks like success.
    func testFinalizeCreationOutcomesForAlreadyResolvedReceipts() async throws {
        let sourceURL = try makeSourceFile()
        let (store, _) = makeStore()

        let creation = try await store.importCopy(of: sourceURL, bookmarkData: nil)
        let firstOutcome = await store.finalizeCreation(creation)
        XCTAssertEqual(firstOutcome, .committed)
        let secondOutcome = await store.finalizeCreation(creation)
        XCTAssertEqual(secondOutcome, .alreadyFinalized)

        let rollbackCreation = try await store.openInPlace(try makeSourceFile(named: "second.ARW"), bookmarkData: nil)
        _ = await store.rollbackNewDocument(rollbackCreation)
        let rolledBackOutcome = await store.finalizeCreation(rollbackCreation)
        XCTAssertEqual(rolledBackOutcome, .alreadyRolledBack)
    }

    // MARK: - 3e. Reconciliation validates before promoting (Codex round-3 review)

    /// A pending record whose `id` field doesn't match its own filename is
    /// too malformed to trust -- promotion must refuse it and surface it as
    /// a diagnosed failure rather than silently promoting (or silently
    /// dropping) it.
    func testReconciliationRefusesToPromoteARecordWhoseIDDoesNotMatchItsFilename() async throws {
        let sourceURL = try makeSourceFile()
        let (store, rootURL) = makeStore()

        let creation = try await store.importCopy(of: sourceURL, bookmarkData: nil)
        let documentID = creation.document.id
        let recordURL = rootURL.appendingPathComponent("Records").appendingPathComponent("\(documentID.uuidString).json")

        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any]
        json?["id"] = UUID().uuidString // corrupt: no longer matches the filename
        try JSONSerialization.data(withJSONObject: json as Any).write(to: recordURL)

        // Without this, `store`'s own still-held per-document lease (from
        // its own `importCopy` above) would make its own reconciliation
        // pass skip this record as "still alive" -- correct in general,
        // but not what this test is about. See
        // `releaseAllPendingLeasesForTesting()`.
        await store.releaseAllPendingLeasesForTesting()

        let report = try await store.reconcileOrphanedImports(activePointer: .active(documentID))
        XCTAssertFalse(report.promotedPendingIDs.contains(documentID), "a record whose id doesn't match its filename must never be promoted")
        XCTAssertFalse(report.failures.isEmpty, "the mismatch must be surfaced, not silently ignored")
    }

    /// An app-copy pending record whose working file has actually gone
    /// missing (disk corruption, manual tampering) must not be promoted --
    /// promoting it would hand a caller a document whose bytes don't
    /// exist.
    func testReconciliationRefusesToPromoteAnAppCopyRecordWhoseWorkingFileIsMissing() async throws {
        let sourceURL = try makeSourceFile()
        let (store, _) = makeStore()

        let creation = try await store.importCopy(of: sourceURL, bookmarkData: nil)
        let documentID = creation.document.id
        try FileManager.default.removeItem(at: creation.document.workingURL)

        // See the id-mismatch test above for why this is necessary: without
        // it, `store`'s own still-held lease from its own `importCopy`
        // would make this same instance's reconciliation skip the record
        // as "still alive" rather than actually validating it.
        await store.releaseAllPendingLeasesForTesting()

        let report = try await store.reconcileOrphanedImports(activePointer: .active(documentID))
        XCTAssertFalse(report.promotedPendingIDs.contains(documentID))
        XCTAssertFalse(report.failures.isEmpty)
    }

    // MARK: - 3f. Full-content digest for relink (Codex round-3 review)

    /// A file over `FingerprintCalculator.wholeFileThreshold` with the
    /// *same size* and *identical first/last MiB* as the original, but
    /// different bytes in the untouched middle, is exactly what a sampled
    /// `FileFingerprint` comparison cannot catch -- the whole reason
    /// `contentDigestSHA256` exists. Relink must reject it.
    func testRelinkRejectsMidFileCorruptionInvisibleToTheSampledFingerprint() async throws {
        let byteCount = Int(FingerprintCalculator.wholeFileThreshold) + (4 << 20)
        let sourceURL = try makeSourceFile(named: "large.ARW", byteCount: byteCount, pattern: 0x11)
        let (store, _) = makeStore()

        let creation = try await store.openInPlace(sourceURL, bookmarkData: nil)
        XCTAssertNotNil(creation.document.contentDigestSHA256, "a freshly created document must have a full digest")

        // Same size, identical edges, corrupted middle.
        var bytes = try Data(contentsOf: sourceURL)
        let middle = bytes.count / 2
        bytes[middle] = bytes[middle] &+ 1
        let candidateURL = temporaryDirectory.appendingPathComponent("candidate.ARW")
        try bytes.write(to: candidateURL)

        // The sampled fingerprint alone would *not* catch this -- proving
        // the premise before proving the fix.
        let candidateFingerprint = try FingerprintCalculator.fingerprint(forFileAt: candidateURL)
        XCTAssertEqual(candidateFingerprint, creation.document.sourceFingerprint, "premise: the sampled fingerprint alone cannot see mid-file corruption")

        do {
            _ = try await store.relinkInPlaceDocument(
                documentID: creation.document.id, candidateURL: candidateURL, bookmarkData: Data(), resolvedBookmarkURL: candidateURL
            )
            XCTFail("expected the full-content digest to catch what the sampled fingerprint could not")
        } catch RelinkError.contentMismatch {
            // expected
        }

        // Nothing was changed.
        let stillThere = try await store.loadDocument(id: creation.document.id)
        XCTAssertEqual(stillThere.workingURL, sourceURL)
    }

    /// The successful, positive-path counterpart: relinking to a byte-
    /// identical candidate succeeds and upgrades the record's location.
    func testRelinkAcceptsAByteIdenticalCandidateUsingTheFullDigest() async throws {
        let byteCount = Int(FingerprintCalculator.wholeFileThreshold) + (1 << 20)
        let sourceURL = try makeSourceFile(named: "large.ARW", byteCount: byteCount, pattern: 0x22)
        let (store, _) = makeStore()

        let creation = try await store.openInPlace(sourceURL, bookmarkData: nil)

        let candidateURL = temporaryDirectory.appendingPathComponent("candidate.ARW")
        try Data(contentsOf: sourceURL).write(to: candidateURL)

        let relinked = try await store.relinkInPlaceDocument(
            documentID: creation.document.id, candidateURL: candidateURL, bookmarkData: Data("bookmark".utf8), resolvedBookmarkURL: candidateURL
        )
        XCTAssertEqual(relinked.workingURL, candidateURL)
        XCTAssertEqual(relinked.contentDigestSHA256, creation.document.contentDigestSHA256)
    }

    /// A legacy record with no stored digest at all must fall back to the
    /// sampled fingerprint rather than refusing relink outright -- but a
    /// successful relink must upgrade it with a real digest so the gap
    /// does not persist for next time too.
    func testRelinkOfALegacyRecordWithNoDigestFallsBackToTheSampledFingerprintAndUpgradesOnSuccess() async throws {
        let sourceURL = try makeSourceFile()
        let (store, rootURL) = makeStore()

        let creation = try await store.openInPlace(sourceURL, bookmarkData: nil)
        let recordURL = rootURL.appendingPathComponent("Records").appendingPathComponent("\(creation.document.id.uuidString).json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any]
        json?.removeValue(forKey: "contentDigestSHA256")
        try JSONSerialization.data(withJSONObject: json as Any).write(to: recordURL)

        let reloaded = try await store.loadDocument(id: creation.document.id)
        XCTAssertNil(reloaded.contentDigestSHA256, "premise: this record has no digest, as a pre-digest-era record would not")

        let candidateURL = temporaryDirectory.appendingPathComponent("candidate.ARW")
        try Data(contentsOf: sourceURL).write(to: candidateURL)

        let relinked = try await store.relinkInPlaceDocument(
            documentID: creation.document.id, candidateURL: candidateURL, bookmarkData: Data("bookmark".utf8), resolvedBookmarkURL: candidateURL
        )
        XCTAssertEqual(relinked.workingURL, candidateURL)
        XCTAssertNotNil(relinked.contentDigestSHA256, "a successful relink must upgrade a legacy record with a real digest")
    }

    // MARK: - 3b. Root import lock: real cross-instance contention

    /// A: lock contention. `reconcileOrphanedImports` cannot even start
    /// scanning while another holder — another store instance, another
    /// process, or (simulated here) this raw handle — has the root import
    /// lock: it must report `.importInProgress` and touch nothing, then
    /// succeed normally once the lock is released. `RawImportLockHandle`
    /// holds the exact same kernel `flock` `importCopy` would hold for its
    /// entire duration, so this is real OS-level contention, not a stand-in.
    func testReconciliationReturnsBusyWhileTheImportLockIsHeldAndRecoversAfterRelease() async throws {
        let sourceURL = try makeSourceFile()
        let (store, rootURL) = makeStore()

        guard let externalLock = RawImportLockHandle(rootURL: rootURL) else {
            XCTFail("Expected to acquire the raw import lock directly")
            return
        }

        do {
            _ = try await store.reconcileOrphanedImports(activePointer: .noActiveDocument)
            XCTFail("Expected reconciliation to report the lock as busy rather than proceed")
        } catch {
            XCTAssertEqual(error as? PhotoDocumentError, .importInProgress)
        }
        // Nothing was scanned or deleted — reconciliation never got past
        // acquiring the lock, so Documents/ was never even listed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Documents").path))

        externalLock.release()

        // Once the lock is free, a real import completes normally.
        let document = try await store.importCopy(of: sourceURL, bookmarkData: nil).document
        let reloaded = try await store.loadDocument(id: document.id)
        XCTAssertEqual(try Data(contentsOf: reloaded.workingURL), try Data(contentsOf: sourceURL))
    }

    /// A (other direction): `importCopy` itself must equally defer to
    /// whoever already holds the lock, making no changes at all.
    func testImportCopyReturnsBusyWhileAnotherHolderHasTheImportLock() async throws {
        let sourceURL = try makeSourceFile()
        let (store, rootURL) = makeStore()

        guard let externalLock = RawImportLockHandle(rootURL: rootURL) else {
            XCTFail("Expected to acquire the raw import lock directly")
            return
        }
        defer { externalLock.release() }

        do {
            _ = try await store.importCopy(of: sourceURL, bookmarkData: nil)
            XCTFail("Expected importCopy to report the lock as busy rather than proceed")
        } catch {
            XCTAssertEqual(error as? PhotoDocumentError, .importInProgress)
        }

        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Documents"))
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Records"))
    }

    /// B: check-record/delete race. The exclusive lock makes the originally
    /// reported interleaving (reconciler checks a record is absent, an
    /// importer commits one, reconciler deletes the directory anyway)
    /// structurally impossible: an importer cannot even begin creating a
    /// `Documents/<id>` directory, let alone commit a record, without first
    /// acquiring the same lock a reconciliation pass holds for its whole
    /// scan. Since the interleaving can't be constructed, this proves the
    /// stronger property the review asked for instead: an importer cannot
    /// commit *at all* while that lock is held — not merely that the
    /// end state happens to look fine.
    func testImportCopyCannotCommitWhileReconciliationHoldsTheLock() async throws {
        let sourceURL = try makeSourceFile()
        let (store, rootURL) = makeStore()

        // Standing in for a reconciliation pass mid-scan: this holds the
        // exact lock `reconcileOrphanedImports` holds for its entire
        // duration.
        guard let reconcilerLock = RawImportLockHandle(rootURL: rootURL) else {
            XCTFail("Expected to acquire the raw import lock directly")
            return
        }

        do {
            _ = try await store.importCopy(of: sourceURL, bookmarkData: nil)
            XCTFail("Expected importCopy to be unable to commit while reconciliation holds the lock")
        } catch {
            XCTAssertEqual(error as? PhotoDocumentError, .importInProgress)
        }
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Documents"))
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Records"))

        reconcilerLock.release()

        let document = try await store.importCopy(of: sourceURL, bookmarkData: nil).document
        XCTAssertEqual(try Data(contentsOf: document.workingURL), try Data(contentsOf: sourceURL))
    }

    /// C: no timeout. There is nothing left in this design that measures
    /// elapsed time — reconciliation's only question is "can the lock be
    /// acquired right now." Holding the raw lock here stands in for an
    /// import that has been running far longer than the review's originally
    /// reported 300-second marker-age threshold ever protected against; the
    /// outcome must be identical regardless of how long that would have
    /// been, because nothing here is measuring it.
    func testReconciliationNeverTreatsAHeldLockAsAbandonedRegardlessOfElapsedTime() async throws {
        let (store, rootURL) = makeStore()

        guard let externalLock = RawImportLockHandle(rootURL: rootURL) else {
            XCTFail("Expected to acquire the raw import lock directly")
            return
        }
        defer { externalLock.release() }

        do {
            _ = try await store.reconcileOrphanedImports(activePointer: .noActiveDocument)
            XCTFail("Expected reconciliation to defer while the lock is held, no matter how long")
        } catch {
            XCTAssertEqual(error as? PhotoDocumentError, .importInProgress)
        }
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

        let report = try await store.reconcileOrphanedImports(activePointer: .noActiveDocument)

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
            let document = try await store.openInPlace(sourceURL, bookmarkData: bookmark).document
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
            let document = try await store.importCopy(of: sourceURL, bookmarkData: bookmark).document
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
        let document = try await store.openInPlace(sourceURL, bookmarkData: nil).document
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
        let document = try await store.openInPlace(sourceURL, bookmarkData: nil).document
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
        let document = try await store.openInPlace(sourceURL, bookmarkData: nil).document

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

    /// `openInPlace` reads `sourceURL` through a single open file
    /// descriptor to compute both the sampled `FileFingerprint` and the
    /// full-content digest (Codex round-5 review) — a write landing on
    /// that exact file between the read finishing and the closing
    /// `fstat` re-check must be caught, deterministically, not merely by
    /// chance timing. `MutateSourceOnCallTrigger` lands the mutation on
    /// the exact `checkCancellation` call between the read loop finishing
    /// and that final identity re-check, for a file small enough (under
    /// the whole-file-threshold path) that the call sequence is fixed:
    /// #1 the one non-empty chunk read, #2 the EOF read, #3 the
    /// post-loop pre-recheck call.
    func testOpenInPlaceRejectsASourceMutatedAfterBeingHashedButBeforeTheClosingIdentityCheck() async throws {
        let sourceURL = try makeSourceFile(byteCount: 4_096, pattern: 0x51)
        let trigger = MutateSourceOnCallTrigger(mutateAtCall: 3) {
            try Data(repeating: 0x52, count: 4_096).write(to: sourceURL)
        }
        let (store, rootURL) = makeStore(checkCancellation: { try trigger.checkCancellation() })

        do {
            _ = try await store.openInPlace(sourceURL, bookmarkData: nil)
            XCTFail("expected a source mutated during identity computation to be rejected")
        } catch {
            XCTAssertEqual(error as? PhotoDocumentError, .sourceModifiedDuringImport)
        }

        // Nothing was written -- no pending record, and (indirectly) no
        // lease left behind either: a fresh store's reconciliation over
        // this same root finds nothing pending to promote or roll back.
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Records"))
        let freshStore = PhotoDocumentStore(rootURL: rootURL)
        let report = try await freshStore.reconcileOrphanedImports(activePointer: .noActiveDocument)
        XCTAssertTrue(report.rolledBackPendingIDs.isEmpty)
        XCTAssertTrue(report.promotedPendingIDs.isEmpty)
        XCTAssertTrue(report.failures.isEmpty)
    }

    /// Same identity transaction, large-file path: the fingerprint's
    /// edge-sampling (captured from the first chunk and a rolling tail
    /// buffer while streaming for the digest) must still agree exactly
    /// with `FingerprintCalculator`'s own independent computation over
    /// the same bytes.
    func testOpenInPlaceSingleFDFingerprintMatchesFingerprintCalculatorForALargeFile() async throws {
        let byteCount = Int(FingerprintCalculator.wholeFileThreshold) + (3 << 20)
        let sourceURL = try makeSourceFile(named: "large.ARW", byteCount: byteCount, pattern: 0x53)
        let (store, _) = makeStore()

        let document = try await store.openInPlace(sourceURL, bookmarkData: nil).document

        let independentlyComputed = try FingerprintCalculator.fingerprint(forFileAt: sourceURL)
        XCTAssertEqual(document.sourceFingerprint, independentlyComputed)
        XCTAssertNotNil(document.contentDigestSHA256)
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

    // MARK: - rollbackNewDocument / updateSourceBookmark / updateInPlaceLocation (Task 6 hardening)

    func testRollbackNewDocumentRemovesAnAppCopysRecordSidecarAndCopyButNeverTheSource() async throws {
        let sourceURL = try makeSourceFile()
        let originalSourceBytes = try Data(contentsOf: sourceURL)
        let (store, rootURL) = makeStore()

        let creation = try await store.importCopy(of: sourceURL, bookmarkData: nil)
        let document = creation.document
        try await store.saveAdjustments(.neutral.setting(.exposure, to: 1), documentID: document.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.workingURL.path))

        let report = await store.rollbackNewDocument(creation)
        XCTAssertEqual(report.outcome, .cleaned)
        XCTAssertTrue(report.isFullyCleaned)
        XCTAssertEqual(report.lock, .succeeded)
        XCTAssertEqual(report.record, .succeeded)
        XCTAssertEqual(report.sidecar, .succeeded)
        XCTAssertEqual(report.copy, .succeeded)

        do {
            _ = try await store.loadDocument(id: document.id)
            XCTFail("Expected the rolled-back document's record to be gone")
        } catch PhotoDocumentError.documentNotFound(document.id) {
            // expected
        }
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Documents").appendingPathComponent(document.id.uuidString))
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Sidecars").appendingPathComponent(document.id.uuidString))
        // The external source must never be touched by a rollback.
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalSourceBytes)
    }

    func testRollbackNewDocumentRemovesAnInPlaceRecordAndSidecarButNeverTheExternalRAW() async throws {
        let sourceURL = try makeSourceFile()
        let originalSourceBytes = try Data(contentsOf: sourceURL)
        let (store, rootURL) = makeStore()

        let creation = try await store.openInPlace(sourceURL, bookmarkData: nil)
        let document = creation.document
        try await store.saveAdjustments(.neutral.setting(.exposure, to: 1), documentID: document.id)

        let report = await store.rollbackNewDocument(creation)
        XCTAssertEqual(report.outcome, .cleaned)
        XCTAssertTrue(report.isFullyCleaned)
        XCTAssertEqual(report.lock, .notApplicable)
        XCTAssertEqual(report.copy, .notApplicable)
        XCTAssertEqual(report.record, .succeeded)
        XCTAssertEqual(report.sidecar, .succeeded)

        do {
            _ = try await store.loadDocument(id: document.id)
            XCTFail("Expected the rolled-back document's record to be gone")
        } catch PhotoDocumentError.documentNotFound(document.id) {
            // expected
        }
        assertDirectoryAbsentOrEmpty(rootURL.appendingPathComponent("Sidecars").appendingPathComponent(document.id.uuidString))
        // The RAW at `workingURL` (== `sourceURL` in-place) must survive intact.
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalSourceBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    /// A receipt is single-use: once a creation has been rolled back, a
    /// second call with the same value must explicitly report
    /// `.alreadyRolledBack`, never disguise itself as another successful
    /// cleanup.
    func testRollbackNewDocumentIsSingleUse() async throws {
        let sourceURL = try makeSourceFile()
        let (store, _) = makeStore()
        let creation = try await store.openInPlace(sourceURL, bookmarkData: nil)

        let first = await store.rollbackNewDocument(creation)
        XCTAssertEqual(first.outcome, .cleaned)
        XCTAssertTrue(first.isFullyCleaned)

        let second = await store.rollbackNewDocument(creation)
        XCTAssertEqual(second.outcome, .alreadyRolledBack)
        XCTAssertFalse(second.isFullyCleaned, "an already-rolled-back result must never read as success")
        XCTAssertEqual(second.lock, .notApplicable)
        XCTAssertEqual(second.record, .notApplicable)
        XCTAssertEqual(second.sidecar, .notApplicable)
        XCTAssertEqual(second.copy, .notApplicable)
    }

    /// Once a creation is finalized (kept), its receipt must never be able
    /// to delete the now-legitimate document, even if a caller (in error)
    /// still holds and reuses the same `PhotoDocumentCreation` value -- and
    /// must say so explicitly via `.alreadyFinalized`, not just "nothing to
    /// do".
    func testRollbackNewDocumentNeverDeletesAFinalizedCreation() async throws {
        let sourceURL = try makeSourceFile()
        let (store, _) = makeStore()
        let creation = try await store.importCopy(of: sourceURL, bookmarkData: nil)
        await store.finalizeCreation(creation)

        let report = await store.rollbackNewDocument(creation)
        XCTAssertEqual(report.outcome, .alreadyFinalized)
        XCTAssertFalse(report.isFullyCleaned, "an already-finalized rejection must never read as a successful cleanup")
        XCTAssertEqual(report.record, .notApplicable)
        XCTAssertEqual(report.copy, .notApplicable)

        // The finalized document is still fully intact.
        let stillThere = try await store.loadDocument(id: creation.document.id)
        XCTAssertEqual(stillThere.id, creation.document.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: creation.document.workingURL.path))
    }

    /// `rollbackNewDocument` only ever accepts a `PhotoDocumentCreation` --
    /// there is no public API that turns an existing `PhotoDocument`
    /// (e.g. one `loadDocument` just returned) into one, so an existing
    /// document can never be deleted through this path. This test
    /// documents that guarantee by construction: it would not compile if
    /// `PhotoDocumentCreation` had a public initializer.
    func testRollbackAPICannotBeCalledWithAnArbitraryExistingDocument() async throws {
        let sourceURL = try makeSourceFile()
        let (store, _) = makeStore()
        let creation = try await store.openInPlace(sourceURL, bookmarkData: nil)
        await store.finalizeCreation(creation)

        // `loadDocument` returns a bare `PhotoDocument`; there is no
        // constructor from that back to a `PhotoDocumentCreation`, so
        // there is no expression that could be written here to roll this
        // existing, finalized document back. (If `PhotoDocumentCreation`
        // ever grows a public initializer, this comment -- and the
        // guarantee -- would no longer hold; watch for that in review.)
        let existing = try await store.loadDocument(id: creation.document.id)
        XCTAssertEqual(existing.id, creation.document.id)
    }

    /// Sidecar removal failure must be visible in the report, not folded
    /// into an overall "succeeded" -- and, per the record-last deletion
    /// ordering (Codex round-3 review), the record itself must not even be
    /// attempted once an earlier step has already failed: as long as it
    /// survives on disk (`.pending`), a retry -- or a later
    /// `reconcileOrphanedImports`, after a real crash -- can still find and
    /// finish this cleanup.
    func testRollbackNewDocumentReportsAFailedSidecarRemoval() async throws {
        let sourceURL = try makeSourceFile()
        let (store, rootURL) = makeStore()
        let creation = try await store.importCopy(of: sourceURL, bookmarkData: nil)
        try await store.saveAdjustments(.neutral, documentID: creation.document.id)

        // Replace the sidecar directory with a regular file so removal
        // fails, simulating a permissions/IO failure without needing real
        // filesystem permission games.
        let sidecarDirectory = rootURL
            .appendingPathComponent("Sidecars", isDirectory: true)
            .appendingPathComponent(creation.document.id.uuidString, isDirectory: true)
        try FileManager.default.removeItem(at: sidecarDirectory)
        let blocker = sidecarDirectory.appendingPathComponent("blocker")
        try FileManager.default.createDirectory(at: sidecarDirectory, withIntermediateDirectories: true)
        try Data([0x00]).write(to: blocker)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: blocker.path)

        let report = await store.rollbackNewDocument(creation)
        XCTAssertEqual(report.outcome, .retryRequired)
        XCTAssertFalse(report.isFullyCleaned)
        XCTAssertEqual(report.lock, .succeeded, "the lock was actually available and acquired -- only the sidecar step itself failed")
        XCTAssertEqual(report.copy, .succeeded)
        XCTAssertEqual(report.sidecar, .failed)
        XCTAssertEqual(report.record, .failed, "the record must not be deleted once an earlier step (the sidecar) has failed -- it is what a retry finds")

        // The record really is still on disk -- not merely reported as
        // `.failed` -- which is what makes a retry (or a fresh store's
        // reconciliation, after a real crash) possible at all.
        let recordURL = rootURL.appendingPathComponent("Records").appendingPathComponent("\(creation.document.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path))

        // The receipt is still valid for a retry -- it was not consumed by
        // a partially-failed attempt.
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: blocker.path)
        let retried = await store.rollbackNewDocument(creation)
        XCTAssertEqual(retried.outcome, .cleaned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))
    }

    /// Contention for the root import lock must not produce a half-done
    /// rollback where some of {copy, record, sidecar} disappear while
    /// others remain, and must not consume the receipt -- a caller (or a
    /// later `reconcileOrphanedImports`, via the record's on-disk
    /// `.pending` state) must be able to retry once the contention clears.
    func testRollbackNewDocumentUnderLockContentionNeverSilentlyDropsTheCopy() async throws {
        let sourceURL = try makeSourceFile()
        let (store, rootURL) = makeStore()
        let creation = try await store.importCopy(of: sourceURL, bookmarkData: nil)
        try await store.saveAdjustments(.neutral, documentID: creation.document.id)

        let contender = RawImportLockHandle(rootURL: rootURL)
        XCTAssertNotNil(contender, "expected to hold the lock for this test")

        let report = await store.rollbackNewDocument(creation)
        XCTAssertEqual(report.outcome, .retryRequired)
        XCTAssertFalse(report.isFullyCleaned)
        XCTAssertEqual(report.lock, .failed)
        // Nothing was attempted -- not just the copy -- while the lock
        // could not be acquired.
        XCTAssertEqual(report.copy, .notApplicable)
        XCTAssertEqual(report.record, .notApplicable)
        XCTAssertEqual(report.sidecar, .notApplicable)

        // Every trace is still fully present and consistent.
        XCTAssertTrue(FileManager.default.fileExists(atPath: creation.document.workingURL.path))
        let stillLoadable = try await store.loadDocument(id: creation.document.id)
        XCTAssertEqual(stillLoadable.id, creation.document.id)
        let stillSaved = try await store.loadAdjustments(documentID: creation.document.id)
        XCTAssertEqual(stillSaved, .neutral)

        // Once the contention clears, the *same* creation can retry and
        // this time actually clean up everything.
        contender?.release()
        let retried = await store.rollbackNewDocument(creation)
        XCTAssertEqual(retried.outcome, .cleaned)
        XCTAssertTrue(retried.isFullyCleaned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: creation.document.workingURL.path))
        do {
            _ = try await store.loadDocument(id: creation.document.id)
            XCTFail("expected the record to be gone after the successful retry")
        } catch PhotoDocumentError.documentNotFound(creation.document.id) {
            // expected
        }
    }

    func testUpdateSourceBookmarkRewritesOnlyThatFieldAtomically() async throws {
        let sourceURL = try makeSourceFile()
        let (store, _) = makeStore()
        let original = "original-bookmark".data(using: .utf8)!
        let refreshed = "refreshed-bookmark".data(using: .utf8)!

        let document = try await store.openInPlace(sourceURL, bookmarkData: original).document
        try await store.updateSourceBookmark(refreshed, documentID: document.id)

        let reloaded = try await store.loadDocument(id: document.id)
        XCTAssertEqual(reloaded.sourceBookmarkData, refreshed)
        XCTAssertEqual(reloaded.workingURL, document.workingURL)
        XCTAssertEqual(reloaded.storageMode, .inPlace)
        XCTAssertEqual(reloaded.workingFingerprint, document.workingFingerprint)
    }

    func testUpdateInPlaceLocationMovesWorkingURLSourceURLAndBookmarkTogether() async throws {
        let sourceURL = try makeSourceFile()
        let (store, _) = makeStore()
        let original = "original-bookmark".data(using: .utf8)!
        let refreshed = "refreshed-bookmark".data(using: .utf8)!

        let document = try await store.openInPlace(sourceURL, bookmarkData: original).document

        let newURL = temporaryDirectory.appendingPathComponent("relocated.ARW")
        try FileManager.default.moveItem(at: sourceURL, to: newURL)
        try await store.updateInPlaceLocation(newURL: newURL, bookmarkData: refreshed, documentID: document.id)

        let reloaded = try await store.loadDocument(id: document.id)
        XCTAssertEqual(reloaded.workingURL, newURL)
        XCTAssertEqual(reloaded.sourceURL, newURL)
        XCTAssertEqual(reloaded.sourceBookmarkData, refreshed)
        XCTAssertEqual(reloaded.storageMode, .inPlace)
        // Content identity is untouched -- only where the file resolves changed.
        XCTAssertEqual(reloaded.workingFingerprint, document.workingFingerprint)
        XCTAssertEqual(reloaded.sourceFingerprint, document.sourceFingerprint)
    }

    // MARK: - 8. Relink identity transaction (Codex round-4 review)

    /// Any diagnostic message a test asserts on must never carry a path
    /// fragment -- an absolute path, this test run's own temp directory,
    /// or any of the usual macOS path prefixes an `NSError
    /// .localizedDescription` tends to embed.
    private func assertMessageIsPathFree(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        for forbidden in ["/Users/", "/Volumes/", "/private/var/", temporaryDirectory.path] {
            XCTAssertFalse(
                message.contains(forbidden),
                "diagnostic message leaked a path fragment (\(forbidden)): \(message)",
                file: file, line: line
            )
        }
    }

    /// The exact TOCTOU window the review's identity-transaction report
    /// targets: `candidateURL` is swapped for different bytes strictly
    /// *after* it has already been opened, read, and hashed once (single
    /// fd, per `relinkInPlaceDocument`'s design), but strictly *before*
    /// the final pre-commit re-check. That re-check -- re-`stat`ing the
    /// path and comparing against the identity captured from the open fd
    /// -- is what must catch this; a naive pre/post-snapshot-of-attributes
    /// design that never re-opens or never compares against the
    /// originally-opened identity would not.
    func testRelinkRejectsACandidateSwappedAfterItWasHashedButBeforeCommit() async throws {
        let sourceURL = try makeSourceFile(byteCount: 4_096, pattern: 0x33)
        let (creationStore, rootURL) = makeStore()
        let creation = try await creationStore.openInPlace(sourceURL, bookmarkData: nil)
        let originalAdjustments = PhotoAdjustments.neutral.setting(.contrast, to: 22)
        try await creationStore.saveAdjustments(originalAdjustments, documentID: creation.document.id)

        let candidateURL = temporaryDirectory.appendingPathComponent("candidate.ARW")
        try Data(contentsOf: sourceURL).write(to: candidateURL)

        // For a file this small: call #1 is the loop's one non-empty
        // read, #2 is the loop's EOF read, and #3 is the single
        // post-loop check right before the final re-stat -- exactly the
        // window this test targets. A fresh store instance (same
        // `rootURL`) is used for the relink attempt so this trigger's
        // count isn't also perturbed by `openInPlace` above having its
        // own `checkCancellation` calls.
        let trigger = MutateSourceOnCallTrigger(mutateAtCall: 3) {
            try Data(repeating: 0x77, count: 4_096).write(to: candidateURL)
        }
        let relinkStore = PhotoDocumentStore(rootURL: rootURL, checkCancellation: { try trigger.checkCancellation() })

        do {
            _ = try await relinkStore.relinkInPlaceDocument(
                documentID: creation.document.id, candidateURL: candidateURL, bookmarkData: Data(), resolvedBookmarkURL: candidateURL
            )
            XCTFail("expected a candidate swapped after being hashed to be rejected")
        } catch RelinkError.sourceModifiedDuringRelink {
            // expected
        }

        // Nothing changed -- verified from an entirely fresh store
        // instance, the same way a real relaunch would see it.
        let freshStore = PhotoDocumentStore(rootURL: rootURL)
        let stillThere = try await freshStore.loadDocument(id: creation.document.id)
        XCTAssertEqual(stillThere.workingURL, sourceURL)
        XCTAssertEqual(stillThere.sourceURL, sourceURL)
        let stillSavedAdjustments = try await freshStore.loadAdjustments(documentID: creation.document.id)
        XCTAssertEqual(stillSavedAdjustments.contrast, 22)
    }

    /// The fresh bookmark's resolved URL is part of the identity
    /// transaction too, not an afterthought -- a bookmark that resolves
    /// to a *different* file than the one just opened and hashed must be
    /// rejected exactly like a swapped candidate path would be.
    func testRelinkRejectsWhenTheResolvedBookmarkURLIsADifferentFile() async throws {
        let sourceURL = try makeSourceFile(byteCount: 4_096, pattern: 0x44)
        let (store, _) = makeStore()
        let creation = try await store.openInPlace(sourceURL, bookmarkData: nil)

        let candidateURL = temporaryDirectory.appendingPathComponent("candidate.ARW")
        try Data(contentsOf: sourceURL).write(to: candidateURL)
        let decoyURL = temporaryDirectory.appendingPathComponent("decoy.ARW")
        try Data(repeating: 0x55, count: 4_096).write(to: decoyURL)

        do {
            _ = try await store.relinkInPlaceDocument(
                documentID: creation.document.id, candidateURL: candidateURL, bookmarkData: Data(), resolvedBookmarkURL: decoyURL
            )
            XCTFail("expected a bookmark resolving to a different file than the picked candidate to be rejected")
        } catch RelinkError.bookmarkIdentityMismatch {
            // expected
        }

        let stillThere = try await store.loadDocument(id: creation.document.id)
        XCTAssertEqual(stillThere.workingURL, sourceURL)
    }

    // MARK: - 9. Legacy large RAW must be safely refused (Codex round-4 review)

    /// A legacy record (no stored digest) whose candidate is *larger*
    /// than `FingerprintCalculator.wholeFileThreshold` has no genuine
    /// full-content guarantee available at all -- the sampled fingerprint
    /// is edges-only at that size. Must refuse outright rather than
    /// silently comparing the sample and calling that safe. Same size,
    /// identical edges, corrupted middle: proves this isn't merely
    /// falling back to (and passing) the weaker sampled check.
    func testRelinkOfALegacyLargeRecordWithNoDigestIsRefusedOutright() async throws {
        let byteCount = Int(FingerprintCalculator.wholeFileThreshold) + (4 << 20)
        let sourceURL = try makeSourceFile(named: "large-legacy.ARW", byteCount: byteCount, pattern: 0x66)
        let (store, rootURL) = makeStore()
        let creation = try await store.openInPlace(sourceURL, bookmarkData: nil)

        let recordURL = rootURL.appendingPathComponent("Records").appendingPathComponent("\(creation.document.id.uuidString).json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any]
        json?.removeValue(forKey: "contentDigestSHA256")
        try JSONSerialization.data(withJSONObject: json as Any).write(to: recordURL)

        var bytes = try Data(contentsOf: sourceURL)
        let middle = bytes.count / 2
        bytes[middle] = bytes[middle] &+ 1
        let candidateURL = temporaryDirectory.appendingPathComponent("candidate-legacy.ARW")
        try bytes.write(to: candidateURL)

        do {
            _ = try await store.relinkInPlaceDocument(
                documentID: creation.document.id, candidateURL: candidateURL, bookmarkData: Data(), resolvedBookmarkURL: candidateURL
            )
            XCTFail("expected a legacy record above the sampling threshold to refuse relink outright, not fall back to the sample")
        } catch RelinkError.legacyFullDigestUnavailable {
            // expected
        }

        let stillThere = try await store.loadDocument(id: creation.document.id)
        XCTAssertEqual(stillThere.workingURL, sourceURL)
    }

    // MARK: - 10. Orphan sidecar reconciliation (Codex round-4 review)

    func testReconciliationRemovesAnOrphanedSidecarDirectoryWithNoRecordAtAll() async throws {
        let (store, rootURL) = makeStore()
        let orphanID = UUID()
        let sidecarDirectory = rootURL.appendingPathComponent("Sidecars", isDirectory: true).appendingPathComponent(orphanID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sidecarDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: sidecarDirectory.appendingPathComponent("sidecar.json"))

        let report = try await store.reconcileOrphanedImports(activePointer: .noActiveDocument)
        XCTAssertTrue(report.removedOrphanSidecarIDs.contains(orphanID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarDirectory.path))
    }

    func testReconciliationReportsAFailedOrphanSidecarRemovalSafely() async throws {
        let (store, rootURL) = makeStore()
        let orphanID = UUID()
        let sidecarDirectory = rootURL.appendingPathComponent("Sidecars", isDirectory: true).appendingPathComponent(orphanID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sidecarDirectory, withIntermediateDirectories: true)
        let blocker = sidecarDirectory.appendingPathComponent("blocker")
        try Data([0x00]).write(to: blocker)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: blocker.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: blocker.path) }

        let report = try await store.reconcileOrphanedImports(activePointer: .noActiveDocument)
        XCTAssertFalse(report.removedOrphanSidecarIDs.contains(orphanID))
        let message = try XCTUnwrap(report.failures[orphanID])
        assertMessageIsPathFree(message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarDirectory.path))
    }

    /// A `Sidecars/` entry whose name isn't even a well-formed UUID might
    /// not be this store's data at all -- must be left completely
    /// untouched and surfaced only as a diagnostic, never deleted on a
    /// guess.
    func testReconciliationLeavesAMalformedSidecarEntryNameCompletelyUntouched() async throws {
        let (store, rootURL) = makeStore()
        let malformedDirectory = rootURL.appendingPathComponent("Sidecars", isDirectory: true).appendingPathComponent("not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: malformedDirectory, withIntermediateDirectories: true)
        try Data("marker".utf8).write(to: malformedDirectory.appendingPathComponent("marker"))

        let report = try await store.reconcileOrphanedImports(activePointer: .noActiveDocument)
        XCTAssertTrue(report.ignoredSidecarEntries.contains("not-a-uuid"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: malformedDirectory.appendingPathComponent("marker").path), "must never delete something it can't positively identify as its own orphan")
    }

    /// A `Sidecars/` entry that *does* have a matching record must never
    /// be touched by this pass, regardless of what else is going on --
    /// the ordinary, overwhelmingly common case.
    func testReconciliationNeverRemovesASidecarDirectoryWithAMatchingRecord() async throws {
        let sourceURL = try makeSourceFile()
        let (store, _) = makeStore()
        let creation = try await store.importCopy(of: sourceURL, bookmarkData: nil)
        try await store.saveAdjustments(.neutral, documentID: creation.document.id)
        await store.releaseAllPendingLeasesForTesting()

        let report = try await store.reconcileOrphanedImports(activePointer: .active(creation.document.id))
        XCTAssertFalse(report.removedOrphanSidecarIDs.contains(creation.document.id))
        _ = try await store.loadAdjustments(documentID: creation.document.id)
    }

    // MARK: - 11. Active pointer corruption must block reconciliation entirely (Codex round-4 review)

    /// A corrupt (not merely absent) active-pointer file must never be
    /// treated as "no active document" -- doing so would let
    /// reconciliation roll back a pending creation that might be exactly
    /// the document the user was mid-handoff to, with no way to tell
    /// since the pointer that would say so can't be read.
    func testCorruptActivePointerBlocksAllPromotionAndRollbackAndIsReportedSafely() async throws {
        let sourceURL = try makeSourceFile()
        let (store, rootURL) = makeStore()
        let creation = try await store.importCopy(of: sourceURL, bookmarkData: nil)
        // Simulates the creating process having died -- see
        // `releaseAllPendingLeasesForTesting()`. Without this, the
        // pending creation would be correctly-but-uninterestingly skipped
        // for the unrelated reason of its lease still being held, masking
        // what this test is actually about.
        await store.releaseAllPendingLeasesForTesting()

        let pointerURL = rootURL.appendingPathComponent("ActiveDocument.json")
        try Data("{ this is not valid JSON".utf8).write(to: pointerURL)

        let pointerState = await store.loadActiveDocumentPointer()
        XCTAssertEqual(pointerState, .corrupt)

        let report = try await store.reconcileOrphanedImports(activePointer: pointerState)
        XCTAssertTrue(report.activePointerWasUnreadable)
        XCTAssertTrue(report.rolledBackPendingIDs.isEmpty, "nothing may be rolled back while the pointer's own content can't be trusted")
        XCTAssertTrue(report.promotedPendingIDs.isEmpty, "nothing may be promoted either -- the pointer might have named exactly this document")

        // The pending document -- record, copy, and adjustments -- is
        // completely intact, from a fresh store instance.
        let freshStore = PhotoDocumentStore(rootURL: rootURL)
        let stillThere = try await freshStore.loadDocument(id: creation.document.id)
        XCTAssertEqual(stillThere.id, creation.document.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: creation.document.workingURL.path))
    }

    func testMissingAndExplicitNilActivePointerAreDistinctFromCorrupt() async throws {
        let (store, rootURL) = makeStore()
        let initial = await store.loadActiveDocumentPointer()
        XCTAssertEqual(initial, .missing)

        try await store.saveActiveDocumentID(nil)
        let afterExplicitNil = await store.loadActiveDocumentPointer()
        XCTAssertEqual(afterExplicitNil, .noActiveDocument)

        let id = UUID()
        try await store.saveActiveDocumentID(id)
        let afterActive = await store.loadActiveDocumentPointer()
        XCTAssertEqual(afterActive, .active(id))

        try Data("not json at all".utf8).write(to: rootURL.appendingPathComponent("ActiveDocument.json"))
        let afterCorruption = await store.loadActiveDocumentPointer()
        XCTAssertEqual(afterCorruption, .corrupt)
    }

    // MARK: - 12. Promotion verifies app-copy content against its digest (Codex round-4 review)

    /// Existence and shape alone (the pre-round-4 checks) would miss
    /// silent corruption in the untouched middle of a large working copy.
    /// When a digest was recorded, promotion must re-hash and require an
    /// exact match.
    func testReconciliationRefusesToPromoteAnAppCopyWhoseWorkingCopyContentDoesNotMatchItsDigest() async throws {
        let sourceURL = try makeSourceFile(byteCount: 8_192, pattern: 0x11)
        let (store, rootURL) = makeStore()
        let creation = try await store.importCopy(of: sourceURL, bookmarkData: nil)
        await store.releaseAllPendingLeasesForTesting()
        XCTAssertNotNil(creation.document.contentDigestSHA256)

        var bytes = try Data(contentsOf: creation.document.workingURL)
        let middle = bytes.count / 2
        bytes[middle] = bytes[middle] &+ 1
        try bytes.write(to: creation.document.workingURL)

        let report = try await store.reconcileOrphanedImports(activePointer: .active(creation.document.id))
        XCTAssertFalse(report.promotedPendingIDs.contains(creation.document.id))
        let message = try XCTUnwrap(report.failures[creation.document.id])
        assertMessageIsPathFree(message)

        // Left as `.pending`, retryable -- not silently dropped.
        let recordURL = rootURL.appendingPathComponent("Records").appendingPathComponent("\(creation.document.id.uuidString).json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any]
        XCTAssertEqual(json?["lifecycleState"] as? String, "pending")
    }
}
