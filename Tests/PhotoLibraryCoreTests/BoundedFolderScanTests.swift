import Foundation
import XCTest
@testable import PhotoLibraryCore

/// Holds one `nextPage()` open so a test can decide exactly when the walk
/// advances.
final class ScanCursorGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var entered = 0

    var enteredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    func open() {
        lock.lock()
        isOpen = true
        lock.unlock()
    }

    private var opened: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpen
    }

    /// `ignoringCancellation` models blocking I/O that finishes what it started
    /// no matter what the caller wants.
    func enterAndWait(timeout: TimeInterval = 5, ignoringCancellation: Bool = false) {
        lock.lock()
        entered += 1
        lock.unlock()

        let deadline = Date().addingTimeInterval(timeout)
        while !opened, ignoringCancellation || !Task.isCancelled, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
}

/// A scripted walk that counts exactly how far it has been driven.
///
/// The point of the whole bounded-pipeline change is "the producer does not run
/// ahead of the consumer", and the only honest way to check that is to count
/// advances rather than guess from memory use.
final class InstrumentedScanCursor: FolderScanCursor, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [FolderScanPage]
    private var callCount = 0
    private var closeCallCount = 0

    /// Opens on the Nth advance (1-based). `nil` never gates.
    let gateOnCall: Int?
    let gate: ScanCursorGate?
    let gateIgnoresCancellation: Bool

    init(
        pages: [FolderScanPage],
        gate: ScanCursorGate? = nil,
        gateOnCall: Int? = nil,
        gateIgnoresCancellation: Bool = false
    ) {
        self.pages = pages
        self.gate = gate
        self.gateOnCall = gateOnCall
        self.gateIgnoresCancellation = gateIgnoresCancellation
    }

    var nextPageCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closeCallCount
    }

    func nextPage() -> FolderScanPage {
        lock.lock()
        callCount += 1
        let call = callCount
        let page = pages.isEmpty ? FolderScanPage(isAtEnd: true) : pages.removeFirst()
        lock.unlock()

        if let gate, gateOnCall == call {
            gate.enterAndWait(ignoringCancellation: gateIgnoresCancellation)
        }
        return page
    }

    func close() {
        lock.lock()
        closeCallCount += 1
        lock.unlock()
    }
}

/// A counter the forced-failure loader can bump from whatever thread the
/// enumerator happens to be on.
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

struct InstrumentedScanCursorFactory: FolderScanCursorFactory {
    let cursor: InstrumentedScanCursor

    func makeCursor(
        root: URL,
        supportedExtensions: Set<String>,
        batchSize: Int
    ) -> any FolderScanCursor {
        cursor
    }
}

