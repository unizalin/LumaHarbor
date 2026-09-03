import Foundation
import XCTest
@testable import LumaHarborApp
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Phase 3 Task 3.3, end to end: multi-select in the grid, drag a slider on
/// the open photo, and confirm the *other* selected photos' own sidecars
/// receive exactly the changed field -- driven entirely through
/// `LibraryViewModel`/`EditorSession` the way a real drag would, not by
/// calling `BatchAdjustmentSyncService` directly (that's already covered by
/// `BatchAdjustmentSyncServiceTests` in `PhotoLibraryCoreTests`).
@MainActor
final class BatchAdjustmentGestureIntegrationTests: AppViewModelTestCase {
    private actor AdjustmentStore {
        private var values: [PhotoID: PhotoAdjustments] = [:]
        func set(_ id: PhotoID, _ value: PhotoAdjustments) { values[id] = value }
        func get(_ id: PhotoID) -> PhotoAdjustments { values[id] ?? .neutral }
    }

    func testDraggingASliderOnTheOpenPhotoSyncsOnlyTheChangedFieldToOtherSelectedPhotos() async throws {
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW", "DSC0003.ARW"])
        let log = ServiceCallLog()
        let store = AdjustmentStore()
        let services = try makeServices(
            loadAdjustments: { photo in await store.get(photo.id) },
            saveAdjustments: { adjustments, photo in
                await store.set(photo.id, adjustments)
                await log.recordSave(photo.id, adjustments)
            }
        )
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        XCTAssertEqual(model.photos.count, 3)
        let source = model.photos[0]
        let targetA = model.photos[1]
        let targetB = model.photos[2]

        // targetA already has its own unrelated edit -- the sync must not
        // clobber it.
        var targetAOwn = PhotoAdjustments.neutral
        targetAOwn.contrast = 20
        await store.set(targetA.id, targetAOwn)

        model.requestSelectPhoto(source.id)
        await waitUntilAppCondition("the source photo to open") {
            await MainActor.run { model.editor.photo?.id == source.id }
        }
        // Opening a fresh photo seeds selectedPhotoIDs to just itself --
        // cmd-clicking the other two afterward is what makes this a batch.
        model.toggleMultiSelect(targetA.id)
        model.toggleMultiSelect(targetB.id)
        XCTAssertEqual(model.selectedPhotoIDs, [source.id, targetA.id, targetB.id])

        model.editor.beginAdjustmentGesture()
        model.editor.setAdjustment(.exposure, to: 1.5)
        model.editor.endAdjustmentGesture()

        await waitUntilAppCondition("both targets to receive the synced save") {
            await log.saveCount >= 2
        }

        let savedForA = await store.get(targetA.id)
        let savedForB = await store.get(targetB.id)
        XCTAssertEqual(savedForA.exposure, 1.5, "the synced field must land on target A")
        XCTAssertEqual(savedForA.contrast, 20, "target A's own unrelated edit must survive the sync")
        XCTAssertEqual(savedForB.exposure, 1.5, "the synced field must land on target B")

        let savedIDs = Set(await log.savedAdjustments.map(\.0))
        XCTAssertFalse(savedIDs.contains(source.id), "the source photo saves through its own normal autosave path, not the batch sync's writes")
    }

    /// Without a genuine multi-selection (just the one open photo), a drag
    /// must never spuriously "sync to itself" or touch any other photo.
    func testDraggingWithNoOtherPhotosSelectedNeverTriggersABatchSync() async throws {
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW"])
        let log = ServiceCallLog()
        let services = try makeServices(
            saveAdjustments: { adjustments, photo in await log.recordSave(photo.id, adjustments) }
        )
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        let source = try XCTUnwrap(model.photos.first)
        let other = try XCTUnwrap(model.photos.last)

        model.requestSelectPhoto(source.id)
        await waitUntilAppCondition("the source photo to open") {
            await MainActor.run { model.editor.photo?.id == source.id }
        }

        model.editor.beginAdjustmentGesture()
        model.editor.setAdjustment(.exposure, to: 1.5)
        model.editor.endAdjustmentGesture()

        // Give any stray batch-sync Task a chance to (incorrectly) run.
        try? await Task.sleep(for: .milliseconds(150))

        let saved = await log.savedAdjustments
        XCTAssertFalse(saved.contains { $0.0 == other.id }, "a photo that was never multi-selected must never receive a sync write")
    }
}
