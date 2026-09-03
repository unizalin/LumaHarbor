import XCTest
@testable import PhotoLibraryCore
import PresetCore
import RawProcessingCore

/// Phase 3 Task 3.3: "Thumbnail multi-select and batch snapshot semantics."
/// `BatchAdjustmentSyncService` is the pure orchestration behind that --
/// snapshot the batch's target list and the source photo's own baseline at
/// gesture start (never re-reading live selection later), then at gesture
/// end sync only the fields that actually changed into every target's own
/// sidecar, preserving each target's own values for every other field.
final class BatchAdjustmentSyncServiceTests: XCTestCase {
    private actor Store {
        private var adjustments: [PhotoID: PhotoAdjustments]
        private(set) var saveCalls: [(PhotoID, PhotoAdjustments)] = []
        private var failingIDs: Set<PhotoID> = []

        init(_ seed: [PhotoID: PhotoAdjustments]) { adjustments = seed }

        func markFailing(_ id: PhotoID) { failingIDs.insert(id) }

        func load(_ id: PhotoID) throws -> PhotoAdjustments {
            if failingIDs.contains(id) { throw StoreError.loadFailed }
            return adjustments[id] ?? .neutral
        }

        func save(_ value: PhotoAdjustments, _ id: PhotoID) throws {
            if failingIDs.contains(id) { throw StoreError.saveFailed }
            adjustments[id] = value
            saveCalls.append((id, value))
        }

        func current(_ id: PhotoID) -> PhotoAdjustments { adjustments[id] ?? .neutral }
    }

    private enum StoreError: Error { case loadFailed, saveFailed }

    private func makeService(_ store: Store) -> BatchAdjustmentSyncService {
        BatchAdjustmentSyncService(
            loadAdjustments: { try await store.load($0) },
            saveAdjustments: { try await store.save($0, $1) }
        )
    }

    // MARK: - Gesture start snapshots selected targets

    func testBeginGestureSnapshotsTheTargetListExcludingTheSourcePhoto() async {
        let source = PhotoID()
        let targetA = PhotoID()
        let targetB = PhotoID()
        let service = makeService(Store([:]))

        // Selection sets sometimes include the currently-open photo itself
        // (it's still "selected" in the grid) -- the source is never its
        // own sync target.
        await service.beginGesture(sourcePhotoID: source, targetPhotoIDs: [source, targetA, targetB], sourceBaseline: .neutral)

        let hasGesture = await service.hasActiveGesture
        XCTAssertTrue(hasGesture)
        let targets = await service.currentTargetPhotoIDs
        XCTAssertEqual(Set(targets), [targetA, targetB])
    }

    func testCommitGestureWithNoActiveGestureReturnsNil() async {
        let service = makeService(Store([:]))
        let result = await service.commitGesture(sourceAfter: .neutral)
        XCTAssertNil(result)
    }

    func testCommitGestureClearsTheActiveGestureSoAnUnrelatedSecondCommitReturnsNil() async {
        let source = PhotoID()
        let target = PhotoID()
        let service = makeService(Store([target: .neutral]))
        var baseline = PhotoAdjustments.neutral
        baseline.exposure = 0
        var after = baseline
        after.exposure = 1

        await service.beginGesture(sourcePhotoID: source, targetPhotoIDs: [target], sourceBaseline: baseline)
        _ = await service.commitGesture(sourceAfter: after)

        let second = await service.commitGesture(sourceAfter: after)
        XCTAssertNil(second, "a commit with no preceding beginGesture must not silently re-sync the last gesture")
    }

    // MARK: - Selection changes mid-drag do not change the current batch target list

