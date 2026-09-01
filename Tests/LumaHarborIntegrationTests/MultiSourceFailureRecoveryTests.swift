import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Task 8 Step 1: the failure/recovery scenarios source lifecycle and
/// scanning must survive, beyond what `ScanCancellationTests` and
/// `MultiSourceBoundedScanTests` already cover -- a scan-time drive removal,
/// an unresponsive ("hung") provider request, that a timed-out file is
/// retried by a later scan generation rather than looped on forever, that a
/// corrupt file in one source never touches a concurrently-scanning other
/// source, and that a scan whose own index writes fail partway through is
/// never mistaken for a clean, successful completion.
///
/// Reuses `InspectionGate`/`GatedScanDecoder` from `ScanCancellationTests.swift`
/// (same target) rather than redeclaring an equivalent stalling decoder.
final class MultiSourceFailureRecoveryTests: TemporaryDirectoryTestCase {
    /// Fails `readMetadata` for exactly one filename, so a single file in a
    /// multi-source scan can be made to look corrupt without affecting any
    /// other file -- in the same source or a concurrently-scanning one.
    private final class SingleFileCorruptingDecoder: RawDecoding, @unchecked Sendable {
        let identifier = DecoderIdentifier(kind: "single-corrupt", version: "test")
        let failingFilename: String

        init(failingFilename: String) {
            self.failingFilename = failingFilename
        }

        func supportsFile(at url: URL) -> Bool { true }

        func readMetadata(at url: URL) throws -> RawMetadata {
            if url.lastPathComponent == failingFilename {
                throw RawDecodingError.corruptedFile(path: url.path)
            }
            return RawMetadata(pixelWidth: 64, pixelHeight: 48)
        }

        func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage {
            let size = CGSize(width: 64, height: 48)
            let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
                .cropped(to: CGRect(origin: .zero, size: size))
            return DecodedRawImage(
                image: image,
                nativePixelSize: size,
                decodedPixelSize: size,
                baselineTemperature: 5_500,
                baselineTint: 0,
                metadata: RawMetadata(pixelWidth: 64, pixelHeight: 48)
            )
        }
    }

    /// Lets a test decide the exact moment a raced provider timeout "fires",
    /// instead of resolving instantly. Resolving instantly would race the
    /// timeout against the real inspection unconditionally -- including for
    /// a perfectly healthy, un-stalled file, whose real work might lose that
    /// race purely on scheduling luck (spawning a detached task, real file
    /// I/O) even though nothing about it is actually slow. Parking every
    /// caller until `fire()` guarantees the timeout can only ever win for a
    /// file this test has already confirmed is genuinely stuck (`gate.started`
    /// observed), while a healthy file's real inspection -- which nothing
    /// here ever blocks -- always resolves the race on its own first.
    private actor TimeoutTrigger {
        private var pending: [CheckedContinuation<Void, Never>] = []
        private var hasFired = false
        private(set) var requestedDurations: [Duration] = []

        func waitToFire(_ duration: Duration) async {
            requestedDurations.append(duration)
            if hasFired { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pending.append(continuation)
            }
        }

        func fire() {
            hasFired = true
            let continuations = pending
            pending.removeAll()
            for continuation in continuations { continuation.resume() }
        }

        /// Rearms the trigger for a later scan on the same service, so that
        /// scan's own timeout races start parked again rather than resolving
        /// immediately because a previous scan already fired.
        func reset() {
            hasFired = false
            pending.removeAll()
        }
    }

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

    private func makeService(
        decoder: any RawDecoding,
        batchSize: Int = 1,
        providerTimeoutSleep: (@Sendable (Duration) async throws -> Void)? = nil
    ) throws -> PhotoLibraryService {
        if let providerTimeoutSleep {
            return try PhotoLibraryService(
                locations: locations,
                decoder: decoder,
                scanner: FolderScanner(batchSize: batchSize),
                registryTransactionStore: nil,
                providerTimeoutSleep: providerTimeoutSleep
            )
        }
        return try PhotoLibraryService(
            locations: locations,
            decoder: decoder,
            scanner: FolderScanner(batchSize: batchSize)
        )
    }

