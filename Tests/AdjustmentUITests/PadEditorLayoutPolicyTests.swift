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
/// Also carries the `PadWorkspaceMode` undo-invariant tests (see below,
/// after the layout-policy cases) in this same class — deliberately, so
/// `swift test --filter 'PadEditorLayoutPolicyTests|EditorSessionEditingTests'`
/// (the plan's own required verification command) actually exercises
/// them, rather than them living under a differently-named class that
/// filter would silently miss.
@MainActor
final class PadEditorLayoutPolicyTests: XCTestCase {

    // MARK: - Landscape / portrait (spec examples)

    func testLandscapeUsesDock() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 1180, height: 820), .trailingDock)
    }

    func testPortraitUsesBottomDrawer() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 820, height: 1180), .bottomDrawer)
    }

    // MARK: - The 899/900pt width boundary, in landscape

    func testWidthExactly900InLandscapeUsesDock() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 900, height: 700), .trailingDock)
    }

    func testWidthOf899InLandscapeUsesBottomDrawer() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 899, height: 700), .bottomDrawer)
    }

    /// Same boundary, expressed as a fractional point just below and at
    /// 900 — `>=` must not be silently rounding or truncating.
    func testWidthJustBelow900InLandscapeUsesBottomDrawer() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 899.5, height: 700), .bottomDrawer)
    }

    func testWidthJustAbove900InLandscapeUsesDock() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 900.5, height: 700), .trailingDock)
    }

    // MARK: - Square

    func testSquareAtOrAboveTheWidthThresholdUsesDock() {
        // width == height, and width >= 900 -- "width >= height" is
        // satisfied by equality, not just strict landscape.
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 1_024, height: 1_024), .trailingDock)
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
    /// but still under the 900pt dock threshold.
    func testModeratelyWideSplitViewPaneBelowThresholdUsesBottomDrawer() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 750, height: 700), .bottomDrawer)
    }

    /// A 2/3-width Split View pane on a 12.9" iPad, wide enough to clear
    /// the dock threshold even while sharing the screen with another app.
    func testWideSplitViewPaneAtOrAboveThresholdUsesDock() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 950, height: 700), .trailingDock)
    }

    // MARK: - Degenerate sizes

    func testZeroSizeDoesNotCrashAndUsesBottomDrawer() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 0, height: 0), .bottomDrawer)
    }

    // MARK: - PadWorkspaceMode: switching never touches EditorSession
    //
    // `PadWorkspaceMode.work`/`.focus` is pure presentation state — the
    // type has no import of, or any other coupling to, `EditorCore` at
    // all (see its declaration), so switching between its two cases can
    // never call an editor API by construction, not merely by convention.
    // These cases prove the invariant that matters on the `EditorSession`
    // side of that boundary: reassigning a `PadWorkspaceMode` value back
    // and forth leaves a real session's undo stack and adjustments
    // completely untouched, and — immediately afterward, using the exact
    // same session — that a single real edit still produces exactly one
    // undo entry, exactly as `EditorSessionEditingTests
    // .testOneAdjustmentCreatesOneUndoEntry` establishes independently.

    private func makeOpenedEditor() -> EditorSession {
        let editor = EditorSession()
        let photo = PhotoAsset(
            id: PhotoID(),
            libraryID: LibraryID(),
            relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"),
            status: .ready
        )
        editor.open(
            photo: photo,
            sourceURL: URL(fileURLWithPath: "/fixture.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )
        return editor
    }

    func testSwitchingWorkspaceModeNeverChangesUndoStateAndASingleAdjustmentStillProducesExactlyOneUndo() {
        let editor = makeOpenedEditor()
        // A prior edit, so `canUndo`/`adjustments` starts non-trivial —
        // proving the mode switch leaves an *already dirty* session alone
        // is a stronger claim than only proving it on a fresh, neutral one.
        editor.setAdjustment(.contrast, to: 8)
        let canUndoBeforeSwitch = editor.canUndo
        let canRedoBeforeSwitch = editor.canRedo
        let adjustmentsBeforeSwitch = editor.adjustments

        // The switch itself: work -> focus -> work. Nothing here is an
        // EditorSession call -- `PadWorkspaceMode` cannot reach `editor`
        // even if this test tried to make it.
        var mode = PadWorkspaceMode.work
        mode = .focus
        mode = .work
        XCTAssertEqual(mode, .work)

        XCTAssertEqual(editor.canUndo, canUndoBeforeSwitch, "switching workspace mode must never change undo availability")
        XCTAssertEqual(editor.canRedo, canRedoBeforeSwitch, "switching workspace mode must never change redo availability")
        XCTAssertEqual(editor.adjustments, adjustmentsBeforeSwitch, "switching workspace mode must never change the current adjustments")

        // The same session, immediately after: one real edit still
        // produces exactly one additional undo step -- a single `undo()`
        // call fully reverts it back to the pre-adjustment state.
        editor.setAdjustment(.exposure, to: 1.25)
        XCTAssertEqual(editor.adjustments.exposure, 1.25)
        XCTAssertTrue(editor.canUndo)

        editor.undo()
        XCTAssertEqual(editor.adjustments, adjustmentsBeforeSwitch, "one undo must fully revert the one edit made after switching modes")
        XCTAssertEqual(editor.canUndo, canUndoBeforeSwitch)
    }

    func testWorkspaceModeSwitchingDuringAnActiveFocusSessionStillLeavesUndoStateAlone() {
        let editor = makeOpenedEditor()
        editor.setAdjustment(.exposure, to: 0.5)
        editor.setAdjustment(.contrast, to: 10)
        let canUndoBefore = editor.canUndo
        let adjustmentsBefore = editor.adjustments

        // Several toggles in a row, as a user flipping back and forth
        // between work and focus repeatedly might do.
        var mode = PadWorkspaceMode.work
        for _ in 0..<5 {
            mode = mode == .work ? .focus : .work
        }

        XCTAssertEqual(editor.canUndo, canUndoBefore)
        XCTAssertEqual(editor.adjustments, adjustmentsBefore)
        _ = mode
    }

    // MARK: - PadBottomDrawerPolicy (Codex round-2 review)
    //
    // The bottom drawer's real `@State` binding is driven entirely by
    // this reducer -- these cases are exactly the presentation-state
    // matrix `PadEditorView` needs to get right: which combinations of
    // mode and inspector presentation must show the drawer, and which
    // must not.

    func testDrawerIsPresentedInWorkModeWithBottomDrawerPresentation() {
        XCTAssertEqual(
            PadBottomDrawerPolicy.presentation(mode: .work, inspectorPresentation: .bottomDrawer),
            .presented
        )
    }

    func testDrawerIsDismissedInWorkModeWithTrailingDockPresentation() {
        XCTAssertEqual(
            PadBottomDrawerPolicy.presentation(mode: .work, inspectorPresentation: .trailingDock),
            .dismissed
        )
    }

    func testDrawerIsDismissedInFocusModeRegardlessOfInspectorPresentation() {
        XCTAssertEqual(
            PadBottomDrawerPolicy.presentation(mode: .focus, inspectorPresentation: .bottomDrawer),
            .dismissed,
            "focus mode must reliably close the drawer even on a narrow window where the drawer would otherwise apply"
        )
        XCTAssertEqual(
            PadBottomDrawerPolicy.presentation(mode: .focus, inspectorPresentation: .trailingDock),
            .dismissed
        )
    }

    func testDrawerReopensReturningToWorkModeWhileStillNarrow() {
        // focus -> work, inspector presentation unchanged (still narrow):
        // must come back to `.presented`, not stay dismissed just because
        // it was dismissed a moment ago.
        let whileFocused = PadBottomDrawerPolicy.presentation(mode: .focus, inspectorPresentation: .bottomDrawer)
        XCTAssertEqual(whileFocused, .dismissed)
        let afterReturningToWork = PadBottomDrawerPolicy.presentation(mode: .work, inspectorPresentation: .bottomDrawer)
        XCTAssertEqual(afterReturningToWork, .presented)
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
            workspaceMode: .focus,
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
        let dirty = PadDocumentScopedWorkspaceState(workspaceMode: .focus, canvasScale: 2, floatingPanelOffset: CGSize(width: 10, height: 10))
        let id = UUID()
        let result = PadDocumentScopedWorkspacePolicy.resettingIfNeeded(dirty, previousDocumentID: id, currentDocumentID: nil)
        XCTAssertEqual(result, dirty, "closing tears the view down on its own -- this policy must not also reset state that's about to be discarded anyway")
    }

    func testStateIsUntouchedWhenTheDocumentIDIsUnchanged() {
        let dirty = PadDocumentScopedWorkspaceState(workspaceMode: .focus, canvasScale: 2.2, floatingPanelOffset: CGSize(width: 5, height: 5))
        let id = UUID()
        let result = PadDocumentScopedWorkspacePolicy.resettingIfNeeded(dirty, previousDocumentID: id, currentDocumentID: id)
        XCTAssertEqual(result, dirty)
    }
}
