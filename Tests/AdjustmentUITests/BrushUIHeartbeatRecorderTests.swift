import AdjustmentUI
import Foundation
import XCTest

final class BrushUIHeartbeatRecorderTests: XCTestCase {
    private let configuration = BrushUIHeartbeatConfiguration(
        buildIdentifier: "anonymous-build",
        variant: "O",
        buildConfiguration: "Release",
        fixtureIdentifier: "anonymous-fixture",
        expectedHeartbeatIntervalNanoseconds: 10,
        maximumFrameCount: 8
    )

    func testGestureStartsAtPointerDownAndEndsOnFirstVisibleFrameAfterPointerUp() throws {
        var recorder = BrushUIHeartbeatRecorder(configuration: configuration)
        let gestureID = UUID()

        recorder.recordHeartbeat(atNanoseconds: 0)
        XCTAssertTrue(recorder.beginGesture(id: gestureID, kind: "paint", atNanoseconds: 5))
        recorder.recordHeartbeat(atNanoseconds: 10) // Straddles pointer-down; excluded.
        recorder.recordHeartbeat(atNanoseconds: 20)
        XCTAssertTrue(recorder.requestGestureEnd(id: gestureID, atNanoseconds: 25))
        XCTAssertTrue(recorder.completedSamples.isEmpty)

        recorder.recordHeartbeat(atNanoseconds: 30)
        XCTAssertTrue(recorder.completedSamples.isEmpty)
        XCTAssertTrue(recorder.markVisibleFrame(id: gestureID, atNanoseconds: 35))

        recorder.recordHeartbeat(atNanoseconds: 40)

        let sample = try XCTUnwrap(recorder.completedSamples.only)
        XCTAssertEqual(sample.gestureID, gestureID)
        XCTAssertEqual(sample.monotonicStartNanoseconds, 5)
        XCTAssertEqual(sample.pointerUpNanoseconds, 25)
        XCTAssertEqual(sample.visibleFrameNanoseconds, 35)
        XCTAssertEqual(sample.monotonicEndNanoseconds, 40)
        XCTAssertEqual(sample.completeness, .complete)
        XCTAssertNil(sample.cancellationReason)
        XCTAssertEqual(sample.frames.map(\.intervalNanoseconds), [10, 10, 10])
        XCTAssertEqual(sample.frames.map(\.extraDelayNanoseconds), [0, 0, 0])
        XCTAssertEqual(sample.frames.map(\.missedHeartbeatCount), [0, 0, 0])
    }

    func testCancellationProducesFailClosedIncompleteSample() throws {
        var recorder = BrushUIHeartbeatRecorder(configuration: configuration)
        let gestureID = UUID()

        recorder.recordHeartbeat(atNanoseconds: 100)
        XCTAssertTrue(recorder.beginGesture(id: gestureID, kind: "erase", atNanoseconds: 100))
        recorder.recordHeartbeat(atNanoseconds: 110)
        XCTAssertTrue(recorder.cancelGesture(
            id: gestureID,
            reason: .gestureCancelled,
            atNanoseconds: 115
        ))

        let sample = try XCTUnwrap(recorder.completedSamples.only)
        XCTAssertEqual(sample.completeness, .incomplete)
        XCTAssertEqual(sample.cancellationReason, .gestureCancelled)
        XCTAssertEqual(sample.monotonicEndNanoseconds, 115)
    }

    func testMissingFinalHeartbeatProducesFailClosedIncompleteSample() throws {
        var recorder = BrushUIHeartbeatRecorder(configuration: configuration)
        let gestureID = UUID()

        recorder.recordHeartbeat(atNanoseconds: 0)
        XCTAssertTrue(recorder.beginGesture(id: gestureID, kind: "paint", atNanoseconds: 0))
        recorder.recordHeartbeat(atNanoseconds: 10)
        XCTAssertTrue(recorder.requestGestureEnd(id: gestureID, atNanoseconds: 12))
        XCTAssertTrue(recorder.markMissingFinalHeartbeat(atNanoseconds: 42))

        let sample = try XCTUnwrap(recorder.completedSamples.only)
        XCTAssertEqual(sample.completeness, .incomplete)
        XCTAssertEqual(sample.cancellationReason, .missingFinalHeartbeat)
    }

