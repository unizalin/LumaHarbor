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
        let deadline = Date().addingTimeInterval(2)
        while editor.previewImage == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let image = try XCTUnwrap(editor.previewImage)
        editor.previewEyedropper(sample: .init(red: 0.6, green: 0.5, blue: 0.4))
        while editor.displayedImage?.dataProvider?.data.map({ CFDataGetBytePtr($0)?[0] }) != 220 &&
            Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        editor.previewEyedropper(sample: .init(red: 0.5, green: 0.5, blue: 0.5))
        while editor.displayedImage?.dataProvider?.data.map({ CFDataGetBytePtr($0)?[0] }) != 100 &&
            Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(editor.displayedAdjustments, editor.adjustments)
        XCTAssertFalse(editor.canUndo)
        XCTAssertNotNil(image)
        editor.close()
    }
}
