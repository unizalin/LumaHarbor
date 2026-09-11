import Foundation
import XCTest

final class CurveHistogramContractTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testCurvePanelKeepsTheInteractiveGraphAndGestureLifecycle() throws {
        let source = try source("Sources/AdjustmentUI/CurveAdjustmentPanel.swift")

        XCTAssertTrue(source.contains("ToneCurveGraph("))
        XCTAssertTrue(source.contains("ToneCurveChannel.allCases"))
        XCTAssertTrue(source.contains("Canvas"))
        XCTAssertTrue(source.contains("DragGesture(minimumDistance: 0)"))
        XCTAssertTrue(source.contains("editor.beginAdjustmentGesture()"))
        XCTAssertTrue(source.contains("editor.endAdjustmentGesture()"))
        XCTAssertTrue(source.contains("Button(L10n.t(\"Reset Channel\")"))
        XCTAssertTrue(source.contains("Button(L10n.t(\"Reset All\")"))
    }

    func testPadInfoDomainUsesTheSharedHistogramInsteadOfAPlaceholder() throws {
        let host = try source("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadInspectorHost.swift")
        let inlinedHost = try source("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift")

        XCTAssertTrue(host.contains("HistogramPanel(histogram: editor.histogram)"))
        XCTAssertFalse(host.contains("EXIF metadata and histogram are not yet wired."))
        XCTAssertTrue(inlinedHost.contains("HistogramPanel(histogram: histogram)"))
    }
}
