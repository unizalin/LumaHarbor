import CoreGraphics
import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

private struct TemperatureColorRenderer: PreviewRendering {
    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        let red: UInt8 = request.adjustments.temperature == 0 ? 100 : 220
        var pixels = [UInt8](repeating: 0, count: 4)
        pixels[0] = red
        pixels[1] = 100
        pixels[2] = 100
        pixels[3] = 255
        guard let context = CGContext(
            data: &pixels,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw ImageRenderError.renderFailed
        }
        return PreviewImage(cgImage: image, pixelSize: CGSize(width: 1, height: 1),
            whiteBalanceBaseline: .init(temperatureKelvin: 5500, tint: 0))
    }
}

@MainActor
final class EditorSessionEyedropperRenderingTests: XCTestCase {
    private func makePhoto() -> PhotoAsset {
        PhotoAsset(
            id: PhotoID(),
            libraryID: LibraryID(),
            relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"),
            status: .ready
        )
    }

    private func makeEditor() -> EditorSession {
        let renderer = TemperatureColorRenderer()
        let editor = EditorSession()
        editor.attach(dependencies: EditorDependencies(
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            loadAdjustments: { _ in .neutral },
            saveAdjustments: { _, _ in }
        ))
        editor.open(
            photo: makePhoto(),
            sourceURL: URL(fileURLWithPath: "/tmp/fixture.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )
        return editor
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for preview state")
    }

    private func red(_ image: CGImage?) -> UInt8? {
        guard let image, let provider = image.dataProvider, let data = provider.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        return bytes[0]
    }

    func testNeutralResampleRestoresTheDisplayedImageAndHistogramAfterWarmPreview() async throws {
        let editor = makeEditor()
        try await waitUntil { self.red(editor.previewImage) == 100 }

        editor.previewEyedropper(sample: .init(red: 0.6, green: 0.5, blue: 0.4))
        try await waitUntil { self.red(editor.previewImage) == 220 }

        editor.previewEyedropper(sample: .init(red: 0.5, green: 0.5, blue: 0.5))
        try await waitUntil { self.red(editor.previewImage) == 100 }
        try await waitUntil { editor.histogram != nil }

        XCTAssertEqual(red(editor.previewImage), 100)
        XCTAssertEqual(editor.displayedAdjustments, editor.adjustments)
        XCTAssertFalse(editor.canUndo)
        let histogram = try XCTUnwrap(editor.histogram)
        XCTAssertEqual(histogram.red[100], 1)
        XCTAssertEqual(histogram.green[100], 1)
        XCTAssertEqual(histogram.blue[100], 1)
        XCTAssertEqual(histogram.red.reduce(0, +), 1)
        XCTAssertEqual(histogram.green.reduce(0, +), 1)
        XCTAssertEqual(histogram.blue.reduce(0, +), 1)
    }
}
