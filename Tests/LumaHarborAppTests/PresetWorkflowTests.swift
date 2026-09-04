import Foundation
import Localization
import XCTest
@testable import EditorCore
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
    ) async throws -> EditorSession {
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

    // MARK: - Preset application diagnostics are surfaced, not discarded (finding #4)
    //
    // `PresetApplicator.apply` used to be wrapped in `try?`, which threw away
    // `PresetApplicationResult.diagnostics` along with any thrown error --
    // even though `apply` never actually throws. These lock down that a
    // skipped contextual leaf (no white-balance baseline yet) is something
    // the view model actually surfaces, both during a transient hover
    // preview and after a real commit.

    func testPreviewingAnAdobePresetWithoutABaselineSurfacesADiagnostic() async throws {
        let editor = try await openedEditor()
        XCTAssertTrue(editor.presetPreviewDiagnostics.isEmpty)

        editor.previewPreset(
            makePreset(exposure: 1.0, temperature: 5500, source: .adobeXMP(tool: nil, version: nil)),
            mode: .merge
        )

        XCTAssertTrue(
            editor.presetPreviewDiagnostics.contains { $0.code == "missingWhiteBalanceBaseline" },
            "The skipped contextual leaf must be observable, not silently dropped"
        )
    }

    /// Round 2, finding #3: `presetPreviewDiagnostics` being non-empty was
    /// necessary but not sufficient -- nothing in `PresetBrowserView`
    /// actually read it, so a hovering user never saw anything. This
    /// asserts on `presetPreviewMessage`, the derived presentation-state
    /// property `PresetBrowserView.previewDiagnostic` binds to directly:
    /// the exact safe text that would appear on screen, not just an
    /// internal fact about the diagnostics array.
    func testPreviewingAnAdobePresetWithoutABaselinePublishesTheExactMessageTheBrowserWouldDisplay() async throws {
        let editor = try await openedEditor()
        XCTAssertNil(editor.presetPreviewMessage)

        editor.previewPreset(
            makePreset(exposure: 1.0, temperature: 5500, source: .adobeXMP(tool: nil, version: nil)),
            mode: .merge
        )

        let message = try XCTUnwrap(editor.presetPreviewMessage)
        XCTAssertEqual(
            message,
            L10n.t("White balance from this preset couldn't be applied yet because this photo hasn't finished decoding.")
        )
    }

    func testPreviewingAPresetWithNoIssuesReportsNoDiagnostics() async throws {
        let editor = try await openedEditor()
        editor.previewPreset(makePreset(exposure: 1.5), mode: .merge)
        XCTAssertTrue(editor.presetPreviewDiagnostics.isEmpty)
    }

    func testCancellingAPresetPreviewClearsItsDiagnostics() async throws {
        let editor = try await openedEditor()
        editor.previewPreset(
            makePreset(exposure: 1.0, temperature: 5500, source: .adobeXMP(tool: nil, version: nil)),
            mode: .merge
        )
        XCTAssertFalse(editor.presetPreviewDiagnostics.isEmpty)
        XCTAssertNotNil(editor.presetPreviewMessage)

        editor.cancelPresetPreview()
        XCTAssertTrue(editor.presetPreviewDiagnostics.isEmpty)
        // The displayed presentation-state, not just the underlying array,
        // must also clear -- otherwise `PresetBrowserView.previewDiagnostic`
        // would leave a stale message on screen after the pointer moves off
        // the row (round 2, finding #3).
        XCTAssertNil(editor.presetPreviewMessage)
    }

    func testCommittingAnAdobePresetWithoutABaselineShowsANonBlockingButVisibleAlert() async throws {
        let editor = try await openedEditor()
        XCTAssertNil(editor.alert)

        editor.commitPreset(
            makePreset(exposure: 1.0, temperature: 5500, source: .adobeXMP(tool: nil, version: nil)),
            mode: .merge
        )

        let alert = try XCTUnwrap(editor.alert, "A skipped contextual field must reach the user somehow, not vanish")
        XCTAssertFalse(alert.message.isEmpty)
        // Spec §6.2/§11: user-facing text must never carry unvetted internal
        // detail -- the diagnostic's raw `detail` (e.g. "requested=5500...")
        // must not leak into what's shown.
        XCTAssertFalse(alert.message.contains("requested="))
    }

    func testCommittingAPresetWithNoDiagnosticsDoesNotShowAnAlert() async throws {
        let editor = try await openedEditor()
        editor.commitPreset(makePreset(exposure: 1.5, contrast: 20), mode: .merge)
        XCTAssertNil(editor.alert, "A preset with nothing to report must not interrupt the user")
    }

    /// Round 2, finding #3: the preset here sets *only* `temperature`, so
    /// with no white-balance baseline yet, the one leaf it has gets
    /// skipped and nothing else in the patch touches anything -- unlike
    /// `testCommittingAnAdobePresetWithoutABaselineShowsANonBlockingButVisibleAlert`
    /// above, whose preset also sets `exposure` and therefore *does*
    /// change something. `history.record` here must be a genuine no-op
    /// (`false`): no Undo entry, `adjustments` unchanged, not dirty -- but
    /// the diagnostic must still reach `alert`, which a `guard
    /// history.record(...) else { return }` placed before the alert would
    /// have skipped entirely.
    func testCommittingAnAdobePresetWithOnlyASkippedTemperatureLeafIsANoOpButStillShowsTheAlert() async throws {
        let editor = try await openedEditor()
        XCTAssertNil(editor.alert)
        let adjustmentsBefore = editor.adjustments
        let canUndoBefore = editor.canUndo
        let saveStateBefore = editor.saveState

        editor.commitPreset(
            makePreset(temperature: 5500, source: .adobeXMP(tool: nil, version: nil)),
            mode: .merge
        )

        XCTAssertEqual(editor.adjustments, adjustmentsBefore, "A no-op commit must not change the committed adjustments")
        XCTAssertEqual(editor.canUndo, canUndoBefore, "A no-op commit must not push an Undo entry")
        XCTAssertEqual(editor.saveState, saveStateBefore, "A no-op commit must not mark the photo dirty")

        let alert = try XCTUnwrap(
            editor.alert,
            "A no-op history.record must not swallow the diagnostic -- the skipped leaf is still real information"
        )
        XCTAssertFalse(alert.message.isEmpty)
        XCTAssertFalse(alert.message.contains("requested="))
    }

    func testCommittingClearsPresetPreviewDiagnosticsEvenWhenTheCommitItselfHasNone() async throws {
        let editor = try await openedEditor()
        editor.previewPreset(
            makePreset(exposure: 1.0, temperature: 5500, source: .adobeXMP(tool: nil, version: nil)),
            mode: .merge
        )
        XCTAssertFalse(editor.presetPreviewDiagnostics.isEmpty)

        editor.commitPreset(makePreset(exposure: 1.5), mode: .merge)
        XCTAssertTrue(editor.presetPreviewDiagnostics.isEmpty)
    }

    // MARK: - No open photo

    func testPreviewAndCommitAreNoOpsWithNoPhotoOpen() {
        let editor = EditorSession()
        editor.previewPreset(makePreset(exposure: 1.0), mode: .merge)
        XCTAssertEqual(editor.displayedAdjustments, .neutral)
        editor.commitPreset(makePreset(exposure: 1.0), mode: .merge)
        XCTAssertEqual(editor.adjustments, .neutral)
        XCTAssertFalse(editor.canUndo)
    }
}

