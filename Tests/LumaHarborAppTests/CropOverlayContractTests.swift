import Foundation
import XCTest

/// Same source-parsing approach as `InspectorAdjustmentGroupsContractTests`
/// -- see that file's own header comment for why. Phase 2 Task 2.3: the
/// crop overlay must actually be reachable from `EditorView`, gated on
/// `EditorSession.toolMode == .crop`, and built from the same fitted-image
/// rectangle the photo itself is drawn in -- not merely exist as an unused
/// type somewhere in `LumaHarborApp`.
final class CropOverlayContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CropOverlayContractTests.swift
            .deletingLastPathComponent() // LumaHarborAppTests
            .deletingLastPathComponent() // Tests
    }()

    private static func loadSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRootURL.appendingPathComponent(relativePath, isDirectory: false),
            encoding: .utf8
        )
    }

    func testEditorViewOnlyMountsTheCropOverlayInCropToolMode() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")

        XCTAssertTrue(source.contains("model.editor.toolMode == .crop"), "the overlay must be gated on the crop tool being active")
        XCTAssertTrue(source.contains("CropOverlayView("), "EditorView must actually mount the overlay, not just define the condition")
    }

    /// The overlay must line up with the same rectangle the `Image` itself
    /// is fit into (`.aspectRatio(contentMode: .fit)` plus the view's own
    /// 16pt padding), or crop handles would drift away from the photo they
    /// are supposedly editing.
    func testEditorViewComputesTheOverlaysFrameFromTheSameFittedImageRect() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")

        XCTAssertTrue(source.contains("AspectFitRect.fitting("))
        XCTAssertTrue(source.contains("imageFrame:"))
    }

    func testCropOverlayViewRoutesEveryDragThroughEditorSessionUpdateAdjustments() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/CropOverlayView.swift")

        XCTAssertTrue(source.contains("editor.updateAdjustments"), "crop edits must go through the same undo/autosave path every other adjustment uses")
        XCTAssertTrue(source.contains("CropDragMath.updatedCrop("), "the drag math itself must be the unit-tested pure function, not reimplemented inline")
        XCTAssertTrue(source.contains("DragGesture"))
    }

    func testEveryNewCropSourceFileExists() throws {
        for path in [
            "Sources/LumaHarborApp/Views/AspectFitRect.swift",
            "Sources/LumaHarborApp/Views/CropDragMath.swift",
            "Sources/LumaHarborApp/Views/CropOverlayView.swift"
        ] {
            let source = try Self.loadSource(path)
            XCTAssertFalse(source.isEmpty)
        }
    }
}
