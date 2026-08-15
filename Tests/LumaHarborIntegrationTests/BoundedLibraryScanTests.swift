import Foundation
import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Bounded-pipeline spec §6.3: the backpressure the UI applies has to reach all
/// the way back through the service to the directory cursor, and a normal scan
/// must still index everything exactly once.
final class BoundedLibraryScanTests: TemporaryDirectoryTestCase {
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

    /// Batch size 1 so every file is its own batch and the test can count
    /// inspections against batches delivered.
    private func makeService(
        decoder: any RawDecoding,
        batchSize: Int = 1
    ) throws -> PhotoLibraryService {
        try PhotoLibraryService(
            locations: locations,
            decoder: decoder,
            scanner: FolderScanner(batchSize: batchSize)
        )
    }

    private func waitForCondition(
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

    private func seedPhotos(_ count: Int) throws {
        for index in 0..<count {
            var data = Data(repeating: 0x30, count: 512)
            data[0] = UInt8(index % 251)
            data[1] = UInt8(index / 251)
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

    // MARK: - Backpressure reaches the cursor

    func testAStalledUIConsumerStopsServiceInspection() async throws {
        try seedPhotos(8)
        let decoder = GatedScanDecoder()
        let service = try makeService(decoder: decoder)
        let library = try await addLibrary(service)

        // Held by hand: a `for await` loop that we `break` out of would release
        // the iterator and cancel the scan, which is a different scenario.
        let iterator = service.scan(libraryID: library.id).makeAsyncIterator()

        var firstBatch: [PhotoAsset] = []
        while let event = await iterator.next() {
            if case .photosIndexed(let batch) = event {
                firstBatch = batch
                break
            }
        }
        XCTAssertEqual(firstBatch.count, 1)

        // Stall, as a UI thread busy laying out the grid would.
        try await Task.sleep(for: .milliseconds(250))

        // One batch is in our hands and at most one more may be parked in the
        // channel. Anything beyond that means the service ran ahead, which in
        // turn would mean the folder walk did too.
        XCTAssertLessThanOrEqual(
            decoder.metadataReads, 2,
            "The service inspected \(decoder.metadataReads) files while the UI was stalled"
        )

        withExtendedLifetime(iterator) {}
    }

    func testBreakingOutOfTheScanStopsFurtherInspection() async throws {
        try seedPhotos(8)
        let decoder = GatedScanDecoder()
        let service = try makeService(decoder: decoder)
        let library = try await addLibrary(service)

        var batches = 0
        for await event in service.scan(libraryID: library.id) {
            if case .photosIndexed = event {
                batches += 1
                if batches == 2 { break }
            }
        }

        let readsAtBreak = decoder.metadataReads
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(
            decoder.metadataReads, readsAtBreak,
            "Inspection continued after the consumer left"
        )
        XCTAssertLessThan(decoder.metadataReads, 8)
    }

    // MARK: - A consumer that leaves before the first event

    func testAConsumerThatNeverTakesStartedDoesNoWorkAndRecordsNoSuccess() async throws {
        // Codex review finding 3. `.started` is the very first send, so if the
        // consumer is gone by then nothing downstream should happen: no
        // manifest read, no directory walk, and above all no success
        // timestamps.
        try seedPhotos(6)
        let decoder = GatedScanDecoder()
        let service = try makeService(decoder: decoder)
        let library = try await addLibrary(service)

        // Scoped so the iterator — and with it the scan — is released
        // immediately, before anything can consume `.started`.
        func startAndAbandon() {
            _ = service.scan(libraryID: library.id).makeAsyncIterator()
        }
        startAndAbandon()

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(
            decoder.metadataReads, 0,
            "The service inspected files for a consumer that never arrived"
        )

        let folder = await service.library(id: library.id)
        XCTAssertNil(
            folder?.lastScanAt,
            "An abandoned scan was recorded as a completed one"
        )

        let manifest = try FileSidecarRepository(libraryRootURL: libraryRoot).loadManifest()
        XCTAssertNil(
            manifest?.lastSuccessfulScanAt,
            "An abandoned scan wrote a successful timestamp"
        )
    }

    func testACancelledScanLeavesNoSuccessTimestampEvenWhenTheWalkFinishes() async throws {
        // The loop can end without ever setting `cancelled`: a small folder
        // finishes walking while the consumer has already gone. The gate before
        // the success writes is the only thing standing between that and a
        // scan that looks complete.
        try seedPhotos(2)
        let decoder = GatedScanDecoder()
        let service = try makeService(decoder: decoder)
        let library = try await addLibrary(service)

        let consumer = Task {
            for await event in service.scan(libraryID: library.id) {
                if case .started = event { break }
            }
        }
        await consumer.value
        try await Task.sleep(for: .milliseconds(300))

        let folder = await service.library(id: library.id)
        XCTAssertNil(folder?.lastScanAt, "A scan nobody consumed was marked successful")

        let manifest = try FileSidecarRepository(libraryRootURL: libraryRoot).loadManifest()
        XCTAssertNil(manifest?.lastSuccessfulScanAt)
    }

    // MARK: - A half-inspected batch never reaches the index

    func testAPartiallyInspectedBatchIsNeverCommitted() async throws {
        // Codex review finding B. Two files share one batch: the first is
        // inspected fine, the second stalls in a decoder that ignores
        // cancellation. Committing the half of the batch that happened to
        // finish would put photos in the index that the scan never actually
        // completed — and the guard before the upsert is the only thing
        // stopping it.
        try seedPhotos(2)
        let gate = InspectionGate()
        let decoder = GatedScanDecoder()
        decoder.gate = gate
        decoder.gateAfterFileCount = 1
        decoder.gateIgnoresCancellation = true

        let service = try makeService(decoder: decoder, batchSize: 2)
        let library = try await addLibrary(service)

        let consumer = Task {
            for await _ in service.scan(libraryID: library.id) {}
        }

        await waitForCondition("the second file to stall") { gate.started > 0 }
        consumer.cancel()
        gate.release()
        await consumer.value
        try await Task.sleep(for: .milliseconds(300))

        let rows = try await service.photos(inLibrary: library.id)
        XCTAssertTrue(
            rows.isEmpty,
            "A half-inspected batch was committed: \(rows.map(\.relativePath))"
        )

        // And it is still not treated as a completed scan.
        let folder = await service.library(id: library.id)
        XCTAssertNil(folder?.lastScanAt)
        let manifest = try FileSidecarRepository(libraryRootURL: libraryRoot).loadManifest()
        XCTAssertNil(manifest?.lastSuccessfulScanAt)
    }

    func testABatchFullyInspectedBeforeCancellationIsStillDropped() async throws {
        // The other position for the same race: every file in the batch was
        // inspected, and the cancel lands in the gap before the commit. The
        // pre-commit checkpoint has to catch that too.
        try seedPhotos(2)
        let gate = InspectionGate()
        let decoder = GatedScanDecoder()
        decoder.gate = gate
        // One read completes normally; the second (last) file enters the gate,
        // so the batch is fully inspected by the time we cancel.
        decoder.gateAfterFileCount = 1
        decoder.gateIgnoresCancellation = true

        let service = try makeService(decoder: decoder, batchSize: 2)
        let library = try await addLibrary(service)

        let consumer = Task {
            for await _ in service.scan(libraryID: library.id) {}
        }

        await waitForCondition("the second (last) file to enter the gate") { gate.started > 0 }
        consumer.cancel()
        gate.release()
        await consumer.value
        try await Task.sleep(for: .milliseconds(300))

        let rows = try await service.photos(inLibrary: library.id)
        XCTAssertTrue(
            rows.isEmpty,
            "A batch was committed after the consumer had gone: \(rows.map(\.relativePath))"
        )
    }

    func testBatchesCommittedBeforeCancellationSurvive() async throws {
        // The complement, so the guard above can't be satisfied by simply never
        // committing anything: whole batches that landed before the cancel are
        // still in the index afterwards.
        try seedPhotos(6)
        let gate = InspectionGate()
        let decoder = GatedScanDecoder()
        decoder.gate = gate
        decoder.gateAfterFileCount = 3
        decoder.gateIgnoresCancellation = true

        let service = try makeService(decoder: decoder, batchSize: 1)
        let library = try await addLibrary(service)

        let consumer = Task {
            for await _ in service.scan(libraryID: library.id) {}
        }

        await waitForCondition("the fourth file to stall") { gate.started > 0 }
        consumer.cancel()
        gate.release()
        await consumer.value
        try await Task.sleep(for: .milliseconds(300))

        let rows = try await service.photos(inLibrary: library.id)
        XCTAssertGreaterThan(
            rows.count, 0,
            "Batches committed before the cancel were rolled back"
        )
        XCTAssertLessThan(rows.count, 6, "The scan carried on past the cancel")

        // Still not a success, though.
        let folder = await service.library(id: library.id)
        XCTAssertNil(folder?.lastScanAt)
    }

    // MARK: - A complete scan is unchanged

    func testAFullScanStillIndexesEveryFileExactlyOnce() async throws {
        let total = 25
        try seedPhotos(total)
        let decoder = GatedScanDecoder()
        let service = try makeService(decoder: decoder)
        let library = try await addLibrary(service)

        var indexedPaths: [String] = []
        var result: LibraryScanResult?
        for await event in service.scan(libraryID: library.id) {
            switch event {
            case .photosIndexed(let batch):
                indexedPaths.append(contentsOf: batch.map(\.relativePath))
            case .finished(let finished):
                result = finished
            default:
                break
            }
        }

        // No drops, no duplicates.
        XCTAssertEqual(indexedPaths.count, total)
        XCTAssertEqual(Set(indexedPaths).count, total, "A file was indexed twice")

        let rows = try await service.photos(inLibrary: library.id)
        XCTAssertEqual(rows.count, total)

        let manifest = try FileSidecarRepository(libraryRootURL: libraryRoot).loadManifest()
        XCTAssertEqual(manifest?.photos.count, total)
        XCTAssertNotNil(
            manifest?.lastSuccessfulScanAt,
            "A completed scan didn't record its success timestamp"
        )

        let summary = try XCTUnwrap(result)
        XCTAssertEqual(summary.indexedCount, total)
        XCTAssertFalse(summary.wasCancelled)

        let folder = await service.library(id: library.id)
        XCTAssertNotNil(folder?.lastScanAt)
    }

    func testRescanningKeepsIdentitiesAndDoesNotDuplicateRows() async throws {
        try seedPhotos(12)
        let decoder = GatedScanDecoder()
        let service = try makeService(decoder: decoder)
        let library = try await addLibrary(service)

        for await _ in service.scan(libraryID: library.id) {}
        let firstPass = try await service.photos(inLibrary: library.id)

        for await _ in service.scan(libraryID: library.id) {}
        let secondPass = try await service.photos(inLibrary: library.id)

        XCTAssertEqual(secondPass.count, 12)
        XCTAssertEqual(
            Set(firstPass.map(\.id)),
            Set(secondPass.map(\.id)),
            "A rescan through the bounded pipeline minted new identities"
        )
    }
}
