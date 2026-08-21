import Foundation
import XCTest
@testable import LumaHarborApp
@testable import PhotoLibraryCore
@testable import PresetCore
@testable import RawProcessingCore

/// Spec §5.3/§9.1: a preset preview (hover, keyboard selection) is purely
/// visual -- it must never dirty the save state, touch Undo/Redo, or leave a
/// trace once cancelled. Committing a preset, however many leaves it sets,
/// must land as exactly one Undo entry.
@MainActor
final class PresetWorkflowTests: AppViewModelTestCase {
    private func makePreset(
        exposure: Double? = nil,
        contrast: Double? = nil,
        temperature: Double? = nil,
        source: PresetSource = .native
    ) -> PresetDocument {
        PresetDocument(
            name: "Test Preset",
            source: source,
            patch: AdjustmentPatch(
                basic: BasicAdjustmentPatch(exposure: exposure, temperature: temperature, contrast: contrast)
            )
        )
    }

    private func openedEditor(
        adjustments: PhotoAdjustments = .neutral,
        isReadOnly: Bool = false
    ) async throws -> EditorViewModel {
        try seedPhotos(["DSC0001.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let photo = try XCTUnwrap(model.photos.first)

        model.editor.open(
            photo: photo,
            sourceURL: photo.url(inLibraryRootedAt: library.rootURL),
            adjustments: adjustments,
            isReadOnly: isReadOnly
        )
        return model.editor
    }

    // MARK: - Preview is transient

    func testPreviewingAPresetChangesDisplayedAdjustmentsButNotCommittedAdjustments() async throws {
        let editor = try await openedEditor()
        let preset = makePreset(exposure: 1.5)

        editor.previewPreset(preset, mode: .merge)

        XCTAssertEqual(editor.displayedAdjustments.exposure, 1.5)
        XCTAssertEqual(editor.adjustments, .neutral, "Preview must not touch the committed edit")
    }

    func testPreviewingAPresetDoesNotDirtySaveState() async throws {
        let editor = try await openedEditor()
        let preset = makePreset(exposure: 1.5)

        editor.previewPreset(preset, mode: .merge)

        XCTAssertFalse(editor.saveState.isDirty, "A preview alone must never mark the edit as unsaved")
    }

    func testPreviewingAPresetDoesNotChangeUndoRedoAvailability() async throws {
        let editor = try await openedEditor()
        let preset = makePreset(exposure: 1.5)

        XCTAssertFalse(editor.canUndo)
        editor.previewPreset(preset, mode: .merge)
        XCTAssertFalse(editor.canUndo, "Preview must not push a history entry")
        XCTAssertFalse(editor.canRedo)
    }

    func testCancellingAPresetPreviewRestoresTheCommittedAdjustments() async throws {
        let editor = try await openedEditor()
        editor.setAdjustment(.saturation, to: 20)
        let committedBeforePreview = editor.adjustments

        editor.previewPreset(makePreset(exposure: 1.5), mode: .merge)
        XCTAssertNotEqual(editor.displayedAdjustments, committedBeforePreview)

        editor.cancelPresetPreview()
        XCTAssertEqual(editor.displayedAdjustments, committedBeforePreview)
        XCTAssertEqual(editor.adjustments, committedBeforePreview)
    }

    func testCancellingWithNoActivePreviewIsHarmless() async throws {
        let editor = try await openedEditor()
        editor.cancelPresetPreview() // must not crash or change anything
        XCTAssertEqual(editor.displayedAdjustments, .neutral)
    }

    func testPreviewingASecondPresetReplacesTheFirstRatherThanCompounding() async throws {
        let editor = try await openedEditor()
        editor.previewPreset(makePreset(exposure: 1.0), mode: .merge)
        XCTAssertEqual(editor.displayedAdjustments.exposure, 1.0)

        editor.previewPreset(makePreset(exposure: 2.0), mode: .merge)
        XCTAssertEqual(editor.displayedAdjustments.exposure, 2.0, "Hovering a second preset must not stack onto the first preview")
    }

    // MARK: - Commit is exactly one Undo entry

    func testCommittingAPresetAppliesItToTheCommittedAdjustments() async throws {
        let editor = try await openedEditor()
        editor.commitPreset(makePreset(exposure: 1.5, contrast: 20), mode: .merge)

        XCTAssertEqual(editor.adjustments.exposure, 1.5)
        XCTAssertEqual(editor.adjustments.contrast, 20)
        XCTAssertEqual(editor.displayedAdjustments, editor.adjustments)
    }

    func testCommittingAMultiFieldPresetCreatesExactlyOneUndoEntry() async throws {
        let editor = try await openedEditor()
        XCTAssertFalse(editor.canUndo)

        editor.commitPreset(makePreset(exposure: 1.5, contrast: 20), mode: .merge)
        XCTAssertTrue(editor.canUndo)

        editor.undo()
        XCTAssertEqual(editor.adjustments, .neutral, "One undo must fully revert a multi-field preset commit")
        XCTAssertFalse(editor.canUndo, "The whole preset commit must have been a single history entry")
    }

    func testCommittingAPresetMarksTheEditDirty() async throws {
        let editor = try await openedEditor()
        editor.commitPreset(makePreset(exposure: 1.5), mode: .merge)
        XCTAssertTrue(editor.saveState.isDirty)
    }

    func testCommittingClearsAnyActivePreview() async throws {
        let editor = try await openedEditor()
        editor.previewPreset(makePreset(exposure: 1.0), mode: .merge)
        editor.commitPreset(makePreset(exposure: 2.0), mode: .merge)

        editor.cancelPresetPreview() // no-op: nothing should still be "previewing"
        XCTAssertEqual(editor.adjustments.exposure, 2.0)
        XCTAssertEqual(editor.displayedAdjustments.exposure, 2.0)
    }

    func testCommittingAPresetThatMatchesTheCurrentStateAddsNoHistoryEntry() async throws {
        let editor = try await openedEditor()
        editor.commitPreset(makePreset(exposure: 0), mode: .merge) // .neutral already has exposure 0
        XCTAssertFalse(editor.canUndo, "Applying a no-op preset must not create an undo step")
    }

    // MARK: - Merge vs. replace

    func testMergeKeepsFieldsThePresetDoesNotTouch() async throws {
        let editor = try await openedEditor()
        editor.setAdjustment(.saturation, to: 30)
        editor.commitPreset(makePreset(exposure: 1.0), mode: .merge)

        XCTAssertEqual(editor.adjustments.exposure, 1.0)
        XCTAssertEqual(editor.adjustments.saturation, 30, "Merge must not reset fields the preset doesn't set")
    }

    func testReplaceResetsFieldsThePresetDoesNotTouch() async throws {
        let editor = try await openedEditor()
        editor.setAdjustment(.saturation, to: 30)
        editor.commitPreset(makePreset(exposure: 1.0), mode: .replace)

        XCTAssertEqual(editor.adjustments.exposure, 1.0)
        XCTAssertEqual(editor.adjustments.saturation, 0, "Replace must start from neutral")
    }

    // MARK: - White-balance baseline lifecycle

    func testAdobeSourcedTemperatureWithoutABaselineYetLeavesTemperatureUntouched() async throws {
        // Nothing has rendered yet immediately after `open()`, so there is no
        // baseline -- an absolute-Kelvin preset's temperature must be left
        // alone rather than resolved against a fabricated baseline of 0
        // (spec §5.3).
        let editor = try await openedEditor()
        editor.commitPreset(
            makePreset(exposure: 1.0, temperature: 5500, source: .adobeXMP(tool: nil, version: nil)),
            mode: .merge
        )
        XCTAssertEqual(editor.adjustments.exposure, 1.0)
        XCTAssertEqual(editor.adjustments.temperature, 0, "No baseline yet: the contextual leaf must be a no-op, not a guess")
    }

    // MARK: - No open photo

    func testPreviewAndCommitAreNoOpsWithNoPhotoOpen() {
        let editor = EditorViewModel()
        editor.previewPreset(makePreset(exposure: 1.0), mode: .merge)
        XCTAssertEqual(editor.displayedAdjustments, .neutral)
        editor.commitPreset(makePreset(exposure: 1.0), mode: .merge)
        XCTAssertEqual(editor.adjustments, .neutral)
        XCTAssertFalse(editor.canUndo)
    }
}
