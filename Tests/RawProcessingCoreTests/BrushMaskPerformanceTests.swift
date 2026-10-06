import CoreGraphics
import CoreImage
import Darwin
import Foundation
import XCTest
@testable import RawProcessingCore

/// Deterministic, opt-in workload for the brush rasterizer. The default unit
/// test only checks the fixture contract so ordinary CI remains bounded; the
/// timed path is enabled by `LUMAHARBOR_RUN_BRUSH_PERF_ACCEPTANCE=1` and is
/// the input to the checked-in acceptance script.
final class BrushMaskPerformanceTests: XCTestCase {
    private let width = 1_600
    private let height = 1_067

    func testWorkloadGeneratorIsDeterministic() throws {
        let masks = makeMasks(count: 10)

        XCTAssertEqual(masks.count, 10)
        XCTAssertEqual(masks[0].strokes.count, 10)
        XCTAssertEqual(masks[0].strokes[0].points.count, 100)
        XCTAssertEqual(masks[0].strokes[0].points.first, BrushMaskPoint(x: 0.05, y: 0.08, pressure: 0.65))
        let finalPoint = try XCTUnwrap(masks[9].strokes[9].points.last)
        XCTAssertEqual(finalPoint.x, 0.941, accuracy: 1e-12)
        XCTAssertEqual(finalPoint.y, 0.23, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(finalPoint.pressure), 0.65, accuracy: 1e-12)
        XCTAssertEqual(masks[0].adjustments.exposure, 0.25)
        XCTAssertEqual(masks[1].adjustments.exposure, -0.2)
    }

    func testOptInWorkloadPrintsMachineReadableSamples() async throws {
        guard ProcessInfo.processInfo.environment["LUMAHARBOR_RUN_BRUSH_PERF_ACCEPTANCE"] == "1" else {
            throw XCTSkip("brush performance acceptance is opt-in")
        }

        let sampleCount = max(
            Int(ProcessInfo.processInfo.environment["LUMAHARBOR_BRUSH_PERF_SAMPLES"] ?? "8") ?? 8,
            1
        )
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let preferMetal = ProcessInfo.processInfo.environment["LUMAHARBOR_BRUSH_PERF_PREFER_METAL"] != "0"
        let service = ImageRenderService(preferMetal: preferMetal)
        let clock = ContinuousClock()

        for maskCount in [0, 1, 10] {
            let masks = makeMasks(count: maskCount)
            _ = try await render(masks, source: source, service: service)

            var coverageSamples: [Double] = []
            var samples: [Double] = []
            for _ in 0..<sampleCount {
                let coverageStart = clock.now
                try await renderCoverageInParallel(masks, extent: source.extent)
                let coverageDuration = coverageStart.duration(to: clock.now)
                coverageSamples.append(
                    Double(coverageDuration.components.seconds)
                        + Double(coverageDuration.components.attoseconds) / 1e18
                )

                let start = clock.now
                _ = try await render(masks, source: source, service: service)
                let duration = start.duration(to: clock.now)
                samples.append(
                    Double(duration.components.seconds)
                        + Double(duration.components.attoseconds) / 1e18
                )
            }

            let record: [String: Any] = [
                "schemaVersion": 1,
                "scenario": "synthetic-1600px",
                "maskCount": maskCount,
                "width": width,
                "height": height,
                "strokeCountPerMask": 10,
                "pointCountPerStroke": 100,
                "sampleCount": samples.count,
                "coverageDurationsSeconds": coverageSamples,
                "durationsSeconds": samples,
                "preferMetal": preferMetal,
                "seed": "LH-BRUSH-PERF-ACCEPTANCE-20261006"
            ]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        }
    }

