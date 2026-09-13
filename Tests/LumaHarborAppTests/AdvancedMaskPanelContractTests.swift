import Foundation
import XCTest

/// Keeps the shared mask inspector honest about the geometry fields exposed
/// by the renderer. The panel is source-checked here because SwiftUI's view
/// tree is not available to the headless test target.
final class AdvancedMaskPanelContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private static func panelSource() throws -> String {
        try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent(
                "Sources/AdjustmentUI/LocalAdjustmentsPanel.swift",
                isDirectory: false
            ),
            encoding: .utf8
        )
    }

    func testPanelExposesGeometryControlsForEveryParametricMask() throws {
        let source = try Self.panelSource()

        for field in [
            "geometry.x",
            "geometry.y",
            "geometry.radius",
            "geometry.radialRadiusY",
            "geometry.feather",
            "geometry.luminanceMin",
            "geometry.luminanceMax",
            "geometry.colorTargetHue",
            "geometry.colorHueTolerance"
        ] {
            XCTAssertTrue(source.contains(field), "selected mask panel must expose \(field)")
        }
    }

    func testPanelKeepsLuminanceBoundsOrdered() throws {
        let source = try Self.panelSource()
        XCTAssertTrue(source.contains("luminanceMin = Swift.min"))
        XCTAssertTrue(source.contains("luminanceMax = Swift.max"))
    }

    func testSelectingNonLinearMaskLeavesLinearCanvasEditingMode() throws {
        let source = try Self.panelSource()
        XCTAssertTrue(source.contains("mask.kind == .linearGradient"))
        XCTAssertTrue(source.contains("editor.toolMode == .linearGradient"))
        XCTAssertTrue(source.contains("editor.setToolMode(.adjust)"))
    }

    func testEditMasksButtonRequiresASelectedLinearMask() throws {
        let source = try Self.panelSource()
        XCTAssertTrue(source.contains("selectedMaskIsLinear"))
        XCTAssertTrue(source.contains("!selectedMaskIsLinear"))
    }
}