    func testSelectionChangesAfterBeginGestureDoNotChangeTheFrozenTargetList() async {
        let source = PhotoID()
        let targetA = PhotoID()
        let targetB = PhotoID()
        let targetC = PhotoID()
        let store = Store([targetA: .neutral, targetB: .neutral, targetC: .neutral])
        let service = makeService(store)
        let baseline = PhotoAdjustments.neutral
        var after = baseline
        after.exposure = 1

        var liveSelection: Set<PhotoID> = [targetA, targetB]
        await service.beginGesture(sourcePhotoID: source, targetPhotoIDs: liveSelection, sourceBaseline: baseline)
        // The user's selection in the grid changes mid-drag -- this must
        // never retarget an already-started gesture.
        liveSelection = [targetC]

        let transaction = await service.commitGesture(sourceAfter: after)

        XCTAssertEqual(Set(transaction?.targetPhotoIDs ?? []), [targetA, targetB])
        let saveCalls = await store.saveCalls
        XCTAssertEqual(Set(saveCalls.map(\.0)), [targetA, targetB], "only the targets frozen at begin-time may ever be written to")
    }

    func testConsecutiveGesturesEachUseTheirOwnFrozenTargetList() async {
        let source = PhotoID()
        let targetA = PhotoID()
        let targetB = PhotoID()
        let store = Store([targetA: .neutral, targetB: .neutral])
        let service = makeService(store)
        var first = PhotoAdjustments.neutral
        first.exposure = 1

        await service.beginGesture(sourcePhotoID: source, targetPhotoIDs: [targetA], sourceBaseline: .neutral)
        let firstTransaction = await service.commitGesture(sourceAfter: first)
        XCTAssertEqual(Set(firstTransaction?.targetPhotoIDs ?? []), [targetA])

        var second = first
        second.contrast = 20
        await service.beginGesture(sourcePhotoID: source, targetPhotoIDs: [targetB], sourceBaseline: first)
        let secondTransaction = await service.commitGesture(sourceAfter: second)
        XCTAssertEqual(Set(secondTransaction?.targetPhotoIDs ?? []), [targetB])

        let saveCalls = await store.saveCalls
        XCTAssertEqual(saveCalls.map(\.0), [targetA, targetB], "each gesture's own writes must stay scoped to its own frozen targets")
    }

    // MARK: - Only modified field IDs are synchronized

    func testCommitGestureWithNoActualChangeWritesNothing() async {
        let source = PhotoID()
        let target = PhotoID()
        let store = Store([target: .neutral])
        let service = makeService(store)

        await service.beginGesture(sourcePhotoID: source, targetPhotoIDs: [target], sourceBaseline: .neutral)
        let transaction = await service.commitGesture(sourceAfter: .neutral)

        XCTAssertEqual(transaction?.modifiedFieldIDs, [])
        let saveCalls = await store.saveCalls
        XCTAssertTrue(saveCalls.isEmpty)
    }

    func testCommitGestureSyncsOnlyTheModifiedFieldsPreservingEachTargetsOwnOtherValues() async throws {
        let source = PhotoID()
        let target = PhotoID()
        var targetOwn = PhotoAdjustments.neutral
        targetOwn.contrast = 20 // the target's own, unrelated edit
        let store = Store([target: targetOwn])
        let service = makeService(store)

        var baseline = PhotoAdjustments.neutral
        baseline.exposure = 0
        var after = baseline
        after.exposure = 1.5 // the only field this drag actually changed

        await service.beginGesture(sourcePhotoID: source, targetPhotoIDs: [target], sourceBaseline: baseline)
        let committed = await service.commitGesture(sourceAfter: after)
        let transaction = try XCTUnwrap(committed)

        XCTAssertEqual(transaction.modifiedFieldIDs, [.basicExposure])
        let updated = await store.current(target)
        XCTAssertEqual(updated.exposure, 1.5, "the synced field must land at the source's own new value")
        XCTAssertEqual(updated.contrast, 20, "a field this drag never touched must keep the target's own value")
    }

    func testCommitGestureRecordsBeforeAndAfterPatchesPerTarget() async throws {
        let source = PhotoID()
        let target = PhotoID()
        var targetOwn = PhotoAdjustments.neutral
        targetOwn.exposure = -0.5 // the target's own prior exposure, about to be overwritten
        let store = Store([target: targetOwn])
        let service = makeService(store)

        let baseline = PhotoAdjustments.neutral
        var after = baseline
        after.exposure = 2.0

        await service.beginGesture(sourcePhotoID: source, targetPhotoIDs: [target], sourceBaseline: baseline)
        let committed = await service.commitGesture(sourceAfter: after)
        let transaction = try XCTUnwrap(committed)

        XCTAssertEqual(transaction.before[target]?.basic?.exposure, -0.5, "before must record the target's own prior value, not the source's")
        XCTAssertEqual(transaction.after[target]?.basic?.exposure, 2.0)
        XCTAssertEqual(transaction.results[target], .success)
    }

