import Foundation
import XCTest
@testable import LumaHarborApp
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Phase 5 Task 5.1 follow-up: Mac batch export queue UI / ViewModel action
/// wiring. `BatchExportQueue` itself (state machine, per-file report, cancel
/// cleanup, path-free failure messages) is already covered end to end by
/// `RawProcessingCoreTests/BatchExportQueueTests.swift`; these tests are
/// about `LibraryViewModel` actually driving it from `selectedPhotoIDs` --
/// starting a batch, observing live per-file status, cancelling, and
/// retaining the finished report until the user closes it or starts another
/// one (roadmap Phase 5 Task 5.1: "Implement Mac export queue UI").
@MainActor
final class BatchExportQueueWiringTests: AppViewModelTestCase {
    private func destinationDirectory() throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("BatchExportDestination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Starting a batch

    /// `StubRawDecoder` (the default test decoder) always fails to decode,
    /// so every item must still reach a terminal `.failed` state -- this is
    /// really a test of the *wiring* (does starting a batch actually
    /// populate `batchExportItems` from `selectedPhotoIDs` and drive them to
    /// completion), not of `BatchExportQueue`'s own success path.
    func testStartBatchExportPopulatesItemsForEverySelectedPhotoAndReachesATerminalState() async throws {
        try seedPhotos(["A.ARW", "B.ARW", "C.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let photoA = try XCTUnwrap(model.photos.first { $0.relativePath == "A.ARW" })
        let photoB = try XCTUnwrap(model.photos.first { $0.relativePath == "B.ARW" })

        model.toggleMultiSelect(photoA.id)
        model.toggleMultiSelect(photoB.id)
        XCTAssertEqual(model.selectedPhotoIDs, [photoA.id, photoB.id])

        model.startBatchExport(to: try destinationDirectory(), options: .default)

        XCTAssertEqual(model.batchExportItems.count, 2, "starting a batch must seed one item per selected photo right away")
        XCTAssertTrue(model.isBatchExporting)

        await waitUntilAppCondition("the batch export to finish") {
            await !model.isBatchExporting
        }

        XCTAssertEqual(Set(model.batchExportItems.map(\.request.baseFilename)), ["A", "B"])
        for item in model.batchExportItems {
            guard case .failed(let message) = item.status else {
                return XCTFail("expected every item to fail against the always-failing test decoder, got \(item.status)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    /// Live per-file progress: the second item must still show `.pending`
    /// while the first is `.running`, proving the UI can render mid-batch
    /// state rather than only a final snapshot.
    func testStartBatchExportShowsLivePerFileStatusBeforeCompletion() async throws {
        try seedPhotos(["A.ARW", "B.ARW"])
        let gate = AppDecodeGate()
        let services = try makeServices(decoder: SucceedingRawDecoder(gate: gate))
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        for photo in model.photos {
            model.toggleMultiSelect(photo.id)
        }

        model.startBatchExport(to: try destinationDirectory(), options: .default)

        await waitUntilAppCondition("the first item's decode to start") { gate.started > 0 }
        XCTAssertEqual(model.batchExportItems.filter { $0.status == .running }.count, 1)
        XCTAssertEqual(model.batchExportItems.filter { $0.status == .pending }.count, 1)

        gate.release()

        await waitUntilAppCondition("the batch export to finish") {
            await !model.isBatchExporting
        }
        for item in model.batchExportItems {
            guard case .succeeded = item.status else {
                return XCTFail("expected every item to succeed against the always-succeeding test decoder, got \(item.status)")
            }
        }
    }

    // MARK: - Cancelling

    func testCancelBatchExportStopsTheInFlightItemAndSkipsEveryItemAfterIt() async throws {
        try seedPhotos(["A.ARW", "B.ARW", "C.ARW"])
        let gate = AppDecodeGate()
        let services = try makeServices(decoder: SucceedingRawDecoder(gate: gate))
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        for photo in model.photos {
            model.toggleMultiSelect(photo.id)
        }

        model.startBatchExport(to: try destinationDirectory(), options: .default)

        await waitUntilAppCondition("the first item's decode to start") { gate.started > 0 }
        model.cancelBatchExport()

        await waitUntilAppCondition("the batch export to finish") {
            await !model.isBatchExporting
        }

        XCTAssertEqual(gate.started, 1, "cancelling must stop the queue before a not-yet-started item begins")
        XCTAssertEqual(model.batchExportItems.filter { $0.status == .cancelled }.count, 3)
    }

    // MARK: - Report retention

    func testStartingANewBatchExportReplacesThePreviousReportRatherThanAppendingToIt() async throws {
        try seedPhotos(["A.ARW", "B.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let photoA = try XCTUnwrap(model.photos.first { $0.relativePath == "A.ARW" })
        let photoB = try XCTUnwrap(model.photos.first { $0.relativePath == "B.ARW" })

        model.toggleMultiSelect(photoA.id)
        model.startBatchExport(to: try destinationDirectory(), options: .default)
        await waitUntilAppCondition("the first batch export to finish") { await !model.isBatchExporting }
        XCTAssertEqual(model.batchExportItems.count, 1)

        model.toggleMultiSelect(photoA.id)
        model.toggleMultiSelect(photoB.id)
        model.startBatchExport(to: try destinationDirectory(), options: .default)

        XCTAssertEqual(model.batchExportItems.count, 1, "a new batch must replace the previous report, not append to it")
        await waitUntilAppCondition("the second batch export to finish") { await !model.isBatchExporting }
    }

    /// Design spec §8.3: "failed / skipped / not run 不得偽裝成成功" -- a
    /// finished report must stay visible (with its real per-file outcomes)
    /// until the user explicitly closes it.
    func testClosingTheSheetAfterABatchFinishesClearsTheReport() async throws {
        try seedPhotos(["A.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        model.toggleMultiSelect(try XCTUnwrap(model.photos.first).id)
        model.isShowingBatchExportSheet = true

        model.startBatchExport(to: try destinationDirectory(), options: .default)
        await waitUntilAppCondition("the batch export to finish") { await !model.isBatchExporting }
        XCTAssertFalse(model.batchExportItems.isEmpty, "the finished report must still be visible before the sheet is closed")

        model.closeBatchExportSheet()

        XCTAssertFalse(model.isShowingBatchExportSheet)
        XCTAssertTrue(model.batchExportItems.isEmpty, "closing the sheet must clear a finished report")
    }

    /// Closing the sheet while a batch is still running must not blow away
    /// the in-flight progress a reopened sheet would need to keep showing.
    func testClosingTheSheetWhileStillRunningDoesNotClearTheInFlightReport() async throws {
        try seedPhotos(["A.ARW"])
        let gate = AppDecodeGate()
        let services = try makeServices(decoder: SucceedingRawDecoder(gate: gate))
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        model.toggleMultiSelect(try XCTUnwrap(model.photos.first).id)
        model.isShowingBatchExportSheet = true

        model.startBatchExport(to: try destinationDirectory(), options: .default)
        await waitUntilAppCondition("the item's decode to start") { gate.started > 0 }

        model.closeBatchExportSheet()
        XCTAssertFalse(model.isShowingBatchExportSheet)
        XCTAssertFalse(model.batchExportItems.isEmpty, "closing while still running must not discard live progress")

        gate.release()
        await waitUntilAppCondition("the batch export to finish") { await !model.isBatchExporting }
    }
}
