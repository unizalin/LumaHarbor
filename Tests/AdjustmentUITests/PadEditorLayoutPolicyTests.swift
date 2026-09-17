import CoreGraphics
import EditorCore
import Foundation
import PhotoLibraryCore
import XCTest
@testable import AdjustmentUI

/// `PadEditorLayoutPolicy` is a pure function of width/height with no
/// SwiftUI dependency, so every case here is a plain value comparison —
/// no view hierarchy, no live device, no rotation simulation needed.
///
/// EditorSession undo invariants remain covered by the dedicated
/// `EditorSessionEditingTests` suite; this class owns only layout policy.
@MainActor
final class PadEditorLayoutPolicyTests: XCTestCase {

    // MARK: - Landscape / portrait (spec examples)

    func testLandscapeUsesDock() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 1180, height: 820), .trailingDock)
    }

    func testPortraitUsesBottomDrawer() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 820, height: 1180), .bottomDrawer)
    }

    func testCompactInspectorUsesOneCustomScrollableSurfaceInsteadOfASystemSheet() throws {
        let source = try Self.padEditorViewSource()
        XCTAssertFalse(source.contains(".sheet(isPresented: $isDrawerPresented"))
        XCTAssertFalse(source.contains(".presentationDetents"))
        XCTAssertTrue(source.contains("movableInspectorPanel(for: size)"))
        XCTAssertTrue(source.contains(".frame(maxHeight: PadEditorLayoutPolicy.movableInspectorHeight(for: size))"))
        XCTAssertTrue(source.contains("ScrollView"), "the compact Inspector must scroll inside its bounded overlay")
    }

    func testDockAndMovableInspectorShareOneContentComposition() throws {
        let source = try Self.padEditorViewSource()
        XCTAssertTrue(source.contains("private var inspectorPanelHeader: some View"))
        XCTAssertTrue(source.contains("private var inspectorPanelContent: some View"))
        XCTAssertTrue(source.contains("trailingDockPanel(width:") && source.contains("movableInspectorPanel(for:"))
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "inspectorPanelContent").count - 1,
            3,
            "the trailing dock and movable overlay must render one shared Inspector surface"
        )
        XCTAssertEqual(
            source.components(separatedBy: "PadInspectorHost(").count - 1,
            1,
            "the host should be composed once, inside inspectorPanelContent"
        )
    }

    func testCompactInspectorMovesWithoutChangingDocumentState() throws {
        let source = try Self.padEditorViewSource()
        XCTAssertFalse(source.contains("isDrawerDismissedByUser"))
        XCTAssertFalse(source.contains("moveDrawerToFocus(with:"))
        XCTAssertTrue(source.contains("commitMovableInspectorDrag(with:"))
        XCTAssertTrue(source.contains("inspectorPanelDragHandle"), "the compact Inspector should move through its own header")
        XCTAssertTrue(source.contains("DragGesture(minimumDistance: 8)"))
        XCTAssertTrue(source.contains(#"L10n.t("Drag to move this panel.")"#), "the Inspector must expose the drag affordance in visible or accessibility text")
        XCTAssertTrue(source.contains("workspaceState.floatingPanelOffset"), "moving the Inspector must update only its document-scoped position")
        XCTAssertFalse(source.contains(".interactiveDismissDisabled(true)"))
    }

    func testCompactDomainBarKeepsInactiveLabelsReadable() throws {
        let source = try Self.padToolRailSource()

        XCTAssertTrue(source.contains("Text(L10n.t(item.labelKey))"))
        XCTAssertTrue(
            source.contains("isSelected ? Color.accentColor : Color.secondary"),
            "inactive domain labels must remain readable on the dark Inspector surface"
        )
    }

    func testInspectorHeaderOffersAnExplicitMinimizeAction() throws {
        let source = try Self.padEditorViewSource()

        XCTAssertTrue(source.contains("inspectorMinimizeButton"))
        XCTAssertTrue(source.contains("xmark.circle.fill"))
        XCTAssertTrue(source.contains("Hide Inspector"))
    }

    func testPortraitInspectorCanBeDismissedWithADownwardHeaderSwipe() throws {
        let source = try Self.padEditorViewSource()

        XCTAssertTrue(source.contains("shouldDismissMovableInspector(for:"))
        XCTAssertTrue(source.contains("minimizeInspector()"))
    }

    func testDownwardInspectorDismissalRequiresAPredominantlyVerticalDrag() {
        XCTAssertTrue(
            PadEditorLayoutPolicy.shouldDismissMovableInspector(
                for: CGSize(width: 8, height: 120)
            )
        )
        XCTAssertFalse(
            PadEditorLayoutPolicy.shouldDismissMovableInspector(
                for: CGSize(width: 140, height: 120)
            )
        )
        XCTAssertFalse(
            PadEditorLayoutPolicy.shouldDismissMovableInspector(
                for: CGSize(width: 0, height: 99)
            )
        )
    }

    func testInspectorHasOneMinimizableSurfaceWithAVisibleRestoreTile() throws {
        let source = try Self.padEditorViewSource()

        XCTAssertTrue(source.contains("isInspectorMinimized"))
        XCTAssertTrue(source.contains("minimizeInspector()"))
        XCTAssertTrue(source.contains("restoreInspector()"))
        XCTAssertTrue(source.contains("inspectorRestoreTile"))
        XCTAssertTrue(source.contains(#"L10n.t("Minimize Inspector")"#))
        XCTAssertTrue(source.contains(#"L10n.t("Show Inspector")"#))
        XCTAssertTrue(
            source.contains(".frame(minWidth: 44, minHeight: 44)"),
            "the minimized Inspector entry must remain a reachable 44pt control"
        )
        XCTAssertFalse(source.contains("inspectorVisibilityToggle"), "minimize should live on the panel; do not add a second toolbar switch")
    }

    func testAdjustmentToolbarEntryReopensTheSingleInspectorPopup() throws {
        let source = try Self.padEditorViewSource()

        XCTAssertTrue(source.contains("private var inspectorPresentationButton: some View"))
        XCTAssertTrue(source.contains("private func presentInspectorFromToolbar()"))
        XCTAssertFalse(source.contains("presentBottomDrawer()"))
        XCTAssertTrue(source.contains(#"Label(L10n.t("Adjustments"), systemImage: "slider.horizontal.3")"#))
        XCTAssertTrue(source.contains(#".accessibilityHint(Text(L10n.t("Show Inspector")))"#))
        let toolbarStart = try XCTUnwrap(source.range(of: "private func presentInspectorFromToolbar()"))
        let dragStart = try XCTUnwrap(source.range(of: "private func commitMovableInspectorDrag"))
        let toolbarBody = source[toolbarStart.lowerBound..<dragStart.lowerBound]
        XCTAssertFalse(toolbarBody.contains("floatingPanelOffset"), "the entry point must not relocate a visible Inspector")
    }

    func testAdjustmentEntryDoesNotExposeACompetingFocusToggleAndFloatingPanelUsesVisibleOrigin() throws {
        let source = try Self.padEditorViewSource()

        XCTAssertFalse(source.contains("workspaceModeToggle"), "Focus must be entered by dragging the Inspector, not a competing toolbar toggle")
        XCTAssertTrue(source.contains("ZStack(alignment: .topLeading)"), "floating coordinates must be based on a visible top-leading origin")
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)"), "the minimized restore tile must remain reachable without affecting floating coordinates")
        XCTAssertTrue(source.contains("movableInspectorWidth(for: size)"), "moving the panel must preserve the bottom-drawer width")
        XCTAssertTrue(source.contains("movableInspectorOrigin(for: size)"), "the overlay must start from an adaptive bottom-centered origin")
        XCTAssertFalse(source.contains("focusLayout(for:"), "the compact Inspector must not have a separate Focus-mode rendering path")
    }

    // MARK: - Adaptive workspace width profiles

    func testWidthProfilesUseAvailableWidthNotDeviceOrientation() {
        XCTAssertEqual(PadWorkspaceLayoutPolicy.profile(forWidth: 699.5), .compact)
        XCTAssertEqual(PadWorkspaceLayoutPolicy.profile(forWidth: 700), .standard)
        XCTAssertEqual(PadWorkspaceLayoutPolicy.profile(forWidth: 1_099.5), .standard)
        XCTAssertEqual(PadWorkspaceLayoutPolicy.profile(forWidth: 1_100), .expanded)
        XCTAssertEqual(PadWorkspaceLayoutPolicy.profile(forWidth: 1_359.5), .expanded)
        XCTAssertEqual(PadWorkspaceLayoutPolicy.profile(forWidth: 1_360), .wide)
    }

    func testAdaptiveWorkspaceLayoutKeepsPrimaryContentAsWidthShrinks() {
        let compact = PadWorkspaceLayoutPolicy.layout(forWidth: 600)
        XCTAssertEqual(compact.librarySidebar, .overlay)
        XCTAssertEqual(compact.editorInspector, .bottomDrawer)
        XCTAssertFalse(compact.showsFilmstrip)

        let standard = PadWorkspaceLayoutPolicy.layout(forWidth: 900)
        XCTAssertEqual(standard.librarySidebar, .overlay)
        XCTAssertEqual(standard.editorInspector, .bottomDrawer)
        XCTAssertFalse(standard.showsFilmstrip)

        let expanded = PadWorkspaceLayoutPolicy.layout(forWidth: 1_180)
        XCTAssertEqual(expanded.librarySidebar, .persistent)
        XCTAssertEqual(expanded.editorInspector, .trailingDock)
        XCTAssertTrue(expanded.showsFilmstrip)

        let wide = PadWorkspaceLayoutPolicy.layout(forWidth: 1_400)
        XCTAssertEqual(wide.librarySidebar, .persistent)
        XCTAssertTrue(wide.showsFilmstrip)
    }

    func testNegativeAndZeroWidthsStayCompact() {
        XCTAssertEqual(PadWorkspaceLayoutPolicy.profile(forWidth: -1), .compact)
        XCTAssertEqual(PadWorkspaceLayoutPolicy.profile(forWidth: 0), .compact)
    }

    func testWorkspaceStateContainsOnlyPresentationPreferences() {
        let state = PadWorkspaceState(
            isSidebarVisible: false,
            isFilmstripVisible: true
        )

        XCTAssertFalse(state.isSidebarVisible)
        XCTAssertTrue(state.isFilmstripVisible)
        XCTAssertTrue(PadWorkspaceState.initial.isSidebarVisible)
    }

    // MARK: - The 1,100pt width boundary, in landscape

    func testWidthExactly1100InLandscapeUsesDock() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 1_100, height: 700), .trailingDock)
    }

    func testWidthOf1099InLandscapeUsesBottomDrawer() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 1_099, height: 700), .bottomDrawer)
    }

    /// Same boundary, expressed as fractional points around 1,100 — `>=`
    /// must not be silently rounding or truncating.
    func testWidthJustBelow1100InLandscapeUsesBottomDrawer() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 1_099.5, height: 700), .bottomDrawer)
    }

    func testWidthJustAbove1100InLandscapeUsesDock() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 1_100.5, height: 700), .trailingDock)
    }

    // MARK: - Responsive trailing-dock sizing

    func testLandscapeDockUsesRemainingWidthWithoutStarvingTheCanvas() {
        let plan = PadEditorLayoutPolicy.plan(for: CGSize(width: 1_100, height: 700))

        XCTAssertEqual(plan.presentation, .trailingDock)
        let expectedInspectorWidth = 1_100
            - PadEditorLayoutPolicy.toolRailWidth
            - PadEditorLayoutPolicy.layoutSeparators
            - PadEditorLayoutPolicy.minimumCanvasWidth
        XCTAssertEqual(plan.inspectorWidth ?? .nan, expectedInspectorWidth, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(plan.inspectorWidth ?? 0, PadEditorLayoutPolicy.minimumInspectorWidth)
        XCTAssertEqual(
            (plan.inspectorWidth ?? 0) + PadEditorLayoutPolicy.toolRailWidth + PadEditorLayoutPolicy.minimumCanvasWidth + PadEditorLayoutPolicy.layoutSeparators,
            1_100,
            accuracy: 0.01
        )
    }

    func testWideLandscapeDockCapsInspectorAndLeavesCanvasRoom() {
        let plan = PadEditorLayoutPolicy.plan(for: CGSize(width: 1_180, height: 820))

        XCTAssertEqual(plan.presentation, .trailingDock)
        XCTAssertEqual(plan.inspectorWidth ?? .nan, PadEditorLayoutPolicy.maximumInspectorWidth, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(plan.canvasWidth ?? 0, PadEditorLayoutPolicy.minimumCanvasWidth)
    }

    func testNarrowLandscapeFallsBackBeforeDockWouldClipCanvas() {
        let plan = PadEditorLayoutPolicy.plan(for: CGSize(width: 1_099, height: 700))

        XCTAssertEqual(plan.presentation, .bottomDrawer)
        XCTAssertNil(plan.inspectorWidth)
        XCTAssertNil(plan.canvasWidth)
    }

    func testFocusPanelWidthStaysReadableAndCapsOnWideScreens() {
        XCTAssertEqual(
            PadEditorLayoutPolicy.floatingPanelWidth(for: CGSize(width: 400, height: 700)),
            PadEditorLayoutPolicy.minimumInspectorWidth,
            accuracy: 0.01
        )
        XCTAssertEqual(
            PadEditorLayoutPolicy.floatingPanelWidth(for: CGSize(width: 1_180, height: 820)),
            PadEditorLayoutPolicy.maximumInspectorWidth,
            accuracy: 0.01
        )
    }

    func testMovableInspectorKeepsTheWideBottomDrawerTreatment() {
        let portrait = PadEditorLayoutPolicy.movableInspectorWidth(for: CGSize(width: 820, height: 1_180))
        XCTAssertEqual(portrait, 772, accuracy: 0.01)

        let wide = PadEditorLayoutPolicy.movableInspectorWidth(for: CGSize(width: 1_400, height: 820))
        XCTAssertEqual(wide, PadEditorLayoutPolicy.movableInspectorMaximumWidth, accuracy: 0.01)
        XCTAssertGreaterThan(portrait, PadEditorLayoutPolicy.maximumInspectorWidth)
    }

    func testMovableInspectorHeightIsBoundedByAvailableHeight() {
        XCTAssertEqual(
            PadEditorLayoutPolicy.movableInspectorHeight(for: CGSize(width: 820, height: 1_180)),
            PadEditorLayoutPolicy.movableInspectorMaximumHeight,
            accuracy: 0.01
        )
        XCTAssertEqual(
            PadEditorLayoutPolicy.movableInspectorHeight(for: CGSize(width: 750, height: 700)),
            652,
            accuracy: 0.01
        )
        XCTAssertGreaterThanOrEqual(
            PadEditorLayoutPolicy.movableInspectorHeight(for: CGSize(width: 320, height: 300)),
            PadEditorLayoutPolicy.movableInspectorMinimumHeight
        )
    }

    func testMovableInspectorOriginIsBottomCenteredWithSafeInsets() {
        let origin = PadEditorLayoutPolicy.movableInspectorOrigin(
            for: CGSize(width: 820, height: 1_180),
            panelSize: CGSize(width: 772, height: 652)
        )

        XCTAssertEqual(origin.x, 24, accuracy: 0.01)
        XCTAssertEqual(origin.y, 504, accuracy: 0.01)

        let narrowOrigin = PadEditorLayoutPolicy.movableInspectorOrigin(
            for: CGSize(width: 320, height: 700),
            panelSize: CGSize(width: 360, height: 652)
        )
        XCTAssertGreaterThanOrEqual(narrowOrigin.x, 24)
        XCTAssertGreaterThanOrEqual(narrowOrigin.y, 24)
    }

    // MARK: - Square

    func testSquareBelowTheExpandedWidthThresholdUsesBottomDrawer() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 1_024, height: 1_024), .bottomDrawer)
    }

    func testSquareBelowTheWidthThresholdUsesBottomDrawer() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 800, height: 800), .bottomDrawer)
    }

    // MARK: - iPad Split View sizes
    //
    // Split View gives an app a slice of the full screen width while the
    // full screen height is untouched -- these are the realistic sizes
    // `PadEditorView` actually has to cope with, not just idealized full-
    // screen landscape/portrait.

    /// A 1/3-width Split View pane on an 11" iPad in landscape: narrow
    /// and taller than it is wide, even though the *device* is in
    /// landscape orientation -- the policy only ever sees the view's own
    /// available size, never device orientation directly.
    func testNarrowSplitViewPaneUsesBottomDrawer() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 320, height: 834), .bottomDrawer)
    }

    /// A 2/3-width Split View pane, wide enough to be landscape-shaped
    /// but still under the 1,100pt dock threshold.
    func testModeratelyWideSplitViewPaneBelowThresholdUsesBottomDrawer() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 750, height: 700), .bottomDrawer)
    }

    /// A 2/3-width Split View pane on a 13" iPad, still under the expanded
    /// width threshold while sharing the screen with another app.
    func testWideSplitViewPaneBelowExpandedThresholdUsesBottomDrawer() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 950, height: 700), .bottomDrawer)
    }

    // MARK: - Degenerate sizes

    func testZeroSizeDoesNotCrashAndUsesBottomDrawer() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 0, height: 0), .bottomDrawer)
    }

    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PadEditorLayoutPolicyTests.swift
            .deletingLastPathComponent() // AdjustmentUITests
            .deletingLastPathComponent() // Tests
    }()

    private static func padEditorViewSource() throws -> String {
        try String(
            contentsOf: repositoryRootURL
                .appendingPathComponent("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift"),
            encoding: .utf8
        )
    }

    private static func padToolRailSource() throws -> String {
        try String(
            contentsOf: repositoryRootURL
                .appendingPathComponent("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadToolRail.swift"),
            encoding: .utf8
        )
    }

    // MARK: - PadFloatingPanelLayout.clampedOffset (Codex round-2 review)

    private let sampleAvailableSize = CGSize(width: 1_180, height: 820)
    private let samplePanelOrigin = CGPoint(x: 24, y: 24)
    private let samplePanelSize = CGSize(width: 320, height: 400)
    private let sampleMinimumVisibleEdge: CGFloat = 44

    func testUnclampedOffsetWithinBoundsIsReturnedUnchanged() {
        let proposed = CGSize(width: 100, height: 60)
        let result = PadFloatingPanelLayout.clampedOffset(
            proposedOffset: proposed,
            panelOrigin: samplePanelOrigin,
            panelSize: samplePanelSize,
            availableSize: sampleAvailableSize,
            minimumVisibleEdge: sampleMinimumVisibleEdge
        )
        XCTAssertEqual(result, proposed, "an offset that's already fully on-screen must not be altered")
    }

    func testClampsAPanelDraggedPastTheLeadingEdge() {
        let proposed = CGSize(width: -10_000, height: 0)
        let result = PadFloatingPanelLayout.clampedOffset(
            proposedOffset: proposed,
            panelOrigin: samplePanelOrigin,
            panelSize: samplePanelSize,
            availableSize: sampleAvailableSize,
            minimumVisibleEdge: sampleMinimumVisibleEdge
        )
        let resultingLeft = samplePanelOrigin.x + result.width
        let resultingRight = resultingLeft + samplePanelSize.width
        XCTAssertGreaterThanOrEqual(resultingRight, sampleMinimumVisibleEdge, "at least the minimum visible edge of the panel must remain on-screen from the left")
    }

    func testClampsAPanelDraggedPastTheTrailingEdge() {
        let proposed = CGSize(width: 10_000, height: 0)
        let result = PadFloatingPanelLayout.clampedOffset(
            proposedOffset: proposed,
            panelOrigin: samplePanelOrigin,
            panelSize: samplePanelSize,
            availableSize: sampleAvailableSize,
            minimumVisibleEdge: sampleMinimumVisibleEdge
        )
        let resultingLeft = samplePanelOrigin.x + result.width
        XCTAssertLessThanOrEqual(resultingLeft, sampleAvailableSize.width - sampleMinimumVisibleEdge, "at least the minimum visible edge of the panel must remain on-screen from the right")
    }

    func testClampsAPanelDraggedPastTheTopEdge() {
        let proposed = CGSize(width: 0, height: -10_000)
        let result = PadFloatingPanelLayout.clampedOffset(
            proposedOffset: proposed,
            panelOrigin: samplePanelOrigin,
            panelSize: samplePanelSize,
            availableSize: sampleAvailableSize,
            minimumVisibleEdge: sampleMinimumVisibleEdge
        )
        let resultingTop = samplePanelOrigin.y + result.height
        let resultingBottom = resultingTop + samplePanelSize.height
        XCTAssertGreaterThanOrEqual(resultingBottom, sampleMinimumVisibleEdge, "at least the minimum visible edge of the panel (including its header) must remain on-screen from the top")
    }

    func testClampsAPanelDraggedPastTheBottomEdge() {
        let proposed = CGSize(width: 0, height: 10_000)
        let result = PadFloatingPanelLayout.clampedOffset(
            proposedOffset: proposed,
            panelOrigin: samplePanelOrigin,
            panelSize: samplePanelSize,
            availableSize: sampleAvailableSize,
            minimumVisibleEdge: sampleMinimumVisibleEdge
        )
        let resultingTop = samplePanelOrigin.y + result.height
        XCTAssertLessThanOrEqual(resultingTop, sampleAvailableSize.height - sampleMinimumVisibleEdge, "at least the minimum visible edge of the panel's header must remain on-screen from the bottom")
    }

    /// All four directions at once (a diagonal drag far past the corner)
    /// must still resolve to a single, fully-defined position — not NaN,
    /// not an inverted range.
    func testClampsADiagonalDragPastAllFourEdges() {
        let proposed = CGSize(width: -10_000, height: -10_000)
        let result = PadFloatingPanelLayout.clampedOffset(
            proposedOffset: proposed,
            panelOrigin: samplePanelOrigin,
            panelSize: samplePanelSize,
            availableSize: sampleAvailableSize,
            minimumVisibleEdge: sampleMinimumVisibleEdge
        )
        XCTAssertFalse(result.width.isNaN)
        XCTAssertFalse(result.height.isNaN)
        let resultingLeft = samplePanelOrigin.x + result.width
        let resultingTop = samplePanelOrigin.y + result.height
        XCTAssertGreaterThanOrEqual(resultingLeft + samplePanelSize.width, sampleMinimumVisibleEdge)
        XCTAssertGreaterThanOrEqual(resultingTop + samplePanelSize.height, sampleMinimumVisibleEdge)
    }

    /// A panel wider (and taller) than the entire available area — e.g. a
    /// Split View pane suddenly much smaller than the panel's own fixed
    /// 320pt width — must still clamp to a single well-defined position
    /// with some of the panel's header reachable, never an empty/inverted
    /// range.
    func testClampsWhenThePanelIsLargerThanTheAvailableArea() {
        let tinyAvailableSize = CGSize(width: 200, height: 300)
        let result = PadFloatingPanelLayout.clampedOffset(
            proposedOffset: .zero,
            panelOrigin: samplePanelOrigin,
            panelSize: samplePanelSize,
            availableSize: tinyAvailableSize,
            minimumVisibleEdge: sampleMinimumVisibleEdge
        )
        XCTAssertFalse(result.width.isNaN)
        XCTAssertFalse(result.height.isNaN)
        let resultingLeft = samplePanelOrigin.x + result.width
        let resultingTop = samplePanelOrigin.y + result.height
        // Some part of the panel must overlap the available rectangle.
        XCTAssertLessThan(resultingLeft, tinyAvailableSize.width)
        XCTAssertGreaterThan(resultingLeft + samplePanelSize.width, 0)
        XCTAssertLessThan(resultingTop, tinyAvailableSize.height)
        XCTAssertGreaterThan(resultingTop + samplePanelSize.height, 0)
    }

    /// Re-clamping after a size change (rotation/Split View resize): a
    /// position that was valid for the old available size but is now out
    /// of bounds must be pulled back in when re-clamped against the new,
    /// smaller size.
    func testRecampsAnAlreadyValidOffsetAfterTheAvailableAreaShrinks() {
        let roomyOffset = CGSize(width: 700, height: 300)
        let stillWithinTheOriginalSize = PadFloatingPanelLayout.clampedOffset(
            proposedOffset: roomyOffset,
            panelOrigin: samplePanelOrigin,
            panelSize: samplePanelSize,
            availableSize: sampleAvailableSize,
            minimumVisibleEdge: sampleMinimumVisibleEdge
        )
        XCTAssertEqual(stillWithinTheOriginalSize, roomyOffset, "premise: this offset is valid before the resize")

        let shrunkAvailableSize = CGSize(width: 500, height: 400)
        let reclamped = PadFloatingPanelLayout.clampedOffset(
            proposedOffset: stillWithinTheOriginalSize,
            panelOrigin: samplePanelOrigin,
            panelSize: samplePanelSize,
            availableSize: shrunkAvailableSize,
            minimumVisibleEdge: sampleMinimumVisibleEdge
        )
        let resultingLeft = samplePanelOrigin.x + reclamped.width
        XCTAssertLessThanOrEqual(resultingLeft, shrunkAvailableSize.width - sampleMinimumVisibleEdge, "the offset that was valid before the resize must be pulled back in for the new, smaller size")
    }

    // MARK: - PadDocumentScopedWorkspacePolicy (Codex round-2 review)

    func testStateResetsToInitialWhenTheOpenDocumentChanges() {
        let dirty = PadDocumentScopedWorkspaceState(
            canvasScale: 3.5,
            floatingPanelOffset: CGSize(width: 120, height: -40)
        )
        let idA = UUID()
        let idB = UUID()
        let result = PadDocumentScopedWorkspacePolicy.resettingIfNeeded(dirty, previousDocumentID: idA, currentDocumentID: idB)
        XCTAssertEqual(result, .initial)
    }

    func testStateIsUntouchedOnTheVeryFirstOpen() {
        let alreadyInitial = PadDocumentScopedWorkspaceState.initial
        let id = UUID()
        let result = PadDocumentScopedWorkspacePolicy.resettingIfNeeded(alreadyInitial, previousDocumentID: nil, currentDocumentID: id)
        XCTAssertEqual(result, alreadyInitial)
    }

    func testStateIsUntouchedWhenClosingToNoDocument() {
        let dirty = PadDocumentScopedWorkspaceState(canvasScale: 2, floatingPanelOffset: CGSize(width: 10, height: 10))
        let id = UUID()
        let result = PadDocumentScopedWorkspacePolicy.resettingIfNeeded(dirty, previousDocumentID: id, currentDocumentID: nil)
        XCTAssertEqual(result, dirty, "closing tears the view down on its own -- this policy must not also reset state that's about to be discarded anyway")
    }

    func testStateIsUntouchedWhenTheDocumentIDIsUnchanged() {
        let dirty = PadDocumentScopedWorkspaceState(canvasScale: 2.2, floatingPanelOffset: CGSize(width: 5, height: 5))
        let id = UUID()
        let result = PadDocumentScopedWorkspacePolicy.resettingIfNeeded(dirty, previousDocumentID: id, currentDocumentID: id)
        XCTAssertEqual(result, dirty)
    }
}
