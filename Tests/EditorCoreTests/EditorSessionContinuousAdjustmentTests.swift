import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

/// Inspector hierarchy/typography/preview-responsiveness spec (2026-09-14)
/// §5.6: generalizes the curve-only preview/commit transaction
/// (`previewCurveEdit`/`commitCurveEdit`) into a shared lifecycle any
/// continuous control (Basic, HSL, Presence, ...) can use --
/// `previewContinuousEdit`/`commitContinuousEdit`/`cancelContinuousEdit`.
/// `previewCurveEdit`/`commitCurveEdit` become thin aliases over the same
/// underlying state, so existing curve tests and call sites keep working
/// unchanged.
@MainActor
final class EditorSessionContinuousAdjustmentTests: XCTestCase {
    private func makeOpenEditor() -> EditorSession {
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

    func testPreviewContinuousEditChangesDisplayedAdjustmentsButNotCommittedAdjustments() {
        let editor = makeOpenEditor()

        editor.previewContinuousEdit { $0.exposure = 1.5 }

        XCTAssertEqual(editor.displayedAdjustments.exposure, 1.5)
        XCTAssertEqual(editor.adjustments, .neutral, "a preview must not touch the committed adjustments")
        XCTAssertFalse(editor.canUndo)
        XCTAssertEqual(editor.saveState, .unchanged)
    }

    func testManyPreviewTicksDuringOneGestureCommitAsExactlyOneUndoEntry() {
        let editor = makeOpenEditor()

        for step in 1...10 {
            editor.previewContinuousEdit { $0.exposure = Double(step) / 10 }
        }
        XCTAssertFalse(editor.canUndo, "no tick before the gesture ends may push an Undo entry")

        editor.commitContinuousEdit()

        XCTAssertTrue(editor.canUndo)
        XCTAssertEqual(editor.adjustments.exposure, 1.0)

        editor.undo()
        XCTAssertEqual(editor.adjustments, .neutral, "exactly one Undo entry, regardless of how many ticks the drag reported")
    }

    func testCommittingWithNoActivePreviewIsANoOp() {
        let editor = makeOpenEditor()
        editor.commitContinuousEdit()
        XCTAssertEqual(editor.adjustments, .neutral)
        XCTAssertFalse(editor.canUndo)
    }

    func testCommittingAPreviewThatResolvesToTheCurrentValueAddsNoHistoryEntry() {
        let editor = makeOpenEditor()
        editor.previewContinuousEdit { _ in }

        editor.commitContinuousEdit()

        XCTAssertFalse(editor.canUndo)
    }

    func testPreviewContinuousEditDoesNothingWithoutAnOpenPhoto() {
        let editor = EditorSession()
        editor.previewContinuousEdit { $0.exposure = 1.5 }
        XCTAssertEqual(editor.displayedAdjustments, .neutral)
    }

    /// Spec §5.6 "cancel": restore the baseline without adding history --
    /// this is the transaction's cancel path (e.g. a keyboard Escape),
    /// distinct from committing at gesture end.
    func testCancelContinuousEditRestoresTheBaselineWithoutHistory() {
        let editor = makeOpenEditor()
        editor.previewContinuousEdit { $0.exposure = 1.5 }
        XCTAssertNotEqual(editor.displayedAdjustments, .neutral)

        editor.cancelContinuousEdit()

        XCTAssertEqual(editor.displayedAdjustments, .neutral)
        XCTAssertEqual(editor.adjustments, .neutral)
        XCTAssertFalse(editor.canUndo)
        XCTAssertEqual(editor.saveState, .unchanged)
    }

    func testCancellingWithNoActivePreviewIsHarmless() {
        let editor = makeOpenEditor()
        editor.cancelContinuousEdit()
        XCTAssertEqual(editor.displayedAdjustments, .neutral)
    }

    /// The curve panel's existing call sites must keep working unchanged --
    /// `previewCurveEdit`/`commitCurveEdit` share the same underlying
    /// preview slot as the generic entry points, so a curve preview can be
    /// committed via either name.
    func testCurveAliasesShareStateWithTheGenericContinuousEditLifecycle() {
        let editor = makeOpenEditor()

        editor.previewCurveEdit { $0.exposure = 0.75 }
        XCTAssertEqual(editor.displayedAdjustments.exposure, 0.75)

        editor.commitContinuousEdit()

        XCTAssertEqual(editor.adjustments.exposure, 0.75)
        XCTAssertTrue(editor.canUndo)
    }

    /// One committed continuous gesture must schedule exactly one autosave
    /// -- not one per preview tick.
    func testCommitContinuousEditSchedulesExactlyOneAutosave() {
        let editor = makeOpenEditor()
        for step in 1...5 {
            editor.previewContinuousEdit { $0.exposure = Double(step) / 10 }
        }

        editor.commitContinuousEdit()

        XCTAssertEqual(editor.saveState, .pending)
    }
}
