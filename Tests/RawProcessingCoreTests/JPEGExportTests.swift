import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import RawProcessingCore

/// A decode that can be held open, so cancellation is observable without
/// depending on how long a real 24 MP decode happens to take.
final class DecodeGate: @unchecked Sendable {
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

    /// Blocks the calling (detached) thread until released or cancelled.
    /// Polling rather than a semaphore so `Task.isCancelled` is observed —
    /// which is the behaviour under test.
    ///
    /// `ignoringCancellation` models the decoder that *doesn't* poll: it runs to
    /// completion and hands back a perfectly good value even though the caller
    /// gave up. The exporter has to cope with that on its own.
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

/// Stands in for `CoreImageRawDecoder` so export behaviour can be tested
/// without a Sony `.ARW` and without Apple's RAW decoder.
struct SyntheticRawDecoder: RawDecoding {
    let identifier = DecoderIdentifier(kind: "synthetic", version: "test")
    var pixelSize = CGSize(width: 64, height: 48)
    /// Holds the decode stage open.
    var gate: DecodeGate?
    /// Holds `readMetadata` open — the export's *second* stage, which runs after
    /// the temp file is already on disk. Deliberately deaf to cancellation.
    var metadataGate: DecodeGate?
    var failure: RawDecodingError?

    /// Built directly rather than via `readMetadata`, so gating the metadata
    /// stage doesn't also stall the decode stage.
    private var syntheticMetadata: RawMetadata {
        RawMetadata(pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height))
    }

    func supportsFile(at url: URL) -> Bool { failure == nil }

    func readMetadata(at url: URL) throws -> RawMetadata {
        metadataGate?.enterAndWait(ignoringCancellation: true)
        if let failure { throw failure }
        return syntheticMetadata
    }

    func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage {
        gate?.enterAndWait()
        try Task.checkCancellation()
        if let failure { throw failure }

        let image = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6))
            .cropped(to: CGRect(origin: .zero, size: pixelSize))
        return DecodedRawImage(
            image: image,
            nativePixelSize: pixelSize,
            decodedPixelSize: pixelSize,
            baselineTemperature: 5_500,
            baselineTint: 0,
            metadata: syntheticMetadata
        )
    }
}

/// Spec §6.3 and §12.2: full-resolution export, serial-numbered filenames,
/// cancellation, and no partial output left behind.
final class JPEGExportTests: XCTestCase {
    private var directory: URL!
    private var sourceURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JPEGExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sourceURL = directory.appendingPathComponent("DSC0001.ARW")
        try Data(repeating: 0x22, count: 256).write(to: sourceURL)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    private func makeRequest(
        destination: URL? = nil,
        baseFilename: String = "DSC0001",
        adjustments: PhotoAdjustments = .neutral
    ) -> ExportRequest {
        ExportRequest(
            sourceURL: sourceURL,
            adjustments: adjustments,
            destinationDirectory: destination ?? directory,
            baseFilename: baseFilename,
            jpegQuality: 0.9
        )
    }