/// Bounded-pipeline spec §6.2.
final class BoundedFolderScanTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)

    private func file(_ name: String) -> ScannedFile {
        ScannedFile(url: root.appendingPathComponent(name), relativePath: name, fileSize: 128)
    }

    private func page(_ names: [String], failures: [String] = [], isAtEnd: Bool = false) -> FolderScanPage {
        FolderScanPage(
            files: names.map(file),
            failures: failures.map { FolderScanFailure(relativePath: $0, reason: "unreadable") },
            isAtEnd: isAtEnd
        )
    }

    private func makeScanner(cursor: InstrumentedScanCursor, batchSize: Int = 2) -> FolderScanner {
        FolderScanner(
            supportedExtensions: ["arw"],
            batchSize: batchSize,
            cursorFactory: InstrumentedScanCursorFactory(cursor: cursor)
        )
    }

    // MARK: - Backpressure

    func testASlowConsumerStopsTheWalkAfterOnePendingBatch() async throws {
        let cursor = InstrumentedScanCursor(pages: [
            page(["a.ARW", "b.ARW"]),
            page(["c.ARW", "d.ARW"]),
            page(["e.ARW", "f.ARW"]),
            page([], isAtEnd: true)
        ])
        let scanner = makeScanner(cursor: cursor)

        // Held by hand rather than via `for await` so the iterator stays alive
        // while the test stalls — releasing it would cancel the producer and
        // make the read-ahead assertion vacuous.
        let iterator = scanner.scan(root: root).makeAsyncIterator()

        // Drain up to and including the first discovered batch.
        var firstBatch: [ScannedFile] = []
        while let event = await iterator.next() {
            if case .discovered(let files) = event { firstBatch = files; break }
        }
        XCTAssertEqual(firstBatch.map(\.relativePath), ["a.ARW", "b.ARW"])

        // First wait for the producer to take the one read-ahead it *is*
        // allowed. Asserting `<= 2` without this would also pass on a producer
        // that never advanced at all — the wrong reason for a green test.
        await waitUntilTrue("the producer to park its one allowed batch") {
            cursor.nextPageCallCount >= 2
        }

        // Now give it room to misbehave. If backpressure were missing it would
        // keep walking the whole script; the sleep is what gives that bug a
        // chance to show, not what synchronises the assertion.
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            cursor.nextPageCallCount, 2,
            "The walk ran ahead: \(cursor.nextPageCallCount) pages read while one batch was undelivered"
        )

        // Keep the iterator alive to the end of the test so its `deinit`
        // doesn't tear the producer down early.
        withExtendedLifetime(iterator) {}
    }

    func testBreakingOutEarlyStopsTheWalkAndClosesTheCursorOnce() async throws {
        let cursor = InstrumentedScanCursor(pages: [
            page(["a.ARW"]), page(["b.ARW"]), page(["c.ARW"]),
            page(["d.ARW"]), page(["e.ARW"]), page([], isAtEnd: true)
        ], gate: nil)
        let scanner = makeScanner(cursor: cursor, batchSize: 1)

        var batches = 0
        for await event in scanner.scan(root: root) {
            if case .discovered = event {
                batches += 1
                if batches == 3 { break }
            }
        }
        XCTAssertEqual(batches, 3)

        // Give the torn-down producer a moment to unwind.
        try await Task.sleep(for: .milliseconds(150))

        let reads = cursor.nextPageCallCount
        XCTAssertLessThanOrEqual(reads, 4, "The walk kept advancing after the consumer left")
        XCTAssertEqual(cursor.closeCount, 1, "The cursor was closed \(cursor.closeCount) times")
    }

    func testHighWaterStaysAtTwoAcrossTenThousandEntries() async throws {
        // 10,000 synthetic files in 500 pages of 20, with a failure sprinkled in
        // every tenth page.
        let pageCount = 500
        let perPage = 20
        var pages: [FolderScanPage] = []
        var expectedFiles: [String] = []
        var expectedFailures: [String] = []

        for pageIndex in 0..<pageCount {
            let names = (0..<perPage).map { String(format: "DSC%05d.ARW", pageIndex * perPage + $0) }
            expectedFiles.append(contentsOf: names)
            let failures = pageIndex % 10 == 0 ? ["broken-\(pageIndex).ARW"] : []
            expectedFailures.append(contentsOf: failures)
            pages.append(page(names, failures: failures))
        }
        pages.append(page([], isAtEnd: true))

        let cursor = InstrumentedScanCursor(pages: pages)
        let scanner = makeScanner(cursor: cursor, batchSize: perPage)

        var receivedFiles: [String] = []
        var receivedFailures: [String] = []
        var deliveredBatches = 0
        var maxRetained = 0
        var summary: ScanSummary?

        for await event in scanner.scan(root: root) {
            switch event {
            case .started:
                continue
            case .discovered(let files):
                receivedFiles.append(contentsOf: files.map(\.relativePath))
                deliveredBatches += 1
                // One batch in the consumer's hand, plus at most one parked in
                // the channel — anything more means the producer ran ahead.
                let retained = cursor.nextPageCallCount - deliveredBatches + 1
                maxRetained = max(maxRetained, retained)
            case .fileFailed(let relativePath, _):
                receivedFailures.append(relativePath)
            case .finished(let result):
                summary = result
            }
        }

        XCTAssertEqual(receivedFiles, expectedFiles, "Files were dropped, duplicated or reordered")
        XCTAssertEqual(receivedFailures, expectedFailures, "Failures were dropped or reordered")
        XCTAssertLessThanOrEqual(maxRetained, 2, "High-water mark reached \(maxRetained) batches")

        let finished = try XCTUnwrap(summary)
        XCTAssertEqual(finished.discoveredCount, expectedFiles.count)
        XCTAssertEqual(finished.failedCount, expectedFailures.count)
        XCTAssertFalse(finished.wasCancelled)
    }

    // MARK: - Terminal shapes

    func testEmptyWalkProducesExactlyOneTerminalEvent() async throws {
        let cursor = InstrumentedScanCursor(pages: [page([], isAtEnd: true)])
        var summaries: [ScanSummary] = []
        var discoveredCount = 0

        for await event in makeScanner(cursor: cursor).scan(root: root) {
            switch event {
            case .finished(let summary): summaries.append(summary)
            case .discovered: discoveredCount += 1
            default: break
            }
        }

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(discoveredCount, 0)
        XCTAssertEqual(summaries.first?.discoveredCount, 0)
    }

    func testAWalkThatDividesEvenlyEndsWithoutAnEmptyBatch() async throws {
        let cursor = InstrumentedScanCursor(pages: [
            page(["a.ARW", "b.ARW"]),
            page(["c.ARW", "d.ARW"]),
            page([], isAtEnd: true)
        ])

        var batchSizes: [Int] = []
        var summaries = 0
        for await event in makeScanner(cursor: cursor).scan(root: root) {
            if case .discovered(let files) = event { batchSizes.append(files.count) }
            if case .finished = event { summaries += 1 }
        }

        XCTAssertEqual(batchSizes, [2, 2], "An empty trailing batch was published")
        XCTAssertEqual(summaries, 1)
    }

    func testAShortFinalBatchIsStillDelivered() async throws {
        let cursor = InstrumentedScanCursor(pages: [
            page(["a.ARW", "b.ARW"]),
            page(["c.ARW"], isAtEnd: true)
        ])

        var received: [String] = []
        var summary: ScanSummary?
        for await event in makeScanner(cursor: cursor).scan(root: root) {
            if case .discovered(let files) = event { received += files.map(\.relativePath) }
            if case .finished(let result) = event { summary = result }
        }

        XCTAssertEqual(received, ["a.ARW", "b.ARW", "c.ARW"])
        XCTAssertEqual(summary?.discoveredCount, 3)
    }

    func testFailuresArriveBeforeTheBatchTheyWereFoundWith() async throws {
        let cursor = InstrumentedScanCursor(pages: [
            page(["a.ARW"], failures: ["bad.ARW"]),
            page([], isAtEnd: true)
        ])

        var order: [String] = []
        for await event in makeScanner(cursor: cursor).scan(root: root) {
            switch event {
            case .fileFailed(let path, _): order.append("failed:\(path)")
            case .discovered(let files): order.append("batch:\(files.count)")
            default: break
            }
        }
        XCTAssertEqual(order, ["failed:bad.ARW", "batch:1"])
    }

    // MARK: - The production cursor budgets failures too

    func testEveryFileFailingStillProducesBoundedPages() async throws {
        // Codex review finding 2. A drive where every RAW is unreadable used to
        // pile one failure per file into a single page, because only successes
        // counted against the budget. That is O(total errors) held at once —
        // exactly what the bounded pipeline exists to prevent.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("BoundedFailurePages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileCount = 40
        var expected: [String] = []
        for index in 0..<fileCount {
            let name = String(format: "DSC%03d.ARW", index)
            expected.append(name)
            try Data([0x01]).write(to: directory.appendingPathComponent(name))
        }

        let batchSize = 5
        // The real `FileManagerFolderScanCursor`, real enumerator — only the
        // resource read is forced to fail.
        var factory = FileManagerFolderScanCursorFactory()
        factory.loadResourceValues = { _, _ in
            throw CocoaError(.fileReadNoPermission)
        }
        let cursor = factory.makeCursor(
            root: directory,
            supportedExtensions: ["arw"],
            batchSize: batchSize
        )
        defer { cursor.close() }

        var pageFailureCounts: [Int] = []
        var collected: [String] = []
        var pages = 0

        while pages < fileCount * 2 {
            pages += 1
            let page = cursor.nextPage()
            pageFailureCounts.append(page.failures.count)
            collected.append(contentsOf: page.failures.map(\.relativePath))
            XCTAssertTrue(page.files.isEmpty, "A forced-failure read produced a file")
            if page.isAtEnd { break }
        }

        // Bounded per page…
        for (index, count) in pageFailureCounts.enumerated() {
            XCTAssertLessThanOrEqual(
                count, batchSize,
                "Page \(index) carried \(count) failures, over the \(batchSize) budget"
            )
        }
        // …and lossless across pages.
        XCTAssertEqual(
            collected.sorted(), expected.sorted(),
            "Failures were dropped or duplicated across pages"
        )
        XCTAssertGreaterThan(pageFailureCounts.count, 1, "Everything arrived on one page")
    }

    func testAMixOfFailuresAndSuccessesSharesOnePageBudget() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("BoundedMixedPages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileCount = 30
        for index in 0..<fileCount {
            try Data([0x01]).write(
                to: directory.appendingPathComponent(String(format: "DSC%03d.ARW", index))
            )
        }

        let batchSize = 4
        var factory = FileManagerFolderScanCursorFactory()
        // Every other file fails, so a page mixes both kinds.
        let failCounter = AtomicCounter()
        factory.loadResourceValues = { url, keys in
            if failCounter.increment() % 2 == 0 {
                throw CocoaError(.fileReadNoPermission)
            }
            return try url.resourceValues(forKeys: keys)
        }
        let cursor = factory.makeCursor(
            root: directory,
            supportedExtensions: ["arw"],
            batchSize: batchSize
        )
        defer { cursor.close() }

        var seen = 0
        while true {
            let page = cursor.nextPage()
            let items = page.files.count + page.failures.count
            XCTAssertLessThanOrEqual(
                items, batchSize,
                "A page carried \(items) items against a budget of \(batchSize)"
            )
            seen += items
            if page.isAtEnd { break }
        }
        XCTAssertEqual(seen, fileCount, "Items were lost between pages")
    }

    // MARK: - Cancellation

    func testCancellingWhileAPageReadIsBlockedStopsTheWalk() async throws {
        let gate = ScanCursorGate()
        let cursor = InstrumentedScanCursor(
            pages: [page(["a.ARW"]), page(["b.ARW"]), page(["c.ARW"]), page([], isAtEnd: true)],
            gate: gate,
            gateOnCall: 2,
            // Non-cooperative: the read finishes regardless, and its result must
            // simply be discarded.
            gateIgnoresCancellation: true
        )
        let scanner = makeScanner(cursor: cursor, batchSize: 1)

        let consumer = Task { () -> Int in
            var batches = 0
            for await event in scanner.scan(root: root) {
                if case .discovered = event { batches += 1 }
            }
            return batches
        }

        await waitUntilTrue("the second page read to block") { gate.enteredCount > 0 }
        consumer.cancel()
        gate.open()

        let delivered = await consumer.value
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertLessThanOrEqual(delivered, 2)
        XCTAssertLessThanOrEqual(
            cursor.nextPageCallCount, 2,
            "The walk started another page after cancellation"
        )
        XCTAssertEqual(cursor.closeCount, 1)
    }

    func testCancellingWhileABatchIsParkedStopsTheWalk() async throws {
        // Spec §6.2.5, the third position: the producer is suspended in `send`
        // with a batch nobody has taken. Cancelling has to wake it and stop the
        // walk rather than leaving a task parked forever.
        let cursor = InstrumentedScanCursor(pages: [
            page(["a.ARW"]), page(["b.ARW"]), page(["c.ARW"]),
            page(["d.ARW"]), page([], isAtEnd: true)
        ])
        let scanner = makeScanner(cursor: cursor, batchSize: 1)

        // Scoped so the iterator is released at the closing brace — that release
        // is exactly what a consumer walking away looks like, and it is what
        // must tear the producer down.
        func takeFirstBatchThenLeave() async -> Int {
            let iterator = scanner.scan(root: root).makeAsyncIterator()
            var received = 0
            while let event = await iterator.next() {
                if case .discovered = event { received += 1; break }
            }
            // Wait for the producer to park its one allowed read-ahead before
            // abandoning it, so the test really covers "cancelled with a batch
            // pending" rather than "cancelled before it got that far".
            await waitUntilTrue("the next batch to be parked") {
                cursor.nextPageCallCount >= 2
            }
            return received
        }

        let received = await takeFirstBatchThenLeave()
        XCTAssertEqual(received, 1)

        // The walk is parked, so this count is stable to read.
        let readsWhileParked = cursor.nextPageCallCount
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            cursor.nextPageCallCount, readsWhileParked,
            "The walk advanced after the consumer abandoned a parked batch"
        )
        XCTAssertEqual(cursor.closeCount, 1, "The cursor was closed \(cursor.closeCount) times")
    }

    func testCancellingBeforeAnyPageIsReadProducesNoBatches() async throws {
        let cursor = InstrumentedScanCursor(pages: [
            page(["a.ARW"]), page([], isAtEnd: true)
        ])
        let scanner = makeScanner(cursor: cursor, batchSize: 1)

        let consumer = Task { () -> Int in
            var batches = 0
            for await event in scanner.scan(root: root) {
                if case .discovered = event { batches += 1 }
            }
            return batches
        }
        consumer.cancel()

        let delivered = await consumer.value
        XCTAssertEqual(delivered, 0)
    }
}
