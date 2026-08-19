import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Acceptance tests against real camera RAW files.
///
/// Spec §12.3 forbids committing large private samples, so the fixtures live
/// outside the repository and the whole suite skips unless you point it at
/// them:
///
///     LUMAHARBOR_RAW_FIXTURE_DIR=/Volumes/SSD/Fixtures swift test
///
/// Sony `.ARW` is the MVP's required format (spec §13.7). Everything here needs
/// Apple's RAW decoder, so these are the tests that must be run on an Apple
/// Silicon Mac with full Xcode before the MVP can be called done — a green run
/// on a Command Line Tools x86_64 host proves nothing about the real target.
final class RawFixtureTests: TemporaryDirectoryTestCase {
    static let fixtureDirectoryEnvironmentKey = "LUMAHARBOR_RAW_FIXTURE_DIR"

    private var fixtures: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()

        guard let path = ProcessInfo.processInfo
            .environment[Self.fixtureDirectoryEnvironmentKey], !path.isEmpty else {
            throw XCTSkip(
                "Set \(Self.fixtureDirectoryEnvironmentKey) to a folder of camera RAW files "
                + "to run the fixture suite. Private samples must never be committed."
            )
        }

        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("\(Self.fixtureDirectoryEnvironmentKey) points at \(path), which doesn't exist.")
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        fixtures = contents
            .filter { CoreImageRawDecoder.candidateFileExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !fixtures.isEmpty else {
            throw XCTSkip("No RAW files found in \(path).")
        }
    }

    private var sonyFixtures: [URL] {
        fixtures.filter { $0.pathExtension.lowercased() == "arw" }
    }

    private func firstSonyFixture() throws -> URL {
        guard let url = sonyFixtures.first else {
            throw XCTSkip("No Sony .ARW fixture present; it is the MVP's required format.")
        }
        return url
    }

    // MARK: - Decoding

    func testEveryFixtureDecodes() throws {
        let decoder = CoreImageRawDecoder()
        for url in fixtures {
            XCTAssertTrue(
                decoder.supportsFile(at: url),
                "\(url.lastPathComponent) isn't supported by this macOS RAW decoder"
            )
            let decoded = try decoder.decode(
                RawDecodeRequest(url: url, quality: .thumbnail(maximumPixelDimension: 512))
            )
            XCTAssertGreaterThan(decoded.nativePixelSize.width, 0, url.lastPathComponent)
            XCTAssertGreaterThan(decoded.nativePixelSize.height, 0, url.lastPathComponent)
        }
    }

    func testSonyArwReportsPlausibleMetadata() throws {
        let url = try firstSonyFixture()
        let metadata = try CoreImageRawDecoder().readMetadata(at: url)

        XCTAssertGreaterThan(metadata.pixelWidth, 1_000)
        XCTAssertGreaterThan(metadata.pixelHeight, 1_000)
        XCTAssertNotNil(metadata.captureDate, "Expected EXIF DateTimeOriginal")
        XCTAssertEqual(metadata.cameraMake?.uppercased(), "SONY")
        XCTAssertNotNil(metadata.cameraModel)
    }

    func testPreviewDecodeHonoursTheRequestedSize() throws {
        // Spec §9: previews decode at display size, not native resolution.
        let url = try firstSonyFixture()
        let decoder = CoreImageRawDecoder()

        let preview = try decoder.decode(
            RawDecodeRequest(url: url, quality: .interactive(maximumPixelDimension: 1_024))
        )
        let longestEdge = max(preview.decodedPixelSize.width, preview.decodedPixelSize.height)
        XCTAssertLessThanOrEqual(longestEdge, 1_100, "Preview came back far larger than requested")
        XCTAssertGreaterThan(
            max(preview.nativePixelSize.width, preview.nativePixelSize.height),
            longestEdge,
            "A 24 MP RAW should be bigger than its 1024px preview"
        )
    }

