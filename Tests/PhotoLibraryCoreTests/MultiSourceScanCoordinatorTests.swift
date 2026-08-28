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

    // MARK: - One active slot per source

    func testSameLibraryIDNeverActiveTwiceSimultaneously() async throws {
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
        XCTAssertEqual(queuedWhileActive, [id])

        await tracker.release(otherSlotID)
        // The slot that just freed must go unused for `id`: its first run is
        // still active, so the replacement must keep waiting.
        try? await Task.sleep(for: .milliseconds(100))
        let maxConcurrentByIDBeforeSecondRun = await tracker.maximumConcurrentCountByID[id]
        XCTAssertEqual(
            maxConcurrentByIDBeforeSecondRun, 1,
            "The same LibraryID ran concurrently with itself"
        )
        let queuedStillWaiting = await coordinator.queuedLibraryIDs
        XCTAssertEqual(
            queuedStillWaiting, [id],
            "A freed slot must not start a second run of an id that is already active"
        )

        await tracker.release(id)
        await waitUntil("the queued replacement to start once the first run finishes") {
            await tracker.runCounts[id] == 2
        }
        let maxConcurrentByIDAfterSecondRun = await tracker.maximumConcurrentCountByID[id]
        XCTAssertEqual(
            maxConcurrentByIDAfterSecondRun, 1,
            "The same LibraryID ran concurrently with itself"
        )

        await tracker.release(id)
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
}
