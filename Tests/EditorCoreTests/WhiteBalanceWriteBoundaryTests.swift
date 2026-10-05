import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

@MainActor
final class WhiteBalanceWriteBoundaryTests: XCTestCase {
    private func editor(baseline: Double?) async -> EditorSession {
        let renderer = BoundaryRenderer(baseline: baseline)
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
        let deadline = Date().addingTimeInterval(1)
        while editor.whiteBalanceCapability == .loading && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return editor
    }

    func testInvalidBaselineNeverWritesTemperatureOrEyedropper() async {
        for baseline in [Double.nan, .infinity, 0, 1999, 50001] {
            let editor = await editor(baseline: baseline)
            editor.setAdjustment(.temperature, to: 10)
            XCTAssertEqual(editor.adjustments.temperature, 0)
            editor.previewEyedropper(sample: .init(red: 0.6, green: 0.5, blue: 0.4))
            XCTAssertFalse(editor.hasEyedropperPreview)
            XCTAssertFalse(editor.commitEyedropper())
            editor.close()
        }
    }

    func testValidBaselineStoresPhotoSpecificClampedOffset() async {
        let editor = await editor(baseline: 2000)
        editor.setAdjustment(.temperature, to: 100)
        XCTAssertEqual(editor.adjustments.temperature, 100)
        editor.setAdjustment(.temperature, to: 2000)
        XCTAssertEqual(editor.adjustments.temperature, 1066.6666666666667, accuracy: 1e-9)
        editor.close()
    }

    func testValidCandidateCannotReleaseAfterBaselineBecomesInvalid() async {
        let editor = await editor(baseline: 5500)
        editor.beginEyedropperForTesting()
        editor.previewEyedropper(sample: .init(red: 0.6, green: 0.5, blue: 0.4))
        XCTAssertTrue(editor.hasEyedropperPreview)
        editor.setWhiteBalanceBaselineForTesting(.init(temperatureKelvin: .nan, tint: 0))
        XCTAssertFalse(editor.commitEyedropper())
        XCTAssertEqual(editor.adjustments, .neutral)
        editor.close()
    }
}

private struct BoundaryRenderer: PreviewRendering {
    let baseline: Double?
    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return PreviewImage(cgImage: context.makeImage()!, pixelSize: CGSize(width: 1, height: 1),
            whiteBalanceBaseline: baseline.map { .init(temperatureKelvin: $0, tint: 0) })
    }
}
