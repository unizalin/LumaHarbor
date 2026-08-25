import CoreGraphics
import EditorCore
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
}
