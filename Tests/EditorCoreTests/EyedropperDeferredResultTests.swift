import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

@MainActor
final class EyedropperDeferredResultTests: XCTestCase {
    func testCandidateCannotCommitAfterAuthoritativeEdit() async throws {
        let renderer = DeferredWBRenderer()
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
        let request = await renderer.next()
        try await renderer.finish(request)
        let deadline = Date().addingTimeInterval(1)
        while editor.previewImage == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        editor.previewEyedropper(sample: .init(red: 0.6, green: 0.5, blue: 0.4))
        editor.setAdjustment(.exposure, to: 1)
        XCTAssertFalse(editor.commitEyedropper())
        XCTAssertEqual(editor.adjustments.exposure, 1)
        XCTAssertEqual(editor.adjustments.temperature, 0)
        editor.close()
    }
}

private actor DeferredWBRenderer: PreviewRendering {
    struct Pending {
        let request: PreviewRequest
        let continuation: CheckedContinuation<PreviewImage, Error>
    }
    var queue: [Pending] = []

    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        try await withCheckedThrowingContinuation { continuation in
            queue.append(Pending(request: request, continuation: continuation))
        }
    }

    func next() async -> PreviewRequest {
        while queue.isEmpty {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return queue[0].request
    }

    func finish(_ request: PreviewRequest) throws {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = PreviewImage(cgImage: context.makeImage()!, pixelSize: CGSize(width: 1, height: 1),
            whiteBalanceBaseline: .init(temperatureKelvin: 5500, tint: 0))
        queue.first?.continuation.resume(returning: image)
        queue.removeFirst()
    }
}
