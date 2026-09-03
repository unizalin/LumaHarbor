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

    // MARK: - Crop tool preview (independent-review P1 fix)

    /// `CropOverlayView` (Task 2.3) draws and drags against `editor
    /// .displayedImage`, which is rendered from `displayedAdjustments` --
    /// that image must show the fully rotated/flipped/straightened frame
    /// *without* the crop applied while the crop tool is active, or the
    /// overlay has no correct frame to reference (re-editing an existing
    /// crop would show an already-cropped-and-filled preview with no way to
    /// see what was cropped away). The *committed* crop
    /// (`editor.adjustments.geometry.crop`) must stay untouched throughout
    /// -- only what's rendered changes, not what's stored.
    func testDisplayedAdjustmentsStripTheCropWhileTheCropToolIsActive() {
        let editor = makeOpenEditor()
        editor.updateAdjustments { $0.geometry.crop = NormalizedCropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5) }
        XCTAssertNotNil(editor.displayedAdjustments.geometry.crop, "outside the crop tool, the committed crop is what's displayed")

        editor.setToolMode(.crop)

        XCTAssertNil(editor.displayedAdjustments.geometry.crop, "the crop tool's own preview must show the pre-crop frame")
        XCTAssertNotNil(editor.adjustments.geometry.crop, "the committed crop itself must be untouched")
    }

    func testDisplayedAdjustmentsRestoreTheCropWhenLeavingTheCropTool() {
        let editor = makeOpenEditor()
        editor.updateAdjustments { $0.geometry.crop = NormalizedCropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5) }
        editor.setToolMode(.crop)
        XCTAssertNil(editor.displayedAdjustments.geometry.crop)

        editor.setToolMode(.adjust)

        XCTAssertNotNil(editor.displayedAdjustments.geometry.crop)
        XCTAssertEqual(editor.displayedAdjustments, editor.adjustments)
    }

    /// The crop-stripping is purely a display-time transform; it must not
    /// touch every other geometry field (rotation especially -- the whole
    /// point of the independent-review fix is that rotate/flip/straighten
    /// stay applied while cropping).
    func testDisplayedAdjustmentsInCropToolModeKeepEveryOtherGeometryField() {
        let editor = makeOpenEditor()
        editor.updateAdjustments {
            $0.geometry.crop = NormalizedCropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
            $0.geometry.rotationDegrees = 90
            $0.geometry.flipHorizontal = true
        }
        editor.setToolMode(.crop)

        XCTAssertEqual(editor.displayedAdjustments.geometry.rotationDegrees, 90)
        XCTAssertTrue(editor.displayedAdjustments.geometry.flipHorizontal)
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

    // MARK: - Adjustment gesture hooks (Phase 3 Task 3.3: batch sync)
    //
    // `beginAdjustmentGesture()`/`endAdjustmentGesture()` are the seam a
    // caller that supports thumbnail multi-select (`LibraryViewModel`, in
    // practice) uses to snapshot the batch's target list and the source
    // photo's own before/after state -- `EditorSession` itself has no
    // concept of "the library" or "other selected photos", it only fires
    // `EditorDependencies`' two optional hooks with `history.current` at
    // the right two moments. Neither hook exists in a build that doesn't
    // wire one (both default to `nil`), so this is zero-cost everywhere
    // else in this codebase.

    private struct NoOpPreviewRenderer: PreviewRendering {
        func render(_ request: PreviewRequest) async throws -> PreviewImage {
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
    }

    private func makeOpenEditorWithGestureHooks(
        onBeginAdjustmentGesture: (@Sendable (PhotoAdjustments) -> Void)? = nil,
        onEndAdjustmentGesture: (@Sendable (PhotoAdjustments) -> Void)? = nil
    ) -> EditorSession {
        let renderer = NoOpPreviewRenderer()
        let editor = EditorSession()
        editor.attach(dependencies: EditorDependencies(
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            loadAdjustments: { _ in .neutral },
            saveAdjustments: { _, _ in },
            onBeginAdjustmentGesture: onBeginAdjustmentGesture,
            onEndAdjustmentGesture: onEndAdjustmentGesture
        ))
        editor.open(
            photo: PhotoAsset(
                id: PhotoID(),
                libraryID: LibraryID(),
                relativePath: "fixture.ARW",
                fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"),
                status: .ready
            ),
            sourceURL: URL(fileURLWithPath: "/fixture.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )
        return editor
    }

    func testBeginAdjustmentGestureFiresTheHookWithTheCurrentAdjustments() {
        var captured: PhotoAdjustments?
        let editor = makeOpenEditorWithGestureHooks(onBeginAdjustmentGesture: { captured = $0 })
        editor.updateAdjustments { $0.exposure = 0.5 }

        editor.beginAdjustmentGesture()

        XCTAssertEqual(captured?.exposure, 0.5)
    }

    func testBeginAdjustmentGestureDoesNothingWithoutAnOpenPhoto() {
        var fired = false
        let editor = EditorSession()
        let renderer = NoOpPreviewRenderer()
        editor.attach(dependencies: EditorDependencies(
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            loadAdjustments: { _ in .neutral },
            saveAdjustments: { _, _ in },
            onBeginAdjustmentGesture: { _ in fired = true }
        ))

        editor.beginAdjustmentGesture()

        XCTAssertFalse(fired, "no photo is open -- there is nothing to snapshot a gesture baseline from")
    }

    func testEndAdjustmentGestureFiresTheHookWithTheCurrentAdjustments() {
        var captured: PhotoAdjustments?
        let editor = makeOpenEditorWithGestureHooks(onEndAdjustmentGesture: { captured = $0 })
        editor.updateAdjustments { $0.contrast = 30 }

        editor.endAdjustmentGesture()

        XCTAssertEqual(captured?.contrast, 30)
    }

    /// The end-to-end shape a real drag produces: begin captures the
    /// baseline *before* any of this drag's own changes, end captures the
    /// final value *after* -- proving the two hooks actually bracket an
    /// edit rather than both firing with the same snapshot.
    func testBeginAndEndAdjustmentGestureBracketAnEditWithDistinctBeforeAndAfterSnapshots() {
        var began: PhotoAdjustments?
        var ended: PhotoAdjustments?
        let editor = makeOpenEditorWithGestureHooks(
            onBeginAdjustmentGesture: { began = $0 },
            onEndAdjustmentGesture: { ended = $0 }
        )

        editor.beginAdjustmentGesture()
        editor.updateAdjustments { $0.exposure = 2.0 }
        editor.endAdjustmentGesture()

        XCTAssertEqual(began?.exposure, 0, "begin must capture the value before this drag's own change")
        XCTAssertEqual(ended?.exposure, 2.0, "end must capture the value after this drag's own change")
    }

    /// Independent review of Task 3.3: `resetAdjustment(_:)`/`resetAll()`
    /// are reachable through the very same ten basic sliders the gesture
    /// hooks are wired to (a context-menu "Reset <field>", a double-click
    /// on the row, or "Reset All Adjustments") -- but neither method fired
    /// either hook, so a batch's other selected photos silently never heard
    /// about a reset, even though a drag on that same field would have
    /// synced it. Reset must bracket its own change with begin/end the same
    /// way a drag does, using the value from just before the reset as the
    /// baseline.
    func testResetAdjustmentFiresBeginAndEndGestureHooksBracketingTheReset() {
        var began: PhotoAdjustments?
        var ended: PhotoAdjustments?
        let editor = makeOpenEditorWithGestureHooks(
            onBeginAdjustmentGesture: { began = $0 },
            onEndAdjustmentGesture: { ended = $0 }
        )
        editor.updateAdjustments { $0.exposure = 1.5 }

        editor.resetAdjustment(.exposure)

        XCTAssertEqual(began?.exposure, 1.5, "begin must capture the value from just before the reset")
        XCTAssertEqual(ended?.exposure, 0, "end must capture the value after the reset")
    }

    func testResetAdjustmentDoesNotFireGestureHooksWhenTheFieldIsAlreadyNeutral() {
        var fired = false
        let editor = makeOpenEditorWithGestureHooks(onBeginAdjustmentGesture: { _ in fired = true })

        editor.resetAdjustment(.exposure)

        XCTAssertFalse(fired, "resetting an already-neutral field changes nothing -- there is nothing for a batch to sync")
    }

    func testResetAllFiresBeginAndEndGestureHooksBracketingEveryFieldItResets() {
        var began: PhotoAdjustments?
        var ended: PhotoAdjustments?
        let editor = makeOpenEditorWithGestureHooks(
            onBeginAdjustmentGesture: { began = $0 },
            onEndAdjustmentGesture: { ended = $0 }
        )
        editor.updateAdjustments {
            $0.exposure = 1.5
            $0.contrast = 30
        }

        editor.resetAll()

        XCTAssertEqual(began?.exposure, 1.5, "begin must capture every field's value from just before resetAll")
        XCTAssertEqual(began?.contrast, 30)
        XCTAssertEqual(ended?.exposure, 0, "end must capture every field's value after resetAll")
        XCTAssertEqual(ended?.contrast, 0)
    }

    func testResetAllDoesNotFireGestureHooksWhenAlreadyNeutral() {
        var fired = false
        let editor = makeOpenEditorWithGestureHooks(onBeginAdjustmentGesture: { _ in fired = true })

        editor.resetAll()

        XCTAssertFalse(fired, "resetting an already-neutral photo changes nothing -- there is nothing for a batch to sync")
    }
}
