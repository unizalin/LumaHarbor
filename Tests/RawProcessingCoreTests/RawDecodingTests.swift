import CoreGraphics
import XCTest
@testable import RawProcessingCore

/// Everything here runs without a real RAW file. Spec §10 needs "missing",
/// "damaged" and "unsupported" to be told apart, and each maps to a different
/// thing the user is asked to do.
final class RawDecodingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RawDecodingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Scale factor

    func testFullQualityNeverScales() {
        XCTAssertEqual(
            CoreImageRawDecoder.scaleFactor(
                nativeSize: CGSize(width: 6_000, height: 4_000),
                maximumPixelDimension: nil
            ),
            1
        )
    }

    func testPreviewFitsTheLongestEdge() {
        let scale = CoreImageRawDecoder.scaleFactor(
            nativeSize: CGSize(width: 6_000, height: 4_000),
            maximumPixelDimension: 1_500
        )
        XCTAssertEqual(scale, 0.25, accuracy: 1e-9)
    }

    func testPortraitOrientationUsesTheHeight() {
        let scale = CoreImageRawDecoder.scaleFactor(
            nativeSize: CGSize(width: 4_000, height: 6_000),
            maximumPixelDimension: 1_500
        )
        XCTAssertEqual(scale, 0.25, accuracy: 1e-9)
    }

    func testNeverUpscalesASmallFile() {
        // Spec §9 sizes previews to the display; blowing a small RAW up to the
        // request would waste memory for no visible gain.
        let scale = CoreImageRawDecoder.scaleFactor(
            nativeSize: CGSize(width: 800, height: 600),
            maximumPixelDimension: 4_000
        )
        XCTAssertEqual(scale, 1)
    }

    func testDegenerateSizeFallsBackToOneToOne() {
        XCTAssertEqual(
            CoreImageRawDecoder.scaleFactor(nativeSize: .zero, maximumPixelDimension: 1_000),
            1
        )
    }

    // MARK: - DecodedRawImage.scaleFactor (spec §7 Gate B3)

    private func makeDecodedImage(nativePixelSize: CGSize, decodedPixelSize: CGSize) -> DecodedRawImage {
        DecodedRawImage(
            image: CIImage.empty(),
            nativePixelSize: nativePixelSize,
            decodedPixelSize: decodedPixelSize,
            baselineTemperature: 5_500,
            baselineTint: 0,
            metadata: RawMetadata()
        )
    }

    func testFullResolutionDecodeReportsScaleFactorOfOne() {
        let decoded = makeDecodedImage(
            nativePixelSize: CGSize(width: 6_000, height: 4_000),
            decodedPixelSize: CGSize(width: 6_000, height: 4_000)
        )
        XCTAssertEqual(decoded.scaleFactor, 1)
    }

    func testDownsampledDecodeReportsAFractionalScaleFactor() {
        let decoded = makeDecodedImage(
            nativePixelSize: CGSize(width: 6_000, height: 4_000),
            decodedPixelSize: CGSize(width: 1_600, height: 1_067)
        )
        XCTAssertEqual(decoded.scaleFactor, 1_600.0 / 6_000.0, accuracy: 1e-9)
    }

    func testDegenerateNativeSizeFallsBackToOneForScaleFactor() {
        let decoded = makeDecodedImage(nativePixelSize: .zero, decodedPixelSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(decoded.scaleFactor, 1)
    }

    // MARK: - Decode quality

    func testDraftModeIsOnlyForInteractiveWork() {
        XCTAssertTrue(DecodeQuality.thumbnail(maximumPixelDimension: 512).allowsDraftMode)
        XCTAssertTrue(DecodeQuality.interactive(maximumPixelDimension: 1_600).allowsDraftMode)
        // Spec §6.3: an export must not use the draft demosaic.
        XCTAssertFalse(DecodeQuality.highQuality(maximumPixelDimension: 1_600).allowsDraftMode)
        XCTAssertFalse(DecodeQuality.full.allowsDraftMode)
    }

    func testOnlyFullDecodeIgnoresAPixelBudget() {
        XCTAssertNil(DecodeQuality.full.maximumPixelDimension)
        XCTAssertEqual(DecodeQuality.interactive(maximumPixelDimension: 900).maximumPixelDimension, 900)
    }

    // MARK: - Error classification

    func testMissingFileIsReportedAsUnavailableNotCorrupt() {
        let decoder = CoreImageRawDecoder()
        let missing = directory.appendingPathComponent("nope.ARW")

        XCTAssertThrowsError(try decoder.decode(RawDecodeRequest(url: missing))) { error in
            guard case RawDecodingError.fileUnavailable = error else {
                return XCTFail("Expected .fileUnavailable, got \(error)")
            }
        }
    }

    func testGarbageBytesAreReportedAsCorrupt() throws {
        let decoder = CoreImageRawDecoder()
        let broken = directory.appendingPathComponent("broken.ARW")
        try Data(repeating: 0xAB, count: 4_096).write(to: broken)

        XCTAssertThrowsError(try decoder.decode(RawDecodeRequest(url: broken))) { error in
            guard case RawDecodingError.corruptedFile = error else {
                return XCTFail("Expected .corruptedFile, got \(error)")
            }
        }
    }

    func testEmptyFileIsReportedAsCorrupt() throws {
        let decoder = CoreImageRawDecoder()
        let empty = directory.appendingPathComponent("empty.ARW")
        try Data().write(to: empty)

        XCTAssertThrowsError(try decoder.decode(RawDecodeRequest(url: empty)))
    }

    func testSupportsFileIsSafeOnRubbish() throws {
        // The scanner calls this on every candidate; it must never throw.
        let decoder = CoreImageRawDecoder()
        let broken = directory.appendingPathComponent("broken.ARW")
        try Data(repeating: 0x00, count: 128).write(to: broken)
        XCTAssertFalse(decoder.supportsFile(at: broken))
        XCTAssertFalse(decoder.supportsFile(at: directory.appendingPathComponent("absent.ARW")))
    }

    func testEveryUserFacingErrorOffersANextStep() {
        // Spec §10: no dead ends.
        let errors: [RawDecodingError] = [
            .fileUnavailable(path: "/Volumes/SSD/a.ARW"),
            .unsupportedFormat(path: "/Volumes/SSD/a.ARW"),
            .corruptedFile(path: "/Volumes/SSD/a.ARW"),
            .decodeFailed(path: "/Volumes/SSD/a.ARW", reason: "test")
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error)")
            XCTAssertNotNil(error.recoverySuggestion, "\(error)")
        }
    }

    func testUnsupportedMessageDoesNotLeakThePath() {
        // Spec §10: don't put unnecessary technical detail in front of the user.
        let error = RawDecodingError.unsupportedFormat(path: "/Volumes/Private/secret/a.ARW")
        XCTAssertFalse(error.errorDescription?.contains("secret") ?? true)
    }

    // MARK: - Candidate extensions

    func testSonyARWIsACandidateExtension() {
        // The MVP's required acceptance format.
        XCTAssertTrue(CoreImageRawDecoder.candidateFileExtensions.contains("arw"))
    }

    func testCandidateExtensionsAreLowercasedForCaseInsensitiveMatching() {
        for ext in CoreImageRawDecoder.candidateFileExtensions {
            XCTAssertEqual(ext, ext.lowercased())
        }
    }

    func testJPEGIsNotTreatedAsARaw() {
        XCTAssertFalse(CoreImageRawDecoder.candidateFileExtensions.contains("jpg"))
        XCTAssertFalse(CoreImageRawDecoder.candidateFileExtensions.contains("png"))
    }
}
