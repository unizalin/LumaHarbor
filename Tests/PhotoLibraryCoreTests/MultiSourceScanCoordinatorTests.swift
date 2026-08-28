import Foundation
import XCTest
@testable import PhotoLibraryCore

/// A boolean an async closure can set and a test can read back, without the
/// data-race a raw captured `var` would be under strict concurrency.
private actor Flag {
    private(set) var value = false
    func set() { value = true }
}

/// Records which `LibraryID`s a coordinator actually ran, and lets a test
/// gate a run open until it explicitly releases it -- the deterministic
/// alternative to guessing timing from a sleep.
///
/// Cooperates with cancellation exactly like a real scan operation
/// (`AcknowledgedAsyncChannel`'s own `send`/`next`): cancelling the `Task`
/// that is awaiting `run(_:)` resumes it immediately via `onCancel`, so
/// `MultiSourceScanCoordinator.cancel(libraryID:)` can free the slot without
/// this test double needing to be released by hand.
private actor ScanTracker {
    private(set) var startOrder: [LibraryID] = []
    private(set) var startedIDs: Set<LibraryID> = []
    private(set) var runCounts: [LibraryID: Int] = [:]
    private var currentActive = 0
    private(set) var maximumConcurrentCount = 0
    private var currentActiveByID: [LibraryID: Int] = [:]
    private(set) var maximumConcurrentCountByID: [LibraryID: Int] = [:]
    private var gates: [LibraryID: CheckedContinuation<Void, Never>] = [:]

    /// Gates until `release(_:)` (or cancellation) opens it.
    func run(_ id: LibraryID) async {
        enter(id)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gates[id] = continuation
            }
        } onCancel: {
            Task { await self.forceRelease(id) }
        }
        leave(id)
    }

    /// Never gates -- for tests that only care about ordering/counting under
    /// rapid scheduling, not manual release timing.
    func runImmediately(_ id: LibraryID) async {
        enter(id)
        leave(id)
    }

    func release(_ id: LibraryID) {
        gates.removeValue(forKey: id)?.resume()
    }

    private func forceRelease(_ id: LibraryID) {
        gates.removeValue(forKey: id)?.resume()
    }

    private func enter(_ id: LibraryID) {
        currentActive += 1
        maximumConcurrentCount = max(maximumConcurrentCount, currentActive)
        currentActiveByID[id, default: 0] += 1
        maximumConcurrentCountByID[id] = max(maximumConcurrentCountByID[id] ?? 0, currentActiveByID[id] ?? 0)
        startOrder.append(id)
        startedIDs.insert(id)
        runCounts[id, default: 0] += 1
    }

    private func leave(_ id: LibraryID) {
        currentActive -= 1
        currentActiveByID[id, default: 1] -= 1
    }
}

