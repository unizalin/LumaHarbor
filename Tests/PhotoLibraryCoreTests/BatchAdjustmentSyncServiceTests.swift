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
}