// MARK: - PresetLibraryViewModel

/// In-memory `PresetRepository` for view-model tests that shouldn't need real
/// file I/O -- only what confirms writes actually happened (or didn't).
actor RecordingPresetRepository: PresetRepository {
    private(set) var savedDocuments: [PresetDocument] = []
    private(set) var deletedIDs: [UUID] = []
    private var storage: [UUID: PresetDocument]
    /// When set, `save` throws this instead of recording anything -- lets a
    /// test simulate a save failure (e.g. finding #6: `toggleFavorite` must
    /// not silently swallow one) without real file I/O.
    private var saveError: Error?

    init(seed: [PresetDocument] = []) {
        storage = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
    }

    func setSaveError(_ error: Error?) {
        saveError = error
    }

    func list() async throws -> [PresetDocument] { Array(storage.values) }
    func load(id: UUID) async throws -> PresetDocument? { storage[id] }

    func save(_ document: PresetDocument, conflict: PresetConflictResolution) async throws -> PresetStoreResult {
        if let saveError { throw saveError }
        savedDocuments.append(document)
        storage[document.id] = document
        return .created
    }

    func delete(id: UUID) async throws {
        deletedIDs.append(id)
        storage.removeValue(forKey: id)
    }
}

@MainActor
final class PresetLibraryViewModelTests: AppViewModelTestCase {
    private func makeDocument(name: String = "Preset", isFavorite: Bool = false, groupPath: [String] = []) -> PresetDocument {
        PresetDocument(
            name: name,
            groupPath: groupPath,
            isFavorite: isFavorite,
            patch: AdjustmentPatch(basic: BasicAdjustmentPatch(exposure: 1.0))
        )
    }

    private func writeFixtureXMP(name: String = "Fixture") throws -> URL {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ProcessVersion="15.4" crs:Exposure2012="+0.50" crs:Contrast2012="+10"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let url = temporaryDirectory.appendingPathComponent("\(name).xmp")
        try Data(xml.utf8).write(to: url)
        return url
    }

    // MARK: - Loading, search, scope filter