    private func seedPhotos(_ names: [String], at root: URL) throws {
        for (index, name) in names.enumerated() {
            var data = Data(repeating: 0x30, count: 512)
            data[0] = UInt8(index)
            try writeFile(data, at: root.appendingPathComponent(name))
        }
    }

    private func addLibrary(
        _ service: PhotoLibraryService,
        at url: URL,
        displayName: String
    ) async throws -> LibraryFolder {
        do {
            return try await service.addLibrary(at: url, displayName: displayName)
        } catch let error as LibraryError {
            if case .bookmark = error {
                throw XCTSkip("This host can't create security-scoped bookmarks: \(error)")
            }
            throw error
        }
    }

    @discardableResult
    private func runScanToCompletion(
        _ service: PhotoLibraryService,
        libraryID: LibraryID
    ) async -> [LibraryScanEvent] {
        var events: [LibraryScanEvent] = []
        for await event in service.scan(libraryID: libraryID) { events.append(event) }
        return events
    }

    private func finishedResult(in events: [LibraryScanEvent]) -> LibraryScanResult? {
        for event in events {
            if case .finished(let result) = event { return result }
        }
        return nil
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @Sendable () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(description)")
    }

    // MARK: - Scan-time drive removal

    /// Addendum: `FileManager.DirectoryEnumerator` can't distinguish "the
    /// walk reached the end of the folder" from "the folder just vanished" --
    /// both simply stop yielding items. Before this task's fix, a scan
    /// interrupted by the drive disappearing mid-walk looked exactly like a
    /// clean, complete scan and would prune every row it hadn't re-seen yet,
    /// which for a large library could mean nearly all of it.
    func testScanTimeDriveRemovalReportsOfflineAndNeverPrunesExistingRows() async throws {
        try seedPhotos(["one.ARW", "two.ARW", "three.ARW"], at: libraryRoot)
        // No gate assigned yet -- the baseline scan below must run unimpeded.
        let decoder = GatedScanDecoder()

        let service = try makeService(decoder: decoder)
        let library = try await addLibrary(service, at: libraryRoot, displayName: "Drive Removal")

        // A clean first scan establishes a baseline every row of which must
        // survive the interrupted rescan below.
        let firstEvents = await runScanToCompletion(service, libraryID: library.id)
        let firstResult = try XCTUnwrap(finishedResult(in: firstEvents))
        XCTAssertFalse(firstResult.wasCancelled)
        let baseline = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(baseline.count, 3)
        let firstScanAtLibrary = await service.library(id: library.id)
        let firstScanAt = try XCTUnwrap(firstScanAtLibrary?.lastScanAt)

        // Stall the rescan partway through, then make the whole source
        // vanish -- exactly what unplugging the drive looks like from here.
        let gate = InspectionGate()
        decoder.gate = gate
        decoder.gateAfterFileCount = decoder.metadataReads
        let runTask = Task { await self.runScanToCompletion(service, libraryID: library.id) }
        await waitUntil("the rescan to stall inside inspection") { gate.started > 0 }
        try FileManager.default.removeItem(at: libraryRoot)
        gate.release()
        let events = await runTask.value

        XCTAssertTrue(
            events.contains { if case .failed(.offline) = $0 { return true }; return false },
            "A scan interrupted by the source vanishing must report offline"
        )
        XCTAssertNil(finishedResult(in: events), "An interrupted scan must not report a clean .finished result")

        let survivors = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(
            Set(survivors.map(\.id)), Set(baseline.map(\.id)),
            "A scan interrupted by drive removal pruned rows it never should have touched"
        )

        let afterScanAt = await service.library(id: library.id)?.lastScanAt
        XCTAssertEqual(
            afterScanAt, firstScanAt,
            "An interrupted scan must not overwrite the last genuinely successful scan's timestamp"
        )
    }

