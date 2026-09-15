import Foundation
import XCTest

/// Inspector hierarchy/typography/preview-responsiveness spec (2026-09-14)
/// §5.2/§5.6: "Changing the selected band must not render the photo, write
/// history, save the sidecar, or reset any values" and "Group expansion,
/// histogram collapse, HSL band selection...submit zero photo previews."
///
/// The real guarantee is architectural, not a runtime flag to assert on: the
/// band-selector view has no reference to `EditorSession`/`EditorCore` at
/// all, so there is no code path by which selecting a band could reach the
/// preview scheduler, undo history, or sidecar writer. These tests pin that
/// architecture so a future change can't quietly reintroduce a dependency
/// that would make band selection capable of triggering a render.
final class ZeroRenderPresentationContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ZeroRenderPresentationContractTests.swift
            .deletingLastPathComponent() // AdjustmentUITests
            .deletingLastPathComponent() // Tests
    }()

    private static func loadSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRootURL.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testHSLBandGridSelectorHasNoDependencyOnEditorCoreOrRawProcessingRender() throws {
        let source = try Self.loadSource("Sources/AdjustmentUI/HSLBandGridSelector.swift")

        XCTAssertFalse(source.contains("import EditorCore"), "the band selector must not depend on EditorSession -- selecting a band must be architecturally incapable of rendering, writing history, or saving")
    }

    func testHSLBandSelectorModelHasNoDependencyOnEditorCore() throws {
        let source = try Self.loadSource("Sources/AdjustmentUI/HSLBandSelectorModel.swift")

        XCTAssertFalse(source.contains("import EditorCore"))
    }

    /// The Level 1 disclosure toggle itself (`expandedGroups`) must be a
    /// plain `Set<InspectorGroup>` mutation, never a call into `model.editor`
    /// -- collapsing/expanding a group must never render, write history, or
    /// save. `inspectorGroup(...)` builds its own header (not a native
    /// `DisclosureGroup`) so the toggle lives directly in a `Button`'s
    /// action closure rather than an `isExpanded: Binding(...)` -- see
    /// `InspectorSharedCatalogContractTests
    /// .testLevel1ExpandedContentIsIndentedRelativeToItsOwnHeader` for why.
    func testInspectorViewDisclosureToggleOnlyMutatesLocalExpansionState() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/InspectorView.swift")
        guard let functionRange = source.range(of: "private func inspectorGroup") else {
            XCTFail("could not locate inspectorGroup(_:sectionID:title:content:) in InspectorView.swift")
            return
        }
        let afterFunction = source[functionRange.lowerBound...]
        guard let buttonRange = afterFunction.range(of: "Button {") else {
            XCTFail("could not locate the disclosure toggle Button in InspectorView.swift")
            return
        }
        guard let labelRange = afterFunction.range(of: "} label: {", range: buttonRange.upperBound..<afterFunction.endIndex) else {
            XCTFail("could not locate the disclosure toggle Button's label boundary in InspectorView.swift")
            return
        }
        let toggleActionBlock = String(afterFunction[buttonRange.upperBound..<labelRange.lowerBound])
        XCTAssertTrue(toggleActionBlock.contains("expandedGroups.insert"))
        XCTAssertTrue(toggleActionBlock.contains("expandedGroups.remove"))
        XCTAssertFalse(toggleActionBlock.contains("model.editor."), "toggling a group's disclosure must never call into EditorSession")
    }

    /// The histogram's own collapse toggle must be pure local `@State` --
    /// nothing about it may reach `EditorSession`.
    func testHistogramPanelCollapseToggleHasNoDependencyOnEditorCore() throws {
        let source = try Self.loadSource("Sources/AdjustmentUI/HistogramPanel.swift")

        XCTAssertTrue(source.contains("isCollapsed.toggle()"))
        XCTAssertFalse(source.contains("import EditorCore"))
        XCTAssertFalse(source.contains("EditorSession"))
    }

    /// Every continuous-adjustment panel the spec names (§5.6's migration
    /// list) must share the same preview/commit transaction, not a
    /// per-panel reinvention.
    func testEveryMigratedContinuousPanelSharesThePreviewCommitTransaction() throws {
        for filename in [
            "BasicAdjustmentPanel.swift", "ColorAdjustmentPanel.swift", "ColorGradingAdjustmentPanel.swift",
            "DetailAdjustmentPanel.swift", "EffectsAdjustmentPanel.swift", "PresenceAdjustmentPanel.swift",
        ] {
            let source = try Self.loadSource("Sources/AdjustmentUI/\(filename)")
            XCTAssertTrue(source.contains("onPreview:"), "\(filename) must preview drags through the shared transaction")
            XCTAssertTrue(source.contains("previewContinuousEdit"), "\(filename) must call EditorSession.previewContinuousEdit")
            XCTAssertTrue(source.contains("onCommitPreview:"), "\(filename) must commit exactly once at gesture end")
            XCTAssertTrue(source.contains("commitContinuousEdit()"), "\(filename) must call EditorSession.commitContinuousEdit()")
        }
    }
}
