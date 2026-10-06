import CoreGraphics
import Darwin
import Foundation
import ImageIO
import XCTest
@testable import RawProcessingCore

/// One real-RAW preview or full-resolution export sample per process. The
/// shell orchestrator controls B/O order and compiles both variants before any
/// timed sample.
final class BrushRawExportABBAHarnessTests: XCTestCase {
    func testMeasurementWaitsForOperationAndPublishedOutputValidation() async {
        let operationGate = AcceptanceGate()
        let validationGate = AcceptanceGate()
        let completed = AcceptanceCompletionFlag()

        let task = Task {
            _ = await BrushRawExportAcceptanceMeasurement.measure(
                operation: {
                    await operationGate.wait()
                    return 1
                },
                validate: { _ in
                    await validationGate.wait()
                }
            )
            await completed.markCompleted()
        }

        await waitUntil("operation to start") { await operationGate.started }
        let completedBeforeOperation = await completed.isCompleted
        XCTAssertFalse(completedBeforeOperation)
        await operationGate.release()
        await waitUntil("published output validation to start") { await validationGate.started }
        let completedBeforeValidation = await completed.isCompleted
        XCTAssertFalse(completedBeforeValidation)
        await validationGate.release()
        _ = await task.value
        let completedAfterValidation = await completed.isCompleted
        XCTAssertTrue(completedAfterValidation)
    }