    func testRecorderOverflowProducesFailClosedIncompleteSample() throws {
        var recorder = BrushUIHeartbeatRecorder(configuration: .init(
            buildIdentifier: "anonymous-build",
            variant: "B",
            buildConfiguration: "Release",
            fixtureIdentifier: "anonymous-fixture",
            expectedHeartbeatIntervalNanoseconds: 10,
            maximumFrameCount: 2
        ))
        let gestureID = UUID()

        recorder.recordHeartbeat(atNanoseconds: 0)
        XCTAssertTrue(recorder.beginGesture(id: gestureID, kind: "paint", atNanoseconds: 0))
        recorder.recordHeartbeat(atNanoseconds: 10)
        recorder.recordHeartbeat(atNanoseconds: 20)
        recorder.recordHeartbeat(atNanoseconds: 30)

        let sample = try XCTUnwrap(recorder.completedSamples.only)
        XCTAssertEqual(sample.completeness, .incomplete)
        XCTAssertEqual(sample.cancellationReason, .recorderOverflow)
        XCTAssertEqual(sample.frames.count, 2)
    }

    func testMissedHeartbeatCountToleratesNanosecondRounding() throws {
        var recorder = BrushUIHeartbeatRecorder(configuration: .init(
            buildIdentifier: "anonymous-build",
            variant: "O",
            buildConfiguration: "Release",
            fixtureIdentifier: "anonymous-fixture",
            expectedHeartbeatIntervalNanoseconds: 16_666_667
        ))
        let gestureID = UUID()

        recorder.recordHeartbeat(atNanoseconds: 0)
        XCTAssertTrue(recorder.beginGesture(id: gestureID, kind: "paint", atNanoseconds: 0))
        recorder.recordHeartbeat(atNanoseconds: 33_333_333)

        XCTAssertEqual(recorder.completedSamples.count, 0)
        XCTAssertTrue(recorder.requestGestureEnd(id: gestureID, atNanoseconds: 34_000_000))
        XCTAssertTrue(recorder.markVisibleFrame(id: gestureID, atNanoseconds: 45_000_000))
        recorder.recordHeartbeat(atNanoseconds: 50_000_000)
        XCTAssertEqual(recorder.completedSamples.only?.frames.first?.missedHeartbeatCount, 1)
    }

    func testGestureWithoutACompleteHeartbeatIntervalFailsClosed() throws {
        var recorder = BrushUIHeartbeatRecorder(configuration: configuration)
        let gestureID = UUID()

        recorder.recordHeartbeat(atNanoseconds: 0)
        XCTAssertTrue(recorder.beginGesture(id: gestureID, kind: "paint", atNanoseconds: 5))
        XCTAssertTrue(recorder.requestGestureEnd(id: gestureID, atNanoseconds: 6))
        XCTAssertTrue(recorder.markVisibleFrame(id: gestureID, atNanoseconds: 8))
        recorder.recordHeartbeat(atNanoseconds: 10)

        let sample = try XCTUnwrap(recorder.completedSamples.only)
        XCTAssertEqual(sample.completeness, .incomplete)
        XCTAssertEqual(sample.cancellationReason, .missingHeartbeatIntervals)
        XCTAssertTrue(sample.frames.isEmpty)
    }

    func testNonMonotonicHeartbeatProducesFailClosedIncompleteSample() throws {
        var recorder = BrushUIHeartbeatRecorder(configuration: configuration)
        let gestureID = UUID()

        recorder.recordHeartbeat(atNanoseconds: 100)
        XCTAssertTrue(recorder.beginGesture(id: gestureID, kind: "paint", atNanoseconds: 100))
        recorder.recordHeartbeat(atNanoseconds: 110)
        recorder.recordHeartbeat(atNanoseconds: 109)

        let sample = try XCTUnwrap(recorder.completedSamples.only)
        XCTAssertEqual(sample.completeness, .incomplete)
        XCTAssertEqual(sample.cancellationReason, .nonMonotonicClock)
    }

