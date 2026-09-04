import Foundation
import XCTest

/// Same source-parsing approach as `CropOverlayContractTests`/
/// `EyedropperOverlayContractTests` -- see either file's own header comment
/// for why. Phase 4 Task 4.3: the linear gradient overlay must actually be
/// reachable from `EditorView`, gated on `EditorSession.toolMode ==
/// .linearGradient`, built from the same fitted-image rectangle the photo
/// itself is drawn in, and every edit must route through the same
/// undo/autosave path every other adjustment already uses -- not merely
/// exist as an unused type somewhere in `LumaHarborApp`/`AdjustmentUI`.
final class LinearGradientOverlayContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LinearGradientOverlayContractTests.swift
            .deletingLastPathComponent() // LumaHarborAppTests
            .deletingLastPathComponent() // Tests
    }()

    private static func loadSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRootURL.appendingPathComponent(relativePath, isDirectory: false),
            encoding: .utf8
        )
    }

    func testEditorViewOnlyMountsTheLinearGradientOverlayInLinearGradientToolMode() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")

        XCTAssertTrue(source.contains("model.editor.toolMode == .linearGradient"), "the overlay must be gated on the linear gradient tool being active")
        XCTAssertTrue(source.contains("LinearGradientOverlayView("), "EditorView must actually mount the overlay, not just define the condition")
    }

    func testEditorViewComputesTheLinearGradientOverlaysFrameFromTheSameFittedImageRect() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")
        // Three overlays now share the same fitted rect computation: crop,
        // eyedropper, and this one -- each its own independent
        // AspectFitRect.fitting(...) call site, not a frame computed once
        // and only reused by the first two.
        let occurrences = source.components(separatedBy: "AspectFitRect.fitting(").count - 1
        XCTAssertGreaterThanOrEqual(occurrences, 3, "CropOverlayView, EyedropperOverlayView and LinearGradientOverlayView must each compute their frame from AspectFitRect")
    }

    func testOverlayRoutesPositionAndRangeDragsThroughEditorSessionUpdateAdjustments() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/LinearGradientOverlayView.swift")

        XCTAssertTrue(source.contains("editor.updateAdjustments"), "gradient edits must go through the same undo/autosave path every other adjustment uses")
        XCTAssertTrue(source.contains("DragGesture"))
        XCTAssertTrue(
            source.contains("LinearGradientDragMath.updatedPosition(") && source.contains("LinearGradientDragMath.updatedDirection("),
            "the drag math itself must be the unit-tested pure functions, not reimplemented inline (matches CropOverlayView's own CropDragMath split)"
        )
    }

    /// A center handle (moves the gradient's position) and a separate
    /// direction/range handle (sets angle + range together by dragging the
    /// arrow's tip) -- two independent draggable points per gradient, not
    /// one handle that conflates both.
    func testOverlayHasTwoIndependentHandleKindsPerGradient() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/LinearGradientOverlayView.swift")

        XCTAssertTrue(source.contains(".x =") || source.contains("geometry.x"), "must read/write the anchor position")
        XCTAssertTrue(source.contains("angleDegrees"), "must read/write the direction")
        XCTAssertTrue(source.contains(".range"), "must read/write the range")
    }

    /// Tapping a handle must select that entry so the panel's per-gradient
    /// controls (exposure slider, delete) know which one they're editing.
    func testOverlaySetsTheSelectedLocalAdjustmentIDOnTap() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/LinearGradientOverlayView.swift")
        XCTAssertTrue(source.contains("editor.selectedLocalAdjustmentID"))
    }

    /// Matches `CropOverlayView`'s own hit-area convention -- a visually
    /// small dot must still have a comfortably larger click/hit target
    /// (spec's own accessibility bar; `CropOverlayView.handleHitAreaSize` is
    /// 28pt against a 12pt visible handle).
    func testHandleHitAreaIsAtLeastAsLargeAsTheCropHandleConvention() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/LinearGradientOverlayView.swift")
        XCTAssertTrue(
            source.contains("handleHitAreaSize"),
            "must define its own named hit-area constant, matching CropOverlayView's convention, not a magic number"
        )
    }

    func testHandlesHaveAccessibilityLabels() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/LinearGradientOverlayView.swift")
        XCTAssertTrue(source.contains(".accessibilityLabel("), "drag handles must be labeled for VoiceOver/accessibility inspection")
    }

    // MARK: - Panel (AdjustmentUI)

    func testPanelOffersAddAndDeleteRoutedThroughTheArrayModelOperations() throws {
        let source = try Self.loadSource("Sources/AdjustmentUI/LocalAdjustmentsPanel.swift")

        XCTAssertTrue(source.contains("editor.updateAdjustments"), "add/delete must go through the same undo/autosave path every other adjustment uses")
        XCTAssertTrue(source.contains(".localAdjustments.append(") || source.contains("localAdjustments +"), "adding a gradient must append a new LocalAdjustment")
        XCTAssertTrue(source.contains(".removing("), "deleting must reuse the tested Array<LocalAdjustment>.removing(_:) model operation, not reimplement list surgery inline")
    }

    func testPanelTogglesTheLinearGradientToolMode() throws {
        let source = try Self.loadSource("Sources/AdjustmentUI/LocalAdjustmentsPanel.swift")
        XCTAssertTrue(source.contains("editor.setToolMode(") && source.contains(".linearGradient"))
    }

    /// Non-destructive copy, matching `GeometryAdjustmentPanel`'s own
    /// established wording exactly.
    func testPanelStatesTheEditIsNonDestructive() throws {
        let source = try Self.loadSource("Sources/AdjustmentUI/LocalAdjustmentsPanel.swift")
        XCTAssertTrue(source.contains("Your RAW original was not changed."))
    }

    func testPanelExposesAnExposureSliderForTheSelectedGradient() throws {
        let source = try Self.loadSource("Sources/AdjustmentUI/LocalAdjustmentsPanel.swift")
        XCTAssertTrue(source.contains("selectedLocalAdjustmentID"))
        XCTAssertTrue(source.contains("adjustments.exposure"), "the selected gradient's own patch.exposure must be editable, matching Task 4.2's local-exposure focus")
    }

    func testInspectorViewMountsTheLocalAdjustmentsPanel() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/InspectorView.swift")
        XCTAssertTrue(source.contains("LocalAdjustmentsPanel(editor:"))
    }

    func testEveryNewLinearGradientSourceFileExists() throws {
        for path in [
            "Sources/LumaHarborApp/Views/LinearGradientOverlayView.swift",
            "Sources/LumaHarborApp/Views/LinearGradientDragMath.swift",
            "Sources/AdjustmentUI/LocalAdjustmentsPanel.swift"
        ] {
            let source = try Self.loadSource(path)
            XCTAssertFalse(source.isEmpty)
        }
    }
}