    func testOptInProductionSample() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LUMAHARBOR_RUN_BRUSH_RAW_EXPORT_ABBA"] == "1" else {
            throw XCTSkip("brush RAW/export B/O acceptance is opt-in")
        }

        let variant = try XCTUnwrap(environment["LUMAHARBOR_BRUSH_VARIANT"])
        let productSHA = try XCTUnwrap(environment["LUMAHARBOR_BRUSH_PRODUCT_SHA"])
        let harnessSHA = try XCTUnwrap(environment["LUMAHARBOR_BRUSH_HARNESS_SHA"])
        let instrumentationDigest = try XCTUnwrap(
            environment["LUMAHARBOR_BRUSH_INSTRUMENTATION_DIGEST"]
        )
        let sourceKind = try XCTUnwrap(environment["LUMAHARBOR_BRUSH_SOURCE_KIND"])
        let operation = try XCTUnwrap(environment["LUMAHARBOR_BRUSH_OPERATION"])
        let scenario = try XCTUnwrap(environment["LUMAHARBOR_BRUSH_SCENARIO"])
        let order = try XCTUnwrap(Int(environment["LUMAHARBOR_BRUSH_ORDER"] ?? ""))
        let sampleOrdinal = try XCTUnwrap(
            Int(environment["LUMAHARBOR_BRUSH_SAMPLE_ORDINAL"] ?? "")
        )
        let maskCount = try XCTUnwrap(Int(environment["LUMAHARBOR_BRUSH_MASK_COUNT"] ?? ""))

        XCTAssertTrue(["B", "O"].contains(variant))
        XCTAssertTrue(["real-raw", "synthetic-24mp"].contains(sourceKind))
        XCTAssertTrue(["preview", "export"].contains(operation))
        XCTAssertTrue([0, 1, 10].contains(maskCount))

        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("BrushRawExportAcceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let sourceURL: URL
        let baseDecoder: any RawDecoding
        switch sourceKind {
        case "real-raw":
            sourceURL = URL(
                fileURLWithPath: try XCTUnwrap(environment["LUMAHARBOR_BRUSH_RAW_SOURCE"])
            )
            baseDecoder = CoreImageRawDecoder()
        case "synthetic-24mp":
            sourceURL = temporaryRoot.appendingPathComponent("synthetic.raw")
            try Data([0]).write(to: sourceURL)
            baseDecoder = SyntheticRawDecoder(pixelSize: CGSize(width: 6_000, height: 4_000))
        default:
            throw AcceptanceHarnessError.invalidConfiguration
        }
        let decodeRecorder = AcceptanceDecodeRecorder()
        let decoder: any RawDecoding = AcceptanceRecordingDecoder(
            base: baseDecoder,
            recorder: decodeRecorder
        )

        let sourceBefore = try sourceState(sourceURL)
        let metadata = try decoder.readMetadata(at: sourceURL)
        let nativeSize = CGSize(width: metadata.pixelWidth, height: metadata.pixelHeight)
        let masks = makeMasks(count: maskCount)

        let decodedSize: CGSize
        let outputSize: CGSize
        let durationSeconds: Double
        let timingBoundary: String
        let publishedFileValidated: Any

        switch operation {
        case "preview":
            guard sourceKind == "real-raw", ["cold", "warm", "changed"].contains(scenario) else {
                throw AcceptanceHarnessError.invalidConfiguration
            }
            let renderer = CoreImagePreviewRenderer(
                decoder: decoder,
                renderService: ImageRenderService(preferMetal: true)
            )
            let base = PhotoAdjustments(brushMasks: masks)
            let timed: PhotoAdjustments
            let warmup: PhotoAdjustments?
            switch scenario {
            case "cold":
                warmup = nil
                timed = base
            case "warm":
                warmup = base
                timed = base
            case "changed":
                warmup = base
                let exposure = sampleOrdinal.isMultiple(of: 2) ? 0.05 : -0.05
                timed = PhotoAdjustments(exposure: exposure, brushMasks: masks)
            default:
                throw AcceptanceHarnessError.invalidConfiguration
            }

            let subject = PreviewSubject(
                UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
            )
            if let warmup {
                _ = try await renderer.render(PreviewRequest(
                    subject: subject,
                    url: sourceURL,
                    adjustments: warmup,
                    targetPixelDimension: 1_600,
                    quality: .interactive
                ))
            }
            let measured = try await BrushRawExportAcceptanceMeasurement.measure(
                operation: {
                    try await renderer.render(PreviewRequest(
                        subject: subject,
                        url: sourceURL,
                        adjustments: timed,
                        targetPixelDimension: 1_600,
                        quality: .interactive
                    ))
                },
                validate: { image in
                    guard let actualDecodedSize = decodeRecorder.lastDecodedPixelSize,
                          image.pixelSize.width > 0, image.pixelSize.height > 0,
                          actualDecodedSize == image.pixelSize,
                          max(image.pixelSize.width, image.pixelSize.height) <= 1_600 else {
                        throw AcceptanceHarnessError.invalidPreview
                    }
                }
            )
            decodedSize = try XCTUnwrap(decodeRecorder.lastDecodedPixelSize)
            outputSize = measured.value.pixelSize
            durationSeconds = measured.durationSeconds
            timingBoundary = "submit-through-materialized-cgimage"
            publishedFileValidated = NSNull()

        case "export":
            guard scenario == "full-resolution", [1, 10].contains(maskCount) else {
                throw AcceptanceHarnessError.invalidConfiguration
            }
            let destination = temporaryRoot.appendingPathComponent("output", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let exporter = PhotoExporter(
                decoder: decoder,
                renderService: ImageRenderService(preferMetal: true)
            )
            let measured = try await BrushRawExportAcceptanceMeasurement.measure(
                operation: {
                    try await exporter.export(ExportRequest(
                        sourceURL: sourceURL,
                        adjustments: PhotoAdjustments(brushMasks: masks),
                        destinationDirectory: destination,
                        baseFilename: "acceptance-output",
                        format: .jpeg,
                        quality: 0.9,
                        exifRetentionPolicy: .removeAll
                    ))
                },
                validate: { outcome in
                    guard let actualDecodedSize = decodeRecorder.lastDecodedPixelSize,
                          [Int(actualDecodedSize.width), Int(actualDecodedSize.height)].sorted()
                            == [Int(nativeSize.width), Int(nativeSize.height)].sorted(),
                          outcome.byteCount > 0,
                          FileManager.default.fileExists(atPath: outcome.url.path),
                          let source = CGImageSourceCreateWithURL(outcome.url as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                          [image.width, image.height].sorted()
                            == [Int(nativeSize.width), Int(nativeSize.height)].sorted() else {
                        throw AcceptanceHarnessError.invalidPublishedExport
                    }
                }
            )
            decodedSize = try XCTUnwrap(decodeRecorder.lastDecodedPixelSize)
            outputSize = measured.value.pixelSize
            durationSeconds = measured.durationSeconds
            timingBoundary = "submit-through-export-return-and-published-image-reopen"
            publishedFileValidated = true

        default:
            throw AcceptanceHarnessError.invalidConfiguration
        }

        let sourceAfter = try sourceState(sourceURL)
        let record: [String: Any] = [
            "schemaVersion": 1,
            "productSHA": productSHA,
            "harnessSHA": harnessSHA,
            "instrumentationDigest": instrumentationDigest,
            "configuration": "release",
            "sourceKind": sourceKind,
            "operation": operation,
            "scenario": scenario,
            "variant": variant,
            "order": order,
            "sampleOrdinal": sampleOrdinal,
            "maskCount": maskCount,
            "nativeSize": jsonSize(nativeSize),
            "decodedSize": jsonSize(decodedSize),
            "outputSize": jsonSize(outputSize),
            "totalDurationSeconds": durationSeconds,
            "peakRSSBytes": try XCTUnwrap(peakRSSBytes),
            "timingBoundary": timingBoundary,
            "publishedFileValidated": publishedFileValidated,
            "sourceFingerprintUnchanged": sourceBefore == sourceAfter,
            "thermalState": thermalStateName,
            "result": "MEASURED",
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private func sourceState(_ url: URL) throws -> SourceState {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return SourceState(
            size: (attributes[.size] as? NSNumber)?.int64Value,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }

    private func jsonSize(_ size: CGSize) -> [String: Int] {
        ["width": Int(size.width.rounded()), "height": Int(size.height.rounded())]
    }

    private var thermalStateName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private var peakRSSBytes: Int64? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Int64(usage.ru_maxrss)
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
                    id: UUID(uuidString: String(
                        format: "00000000-0000-4000-8000-%012d",
                        strokeIndex + maskIndex * 10 + 1
                    ))!,
                    points: points,
                    size: 0.018,
                    feather: 0.25,
                    flow: 0.6,
                    density: 0.8
                )
            }
            return BrushMask(
                id: UUID(uuidString: String(
                    format: "00000000-0000-4000-9000-%012d",
                    maskIndex + 1
                ))!,
                name: "benchmark-\(maskIndex)",
                strokes: strokes,
                adjustments: BrushMaskPatch(exposure: maskIndex.isMultiple(of: 2) ? 0.25 : -0.2)
            )
        }
    }
}

