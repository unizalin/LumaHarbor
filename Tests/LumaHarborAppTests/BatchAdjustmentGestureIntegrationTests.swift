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

    /// Independent review of Task 3.4's own independent-review fix round,
    /// Finding 4: a partial failure inside `undo(_:)` must not discard the
    /// only record of what's still safe to revert. Keeping
    /// `lastBatchTransaction` around lets "Undo Batch Sync" be chosen again
    /// once the underlying problem clears, retrying just the target that
    /// failed -- the target that already reverted successfully must not be
    /// touched a second time.
    func testUndoLastBatchTransactionKeepsTheTransactionForRetryAfterAPartialFailure() async throws {
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW", "DSC0003.ARW"])
        let log = ServiceCallLog()
        let store = AdjustmentStore()
        actor FailureSwitch {
            private var failingID: PhotoID?
            func fail(for id: PhotoID) { failingID = id }
            func clear() { failingID = nil }
            func shouldFail(_ id: PhotoID) -> Bool { failingID == id }
        }
        struct SimulatedWriteFailure: Error {}
        let failureSwitch = FailureSwitch()
        let services = try makeServices(
            loadAdjustments: { photo in await store.get(photo.id) },
            saveAdjustments: { adjustments, photo in
                guard await !failureSwitch.shouldFail(photo.id) else { throw SimulatedWriteFailure() }
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
        await waitUntilAppCondition("both targets to receive the synced save") {
            await log.saveCount >= 2
        }

        // Target B's own revert write will fail this first attempt.
        await failureSwitch.fail(for: targetB.id)
        let firstSummary = await model.undoLastBatchTransaction()

        XCTAssertEqual(firstSummary?.affected, 1, "target A must still revert normally")
        XCTAssertEqual(firstSummary?.failed, 1, "target B's revert write failed")
        XCTAssertNotNil(model.lastBatchTransaction, "a partial failure must stay retryable, not be discarded")
        let afterFirstA = await store.get(targetA.id)
        XCTAssertEqual(afterFirstA.exposure, 0, "A already reverted")
        let afterFirstB = await store.get(targetB.id)
        XCTAssertEqual(afterFirstB.exposure, 1.5, "B's failed revert must leave it exactly as the original sync left it")

        // The underlying problem clears; the user retries.
        await failureSwitch.clear()
        let secondSummary = await model.undoLastBatchTransaction()

        XCTAssertEqual(secondSummary?.affected, 1, "target B is now revertible")
        XCTAssertEqual(secondSummary?.skipped, 1, "target A was already reverted on the first attempt -- its synced field no longer matches what the sync wrote, so the retry must not touch it again")
        XCTAssertNil(model.lastBatchTransaction, "a fully-clean retry finally consumes the transaction")
        let afterSecondB = await store.get(targetB.id)
        XCTAssertEqual(afterSecondB.exposure, 0, "B must now be reverted too")
    }

    /// Independent review of Task 3.4's own independent-review fix round,
    /// Finding 4: a second call to `undoLastBatchTransaction()` made while
    /// the first is still running (a double-click on "Undo Batch Sync"
    /// before the menu has re-disabled itself) must be ignored outright,
    /// not started as its own, redundant revert of the same transaction.
    func testUndoLastBatchTransactionIgnoresASecondCallWhileTheFirstIsStillRunning() async throws {
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW"])
        let log = ServiceCallLog()
        let store = AdjustmentStore()
        actor Gate {
            private var armed = false
            private var hasArrived = false
            private var arrivedContinuation: CheckedContinuation<Void, Never>?
            private var isReleased = false
            private var releaseContinuation: CheckedContinuation<Void, Never>?

            func arm() { armed = true }

            /// A no-op before `arm()` -- lets the setup sync's own save
            /// through untouched; only pauses once armed, right before the
            /// two concurrent undo calls this test drives.
            func passThroughOrPause() async {
                guard armed else { return }
                hasArrived = true
                arrivedContinuation?.resume()
                arrivedContinuation = nil
                guard !isReleased else { return }
                await withCheckedContinuation { releaseContinuation = $0 }
            }

            func waitForArrival() async {
                guard !hasArrived else { return }
                await withCheckedContinuation { arrivedContinuation = $0 }
            }

            func release() {
                isReleased = true
                releaseContinuation?.resume()
                releaseContinuation = nil
            }
        }
        let gate = Gate()
        let services = try makeServices(
            loadAdjustments: { photo in await store.get(photo.id) },
            saveAdjustments: { adjustments, photo in
                await gate.passThroughOrPause()
                await store.set(photo.id, adjustments)
                await log.recordSave(photo.id, adjustments)
            }
        )
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        let source = model.photos[0]
        let target = model.photos[1]

        model.requestSelectPhoto(source.id)
        await waitUntilAppCondition("the source photo to open") {
            await MainActor.run { model.editor.photo?.id == source.id }
        }
        model.toggleMultiSelect(target.id)

        model.editor.beginAdjustmentGesture()
        model.editor.setAdjustment(.exposure, to: 1.5)
        model.editor.endAdjustmentGesture()
        await waitUntilAppCondition("the target to receive the synced save") {
            await log.saveCount >= 1
        }

        await gate.arm()
        async let firstSummary = model.undoLastBatchTransaction()
        await gate.waitForArrival() // the first call is now paused inside its own revert save.

        let secondSummary = await model.undoLastBatchTransaction()
        XCTAssertNil(secondSummary, "a second call while the first is still running must be ignored, not started as its own revert")

        await gate.release()
        let firstResult = await firstSummary
        XCTAssertEqual(firstResult?.affected, 1, "the one call that was actually allowed to run must still succeed")
        let reverted = await store.get(target.id)
        XCTAssertEqual(reverted.exposure, 0)
    }

    /// Independent review of the Task 3.4 follow-up round itself, Finding 1:
    /// `undoLastBatchTransaction()` reads `lastBatchTransaction` into a
    /// local, awaits `batchSyncService.undo(_:)`, then writes back to
    /// `lastBatchTransaction` based on the outcome -- with no check that
    /// `lastBatchTransaction` is still the *same* transaction it started
    /// with. A brand-new, completely unrelated batch sync that lands while
    /// the first undo is still in flight replaces `lastBatchTransaction`
    /// with its own transaction; the first undo's completion must not then
    /// stomp on it.
    func testUndoLastBatchTransactionDoesNotClobberAnUnrelatedTransactionThatLandsWhileItIsInFlight() async throws {
        try seedPhotos(["DSC0001.ARW", "DSC0002.ARW", "DSC0003.ARW", "DSC0004.ARW"])
        let log = ServiceCallLog()
        let store = AdjustmentStore()
        actor Gate {
            private var armedFor: PhotoID?
            private var hasArrived = false
            private var arrivedContinuation: CheckedContinuation<Void, Never>?
            private var isReleased = false
            private var releaseContinuation: CheckedContinuation<Void, Never>?

            func arm(for id: PhotoID) { armedFor = id }

            /// A no-op for any photo other than the armed one -- lets every
            /// other save (the setup syncs, T2's own sync) through
            /// untouched.
            func passThroughOrPause(_ id: PhotoID) async {
                guard armedFor == id else { return }
                hasArrived = true
                arrivedContinuation?.resume()
                arrivedContinuation = nil
                guard !isReleased else { return }
                await withCheckedContinuation { releaseContinuation = $0 }
            }

            func waitForArrival() async {
                guard !hasArrived else { return }
                await withCheckedContinuation { arrivedContinuation = $0 }
            }

            func release() {
                isReleased = true
                releaseContinuation?.resume()
                releaseContinuation = nil
            }
        }
        let gate = Gate()
        let services = try makeServices(
            loadAdjustments: { photo in await store.get(photo.id) },
            saveAdjustments: { adjustments, photo in
                await gate.passThroughOrPause(photo.id)
                await store.set(photo.id, adjustments)
                await log.recordSave(photo.id, adjustments)
            }
        )
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        let sourceA = model.photos[0]
        let targetB = model.photos[1]
        let sourceC = model.photos[2]
        let targetD = model.photos[3]

        // T1: A (source) -> B, an ordinary batch sync.
        model.requestSelectPhoto(sourceA.id)
        await waitUntilAppCondition("A to open") {
            await MainActor.run { model.editor.photo?.id == sourceA.id }
        }
        model.toggleMultiSelect(targetB.id)
        model.editor.beginAdjustmentGesture()
        model.editor.setAdjustment(.exposure, to: 1.5)
        model.editor.endAdjustmentGesture()
        await waitUntilAppCondition("B to receive T1's synced save") {
            await log.saveCount >= 1
        }
        let t1ID = try XCTUnwrap(model.lastBatchTransaction?.id)

        // Start undoing T1, but pause it right as it's about to write B's
        // reverted value back.
        await gate.arm(for: targetB.id)
        async let firstUndoSummary = model.undoLastBatchTransaction()
        await gate.waitForArrival() // T1's own undo is now paused mid-write.

        // While T1's undo is still in flight, an entirely unrelated batch
        // sync (T2: C -> D) completes normally. Waits on D's own save
        // specifically -- not a raw save count -- since switching away from
        // A also flushes A's own pending autosave through the same log,
        // which would otherwise satisfy a plain count too early, before D
        // (and therefore T2's own `endBatchGesture`) has actually landed.
        model.requestSelectPhoto(sourceC.id)
        await waitUntilAppCondition("C to open") {
            await MainActor.run { model.editor.photo?.id == sourceC.id }
        }
        model.toggleMultiSelect(targetD.id)
        model.editor.beginAdjustmentGesture()
        model.editor.setAdjustment(.contrast, to: 20)
        model.editor.endAdjustmentGesture()
        await waitUntilAppCondition("D to receive T2's synced save") {
            await log.savedAdjustments.contains { $0.0 == targetD.id }
        }
        let t2ID = try XCTUnwrap(model.lastBatchTransaction?.id)
        XCTAssertNotEqual(t1ID, t2ID, "T2 must be its own, distinct transaction")

        // Now let T1's undo finish.
        await gate.release()
        let firstResult = await firstUndoSummary
        XCTAssertEqual(firstResult?.failed, 0, "T1's own undo must still succeed once released")

        XCTAssertEqual(
            model.lastBatchTransaction?.id, t2ID,
            "T1's undo completing after T2 landed must not clobber T2 -- it must still be the thing 'Undo Batch Sync' would revert next"
        )
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
