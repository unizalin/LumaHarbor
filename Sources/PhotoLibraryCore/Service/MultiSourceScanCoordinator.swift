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

    /// Boxes one registration's eventual completion signal. Mutated only
    /// while running on this actor -- every read/write happens inside
    /// `waitBox`/`resolveBox`, both actor-isolated -- so capturing a box
    /// across a `Task`/`TaskGroup` boundary to hand into a later
    /// actor-isolated call is safe despite the class itself not being
    /// inherently thread-safe. A box nobody ever waits on (the fire-and-
    /// forget `enqueue(...)` path passes `nil` instead of creating one) is
    /// simply never created, so there is nothing to leak.
    private final class CompletionBox: @unchecked Sendable {
        var isResolved = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private struct QueuedOperation {
        let libraryID: LibraryID
        var priority: ScanPriority
        var operation: @Sendable () async -> Void
        /// Insertion order, so equal-priority entries stay FIFO (req. 4/6 of
        /// the Task 3 brief) even though `queue` itself is reordered by
        /// priority when picking the next runnable entry.
        let sequence: UInt64
        /// `nil` for entries registered through the fire-and-forget
        /// `enqueue(...)`, which nothing is waiting on. Resolved exactly
        /// once: when `operation` actually finishes running, or immediately
        /// -- without ever running `operation` -- if this entry is displaced
        /// by a later registration for the same `libraryID` while it was
        /// still queued.
        let completionBox: CompletionBox?
    }

    private var queue: [QueuedOperation] = []
    private var activeTasks: [LibraryID: Task<Void, Never>] = [:]
    /// Extra completion boxes riding along with the currently-active task for
    /// a `libraryID`: created when a registration arrives for a `libraryID`
    /// that is already active. One `libraryID` may be active or queued at
    /// once, never both (req. 5/10) -- so a duplicate registration against an
    /// already-active source never queues a second (redundant) run of it;
    /// it instead waits for the exact same in-flight run to finish, resolved
    /// alongside the original caller by `completed(libraryID:completionBox:)`
    /// below. A fire-and-forget `enqueue(...)` for an already-active
    /// `libraryID` has no box to add here at all -- it has nothing to wait
    /// for, and its `operation` is simply never run a second time.
    private var activeRiders: [LibraryID: [CompletionBox]] = [:]
    private var sequenceCounter: UInt64 = 0

    /// Test-only high-water mark of `activeTasks.count`, so a test can prove
    /// the two-slot budget was never exceeded without racing a live read of
    /// `activeTasks` against scheduling.
    private(set) var maximumObservedActiveCount = 0

    // MARK: - Scheduling

    /// Registers `operation` for `libraryID` and returns once it is queued
    /// (or already running) -- it does not wait for `operation` itself to
    /// run. A `libraryID` may have at most one active-or-queued entry at once
    /// (req. 5): a second `enqueue` for a `libraryID` that is still queued
    /// replaces that queued entry outright, never appending a duplicate; a
    /// second `enqueue` while the first is already *active* is dropped
    /// without ever queuing or running a second time -- the already-running
    /// scan keeps running under its own existing generation/cancellation
    /// contract (req. 6) rather than being torn down or duplicated here.
    func enqueue(
        libraryID: LibraryID,
        priority: ScanPriority,
        operation: @escaping @Sendable () async -> Void
    ) {
        insert(libraryID: libraryID, priority: priority, operation: operation, completionBox: nil)
        scheduleAvailableSlots()
    }

    /// Like `enqueue`, but suspends the caller until `operation` has actually
    /// run to completion. Three cases resume this call:
    ///
    /// - `operation` ran to completion (normally or after cooperative
    ///   cancellation) -- the common case.
    /// - This entry was displaced by a later registration for the same
    ///   `libraryID` before it ever started running, which resumes this call
    ///   immediately without running `operation` at all. Displacement is a
    ///   legitimate supersession, not a hang: the caller is told its request
    ///   is done being waited on, exactly as a superseded scan generation
    ///   already completes without doing further work.
    /// - `libraryID` was already active when this call registered: rather
    ///   than queuing (and eventually running) a second, redundant scan of
    ///   the same source, this call rides along on the *existing* active
    ///   run and resumes when that one finishes -- never hanging, and never
    ///   starting a second scan.
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
        let box = CompletionBox()
        insert(libraryID: libraryID, priority: priority, operation: operation, completionBox: box)
        scheduleAvailableSlots()
        await withTaskCancellationHandler {
            await waitBox(box)
        } onCancel: {
            Task { await self.cancel(libraryID: libraryID) }
        }
    }

    /// Registers every `(libraryID, priority, operation)` triple in `entries`
    /// atomically, in array order, before any of them is allowed to start --
    /// then awaits every one of them the way `run(...)` would.
    ///
    /// Why this exists: a caller with several sources to schedule in one
    /// batch (`PhotoLibraryService.scanLibraries`) cannot get deterministic
    /// priority/FIFO ordering among that batch by spawning one concurrent
    /// child task per source that each independently calls `run(...)` --
    /// `TaskGroup` gives no guarantee about which child task actually reaches
    /// this actor first, so a `.selected`-priority source could in principle
    /// lose a race to two `.normal` ones and get queued behind them. Building
    /// the whole batch into `queue`/`activeRiders` in one synchronous,
    /// non-suspending pass (`insert(...)` never awaits) closes that race:
    /// nothing else can reach this actor while the pass runs, so the
    /// priority/FIFO ordering `scheduleAvailableSlots()` sees once the pass
    /// finishes reflects the whole batch, not whichever entry happened to
    /// arrive first.
    ///
    /// A duplicate `libraryID` within `entries` itself is inserted exactly as
    /// if its two entries had been passed to `enqueue(...)`/`run(...)` one
    /// after another in array order: the later entry replaces the earlier
    /// one before either starts, and the earlier one resolves immediately
    /// without ever running -- the same "later registration supersedes an
    /// earlier still-queued one" rule `insert(...)` already applies outside
    /// a batch. (`PhotoLibraryService.scanLibraries` never actually exercises
    /// this case: it de-duplicates `libraryIDs` before building `entries`.)
    ///
    /// Returns once every entry in the batch has run to completion, failed,
    /// been cancelled, or -- for a `libraryID` already active from an earlier
    /// call, or a duplicate `libraryID` within `entries` itself -- been
    /// resolved without ever running, per `run(...)`'s usual semantics.
    func runBatch(
        _ entries: [(libraryID: LibraryID, priority: ScanPriority, operation: @Sendable () async -> Void)]
    ) async {
        let boxes = entries.map { _ in CompletionBox() }
        for (entry, box) in zip(entries, boxes) {
            insert(
                libraryID: entry.libraryID, priority: entry.priority,
                operation: entry.operation, completionBox: box
            )
        }
        scheduleAvailableSlots()

        await withTaskGroup(of: Void.self) { group in
            for (entry, box) in zip(entries, boxes) {
                group.addTask {
                    await withTaskCancellationHandler {
                        await self.waitBox(box)
                    } onCancel: {
                        Task { await self.cancel(libraryID: entry.libraryID) }
                    }
                }
            }
        }
    }

    /// Removes any queued entry for `libraryID` (never running it) and
    /// cancels its active task, if any. Either half may be a no-op: cancel
    /// is safe to call for a `libraryID` that is only queued, only active,
    /// or not known to the coordinator at all. Because a `libraryID` is never
    /// both active and queued at once (req. 5/10), these two halves can never
    /// collide for the same `libraryID` -- removing a queued duplicate can
    /// never reach into `activeTasks` for that same id, since no such active
    /// entry can exist alongside it.
    ///
    /// A cancelled active task still runs its own `Task<Void, Never>` to
    /// completion cooperatively -- exactly like cancelling the consumer of a
    /// `LibraryScanSequence` directly -- so the slot is only actually
    /// released, and the next queued item started, once that completion
    /// callback re-enters this actor (req. 8). Any riders waiting on that
    /// same active run (see `activeRiders`) resolve at that same point.
    func cancel(libraryID: LibraryID) {
        if let index = queue.firstIndex(where: { $0.libraryID == libraryID }) {
            let displaced = queue.remove(at: index)
            resolveIfNeeded(displaced.completionBox)
        }
        activeTasks[libraryID]?.cancel()
    }

    // MARK: - Test-only introspection

    var activeLibraryIDs: Set<LibraryID> { Set(activeTasks.keys) }
    var queuedLibraryIDs: [LibraryID] { queue.map(\.libraryID) }
    var activeCount: Int { activeTasks.count }

    // MARK: - Private

    /// Places one entry into `queue` (or, if `libraryID` is already active,
    /// onto `activeRiders`) without scheduling -- callers are responsible for
    /// calling `scheduleAvailableSlots()` themselves once every entry in a
    /// batch has been inserted, so priority is decided over the whole batch
    /// rather than slot-by-slot as each entry lands. Never suspends: this is
    /// what lets `runBatch(_:)` insert an entire batch as one atomic step.
    private func insert(
        libraryID: LibraryID,
        priority: ScanPriority,
        operation: @escaping @Sendable () async -> Void,
        completionBox: CompletionBox?
    ) {
        if activeTasks[libraryID] != nil {
            if let completionBox {
                activeRiders[libraryID, default: []].append(completionBox)
            }
            return
        }

        sequenceCounter += 1
        let entry = QueuedOperation(
            libraryID: libraryID, priority: priority, operation: operation,
            sequence: sequenceCounter, completionBox: completionBox
        )
        if let index = queue.firstIndex(where: { $0.libraryID == libraryID }) {
            let displaced = queue[index]
            queue[index] = entry
            resolveIfNeeded(displaced.completionBox)
        } else {
            queue.append(entry)
        }
    }

    private func scheduleAvailableSlots() {
        while activeTasks.count < Self.maximumConcurrentScans {
            guard let index = nextRunnableIndex() else { break }
            start(queue.remove(at: index))
        }
    }

    /// The best entry to run next among those not already active: highest
    /// priority first, then earliest insertion (req. 4/7 -- FIFO within a
    /// priority tier, selected-priority ahead of normal). The `activeTasks`
    /// guard below is defensive rather than load-bearing: `insert(...)`
    /// never lets a `libraryID` already in `activeTasks` reach `queue` in the
    /// first place (it becomes an `activeRiders` entry instead), so this
    /// should never actually filter anything out -- it stands as an explicit
    /// assertion of that invariant rather than a silent assumption of it.
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
        let completionBox = entry.completionBox
        activeTasks[libraryID] = Task {
            await operation()
            self.completed(libraryID: libraryID, completionBox: completionBox)
        }
        maximumObservedActiveCount = max(maximumObservedActiveCount, activeTasks.count)
    }

    private func completed(libraryID: LibraryID, completionBox: CompletionBox?) {
        activeTasks.removeValue(forKey: libraryID)
        resolveIfNeeded(completionBox)
        if let riders = activeRiders.removeValue(forKey: libraryID) {
            for rider in riders { resolveBox(rider) }
        }
        scheduleAvailableSlots()
    }

    private func resolveIfNeeded(_ box: CompletionBox?) {
        guard let box else { return }
        resolveBox(box)
    }

    private func resolveBox(_ box: CompletionBox) {
        box.isResolved = true
        if let continuation = box.continuation {
            box.continuation = nil
            continuation.resume()
        }
    }

    private func waitBox(_ box: CompletionBox) async {
        if box.isResolved { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if box.isResolved {
                continuation.resume()
            } else {
                box.continuation = continuation
            }
        }
    }
}
