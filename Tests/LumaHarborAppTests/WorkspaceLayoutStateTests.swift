import XCTest
@testable import LumaHarborApp

/// Phase 2.3 (spec §6.3): pure state/policy tests for the Mac focus
/// workspace -- individual sidebar/inspector/filmstrip visibility, focus
/// mode's effect on all three at once, and the inspector width clamp. None
/// of this touches SwiftUI or `@AppStorage` directly, so it can be checked
/// without a live view hierarchy, mirroring `CanvasViewportState`'s and
/// `EditorSession.CompareMode`'s own model-only test style.
final class WorkspaceLayoutStateTests: XCTestCase {
    // MARK: - Defaults

    func testDefaultsShowAllThreePanesWithFocusModeOffAndTheOriginalInspectorWidth() {
        let state = WorkspaceLayoutState()

        XCTAssertTrue(state.showSidebar)
        XCTAssertTrue(state.showInspector)
        XCTAssertTrue(state.showFilmstrip)
        XCTAssertFalse(state.focusMode)
        XCTAssertEqual(state.inspectorWidth, 300)
    }

    func testDefaultVisibilityIsAlreadyEffectiveWhenFocusModeIsOff() {
        let state = WorkspaceLayoutState()

        XCTAssertTrue(state.effectiveShowSidebar)
        XCTAssertTrue(state.effectiveShowInspector)
        XCTAssertTrue(state.effectiveShowFilmstrip)
    }

    // MARK: - Focus mode hides all three, regardless of their own preference

    func testFocusModeHidesAllThreePanesEvenWhenEachIsIndividuallyShown() {
        let state = WorkspaceLayoutState(
            showSidebar: true,
            showInspector: true,
            showFilmstrip: true,
            focusMode: true
        )

        XCTAssertFalse(state.effectiveShowSidebar)
        XCTAssertFalse(state.effectiveShowInspector)
        XCTAssertFalse(state.effectiveShowFilmstrip)
    }

    /// Focus mode wins even over a pane whose own preference is already
    /// off -- the effective result must never differ from "off" once focus
    /// mode is on.
    func testFocusModeKeepsAPaneHiddenIfItWasAlreadyHiddenOnItsOwn() {
        let state = WorkspaceLayoutState(showSidebar: false, focusMode: true)

        XCTAssertFalse(state.effectiveShowSidebar)
    }

    /// Spec §6.3: "focus mode 隱藏非必要 chrome" -- the three chrome panes only.
    /// Turning focus mode on must never touch the underlying per-pane
    /// preference itself (only the *effective* visibility), which is what
    /// lets `testTurningFocusModeOffRestoresEachPanesOwnPreference` below
    /// prove restoration without any extra bookkeeping.
    func testFocusModeDoesNotMutateTheUnderlyingPerPanePreferences() {
        var state = WorkspaceLayoutState(showSidebar: true, showInspector: false, showFilmstrip: true)
        state.focusMode = true

        XCTAssertTrue(state.showSidebar)
        XCTAssertFalse(state.showInspector)
        XCTAssertTrue(state.showFilmstrip)
    }

    // MARK: - Turning focus mode off restores each pane's own preference

    func testTurningFocusModeOffRestoresEachPanesOwnPreference() {
        var state = WorkspaceLayoutState(showSidebar: true, showInspector: false, showFilmstrip: true, focusMode: true)
        XCTAssertFalse(state.effectiveShowSidebar)
        XCTAssertFalse(state.effectiveShowInspector)
        XCTAssertFalse(state.effectiveShowFilmstrip)

        state.focusMode = false

        XCTAssertTrue(state.effectiveShowSidebar)
        XCTAssertFalse(state.effectiveShowInspector, "inspector's own preference was off before focus mode -- it must stay off, not come back on")
        XCTAssertTrue(state.effectiveShowFilmstrip)
    }

    // MARK: - Inspector width clamp

    func testInspectorWidthClampsBelowTheMinimum() {
        XCTAssertEqual(WorkspaceLayoutState.clampedInspectorWidth(100), WorkspaceLayoutState.minimumInspectorWidth)
        XCTAssertEqual(WorkspaceLayoutState.clampedInspectorWidth(279.9), WorkspaceLayoutState.minimumInspectorWidth)
    }

    func testInspectorWidthClampsAboveTheMaximum() {
        XCTAssertEqual(WorkspaceLayoutState.clampedInspectorWidth(1000), WorkspaceLayoutState.maximumInspectorWidth)
        XCTAssertEqual(WorkspaceLayoutState.clampedInspectorWidth(420.1), WorkspaceLayoutState.maximumInspectorWidth)
    }

    func testInspectorWidthWithinRangeIsUnchanged() {
        XCTAssertEqual(WorkspaceLayoutState.clampedInspectorWidth(280), 280)
        XCTAssertEqual(WorkspaceLayoutState.clampedInspectorWidth(420), 420)
        XCTAssertEqual(WorkspaceLayoutState.clampedInspectorWidth(350), 350)
    }

    func testMinimumAndMaximumInspectorWidthMatchTheSpecRange() {
        XCTAssertEqual(WorkspaceLayoutState.minimumInspectorWidth, 280)
        XCTAssertEqual(WorkspaceLayoutState.maximumInspectorWidth, 420)
    }

    /// The initializer must apply the same clamp as `clampedInspectorWidth`
    /// directly -- a caller building state from a stale/out-of-range stored
    /// `@AppStorage` value (e.g. from an older build, or a corrupted
    /// default) can never end up with an unclamped width.
    func testInitializerClampsAnOutOfRangeInspectorWidth() {
        XCTAssertEqual(WorkspaceLayoutState(inspectorWidth: 50).inspectorWidth, WorkspaceLayoutState.minimumInspectorWidth)
        XCTAssertEqual(WorkspaceLayoutState(inspectorWidth: 5000).inspectorWidth, WorkspaceLayoutState.maximumInspectorWidth)
    }

    // MARK: - Equatable, so a SwiftUI-side computed property can be diffed in tests

    func testEqualStatesCompareEqual() {
        XCTAssertEqual(WorkspaceLayoutState(), WorkspaceLayoutState())
        XCTAssertNotEqual(
            WorkspaceLayoutState(showSidebar: true),
            WorkspaceLayoutState(showSidebar: false)
        )
    }
}