    func testFullDecodeReturnsNativeResolution() throws {
        let url = try firstSonyFixture()
        let decoded = try CoreImageRawDecoder().decode(RawDecodeRequest(url: url, quality: .full))

        // CIRAWFilter.nativeSize ignores the orientation property, but the
        // decoded output's extent respects it, so a portrait-tagged fixture
        // (EXIF orientation 8, confirmed via CIRAWFilter debug output on
        // _DSC1896.ARW: nativeSize=6000x4000, outputExtent=4000x6000) swaps
        // axes here. Compare the pair rather than each side.
        let decodedPair = [decoded.decodedPixelSize.width, decoded.decodedPixelSize.height].sorted()
        let nativePair = [decoded.nativePixelSize.width, decoded.nativePixelSize.height].sorted()
        XCTAssertEqual(decodedPair[0], nativePair[0], accuracy: 2)
        XCTAssertEqual(decodedPair[1], nativePair[1], accuracy: 2)
    }

    func testWhiteBalanceOffsetChangesTheRender() throws {
        let url = try firstSonyFixture()
        let decoder = CoreImageRawDecoder()
        let renderer = ImageRenderService()

        let asShot = try decoder.decode(
            RawDecodeRequest(url: url, quality: .thumbnail(maximumPixelDimension: 256))
        )
        let warmed = try decoder.decode(RawDecodeRequest(
            url: url,
            quality: .thumbnail(maximumPixelDimension: 256),
            whiteBalance: RawWhiteBalance(temperatureOffsetKelvin: 3_000, tintOffset: 0)
        ))

        XCTAssertEqual(asShot.baselineTemperature, warmed.baselineTemperature, accuracy: 0.5)
        let plain = try renderer.jpegData(from: asShot.image, quality: 0.9)
        let shifted = try renderer.jpegData(from: warmed.image, quality: 0.9)
        XCTAssertNotEqual(plain, shifted, "The temperature offset never reached the decoder")
    }

    // MARK: - Export

    func testFullResolutionExportMatchesTheSourceDimensions() async throws {
        // Spec §13.7: export from the full-resolution RAW, tagged sRGB.
        let url = try firstSonyFixture()
        let destination = try makeSubdirectory("Exports")
        let metadata = try CoreImageRawDecoder().readMetadata(at: url)

        let exporter = JPEGExporter()
        let outcome = try await exporter.export(ExportRequest(
            sourceURL: url,
            adjustments: PhotoAdjustments(exposure: 0.3, contrast: 15, vibrance: 20),
            destinationDirectory: destination,
            baseFilename: url.deletingPathExtension().lastPathComponent,
            jpegQuality: 0.9
        ))

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(outcome.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        // Orientation may swap the axes, so compare the pair rather than each side.
        let exported = [image.width, image.height].sorted()
        let expected = [metadata.pixelWidth, metadata.pixelHeight].sorted()
        XCTAssertEqual(exported, expected, "Export was not full resolution")

        let colorSpace = try XCTUnwrap(image.colorSpace)
        XCTAssertEqual(
            colorSpace.name as String?,
            CGColorSpace.sRGB as String,
            "Expected an sRGB profile, got \((colorSpace.name as String?) ?? "none")"
        )
    }

    func testExportingNeverModifiesTheOriginal() async throws {
        // Spec §13.6 — the promise the whole non-destructive design rests on.
        let url = try firstSonyFixture()
        let destination = try makeSubdirectory("Exports")

        let fingerprintBefore = try FingerprintCalculator.fingerprint(forFileAt: url)
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: url.path)

        _ = try await JPEGExporter().export(ExportRequest(
            sourceURL: url,
            adjustments: PhotoAdjustments(exposure: 1),
            destinationDirectory: destination,
            baseFilename: "roundtrip",
            jpegQuality: 0.8
        ))

        let fingerprintAfter = try FingerprintCalculator.fingerprint(forFileAt: url)
        let attributesAfter = try FileManager.default.attributesOfItem(atPath: url.path)

        XCTAssertEqual(fingerprintBefore, fingerprintAfter)
        XCTAssertEqual(
            attributesAfter[.modificationDate] as? Date,
            attributesBefore[.modificationDate] as? Date
        )
    }

