import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Holds one inspection stage open so cancellation can be aimed precisely.
final class InspectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isReleased = false
    private var startedCount = 0

    var started: Int {
        lock.lock()
        defer { lock.unlock() }
        return startedCount
    }

    func release() {
        lock.lock()
        isReleased = true
        lock.unlock()
    }

    private var released: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isReleased
    }

    /// `ignoringCancellation` is the decoder that never polls — it finishes the
    /// file it started and hands back a good answer for a scan nobody wants.
    func enterAndWait(timeout: TimeInterval = 5, ignoringCancellation: Bool = false) {
        lock.lock()
        startedCount += 1
        lock.unlock()

        let deadline = Date().addingTimeInterval(timeout)
        while !released, ignoringCancellation || !Task.isCancelled, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}

/// A decoder whose metadata read the test can stall. Metadata is the slow stage
/// of `PhotoLibraryService.inspect`, so it's where a real scan gets cancelled.
final class GatedScanDecoder: RawDecoding, @unchecked Sendable {
    let identifier = DecoderIdentifier(kind: "gated", version: "test")

    private let lock = NSLock()
    private var metadataCount = 0

    /// Opens after this many files have been inspected, so a test can let the
    /// first batch land and stall the next one.
    var gateAfterFileCount = 0
    var gate: InspectionGate?
    var gateIgnoresCancellation = false

