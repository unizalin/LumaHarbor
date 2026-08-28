import Foundation

/// Schedules scan work across multiple library sources with a fixed
/// concurrency budget (spec §9): at most two libraries scan at once, and the
/// rest queue behind them.
///
/// Internal on purpose (req. 11 of the Task 3 brief): this is a service
/// composition detail, not product API. `PhotoLibraryService.scanLibraries`
/// is the only public surface that uses it; tests reach it directly via
/// `@testable import`.
///
/// An actor because the queue, the active-slot table and the sequence
/// counter are shared mutable state that every `enqueue`/`cancel` call and
/// every scan's own completion both reach for.
actor MultiSourceScanCoordinator {
    /// The caller's currently-selected source is scheduled ahead of every
    /// `.normal` one waiting behind it (spec §9), but never interrupts a
    /// scan already running -- an in-flight batch is never rudely cut off.
    enum ScanPriority: Sendable, Equatable {
        case normal
        case selected

        fileprivate var rank: Int {
            switch self {
            case .normal: return 0
            case .selected: return 1
            }
        }
    }

    /// Exactly two -- spec §9's "全 App 最多兩個來源同時掃描".
    static let maximumConcurrentScans = 2

    private struct QueuedOperation {
        let libraryID: LibraryID
        var priority: ScanPriority
        var operation: @Sendable () async -> Void
        /// Insertion order, so equal-priority entries stay FIFO (req. 4/6 of
        /// the Task 3 brief) even though `queue` itself is reordered by
        /// priority when picking the next runnable entry.
        let sequence: UInt64
        /// Resumed exactly once: when `operation` actually finishes running,
        /// or immediately -- without ever running `operation` -- if this
        /// entry is displaced by a later enqueue for the same `libraryID`
        /// while it was still queued. `nil` for entries registered through
        /// the fire-and-forget `enqueue(...)`, which nothing is waiting on.
        var completion: CheckedContinuation<Void, Never>?
    }

    private var queue: [QueuedOperation] = []
    private var activeTasks: [LibraryID: Task<Void, Never>] = [:]
    private var sequenceCounter: UInt64 = 0

    /// Test-only high-water mark of `activeTasks.count`, so a test can prove
    /// the two-slot budget was never exceeded without racing a live read of
    /// `activeTasks` against scheduling.
    private(set) var maximumObservedActiveCount = 0

    // MARK: - Scheduling

    /// Registers `operation` for `libraryID` and returns once it is queued
    /// (or already running) -- it does not wait for `operation` itself to
    /// run. A `libraryID` may have at most one active and one queued entry
    /// at once (req. 5): a second `enqueue` for a `libraryID` that is still
    /// queued replaces that queued entry outright, never appending a
    /// duplicate; a second `enqueue` while the first is already active
    /// queues behind it -- the coordinator never starts the same
    /// `libraryID` in two slots at once (req. 10), and the already-running
    /// scan keeps running under its own existing generation/cancellation
    /// contract (req. 6) rather than being torn down here.
    func enqueue(
        libraryID: LibraryID,
        priority: ScanPriority,
        operation: @escaping @Sendable () async -> Void
    ) {
        register(libraryID: libraryID, priority: priority, operation: operation, completion: nil)
    }

    /// Like `enqueue`, but suspends the caller until `operation` has
    /// actually run to completion -- including the case where a later
    /// `enqueue`/`run` for the same `libraryID` displaces this one before it
    /// ever started, which resumes this call immediately without running
    /// `operation` at all. Displacement is a legitimate supersession, not a
    /// hang: the caller is told its request is done being waited on, exactly
    /// as a superseded scan generation already completes without doing
    /// further work.
    ///
    /// Cancelling the calling task -- e.g. cancelling a
    /// `PhotoLibraryService.scanLibraries` caller -- cancels the entry itself
    /// via `cancel(libraryID:)` (removing it if still queued, or cancelling
    /// its active task if running) rather than merely marking the caller's
    /// own suspension point cancelled and leaving the scan running
    /// unobserved.
    func run(
        libraryID: LibraryID,
        priority: ScanPriority,
        operation: @escaping @Sendable () async -> Void
    ) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                register(libraryID: libraryID, priority: priority, operation: operation, completion: continuation)
            }
        } onCancel: {
            Task { await self.cancel(libraryID: libraryID) }
        }
    }

    /// Removes any queued entry for `libraryID` (never running it) and
    /// cancels its active task, if any. Either half may be a no-op: cancel
    /// is safe to call for a `libraryID` that is only queued, only active,
    /// or not known to the coordinator at all.
    ///
    /// A cancelled active task still runs its own `Task<Void, Never>` to
    /// completion cooperatively -- exactly like cancelling the consumer of a
    /// `LibraryScanSequence` directly -- so the slot is only actually
    /// released, and the next queued item started, once that completion
    /// callback re-enters this actor (req. 8).
    func cancel(libraryID: LibraryID) {
        if let index = queue.firstIndex(where: { $0.libraryID == libraryID }) {
            let displaced = queue.remove(at: index)
            displaced.completion?.resume()
        }
        activeTasks[libraryID]?.cancel()
    }

    // MARK: - Test-only introspection

    var activeLibraryIDs: Set<LibraryID> { Set(activeTasks.keys) }
    var queuedLibraryIDs: [LibraryID] { queue.map(\.libraryID) }
    var activeCount: Int { activeTasks.count }

    // MARK: - Private

    private func register(
        libraryID: LibraryID,
        priority: ScanPriority,
        operation: @escaping @Sendable () async -> Void,
        completion: CheckedContinuation<Void, Never>?
    ) {
        sequenceCounter += 1
        let entry = QueuedOperation(
            libraryID: libraryID, priority: priority, operation: operation,
            sequence: sequenceCounter, completion: completion
        )
        if let index = queue.firstIndex(where: { $0.libraryID == libraryID }) {
            let displaced = queue[index]
            queue[index] = entry
            displaced.completion?.resume()
        } else {
            queue.append(entry)
        }
        scheduleAvailableSlots()
    }

    private func scheduleAvailableSlots() {
        while activeTasks.count < Self.maximumConcurrentScans {
            guard let index = nextRunnableIndex() else { break }
            start(queue.remove(at: index))
        }
    }

    /// The best entry to run next among those not already active: highest
    /// priority first, then earliest insertion (req. 4/7 -- FIFO within a
    /// priority tier, selected-priority ahead of normal). An entry whose
    /// `libraryID` is already active is skipped, not merely deprioritised --
    /// it stays queued until that active run finishes.
    private func nextRunnableIndex() -> Int? {
        var best: Int?
        for (index, entry) in queue.enumerated() {
            guard activeTasks[entry.libraryID] == nil else { continue }
            guard let bestIndex = best else {
                best = index
                continue
            }
            let current = queue[bestIndex]
            if entry.priority.rank > current.priority.rank
                || (entry.priority.rank == current.priority.rank && entry.sequence < current.sequence) {
                best = index
            }
        }
        return best
    }

    private func start(_ entry: QueuedOperation) {
        let libraryID = entry.libraryID
        let operation = entry.operation
        let completion = entry.completion
        activeTasks[libraryID] = Task {
            await operation()
            self.completed(libraryID: libraryID, completion: completion)
        }
        maximumObservedActiveCount = max(maximumObservedActiveCount, activeTasks.count)
    }

    private func completed(libraryID: LibraryID, completion: CheckedContinuation<Void, Never>?) {
        activeTasks.removeValue(forKey: libraryID)
        completion?.resume()
        scheduleAvailableSlots()
    }
}
