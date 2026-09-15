import Foundation
import XCTest
@testable import AdjustmentUI

final class BasicAdjustmentPanelModelTests: XCTestCase {
    func testRowsComeFromTheCanonicalAdjustmentCatalog() {
        XCTAssertEqual(BasicAdjustmentPanelModel.rows.count, 10)
        XCTAssertEqual(Set(BasicAdjustmentPanelModel.rows.map(\.kind.rawValue)).count, 10)
    }

    func testExposureIsFirstAndSaturationIsLast() {
        XCTAssertEqual(BasicAdjustmentPanelModel.rows.first?.kind, .exposure)
        XCTAssertEqual(BasicAdjustmentPanelModel.rows.last?.kind, .saturation)
    }

    func testPositiveValuesCarryAPlusSign() {
        XCTAssertEqual(BasicAdjustmentPanelModel.formatted(1.25, fractionDigits: 2), "+1.25")
        XCTAssertEqual(BasicAdjustmentPanelModel.formatted(0, fractionDigits: 0), "0")
    }

    func testLabelSelectionDoesNotResetTheAdjustment() throws {
        let panelSource = try panelSource()

        // The reset gesture itself now lives once in the shared row
        // (`AdjustmentGroupPanelsContractTests
        // .testSharedSliderRowProvidesExplicitResetWithoutLabelSelectionReset`)
        // -- this only has to confirm the panel neither reinvents a
        // double-click reset nor drops its own reset wiring.
        XCTAssertFalse(panelSource.contains(".onTapGesture(count: 2)"))
        XCTAssertTrue(panelSource.contains("editor.resetAdjustment(definition.kind)"))
    }

    func testViewUsesCanonicalRowsWithoutGroupReordering() throws {
        let panelSource = try panelSource()

        XCTAssertTrue(panelSource.contains("ForEach(BasicAdjustmentPanelModel.rows, id: \\.kind)"))
        XCTAssertFalse(panelSource.contains("AdjustmentGroup.allCases"))
        XCTAssertFalse(panelSource.contains("AdjustmentCatalog.definitions(in:"))
    }

    /// Phase 3 Task 3.3: the ten basic sliders are where batch sync's
    /// gesture snapshot must actually begin/end -- `editor.beginAdjustmentGesture()`
    /// on drag start, `editor.endAdjustmentGesture()` on drag end -- so a
    /// caller with thumbnail multi-select active can snapshot/sync the
    /// batch around exactly this drag, not some other moment.
    func testBasicSlidersWireTheAdjustmentGestureLifecycle() throws {
        let panelSource = try panelSource()

        XCTAssertTrue(panelSource.contains("onEditingChanged:"), "the basic sliders must report drag start/end, not just live value changes")
        XCTAssertTrue(panelSource.contains("editor.beginAdjustmentGesture()"))
        XCTAssertTrue(panelSource.contains("editor.endAdjustmentGesture()"))
    }

    /// Inspector hierarchy/typography spec (2026-09-14) §5.3/§5.4: the ten
    /// basic rows must not fall back to 80% label scaling, and must build on
    /// the one shared adaptive row (`AdjustmentSliderRow`) rather than a
    /// second, duplicated row layout.
    func testBasicRowsUseTheSharedAdaptiveRowWithoutLabelScaling() throws {
        let panelSource = try panelSource()

        XCTAssertFalse(panelSource.contains(".minimumScaleFactor(0.8)"), "basic rows must not rely on 80% label scaling")
        XCTAssertTrue(panelSource.contains("AdjustmentSliderRow("), "basic rows must build on the one shared adaptive row")
    }

    /// The preview/commit transaction (spec §5.6) must be wired at the
    /// slider-drag call site, not just declared on `EditorSession` -- a
    /// migrated panel passes both `onPreview` and `onCommitPreview`.
    func testBasicSlidersWireTheContinuousEditTransaction() throws {
        let panelSource = try panelSource()

        XCTAssertTrue(panelSource.contains("onPreview:"), "the slider drag must preview through the shared transaction")
        XCTAssertTrue(panelSource.contains("editor.previewContinuousEdit"))
        XCTAssertTrue(panelSource.contains("onCommitPreview:"), "the slider drag must commit exactly once at gesture end")
        XCTAssertTrue(panelSource.contains("editor.commitContinuousEdit()"))
    }

    private func panelSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AdjustmentUI/BasicAdjustmentPanel.swift"),
            encoding: .utf8
        )
    }
}