    func testCommitGestureContinuesToOtherTargetsWhenOneFailsAndRecordsTheFailure() async throws {
        let source = PhotoID()
        let goodTarget = PhotoID()
        let badTarget = PhotoID()
        let store = Store([goodTarget: .neutral, badTarget: .neutral])
        await store.markFailing(badTarget)
        let service = makeService(store)

        let baseline = PhotoAdjustments.neutral
        var after = baseline
        after.exposure = 1

        await service.beginGesture(sourcePhotoID: source, targetPhotoIDs: [goodTarget, badTarget], sourceBaseline: baseline)
        let committed = await service.commitGesture(sourceAfter: after)
        let transaction = try XCTUnwrap(committed)

        XCTAssertEqual(transaction.results[goodTarget], .success)
        if case .failure? = transaction.results[badTarget] {
            // expected
        } else {
            XCTFail("expected .failure for the target whose save throws, got \(String(describing: transaction.results[badTarget]))")
        }
        let updatedGood = await store.current(goodTarget)
        XCTAssertEqual(updatedGood.exposure, 1, "a failure on one target must not stop the others from syncing")
    }

    // MARK: - Task 3.4: compound batch undo (revert = write `before[id]` back)

    func testUndoRevertsEveryTargetToItsOwnPriorValueOnFullSuccess() async throws {
        let source = PhotoID()
        let targetA = PhotoID()
        let targetB = PhotoID()
        var targetAOwn = PhotoAdjustments.neutral
        targetAOwn.exposure = -0.5
        targetAOwn.contrast = 20 // unrelated field, must survive the undo too
        let store = Store([targetA: targetAOwn, targetB: .neutral])
        let service = makeService(store)

        let baseline = PhotoAdjustments.neutral
        var after = baseline
        after.exposure = 1.5

        await service.beginGesture(sourcePhotoID: source, targetPhotoIDs: [targetA, targetB], sourceBaseline: baseline)
        let committed = await service.commitGesture(sourceAfter: after)
        let transaction = try XCTUnwrap(committed)

        let summary = await service.undo(transaction)

        XCTAssertEqual(summary.affected, 2)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.skipped, 0)
        let revertedA = await store.current(targetA)
        XCTAssertEqual(revertedA.exposure, -0.5, "target A's own prior exposure must come back")
        XCTAssertEqual(revertedA.contrast, 20, "an unrelated field must survive the undo, same as it survived the original sync")
        let revertedB = await store.current(targetB)
        XCTAssertEqual(revertedB.exposure, 0)
    }

    /// Partial failure: a target the original sync never actually wrote to
    /// (its own load/save was already broken) has nothing to revert --
    /// undo must not touch it, and must not count it as a failure of its
    /// own.
    func testUndoSkipsTargetsThatFailedTheOriginalSync() async throws {
        let source = PhotoID()
        let goodTarget = PhotoID()
        let badTarget = PhotoID()
        let store = Store([goodTarget: .neutral, badTarget: .neutral])
        await store.markFailing(badTarget)
        let service = makeService(store)

        let baseline = PhotoAdjustments.neutral
        var after = baseline
        after.exposure = 1

        await service.beginGesture(sourcePhotoID: source, targetPhotoIDs: [goodTarget, badTarget], sourceBaseline: baseline)
        let committed = await service.commitGesture(sourceAfter: after)
        let transaction = try XCTUnwrap(committed)

        let summary = await service.undo(transaction)

        XCTAssertEqual(summary.affected, 1, "only the target the original sync actually wrote to needs reverting")
        XCTAssertEqual(summary.skipped, 1, "a target the original sync never touched must not be touched by undo either")
        XCTAssertEqual(summary.failed, 0)
    }

    /// Undo after partial failure, the other direction: the revert write
    /// itself can fail (e.g. the target became unwritable in between) --
    /// tallied distinctly from `skipped`, and the target's sidecar must be
    /// left exactly as the original sync left it, never half-written.
    func testUndoTalliesFailedWhenTheTargetBecomesUnwritableBeforeTheRevertRuns() async throws {
        let source = PhotoID()
        let target = PhotoID()
        let store = Store([target: .neutral])
        let service = makeService(store)

        let baseline = PhotoAdjustments.neutral
        var after = baseline
        after.exposure = 1

        await service.beginGesture(sourcePhotoID: source, targetPhotoIDs: [target], sourceBaseline: baseline)
        let committed = await service.commitGesture(sourceAfter: after)
        let transaction = try XCTUnwrap(committed)
        await store.markFailing(target)

        let summary = await service.undo(transaction)

        XCTAssertEqual(summary.affected, 0)
        XCTAssertEqual(summary.failed, 1)
        let unchanged = await store.current(target)
        XCTAssertEqual(unchanged.exposure, 1, "a failed undo write must leave the target exactly as the original sync left it")
    }

    /// Independent review of Task 3.4: `undo(_:)` merged `before[target]`
    /// back onto the target's *current* adjustments without ever checking
    /// whether the target's synced fields still held what the sync wrote --
    /// a target edited (directly, or by a later batch sync) on the very
    /// same field between the original sync and this undo would have that
    /// later, deliberate edit silently discarded.
    func testUndoDoesNotOverwriteAFieldTheTargetHasBeenEditedOnSinceTheSync() async throws {
        let source = PhotoID()
        let target = PhotoID()
        let store = Store([target: .neutral])
        let service = makeService(store)

        let baseline = PhotoAdjustments.neutral
        var after = baseline
        after.exposure = 1.5

        await service.beginGesture(sourcePhotoID: source, targetPhotoIDs: [target], sourceBaseline: baseline)
        let committed = await service.commitGesture(sourceAfter: after)
        let transaction = try XCTUnwrap(committed)

        // The user opens the target directly and edits the very same field
        // the sync touched, after the sync but before the undo.
        var manuallyEdited = PhotoAdjustments.neutral
        manuallyEdited.exposure = 2.5
        try await store.save(manuallyEdited, target)

        let summary = await service.undo(transaction)

        XCTAssertEqual(summary.affected, 0, "the target must not be reverted once it's been edited on the synced field since the sync")
        XCTAssertEqual(summary.skipped, 1)
        let current = await store.current(target)
        XCTAssertEqual(current.exposure, 2.5, "the user's later manual edit must survive the undo")
    }

    /// The same protection, but scoped to only the field that actually
    /// conflicts -- a target edited on an *unrelated* field since the sync
    /// must still have the synced field reverted normally.
    func testUndoStillRevertsWhenTheTargetWasOnlyEditedOnAnUnrelatedFieldSinceTheSync() async throws {
        let source = PhotoID()
        let target = PhotoID()
        let store = Store([target: .neutral])
        let service = makeService(store)

        let baseline = PhotoAdjustments.neutral
        var after = baseline
        after.exposure = 1.5

        await service.beginGesture(sourcePhotoID: source, targetPhotoIDs: [target], sourceBaseline: baseline)
        let committed = await service.commitGesture(sourceAfter: after)
        let transaction = try XCTUnwrap(committed)

        // An unrelated field edited on the target since the sync -- must not
        // block the revert of the field the sync actually touched.
        var edited = PhotoAdjustments.neutral
        edited.exposure = 1.5 // still exactly what the sync wrote
        edited.contrast = 20 // the target's own, unrelated new edit
        try await store.save(edited, target)

        let summary = await service.undo(transaction)

        XCTAssertEqual(summary.affected, 1)
        XCTAssertEqual(summary.skipped, 0)
        let current = await store.current(target)
        XCTAssertEqual(current.exposure, 0, "the synced field must still revert when untouched since the sync")
        XCTAssertEqual(current.contrast, 20, "an unrelated later edit must survive the undo")
    }

    /// Independent review of Task 3.4's own independent-review fix round,
    /// Finding 2: `commitGesture`/`undo` each run a target's own
    /// `load → merge → save` cycle across several `await` points -- actor
    /// isolation guarantees only one call's *unsuspended* code runs at a
    /// time, not that a whole such cycle is atomic against another call
    /// into this same actor that starts while the first is suspended. A
    /// rendezvous (`Interleaver` below) deterministically forces the
    /// interleaving a real timing race would only sometimes produce: a
    /// second batch sync (T2) is paused *inside* its own `loadAdjustments`
    /// call for `target`, `undo` (of an earlier transaction T1, sharing the
    /// same target) is driven to completion while T2 is still suspended
    /// there, then T2 is released to finish. Without `targetsInFlight`,
    /// `undo`'s own load would have raced ahead of T2's paused one, read
    /// the pre-T2 value, and its later `saveAdjustments` would have landed
    /// *after* T2's own save -- silently erasing T2's result.
    func testUndoDoesNotRaceAConcurrentCommitGestureOnTheSameTarget() async throws {
        actor Interleaver {
            private var hasArrived = false
            private var arrivedContinuation: CheckedContinuation<Void, Never>?
            private var isReleased = false
            private var releaseContinuation: CheckedContinuation<Void, Never>?

            /// Called from inside the paused operation: signals arrival,
            /// then suspends until `release()`.
            func arriveAndWaitForRelease() async {
                hasArrived = true
                arrivedContinuation?.resume()
                arrivedContinuation = nil
                guard !isReleased else { return }
                await withCheckedContinuation { releaseContinuation = $0 }
            }

            /// Called from the test: suspends until `arriveAndWaitForRelease()`
            /// has actually been entered by the other task.
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

        let source = PhotoID()
        let target = PhotoID()
        let store = Store([target: .neutral])

        // T1: an ordinary, ungated sync that produces the transaction this
        // test will later undo.
        let setupService = makeService(store)
        let baseline = PhotoAdjustments.neutral
        var afterT1 = baseline
        afterT1.exposure = 1.5
        await setupService.beginGesture(sourcePhotoID: source, targetPhotoIDs: [target], sourceBaseline: baseline)
        let committedT1 = await setupService.commitGesture(sourceAfter: afterT1)
        let transaction = try XCTUnwrap(committedT1)

        // A second service instance sharing the same store/target, standing
        // in for "another in-flight batch sync (T2)" -- gated so its own
        // load for `target` pauses on command.
        let interleaver = Interleaver()
        let service = BatchAdjustmentSyncService(
            loadAdjustments: { id in
                if id == target { await interleaver.arriveAndWaitForRelease() }
                return try await store.load(id)
            },
            saveAdjustments: { value, id in try await store.save(value, id) }
        )
        var afterT2 = afterT1
        afterT2.contrast = 20 // a field T1 never touched
        await service.beginGesture(sourcePhotoID: source, targetPhotoIDs: [target], sourceBaseline: afterT1)

        let t2Task = Task { await service.commitGesture(sourceAfter: afterT2) }
        await interleaver.waitForArrival() // T2 is now paused inside its own load for `target`.

        let undoSummary = await service.undo(transaction)

        await interleaver.release()
        let t2Result = await t2Task.value
        let t2Transaction = try XCTUnwrap(t2Result)

        XCTAssertEqual(undoSummary.affected, 0, "undo must back off rather than race T2's in-flight write")
        XCTAssertEqual(undoSummary.failed, 1)
        XCTAssertEqual(t2Transaction.results[target], .success, "T2 itself must still complete normally once released")
        let final = await store.current(target)
        XCTAssertEqual(final.contrast, 20, "T2's own sync must land")
        XCTAssertEqual(final.exposure, 1.5, "T1's value (T2's own baseline) must survive -- not clobbered by undo racing in")
    }

    func testUndoOfATransactionWithNoModifiedFieldsIsANoOp() async throws {
        let source = PhotoID()
        let target = PhotoID()
        let service = makeService(Store([target: .neutral]))

        await service.beginGesture(sourcePhotoID: source, targetPhotoIDs: [target], sourceBaseline: .neutral)
        let committed = await service.commitGesture(sourceAfter: .neutral) // no actual change
        let transaction = try XCTUnwrap(committed)

        let summary = await service.undo(transaction)

        XCTAssertEqual(summary.affected, 0)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.skipped, 0)
    }
}