    // MARK: - Provider request timeout, then a retry via a fresh generation

    /// The 30-second timeout is fixed, but the wait itself is injected via
    /// `TimeoutTrigger`: this test only fires it once it has independently
    /// confirmed (`gate.started`) that the second file's inspection is
    /// genuinely stuck, so the timeout path is proven without an actual
    /// 30-second wait -- and without any risk of it firing "early" against a
    /// perfectly healthy file. The stalled provider read (`GatedScanDecoder`
    /// + `InspectionGate`) keeps running in the background, orphaned, after
    /// the timeout wins.
    func testProviderRequestTimeoutFailsThatFileThenARetryOnANewGenerationRecoversIt() async throws {
        try seedPhotos(["one.ARW", "two.ARW"], at: libraryRoot)
        let gate = InspectionGate()
        let decoder = GatedScanDecoder()
        decoder.gate = gate
        decoder.gateAfterFileCount = 1 // the second file's decode stalls

        let trigger = TimeoutTrigger()
        let service = try makeService(decoder: decoder) { duration in
            await trigger.waitToFire(duration)
        }
        let library = try await addLibrary(service, at: libraryRoot, displayName: "Provider Timeout")

        let runTask = Task { await self.runScanToCompletion(service, libraryID: library.id) }
        await waitUntil("the second file to stall inside inspection") { gate.started > 0 }
        await trigger.fire()
        let firstEvents = await runTask.value

        let firstResult = try XCTUnwrap(finishedResult(in: firstEvents))
        XCTAssertFalse(firstResult.wasCancelled, "A timed-out file must not abort the rest of the scan")
        XCTAssertEqual(firstResult.indexedCount, 1, "The un-stalled file must still index normally")
        XCTAssertEqual(firstResult.failedCount, 1, "The stalled file must be reported as a per-file failure")

        // Every file's inspection races the fixed 30-second provider timeout
        // -- one request per file, whether or not it actually wins.
        let recordedDurations = await trigger.requestedDurations
        XCTAssertEqual(recordedDurations.count, 2)
        XCTAssertTrue(recordedDurations.allSatisfy { $0 == PhotoLibraryService.providerRequestTimeout })

        let afterFirstScan = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(afterFirstScan.count, 1, "The timed-out file must not be indexed by this scan")

        // Retry via a fresh scan generation -- never an automatic retry loop
        // inside the same scan.
        gate.release()
        // Give the orphaned, discarded inspection (the real work that lost
        // the race, blocked on `gate` this whole time) a moment to actually
        // unwind before the retry scan starts and before teardown removes
        // the temporary directory out from under it -- the same settling
        // idiom `ScanCancellationTests` uses after releasing a gate.
        try? await Task.sleep(for: .milliseconds(200))
        decoder.gate = nil
        await trigger.reset()
        let secondEvents = await runScanToCompletion(service, libraryID: library.id)
        let secondResult = try XCTUnwrap(finishedResult(in: secondEvents))
        XCTAssertFalse(secondResult.wasCancelled)
        XCTAssertEqual(
            secondResult.indexedCount, 2,
            "A fresh scan generation must pick the previously timed-out file back up"
        )
        XCTAssertEqual(secondResult.failedCount, 0)

        let afterSecondScan = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(afterSecondScan.count, 2)
    }

    // MARK: - Corrupt RAW continuation across a concurrent multi-source scan

