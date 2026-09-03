import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

@MainActor
final class EditorSessionEditingTests: XCTestCase {
    func testOneAdjustmentCreatesOneUndoEntry() {
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

        editor.setAdjustment(.exposure, to: 1.25)
        XCTAssertEqual(editor.adjustments.exposure, 1.25)
        XCTAssertTrue(editor.canUndo)

        editor.undo()
        XCTAssertEqual(editor.adjustments.exposure, 0)
        XCTAssertFalse(editor.canUndo)
    }

    /// AwayPhotoRawEditor parity Phase 1 Task 3: the grouped inspector
    /// panels (Color/Curve/Detail/Effects) edit sub-struct fields that have
    /// no `AdjustmentKind` case of their own -- `setAdjustment(_:to:)` can't
    /// reach `hsl`, `advancedToneCurve`, `sharpening`, `noiseReduction`,
    /// `vignette` or `grain`. `updateAdjustments(_:)` is the one general
    /// entry point those panels go through instead, and it must land on the
    /// same undo stack `setAdjustment` does.
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

    func testUpdateAdjustmentsAppliesTheTransformAndCreatesOneUndoEntry() {
        let editor = makeOpenEditor()

        editor.updateAdjustments { $0.hsl.red.saturation = 40 }

        XCTAssertEqual(editor.adjustments.hsl.red.saturation, 40)
        XCTAssertTrue(editor.canUndo)

        editor.undo()
        XCTAssertEqual(editor.adjustments.hsl.red.saturation, 0)
        XCTAssertFalse(editor.canUndo)
    }

    func testUpdateAdjustmentsIsANoOpWhenTheTransformDoesNotChangeAnything() {
        let editor = makeOpenEditor()

        editor.updateAdjustments { $0.hsl.red.saturation = 0 }

        XCTAssertFalse(editor.canUndo, "setting a field to its already-current value must not push an undo entry")
    }

    func testUpdateAdjustmentsDoesNothingWithoutAnOpenPhoto() {
        let editor = EditorSession()

        editor.updateAdjustments { $0.hsl.red.saturation = 40 }

        XCTAssertEqual(editor.adjustments, .neutral)
        XCTAssertFalse(editor.canUndo)
    }

    func testUpdateAdjustmentsCanEditEverySubStructTheGroupedPanelsNeed() {
        let editor = makeOpenEditor()

        editor.updateAdjustments { $0.sharpening.amount = 30 }
        editor.updateAdjustments { $0.noiseReduction.luminanceAmount = 20 }
        editor.updateAdjustments { $0.vignette.amount = -15 }
        editor.updateAdjustments { $0.grain.amount = 10 }
        editor.updateAdjustments { $0.advancedToneCurve = AdvancedToneCurve(points: [ToneCurvePoint(x: 0.25, y: 0.5)]) }

        XCTAssertEqual(editor.adjustments.sharpening.amount, 30)
        XCTAssertEqual(editor.adjustments.noiseReduction.luminanceAmount, 20)
        XCTAssertEqual(editor.adjustments.vignette.amount, -15)
        XCTAssertEqual(editor.adjustments.grain.amount, 10)
        XCTAssertFalse(editor.adjustments.advancedToneCurve.isIdentity)
    }

    // MARK: - Tool mode (Phase 2 Task 2.3)

    func testToolModeDefaultsToAdjust() {
        let editor = makeOpenEditor()
        XCTAssertEqual(editor.toolMode, .adjust)
    }

    func testSetToolModeSwitchesToCropAndBack() {
        let editor = makeOpenEditor()

        editor.setToolMode(.crop)
        XCTAssertEqual(editor.toolMode, .crop)

        editor.setToolMode(.adjust)
        XCTAssertEqual(editor.toolMode, .adjust)
    }

    /// Purely UI state -- switching tools must never touch the undo stack,
    /// save state, or an unrelated adjustment.
    func testSettingToolModeDoesNotCreateAnUndoEntryOrDirtyTheSaveState() {
        let editor = makeOpenEditor()
        XCTAssertFalse(editor.canUndo)

        editor.setToolMode(.crop)

        XCTAssertFalse(editor.canUndo)
        XCTAssertEqual(editor.saveState, .unchanged)
        XCTAssertEqual(editor.adjustments, .neutral)
    }