    // MARK: - Preview scheduling on real files

    func testPreviewSchedulerDeliversARenderedFrameForARealRaw() async throws {
        let url = try firstSonyFixture()
        let scheduler = PreviewScheduler(renderer: CoreImagePreviewRenderer())
        let subject = PreviewSubject(UUID())

        let token = await scheduler.submit(PreviewRequest(
            subject: subject,
            url: url,
            adjustments: PhotoAdjustments(exposure: 0.5),
            targetPixelDimension: 800,
            quality: .interactive
        ))

        for await event in scheduler.events {
            if case .produced(let result) = event {
                XCTAssertEqual(result.token, token)
                XCTAssertGreaterThan(result.image.cgImage.width, 0)
                XCTAssertLessThanOrEqual(
                    max(result.image.cgImage.width, result.image.cgImage.height), 900
                )
                return
            }
            if case .failed(_, let error) = event {
                return XCTFail("Preview failed for \(url.lastPathComponent): \(error)")
            }
        }
    }

    // MARK: - Performance (spec §11: interactive preview target ≤150ms)

    /// A single interactive-quality decode+adjust+render, at the exact pixel
    /// target `EditorViewModel.previewPixelDimension` actually requests
    /// (1,600px). This isolates the cost the spec's 150ms target is about --
    /// the dominant, unpreemptable cost identified in the 2026-08-17 P1
    /// finding (docs/testing/reports/2026-08-16-mvp-acceptance-progress.md):
    /// a RAW decode can't be interrupted mid-flight, so this is what a single
    /// slider tick costs regardless of the submit-side throttle that was
    /// added to fix that P1 (`EditorViewModel.interactiveThrottleInterval`,
    /// covered separately by
    /// `EditorViewModelPreviewTests.testRapidSliderDragCoalescesIntoTheThrottleFloorInsteadOfQueueingOnePerTick`
    /// with a stub renderer). Together: the throttle caps submissions to at
    /// most one per 80ms, and this test says how long each of those actually
    /// takes on real hardware.
    ///
    /// No hard pass/fail threshold -- hardware varies between machines and
    /// CI runners, and turning a measurement into a flaky gate would defeat
    /// the point (this suite is opt-in via an environment variable for
    /// exactly this kind of reason). The numbers are printed for a human to
    /// read against the spec's target instead.
    func testInteractivePreviewLatencyForARealPhoto() async throws {
        let url = try firstSonyFixture()
        let renderer = CoreImagePreviewRenderer()
        let subject = PreviewSubject(UUID())
        let clock = ContinuousClock()

        func decodeOnce(exposure: Double) async throws -> Duration {
            let start = clock.now
            _ = try await renderer.render(PreviewRequest(
                subject: subject,
                url: url,
                adjustments: PhotoAdjustments(exposure: exposure),
                targetPixelDimension: 1_600,
                quality: .interactive
            ))
            return start.duration(to: clock.now)
        }

        // First call pays for CoreImage warming up its own internal caches;
        // report it separately from steady-state so a human can see what a
        // real drag actually experiences after the first tick.
        let cold = try await decodeOnce(exposure: 0)
        let warm = try [
            await decodeOnce(exposure: 0.5),
            await decodeOnce(exposure: 1.0),
            await decodeOnce(exposure: 1.5),
        ]

        print("""
            [Gate F performance] interactive preview decode, \(url.lastPathComponent), \
            1600px target, spec §11 target ≤150ms:
              cold:  \(cold)
              warm:  \(warm.map(String.init(describing:)).joined(separator: ", "))
            """)
    }
}

private func XCTAssertEqual(
    _ lhs: CGFloat,
    _ rhs: CGFloat,
    accuracy: CGFloat,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertLessThanOrEqual(abs(lhs - rhs), accuracy, file: file, line: line)
}