    func testLoadMergesMineAndLibraryScopes() async throws {
        let mine = RecordingPresetRepository(seed: [makeDocument(name: "Mine")])
        let library = RecordingPresetRepository(seed: [makeDocument(name: "Library")])
        // Empty built-in scope: this test is specifically about mine/library
        // merging, not the (unrelated) real built-in preset content.
        let sut = PresetLibraryViewModel(
            myRepository: mine, libraryRepository: library,
            builtInRepository: BuiltInPresetRepository(documents: [])
        )

        await sut.load()

        XCTAssertEqual(Set(sut.items.map(\.document.name)), ["Mine", "Library"])
        XCTAssertEqual(sut.items.first { $0.document.name == "Mine" }?.scope, .mine)
        XCTAssertEqual(sut.items.first { $0.document.name == "Library" }?.scope, .library)
    }

    func testSearchMatchesNameOrGroupPath() async throws {
        let mine = RecordingPresetRepository(seed: [
            makeDocument(name: "Golden Hour"),
            makeDocument(name: "Moody", groupPath: ["Black and White"])
        ])
        let sut = PresetLibraryViewModel(myRepository: mine)
        await sut.load()

        sut.searchText = "golden"
        XCTAssertEqual(sut.filteredItems.map(\.document.name), ["Golden Hour"])

        sut.searchText = "black and white"
        XCTAssertEqual(sut.filteredItems.map(\.document.name), ["Moody"])
    }

    func testScopeFilterNarrowsToOneScopeOrFavorites() async throws {
        let mine = RecordingPresetRepository(seed: [makeDocument(name: "Mine", isFavorite: true)])
        let library = RecordingPresetRepository(seed: [makeDocument(name: "Library")])
        // Empty built-in scope: this test is specifically about mine/
        // library/favorites filtering, not the real built-in preset content.
        let sut = PresetLibraryViewModel(
            myRepository: mine, libraryRepository: library,
            builtInRepository: BuiltInPresetRepository(documents: [])
        )
        await sut.load()

        sut.scopeFilter = .scope(.mine)
        XCTAssertEqual(sut.filteredItems.map(\.document.name), ["Mine"])

        sut.scopeFilter = .scope(.library)
        XCTAssertEqual(sut.filteredItems.map(\.document.name), ["Library"])

        sut.scopeFilter = .favorites
        XCTAssertEqual(sut.filteredItems.map(\.document.name), ["Mine"])

        sut.scopeFilter = .all
        XCTAssertEqual(sut.filteredItems.count, 2)
    }

    // MARK: - Create

