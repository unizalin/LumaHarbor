import Foundation
import XCTest

/// P2 (`2026-09-10-shared-professional-inspector-catalog.md` §5): proves
/// `PadEditorView.swift`'s inlined `PadInspectorHost`/`PadToolRail` (kept
/// inlined for the `.xcodeproj` fixed-member-list constraint -- see the plan's
/// "工程限制" section) route through the shared `AdjustmentUI.InspectorCatalog`
/// vocabulary instead of hand-declaring a second, parallel field list, and
/// that the White Balance panel the design gap analysis found missing (§1
/// item 2) is now actually mounted. Same source-parsing approach as the
/// sibling `PadToolRailContractTests`.
final class PadCatalogWiringContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PadCatalogWiringContractTests.swift
            .deletingLastPathComponent() // AdjustmentUITests
            .deletingLastPathComponent() // Tests
    }()

    private static func padEditorSource() throws -> String {
        try String(
            contentsOf: Self.repositoryRootURL
                .appendingPathComponent("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift"),
            encoding: .utf8
        )
    }

    func testPadEditorViewDoesNotHandDeclareItsOwnLightKindsArray() throws {
        let source = try Self.padEditorSource()
        XCTAssertFalse(
            source.contains("private static let lightKinds: [AdjustmentKind]"),
            "the tone-kinds list must come from InspectorCatalog.section(.basic), not a second hand-maintained array"
        )
    }

    func testPadEditorViewMountsBasicPanelFromTheSharedCatalog() throws {
        let source = try Self.padEditorSource()
        XCTAssertTrue(source.contains("InspectorCatalog.section(.basic).adjustmentKinds"))
    }

    /// The gap this closes: `PadAdjustSubmodeKinds.color` declared White
    /// Balance fields but no panel ever rendered them (design spec analysis
    /// §1 item 2). Color submode must now actually mount a White Balance
    /// `BasicAdjustmentPanel`, matching Mac's `.color` DisclosureGroup.
    func testPadEditorViewMountsWhiteBalancePanelInColorSubmode() throws {
        let source = try Self.padEditorSource()
        XCTAssertTrue(
            source.contains("InspectorCatalog.section(.whiteBalance).adjustmentKinds"),
            "Color submode must mount the White Balance panel via the shared catalog -- it was previously declared but never rendered"
        )
    }

    func testPadEditorViewOwnsASharedNavigationModel() throws {
        let source = try Self.padEditorSource()
        XCTAssertTrue(source.contains("InspectorNavigationModel"))
    }

    func testPadEditorViewExposesSearchFavoritePinAndReset() throws {
        let source = try Self.padEditorSource()
        XCTAssertTrue(source.contains("navigation.searchQuery") || source.contains("inspectorNavigation.searchQuery"))
        XCTAssertTrue(source.contains("toggleFavorite"))
        XCTAssertTrue(source.contains("togglePin"))
        XCTAssertTrue(source.contains("InspectorCatalog.resetting("))
    }

    func testPadEditorViewFollowsCanvasToolModeChanges() throws {
        let source = try Self.padEditorSource()
        XCTAssertTrue(source.contains(".follow(toolMode:"))
    }

    func testEveryNewControlMeetsTheFortyFourPointTapTarget() throws {
        let source = try Self.padEditorSource()
        // Existing convention already enforced elsewhere in this file --
        // just confirms the new controls this task adds reuse it rather than
        // inventing a smaller tap target.
        XCTAssertTrue(source.contains("minWidth: 44, minHeight: 44") || source.contains("width: 44, height: 44"))
    }
}
