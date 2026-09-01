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
    /// The completion box of whichever registration actually *started* the
    /// currently-active task for a `libraryID` -- i.e. the one `start(_:)`
    /// promoted out of `queue`, as opposed to a rider that arrived after the
    /// task was already running. `nil`/absent for a `libraryID` started via
    /// the fire-and-forget `enqueue(...)`, which has no box at all.
    /// `cancelRegistration(libraryID:box:)` uses this to tell "the caller
    /// that owns this active scan is cancelling it" (which legitimately
    /// cancels `activeTasks[libraryID]`) apart from "a rider is cancelling
    /// its own wait" (which must not).
    private var activeOwnerBoxes: [LibraryID: CompletionBox] = [:]
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
    /// Cancelling the calling task cancels this specific registration via
    /// `cancelRegistration(libraryID:box:)` -- never the blunter
    /// `cancel(libraryID:)`, and deliberately scoped to *this* call's own
    /// box:
    ///
    /// - If this call is still queued, its entry is removed (never run).
    /// - If this call is a rider on someone else's already-active scan, only
    ///   this call's own wait is torn down -- the shared active scan, and
    ///   every other caller/rider waiting on it, is left running untouched.
    ///   A rider cancelling itself must never take down a scan another
    ///   caller started and is still waiting on (e.g. two independent
    ///   `PhotoLibraryService.scanLibraries` callers racing the same
    ///   `libraryID`).
    /// - If this call is the one that actually *started* the active scan
    ///   (its box is `activeOwnerBoxes[libraryID]`), cancelling it really is
    ///   a request to stop that scan, so it does cancel
    ///   `activeTasks[libraryID]` -- same effect as calling
    ///   `cancel(libraryID:)` directly.
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
            Task { await self.cancelRegistration(libraryID: libraryID, box: box) }
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
                        // Scoped to this one entry's own box, exactly like
                        // `run(...)`'s cancellation handler -- cancelling one
                        // entry in a batch (e.g. the whole `scanLibraries`
                        // call this entry came from) must never cancel a
                        // *different* caller's already-active scan of the
                        // same `libraryID` that this entry turned out to be
                        // riding on.
                        Task { await self.cancelRegistration(libraryID: entry.libraryID, box: box) }
                    }
                }
            }
        }
    }

    /// Unconditional, source-level cancel: removes any queued entry for
    /// `libraryID` (never running it) and cancels its active task, if any --
    /// regardless of who started that active task or who else is riding on
    /// it. This is the right call for an explicit "stop scanning this
    /// library" request (e.g. a cancel button aimed at one specific
    /// library), but it is deliberately *not* what a `run(...)`/
    /// `runBatch(...)` caller's own cancellation uses -- that goes through
    /// `cancelRegistration(libraryID:box:)` instead, which only tears down
    /// the calling registration itself and never a scan some other caller
    /// started or is still waiting on. Either half here may be a no-op:
    /// cancel is safe to call for a `libraryID` that is only queued, only
    /// active, or not known to the coordinator at all. Because a `libraryID`
    /// is never both active and queued at once (req. 5/10), these two halves
    /// can never collide for the same `libraryID` -- removing a queued
    /// duplicate can never reach into `activeTasks` for that same id, since
    /// no such active entry can exist alongside it.
    ///
    /// A cancelled active task still runs its own `Task<Void, Never>` to
    /// completion cooperatively -- exactly like cancelling the consumer of a
    /// `LibraryScanSequence` directly -- so the slot is only actually
    /// released, and the next queued item started, once that completion
    /// callback re-enters this actor (req. 8). Any riders waiting on that
    /// same active run (see `activeRiders`) resolve at that same point --
    /// this is the one case where cancelling deliberately takes every rider
    /// down with the scan they were all waiting on, because the request here
    /// is explicitly "stop this library", not "stop my own wait".
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
        if let completionBox {
            activeOwnerBoxes[libraryID] = completionBox
        }
        activeTasks[libraryID] = Task {
            await operation()
            self.completed(libraryID: libraryID, completionBox: completionBox)
        }
        maximumObservedActiveCount = max(maximumObservedActiveCount, activeTasks.count)
    }

    private func completed(libraryID: LibraryID, completionBox: CompletionBox?) {
        activeTasks.removeValue(forKey: libraryID)
        activeOwnerBoxes.removeValue(forKey: libraryID)
        resolveIfNeeded(completionBox)
        if let riders = activeRiders.removeValue(forKey: libraryID) {
            for rider in riders { resolveBox(rider) }
        }
        scheduleAvailableSlots()
    }

    /// Cancels exactly the registration identified by `box`, scoped so that
    /// cancelling one caller's own `run(...)`/`runBatch(...)` wait can never
    /// reach past that caller into a scan someone else started or is also
    /// waiting on. Contrast with `cancel(libraryID:)`, which is an
    /// unconditional, source-level "stop scanning this library" -- the right
    /// call for an explicit cancel button, but too broad for "my task got
    /// cancelled" when `libraryID` might be shared with another caller.
    ///
    /// - Already resolved (e.g. this entry was displaced while still queued,
    ///   or its active run/rider group already finished by the time this
    ///   runs): a no-op. `resolveBox(_:)` is never reached, so there is no
    ///   risk of double-resuming `box`'s continuation.
    /// - Still queued: removed like any other queued cancellation, and
    ///   `box` resolves without ever running.
    /// - A rider on someone else's active scan: `box` alone is dropped from
    ///   `activeRiders[libraryID]` and resolved. `activeTasks[libraryID]` is
    ///   never touched -- the scan that started it, and every other rider
    ///   waiting on it, keep running exactly as if this call had never
    ///   happened.
    /// - The owner of the active scan (`box === activeOwnerBoxes[libraryID]`):
    ///   this caller is the one who started the scan, so cancelling it is a
    ///   genuine request to stop that scan -- delegates to
    ///   `cancel(libraryID:)`.
    private func cancelRegistration(libraryID: LibraryID, box: CompletionBox) {
        guard !box.isResolved else { return }

        if let index = queue.firstIndex(where: { $0.libraryID == libraryID && $0.completionBox === box }) {
            queue.remove(at: index)
            resolveBox(box)
            return
        }

        if var riders = activeRiders[libraryID], let riderIndex = riders.firstIndex(where: { $0 === box }) {
            riders.remove(at: riderIndex)
            if riders.isEmpty {
                activeRiders.removeValue(forKey: libraryID)
            } else {
                activeRiders[libraryID] = riders
            }
            resolveBox(box)
            return
        }

        if activeOwnerBoxes[libraryID] === box {
            cancel(libraryID: libraryID)
        }
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
