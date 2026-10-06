import CoreImage
import Foundation
import XCTest
@testable import RawProcessingCore

final class BrushMaskCancellationTests: XCTestCase {
    func testParentCancellationStopsDetachedSyncRendererDuringRasterization() async throws {
        let harness = CancellationHarness(stage: .rasterization)
        let source = makeSource()
        let task = Task.detached {
            try BrushMaskRenderer._applyValidated(
                [self.makeMask(index: 0)],
                to: source,
                observer: harness.observer
            )
        }

        await waitUntil("sync rasterization barrier") { harness.reached }
        task.cancel()
        harness.release()
        await assertCancelled(task)
        harness.assertBalanced(expectedMinimumStarted: 1)
    }

    func testParentCancellationStopsDirectAsyncRendererDuringConversion() async throws {
        let harness = CancellationHarness(stage: .conversion)
        let source = makeSource()
        let task = Task.detached {
            try await BrushMaskRenderer._applyValidatedAsync(
                [self.makeMask(index: 0)],
                to: source,
                observer: harness.observer
            )
        }

        await waitUntil("async conversion barrier") { harness.reached }
        task.cancel()
        harness.release()
        await assertCancelled(task)
        harness.assertBalanced(expectedMinimumStarted: 1)
    }

    func testParentCancellationJoinsEveryStartedParallelCoverageWorker() async throws {
        let harness = CancellationHarness(stage: .rasterization, requiredArrivals: 2)
        let source = makeSource()
        let masks = (0..<3).map(makeMask(index:))
        let task = Task.detached {
            try await BrushMaskRenderer._applyValidatedAsync(
                masks,
                to: source,
                observer: harness.observer
            )
        }

        await waitUntil("two parallel coverage workers") { harness.reached }
        task.cancel()
        harness.release()
        await assertCancelled(task)
        harness.assertBalanced(expectedMinimumStarted: 2)
    }

    func testParentCancellationStopsBoundedValidationLoop() async throws {
        let harness = CancellationHarness(stage: .validation)
        let source = makeSource()
        let points = (0..<10_000).map { index in
            BrushMaskPoint(
                x: 0.1 + 0.8 * Double(index % 100) / 99,
                y: 0.1 + 0.8 * Double(index / 100) / 99
            )
        }
        let mask = BrushMask(
            strokes: [BrushMaskStroke(points: points, size: 0.02)],
            adjustments: BrushMaskPatch(exposure: 1)
        )
        let task = Task.detached {
            try await BrushMaskRenderer._applyValidatedAsync(
                [mask],
                to: source,
                observer: harness.observer
            )
        }

        await waitUntil("validation barrier") { harness.reached }
        task.cancel()
        harness.release()
        await assertCancelled(task)
        harness.assertBalanced(expectedMinimumStarted: 0)
    }

    func testParentCancellationStopsSamplingLoop() async throws {
        let harness = CancellationHarness(stage: .sampling)
        let source = makeSource()
        let mask = BrushMask(
            strokes: [BrushMaskStroke(
                points: Array(repeating: BrushMaskPoint(x: 0.5, y: 0.5), count: 5_000),
                size: 0.02,
                feather: 0.25,
                flow: 0.8
            )],
            adjustments: BrushMaskPatch(exposure: 1)
        )
        let task = Task.detached {
            try await BrushMaskRenderer._applyValidatedAsync(
                [mask],
                to: source,
                observer: harness.observer
            )
        }

        await waitUntil("sampling barrier") { harness.reached }
        task.cancel()
        harness.release()
        await assertCancelled(task)
        harness.assertBalanced(expectedMinimumStarted: 1)
    }

    func testPreCancelledRendererDoesNotStartCoverageWorker() async throws {
        let harness = CancellationHarness(stage: .rasterization)
        let startGate = DispatchSemaphore(value: 0)
        let source = makeSource()
        let task = Task.detached {
            startGate.wait()
            return try await BrushMaskRenderer._applyValidatedAsync(
                [self.makeMask(index: 0)],
                to: source,
                observer: harness.observer
            )
        }

        task.cancel()
        startGate.signal()
        await assertCancelled(task)
        harness.assertBalanced(expectedMinimumStarted: 0)
    }

    func testPreviewSchedulerCancelsRasterizingProductionRequestWithoutLateDelivery() async throws {
        let harness = CancellationHarness(stage: .rasterization)
        let observerFactory = OneShotObserverFactory(observer: harness.observer)
        let renderer = CoreImagePreviewRenderer(
            decoder: SyntheticRawDecoder(pixelSize: CGSize(width: 800, height: 600)),
            brushRenderObserverFactory: { observerFactory.take() }
        )
        let scheduler = PreviewScheduler(renderer: renderer)
        let abandonedSubject = PreviewSubject(UUID())
        let currentSubject = PreviewSubject(UUID())
        let abandonedContext = UUID()
        let currentContext = UUID()
        _ = await scheduler.submit(PreviewRequest(
            subject: abandonedSubject,
            url: URL(fileURLWithPath: "/tmp/preview-a.ARW"),
            adjustments: PhotoAdjustments(brushMasks: [makeMask(index: 0)]),
            targetPixelDimension: 800,
            quality: .interactive,
            contextID: abandonedContext
        ))

        await waitUntil("production preview rasterization barrier") { harness.reached }
        let currentToken = await scheduler.submit(PreviewRequest(
            subject: currentSubject,
            url: URL(fileURLWithPath: "/tmp/preview-b.ARW"),
            adjustments: .neutral,
            targetPixelDimension: 800,
            quality: .interactive,
            contextID: currentContext
        ))
        harness.release()

        await waitUntil("cancelled preview and replacement to settle") {
            let discarded = await scheduler.discardedStaleCount
            let delivered = await scheduler.deliveredCount
            let inFlight = await scheduler.inFlightCount
            return discarded >= 1 && delivered == 1 && inFlight == 0
        }
        let failedCount = await scheduler.failedCount
        let current = await scheduler.currentSubject
        let isCurrent = await scheduler.isCurrent(currentToken)
        XCTAssertEqual(failedCount, 0)
        XCTAssertEqual(current, currentSubject)
        XCTAssertTrue(isCurrent)
        harness.assertBalanced(expectedMinimumStarted: 1)
    }