    func testCreatePresetSavesOnlySelectedFieldsToTheChosenScope() async throws {
        let mine = RecordingPresetRepository()
        let sut = PresetLibraryViewModel(myRepository: mine)
        var adjustments = PhotoAdjustments.neutral
        adjustments.exposure = 1.5
        adjustments.contrast = 20

        await sut.createPreset(
            name: "New Preset",
            groupPath: [],
            isFavorite: false,
            scope: .mine,
            selectedFields: [.basicExposure],
            from: adjustments
        )

        let saved = await mine.savedDocuments
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.patch.basic?.exposure, 1.5)
        XCTAssertNil(saved.first?.patch.basic?.contrast, "Only the selected field should be included")
    }

    /// Round 2, finding #4: `CreatePresetSheet` used to dismiss itself
    /// unconditionally right after this call, regardless of outcome, which
    /// is what actually made `alert` unreachable on a failure -- setting
    /// `alert` alone was never enough. This is the exact `Bool` the sheet
    /// now branches on to decide whether to stay open, so it's the
    /// presentation-relevant contract to test, not just "is `alert`
    /// non-nil".
    func testCreatePresetReturnsTrueOnSuccessSoTheSheetKnowsItMayDismiss() async throws {
        let mine = RecordingPresetRepository()
        let sut = PresetLibraryViewModel(myRepository: mine)

        let saved = await sut.createPreset(
            name: "New Preset",
            groupPath: [],
            isFavorite: false,
            scope: .mine,
            selectedFields: [.basicExposure],
            from: .neutral
        )

        XCTAssertTrue(saved)
        XCTAssertNil(sut.alert)
    }

    func testCreatePresetReturnsFalseOnFailureSoTheSheetKnowsToStayOpen() async throws {
        let sut = PresetLibraryViewModel(myRepository: RecordingPresetRepository()) // no libraryRepository

        let saved = await sut.createPreset(
            name: "New Preset",
            groupPath: [],
            isFavorite: false,
            scope: .library,
            selectedFields: [.basicExposure],
            from: .neutral
        )

        XCTAssertFalse(saved, "A save failure must tell the caller not to dismiss -- that's the only way `alert` can ever be seen")
        XCTAssertNotNil(sut.alert)
    }

    // MARK: - Favorite / delete / copy

    func testToggleFavoriteFlipsAndPersists() async throws {
        let document = makeDocument(isFavorite: false)
        let mine = RecordingPresetRepository(seed: [document])
        let sut = PresetLibraryViewModel(myRepository: mine)
        await sut.load()

        await sut.toggleFavorite(PresetListItem(document: document, scope: .mine))

        let saved = await mine.savedDocuments
        XCTAssertEqual(saved.last?.isFavorite, true)
    }

    /// Finding #6: `toggleFavorite` used to swallow a failed save with
    /// `try?`, unlike rename/delete/copy/createPreset in this same class,
    /// which all populate `alert` on error.
    func testToggleFavoriteShowsAnAlertWhenSaveFails() async throws {
        let document = makeDocument(isFavorite: false)
        let mine = RecordingPresetRepository(seed: [document])
        await mine.setSaveError(PresetError.readOnlyDestination("test"))
        let sut = PresetLibraryViewModel(myRepository: mine)
        await sut.load()
        XCTAssertNil(sut.alert)

        await sut.toggleFavorite(PresetListItem(document: document, scope: .mine))

        XCTAssertNotNil(sut.alert, "A failed favorite save must not be silently swallowed")
        let saved = await mine.savedDocuments
        XCTAssertTrue(saved.isEmpty, "The failed save must not be recorded as if it had succeeded")
    }

    func testDeleteRemovesFromTheOwningRepository() async throws {
        let document = makeDocument()
        let mine = RecordingPresetRepository(seed: [document])
        let sut = PresetLibraryViewModel(myRepository: mine)
        await sut.load()

        await sut.delete(PresetListItem(document: document, scope: .mine))

        let deleted = await mine.deletedIDs
        XCTAssertEqual(deleted, [document.id])
    }

    func testCopyWritesToTheOtherScopeWithoutDeletingTheSource() async throws {
        let document = makeDocument()
        let mine = RecordingPresetRepository(seed: [document])
        let library = RecordingPresetRepository()
        let sut = PresetLibraryViewModel(myRepository: mine, libraryRepository: library)

        await sut.copy(PresetListItem(document: document, scope: .mine), to: .library)

        let librarySaved = await library.savedDocuments
        XCTAssertEqual(librarySaved.map(\.id), [document.id])
        let mineDeleted = await mine.deletedIDs
        XCTAssertTrue(mineDeleted.isEmpty, "Copy must not remove the source")
    }

    // MARK: - Import: preview-first, cancel writes nothing (spec §9.3)

    func testCancelledImportWritesNothing() async throws {
        let fixture = try writeFixtureXMP()
        let mine = RecordingPresetRepository()
        let sut = PresetLibraryViewModel(myRepository: mine)

        await sut.previewImport([fixture])
        XCTAssertEqual(sut.importState, .preview)

        sut.cancelImport()
        XCTAssertEqual(sut.importState, .idle)
        XCTAssertTrue(sut.importItems.isEmpty)

        let saved = await mine.savedDocuments
        XCTAssertEqual(saved, [], "Cancelling an import must write nothing")
    }

    func testConfirmImportSavesToTheChosenScope() async throws {
        let fixture = try writeFixtureXMP()
        let mine = RecordingPresetRepository()
        let sut = PresetLibraryViewModel(myRepository: mine)

        await sut.previewImport([fixture])
        await sut.confirmImport(scope: .mine)

        let saved = await mine.savedDocuments
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.patch.basic?.exposure, 0.5)
        XCTAssertEqual(sut.importState, .idle)
        XCTAssertTrue(sut.importItems.isEmpty)
    }

    func testDeselectingAnApproximateFieldExcludesItFromTheSavedPatch() async throws {
        let fixture = try writeFixtureXMP()
        let mine = RecordingPresetRepository()
        let sut = PresetLibraryViewModel(myRepository: mine)

        await sut.previewImport([fixture])
        let item = try XCTUnwrap(sut.importItems.first)
        XCTAssertTrue(item.preview.approximateFields.contains(.basicContrast))

        sut.setApproximateField(.basicContrast, included: false, for: item.id)
        await sut.confirmImport(scope: .mine)

        let saved = await mine.savedDocuments
        XCTAssertEqual(saved.first?.patch.basic?.exposure, 0.5, "Native field must still be saved")
        XCTAssertNil(saved.first?.patch.basic?.contrast, "Deselected approximate field must be excluded")
    }

    func testDeselectingANativeFieldIsRejected() async throws {
        let fixture = try writeFixtureXMP()
        let mine = RecordingPresetRepository()
        let sut = PresetLibraryViewModel(myRepository: mine)

        await sut.previewImport([fixture])
        let item = try XCTUnwrap(sut.importItems.first)

        sut.setApproximateField(.basicExposure, included: false, for: item.id) // native, not approximate
        await sut.confirmImport(scope: .mine)

        let saved = await mine.savedDocuments
        XCTAssertEqual(saved.first?.patch.basic?.exposure, 0.5, "A native field can't be deselected")
    }

    // MARK: - Finding #5: choosing an unavailable scope must never be a silent no-op
    //
    // `ImportPresetSheet`/`CreatePresetSheet` are fixed separately (the
    // "This Library" segment no longer exists in the picker at all when
    // `hasLibraryScope` is false, and an `.onChange` resets a stale
    // selection back to `.mine`), which SwiftUI view code isn't unit-tested
    // in this codebase. These pin down the ViewModel's own second line of
    // defense: even if `scope` somehow still points at a repository that
    // doesn't exist, none of these silently do nothing.

    func testCreatePresetShowsAnAlertWhenTheChosenScopeHasNoRepository() async throws {
        let sut = PresetLibraryViewModel(myRepository: RecordingPresetRepository()) // no libraryRepository
        XCTAssertNil(sut.alert)

        await sut.createPreset(
            name: "New Preset",
            groupPath: [],
            isFavorite: false,
            scope: .library,
            selectedFields: [.basicExposure],
            from: .neutral
        )

        XCTAssertNotNil(sut.alert, "Choosing an unavailable scope must not be a silent no-op")
    }

    func testCopyShowsAnAlertWhenTheDestinationScopeHasNoRepository() async throws {
        let document = makeDocument()
        let mine = RecordingPresetRepository(seed: [document])
        let sut = PresetLibraryViewModel(myRepository: mine) // no libraryRepository
        XCTAssertNil(sut.alert)

        await sut.copy(PresetListItem(document: document, scope: .mine), to: .library)

        XCTAssertNotNil(sut.alert, "Choosing an unavailable destination scope must not be a silent no-op")
    }

    func testConfirmImportEntersAFailedStateWhenTheChosenScopeHasNoRepository() async throws {
        let fixture = try writeFixtureXMP()
        let sut = PresetLibraryViewModel(myRepository: RecordingPresetRepository()) // no libraryRepository
        await sut.previewImport([fixture])
        XCTAssertEqual(sut.importState, .preview)

        await sut.confirmImport(scope: .library)

        guard case .failed = sut.importState else {
            return XCTFail("Expected .failed, got \(sut.importState) -- choosing an unavailable scope must not silently do nothing")
        }
    }

    // MARK: - Built-in scope (Phase 3 Task 3.1: built-in vs user precedence)

    func testLoadIncludesBuiltInPresetsAlongsideMineAndLibrary() async throws {
        let builtIn = BuiltInPresetRepository(documents: [makeDocument(name: "Built-In One")])
        let mine = RecordingPresetRepository(seed: [makeDocument(name: "Mine")])
        let sut = PresetLibraryViewModel(myRepository: mine, builtInRepository: builtIn)

        await sut.load()

        XCTAssertEqual(Set(sut.items.map(\.document.name)), ["Built-In One", "Mine"])
        XCTAssertEqual(sut.items.first { $0.document.name == "Built-In One" }?.scope, .builtIn)
    }

    /// "Precedence" here means *coexistence*: a name collision across scopes
    /// must not merge, shadow, or drop either preset -- they're distinguished
    /// by scope, not by name uniqueness.
    func testBuiltInAndAUserPresetCanShareTheSameNameWithoutConflict() async throws {
        let sharedName = "Same Name"
        let builtIn = BuiltInPresetRepository(documents: [
            PresetDocument(name: sharedName, patch: AdjustmentPatch(basic: BasicAdjustmentPatch(exposure: 1)))
        ])
        let mine = RecordingPresetRepository(seed: [makeDocument(name: sharedName)])
        let sut = PresetLibraryViewModel(myRepository: mine, builtInRepository: builtIn)

        await sut.load()

        XCTAssertEqual(
            sut.items.filter { $0.document.name == sharedName }.count, 2,
            "a name collision across scopes must not merge or drop either preset"
        )
    }

    func testScopeFilterCanIsolateBuiltInPresets() async throws {
        let builtIn = BuiltInPresetRepository(documents: [makeDocument(name: "Built-In")])
        let mine = RecordingPresetRepository(seed: [makeDocument(name: "Mine")])
        let sut = PresetLibraryViewModel(myRepository: mine, builtInRepository: builtIn)
        await sut.load()

        sut.scopeFilter = .scope(.builtIn)

        XCTAssertEqual(sut.filteredItems.map(\.document.name), ["Built-In"])
    }

    func testTogglingFavoriteOnABuiltInPresetFailsWithoutCorruptingWhatsDisplayed() async throws {
        let builtIn = BuiltInPresetRepository()
        let sut = PresetLibraryViewModel(builtInRepository: builtIn)
        await sut.load()
        let item = try XCTUnwrap(sut.items.first)

        await sut.toggleFavorite(item)

        XCTAssertNotNil(sut.alert)
        let reloaded = try XCTUnwrap(sut.items.first { $0.id == item.id })
        XCTAssertEqual(
            reloaded.document.isFavorite, item.document.isFavorite,
            "a rejected write must not silently mutate what's displayed"
        )
    }

    func testDeletingABuiltInPresetFailsAndLeavesItInTheList() async throws {
        let builtIn = BuiltInPresetRepository()
        let sut = PresetLibraryViewModel(builtInRepository: builtIn)
        await sut.load()
        let item = try XCTUnwrap(sut.items.first)
        let countBefore = sut.items.count

        await sut.delete(item)

        XCTAssertNotNil(sut.alert)
        XCTAssertEqual(sut.items.count, countBefore, "a rejected delete must not remove the preset from what's displayed")
    }

    func testCopyingABuiltInPresetToMinePersistsItThere() async throws {
        let builtIn = BuiltInPresetRepository()
        let mine = RecordingPresetRepository()
        let sut = PresetLibraryViewModel(myRepository: mine, builtInRepository: builtIn)
        await sut.load()
        let item = try XCTUnwrap(sut.items.first)

        await sut.copy(item, to: .mine)

        let savedNames = await mine.savedDocuments.map(\.name)
        XCTAssertTrue(savedNames.contains(item.document.name))
    }

    /// Independent-review finding (2026-09-03): `BuiltInPresetRepository`'s
    /// documents carry fixed UUIDs that are never file-backed anywhere --
    /// forwarding a built-in preset's own `id` into a real, file-backed
    /// scope on copy would give the still-present `.builtIn` row and the
    /// newly-copied `.mine` row the same `PresetListItem.id` (SwiftUI
    /// `Identifiable` collision, since `id` is just `document.id`,
    /// unqualified by scope), permanently, on disk. Copying a built-in
    /// preset must mint a brand-new identity, the same way `.xmp`/`.lhpreset`
    /// import already does for the same underlying reason -- it must never
    /// reuse the source's own id.
    func testCopyingABuiltInPresetMintsAFreshIdentityRatherThanReusingTheBuiltInsUUID() async throws {
        let builtIn = BuiltInPresetRepository()
        let mine = RecordingPresetRepository()
        let sut = PresetLibraryViewModel(myRepository: mine, builtInRepository: builtIn)
        await sut.load()
        let item = try XCTUnwrap(sut.items.first { $0.scope == .builtIn })

        await sut.copy(item, to: .mine)

        let savedDocuments = await mine.savedDocuments
        let saved = try XCTUnwrap(savedDocuments.first)
        XCTAssertNotEqual(saved.id, item.document.id, "copying a built-in preset must never reuse its fixed, permanently-built-in UUID")
    }

    /// A copy between the two *real*, file-backed scopes is a different
    /// situation -- `presetDocumentsAreCanonicallyEqual`/`.keepBoth`'s own
    /// duplicate detection at the repository layer depends on identity
    /// staying stable across a "My Presets" <-> "This Library" copy, so this
    /// pins that the built-in-only fix above does not regress that existing,
    /// already-tested behavior (`testCopyWritesToTheOtherScopeWithoutDeletingTheSource`).
    func testCopyingABetweenMineAndLibraryPreservesIdentity() async throws {
        let document = makeDocument()
        let mine = RecordingPresetRepository(seed: [document])
        let library = RecordingPresetRepository()
        let sut = PresetLibraryViewModel(myRepository: mine, libraryRepository: library)

        await sut.copy(PresetListItem(document: document, scope: .mine), to: .library)

        let librarySaved = await library.savedDocuments
        XCTAssertEqual(librarySaved.map(\.id), [document.id])
    }

    // MARK: - Edit an existing preset / sparse patch removal (Phase 3 Task 3.1)

    func testUpdatePresetRemovesUncheckedFieldsFromThePatch() async throws {
        let original = PresetDocument(
            name: "Original",
            patch: AdjustmentPatch(basic: BasicAdjustmentPatch(exposure: 1.0, contrast: 20))
        )
        let mine = RecordingPresetRepository(seed: [original])
        // Empty built-in scope so `sut.items.first` is unambiguously the
        // one preset this test actually seeded.
        let sut = PresetLibraryViewModel(myRepository: mine, builtInRepository: BuiltInPresetRepository(documents: []))
        await sut.load()
        let item = try XCTUnwrap(sut.items.first)

        let saved = await sut.updatePreset(
            item, name: original.name, groupPath: [], isFavorite: false,
            keptFields: [.basicExposure]
        )

        XCTAssertTrue(saved)
        let savedDocuments = await mine.savedDocuments
        let updated = try XCTUnwrap(savedDocuments.last)
        XCTAssertTrue(updated.patch.contains(.basicExposure))
        XCTAssertFalse(
            updated.patch.contains(.basicContrast),
            "an unchecked field must actually disappear from the patch, not just read as its default value"
        )
    }

    func testUpdatePresetKeepsTheSameIdentityAndCreationDate() async throws {
        let original = PresetDocument(
            name: "Original",
            createdAt: Date(timeIntervalSince1970: 1_000),
            patch: AdjustmentPatch(basic: BasicAdjustmentPatch(exposure: 1.0))
        )
        let mine = RecordingPresetRepository(seed: [original])
        // Empty built-in scope so `sut.items.first` is unambiguously the
        // one preset this test actually seeded.
        let sut = PresetLibraryViewModel(myRepository: mine, builtInRepository: BuiltInPresetRepository(documents: []))
        await sut.load()
        let item = try XCTUnwrap(sut.items.first)

        _ = await sut.updatePreset(item, name: "Renamed", groupPath: [], isFavorite: true, keptFields: [.basicExposure])

        let savedDocuments = await mine.savedDocuments
        let updated = try XCTUnwrap(savedDocuments.last)
        XCTAssertEqual(updated.id, original.id, "editing a preset must never mint a new identity")
        XCTAssertEqual(updated.createdAt, original.createdAt)
        XCTAssertEqual(updated.name, "Renamed")
        XCTAssertTrue(updated.isFavorite)
    }

    func testUpdatePresetOnABuiltInPresetIsRejected() async throws {
        let builtIn = BuiltInPresetRepository()
        let sut = PresetLibraryViewModel(builtInRepository: builtIn)
        await sut.load()
        let item = try XCTUnwrap(sut.items.first)

        let saved = await sut.updatePreset(item, name: item.document.name, groupPath: [], isFavorite: false, keptFields: [])

        XCTAssertFalse(saved)
        XCTAssertNotNil(sut.alert)
    }

    func testUpdatePresetWithNoRepositoryForScopeFails() async throws {
        let original = makeDocument()
        let sut = PresetLibraryViewModel() // no myRepository attached
        let item = PresetListItem(document: original, scope: .mine)

        let saved = await sut.updatePreset(item, name: original.name, groupPath: [], isFavorite: false, keptFields: [])

        XCTAssertFalse(saved)
        XCTAssertNotNil(sut.alert)
    }

    // MARK: - Backup/restore and .lhpreset import (Phase 3 Task 3.2)

    private func writeFixtureLHPreset(document: PresetDocument, name: String = "Fixture") throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("\(name).lhpreset")
        try SidecarCoding.encode(document).write(to: url)
        return url
    }

    func testExportBackupProducesAnArchiveContainingExactlyThatScopesDocuments() async throws {
        let mine = RecordingPresetRepository(seed: [makeDocument(name: "A"), makeDocument(name: "B")])
        let library = RecordingPresetRepository(seed: [makeDocument(name: "Library Only")])
        let sut = PresetLibraryViewModel(myRepository: mine, libraryRepository: library)

        let data = try await sut.exportBackup(scope: .mine)
        let archive = try PresetBackupCoding.decode(data)

        XCTAssertEqual(Set(archive.documents.map(\.name)), ["A", "B"])
    }

    func testExportBackupThrowsWhenTheScopesRepositoryIsUnavailable() async throws {
        let sut = PresetLibraryViewModel(myRepository: RecordingPresetRepository()) // no libraryRepository
        do {
            _ = try await sut.exportBackup(scope: .library)
            XCTFail("Expected exportBackup to throw for an unavailable scope")
        } catch {
            // Expected -- no repository to list from.
        }
    }

    func testRestoreBackupAppliesEveryDocumentAndReloadsItems() async throws {
        let mine = RecordingPresetRepository()
        let sut = PresetLibraryViewModel(myRepository: mine, builtInRepository: BuiltInPresetRepository(documents: []))
        let archive = PresetBackupArchive(documents: [makeDocument(name: "Restored A"), makeDocument(name: "Restored B")])
        let data = try PresetBackupCoding.encode(archive)

        let summary = await sut.restoreBackup(data, into: .mine, conflict: .replace)

        XCTAssertEqual(summary?.created, 2)
        let saved = await mine.savedDocuments
        XCTAssertEqual(Set(saved.map(\.name)), ["Restored A", "Restored B"])
        XCTAssertEqual(sut.items.count, 2, "restoreBackup must reload items so the browser reflects what was restored")
    }

    func testRestoringABackupPresentsTheCompletionSummaryThroughTheViewModelAlert() async throws {
        let mine = RecordingPresetRepository()
        let sut = PresetLibraryViewModel(myRepository: mine, builtInRepository: BuiltInPresetRepository(documents: []))
        let archive = PresetBackupArchive(documents: [makeDocument(name: "Restored A")])
        let data = try PresetBackupCoding.encode(archive)

        let summary = await sut.restoreBackupAndPresentSummary(data, into: .mine, conflict: .keepBoth)

        XCTAssertEqual(summary?.created, 1)
        let alert = try XCTUnwrap(sut.alert, "A completed restore must present a visible summary, not only reload the list")
        XCTAssertEqual(alert.title, L10n.t("Restore complete"))
        XCTAssertTrue(alert.message.contains("1 \(L10n.t("added"))"))
    }

    func testRestoreBackupWithMalformedDataSetsAlertAndReturnsNil() async throws {
        let sut = PresetLibraryViewModel(myRepository: RecordingPresetRepository())
        XCTAssertNil(sut.alert)

        let summary = await sut.restoreBackup(Data("not an archive".utf8), into: .mine, conflict: .replace)

        XCTAssertNil(summary)
        XCTAssertNotNil(sut.alert)
    }

    func testRestoreBackupIntoAnUnavailableScopeSetsAlertAndReturnsNil() async throws {
        let sut = PresetLibraryViewModel(myRepository: RecordingPresetRepository()) // no libraryRepository
        let archive = PresetBackupArchive(documents: [makeDocument()])
        let data = try PresetBackupCoding.encode(archive)

        let summary = await sut.restoreBackup(data, into: .library, conflict: .replace)

        XCTAssertNil(summary)
        XCTAssertNotNil(sut.alert)
    }

    func testPreviewImportAcceptsALhpresetFileAndProposesItsExactPatchAsAllNativeFields() async throws {
        let document = makeDocument(name: "Native Fixture")
        let fixture = try writeFixtureLHPreset(document: document)
        let sut = PresetLibraryViewModel(myRepository: RecordingPresetRepository())

        await sut.previewImport([fixture])

        XCTAssertEqual(sut.importState, .preview)
        let item = try XCTUnwrap(sut.importItems.first)
        XCTAssertEqual(item.preview.proposedPreset.name, "Native Fixture")
        XCTAssertEqual(item.preview.proposedPreset.patch, document.patch)
        XCTAssertEqual(Set(item.preview.nativeFields), [.basicExposure])
        XCTAssertTrue(item.preview.approximateFields.isEmpty)
        XCTAssertTrue(item.preview.preservedProperties.isEmpty)
    }

    /// Independent-review finding (2026-09-03): a `.lhpreset` file that was
    /// itself originally imported from Adobe XMP (so it carries `source:
    /// .adobeXMP` and an `xmpEnvelope` preserving the full original packet,
    /// unmapped properties included) must not silently become a plain
    /// native preset on re-import -- that would both drop the "Imported"
    /// source badge (Task 3.1) and, if later re-exported to `.xmp`, fall
    /// back to a blank envelope and permanently lose everything
    /// `xmpEnvelope` was preserving (exactly what Task 3.2's own "preserve
    /// unknown XMP fields" work exists to prevent).
    func testPreviewImportOfALhpresetFilePreservesItsSourceAndXMPEnvelope() async throws {
        let envelope = XMPEnvelope(originalPacketUTF8: "<xmp>unmapped-content</xmp>", documentKind: .developPreset)
        let document = PresetDocument(
            name: "Reimported",
            source: .adobeXMP(tool: "Lightroom", version: "15.4"),
            patch: AdjustmentPatch(basic: BasicAdjustmentPatch(exposure: 1.0)),
            xmpEnvelope: envelope
        )
        let fixture = try writeFixtureLHPreset(document: document)
        let sut = PresetLibraryViewModel(myRepository: RecordingPresetRepository())

        await sut.previewImport([fixture])

        let item = try XCTUnwrap(sut.importItems.first)
        XCTAssertEqual(item.preview.proposedPreset.source, document.source)
        XCTAssertEqual(item.preview.proposedPreset.xmpEnvelope, envelope)
    }

    func testPreviewImportOfALhpresetFileMintsAFreshIdentityRatherThanReusingTheFiles() async throws {
        let document = makeDocument()
        let fixture = try writeFixtureLHPreset(document: document)
        let sut = PresetLibraryViewModel(myRepository: RecordingPresetRepository())

        await sut.previewImport([fixture])

        let item = try XCTUnwrap(sut.importItems.first)
        XCTAssertNotEqual(item.preview.proposedPreset.id, document.id, "importing must never silently adopt the source file's own identity")
    }

    func testPreviewImportOfACorruptLhpresetFileCountsAsAFailureLikeACorruptXMPFile() async throws {
        let url = temporaryDirectory.appendingPathComponent("Corrupt.lhpreset")
        try Data("not json".utf8).write(to: url)
        let sut = PresetLibraryViewModel(myRepository: RecordingPresetRepository())

        await sut.previewImport([url])

        guard case .failed = sut.importState else {
            return XCTFail("Expected .failed, got \(sut.importState)")
        }
    }
}
