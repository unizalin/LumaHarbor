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

// MARK: - PresetLibraryViewModel

/// In-memory `PresetRepository` for view-model tests that shouldn't need real
/// file I/O -- only what confirms writes actually happened (or didn't).
actor RecordingPresetRepository: PresetRepository {
    private(set) var savedDocuments: [PresetDocument] = []
    private(set) var deletedIDs: [UUID] = []
    private var storage: [UUID: PresetDocument]

    init(seed: [PresetDocument] = []) {
        storage = Dictionary(uniqueKeysWithValues: seed.map { ($0.id, $0) })
    }

    func list() async throws -> [PresetDocument] { Array(storage.values) }
    func load(id: UUID) async throws -> PresetDocument? { storage[id] }

    func save(_ document: PresetDocument, conflict: PresetConflictResolution) async throws -> PresetStoreResult {
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
        let sut = PresetLibraryViewModel(myRepository: mine, libraryRepository: library)

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
        let sut = PresetLibraryViewModel(myRepository: mine, libraryRepository: library)
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
}
