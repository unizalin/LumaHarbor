import Foundation
import XCTest

/// Same source-parsing approach as `CropOverlayContractTests` -- see that
/// file's own header comment for why. Phase 2 Task 2.4: the eyedropper must
/// actually be reachable from `EditorView`/`InspectorView`, gated on
/// `EditorSession.toolMode == .whiteBalance`, must offer an explicit cancel
/// path, and must only ever *apply* on commit -- not merely exist as an
/// unused type somewhere in `LumaHarborApp`.
final class EyedropperOverlayContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // EyedropperOverlayContractTests.swift
            .deletingLastPathComponent() // LumaHarborAppTests
            .deletingLastPathComponent() // Tests
    }()

    private static func loadSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRootURL.appendingPathComponent(relativePath, isDirectory: false),
            encoding: .utf8
        )
    }

    func testEditorViewOnlyMountsTheEyedropperOverlayInWhiteBalanceToolMode() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")

        XCTAssertTrue(source.contains("model.editor.toolMode == .whiteBalance"), "the overlay must be gated on the eyedropper tool being active")
        XCTAssertTrue(source.contains("EyedropperOverlayView("), "EditorView must actually mount the overlay, not just define the condition")
    }

    func testEditorViewComputesTheEyedropperOverlaysFrameFromTheSameFittedImageRect() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")
        // Both overlays must line up with the same rectangle the photo
        // itself is drawn in -- two independent AspectFitRect.fitting(...)
        // call sites, not a frame computed once and only reused by one of them.
        let occurrences = source.components(separatedBy: "AspectFitRect.fitting(").count - 1
        XCTAssertGreaterThanOrEqual(occurrences, 2, "both CropOverlayView and EyedropperOverlayView must compute their frame from AspectFitRect")
    }

    func testEyedropperOverlayPreviewsOnEveryDragChangeAndCommitsOnlyOnRelease() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EyedropperOverlayView.swift")

        XCTAssertTrue(source.contains("editor.previewEyedropper("), "a drag in progress must only preview, never write to history")
        XCTAssertTrue(source.contains(".onChanged"))
        XCTAssertTrue(source.contains(".onEnded"))
        XCTAssertTrue(source.contains("editor.commitEyedropper()"), "release must be the one place that commits")
        XCTAssertTrue(source.contains("PixelSampler.sample("), "must sample the actually-displayed image, not a hardcoded/mocked colour")
        XCTAssertTrue(source.contains("AspectFitRect.imagePixel("), "must map the click location to a pixel coordinate through the shared, tested helper")
    }

    /// The explicit cancel path (design spec §6.4: "使用者必須能取消滴管") --
    /// toggling the eyedropper off must call `cancelEyedropperPreview()`,
    /// not merely flip `toolMode` and leave a stale preview live.
    func testTheEyedropperToggleButtonCancelsAnyLivePreviewWhenTurnedOff() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/WhiteBalanceEyedropperButton.swift")

        XCTAssertTrue(source.contains("editor.cancelEyedropperPreview()"))
        XCTAssertTrue(source.contains(".whiteBalance"))
        XCTAssertTrue(source.contains("L10n.t(\"White Balance Eyedropper\")"))
        XCTAssertTrue(source.contains("L10n.t(\"Cancel Eyedropper\")"))
    }

    func testInspectorViewMountsTheEyedropperButtonNearTheColorGroup() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/InspectorView.swift")
        XCTAssertTrue(source.contains("WhiteBalanceEyedropperButton(editor:"))
    }

    func testEveryNewEyedropperSourceFileExists() throws {
        for path in [
            "Sources/RawProcessingCore/Model/WhiteBalanceEyedropper.swift",
            "Sources/RawProcessingCore/Pipeline/PixelSampler.swift",
            "Sources/LumaHarborApp/Views/EyedropperOverlayView.swift",
            "Sources/LumaHarborApp/Views/WhiteBalanceEyedropperButton.swift"
        ] {
            let source = try Self.loadSource(path)
            XCTAssertFalse(source.isEmpty)
        }
    }
}