    /// The single-source "a corrupt file doesn't stop the scan" pattern is
    /// already established (`PhotoStatus.failed`'s own doc comment). This
    /// proves it holds when that corrupt file's source is scanning
    /// concurrently with a second, completely healthy one: the corrupt file
    /// is indexed with `.failed` status (not skipped, not retried in-line),
    /// its own source finishes normally, and the other source is entirely
    /// unaffected.
    func testCorruptRawInOneSourceDoesNotAffectAConcurrentlyScanningSource() async throws {
        let rootA = try makeSubdirectory("CorruptRootA")
        let rootB = try makeSubdirectory("CorruptRootB")
        try seedPhotos(["a-one.ARW", "a-two.ARW"], at: rootA)
        try seedPhotos(["b-one.ARW", "b-two.ARW"], at: rootB)

        let decoder = SingleFileCorruptingDecoder(failingFilename: "a-two.ARW")
        let service = try makeService(decoder: decoder)
        let libraryA = try await addLibrary(service, at: rootA, displayName: "Corrupt A")
        let libraryB = try await addLibrary(service, at: rootB, displayName: "Healthy B")

        actor Collector {
            private var finished: [LibraryID: LibraryScanResult] = [:]
            func record(libraryID: LibraryID, event: LibraryScanEvent) {
                if case .finished(let result) = event { finished[libraryID] = result }
            }
            var results: [LibraryID: LibraryScanResult] { finished }
        }
        let collector = Collector()

        await service.scanLibraries([libraryA.id, libraryB.id], selectedLibraryID: nil) { libraryID, event in
            await collector.record(libraryID: libraryID, event: event)
        }

        let results = await collector.results
        let resultA = try XCTUnwrap(results[libraryA.id])
        let resultB = try XCTUnwrap(results[libraryB.id])
        XCTAssertFalse(resultA.wasCancelled)
        XCTAssertFalse(resultB.wasCancelled)
        XCTAssertEqual(resultA.indexedCount, 2, "A corrupt file is still indexed -- marked failed, never skipped")
        XCTAssertEqual(resultB.indexedCount, 2)

        let photosA = try await service.photos(inLibrary: libraryA.id)
        let corrupt = try XCTUnwrap(photosA.first { $0.relativePath == "a-two.ARW" })
        XCTAssertEqual(corrupt.status, .failed)
        let healthyInA = try XCTUnwrap(photosA.first { $0.relativePath == "a-one.ARW" })
        XCTAssertEqual(healthyInA.status, .ready)

        let photosB = try await service.photos(inLibrary: libraryB.id)
        XCTAssertTrue(
            photosB.allSatisfy { $0.status == .ready },
            "Source B must be entirely unaffected by source A's corrupt file"
        )
    }

    // MARK: - No prune after a partial (mid-scan index write) failure

    /// Distinct from a per-file inspection failure -- which an otherwise
    /// complete scan is *supposed* to prune around, and which
    /// `MultiSourceBoundedScanTests` already proves. This is the local index
    /// itself failing partway through a scan: before this task's fix, that
    /// left `cancelled` false, so the scan still reported a clean success and
    /// still ran its destructive prune, even though large parts of what it
    /// "saw" were never actually persisted.
    func testIndexWriteFailureDuringAScanIsNeverReportedAsACleanCompletion() async throws {
        try seedPhotos(["one.ARW", "two.ARW"], at: libraryRoot)
        let service = try makeService(decoder: GatedScanDecoder())
        let library = try await addLibrary(service, at: libraryRoot, displayName: "Index Failure")
        XCTAssertNil(library.lastScanAt)

        let indexStore = await service.indexStore
        indexStore.close() // simulate the local index becoming unavailable mid-scan

        let events = await runScanToCompletion(service, libraryID: library.id)
        let result = try XCTUnwrap(finishedResult(in: events))
        XCTAssertTrue(
            result.wasCancelled,
            "A scan whose index writes failed must not be reported as a clean, successful completion"
        )

        let after = await service.library(id: library.id)
        XCTAssertNil(after?.lastScanAt, "A scan whose index writes failed must not record lastScanAt")

        let manifest = try FileSidecarRepository(libraryRootURL: libraryRoot).loadManifest()
        XCTAssertNil(
            manifest?.lastSuccessfulScanAt,
            "A scan whose index writes failed must not stamp the portable success timestamp"
        )
    }
}
