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

    /// Independent review of Task 3.3: a reset (context menu, double-click,
    /// or "Reset All") on one of the ten basic sliders is just as much an
    /// edit to that field as a drag is -- it must sync to a batch's other
    /// selected photos the same way, end to end through
    /// `LibraryViewModel`/`EditorSession`, not just at the `EditorSession`
    /// unit level.
    func testResettingASliderOnTheOpenPhotoSyncsTheResetToOtherSelectedPhotos() async throws {
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
        let source = model.photos[0]
        let targetA = model.photos[1]
        let targetB = model.photos[2]

        model.requestSelectPhoto(source.id)
        await waitUntilAppCondition("the source photo to open") {
            await MainActor.run { model.editor.photo?.id == source.id }
        }
        model.toggleMultiSelect(targetA.id)
        model.toggleMultiSelect(targetB.id)

        // A prior drag put exposure at 1.5 everywhere in the batch -- this
        // is the same setup `testDraggingASliderOnTheOpenPhotoSyncsOnlyThe
        // ChangedFieldToOtherSelectedPhotos` already proves works.
        model.editor.beginAdjustmentGesture()
        model.editor.setAdjustment(.exposure, to: 1.5)
        model.editor.endAdjustmentGesture()
        await waitUntilAppCondition("both targets to receive the initial synced save") {
            await log.saveCount >= 2
        }

        model.editor.resetAdjustment(.exposure)

        await waitUntilAppCondition("both targets to receive the reset sync") {
            await log.saveCount >= 4
        }

        let savedForA = await store.get(targetA.id)
        let savedForB = await store.get(targetB.id)
        XCTAssertEqual(savedForA.exposure, 0, "the reset must sync to target A, the same as a drag back to 0 would")
        XCTAssertEqual(savedForB.exposure, 0, "the reset must sync to target B, the same as a drag back to 0 would")
    }

    // MARK: - Task 3.4: compound batch undo

    /// End to end, through `LibraryViewModel`, not by calling
    /// `BatchAdjustmentSyncService.undo(_:)` directly (already exhaustively
    /// covered by `BatchAdjustmentSyncServiceTests`'s full-success/
    /// partial-failure/revert-write-failure cases) -- this proves the
    /// wiring: `lastBatchTransaction` is captured after a real sync,
    /// `undoLastBatchTransaction()` reverts every target's own sidecar, and
    /// the transaction is consumed so a second undo has nothing left to do.
    func testUndoLastBatchTransactionRevertsEveryTargetAndClearsTheTransaction() async throws {
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
        let source = model.photos[0]
        let targetA = model.photos[1]
        let targetB = model.photos[2]

        // targetA already has its own unrelated edit -- the undo must not
        // clobber it, same as the original sync doesn't.
        var targetAOwn = PhotoAdjustments.neutral
        targetAOwn.contrast = 20
        await store.set(targetA.id, targetAOwn)

        model.requestSelectPhoto(source.id)
        await waitUntilAppCondition("the source photo to open") {
            await MainActor.run { model.editor.photo?.id == source.id }
        }
        model.toggleMultiSelect(targetA.id)
        model.toggleMultiSelect(targetB.id)

        model.editor.beginAdjustmentGesture()
        model.editor.setAdjustment(.exposure, to: 1.5)
        model.editor.endAdjustmentGesture()
        await waitUntilAppCondition("both targets to receive the synced save") {
            await log.saveCount >= 2
        }
        XCTAssertNotNil(model.lastBatchTransaction, "a sync that actually changed something must be undoable")

        let summary = await model.undoLastBatchTransaction()

        XCTAssertEqual(summary?.affected, 2)
        XCTAssertEqual(summary?.failed, 0)
        XCTAssertEqual(summary?.skipped, 0)
        let revertedA = await store.get(targetA.id)
        let revertedB = await store.get(targetB.id)
        XCTAssertEqual(revertedA.exposure, 0, "target A's exposure must come back to what it was before the sync")
        XCTAssertEqual(revertedA.contrast, 20, "target A's own unrelated edit must survive the undo")
        XCTAssertEqual(revertedB.exposure, 0)
        XCTAssertNil(model.lastBatchTransaction, "a compound batch undo is one-shot -- it must consume the transaction")

        // A second undo has nothing left to revert.
        let secondSummary = await model.undoLastBatchTransaction()
        XCTAssertNil(secondSummary)
    }

    /// Independent review of Task 3.4: `lastBatchTransaction` is
    /// deliberately one-shot, not a stack (`CURRENT.md`'s own documented
    /// scope boundary) -- a second sync silently replaces the first as
    /// "the thing Undo Batch Sync will revert." This locks that exact
    /// behavior in as a real, tested contract rather than an unverified
    /// claim: undoing after two consecutive syncs must revert only the
    /// second one, leaving the first's own sync results on the targets
    /// untouched.
    func testUndoLastBatchTransactionOnlyRevertsTheMostRecentOfTwoConsecutiveSyncs() async throws {
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
        let source = model.photos[0]
        let targetA = model.photos[1]
        let targetB = model.photos[2]

        model.requestSelectPhoto(source.id)
        await waitUntilAppCondition("the source photo to open") {
            await MainActor.run { model.editor.photo?.id == source.id }
        }
        model.toggleMultiSelect(targetA.id)
        model.toggleMultiSelect(targetB.id)

        model.editor.beginAdjustmentGesture()
        model.editor.setAdjustment(.exposure, to: 1.5)
        model.editor.endAdjustmentGesture()
        await waitUntilAppCondition("the first sync to land on both targets") {
            await log.saveCount >= 2
        }

        model.editor.beginAdjustmentGesture()
        model.editor.setAdjustment(.contrast, to: 20)
        model.editor.endAdjustmentGesture()
        await waitUntilAppCondition("the second sync to land on both targets") {
            await log.saveCount >= 4
        }

        let summary = await model.undoLastBatchTransaction()

        XCTAssertEqual(summary?.affected, 2, "only the second sync's own targets are reverted")
        let revertedA = await store.get(targetA.id)
        let revertedB = await store.get(targetB.id)
        XCTAssertEqual(revertedA.contrast, 0, "the second sync (contrast) must be undone")
        XCTAssertEqual(revertedB.contrast, 0)
        XCTAssertEqual(revertedA.exposure, 1.5, "the first sync (exposure) is not this undo's transaction -- it must survive untouched")
        XCTAssertEqual(revertedB.exposure, 1.5)
    }

    func testUndoLastBatchTransactionWithNothingToUndoReturnsNil() async throws {
        try seedPhotos(["DSC0001.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)

        let summary = await model.undoLastBatchTransaction()

        XCTAssertNil(summary)
    }
}
