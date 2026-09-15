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

    /// The shared slider row every sub-struct panel uses: it must provide an
    /// explicit context-menu reset item and route every edit through
    /// `EditorSession.updateAdjustments(_:)` -- not `setAdjustment(_:to:)`,
    /// which has no case for these fields. Selecting a label must not reset it.
    func testSharedSliderRowProvidesExplicitResetWithoutLabelSelectionReset() throws {
        let source = try Self.loadSource("AdjustmentSliderRow.swift")

        XCTAssertFalse(source.contains(".onTapGesture(count: 2)"))
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
        XCTAssertTrue(source.contains("onEditingChanged: { isEditing in"), "it must actually be wired into the underlying Slider, not just declared")
        XCTAssertTrue(source.contains("onEditingChanged(isEditing)"), "the caller's begin/end hook must still fire")
    }

    /// Inspector hierarchy/typography/preview spec (2026-09-14) §5.4/§5.6:
    /// the one shared row must not rely on 80% label scaling, must switch
    /// composition at the shared 340pt threshold, and must expose the
    /// preview/commit transaction hooks every continuous control migrates to.
    func testSharedSliderRowIsAdaptiveAndSupportsTheContinuousEditTransaction() throws {
        let source = try Self.loadSource("AdjustmentSliderRow.swift")

        XCTAssertFalse(source.contains(".minimumScaleFactor(0.8)"), "the shared row must not rely on 80% label scaling")
        XCTAssertTrue(source.contains("AdaptiveRowContainer"), "the shared row must switch composition at the shared width threshold")
        XCTAssertTrue(source.contains("onPreview"), "the shared row must accept a continuous-drag preview write")
        XCTAssertTrue(source.contains("onCommitPreview"), "the shared row must accept a one-shot commit at gesture end")
    }

    /// Inspector hierarchy/typography spec (2026-09-14) §5.2: the eight HSL
    /// bands now come from the shared `HSLBandID`/`HSLBandSelectorModel`
    /// adaptive selector, not per-band literal labels inside
    /// `ColorAdjustmentPanel.swift` itself -- so the band-name coverage
    /// check moves to `HSLBandSelectorModel.swift`, while the panel itself
    /// is checked for the Hue/Saturation/Luminance field rows, the adaptive
    /// selector, and the no-nested-disclosure contract.
    func testColorPanelCoversAllEightHSLBandsWithHueSaturationAndLuminanceRows() throws {
        let bandModelSource = try Self.loadSource("HSLBandSelectorModel.swift")
        for band in ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"] {
            XCTAssertTrue(bandModelSource.contains(band), "the shared band model must declare the \(band) HSL band")
        }

        let source = try Self.loadSource("ColorAdjustmentPanel.swift")
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
        XCTAssertTrue(
            source.contains("HSLBandGridSelector("),
            "the Color panel must present bands through the shared adaptive grid selector, not per-band disclosure groups"
        )
        XCTAssertFalse(
            source.contains("DisclosureGroup(L10n.t(band"),
            "the Color panel must not reintroduce one nested DisclosureGroup per HSL band"
        )
    }

    func testColorPanelUsesARealSecondLevelSectionAndCumulativeThirdLevelInset() throws {
        let source = try Self.loadSource("ColorAdjustmentPanel.swift")

        XCTAssertTrue(
            source.contains("Level2DisclosureGroup(L10n.t(\"HSL\"), initiallyExpanded: true)"),
            "HSL must be a visibly distinct Level 2 disclosure under the Level 1 Color group"
        )
        XCTAssertTrue(
            source.contains("Level2Section(L10n.t(\"Black & White\")"),
            "Black & White must use the same Level 2 hierarchy rather than align with Level 3 controls"
        )
    }

    func testDetailPanelCoversSharpeningAndNoiseReduction() throws {
        let source = try Self.loadSource("DetailAdjustmentPanel.swift")

        XCTAssertTrue(source.contains("L10n.t(\"Sharpening\")"))
        XCTAssertTrue(source.contains("L10n.t(\"Noise Reduction\")"))
        XCTAssertTrue(source.contains(".sharpening"))
        XCTAssertTrue(source.contains(".noiseReduction"))
        XCTAssertTrue(source.contains("editor.updateAdjustments"))

        let disclosureCount = source.components(separatedBy: "Level2DisclosureGroup(").count - 1
        XCTAssertEqual(
            disclosureCount,
            2,
            "Detail may disclose Sharpening and Noise Reduction, but Luminance and Color must be Level 3 headings rather than nested Level 2 disclosures"
        )
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
    /// per-row gesture. P3 (per-channel curves) splits this into two
    /// buttons -- "Reset Channel" (only the selected Composite/R/G/B curve)
    /// and "Reset All" (every channel) -- each independently disabled once
    /// its own scope is already neutral, matching `InspectorView`'s existing
    /// top-level "Reset All" button's own disabled-when-nothing-to-reset
    /// behavior.
    func testCurvePanelHasVisibleResetButtonsDisabledWhenAlreadyNeutral() throws {
        let source = try Self.loadSource("CurveAdjustmentPanel.swift")

        XCTAssertTrue(source.contains("Button(L10n.t(\"Reset Channel\")"))
        XCTAssertTrue(source.contains("Button(L10n.t(\"Reset All\")"))
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
            source.contains("GridItem(.adaptive(minimum: 96)") && source.contains(".frame(maxWidth: .infinity, minHeight: 44)"),
            "rotate and flip controls must reflow into readable, tappable cells on narrow iPad inspectors"
        )

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
