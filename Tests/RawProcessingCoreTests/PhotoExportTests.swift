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

/// Records every decode request an exporter under test made, so a test can
/// assert *how* the export decoded (Phase 1 Task 4: "ensure export renders
/// from full-resolution source, not preview cache") without depending on
/// timing. A plain class, not the `struct` decoder itself, since the decoder
/// is handed to the exporter by value and a struct can't accumulate state
/// across calls that way.
final class DecodeRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [RawDecodeRequest] = []

    func record(_ request: RawDecodeRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
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
    /// EXIF fields the decode reports, beyond pixel size -- `nil` keeps the
    /// old size-only default so every pre-existing test is unaffected.
    var metadataOverride: RawMetadata?
    var recorder: DecodeRequestRecorder?

    /// Built directly rather than via `readMetadata`, so gating the metadata
    /// stage doesn't also stall the decode stage.
    private var syntheticMetadata: RawMetadata {
        if var override = metadataOverride {
            override.pixelWidth = Int(pixelSize.width)
            override.pixelHeight = Int(pixelSize.height)
            return override
        }
        return RawMetadata(pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height))
    }

    func supportsFile(at url: URL) -> Bool { failure == nil }

    func readMetadata(at url: URL) throws -> RawMetadata {
        metadataGate?.enterAndWait(ignoringCancellation: true)
        if let failure { throw failure }
        return syntheticMetadata
    }

    func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage {
        recorder?.record(request)
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
final class PhotoExportTests: XCTestCase {
    private var directory: URL!
    private var sourceURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PhotoExportTests-\(UUID().uuidString)", isDirectory: true)
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
        adjustments: PhotoAdjustments = .neutral,
        format: ExportFormat = .jpeg,
        quality: Double = 0.9,
        bitDepth: ExportBitDepth = .eightBit,
        maximumWidth: Int? = nil,
        maximumHeight: Int? = nil,
        dpi: Double? = nil,
        exifRetentionPolicy: ExifRetentionPolicy = .preserveAll
    ) -> ExportRequest {
        ExportRequest(
            sourceURL: sourceURL,
            adjustments: adjustments,
            destinationDirectory: destination ?? directory,
            baseFilename: baseFilename,
            format: format,
            quality: quality,
            bitDepth: bitDepth,
            maximumWidth: maximumWidth,
            maximumHeight: maximumHeight,
            dpi: dpi,
            exifRetentionPolicy: exifRetentionPolicy
        )
    }

    private func leftoverTemporaryFiles() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".lumaharbor-export-") || $0.hasSuffix(".tmp") }
    }

    // MARK: - Happy path

    func testExportWritesAJPEGAtFullResolution() async throws {
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
        let outcome = try await exporter.export(makeRequest())

        XCTAssertEqual(outcome.url.lastPathComponent, "DSC0001.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.url.path))
        XCTAssertGreaterThan(outcome.byteCount, 0)
        // Spec §6.3: the export re-decodes the original, it doesn't reuse the
        // screen-sized preview.
        XCTAssertEqual(outcome.pixelSize, CGSize(width: 64, height: 48))
    }

    func testExportedFileIsARealJPEG() async throws {
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
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
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
        let outcome = try await exporter.export(makeRequest())

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let colorSpace = try XCTUnwrap(image.colorSpace)
        let name = colorSpace.name as String?
        XCTAssertEqual(
            name, CGColorSpace.sRGB as String,
            "Expected an sRGB profile, got \(name ?? "none")"
        )
    }

    func testAdjustmentsReachTheExportedPixels() async throws {
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
        let plain = try await exporter.export(makeRequest(baseFilename: "plain"))
        let bright = try await exporter.export(
            makeRequest(baseFilename: "bright", adjustments: PhotoAdjustments(exposure: 2))
        )

        let plainSize = try Data(contentsOf: plain.url).count
        let brightSize = try Data(contentsOf: bright.url).count
        XCTAssertNotEqual(plainSize, brightSize, "The adjustment never reached the encoder")
    }

    func testLeavesNoTemporaryFileBehindOnSuccess() async throws {
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
        _ = try await exporter.export(makeRequest())
        let leftovers = try leftoverTemporaryFiles()
        XCTAssertEqual(leftovers, [])
    }

    // MARK: - Collisions

    func testASecondExportGetsASerialSuffixRatherThanOverwriting() async throws {
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
        let first = try await exporter.export(makeRequest())
        let firstBytes = try Data(contentsOf: first.url)

        let second = try await exporter.export(makeRequest())
        XCTAssertEqual(second.url.lastPathComponent, "DSC0001-1.jpg")

        // Spec §6.3: silent overwriting is forbidden.
        let firstStillThere = try Data(contentsOf: first.url)
        XCTAssertEqual(firstStillThere, firstBytes)
    }

    func testCollisionCountingContinuesPastTheFirstSuffix() async throws {
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
        _ = try await exporter.export(makeRequest())
        _ = try await exporter.export(makeRequest())
        let third = try await exporter.export(makeRequest())
        XCTAssertEqual(third.url.lastPathComponent, "DSC0001-2.jpg")
    }

    // MARK: - Cancellation

    func testCancellingAnExportStopsItAndRemovesThePartialOutput() async throws {
        let gate = DecodeGate()
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder(gate: gate))

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
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder(gate: gate))

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
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder(metadataGate: metadataGate))

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
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder(metadataGate: metadataGate))

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

        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
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
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
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
        let exporter = PhotoExporter(
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
            .rendering(.insufficientDiskSpace),
            .formatNotSupported(.heic)
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error)")
            XCTAssertNotNil(error.recoverySuggestion, "\(error)")
        }
    }

    // MARK: - Format-aware export (Phase 1 Task 4)

    func testExportsAsPNG() async throws {
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
        let outcome = try await exporter.export(makeRequest(format: .png))

        XCTAssertEqual(outcome.url.lastPathComponent, "DSC0001.png")
        let data = try Data(contentsOf: outcome.url)
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "Missing PNG signature")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
    }

    func testExportsAsTIFF() async throws {
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
        let outcome = try await exporter.export(makeRequest(format: .tiff))

        XCTAssertEqual(outcome.url.lastPathComponent, "DSC0001.tiff")
        let data = try Data(contentsOf: outcome.url)
        let isLittleEndianTIFF = Array(data.prefix(4)) == [0x49, 0x49, 0x2A, 0x00]
        let isBigEndianTIFF = Array(data.prefix(4)) == [0x4D, 0x4D, 0x00, 0x2A]
        XCTAssertTrue(isLittleEndianTIFF || isBigEndianTIFF, "Missing TIFF signature")
    }

    func testExportsAsHEIC() async throws {
        try XCTSkipUnless(ExportFormat.heic.isSupported(), "This machine's ImageIO build can't encode HEIC")
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
        let outcome = try await exporter.export(makeRequest(format: .heic))

        XCTAssertEqual(outcome.url.lastPathComponent, "DSC0001.heic")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, ExportFormat.heic.utTypeIdentifier)
    }

    /// Existing JPEG behaviour must survive the generalization untouched --
    /// this is the same assertion `testExportWritesAJPEGAtFullResolution`
    /// already makes with an explicit `format: .jpeg` request instead of
    /// relying only on the default.
    func testExplicitJPEGFormatMatchesTheDefaultBehaviour() async throws {
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
        let outcome = try await exporter.export(makeRequest(format: .jpeg))
        XCTAssertEqual(outcome.url.lastPathComponent, "DSC0001.jpg")
        let data = try Data(contentsOf: outcome.url)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
    }

    // MARK: - Capability guard

    /// Plan: "if a platform cannot encode one format, show disabled/
    /// unsupported UI instead of pretending success." The exporter itself
    /// must refuse before touching disk, not fail midway or silently
    /// downgrade to another format.
    func testUnsupportedFormatIsRejectedBeforeWritingAnything() async throws {
        let exporter = PhotoExporter(
            decoder: SyntheticRawDecoder(),
            encodableTypeIdentifiers: { [] }
        )

        do {
            _ = try await exporter.export(makeRequest(format: .heic))
            XCTFail("An unsupported format must not report success")
        } catch let error as ExportError {
            guard case .formatNotSupported(.heic) = error else {
                return XCTFail("Expected .formatNotSupported(.heic), got \(error)")
            }
        }

        // `directory` also holds the synthetic source fixture written in
        // `setUpWithError` -- the guard must reject before writing an
        // *export* output, not before the directory exists at all.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents, [sourceURL.lastPathComponent], "The capability guard must reject before writing anything: \(contents)")
    }

    func testASupportedFormatIsUnaffectedByAnUnrelatedCapabilityGap() async throws {
        // JPEG stays supported even when the injected capability set is
        // missing HEIC -- the guard checks the *requested* format only.
        let exporter = PhotoExporter(
            decoder: SyntheticRawDecoder(),
            encodableTypeIdentifiers: { [ExportFormat.jpeg.utTypeIdentifier] }
        )
        let outcome = try await exporter.export(makeRequest(format: .jpeg))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.url.path))
    }

    // MARK: - Resizing

    func testMaximumWidthResizesTheExportedPixels() async throws {
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder(pixelSize: CGSize(width: 4_000, height: 3_000)))
        let outcome = try await exporter.export(makeRequest(format: .png, maximumWidth: 2_000))

        XCTAssertEqual(outcome.pixelSize, CGSize(width: 2_000, height: 1_500))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 2_000)
        XCTAssertEqual(image.height, 1_500)
    }

    func testNoResizeCapKeepsTheFullNativeSize() async throws {
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder(pixelSize: CGSize(width: 4_000, height: 3_000)))
        let outcome = try await exporter.export(makeRequest(format: .png))
        XCTAssertEqual(outcome.pixelSize, CGSize(width: 4_000, height: 3_000))
    }

    // MARK: - DPI metadata

    func testDPIIsWrittenToTheExportedFile() async throws {
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
        let outcome = try await exporter.export(makeRequest(format: .png, dpi: 300))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyDPIWidth] as? Double, 300)
        XCTAssertEqual(properties[kCGImagePropertyDPIHeight] as? Double, 300)
    }

    func testNoDPIRequestLeavesTheEncodersOwnDefault() async throws {
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
        let outcome = try await exporter.export(makeRequest(format: .png, dpi: nil))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        // Not asserting a specific fallback value (that's the encoder's own
        // business) -- only that requesting no DPI didn't crash and still
        // produced a valid, readable file.
        XCTAssertNotNil(properties[kCGImagePropertyPixelWidth])
    }

    // MARK: - Bit depth

    func testSixteenBitTIFFProducesASixteenBitPerChannelFile() async throws {
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
        let outcome = try await exporter.export(makeRequest(format: .tiff, bitDepth: .sixteenBit))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.bitsPerComponent, 16)
    }

    func testEightBitTIFFProducesAnEightBitPerChannelFile() async throws {
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
        let outcome = try await exporter.export(makeRequest(format: .tiff, bitDepth: .eightBit))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.bitsPerComponent, 8)
    }

    /// Bit depth only means something for TIFF in this foundation version --
    /// requesting 16-bit against a JPEG must not crash or change JPEG's own
    /// (always 8-bit) output.
    func testBitDepthIsIgnoredForFormatsThatDontSupportAChoice() async throws {
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder())
        let outcome = try await exporter.export(makeRequest(format: .jpeg, bitDepth: .sixteenBit))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.bitsPerComponent, 8)
    }

    // MARK: - EXIF retention

    func testPreserveAllWritesCameraMetadataIntoTheExportedFile() async throws {
        let decoder = SyntheticRawDecoder(metadataOverride: RawMetadata(cameraMake: "SONY", cameraModel: "ILCE-7M4"))
        let exporter = PhotoExporter(decoder: decoder)
        let outcome = try await exporter.export(makeRequest(format: .tiff, exifRetentionPolicy: .preserveAll))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let tiff = try XCTUnwrap(properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        XCTAssertEqual(tiff[kCGImagePropertyTIFFMake] as? String, "SONY")
    }

    func testRemoveAllStripsCameraMetadataFromTheExportedFile() async throws {
        let decoder = SyntheticRawDecoder(metadataOverride: RawMetadata(cameraMake: "SONY", cameraModel: "ILCE-7M4"))
        let exporter = PhotoExporter(decoder: decoder)
        let outcome = try await exporter.export(makeRequest(format: .tiff, exifRetentionPolicy: .removeAll))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake], "removeAll must not leak the camera make into the exported file")
    }

    /// P1 fix (independent review finding): `SyntheticRawDecoder`'s
    /// `metadataOverride` stands in for the *source RAW file's own*
    /// un-rotated EXIF orientation tag (e.g. 6 for a portrait shot) --
    /// exactly what `CoreImageRawDecoder.decode(_:)` reads straight off
    /// disk, independent of what `CIRAWFilter.outputImage` itself does to
    /// the pixels. Real `CIRAWFilter` output is already rotated to display
    /// orientation, so writing that same source tag onto the exported
    /// (already-rotated) pixels would tell any EXIF-aware viewer to rotate
    /// an already-upright image a second time. Neither `preserveAll` nor
    /// `partial` may let that tag reach the exported file. Asserts "absent
    /// or 1 (normal)" rather than strictly absent: some encoders (TIFF,
    /// confirmed by hand) stamp their own default orientation of 1 even when
    /// the caller writes nothing at all -- 1 is exactly the semantically
    /// correct "no further rotation needed" value for already-oriented
    /// pixels, so it is an acceptable outcome, unlike the source's actual 6.
    func testPreserveAllNeverWritesTheSourcesOrientationTagIntoTheExportedFile() async throws {
        let decoder = SyntheticRawDecoder(metadataOverride: RawMetadata(orientation: 6))
        let exporter = PhotoExporter(decoder: decoder)
        let outcome = try await exporter.export(makeRequest(format: .tiff, exifRetentionPolicy: .preserveAll))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        assertExportedOrientationIsNeverTheSourcesNonNormalValue(properties)
    }

    func testPartialNeverWritesTheSourcesOrientationTagIntoTheExportedFile() async throws {
        let decoder = SyntheticRawDecoder(metadataOverride: RawMetadata(orientation: 6))
        let exporter = PhotoExporter(decoder: decoder)
        let outcome = try await exporter.export(makeRequest(format: .tiff, exifRetentionPolicy: .partial))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        assertExportedOrientationIsNeverTheSourcesNonNormalValue(properties)
    }

    /// Regression guard: `removeAll` already happened to avoid this bug (it
    /// drops all metadata including orientation), and the P1 fix must not
    /// change that.
    func testRemoveAllStillNeverWritesOrientation() async throws {
        let decoder = SyntheticRawDecoder(metadataOverride: RawMetadata(orientation: 6))
        let exporter = PhotoExporter(decoder: decoder)
        let outcome = try await exporter.export(makeRequest(format: .tiff, exifRetentionPolicy: .removeAll))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        assertExportedOrientationIsNeverTheSourcesNonNormalValue(properties)
    }

    private func assertExportedOrientationIsNeverTheSourcesNonNormalValue(
        _ properties: [CFString: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let value = properties[kCGImagePropertyOrientation] as? Int
        XCTAssertTrue(
            value == nil || value == 1,
            "exported orientation must be absent or 1 (normal), never the source RAW's own tag -- got \(String(describing: value))",
            file: file, line: line
        )
    }

    // MARK: - Full resolution, not the preview cache

    func testExportAlwaysRequestsAFullQualityDecodeRegardlessOfPreviewState() async throws {
        let recorder = DecodeRequestRecorder()
        let exporter = PhotoExporter(decoder: SyntheticRawDecoder(recorder: recorder))
        _ = try await exporter.export(makeRequest())

        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.quality, .full, "Export must never reuse a preview-sized decode")
    }
}
