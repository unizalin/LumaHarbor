import Foundation
import XCTest

/// P2 (`2026-09-10-shared-professional-inspector-catalog.md` §5): proves Mac's
/// `InspectorView` actually wires up the shared `InspectorCatalog`/
/// `InspectorNavigationModel` -- search, favorites, pin, smart follow, and
/// section/domain reset -- rather than these types existing unused in
/// `AdjustmentUI`. Same source-parsing approach as the sibling
/// `InspectorAdjustmentGroupsContractTests` (no SwiftUI view-inspection
/// dependency in this package).
final class InspectorSharedCatalogContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // InspectorSharedCatalogContractTests.swift
            .deletingLastPathComponent() // LumaHarborAppTests
            .deletingLastPathComponent() // Tests
    }()

    private static func inspectorSource() throws -> String {
        try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent("Sources/LumaHarborApp/Views/InspectorView.swift"),
            encoding: .utf8
        )
    }

    func testInspectorViewOwnsTheSharedNavigationModel() throws {
        let source = try Self.inspectorSource()
        XCTAssertTrue(source.contains("InspectorNavigationModel()"),
                      "InspectorView must attach the shared navigation model, not a Mac-only reimplementation")
    }

    func testInspectorViewExposesASearchFieldBoundToTheSharedModel() throws {
        let source = try Self.inspectorSource()
        XCTAssertTrue(source.contains("navigation.searchQuery"))
        XCTAssertTrue(source.contains("L10n.t(\"Search Adjustments\")"))
    }

    func testInspectorViewExposesFavoriteTogglesThroughTheSharedModel() throws {
        let source = try Self.inspectorSource()
        XCTAssertTrue(source.contains("navigation.toggleFavorite"))
        XCTAssertTrue(source.contains("navigation.isFavorite"))
    }

    func testInspectorViewExposesAPinToggle() throws {
        let source = try Self.inspectorSource()
        XCTAssertTrue(source.contains("navigation.togglePin()"))
        XCTAssertTrue(source.contains("navigation.isPinned"))
    }

    func testInspectorViewFollowsCanvasToolModeChanges() throws {
        let source = try Self.inspectorSource()
        XCTAssertTrue(source.contains("navigation.follow(toolMode:"))
        XCTAssertTrue(source.contains("model.editor.toolMode"))
    }

    func testInspectorViewOffersSectionAndDomainResetThroughTheSharedCatalog() throws {
        let source = try Self.inspectorSource()
        XCTAssertTrue(source.contains("InspectorCatalog.resetting("), "section/domain reset must route through InspectorCatalog, not a duplicated reset routine")
        XCTAssertTrue(source.contains("InspectorCatalog.isNeutral("))
        XCTAssertTrue(source.contains("L10n.t(\"Reset Adjust\")"))
        XCTAssertTrue(source.contains("L10n.t(\"Reset Geometry\")"))
        XCTAssertTrue(source.contains("L10n.t(\"Reset Local Adjustments\")"))
    }

    func testInspectorViewDoesNotDeclareItsOwnSeparateFieldVocabulary() throws {
        let source = try Self.inspectorSource()
        XCTAssertFalse(source.contains("static let toneKinds: [AdjustmentKind] = [\n"),
                       "tone kinds must be derived from InspectorCatalog, not hand-duplicated")
    }
}