private enum AcceptanceHarnessError: Error {
    case invalidConfiguration
    case invalidPreview
    case invalidPublishedExport
}

private struct SourceState: Equatable {
    let size: Int64?
    let modificationDate: Date?
}

private final class AcceptanceDecodeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDecodedPixelSize: CGSize?

    var lastDecodedPixelSize: CGSize? {
        lock.lock()
        defer { lock.unlock() }
        return storedDecodedPixelSize
    }

    func record(_ image: DecodedRawImage) {
        lock.lock()
        storedDecodedPixelSize = image.decodedPixelSize
        lock.unlock()
    }
}

private struct AcceptanceRecordingDecoder: RawDecoding {
    let base: any RawDecoding
    let recorder: AcceptanceDecodeRecorder

    var identifier: DecoderIdentifier { base.identifier }

    func supportsFile(at url: URL) -> Bool {
        base.supportsFile(at: url)
    }

    func readMetadata(at url: URL) throws -> RawMetadata {
        try base.readMetadata(at: url)
    }

    func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage {
        let image = try base.decode(request)
        recorder.record(image)
        return image
    }
}

private struct BrushRawExportAcceptanceMeasurement<Value> {
    let value: Value
    let durationSeconds: Double

    static func measure(
        operation: () async throws -> Value,
        validate: (Value) async throws -> Void
    ) async rethrows -> BrushRawExportAcceptanceMeasurement<Value> {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await operation()
        try await validate(value)
        let duration = start.duration(to: clock.now)
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        return BrushRawExportAcceptanceMeasurement(value: value, durationSeconds: seconds)
    }
}

private actor AcceptanceGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private var released = false

    func wait() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor AcceptanceCompletionFlag {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}