    func testOptInCancellationLatencyPrintsMachineReadableSamples() async throws {
        guard ProcessInfo.processInfo.environment["LUMAHARBOR_RUN_BRUSH_PERF_ACCEPTANCE"] == "1" else {
            throw XCTSkip("brush performance acceptance is opt-in")
        }

        let sampleCount = max(
            Int(ProcessInfo.processInfo.environment["LUMAHARBOR_BRUSH_PERF_SAMPLES"] ?? "8") ?? 8,
            1
        )
        let mask = makeMasks(count: 1)[0]
        let clock = ContinuousClock()
        var previewSamples: [Double] = []
        var exportSamples: [Double] = []

        for sampleOrdinal in 0..<sampleCount {
            let probe = CancellationLatencyProbe(stage: .rasterization)
            let renderer = CoreImagePreviewRenderer(
                decoder: SyntheticRawDecoder(pixelSize: CGSize(width: width, height: height)),
                brushRenderObserverFactory: { probe.observer }
            )
            let request = PreviewRequest(
                subject: PreviewSubject(UUID()),
                url: URL(fileURLWithPath: "/tmp/brush-perf-preview.raw"),
                adjustments: PhotoAdjustments(brushMasks: [mask]),
                targetPixelDimension: width,
                quality: .interactive
            )
            let task = Task { try await renderer.render(request) }
            await waitUntil("preview cancellation barrier \(sampleOrdinal)") { probe.reached }
            let start = clock.now
            task.cancel()
            probe.release()
            do {
                _ = try await task.value
                XCTFail("cancelled preview returned a frame")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            previewSamples.append(seconds(start.duration(to: clock.now)))
            probe.assertBalanced()
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("BrushCancellationPerf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.raw")
        try Data([0]).write(to: sourceURL)

        for sampleOrdinal in 0..<sampleCount {
            let probe = CancellationLatencyProbe(stage: .rasterization)
            let exporter = PhotoExporter(
                decoder: SyntheticRawDecoder(pixelSize: CGSize(width: 6_000, height: 4_000)),
                brushRenderObserverFactory: { probe.observer }
            )
            let request = ExportRequest(
                sourceURL: sourceURL,
                adjustments: PhotoAdjustments(brushMasks: [mask]),
                destinationDirectory: directory,
                baseFilename: "cancelled-\(sampleOrdinal)",
                format: .jpeg
            )
            let task = Task { try await exporter.export(request) }
            await waitUntil("export cancellation barrier \(sampleOrdinal)", timeout: 10) { probe.reached }
            let start = clock.now
            task.cancel()
            probe.release()
            do {
                _ = try await task.value
                XCTFail("cancelled export published a file")
            } catch {
                XCTAssertEqual(error as? ExportError, .cancelled)
            }
            exportSamples.append(seconds(start.duration(to: clock.now)))
            probe.assertBalanced()
        }

        let previewP95 = nearestRankP95(previewSamples)
        let exportP95 = nearestRankP95(exportSamples)
        XCTAssertLessThanOrEqual(previewP95, 0.1)
        XCTAssertLessThanOrEqual(exportP95, 0.1)
        for (scenario, samples) in [("preview-cancel", previewSamples), ("export-cancel-24mp", exportSamples)] {
            let record: [String: Any] = [
                "schemaVersion": 2,
                "scenario": scenario,
                "variant": "O",
                "sampleCount": samples.count,
                "durationsSeconds": samples,
                "p95Seconds": nearestRankP95(samples),
                "workerCounts": ["startedMinimum": 1, "activeAfterJoin": 0],
                "cancelOutcome": "cancelled-and-joined",
                "result": nearestRankP95(samples) <= 0.1 ? "PASS" : "FAIL"
            ]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        }
    }

    func testOptInFiftyCancellationCyclesSettleWorkersAndMemory() async throws {
        guard ProcessInfo.processInfo.environment["LUMAHARBOR_RUN_BRUSH_PERF_ACCEPTANCE"] == "1" else {
            throw XCTSkip("brush performance acceptance is opt-in")
        }

        let mask = makeMasks(count: 1)[0]
        var totalStarted = 0
        for cycle in 0..<5 {
            totalStarted += try await runCancelledPreviewCycle(cycle, mask: mask)
        }
        try await Task.sleep(for: .milliseconds(100))
        let warmPlateau = try currentResidentSizeBytes()

        for cycle in 5..<55 {
            totalStarted += try await runCancelledPreviewCycle(cycle, mask: mask)
        }
        try await Task.sleep(for: .milliseconds(100))
        let settled = try currentResidentSizeBytes()
        let limit = warmPlateau + 32 * 1_024 * 1_024
        XCTAssertLessThanOrEqual(settled, limit)

        let record: [String: Any] = [
            "schemaVersion": 2,
            "scenario": "50-cancel-switch-preview",
            "variant": "O",
            "warmupCycles": 5,
            "measuredCycles": 50,
            "warmPlateauRSSBytes": warmPlateau,
            "settledRSSBytes": settled,
            "rssLimitBytes": limit,
            "workerCounts": ["started": totalStarted, "finished": totalStarted, "activeAfterJoin": 0],
            "cancelOutcome": "all-cancelled-and-joined",
            "result": settled <= limit ? "PASS" : "FAIL"
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private func render(
        _ masks: [BrushMask],
        source: CIImage,
        service: ImageRenderService
    ) async throws -> CGImage {
        let rendered = try await BrushMaskRenderer.applyValidatedAsync(masks, to: source)
        return try service.makeCGImage(rendered)
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func nearestRankP95(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        let index = max(Int(ceil(0.95 * Double(sorted.count))) - 1, 0)
        return sorted[index]
    }

    private func runCancelledPreviewCycle(_ cycle: Int, mask: BrushMask) async throws -> Int {
        let probe = CancellationLatencyProbe(stage: .rasterization)
        let renderer = CoreImagePreviewRenderer(
            decoder: SyntheticRawDecoder(pixelSize: CGSize(width: width, height: height)),
            brushRenderObserverFactory: { probe.observer }
        )
        let subjectSuffix = cycle.isMultiple(of: 2) ? 1 : 2
        let request = PreviewRequest(
            subject: PreviewSubject(UUID(uuidString: String(
                format: "00000000-0000-4000-c000-%012d",
                subjectSuffix
            ))!),
            url: URL(fileURLWithPath: "/tmp/brush-perf-switch-\(subjectSuffix).raw"),
            adjustments: PhotoAdjustments(
                exposure: cycle.isMultiple(of: 2) ? 0.05 : -0.05,
                brushMasks: [mask]
            ),
            targetPixelDimension: width,
            quality: .interactive
        )
        let task = Task { try await renderer.render(request) }
        await waitUntil("50-cycle cancellation barrier \(cycle)") { probe.reached }
        task.cancel()
        probe.release()
        do {
            _ = try await task.value
            XCTFail("cancelled switch cycle returned a frame")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        probe.assertBalanced()
        return probe.workerCounts.started
    }

    private func currentResidentSizeBytes() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw NSError(domain: "BrushMaskPerformanceTests", code: Int(result))
        }
        return info.resident_size
    }

    private func renderCoverageInParallel(_ masks: [BrushMask], extent: CGRect) async throws {
        if masks.count == 1, let mask = masks.first {
            _ = try BrushMaskRenderer._testRenderCoverage(mask, imageExtent: extent)
            return
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for mask in masks {
                group.addTask {
                    _ = try BrushMaskRenderer._testRenderCoverage(mask, imageExtent: extent)
                }
            }
            try await group.waitForAll()
        }
    }

    private func makeMasks(count: Int) -> [BrushMask] {
        (0..<count).map { maskIndex in
            let strokes = (0..<10).map { strokeIndex in
                let points = (0..<100).map { pointIndex in
                    BrushMaskPoint(
                        x: 0.05 + 0.009 * Double(pointIndex),
                        y: 0.08 + Double((10 * maskIndex + strokeIndex) % 84) / 100,
                        pressure: 0.65
                    )
                }
                return BrushMaskStroke(
                    id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", strokeIndex + maskIndex * 10 + 1))!,
                    points: points,
                    size: 0.018,
                    feather: 0.25,
                    flow: 0.6,
                    density: 0.8
                )
            }
            return BrushMask(
                id: UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", maskIndex + 1))!,
                name: "benchmark-(maskIndex)",
                strokes: strokes,
                adjustments: BrushMaskPatch(exposure: maskIndex.isMultiple(of: 2) ? 0.25 : -0.2)
            )
        }
    }

    private final class CancellationLatencyProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private let stage: BrushMaskRenderEvent.Stage
        private var didReach = false
        private var isReleased = false
        private var started = 0
        private var finished = 0

        init(stage: BrushMaskRenderEvent.Stage) {
            self.stage = stage
        }

        lazy var observer = BrushMaskRenderObserver { [weak self] event in
            self?.record(event)
        }

        var reached: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didReach
        }

        func release() {
            lock.lock()
            isReleased = true
            lock.unlock()
            semaphore.signal()
        }

        func assertBalanced(file: StaticString = #filePath, line: UInt = #line) {
            lock.lock()
            let counts = (started, finished)
            lock.unlock()
            XCTAssertGreaterThanOrEqual(counts.0, 1, file: file, line: line)
            XCTAssertEqual(counts.1, counts.0, file: file, line: line)
        }

        var workerCounts: (started: Int, finished: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (started, finished)
        }

        private func record(_ event: BrushMaskRenderEvent) {
            var shouldWait = false
            lock.lock()
            switch event.kind {
            case .workerStarted:
                started += 1
            case .workerFinished:
                finished += 1
            case .progress:
                if !didReach, event.stage == stage, event.completedIterations >= 4_096 {
                    didReach = true
                    shouldWait = !isReleased
                }
            }
            lock.unlock()

            while shouldWait {
                _ = semaphore.wait(timeout: .now() + 0.01)
                lock.lock()
                shouldWait = !isReleased
                lock.unlock()
            }
        }
    }
}