    func testExportCancellationDuringRasterizationCleansTemporaryAndFinalFiles() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("BrushExportCancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.raw")
        try Data([0]).write(to: sourceURL)

        let harness = CancellationHarness(stage: .rasterization)
        let exporter = PhotoExporter(
            decoder: SyntheticRawDecoder(pixelSize: CGSize(width: 6_000, height: 4_000)),
            brushRenderObserverFactory: { harness.observer }
        )
        let request = ExportRequest(
            sourceURL: sourceURL,
            adjustments: PhotoAdjustments(brushMasks: [makeMask(index: 0)]),
            destinationDirectory: directory,
            baseFilename: "cancelled",
            format: .jpeg
        )
        let task = Task { try await exporter.export(request) }

        await waitUntil("export rasterization barrier", timeout: 10) { harness.reached }
        task.cancel()
        harness.release()
        do {
            _ = try await task.value
            XCTFail("cancelled export must not publish a final file")
        } catch {
            XCTAssertEqual(error as? ExportError, .cancelled)
        }

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(contents.contains { $0.hasSuffix(".jpg") })
        XCTAssertFalse(contents.contains { $0.hasPrefix(".lumaharbor-export-") || $0.hasSuffix(".tmp") })
        harness.assertBalanced(expectedMinimumStarted: 1)
    }

    private func makeSource() -> CIImage {
        CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    private func makeMask(index: Int) -> BrushMask {
        BrushMask(
            id: UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", index + 1))!,
            strokes: [BrushMaskStroke(
                points: [BrushMaskPoint(x: 0.5, y: 0.5)],
                size: 1,
                feather: 0.25,
                flow: 0.8
            )],
            adjustments: BrushMaskPatch(exposure: index.isMultiple(of: 2) ? 1 : -1)
        )
    }

    private func assertCancelled(
        _ task: Task<CIImage, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("render must not return a partial success after cancellation", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)", file: file, line: line)
        }
    }

    private final class CancellationHarness: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseSemaphore = DispatchSemaphore(value: 0)
        private let targetStage: BrushMaskRenderEvent.Stage
        private let requiredArrivals: Int
        private var arrivals = 0
        private var released = false
        private var started = Set<Int>()
        private var finished = Set<Int>()

        let requestID = UUID()

        init(stage: BrushMaskRenderEvent.Stage, requiredArrivals: Int = 1) {
            self.targetStage = stage
            self.requiredArrivals = requiredArrivals
        }

        lazy var observer = BrushMaskRenderObserver(requestID: requestID) { [weak self] event in
            self?.record(event)
        }

        var reached: Bool {
            lock.lock()
            defer { lock.unlock() }
            return arrivals >= requiredArrivals
        }

        func release() {
            lock.lock()
            released = true
            lock.unlock()
            for _ in 0..<16 { releaseSemaphore.signal() }
        }

        func assertBalanced(
            expectedMinimumStarted: Int,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            lock.lock()
            let startedSnapshot = started
            let finishedSnapshot = finished
            lock.unlock()
            if expectedMinimumStarted == 0 {
                XCTAssertEqual(startedSnapshot.count, 0, file: file, line: line)
            } else {
                XCTAssertGreaterThanOrEqual(startedSnapshot.count, expectedMinimumStarted, file: file, line: line)
            }
            XCTAssertEqual(finishedSnapshot, startedSnapshot, "every started worker must finish before return", file: file, line: line)
        }

        private func record(_ event: BrushMaskRenderEvent) {
            var shouldWait = false
            lock.lock()
            XCTAssertEqual(event.requestID, requestID)
            switch event.kind {
            case .workerStarted:
                started.insert(event.maskIndex)
            case .workerFinished:
                finished.insert(event.maskIndex)
            case .progress:
                if event.stage == targetStage,
                   event.completedIterations >= 4_096,
                   arrivals < requiredArrivals {
                    arrivals += 1
                    shouldWait = !released
                }
            }
            lock.unlock()

            while shouldWait {
                _ = releaseSemaphore.wait(timeout: .now() + 0.01)
                lock.lock()
                shouldWait = !released
                lock.unlock()
            }
        }
    }

    private final class OneShotObserverFactory: @unchecked Sendable {
        private let lock = NSLock()
        private var observer: BrushMaskRenderObserver?

        init(observer: BrushMaskRenderObserver) {
            self.observer = observer
        }

        func take() -> BrushMaskRenderObserver? {
            lock.lock()
            defer { lock.unlock() }
            defer { observer = nil }
            return observer
        }
    }
}
