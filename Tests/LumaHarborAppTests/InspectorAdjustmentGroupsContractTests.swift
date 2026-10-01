import Foundation
import XCTest

/// Same source-parsing approach as `InspectorMetadataContractTests` -- see
/// that file's own header comment for why. AwayPhotoRawEditor parity Phase 1
/// Task 3: the Mac inspector must present the existing adjustment model as
/// clearly labeled, grouped panels -- Basic, Color, Curve, Detail, Effects
/// (design spec §6.3) -- not one flat list, and every group must actually be
/// reachable from `InspectorView`, not merely exist as an unused type
/// somewhere in `AdjustmentUI`.
final class InspectorAdjustmentGroupsContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // InspectorAdjustmentGroupsContractTests.swift
            .deletingLastPathComponent() // LumaHarborAppTests
            .deletingLastPathComponent() // Tests
    }()

    private static func loadSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRootURL.appendingPathComponent(relativePath, isDirectory: false),
            encoding: .utf8
        )
    }

    private static func inspectorSource() throws -> String {
        try loadSource("Sources/LumaHarborApp/Views/InspectorView.swift")
    }

    /// Acceptance: "Every existing `AdjustmentKind` is reachable in Mac UI."
    /// `BasicAdjustmentPanel` already covers every `AdjustmentKind` (see
    /// `BasicAdjustmentPanelModelTests`); this only has to prove the
    /// inspector still actually mounts it, under a visible "Basic" header.
    func testInspectorViewMountsTheBasicPanelUnderALocalizedBasicHeader() throws {
        let source = try Self.inspectorSource()

        XCTAssertTrue(source.contains("L10n.t(\"Basic\")"), "the basic-adjustments group must have a visible, localized header")
        XCTAssertTrue(source.contains("BasicAdjustmentPanel(editor:"), "the Basic group must mount BasicAdjustmentPanel, which already covers every AdjustmentKind")
    }

    func testWhiteBalanceIsMountedInsideTheBasicAdjustmentFlow() throws {
        let source = try Self.inspectorSource()
        guard
            let basicStart = source.range(of: "inspectorGroup(.basic"),
            let colorStart = source.range(of: "inspectorGroup(.color")
        else {
            XCTFail("InspectorView must retain Basic and Color groups")
            return
        }

        let basicSource = String(source[basicStart.lowerBound..<colorStart.lowerBound])
        XCTAssertTrue(
            basicSource.contains("whiteBalanceKinds"),
            "white balance must be reachable in the Basic group before tone controls"
        )
        XCTAssertTrue(
            basicSource.contains("WhiteBalanceEyedropperButton"),
            "the Basic group must keep the white-balance eyedropper beside the controls"
        )
    }

    /// The four groups the design spec adds beyond the ten basic sliders --
    /// each must have its own localized header and mount its own panel.
    func testInspectorViewMountsEveryNewGroupWithALocalizedHeader() throws {
        let source = try Self.inspectorSource()

        let groups: [(header: String, panelConstructorPrefix: String)] = [
            ("Color", "ColorAdjustmentPanel(editor:"),
            ("Curve", "CurveAdjustmentPanel(editor:"),
            ("Detail", "DetailAdjustmentPanel(editor:"),
            ("Effects", "EffectsAdjustmentPanel(editor:"),
            ("Geometry", "GeometryAdjustmentPanel(editor:")
        ]
        for group in groups {
            XCTAssertTrue(
                source.contains("L10n.t(\"\(group.header)\")"),
                "the \(group.header) group must have a visible, localized header"
            )
            XCTAssertTrue(
                source.contains(group.panelConstructorPrefix),
                "the \(group.header) group must actually mount \(group.panelConstructorPrefix)…)"
            )
        }
    }

    func testInspectorOffersSoloModeAndPersistentGroupPinning() throws {
        let source = try Self.inspectorSource()

        XCTAssertTrue(source.contains("soloMode"), "Solo Mode must be a workspace preference, not photo state")
        XCTAssertTrue(source.contains("workspaceSoloMode"), "Solo Mode needs a stable persisted workspace key")
        XCTAssertTrue(source.contains("pinnedGroups"), "the inspector must track pinned groups separately from expansion state")
        XCTAssertTrue(source.contains("Pin Group"))
        XCTAssertTrue(source.contains("Unpin Group"))
    }

    func testGeometryIsNotWrappedInAnAdditionalSameNameDisclosureGroup() throws {
        let source = try Self.inspectorSource()

        XCTAssertTrue(source.contains("geometrySection"), "Geometry should have a direct section entry")
        XCTAssertFalse(source.contains("inspectorGroup(.geometry"), "Geometry must not be nested in a same-name outer disclosure")
    }

    /// Every new panel referenced by `InspectorView` must actually exist as
    /// a public view in `AdjustmentUI` -- catches a header added with no
    /// corresponding panel ever built.
    func testEveryNewAdjustmentPanelSourceFileExists() throws {
        for filename in [
            "ColorAdjustmentPanel.swift", "CurveAdjustmentPanel.swift", "DetailAdjustmentPanel.swift",
            "EffectsAdjustmentPanel.swift", "GeometryAdjustmentPanel.swift"
        ] {
            let source = try Self.loadSource("Sources/AdjustmentUI/\(filename)")
            XCTAssertTrue(source.contains("public struct"), "\(filename) must define a public SwiftUI view usable from LumaHarborApp")
        }
    }
}
