import Combine
import CoreGraphics
@testable import EditorCore
import XCTest

@MainActor
final class EditorRenderStateIsolationTests: XCTestCase {
    func testRenderOnlyPublicationDoesNotInvalidateEditorSession() {
        let editor = EditorSession()
        var editorPublicationCount = 0
        var renderPublicationCount = 0
        let editorCancellable = editor.objectWillChange.sink {
            editorPublicationCount += 1
        }
        let renderCancellable = editor.renderState.objectWillChange.sink {
            renderPublicationCount += 1
        }

        editor.renderState.previewImage = makeImage()

        XCTAssertEqual(editorPublicationCount, 0)
        XCTAssertEqual(renderPublicationCount, 1)

        editor.brushMaskGestureSettings.size = 0.1
        XCTAssertEqual(editorPublicationCount, 1)

        withExtendedLifetime((editorCancellable, renderCancellable)) {}
    }

    func testHistoryPublicationDoesNotInvalidateEditorSession() {
        let editor = EditorSession()
        var editorPublicationCount = 0
        var historyPublicationCount = 0
        let editorCancellable = editor.objectWillChange.sink {
            editorPublicationCount += 1
        }
        let historyCancellable = editor.historyState.objectWillChange.sink {
            historyPublicationCount += 1
        }

        editor.historyState.saveState = .pending

        XCTAssertEqual(editorPublicationCount, 0)
        XCTAssertEqual(historyPublicationCount, 1)

        editor.brushMaskGestureSettings.size = 0.1
        XCTAssertEqual(editorPublicationCount, 1)

        withExtendedLifetime((editorCancellable, historyCancellable)) {}
    }

    private func makeImage() -> CGImage {
        var pixel: [UInt8] = [0, 0, 0, 255]
        let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }
}
