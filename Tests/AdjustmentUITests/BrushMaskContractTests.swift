import Foundation
import XCTest

final class BrushMaskContractTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    func testIndependentOverlayConsumesTypedBrushSessionAndAuthoritativeMapping() throws {
        let path = "Sources/AdjustmentUI/BrushMaskOverlayView.swift"
        let source = try source(path)
        XCTAssertTrue(source.contains("public struct BrushMaskOverlayView"))
        XCTAssertTrue(source.contains("beginBrushMaskGesture"))
        XCTAssertTrue(source.contains("appendBrushMaskPoint"))
        XCTAssertTrue(source.contains("endBrushMaskGesture"))
        XCTAssertTrue(source.contains("cancelBrushMaskGesture"))
        XCTAssertTrue(source.contains("BrushCoordinateMapping"))
        XCTAssertTrue(source.contains("sourceToDisplay"))
        XCTAssertTrue(source.contains("sourceExtent"))
    }

    func testLegacyBrushAndAdjustmentBrushUseSeparateModesAndOverlays() throws {
        let legacy = try source("Sources/AdjustmentUI/MaskOverlayViews.swift")
        XCTAssertTrue(legacy.contains("LegacyBrushMaskOverlayView"))
        XCTAssertFalse(legacy.contains("public struct BrushMaskOverlayView"))

        let mac = try source("Sources/LumaHarborApp/Views/EditorView.swift")
        let pad = try source("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorCanvasView.swift")
        for canvas in [mac, pad] {
            XCTAssertTrue(canvas.contains("toolMode == .brush"))
            XCTAssertTrue(canvas.contains("LegacyBrushMaskOverlayView"))
            XCTAssertTrue(canvas.contains("toolMode == .brushMask"))
            XCTAssertTrue(canvas.contains("BrushMaskOverlayView"))
        }
    }

    func testPanelKeepsLegacyMasksAndAddsIndependentBrushControls() throws {
        let panel = try source("Sources/AdjustmentUI/LocalAdjustmentsPanel.swift")
        XCTAssertTrue(panel.contains("legacyMasks") || panel.contains("masks"))
        XCTAssertTrue(panel.contains("brushMasks"))
        for key in [
            "Adjustment Brush", "Add Adjustment Brush", "Paint", "Erase", "Size",
            "Feather", "Flow", "Density", "Exposure", "Delete Adjustment Brush"
        ] {
            let localized = panel.contains("L10n.t(\"\(key)\")") || panel.contains("brushSlider(label: \"\(key)\"")
            XCTAssertTrue(localized, "missing localized brush control: \(key)")
        }
        for key in ["addBrushMask", "selectBrushMask", "deleteBrushMask", "setToolMode(.brushMask)"] {
            XCTAssertTrue(panel.contains(key), "missing brush workflow: \(key)")
        }
    }

    func testBrushControlsHaveStableTouchTargetsAndAccessibilityHooks() throws {
        let overlay = try source("Sources/AdjustmentUI/BrushMaskOverlayView.swift")
        let panel = try source("Sources/AdjustmentUI/LocalAdjustmentsPanel.swift")
        XCTAssertGreaterThanOrEqual(overlay.components(separatedBy: ".frame(width: imageFrame.width").count - 1, 1)
        XCTAssertTrue(overlay.contains("accessibilityLabel"))
        XCTAssertTrue(overlay.contains("accessibilityIdentifier"))
        XCTAssertGreaterThanOrEqual(panel.components(separatedBy: ".frame(minHeight: 44").count - 1, 3)
    }

    func testBrushSettingsCoverPaintEraseFootprintAndExposurePatch() throws {
        let overlay = try source("Sources/AdjustmentUI/BrushMaskOverlayView.swift")
        let panel = try source("Sources/AdjustmentUI/LocalAdjustmentsPanel.swift")
        for key in ["BrushMaskStrokeMode.paint", "BrushMaskStrokeMode.erase", "size", "feather", "flow", "density"] {
            XCTAssertTrue(overlay.contains(key) || panel.contains(key), "missing brush setting: \(key)")
        }
        XCTAssertTrue(panel.contains("adjustments.exposure"))
        XCTAssertTrue(overlay.contains("displayDiameter"))
    }

    func testBrushGestureFeedsOptInUIHeartbeatProbeWithoutReplacingProductGestureFlow() throws {
        let overlay = try source("Sources/AdjustmentUI/BrushMaskOverlayView.swift")
        XCTAssertTrue(overlay.contains("BrushUIPerformanceProbe.shared.activate"))
        XCTAssertTrue(overlay.contains("BrushUIPerformanceProbe.shared.beginGesture"))
        XCTAssertTrue(overlay.contains("BrushUIPerformanceProbe.shared.requestGestureEnd"))
        XCTAssertTrue(overlay.contains("BrushUIPerformanceProbe.shared.previewFrameBecameVisible"))
        XCTAssertTrue(overlay.contains("BrushUIPerformanceProbe.shared.cancelGesture"))
        XCTAssertTrue(overlay.contains("editor.renderState.$previewImage"))
        XCTAssertFalse(overlay.contains("editor.$previewImage"))
        XCTAssertTrue(overlay.contains("beginBrushMaskGesture"))
        XCTAssertTrue(overlay.contains("appendBrushMaskPoint"))
        XCTAssertTrue(overlay.contains("endBrushMaskGesture"))
    }

    func testExistingBrushStrokesUseOneCanvasPerMaskInsteadOfOneViewPerStroke() throws {
        let overlay = try source("Sources/AdjustmentUI/BrushMaskOverlayView.swift")
        XCTAssertTrue(overlay.contains("Canvas { context"))
        XCTAssertFalse(overlay.contains("ForEach(mask.strokes)"))
        XCTAssertTrue(overlay.contains("context.stroke"))
        XCTAssertTrue(overlay.contains("stroke.mode == .erase ? .orange : .accentColor"))
        XCTAssertTrue(overlay.contains("displayDiameter(stroke: stroke, mapping: mapping)"))
    }
}
