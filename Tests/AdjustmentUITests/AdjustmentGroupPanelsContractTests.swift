import Foundation
import XCTest

/// AwayPhotoRawEditor parity Phase 1 Task 3: reset-to-neutral is a required,
/// visible affordance for every adjustment (plan acceptance: "Each
/// adjustment has visible neutral/reset semantics"). `BasicAdjustmentPanel`
/// already establishes the pattern -- a double-click on the row plus a
/// context-menu "Reset <label>" item (`BasicAdjustmentPanelModelTests
/// .testMacResetGestureAndHelpRemainPlatformGuarded`) -- so the four new
/// grouped panels this task adds (Color/Curve/Detail/Effects) must follow
/// the exact same pattern rather than inventing a second one. Like
/// `BasicAdjustmentPanelModelTests`, this source-parses the raw file text:
/// there is no third-party SwiftUI view-inspection dependency in this
/// package.
final class AdjustmentGroupPanelsContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AdjustmentGroupPanelsContractTests.swift
            .deletingLastPathComponent() // AdjustmentUITests
            .deletingLastPathComponent() // Tests
    }()

    private static func loadSource(_ filename: String) throws -> String {
        try String(
            contentsOf: repositoryRootURL
                .appendingPathComponent("Sources/AdjustmentUI", isDirectory: true)
                .appendingPathComponent(filename),
            encoding: .utf8
        )
    }

    /// The shared slider row every sub-struct panel uses: it must reproduce
    /// `BasicAdjustmentPanel`'s macOS double-click-to-reset gesture, a
    /// context-menu reset item, and route every edit through
    /// `EditorSession.updateAdjustments(_:)` -- not `setAdjustment(_:to:)`,
    /// which has no case for these fields.
    func testSharedSliderRowReproducesTheBasicPanelsResetGesture() throws {
        let source = try Self.loadSource("AdjustmentSliderRow.swift")

        XCTAssertTrue(source.contains("#if os(macOS)"))
        XCTAssertTrue(source.contains(".onTapGesture(count: 2)"))
        XCTAssertTrue(source.contains("L10n.t(\"Double-click the row to reset\")"))
        XCTAssertTrue(source.contains("contextMenu"))
        XCTAssertTrue(source.contains("L10n.t(\"Reset\")"))
    }

    /// Phase 3 Task 3.3: the shared row must report drag start/end (via
    /// SwiftUI's own `Slider(value:in:onEditingChanged:)`), not just live
    /// value changes -- this is what lets `BasicAdjustmentPanel` (and any
    /// other panel built on this row) call `EditorSession.beginAdjustmentGesture()`
    /// /`.endAdjustmentGesture()` at the right two moments for batch sync.
    func testSharedSliderRowSupportsTheGestureLifecycle() throws {
        let source = try Self.loadSource("AdjustmentSliderRow.swift")

        XCTAssertTrue(source.contains("onEditingChanged: (Bool) -> Void"), "the row must accept a drag start/end callback")
        XCTAssertTrue(source.contains("onEditingChanged: onEditingChanged"), "it must actually be wired into the underlying Slider, not just declared")
    }

    func testColorPanelCoversAllEightHSLBandsWithHueSaturationAndLuminanceRows() throws {
        let source = try Self.loadSource("ColorAdjustmentPanel.swift")

        for band in ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"] {
            XCTAssertTrue(source.contains("\"\(band)\""), "the Color panel must label the \(band) HSL band")
        }
        for field in ["Hue", "Saturation", "Luminance"] {
            XCTAssertTrue(source.contains("\"\(field)\""), "the Color panel must label the \(field) row")
        }
        XCTAssertTrue(source.contains("L10n.t("), "band/field labels must be routed through localization")
        XCTAssertTrue(source.contains("editor.updateAdjustments"), "HSL edits must go through updateAdjustments(_:), which has no per-kind fast path")
        // One shared row builder used for all 8 bands * 3 fields, not one-off Sliders per band.
        XCTAssertTrue(
            source.contains("AdjustmentSliderRow("),
            "the Color panel must build its hue/saturation/luminance rows from the shared AdjustmentSliderRow, not one-off Sliders"
        )
    }

    func testDetailPanelCoversSharpeningAndNoiseReduction() throws {
        let source = try Self.loadSource("DetailAdjustmentPanel.swift")

        XCTAssertTrue(source.contains("L10n.t(\"Sharpening\")"))
        XCTAssertTrue(source.contains("L10n.t(\"Noise Reduction\")"))
        XCTAssertTrue(source.contains(".sharpening"))
        XCTAssertTrue(source.contains(".noiseReduction"))
        XCTAssertTrue(source.contains("editor.updateAdjustments"))
    }

    func testEffectsPanelCoversVignetteAndGrain() throws {
        let source = try Self.loadSource("EffectsAdjustmentPanel.swift")

        XCTAssertTrue(source.contains("L10n.t(\"Vignette\")"))
        XCTAssertTrue(source.contains("L10n.t(\"Grain\")"))
        XCTAssertTrue(source.contains(".vignette"))
        XCTAssertTrue(source.contains(".grain"))
        XCTAssertTrue(source.contains("editor.updateAdjustments"))
    }

    /// The curve panel has no fixed slider set (`AdvancedToneCurve.points`
    /// is an arbitrary-length array -- see that type's own doc comment), so
    /// its reset affordance is a plain, visible Reset button rather than a
    /// per-row gesture. It must still be disabled once the curve is already
    /// neutral, matching `InspectorView`'s existing top-level "Reset All"
    /// button's own disabled-when-nothing-to-reset behavior.
    func testCurvePanelHasAVisibleResetButtonDisabledWhenAlreadyNeutral() throws {
        let source = try Self.loadSource("CurveAdjustmentPanel.swift")

        XCTAssertTrue(source.contains("Button(L10n.t(\"Reset\")"))
        XCTAssertTrue(source.contains(".disabled("))
        XCTAssertTrue(source.contains("isIdentity"))
        XCTAssertTrue(source.contains("editor.updateAdjustments"))
    }

    /// Phase 2 Task 2.3: rotate/flip/straighten write through
    /// `updateAdjustments(_:)` like every other grouped panel; "Edit Crop"
    /// is the one control that instead switches `EditorSession.toolMode`
    /// (§6.5 needs an on-canvas overlay, not a slider, for the crop rect
    /// itself -- see `CropOverlayView`). The panel must also carry the
    /// required non-destructive safety copy and its own visible, disableable
    /// Reset, matching every other group's affordances.
    func testGeometryPanelCoversRotateFlipStraightenCropAndSafetyCopy() throws {
        let source = try Self.loadSource("GeometryAdjustmentPanel.swift")

        XCTAssertTrue(source.contains("rotatedClockwise()"), "must expose a rotate-right action")
        XCTAssertTrue(source.contains("rotatedCounterclockwise()"), "must expose a rotate-left action")
        XCTAssertTrue(source.contains("flippingHorizontal()"))
        XCTAssertTrue(source.contains("flippingVertical()"))
        XCTAssertTrue(source.contains("L10n.t(\"Straighten\")"))
        XCTAssertTrue(source.contains(".straightenDegrees"))
        XCTAssertTrue(source.contains("editor.updateAdjustments"), "rotate/flip/straighten must go through the same undo/autosave path every other panel uses")

        XCTAssertTrue(source.contains("editor.setToolMode("), "the crop tool must switch EditorSession.toolMode, not draw its own overlay logic here")
        XCTAssertTrue(source.contains(".crop"), "must be able to enter the .crop tool mode")
        XCTAssertTrue(source.contains("L10n.t(\"Edit Crop\")"))
        XCTAssertTrue(source.contains("L10n.t(\"Aspect Ratio\")"))
        XCTAssertTrue(source.contains("CropAspectRatio.freeform"))
        XCTAssertTrue(source.contains("CropAspectRatio.square"))

        XCTAssertTrue(
            source.contains("L10n.t(\"Geometry adjustments are non-destructive.\")"),
            "the panel must state the edit is non-destructive"
        )
        XCTAssertTrue(
            source.contains("L10n.t(\"Your RAW original was not changed.\")"),
            "the panel must state the RAW original is unchanged"
        )
        XCTAssertTrue(source.contains("Button(L10n.t(\"Reset\")"))
        XCTAssertTrue(source.contains("isIdentity"), "the panel's own Reset must disable once geometry is already neutral")
    }
}