    /// Opening a different photo while the crop tool is active must not
    /// leave a crop overlay armed against a photo the user never asked to
    /// crop.
    func testOpeningAPhotoResetsToolModeToAdjust() {
        let editor = makeOpenEditor()
        editor.setToolMode(.crop)
        XCTAssertEqual(editor.toolMode, .crop)

        let secondPhoto = PhotoAsset(
            id: PhotoID(),
            libraryID: LibraryID(),
            relativePath: "second.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "second"),
            status: .ready
        )
        editor.open(
            photo: secondPhoto,
            sourceURL: URL(fileURLWithPath: "/second.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )

        XCTAssertEqual(editor.toolMode, .adjust)
    }

    func testClosingResetsToolModeToAdjust() {
        let editor = makeOpenEditor()
        editor.setToolMode(.crop)

        editor.close()

        XCTAssertEqual(editor.toolMode, .adjust)
    }

    // MARK: - White balance eyedropper (Phase 2 Task 2.4)

    /// Design spec §6.4: "使用者必須能取消滴管，不得在 hover / preview 階段寫入
    /// sidecar" -- previewing must change what's *displayed* without
    /// touching `history`/`saveState`/Undo at all, the same contract
    /// `previewPreset(_:mode:)` already guarantees for presets
    /// (`PresetWorkflowTests`).
    func testPreviewEyedropperChangesDisplayedAdjustmentsButNotCommittedAdjustments() {
        let editor = makeOpenEditor()
        let warmSample = WhiteBalanceEyedropper.Sample(red: 0.6, green: 0.5, blue: 0.4)

        editor.previewEyedropper(sample: warmSample)

        XCTAssertNotEqual(editor.displayedAdjustments.temperature, 0)
        XCTAssertEqual(editor.adjustments, .neutral, "the committed adjustments must be untouched by a preview")
    }

    func testPreviewEyedropperDoesNotDirtySaveStateOrTouchUndo() {
        let editor = makeOpenEditor()
        editor.previewEyedropper(sample: WhiteBalanceEyedropper.Sample(red: 0.6, green: 0.5, blue: 0.4))

        XCTAssertEqual(editor.saveState, .unchanged)
        XCTAssertFalse(editor.canUndo)
    }

    func testCancellingAnEyedropperPreviewRestoresTheCommittedAdjustments() {
        let editor = makeOpenEditor()
        editor.previewEyedropper(sample: WhiteBalanceEyedropper.Sample(red: 0.6, green: 0.5, blue: 0.4))
        XCTAssertNotEqual(editor.displayedAdjustments, .neutral)

        editor.cancelEyedropperPreview()

        XCTAssertEqual(editor.displayedAdjustments, .neutral)
        XCTAssertEqual(editor.saveState, .unchanged)
        XCTAssertFalse(editor.canUndo)
    }

    func testCancellingWithNoActiveEyedropperPreviewIsHarmless() {
        let editor = makeOpenEditor()
        editor.cancelEyedropperPreview() // must not crash or change anything
        XCTAssertEqual(editor.displayedAdjustments, .neutral)
    }

    func testCommittingAnEyedropperSampleAppliesItAndCreatesExactlyOneUndoEntry() {
        let editor = makeOpenEditor()
        editor.previewEyedropper(sample: WhiteBalanceEyedropper.Sample(red: 0.6, green: 0.5, blue: 0.4))

        editor.commitEyedropper()

        XCTAssertNotEqual(editor.adjustments.temperature, 0, "the sampled delta must land on the committed adjustments")
        XCTAssertEqual(editor.displayedAdjustments, editor.adjustments)
        XCTAssertTrue(editor.canUndo)

        editor.undo()
        XCTAssertEqual(editor.adjustments.temperature, 0, "exactly one undo entry, regardless of how the preview updated along the way")
    }

    func testCommittingAnEyedropperSampleMarksTheEditDirty() {
        let editor = makeOpenEditor()
        editor.previewEyedropper(sample: WhiteBalanceEyedropper.Sample(red: 0.6, green: 0.5, blue: 0.4))
        editor.commitEyedropper()
        XCTAssertEqual(editor.saveState, .pending)
    }

    func testCommittingWithNoActivePreviewIsANoOp() {
        let editor = makeOpenEditor()
        editor.commitEyedropper()
        XCTAssertEqual(editor.adjustments, .neutral)
        XCTAssertFalse(editor.canUndo)
    }

    /// An already-neutral sample resolves to no delta at all
    /// (`WhiteBalanceEyedropperTests.testAnAlreadyNeutralSampleProducesNoDelta`),
    /// so committing it must add no history entry -- same "no-op transform
    /// pushes nothing to Undo" contract every other edit path in this class
    /// already has.
    func testCommittingANeutralSampleAddsNoHistoryEntry() {
        let editor = makeOpenEditor()
        editor.previewEyedropper(sample: WhiteBalanceEyedropper.Sample(red: 0.5, green: 0.5, blue: 0.5))
        editor.commitEyedropper()
        XCTAssertFalse(editor.canUndo)
    }

    func testPreviewingASecondSampleReplacesTheFirstRatherThanCompounding() {
        let editor = makeOpenEditor()
        editor.previewEyedropper(sample: WhiteBalanceEyedropper.Sample(red: 0.6, green: 0.5, blue: 0.4))
        let firstPreviewTemperature = editor.displayedAdjustments.temperature

        editor.previewEyedropper(sample: WhiteBalanceEyedropper.Sample(red: 0.7, green: 0.5, blue: 0.3))

        XCTAssertNotEqual(
            editor.displayedAdjustments.temperature, firstPreviewTemperature + firstPreviewTemperature,
            "re-sampling must not stack the two deltas together"
        )
    }

    func testPreviewEyedropperDoesNothingWithoutAnOpenPhoto() {
        let editor = EditorSession()
        editor.previewEyedropper(sample: WhiteBalanceEyedropper.Sample(red: 0.6, green: 0.5, blue: 0.4))
        XCTAssertEqual(editor.displayedAdjustments, .neutral)
    }

    func testOpeningAPhotoClearsAnyActiveEyedropperPreview() {
        let editor = makeOpenEditor()
        editor.previewEyedropper(sample: WhiteBalanceEyedropper.Sample(red: 0.6, green: 0.5, blue: 0.4))
        XCTAssertNotEqual(editor.displayedAdjustments, .neutral)

        let secondPhoto = PhotoAsset(
            id: PhotoID(),
            libraryID: LibraryID(),
            relativePath: "second.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "second"),
            status: .ready
        )
        editor.open(
            photo: secondPhoto,
            sourceURL: URL(fileURLWithPath: "/second.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )

        XCTAssertEqual(editor.displayedAdjustments, .neutral)
    }

    func testClosingClearsAnyActiveEyedropperPreview() {
        let editor = makeOpenEditor()
        editor.previewEyedropper(sample: WhiteBalanceEyedropper.Sample(red: 0.6, green: 0.5, blue: 0.4))

        editor.close()

        XCTAssertEqual(editor.displayedAdjustments, .neutral)
    }
}
