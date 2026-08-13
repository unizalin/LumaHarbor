import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Spec §13.4: original comparison, undo, redo and reset all need test cover.
final class EditHistoryTests: XCTestCase {
    func testStartsWithNothingToUndoOrRedo() {
        let history = EditHistory(initial: PhotoAdjustments.neutral)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.current, .neutral)
    }

    func testRecordingMovesForwardAndEnablesUndo() {
        var history = EditHistory(initial: PhotoAdjustments.neutral)
        XCTAssertTrue(history.record(PhotoAdjustments(exposure: 1)))
        XCTAssertEqual(history.current.exposure, 1)
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    func testRecordingTheSameValueIsANoOp() {
        // Holding a slider still shouldn't fill the undo stack with duplicates.
        var history = EditHistory(initial: PhotoAdjustments(exposure: 1))
        XCTAssertFalse(history.record(PhotoAdjustments(exposure: 1)))
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.undoCount, 0)
    }

    func testUndoThenRedoReturnsToWhereItStarted() {
        var history = EditHistory(initial: PhotoAdjustments.neutral)
        history.record(PhotoAdjustments(exposure: 1))
        history.record(PhotoAdjustments(exposure: 2))

        XCTAssertEqual(history.undo()?.exposure, 1)
        XCTAssertEqual(history.undo()?.exposure, 0)
        XCTAssertFalse(history.canUndo)

        XCTAssertEqual(history.redo()?.exposure, 1)
        XCTAssertEqual(history.redo()?.exposure, 2)
        XCTAssertFalse(history.canRedo)
    }

    func testUndoAtTheStartReturnsNil() {
        var history = EditHistory(initial: PhotoAdjustments.neutral)
        XCTAssertNil(history.undo())
        XCTAssertEqual(history.current, .neutral)
    }

    func testRedoAtTheEndReturnsNil() {
        var history = EditHistory(initial: PhotoAdjustments.neutral)
        history.record(PhotoAdjustments(exposure: 1))
        XCTAssertNil(history.redo())
    }

    func testANewEditDiscardsTheRedoBranch() {
        var history = EditHistory(initial: PhotoAdjustments.neutral)
        history.record(PhotoAdjustments(exposure: 1))
        history.record(PhotoAdjustments(exposure: 2))
        history.undo()
        XCTAssertTrue(history.canRedo)

        history.record(PhotoAdjustments(exposure: 5))
        XCTAssertFalse(history.canRedo, "Editing after undo must abandon the old branch")
        XCTAssertEqual(history.current.exposure, 5)
    }

    func testHistoryIsBoundedAndDropsTheOldestEntries() {
        var history = EditHistory(initial: PhotoAdjustments.neutral, limit: 3)
        for value in 1...10 {
            history.record(PhotoAdjustments(exposure: Double(value) * 0.1))
        }
        XCTAssertEqual(history.undoCount, 3)

        // Undoing to the bottom lands on the oldest value still retained, not
        // on the original.
        while history.canUndo { history.undo() }
        XCTAssertEqual(history.current.exposure, 0.7, accuracy: 1e-9)
    }

    func testLimitIsNeverBelowOne() {
        var history = EditHistory(initial: PhotoAdjustments.neutral, limit: 0)
        history.record(PhotoAdjustments(exposure: 1))
        XCTAssertTrue(history.canUndo)
    }

    func testResetClearsBothStacks() {
        var history = EditHistory(initial: PhotoAdjustments.neutral)
        history.record(PhotoAdjustments(exposure: 1))
        history.undo()

        history.reset(to: PhotoAdjustments(contrast: 40))
        XCTAssertEqual(history.current.contrast, 40)
        XCTAssertFalse(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    // MARK: - PhotoAdjustments conveniences

    func testResetToNeutralIsItselfUndoable() {
        // Spec §6.2 lists "reset the whole photo" as an action; if it weren't
        // undoable it would be the one destructive button in the editor.
        var history = EditHistory(initial: PhotoAdjustments(exposure: 2, contrast: 30))
        XCTAssertTrue(history.resetToNeutral())
        XCTAssertTrue(history.current.isNeutral)

        history.undo()
        XCTAssertEqual(history.current.exposure, 2)
        XCTAssertEqual(history.current.contrast, 30)
    }

    func testResetToNeutralOnAnUneditedPhotoDoesNothing() {
        var history = EditHistory(initial: PhotoAdjustments.neutral)
        XCTAssertFalse(history.resetToNeutral())
        XCTAssertFalse(history.canUndo)
    }

    func testResettingOneAdjustmentIsUndoable() {
        var history = EditHistory(initial: PhotoAdjustments(exposure: 2, contrast: 30))
        XCTAssertTrue(history.resetAdjustment(.contrast))
        XCTAssertEqual(history.current.contrast, 0)
        XCTAssertEqual(history.current.exposure, 2, "Other sliders must be untouched")

        history.undo()
        XCTAssertEqual(history.current.contrast, 30)
    }

    func testSetAdjustmentClampsThroughTheCatalog() {
        var history = EditHistory(initial: PhotoAdjustments.neutral)
        history.setAdjustment(.exposure, to: 99)
        XCTAssertEqual(history.current.exposure, 5)
    }

    func testSetAdjustmentToTheCurrentValueIsANoOp() {
        var history = EditHistory(initial: PhotoAdjustments(exposure: 1))
        XCTAssertFalse(history.setAdjustment(.exposure, to: 1))
        XCTAssertEqual(history.undoCount, 0)
    }

    func testALongEditSessionUndoesInExactReverseOrder() {
        var history = EditHistory(initial: PhotoAdjustments.neutral)
        let kinds: [AdjustmentKind] = [.exposure, .contrast, .shadows, .vibrance, .saturation]
        for (index, kind) in kinds.enumerated() {
            history.setAdjustment(kind, to: Double(index + 1))
        }

        for kind in kinds.reversed() {
            XCTAssertNotEqual(history.current[kind], 0)
            history.undo()
            XCTAssertEqual(history.current[kind], 0, "\(kind) should be back to default")
        }
        XCTAssertTrue(history.current.isNeutral)
    }
}