    private func leftoverTemporaryFiles() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".lumaharbor-export-") || $0.hasSuffix(".tmp") }
    }

    // MARK: - Happy path

    func testExportWritesAJPEGAtFullResolution() async throws {
        let exporter = JPEGExporter(decoder: SyntheticRawDecoder())
        let outcome = try await exporter.export(makeRequest())

        XCTAssertEqual(outcome.url.lastPathComponent, "DSC0001.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.url.path))
        XCTAssertGreaterThan(outcome.byteCount, 0)
        // Spec §6.3: the export re-decodes the original, it doesn't reuse the
        // screen-sized preview.
        XCTAssertEqual(outcome.pixelSize, CGSize(width: 64, height: 48))
    }

    func testExportedFileIsARealJPEG() async throws {
        let exporter = JPEGExporter(decoder: SyntheticRawDecoder())
        let outcome = try await exporter.export(makeRequest())

        let data = try Data(contentsOf: outcome.url)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "Missing JPEG start-of-image marker")

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
    }

    func testExportedFileIsTaggedSRGB() async throws {
        // Spec §13.7: the exported JPEG must carry an sRGB profile.
        let exporter = JPEGExporter(decoder: SyntheticRawDecoder())
        let outcome = try await exporter.export(makeRequest())

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let colorSpace = try XCTUnwrap(image.colorSpace)
        let name = colorSpace.name as String?
        XCTAssertNotNil(name)
        XCTAssertTrue(
            (name ?? "").contains("sRGB"),
            "Expected an sRGB profile, got \(name ?? "none")"
        )
    }

    func testAdjustmentsReachTheExportedPixels() async throws {
        let exporter = JPEGExporter(decoder: SyntheticRawDecoder())
        let plain = try await exporter.export(makeRequest(baseFilename: "plain"))
        let bright = try await exporter.export(
            makeRequest(baseFilename: "bright", adjustments: PhotoAdjustments(exposure: 2))
        )

        let plainSize = try Data(contentsOf: plain.url).count
        let brightSize = try Data(contentsOf: bright.url).count
        XCTAssertNotEqual(plainSize, brightSize, "The adjustment never reached the encoder")
    }

    func testLeavesNoTemporaryFileBehindOnSuccess() async throws {
        let exporter = JPEGExporter(decoder: SyntheticRawDecoder())
        _ = try await exporter.export(makeRequest())
        let leftovers = try leftoverTemporaryFiles()
        XCTAssertEqual(leftovers, [])
    }

    // MARK: - Collisions

    func testASecondExportGetsASerialSuffixRatherThanOverwriting() async throws {
        let exporter = JPEGExporter(decoder: SyntheticRawDecoder())
        let first = try await exporter.export(makeRequest())
        let firstBytes = try Data(contentsOf: first.url)

        let second = try await exporter.export(makeRequest())
        XCTAssertEqual(second.url.lastPathComponent, "DSC0001-1.jpg")

        // Spec §6.3: silent overwriting is forbidden.
        let firstStillThere = try Data(contentsOf: first.url)
        XCTAssertEqual(firstStillThere, firstBytes)
    }

    func testCollisionCountingContinuesPastTheFirstSuffix() async throws {
        let exporter = JPEGExporter(decoder: SyntheticRawDecoder())
        _ = try await exporter.export(makeRequest())
        _ = try await exporter.export(makeRequest())
        let third = try await exporter.export(makeRequest())
        XCTAssertEqual(third.url.lastPathComponent, "DSC0001-2.jpg")
    }

    // MARK: - Cancellation

    func testCancellingAnExportStopsItAndRemovesThePartialOutput() async throws {
        let gate = DecodeGate()
        let exporter = JPEGExporter(decoder: SyntheticRawDecoder(gate: gate))

        let task = Task { try await exporter.export(makeRequest()) }
        await waitUntil("the decode to start") { gate.started > 0 }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled export should not report success")
        } catch {
            // Either surfaces; both mean the work stopped.
            let isCancellation = error is CancellationError
                || (error as? ExportError) == .cancelled
                || (error as? ExportError) == .decoding(.cancelled)
            XCTAssertTrue(isCancellation, "Expected a cancellation, got \(error)")
        }

        // Spec §6.3: no half-written .jpg that looks finished, no stray temp.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(
            contents.contains { $0.hasSuffix(".jpg") },
            "A cancelled export left output behind: \(contents)"
        )
        let leftovers = try leftoverTemporaryFiles()
        XCTAssertEqual(leftovers, [])
    }

    func testCancellationActuallyInterruptsTheDecode() async throws {
        // `Task.detached` doesn't inherit cancellation; this is the regression
        // guard for the bridge that makes it propagate. Without it the export
        // would run to completion and this test would time out on the gate.
        let gate = DecodeGate()
        let exporter = JPEGExporter(decoder: SyntheticRawDecoder(gate: gate))

        let started = Date()
        let task = Task { try await exporter.export(makeRequest()) }
        await waitUntil("the decode to start") { gate.started > 0 }
        task.cancel()
        _ = try? await task.value

        XCTAssertLessThan(
            Date().timeIntervalSince(started), 4,
            "The export ignored cancellation and waited out the gate"
        )
    }

    func testCancellingDuringTheMetadataReadStillLosesTheRename() async throws {
        // Regression guard for the window between "temp file written" and
        // "rename". The decode stage is ungated here, so it finishes and the
        // JPEG is already on disk as a temp file; the metadata read is then held
        // open by a gate that ignores cancellation, exactly like a decoder that
        // never polls. It hands back a valid value after the caller has given
        // up, and the export must still refuse to publish the .jpg.
        let metadataGate = DecodeGate()
        let exporter = JPEGExporter(decoder: SyntheticRawDecoder(metadataGate: metadataGate))

        let task = Task { try await exporter.export(makeRequest()) }

        // Reaching the metadata gate is proof the decode stage already
        // completed — no sleeping, no guessing at timings.
        await waitUntil("the metadata read to start") { metadataGate.started > 0 }

        task.cancel()
        metadataGate.release()

        do {
            _ = try await task.value
            XCTFail("A cancelled export must not report success")
        } catch {
            XCTAssertEqual(error as? ExportError, .cancelled)
        }

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(
            contents.contains { $0.hasSuffix(".jpg") },
            "Cancellation lost the race against the rename: \(contents)"
        )
        let leftovers = try leftoverTemporaryFiles()
        XCTAssertEqual(leftovers, [], "The temp file outlived the cancelled export")
    }

    func testAnUncancelledExportStillCompletesWhenTheMetadataGateIsReleased() async throws {
        // The mirror image of the test above: same gated metadata stage, no
        // cancellation, so the rename must go through. Without this, the test
        // above would still pass if the exporter simply never published.
        let metadataGate = DecodeGate()
        let exporter = JPEGExporter(decoder: SyntheticRawDecoder(metadataGate: metadataGate))

        let task = Task { try await exporter.export(makeRequest()) }
        await waitUntil("the metadata read to start") { metadataGate.started > 0 }
        metadataGate.release()

        let outcome = try await task.value
        XCTAssertEqual(outcome.url.lastPathComponent, "DSC0001.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.url.path))
        let leftovers = try leftoverTemporaryFiles()
        XCTAssertEqual(leftovers, [])
    }

    // MARK: - Failures

    func testAReadOnlyDestinationIsRefusedUpFront() async throws {
        try XCTSkipUnless(getuid() != 0, "Test must not run as root")

        let exporter = JPEGExporter(decoder: SyntheticRawDecoder())
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o555)],
            ofItemAtPath: directory.path
        )

        do {
            _ = try await exporter.export(makeRequest())
            XCTFail("Exporting to a read-only folder should have thrown")
        } catch let error as ExportError {
            guard case .destinationNotWritable = error else {
                return XCTFail("Expected .destinationNotWritable, got \(error)")
            }
            XCTAssertNotNil(error.errorDescription)
            XCTAssertNotNil(error.recoverySuggestion)
        }
    }

    func testAMissingDestinationIsReportedAsUnavailable() async throws {
        let exporter = JPEGExporter(decoder: SyntheticRawDecoder())
        let missing = directory.appendingPathComponent("NotMounted", isDirectory: true)

        do {
            _ = try await exporter.export(makeRequest(destination: missing))
            XCTFail("Exporting into a missing folder should have thrown")
        } catch let error as ExportError {
            guard case .destinationUnavailable = error else {
                return XCTFail("Expected .destinationUnavailable, got \(error)")
            }
        }
    }

    func testADecodeFailureIsSurfacedAndLeavesNothingBehind() async throws {
        let exporter = JPEGExporter(
            decoder: SyntheticRawDecoder(failure: .corruptedFile(path: "/tmp/x.ARW"))
        )

        do {
            _ = try await exporter.export(makeRequest())
            XCTFail("A corrupt source should have thrown")
        } catch let error as ExportError {
            guard case .decoding = error else {
                return XCTFail("Expected .decoding, got \(error)")
            }
        }

        let leftovers = try leftoverTemporaryFiles()
        XCTAssertEqual(leftovers, [])
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(contents.contains { $0.hasSuffix(".jpg") })
    }

    func testEveryExportErrorOffersANextStep() {
        let errors: [ExportError] = [
            .destinationNotWritable(path: "/Volumes/SSD"),
            .destinationUnavailable(path: "/Volumes/SSD"),
            .couldNotFindUniqueName(baseName: "DSC0001"),
            .insufficientDiskSpace,
            .decoding(.corruptedFile(path: "/tmp/x.ARW")),
            .rendering(.insufficientDiskSpace)
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error)")
            XCTAssertNotNil(error.recoverySuggestion, "\(error)")
        }
    }
}