    func testJSONContainsRequiredRawEvidenceFields() throws {
        var recorder = BrushUIHeartbeatRecorder(configuration: configuration)
        recorder.recordHeartbeat(atNanoseconds: 0)
        XCTAssertTrue(recorder.beginGesture(id: UUID(), kind: "paint", atNanoseconds: 0))
        recorder.recordHeartbeat(atNanoseconds: 20)
        XCTAssertTrue(recorder.requestGestureEnd(atNanoseconds: 21))
        XCTAssertTrue(recorder.markVisibleFrame(atNanoseconds: 25))
        recorder.recordHeartbeat(atNanoseconds: 30)

        let sample = try XCTUnwrap(recorder.completedSamples.only)
        let data = try JSONEncoder().encode(sample)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        for key in [
            "schemaVersion", "buildIdentifier", "variant", "gestureKind", "gestureID",
            "buildConfiguration", "fixtureIdentifier", "cancellationReason",
            "expectedHeartbeatIntervalNanoseconds", "monotonicStartNanoseconds",
            "pointerUpNanoseconds", "visibleFrameNanoseconds", "monotonicEndNanoseconds",
            "frames", "completeness"
        ] {
            XCTAssertNotNil(object[key], "missing JSON evidence field: \(key)")
        }
        XCTAssertTrue(object["cancellationReason"] is NSNull)
    }

    func testRuntimeConfigurationRequiresExplicitOutputVariantAndBuild() throws {
        XCTAssertNil(BrushUIPerformanceProbeConfiguration(environment: [:]))
        XCTAssertNil(BrushUIPerformanceProbeConfiguration(environment: [
            "LUMAHARBOR_PERF_UI_OUTPUT": "/tmp/evidence.jsonl",
            "LUMAHARBOR_PERF_UI_VARIANT": "O"
        ]))

        let parsed = try XCTUnwrap(BrushUIPerformanceProbeConfiguration(environment: [
            "LUMAHARBOR_PERF_UI_OUTPUT": "/tmp/evidence.jsonl",
            "LUMAHARBOR_PERF_UI_VARIANT": "O",
            "LUMAHARBOR_PERF_UI_BUILD": "candidate-sha",
            "LUMAHARBOR_PERF_UI_CONFIGURATION": "Release",
            "LUMAHARBOR_PERF_UI_FIXTURE": "anonymous-fixture",
            "LUMAHARBOR_PERF_UI_HEARTBEAT_NS": "10000000",
            "LUMAHARBOR_PERF_UI_MAX_FRAMES": "99"
        ]))

        XCTAssertEqual(parsed.outputURL.path, "/tmp/evidence.jsonl")
        XCTAssertEqual(parsed.recorderConfiguration.variant, "O")
        XCTAssertEqual(parsed.recorderConfiguration.buildIdentifier, "candidate-sha")
        XCTAssertEqual(parsed.recorderConfiguration.buildConfiguration, "Release")
        XCTAssertEqual(parsed.recorderConfiguration.fixtureIdentifier, "anonymous-fixture")
        XCTAssertEqual(parsed.recorderConfiguration.expectedHeartbeatIntervalNanoseconds, 10_000_000)
        XCTAssertEqual(parsed.recorderConfiguration.maximumFrameCount, 99)
    }

    func testJSONLWriterTruncatesOldDataAndWritesOneGesturePerLine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brush-ui-heartbeat-writer-\(UUID().uuidString)", isDirectory: true)
        let output = directory.appendingPathComponent("samples.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("stale\n".utf8).write(to: output)

        let writer = try BrushUIHeartbeatJSONLWriter(outputURL: output)
        var recorder = BrushUIHeartbeatRecorder(configuration: configuration)
        recorder.recordHeartbeat(atNanoseconds: 0)
        XCTAssertTrue(recorder.beginGesture(id: UUID(), kind: "paint", atNanoseconds: 0))
        recorder.recordHeartbeat(atNanoseconds: 10)
        XCTAssertTrue(recorder.requestGestureEnd(atNanoseconds: 11))
        XCTAssertTrue(recorder.markVisibleFrame(atNanoseconds: 15))
        recorder.recordHeartbeat(atNanoseconds: 20)
        let sample = try XCTUnwrap(recorder.completedSamples.only)

        try writer.append(sample)
        try writer.synchronize()

        let lines = try String(contentsOf: output, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].contains("stale"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(object["gestureKind"] as? String, "paint")
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
