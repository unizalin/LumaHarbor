import CoreGraphics
import Foundation
import XCTest
@testable import RawProcessingCore

/// Roadmap Phase 5 Task 5.1: batch export queue state machine, per-file
/// report, and cancel-cleanup. Reuses `SyntheticRawDecoder`/`DecodeGate`/
/// `DecodeRequestRecorder` from `PhotoExportTests.swift` (same test target,
/// default `internal` visibility) rather than duplicating them.
final class BatchExportQueueTests: XCTestCase {
    private var directory: URL!
    private var sourceURLs: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("BatchExportQueueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sourceURLs = (0..<3).map { index in
            let url = directory.appendingPathComponent("DSC000\(index).ARW")
            try? Data(repeating: 0x22, count: 256).write(to: url)
            return url
        }
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        sourceURLs = []
        try super.tearDownWithError()
    }

    private func makeRequest(_ sourceURL: URL, baseFilename: String) -> ExportRequest {
        ExportRequest(
            sourceURL: sourceURL,
            adjustments: .neutral,
            destinationDirectory: directory,
            baseFilename: baseFilename,
            format: .png
        )
    }

    private func leftoverTemporaryFiles() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".lumaharbor-export-") || $0.hasSuffix(".tmp") }
    }

    // MARK: - State transitions

    func testEveryItemStartsPendingBeforeTheQueueRuns() async {
        let queue = BatchExportQueue(exporter: PhotoExporter(decoder: SyntheticRawDecoder()))
        let requests = zip(sourceURLs, ["a", "b", "c"]).map { makeRequest($0, baseFilename: $1) }

        var firstSnapshot: [BatchExportItem] = []
        _ = await queue.run(requests) { items in
            if firstSnapshot.isEmpty { firstSnapshot = items }
        }

        XCTAssertEqual(firstSnapshot.count, 3)
        XCTAssertTrue(firstSnapshot.allSatisfy { $0.status == .pending }, "the very first snapshot must show every item still pending")
    }

    func testASucceedingItemMovesFromPendingToRunningToSucceeded() async {
        let queue = BatchExportQueue(exporter: PhotoExporter(decoder: SyntheticRawDecoder()))
        let request = makeRequest(sourceURLs[0], baseFilename: "a")

        var observedStatuses: [BatchExportItemStatus] = []
        let report = await queue.run([request]) { items in
            observedStatuses.append(items[0].status)
        }

        XCTAssertEqual(observedStatuses.first, .pending)
        XCTAssertTrue(observedStatuses.contains(.running), "must observe a running state before completion")
        guard case .succeeded = observedStatuses.last else {
            return XCTFail("expected the final status to be .succeeded, got \(String(describing: observedStatuses.last))")
        }
        guard case .succeeded = report.files[0].status else {
            return XCTFail("expected the report's final status to be .succeeded")
        }
    }

    func testAFailingItemMovesToFailedAndDoesNotStopTheRestOfTheQueue() async {
        let failingDecoder = SyntheticRawDecoder(failure: .corruptedFile(path: "/tmp/bad.ARW"))
        let workingDecoder = SyntheticRawDecoder()

        // A decoder that fails only for the first source URL, succeeds for
        // the rest -- proves one bad file doesn't abort the whole batch.
        struct RoutingDecoder: RawDecoding {
            let identifier = DecoderIdentifier(kind: "routing", version: "test")
            let failingURL: URL
            let failing: SyntheticRawDecoder
            let working: SyntheticRawDecoder

            func supportsFile(at url: URL) -> Bool { true }
            func readMetadata(at url: URL) throws -> RawMetadata {
                url == failingURL ? try failing.readMetadata(at: url) : try working.readMetadata(at: url)
            }
            func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage {
                request.url == failingURL ? try failing.decode(request) : try working.decode(request)
            }
        }

        let decoder = RoutingDecoder(failingURL: sourceURLs[0], failing: failingDecoder, working: workingDecoder)
        let queue = BatchExportQueue(exporter: PhotoExporter(decoder: decoder))
        let requests = zip(sourceURLs, ["a", "b", "c"]).map { makeRequest($0, baseFilename: $1) }

        let report = await queue.run(requests)

        guard case .failed = report.files[0].status else {
            return XCTFail("expected item 0 to be .failed, got \(report.files[0].status)")
        }
        guard case .succeeded = report.files[1].status else {
            return XCTFail("expected item 1 to still succeed despite item 0 failing")
        }
        guard case .succeeded = report.files[2].status else {
            return XCTFail("expected item 2 to still succeed despite item 0 failing")
        }
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertEqual(report.succeededCount, 2)
    }

    func testCancellingBeforeTheQueueStartsMarksEveryItemCancelled() async {
        let queue = BatchExportQueue(exporter: PhotoExporter(decoder: SyntheticRawDecoder()))
        let requests = zip(sourceURLs, ["a", "b", "c"]).map { makeRequest($0, baseFilename: $1) }

        let task = Task { () -> BatchExportReport in
            await queue.run(requests)
        }
        task.cancel()
        let report = await task.value

        XCTAssertEqual(report.cancelledCount, 3)
        XCTAssertEqual(report.succeededCount, 0)
    }

    // MARK: - Collision policy (Phase 5 Task 5.2)

    /// A `.skip`-policy collision on one file must show up as its own
    /// distinct terminal state, never disguised as `.succeeded` (design
    /// spec §8.3: "failed / skipped / not run 不得偽裝成成功") and never
    /// counted as `.failed` either -- it isn't an error, it's the user's
    /// own chosen policy doing exactly what it says.
    func testASkippedCollisionIsItsOwnStatusDistinctFromSucceededAndFailed() async {
        let queue = BatchExportQueue(exporter: PhotoExporter(decoder: SyntheticRawDecoder()))
        var request = makeRequest(sourceURLs[0], baseFilename: "a")
        request.collisionPolicy = .skip

        // Export "a" once so the second run collides.
        _ = await queue.run([request])
        let report = await queue.run([request])

        guard case .skipped = report.files[0].status else {
            return XCTFail("expected .skipped, got \(report.files[0].status)")
        }
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.succeededCount, 0)
        XCTAssertEqual(report.failedCount, 0)
    }

    func testASkippedItemDoesNotStopTheRestOfTheBatch() async {
        let queue = BatchExportQueue(exporter: PhotoExporter(decoder: SyntheticRawDecoder()))
        var requests = zip(sourceURLs, ["a", "b", "c"]).map { makeRequest($0, baseFilename: $1) }
        requests[0].collisionPolicy = .skip
        // Pre-create "a"'s destination so item 0 collides and is skipped.
        _ = await queue.run([requests[0]])

        let report = await queue.run(requests)

        guard case .skipped = report.files[0].status else {
            return XCTFail("expected item 0 to be .skipped, got \(report.files[0].status)")
        }
        guard case .succeeded = report.files[1].status else {
            return XCTFail("expected item 1 to still succeed despite item 0 being skipped")
        }
        guard case .succeeded = report.files[2].status else {
            return XCTFail("expected item 2 to still succeed despite item 0 being skipped")
        }
    }

    // MARK: - Per-file report

    func testReportListsEveryFileWithItsOwnSourceAndFilename() async {
        let queue = BatchExportQueue(exporter: PhotoExporter(decoder: SyntheticRawDecoder()))
        let requests = zip(sourceURLs, ["a", "b", "c"]).map { makeRequest($0, baseFilename: $1) }

        let report = await queue.run(requests)

        XCTAssertEqual(report.files.map(\.baseFilename), ["a", "b", "c"])
        XCTAssertEqual(report.files.map(\.sourceURL), sourceURLs)
    }

    func testReportCountsMatchTheItemsActualOutcomes() async {
        let decoder = SyntheticRawDecoder(failure: .corruptedFile(path: "/tmp/bad.ARW"))
        let queue = BatchExportQueue(exporter: PhotoExporter(decoder: decoder))
        let requests = zip(sourceURLs, ["a", "b", "c"]).map { makeRequest($0, baseFilename: $1) }

        let report = await queue.run(requests)

        XCTAssertEqual(report.succeededCount, 0)
        XCTAssertEqual(report.failedCount, 3)
        XCTAssertEqual(report.cancelledCount, 0)
    }

    /// Regression: `RawDecodingError.fileUnavailable`'s own `errorDescription`
    /// embeds the source file's absolute path (see `RawDecodingError.swift`),
    /// and `PhotoExporter` wraps a decoder's thrown `RawDecodingError` in
    /// `ExportError.decoding(_:)` before this queue ever sees it. A per-file
    /// failure message built from that raw description would put a private
    /// filesystem path -- including whatever the user's macOS account name
    /// is -- into a report the UI shows and the user might screenshot or
    /// share, which conflicts with this project's path-free diagnostic
    /// convention (`EditorCore/SafeErrorPresentation.swift`).
    func testFailedStatusMessageNeverIncludesTheSourceFilesAbsolutePath() async {
        let leakedPath = "/Users/private-name/Pictures/DSC0001.ARW"
        let decoder = SyntheticRawDecoder(failure: .fileUnavailable(path: leakedPath))
        let queue = BatchExportQueue(exporter: PhotoExporter(decoder: decoder))
        let requests = zip(sourceURLs, ["a", "b", "c"]).map { makeRequest($0, baseFilename: $1) }

        let report = await queue.run(requests)

        for file in report.files {
            guard case .failed(let message) = file.status else {
                return XCTFail("expected every item to fail when the decoder always throws .fileUnavailable, got \(file.status)")
            }
            XCTAssertFalse(message.contains(leakedPath), "failed message must not leak the source file's absolute path: \(message)")
            XCTAssertFalse(message.contains("/Users/"), "failed message must not leak any absolute user path: \(message)")
            XCTAssertFalse(message.contains("private-name"), "failed message must not leak the username segment of a path: \(message)")
        }
    }

    // MARK: - Cancel cleanup

    func testCancellingMidQueueLeavesNoTemporaryFilesForAnyFile() async throws {
        let gate = DecodeGate()
        let decoder = SyntheticRawDecoder(gate: gate)
        let queue = BatchExportQueue(exporter: PhotoExporter(decoder: decoder))
        let requests = zip(sourceURLs, ["a", "b", "c"]).map { makeRequest($0, baseFilename: $1) }

        let task = Task { () -> BatchExportReport in
            await queue.run(requests)
        }
        await waitUntil("the first item's decode to start") { gate.started > 0 }
        task.cancel()
        let report = await task.value

        let leftovers = try leftoverTemporaryFiles()
        XCTAssertEqual(leftovers, [], "a cancelled batch must leave no temp files behind, including for the item that was mid-export")

        let finishedOutputs = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".png") }
        XCTAssertEqual(finishedOutputs, [], "a cancelled batch must publish no output file")

        // Every item resolves to a terminal state -- none left pending or
        // running once the cancelled task has returned.
        for file in report.files {
            switch file.status {
            case .pending, .running:
                XCTFail("no item should still be pending/running after the queue's Task was cancelled and awaited")
            case .succeeded, .failed, .cancelled, .skipped:
                continue
            }
        }
    }

    func testCancellingMidQueueNeverStartsAFileThatHadNotYetBegun() async throws {
        let gate = DecodeGate()
        let decoder = SyntheticRawDecoder(gate: gate)
        let queue = BatchExportQueue(exporter: PhotoExporter(decoder: decoder))
        let requests = zip(sourceURLs, ["a", "b", "c"]).map { makeRequest($0, baseFilename: $1) }

        let task = Task { () -> BatchExportReport in
            await queue.run(requests)
        }
        await waitUntil("the first item's decode to start") { gate.started > 0 }
        task.cancel()
        gate.release()
        _ = await task.value

        // Only the item that was already gated should ever have reached the
        // decoder -- a cancelled queue must not start later items at all.
        XCTAssertEqual(gate.started, 1, "cancellation must stop the queue before a not-yet-started item begins")
    }
}