    var metadataReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return metadataCount
    }

    func supportsFile(at url: URL) -> Bool { true }

    func readMetadata(at url: URL) throws -> RawMetadata {
        lock.lock()
        metadataCount += 1
        let index = metadataCount
        lock.unlock()

        if index > gateAfterFileCount {
            gate?.enterAndWait(ignoringCancellation: gateIgnoresCancellation)
        }
        // A cooperative decoder polls and throws; a non-cooperative one (as
        // modelled by `gateIgnoresCancellation`) hands back a perfectly good
        // result for a scan nobody is waiting for any more, so the service's
        // own pre-commit checkpoint — not this helper — is what has to catch it.
        if !gateIgnoresCancellation {
            try Task.checkCancellation()
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

/// Addendum §3.5 and §4.3: what a cancelled scan must and must not leave behind.
final class ScanCancellationTests: TemporaryDirectoryTestCase {
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

    private func makeService(decoder: any RawDecoding) throws -> PhotoLibraryService {
        // Batch size 1 so each file is committed on its own and the test can
        // reason about exactly which ones landed.
        try PhotoLibraryService(
            locations: locations,
            decoder: decoder,
            scanner: FolderScanner(batchSize: 1)
        )
    }

    private func seedPhotos(_ count: Int) throws {
        for index in 0..<count {
            var data = Data(repeating: 0x30, count: 512)
            data[0] = UInt8(index)
            try writeFile(
                data,
                at: libraryRoot.appendingPathComponent(String(format: "DSC%04d.ARW", index))
            )
        }
    }

    private func addLibrary(_ service: PhotoLibraryService) async throws -> LibraryFolder {
        do {
            return try await service.addLibrary(at: libraryRoot, displayName: "Test Drive")
        } catch let error as LibraryError {
            if case .bookmark = error {
                throw XCTSkip("This host can't create security-scoped bookmarks: \(error)")
            }
            throw error
        }
    }

    /// Consumes a scan until `stopWhen` holds, then cancels the consumer — which
    /// is what a user switching folders actually does.
    @discardableResult
    private func runScanCancelling(
        _ service: PhotoLibraryService,
        libraryID: LibraryID,
        stopWhen: @escaping @Sendable () -> Bool
    ) async -> [LibraryScanEvent] {
        let consumer = Task { () -> [LibraryScanEvent] in
            var collected: [LibraryScanEvent] = []
            for await event in service.scan(libraryID: libraryID) {
                collected.append(event)
            }
            return collected
        }

        await waitUntilStopCondition(stopWhen)
        consumer.cancel()
        return await consumer.value
    }

    private func waitUntilStopCondition(
        _ condition: @Sendable () -> Bool,
        timeout: TimeInterval = 5
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for the scan to reach the cancellation point")
    }

    @discardableResult
    private func runScanToCompletion(
        _ service: PhotoLibraryService,
        libraryID: LibraryID
    ) async -> LibraryScanResult? {
        var result: LibraryScanResult?
        for await event in service.scan(libraryID: libraryID) {
            if case .finished(let finished) = event { result = finished }
        }
        return result
    }

    // MARK: - Cooperative cancellation

    func testCancellingDuringMetadataReadStopsTheScan() async throws {
        try seedPhotos(6)
        let gate = InspectionGate()
        let decoder = GatedScanDecoder()
        decoder.gate = gate
        decoder.gateAfterFileCount = 1

        let service = try makeService(decoder: decoder)
        let library = try await addLibrary(service)

        let events = await runScanCancelling(service, libraryID: library.id) {
            gate.started > 0
        }
        gate.release()

        // Whatever the scan managed before the stall may stay; the rest must
        // never have been inspected.
        XCTAssertLessThan(
            decoder.metadataReads, 6,
            "The scan kept inspecting files after the consumer went away"
        )

        let indexed = try await service.photos(inLibrary: library.id)
        XCTAssertLessThan(indexed.count, 6)

        // Addendum §3.5: cancellation is not a damaged photo.
        for photo in indexed {
            XCTAssertNotEqual(photo.status, .failed, "\(photo.relativePath) was marked failed")
        }
        XCTAssertFalse(
            events.contains { if case .photoFailed = $0 { return true } else { return false } },
            "Cancellation surfaced as a per-photo failure"
        )
    }

    func testCancelledFirstScanLeavesLastScanAtNil() async throws {
        // The UI uses `lastScanAt == nil` to decide a folder still needs its
        // first scan; stamping it after a cancel skips that scan forever.
        try seedPhotos(4)
        let gate = InspectionGate()
        let decoder = GatedScanDecoder()
        decoder.gate = gate

        let service = try makeService(decoder: decoder)
        let library = try await addLibrary(service)
        XCTAssertNil(library.lastScanAt)

        _ = await runScanCancelling(service, libraryID: library.id) { gate.started > 0 }
        gate.release()

        let after = await service.library(id: library.id)
        XCTAssertNil(after?.lastScanAt, "A cancelled first scan was recorded as complete")

        let manifest = try FileSidecarRepository(libraryRootURL: libraryRoot).loadManifest()
        XCTAssertNil(
            manifest?.lastSuccessfulScanAt,
            "A cancelled scan updated the portable success timestamp"
        )
    }

    func testCancelledRescanKeepsThePreviousSuccessfulTimestamp() async throws {
        try seedPhotos(3)
        let decoder = GatedScanDecoder()
        let service = try makeService(decoder: decoder)
        let library = try await addLibrary(service)

        let firstResult = await runScanToCompletion(service, libraryID: library.id)
        XCTAssertEqual(firstResult?.wasCancelled, false)
        let afterSuccess = await service.library(id: library.id)
        let successTimestamp = try XCTUnwrap(afterSuccess?.lastScanAt)

        let manifestAfterSuccess = try FileSidecarRepository(libraryRootURL: libraryRoot)
            .loadManifest()
        let manifestSuccessTimestamp = try XCTUnwrap(manifestAfterSuccess?.lastSuccessfulScanAt)

        // Now cancel a rescan partway through.
        let gate = InspectionGate()
        decoder.gate = gate
        decoder.gateAfterFileCount = decoder.metadataReads
        _ = await runScanCancelling(service, libraryID: library.id) { gate.started > 0 }
        gate.release()

        let afterCancel = await service.library(id: library.id)
        XCTAssertEqual(afterCancel?.lastScanAt, successTimestamp)

        let manifestAfterCancel = try FileSidecarRepository(libraryRootURL: libraryRoot)
            .loadManifest()
        XCTAssertEqual(manifestAfterCancel?.lastSuccessfulScanAt, manifestSuccessTimestamp)
    }

    func testCancelledScanDoesNotPruneExistingRows() async throws {
        // Pruning is keyed on "not seen by this scan", so running it after a
        // cancel would delete every photo the scan never reached.
        try seedPhotos(4)
        let decoder = GatedScanDecoder()
        let service = try makeService(decoder: decoder)
        let library = try await addLibrary(service)

        _ = await runScanToCompletion(service, libraryID: library.id)
        let complete = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(complete.count, 4)

        let gate = InspectionGate()
        decoder.gate = gate
        decoder.gateAfterFileCount = decoder.metadataReads
        _ = await runScanCancelling(service, libraryID: library.id) { gate.started > 0 }
        gate.release()

        let survivors = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(survivors.count, 4, "A cancelled rescan pruned rows it never reached")
        XCTAssertEqual(
            Set(survivors.map(\.id)),
            Set(complete.map(\.id)),
            "Photo identities changed across a cancelled rescan"
        )
    }

    // MARK: - Non-cooperative inspection

    func testNonCooperativeInspectionDiscardsItsResultAndStopsThere() async throws {
        // Addendum §3.5: a decoder that ignores cancellation may finish the file
        // it already started, but that result must be dropped and the next file
        // must never begin.
        try seedPhotos(6)
        let gate = InspectionGate()
        let decoder = GatedScanDecoder()
        decoder.gate = gate
        decoder.gateIgnoresCancellation = true
        decoder.gateAfterFileCount = 1

        let service = try makeService(decoder: decoder)
        let library = try await addLibrary(service)

        _ = await runScanCancelling(service, libraryID: library.id) { gate.started > 0 }

        let readsAtCancel = decoder.metadataReads
        gate.release()
        // Give the released inspection time to come back and be rejected.
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            decoder.metadataReads, readsAtCancel,
            "The scan started another file after cancellation"
        )

        let indexed = try await service.photos(inLibrary: library.id)
        XCTAssertLessThanOrEqual(
            indexed.count, 1,
            "The result of the cancelled inspection was indexed anyway"
        )
        let after = await service.library(id: library.id)
        XCTAssertNil(after?.lastScanAt)
    }

    // MARK: - Restart isolation

    /// The overlap the UI actually produces: cancel, immediately rescan, and the
    /// abandoned run only surfaces once the newer one has already finished.
    ///
    /// Deliberately never releases the first gate until after the second scan
    /// has completed and been checked — releasing first would let the runs be
    /// sequential, which is exactly the case that hides the bug.
    func testStaleScanCompletingAfterASecondScanWritesNothing() async throws {
        try seedPhotos(4)
        let gate = InspectionGate()
        let decoder = GatedScanDecoder()
        decoder.gate = gate
        // Ignores cancellation: the first scan stays parked inside a metadata
        // read holding a manifest snapshot from before the second scan existed.
        decoder.gateIgnoresCancellation = true
        decoder.gateAfterFileCount = 1

        let service = try makeService(decoder: decoder)
        let library = try await addLibrary(service)
        let repository = FileSidecarRepository(libraryRootURL: libraryRoot)

        let firstConsumer = Task { () -> Void in
            for await _ in service.scan(libraryID: library.id) {}
        }
        await waitUntilStopCondition { gate.started > 0 }
        firstConsumer.cancel()

        // Second scan runs to completion while the first is *still stuck*.
        decoder.gate = nil
        let second = await runScanToCompletion(service, libraryID: library.id)
        let secondResult = try XCTUnwrap(second)
        XCTAssertFalse(secondResult.wasCancelled)
        XCTAssertEqual(secondResult.indexedCount, 4)

        let afterSecond = await service.library(id: library.id)
        let successTimestamp = try XCTUnwrap(
            afterSecond?.lastScanAt, "The second scan was not recorded as successful"
        )
        let manifestAfterSecond = try repository.loadManifest()
        let manifestSuccess = try XCTUnwrap(manifestAfterSecond?.lastSuccessfulScanAt)
        let rowsAfterSecond = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(rowsAfterSecond.count, 4)

        // Only now does the abandoned inspection come back.
        gate.release()
        await firstConsumer.value
        try? await Task.sleep(for: .milliseconds(300))

        let afterStale = await service.library(id: library.id)
        XCTAssertEqual(
            afterStale?.lastScanAt, successTimestamp,
            "The stale scan overwrote the newer scan's successful timestamp"
        )

        let manifestAfterStale = try repository.loadManifest()
        XCTAssertEqual(
            manifestAfterStale?.lastSuccessfulScanAt, manifestSuccess,
            "The stale scan wrote its old manifest snapshot back over the new one"
        )

        let rowsAfterStale = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(rowsAfterStale.count, rowsAfterSecond.count)
        XCTAssertEqual(
            Set(rowsAfterStale.map(\.id)),
            Set(rowsAfterSecond.map(\.id)),
            "The stale scan rewrote index rows the newer scan owned"
        )
    }
}
