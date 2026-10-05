import CoreGraphics
import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

private struct TemperatureColorRenderer: PreviewRendering {
    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        var pixels = [UInt8](repeating: 100, count: 4)
        pixels[0] = request.adjustments.temperature == 0 ? 100 : 220
        pixels[3] = 255
        let context = CGContext(data: &pixels, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return PreviewImage(cgImage: context.makeImage()!, pixelSize: CGSize(width: 1, height: 1),
            whiteBalanceBaseline: .init(temperatureKelvin: 5500, tint: 0))
    }
}

@MainActor
final class EditorSessionEyedropperRenderingTests: XCTestCase {
    func testNeutralResampleRestoresDisplayedImageAndHistogram() async throws {
        let renderer = TemperatureColorRenderer()
        let editor = EditorSession()
        editor.attach(dependencies: EditorDependencies(
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer, loadAdjustments: { _ in .neutral },
            saveAdjustments: { _, _ in }
        ))
        let photo = PhotoAsset(id: PhotoID(), libraryID: LibraryID(), relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"), status: .ready)
        editor.open(photo: photo, sourceURL: URL(fileURLWithPath: "/tmp/fixture.ARW"),
            adjustments: .neutral, isReadOnly: false)
        let initialReady = await waitUntil("initial preview and histogram") {
            editor.previewImage != nil && editor.histogram != nil
        }
        XCTAssertTrue(initialReady)
        let image = try XCTUnwrap(editor.previewImage)
        let baselineHistogram = try XCTUnwrap(editor.histogram)
        let baselineRed = try XCTUnwrap(red(of: image))
        XCTAssertEqual(baselineRed, 100)
        let samplingContext = try XCTUnwrap(editor.beginEyedropperSampling(sourceImage: image))
        editor.previewEyedropper(
            sample: .init(red: 0.6, green: 0.5, blue: 0.4), context: samplingContext
        )
        let warmReady = await waitUntil("warm eyedropper preview") {
            self.red(of: editor.displayedImage) == 220 && editor.histogram != baselineHistogram
        }
        XCTAssertTrue(warmReady)
        XCTAssertEqual(red(of: editor.displayedImage), 220)
        let warmHistogram = try XCTUnwrap(editor.histogram)
        XCTAssertNotEqual(warmHistogram, baselineHistogram)
        let neutralContext = try XCTUnwrap(editor.beginEyedropperForTesting())
        editor.previewEyedropper(
            sample: .init(red: 0.5, green: 0.5, blue: 0.5), context: neutralContext
        )
        let neutralReady = await waitUntil("neutral restored preview") {
            self.red(of: editor.displayedImage) == 100 && editor.histogram == baselineHistogram
        }
        XCTAssertTrue(neutralReady)
        XCTAssertEqual(red(of: editor.displayedImage), 100)
        let restoredHistogram = try XCTUnwrap(editor.histogram)
        XCTAssertEqual(restoredHistogram.red, baselineHistogram.red)
        XCTAssertEqual(restoredHistogram.green, baselineHistogram.green)
        XCTAssertEqual(restoredHistogram.blue, baselineHistogram.blue)
        XCTAssertNotEqual(warmHistogram, restoredHistogram)
        XCTAssertEqual(editor.displayedAdjustments, editor.adjustments)
        XCTAssertFalse(editor.canUndo)
        XCTAssertNotNil(image)
        editor.close()
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if !condition() {
            XCTFail("Timed out waiting for \(description)")
            return false
        }
        return true
    }

    private func red(of image: CGImage?) -> UInt8? {
        guard let data = image?.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else { return nil }
        return pointer[0]
    }
}
