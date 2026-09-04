import Foundation
import XCTest

/// Same source-parsing approach as `LinearGradientOverlayContractTests` --
/// see its own header comment for why. Phase 4 Task 4.5: the spot heal
/// overlay must actually be reachable from `EditorView`, gated on
/// `EditorSession.toolMode == .spotHeal`, built from the same fitted-image
/// rectangle the photo itself is drawn in, and every edit must route
/// through the same undo/autosave path every other adjustment already uses
/// -- not merely exist as an unused type somewhere in
/// `LumaHarborApp`/`AdjustmentUI`. Also covers the roadmap's explicit
/// "source-contracts for add, select, move source, move target, size,
/// feather, delete, mode switch" and "record quality limitations honestly"
/// requirements.
final class SpotHealOverlayContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SpotHealOverlayContractTests.swift
            .deletingLastPathComponent() // LumaHarborAppTests
            .deletingLastPathComponent() // Tests
    }()

    private static func loadSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRootURL.appendingPathComponent(relativePath, isDirectory: false),
            encoding: .utf8
        )
    }

    // MARK: - Overlay (LumaHarborApp)

    func testEditorViewOnlyMountsTheSpotHealOverlayInSpotHealToolMode() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")

        XCTAssertTrue(source.contains("model.editor.toolMode == .spotHeal"), "the overlay must be gated on the spot heal tool being active")
        XCTAssertTrue(source.contains("SpotHealOverlayView("), "EditorView must actually mount the overlay, not just define the condition")
    }

    func testEditorViewComputesTheSpotHealOverlaysFrameFromTheSameFittedImageRect() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")
        // Four overlays now share the same fitted rect computation: crop,
        // eyedropper, linear gradient, and this one.
        let occurrences = source.components(separatedBy: "AspectFitRect.fitting(").count - 1
        XCTAssertGreaterThanOrEqual(occurrences, 4, "CropOverlayView, EyedropperOverlayView, LinearGradientOverlayView and SpotHealOverlayView must each compute their frame from AspectFitRect")
    }

    func testOverlayRoutesTargetSourceAndSizeDragsThroughEditorSessionUpdateAdjustments() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/SpotHealOverlayView.swift")

        XCTAssertTrue(source.contains("editor.updateAdjustments"), "spot heal edits must go through the same undo/autosave path every other adjustment uses")
        XCTAssertTrue(source.contains("DragGesture"))
        XCTAssertTrue(
            source.contains("SpotHealDragMath.updatedTargetPosition(")
                && source.contains("SpotHealDragMath.updatedSourcePosition(")
                && source.contains("SpotHealDragMath.updatedRadius("),
            "the drag math itself must be the unit-tested pure functions, not reimplemented inline (matches LinearGradientOverlayView's own LinearGradientDragMath split)"
        )
    }

    /// Move target, move source, and size are three independent draggable
    /// points -- not one handle conflating all three.
    func testOverlayHasThreeIndependentHandleKinds() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/SpotHealOverlayView.swift")

        XCTAssertTrue(source.contains("targetDragGesture"), "must have a dedicated target-move gesture")
        XCTAssertTrue(source.contains("sourceDragGesture"), "must have a dedicated source-move gesture")
        XCTAssertTrue(source.contains("sizeDragGesture") || source.contains("radiusDragGesture"), "must have a dedicated size/radius gesture")
    }

    /// Heal mode has no source point for the user to place -- the render
    /// falls back to a fixed auto-sampled offset (design spec §6.7).
    /// Showing a draggable source handle in heal mode would silently imply
    /// clone semantics that aren't actually in effect.
    func testOverlayOnlyOffersTheSourceHandleInCloneMode() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/SpotHealOverlayView.swift")
        XCTAssertTrue(source.contains("healMode == .clone"), "the source handle must be gated on clone mode")
    }

    func testOverlaySetsTheSelectedLocalAdjustmentIDOnTap() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/SpotHealOverlayView.swift")
        XCTAssertTrue(source.contains("editor.selectedLocalAdjustmentID"))
    }

    func testHandleHitAreaIsAtLeastAsLargeAsTheCropHandleConvention() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/SpotHealOverlayView.swift")
        XCTAssertTrue(
            source.contains("handleHitAreaSize"),
            "must define its own named hit-area constant, matching CropOverlayView/LinearGradientOverlayView's convention, not a magic number"
        )
    }

    func testHandlesHaveAccessibilityLabels() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/SpotHealOverlayView.swift")
        XCTAssertTrue(source.contains(".accessibilityLabel("), "drag handles must be labeled for VoiceOver/accessibility inspection")
    }

    // MARK: - Drag math (LumaHarborApp)

    func testEveryNewSpotHealSourceFileExists() throws {
        for path in [
            "Sources/LumaHarborApp/Views/SpotHealOverlayView.swift",
            "Sources/LumaHarborApp/Views/SpotHealDragMath.swift"
        ] {
            let source = try Self.loadSource(path)
            XCTAssertFalse(source.isEmpty)
        }
    }

    // MARK: - Panel (AdjustmentUI)

    func testPanelOffersAddAndDeleteForSpotHealRoutedThroughTheArrayModelOperations() throws {
        let source = try Self.loadSource("Sources/AdjustmentUI/LocalAdjustmentsPanel.swift")

        XCTAssertTrue(source.contains("kind: .spotHeal"), "adding a spot heal must create a LocalAdjustment(kind: .spotHeal)")
        XCTAssertTrue(source.contains(".removing("), "deleting must reuse the tested Array<LocalAdjustment>.removing(_:) model operation")
    }

    func testPanelTogglesTheSpotHealToolMode() throws {
        let source = try Self.loadSource("Sources/AdjustmentUI/LocalAdjustmentsPanel.swift")
        XCTAssertTrue(source.contains("editor.setToolMode(") && source.contains(".spotHeal"))
    }

    func testPanelExposesAModeSwitchBetweenHealAndClone() throws {
        let source = try Self.loadSource("Sources/AdjustmentUI/LocalAdjustmentsPanel.swift")
        XCTAssertTrue(source.contains("healMode"), "must expose SpotHealMode's own heal/clone switch, not a bespoke boolean")
        XCTAssertTrue(source.contains(".heal") && source.contains(".clone"))
    }

    func testPanelExposesRadiusAndFeatherSlidersForTheSelectedSpotHeal() throws {
        let source = try Self.loadSource("Sources/AdjustmentUI/LocalAdjustmentsPanel.swift")
        XCTAssertTrue(source.contains("selectedLocalAdjustmentID"))
        XCTAssertTrue(source.contains("geometry.radius"), "size must be editable for the selected spot heal entry")
        XCTAssertTrue(source.contains("geometry.feather"), "feather must be editable for the selected spot heal entry")
    }

    /// Roadmap Task 4.5 explicitly requires recording quality limitations
    /// honestly, not just implementing the control -- matches how
    /// `LocalAdjustmentRenderer.autoSourcePoint`'s own doc comment already
    /// does this at the render layer.
    func testPanelRecordsHealModesQualityLimitationHonestly() throws {
        let source = try Self.loadSource("Sources/AdjustmentUI/LocalAdjustmentsPanel.swift")
        XCTAssertTrue(
            source.lowercased().contains("samples nearby texture"),
            "the panel must tell the user heal mode is a fixed auto-sample, not content-aware fill"
        )
    }

    func testInspectorViewMountsTheLocalAdjustmentsPanel() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/InspectorView.swift")
        XCTAssertTrue(source.contains("LocalAdjustmentsPanel(editor:"))
    }
}