/// Task 3: two-slot, priority-aware, one-active-per-source scan scheduling
/// (spec §9). `MultiSourceScanCoordinator` is internal by design -- reached
/// here only through `@testable import`, never a public seam.
final class MultiSourceScanCoordinatorTests: XCTestCase {
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(description)")
    }

    // MARK: - Two-slot budget

    func testOnlyTwoSourcesRunAndThirdWaits() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let ids = [LibraryID(), LibraryID(), LibraryID()]

        await coordinator.enqueue(libraryID: ids[0], priority: .normal) { await tracker.run(ids[0]) }
        await coordinator.enqueue(libraryID: ids[1], priority: .normal) { await tracker.run(ids[1]) }
        await coordinator.enqueue(libraryID: ids[2], priority: .normal) { await tracker.run(ids[2]) }

        await waitUntil("two sources to start") { await tracker.startedIDs.count == 2 }
        let activeCount = await coordinator.activeCount
        XCTAssertEqual(activeCount, 2)
        let startedBeforeRelease = await tracker.startedIDs
        XCTAssertFalse(startedBeforeRelease.contains(ids[2]), "The third source started before a slot freed")

        await tracker.release(ids[0])
        await waitUntil("the third source to start once a slot frees") {
            await tracker.startedIDs.contains(ids[2])
        }
        let maximumConcurrent = await tracker.maximumConcurrentCount
        XCTAssertLessThanOrEqual(maximumConcurrent, 2)

        await tracker.release(ids[1])
        await tracker.release(ids[2])
    }

    // MARK: - Duplicate queued enqueue

    func testDuplicateQueuedEnqueueReplacesOldOperationWithoutRunningIt() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let blockerA = LibraryID()
        let blockerB = LibraryID()
        let targetID = LibraryID()
        let oldRan = Flag()
        let newRan = Flag()

        await coordinator.enqueue(libraryID: blockerA, priority: .normal) { await tracker.run(blockerA) }
        await coordinator.enqueue(libraryID: blockerB, priority: .normal) { await tracker.run(blockerB) }
        await waitUntil("both blockers to start") { await tracker.startedIDs.count == 2 }

        await coordinator.enqueue(libraryID: targetID, priority: .normal) { await oldRan.set() }
        await coordinator.enqueue(libraryID: targetID, priority: .normal) { await newRan.set() }
        let queuedAfterDuplicate = await coordinator.queuedLibraryIDs
        XCTAssertEqual(
            queuedAfterDuplicate, [targetID],
            "A duplicate queued enqueue must replace in place, never append a second entry"
        )

        await tracker.release(blockerA)
        await waitUntil("the replacement operation to run") { await newRan.value }

        let oldRanValue = await oldRan.value
        let newRanValue = await newRan.value
        XCTAssertFalse(oldRanValue, "The superseded queued operation must never run")
        XCTAssertTrue(newRanValue)

        await tracker.release(blockerB)
    }

    // MARK: - Selected-source priority

    func testSelectedPriorityRunsBeforeEarlierQueuedNormalWork() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let blockerA = LibraryID()
        let blockerB = LibraryID()
        let normalID = LibraryID()
        let selectedID = LibraryID()

        await coordinator.enqueue(libraryID: blockerA, priority: .normal) { await tracker.run(blockerA) }
        await coordinator.enqueue(libraryID: blockerB, priority: .normal) { await tracker.run(blockerB) }
        await waitUntil("both blockers to start") { await tracker.startedIDs.count == 2 }

        // `normalID` queues first; `selectedID` arrives later but with
        // explicit priority, and must still be scheduled first.
        await coordinator.enqueue(libraryID: normalID, priority: .normal) { await tracker.run(normalID) }
        await coordinator.enqueue(libraryID: selectedID, priority: .selected) { await tracker.run(selectedID) }
        let queuedBeforeStart = await coordinator.queuedLibraryIDs
        XCTAssertEqual(queuedBeforeStart, [normalID, selectedID])

        await tracker.release(blockerA)
        await waitUntil("the selected source to start ahead of the earlier-queued normal one") {
            await tracker.startedIDs.contains(selectedID)
        }
        let startedIDsAfterSelectedRuns = await tracker.startedIDs
        XCTAssertFalse(
            startedIDsAfterSelectedRuns.contains(normalID),
            "Selected priority must be scheduled before an earlier-queued normal-priority source"
        )

        await tracker.release(selectedID)
        await waitUntil("the normal source to start once the selected one finishes") {
            await tracker.startedIDs.contains(normalID)
        }

        await tracker.release(blockerB)
        await tracker.release(normalID)
    }

    func testSamePriorityStaysFIFO() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let blockerA = LibraryID()
        let blockerB = LibraryID()
        let first = LibraryID()
        let second = LibraryID()

        await coordinator.enqueue(libraryID: blockerA, priority: .normal) { await tracker.run(blockerA) }
        await coordinator.enqueue(libraryID: blockerB, priority: .normal) { await tracker.run(blockerB) }
        await waitUntil("both blockers to start") { await tracker.startedIDs.count == 2 }

        await coordinator.enqueue(libraryID: first, priority: .normal) { await tracker.run(first) }
        await coordinator.enqueue(libraryID: second, priority: .normal) { await tracker.run(second) }
        let queuedBoth = await coordinator.queuedLibraryIDs
        XCTAssertEqual(queuedBoth, [first, second])

        await tracker.release(blockerA)
        await waitUntil("the first-queued source to start") { await tracker.startedIDs.contains(first) }
        let startedIDsAfterFirstRuns = await tracker.startedIDs
        XCTAssertFalse(
            startedIDsAfterFirstRuns.contains(second),
            "FIFO: a later-queued, same-priority source must not start ahead of an earlier one"
        )

        await tracker.release(first)
        await tracker.release(blockerB)
        await waitUntil("the second source to start") { await tracker.startedIDs.contains(second) }
        await tracker.release(second)
    }

    // MARK: - `runBatch(_:)` deterministic batch scheduling

    /// Codex pre-landing review round 1, finding 2 (P2): registering
    /// `.normal` sources through one `TaskGroup` child task per source races
    /// a later-arriving `.selected` one for the two available slots. This
    /// proves `runBatch(_:)` -- the atomic, non-suspending registration path
    /// `PhotoLibraryService.scanLibraries` now uses -- schedules the selected
    /// source ahead of two earlier-positioned normal ones within a *single*
    /// batch call, with only two slots available, every time.
    func testRunBatchSchedulesSelectedPriorityAheadOfNormalEntriesInTheSameBatch() async throws {
        for _ in 0..<20 {
            let coordinator = MultiSourceScanCoordinator()
            let tracker = ScanTracker()
            let normalA = LibraryID()
            let normalB = LibraryID()
            let selectedC = LibraryID()
            let allIDs: Set<LibraryID> = [normalA, normalB, selectedC]

            let batchTask = Task {
                await coordinator.runBatch([
                    (libraryID: normalA, priority: .normal, operation: { await tracker.run(normalA) }),
                    (libraryID: normalB, priority: .normal, operation: { await tracker.run(normalB) }),
                    (libraryID: selectedC, priority: .selected, operation: { await tracker.run(selectedC) }),
                ])
            }

            await waitUntil("two sources to start") { await tracker.startedIDs.count == 2 }
            let startedAfterTwo = await tracker.startedIDs
            XCTAssertTrue(
                startedAfterTwo.contains(selectedC),
                "The selected source must be among the first two started, even though it is listed last"
            )
            XCTAssertFalse(
                startedAfterTwo.contains(normalA) && startedAfterTwo.contains(normalB),
                "The selected source must not be the one left waiting for a third slot"
            )

            // Release only the two that actually started -- `ScanTracker`'s
            // gate is a no-op if released before the id registers it, so the
            // still-queued third id must not be released until it has
            // actually started.
            for startedID in startedAfterTwo {
                await tracker.release(startedID)
            }
            let remainingID = try XCTUnwrap(allIDs.subtracting(startedAfterTwo).first)
            await waitUntil("the third source to start once a slot frees") {
                await tracker.startedIDs.contains(remainingID)
            }
            await tracker.release(remainingID)
            await batchTask.value
        }
    }

    /// Same-priority entries within one `runBatch(_:)` call keep the FIFO
    /// guarantee (req. 4/7) that `enqueue(...)`-built queues already have.
    func testRunBatchKeepsSamePriorityEntriesFIFO() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let blockerA = LibraryID()
        let blockerB = LibraryID()
        let first = LibraryID()
        let second = LibraryID()

        await coordinator.enqueue(libraryID: blockerA, priority: .normal) { await tracker.run(blockerA) }
        await coordinator.enqueue(libraryID: blockerB, priority: .normal) { await tracker.run(blockerB) }
        await waitUntil("both blockers to start") { await tracker.startedIDs.count == 2 }

        let batchTask = Task {
            await coordinator.runBatch([
                (libraryID: first, priority: .normal, operation: { await tracker.run(first) }),
                (libraryID: second, priority: .normal, operation: { await tracker.run(second) }),
            ])
        }
        await waitUntil("both batch entries to be queued") { await coordinator.queuedLibraryIDs == [first, second] }

        await tracker.release(blockerA)
        await waitUntil("the first-listed batch entry to start") { await tracker.startedIDs.contains(first) }
        let startedAfterFirst = await tracker.startedIDs
        XCTAssertFalse(
            startedAfterFirst.contains(second),
            "FIFO within a batch: a later-listed, same-priority entry must not start ahead of an earlier one"
        )

        await tracker.release(first)
        await tracker.release(blockerB)
        await waitUntil("the second batch entry to start") { await tracker.startedIDs.contains(second) }
        await tracker.release(second)
        await batchTask.value
    }

    /// A duplicate `libraryID` within a single `runBatch(_:)` call is
    /// inserted exactly as if the two entries had been passed to `insert(...)`
    /// one after another in array order: the later entry replaces the
    /// earlier one before either ever starts, matching `enqueue(...)`'s
    /// ordinary "a second registration for a still-queued libraryID replaces
    /// it in place" rule. Only one of the two ever consumes a slot, and the
    /// superseded one never runs its own operation.
    func testRunBatchDeduplicatesRepeatedLibraryIDWithinOneBatch() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let id = LibraryID()
        let firstRan = Flag()

        let batchTask = Task {
            await coordinator.runBatch([
                (libraryID: id, priority: .normal, operation: { await firstRan.set() }),
                (libraryID: id, priority: .normal, operation: { await tracker.run(id) }),
            ])
        }
        await waitUntil("the id to start") { await tracker.startedIDs.contains(id) }
        let activeCount = await coordinator.activeCount
        XCTAssertEqual(activeCount, 1, "A duplicate id within one batch must not consume a second slot")
        let queued = await coordinator.queuedLibraryIDs
        XCTAssertEqual(queued, [], "A duplicate id within one batch must never be queued")

        await tracker.release(id)
        await batchTask.value
        let firstRanValue = await firstRan.value
        XCTAssertFalse(
            firstRanValue,
            "The earlier duplicate entry within a batch must be superseded and never run its own operation"
        )
        let runCount = await tracker.runCounts[id]
        XCTAssertEqual(runCount, 1)
    }

    // MARK: - Cancellation

    func testCancelQueuedItemNeverRuns() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let blockerA = LibraryID()
        let blockerB = LibraryID()
        let queuedID = LibraryID()
        let ran = Flag()

        await coordinator.enqueue(libraryID: blockerA, priority: .normal) { await tracker.run(blockerA) }
        await coordinator.enqueue(libraryID: blockerB, priority: .normal) { await tracker.run(blockerB) }
        await waitUntil("both blockers to start") { await tracker.startedIDs.count == 2 }

        await coordinator.enqueue(libraryID: queuedID, priority: .normal) { await ran.set() }
        let queuedBeforeCancel = await coordinator.queuedLibraryIDs
        XCTAssertEqual(queuedBeforeCancel, [queuedID])

        await coordinator.cancel(libraryID: queuedID)
        let queuedAfterCancel = await coordinator.queuedLibraryIDs
        XCTAssertEqual(queuedAfterCancel, [], "A cancelled queued entry must be removed immediately")

        await tracker.release(blockerA)
        await tracker.release(blockerB)
        try? await Task.sleep(for: .milliseconds(100))
        let ranValue = await ran.value
        XCTAssertFalse(ranValue, "A cancelled queued operation must never run")
    }

    func testCancelActiveItemReleasesSlotForNextQueued() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let activeA = LibraryID()
        let activeB = LibraryID()
        let queuedID = LibraryID()

        await coordinator.enqueue(libraryID: activeA, priority: .normal) { await tracker.run(activeA) }
        await coordinator.enqueue(libraryID: activeB, priority: .normal) { await tracker.run(activeB) }
        await waitUntil("both to start") { await tracker.startedIDs.count == 2 }

        await coordinator.enqueue(libraryID: queuedID, priority: .normal) { await tracker.run(queuedID) }
        let queuedBeforeCancel = await coordinator.queuedLibraryIDs
        XCTAssertEqual(queuedBeforeCancel, [queuedID])

        await coordinator.cancel(libraryID: activeA)
        await waitUntil("the queued source to start once the cancelled slot frees") {
            await tracker.startedIDs.contains(queuedID)
        }
        let activeCountAfter = await coordinator.activeCount
        XCTAssertLessThanOrEqual(activeCountAfter, 2, "Cancellation must not leak or double-count a slot")

        await tracker.release(activeB)
        await tracker.release(queuedID)
    }

    // MARK: - Slot release regardless of how an operation ends

    func testSlotIsReleasedWhenOperationInternallyCatchesAThrow() async throws {
        struct DummyError: Error {}
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let blockerID = LibraryID()
        let throwingID = LibraryID()
        let queuedID = LibraryID()

        await coordinator.enqueue(libraryID: blockerID, priority: .normal) { await tracker.run(blockerID) }
        await coordinator.enqueue(libraryID: throwingID, priority: .normal) {
            do { throw DummyError() } catch { /* every real operation must swallow its own errors */ }
            await tracker.run(throwingID)
        }
        await waitUntil("both slots to start") { await tracker.startedIDs.count == 2 }

        await coordinator.enqueue(libraryID: queuedID, priority: .normal) { await tracker.run(queuedID) }
        let queuedBeforeRelease = await coordinator.queuedLibraryIDs
        XCTAssertEqual(queuedBeforeRelease, [queuedID])

        await tracker.release(throwingID)
        await waitUntil("the queued source to start once the throwing operation's slot frees") {
            await tracker.startedIDs.contains(queuedID)
        }
        let activeCountAfter = await coordinator.activeCount
        XCTAssertLessThanOrEqual(activeCountAfter, 2)

        await tracker.release(blockerID)
        await tracker.release(queuedID)
    }

    // MARK: - One active-or-queued slot per source

    /// Codex pre-landing review round 1, finding 1 (P1): the original
    /// implementation let a re-`enqueue` of an already-active `libraryID`
    /// queue a second, "shadow" entry that would run again once the active
    /// scan finished -- violating the plan's "one LibraryID may be active or
    /// queued once" invariant and letting `scanLibraries([id, id])` run a
    /// source twice. This test locks in the corrected behavior: no queued
    /// entry is ever created, and the operation never runs a second time.
    func testActiveEnqueueForSameLibraryIDNeverQueuesOrRunsTwice() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let id = LibraryID()
        let otherSlotID = LibraryID()

        await coordinator.enqueue(libraryID: otherSlotID, priority: .normal) { await tracker.run(otherSlotID) }
        await coordinator.enqueue(libraryID: id, priority: .normal) { await tracker.run(id) }
        await waitUntil("both to start") { await tracker.startedIDs.count == 2 }

        // Re-enqueue the same id while its first run is still active.
        await coordinator.enqueue(libraryID: id, priority: .normal) { await tracker.run(id) }
        let queuedWhileActive = await coordinator.queuedLibraryIDs
        XCTAssertEqual(
            queuedWhileActive, [],
            "A duplicate enqueue for an already-active libraryID must never create a queued entry"
        )
        let activeCountWhileActive = await coordinator.activeCount
        XCTAssertEqual(activeCountWhileActive, 2, "The duplicate enqueue must not itself consume a slot")

        await tracker.release(otherSlotID)
        // The slot that just freed must go unused for `id`: there is no
        // queued duplicate to start, since none was ever created.
        try? await Task.sleep(for: .milliseconds(100))
        let queuedStillEmpty = await coordinator.queuedLibraryIDs
        XCTAssertEqual(
            queuedStillEmpty, [],
            "No queued entry should ever appear for an id that is already active"
        )
        let runCountBeforeFirstFinishes = await tracker.runCounts[id]
        XCTAssertEqual(runCountBeforeFirstFinishes, 1, "The duplicate enqueue must never run its own operation")

        await tracker.release(id)
        try? await Task.sleep(for: .milliseconds(100))
        let finalRunCount = await tracker.runCounts[id]
        XCTAssertEqual(finalRunCount, 1, "An already-active id must run exactly once, never twice")
        let maxConcurrentByID = await tracker.maximumConcurrentCountByID[id]
        XCTAssertEqual(maxConcurrentByID, 1, "The same LibraryID ran concurrently with itself")
    }

    /// Codex pre-landing review round 1, finding 1 (P1): `run(...)` called
    /// for an already-active `libraryID` must neither hang nor start a
    /// second scan -- it rides along on the existing active run and resumes
    /// exactly when that run finishes.
    func testRunWhileActiveWaitsForTheActiveOperationWithoutRunningASecondTime() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let id = LibraryID()
        let secondRan = Flag()
        let secondDone = Flag()

        let firstTask = Task {
            await coordinator.run(libraryID: id, priority: .normal) { await tracker.run(id) }
        }
        await waitUntil("the first run to start") { await tracker.startedIDs.contains(id) }

        let secondTask = Task {
            await coordinator.run(libraryID: id, priority: .normal) { await secondRan.set() }
            await secondDone.set()
        }

        try? await Task.sleep(for: .milliseconds(100))
        let secondDoneBeforeRelease = await secondDone.value
        XCTAssertFalse(
            secondDoneBeforeRelease,
            "run(...) for an already-active id must wait for that active run, not hang or return on its own"
        )
        let queuedWhileActive = await coordinator.queuedLibraryIDs
        XCTAssertEqual(queuedWhileActive, [], "run(...) for an already-active id must never be queued")

        await tracker.release(id)
        await firstTask.value
        await waitUntil("the second run(...) call to resume once the active operation finishes") {
            await secondDone.value
        }
        await secondTask.value

        let secondRanValue = await secondRan.value
        XCTAssertFalse(secondRanValue, "run(...) for an already-active id must never execute its own operation")
        let runCount = await tracker.runCounts[id]
        XCTAssertEqual(runCount, 1)
    }

    /// Codex pre-landing review round 1, finding 1 (P1): since a `libraryID`
    /// can never be both active and queued at once, `cancel(libraryID:)`'s
    /// queued-removal half can never reach into `activeTasks` for that same
    /// id -- so cancelling a queued entry must never touch an unrelated
    /// active scan.
    func testCancelQueuedItemNeverAffectsUnrelatedActiveScans() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let activeA = LibraryID()
        let activeB = LibraryID()
        let queuedID = LibraryID()

        await coordinator.enqueue(libraryID: activeA, priority: .normal) { await tracker.run(activeA) }
        await coordinator.enqueue(libraryID: activeB, priority: .normal) { await tracker.run(activeB) }
        await waitUntil("both to start") { await tracker.startedIDs.count == 2 }

        await coordinator.enqueue(libraryID: queuedID, priority: .normal) { await tracker.run(queuedID) }
        let queuedBeforeCancel = await coordinator.queuedLibraryIDs
        XCTAssertEqual(queuedBeforeCancel, [queuedID])

        await coordinator.cancel(libraryID: queuedID)

        let activeIDsAfterCancel = await coordinator.activeLibraryIDs
        XCTAssertEqual(
            activeIDsAfterCancel, [activeA, activeB],
            "Cancelling a queued entry must not touch unrelated active scans"
        )
        let queuedAfterCancel = await coordinator.queuedLibraryIDs
        XCTAssertEqual(queuedAfterCancel, [])

        try? await Task.sleep(for: .milliseconds(100))
        let queuedIDStarted = await tracker.startedIDs.contains(queuedID)
        XCTAssertFalse(queuedIDStarted, "A cancelled queued operation must never run")

        await tracker.release(activeA)
        await tracker.release(activeB)
    }

    // MARK: - High-density scheduling

    func testHighDensityEnqueueCancelCompletionKeepsActiveSlotCountCorrect() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let ids = (0..<50).map { _ in LibraryID() }

        await withTaskGroup(of: Void.self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    await coordinator.enqueue(
                        libraryID: id,
                        priority: index.isMultiple(of: 2) ? .selected : .normal
                    ) {
                        await tracker.runImmediately(id)
                    }
                    if index.isMultiple(of: 5) {
                        await coordinator.cancel(libraryID: id)
                    }
                }
            }
        }

        await waitUntil("every non-cancelled id to finish", timeout: 10) {
            let active = await coordinator.activeCount
            let queued = await coordinator.queuedLibraryIDs
            return active == 0 && queued.isEmpty
        }

        let maximumConcurrent = await tracker.maximumConcurrentCount
        XCTAssertLessThanOrEqual(
            maximumConcurrent, 2,
            "The two-slot budget was exceeded under high-density scheduling"
        )
        let finalActiveCount = await coordinator.activeCount
        let finalQueuedIDs = await coordinator.queuedLibraryIDs
        XCTAssertEqual(finalActiveCount, 0)
        XCTAssertEqual(finalQueuedIDs, [])
        for id in ids {
            let maximumConcurrentForID = await tracker.maximumConcurrentCountByID[id] ?? 0
            XCTAssertLessThanOrEqual(
                maximumConcurrentForID, 1,
                "A LibraryID ran concurrently with itself under high-density scheduling"
            )
        }
    }

    // MARK: - `run(libraryID:priority:operation:)`

    func testRunSuspendsUntilOperationCompletes() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let id = LibraryID()
        let doneFlag = Flag()

        let observer = Task {
            await coordinator.run(libraryID: id, priority: .normal) { await tracker.run(id) }
            await doneFlag.set()
        }
        await waitUntil("the operation to start") { await tracker.startedIDs.contains(id) }
        try? await Task.sleep(for: .milliseconds(50))
        let doneBeforeRelease = await doneFlag.value
        XCTAssertFalse(doneBeforeRelease, "run(...) returned before its operation finished")

        await tracker.release(id)
        await observer.value
        let doneAfterRelease = await doneFlag.value
        XCTAssertTrue(doneAfterRelease)
    }

    func testRunResumesImmediatelyWhenDisplacedWhileQueued() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let blockerA = LibraryID()
        let blockerB = LibraryID()
        let id = LibraryID()

        await coordinator.enqueue(libraryID: blockerA, priority: .normal) { await tracker.run(blockerA) }
        await coordinator.enqueue(libraryID: blockerB, priority: .normal) { await tracker.run(blockerB) }
        await waitUntil("both blockers to start") { await tracker.startedIDs.count == 2 }

        let oldRan = Flag()
        let oldFinished = Flag()
        let oldRunTask = Task {
            await coordinator.run(libraryID: id, priority: .normal) { await oldRan.set() }
            await oldFinished.set()
        }
        await waitUntil("the first run to be queued") { await coordinator.queuedLibraryIDs == [id] }

        let newRan = Flag()
        await coordinator.enqueue(libraryID: id, priority: .normal) { await newRan.set() }

        await waitUntil("the displaced run(...) call to resume on its own") { await oldFinished.value }
        await oldRunTask.value
        let oldRanValue = await oldRan.value
        XCTAssertFalse(oldRanValue, "A displaced run(...) operation must never execute")

        await tracker.release(blockerA)
        await waitUntil("the replacement operation to run") { await newRan.value }
        await tracker.release(blockerB)
    }

    func testRunCancellationCancelsTheUnderlyingActiveOperation() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let id = LibraryID()
        let doneFlag = Flag()

        let runTask = Task {
            await coordinator.run(libraryID: id, priority: .normal) { await tracker.run(id) }
            await doneFlag.set()
        }
        await waitUntil("the operation to start") { await tracker.startedIDs.contains(id) }

        runTask.cancel()
        // No explicit `tracker.release(id)`: the underlying operation must
        // stop on its own, because cancelling `run(...)`'s caller must cancel
        // the coordinator's own active task for this libraryID -- which
        // `ScanTracker.run` cooperates with exactly like a real scan would.
        await waitUntil("run(...) to return once cancellation reaches the active operation") {
            await doneFlag.value
        }
        let activeCount = await coordinator.activeCount
        XCTAssertEqual(activeCount, 0, "The slot must be released once the cancelled operation actually stops")
    }

    func testRunCancellationRemovesAStillQueuedEntry() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let blockerA = LibraryID()
        let blockerB = LibraryID()
        let id = LibraryID()
        let ran = Flag()

        await coordinator.enqueue(libraryID: blockerA, priority: .normal) { await tracker.run(blockerA) }
        await coordinator.enqueue(libraryID: blockerB, priority: .normal) { await tracker.run(blockerB) }
        await waitUntil("both blockers to start") { await tracker.startedIDs.count == 2 }

        let doneFlag = Flag()
        let runTask = Task {
            await coordinator.run(libraryID: id, priority: .normal) { await ran.set() }
            await doneFlag.set()
        }
        await waitUntil("the run to be queued") { await coordinator.queuedLibraryIDs == [id] }

        runTask.cancel()
        await waitUntil("the cancelled run(...) call to return") { await doneFlag.value }

        let queuedAfterCancel = await coordinator.queuedLibraryIDs
        XCTAssertEqual(queuedAfterCancel, [], "A cancelled still-queued run(...) entry must be removed")

        await tracker.release(blockerA)
        await tracker.release(blockerB)
        try? await Task.sleep(for: .milliseconds(100))
        let ranValue = await ran.value
        XCTAssertFalse(ranValue, "A cancelled queued run(...) operation must never execute")
    }

    // MARK: - Rider cancellation must not cancel the active owner

    /// Codex pre-landing re-review round 2, finding 1 (P1, blocking): the
    /// round-1 fix let a duplicate registration against an already-active
    /// `libraryID` ride along on that active run instead of queuing a
    /// second one, but `run(...)`'s cancellation handler still called the
    /// unconditional `cancel(libraryID:)` -- so cancelling the *rider's own*
    /// caller (e.g. a second, independent `PhotoLibraryService.scanLibraries`
    /// call for the same source) tore down the *original* caller's
    /// already-active scan too. This proves cancelling a rider now only
    /// removes that rider's own wait -- the active owner's scan, and its
    /// operation, are completely unaffected.
    func testCancellingARiderNeverCancelsTheActiveOwnersScan() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let id = LibraryID()

        let ownerTask = Task {
            await coordinator.run(libraryID: id, priority: .normal) { await tracker.run(id) }
        }
        await waitUntil("the owner to start") { await tracker.startedIDs.contains(id) }

        let riderRan = Flag()
        let riderDone = Flag()
        let riderTask = Task {
            await coordinator.run(libraryID: id, priority: .normal) { await riderRan.set() }
            await riderDone.set()
        }
        // Give the rider a moment to actually register (become a rider on
        // the active owner) before cancelling it.
        try? await Task.sleep(for: .milliseconds(50))

        riderTask.cancel()
        await waitUntil("the cancelled rider to return") { await riderDone.value }

        // The owner's scan must be completely unaffected by the rider's own
        // cancellation: still active, its own operation not released or
        // disturbed.
        try? await Task.sleep(for: .milliseconds(100))
        let activeCountAfterRiderCancel = await coordinator.activeCount
        XCTAssertEqual(
            activeCountAfterRiderCancel, 1,
            "Cancelling a rider must not cancel the active owner's scan"
        )
        let runCountBeforeRelease = await tracker.runCounts[id]
        XCTAssertEqual(runCountBeforeRelease, 1, "The owner's operation must not be re-run or disturbed")

        await tracker.release(id)
        await ownerTask.value
        let finalRunCount = await tracker.runCounts[id]
        XCTAssertEqual(
            finalRunCount, 1,
            "The owner's operation must run exactly once, undisturbed by the cancelled rider"
        )
        let maxConcurrentByID = await tracker.maximumConcurrentCountByID[id]
        XCTAssertEqual(maxConcurrentByID, 1)
        let riderRanValue = await riderRan.value
        XCTAssertFalse(riderRanValue, "A cancelled rider must never run its own operation")
    }

    /// Same finding, exercised through `runBatch(_:)`: cancelling the task
    /// running a batch whose only entry turned out to be a rider on someone
    /// else's active scan must not cancel that active scan either.
    func testCancellingARiderWithinRunBatchNeverCancelsTheActiveOwnersScan() async throws {
        let coordinator = MultiSourceScanCoordinator()
        let tracker = ScanTracker()
        let id = LibraryID()

        let ownerTask = Task {
            await coordinator.run(libraryID: id, priority: .normal) { await tracker.run(id) }
        }
        await waitUntil("the owner to start") { await tracker.startedIDs.contains(id) }

        let riderRan = Flag()
        let batchTask = Task {
            await coordinator.runBatch([
                (libraryID: id, priority: .normal, operation: { await riderRan.set() }),
            ])
        }
        // Give the batch's single entry a moment to actually register as a
        // rider before cancelling the whole batch call.
        try? await Task.sleep(for: .milliseconds(50))

        batchTask.cancel()
        await batchTask.value

        try? await Task.sleep(for: .milliseconds(100))
        let activeCountAfterRiderCancel = await coordinator.activeCount
        XCTAssertEqual(
            activeCountAfterRiderCancel, 1,
            "Cancelling a runBatch(_:) call whose entry is riding on an active scan must not cancel that scan"
        )
        let runCountBeforeRelease = await tracker.runCounts[id]
        XCTAssertEqual(runCountBeforeRelease, 1, "The owner's operation must not be re-run or disturbed")

        await tracker.release(id)
        await ownerTask.value
        let finalRunCount = await tracker.runCounts[id]
        XCTAssertEqual(finalRunCount, 1, "The owner's operation must run exactly once")
        let riderRanValue = await riderRan.value
        XCTAssertFalse(riderRanValue, "A cancelled batch rider must never run its own operation")
    }
}
