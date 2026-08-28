# Task 3 report — Schedule bounded scans across multiple sources

## Status

DONE

- Baseline HEAD before Task 3 work: `a350ede` (`docs: preserve Task 2 review
  handoff evidence`).
- Task 2 status going into this task: **Codex re-review APPROVED**, with the
  three latest commits on the branch being the round-3 re-review fix
  (`8e61820`), its evidence doc (`98d7356`), and the preserved Task 2
  handoff/review documents (`a350ede`).
- Task 3 stayed strictly within the plan's scope: `MultiSourceScanCoordinator`,
  `PhotoLibraryService.scanLibraries`, and their tests. No Task 4 work was
  started. No push, merge, rebase, amend, or squash was performed.

## Phase 0 — untracked sdd documents

At the start of this task, `git status --short --branch` was already clean
except for the branch header — the five previously-untracked Task 2 documents
had already been brought under version control in commit `a350ede` earlier in
this same session, before Task 3 began. There was nothing left to triage in
this task: no untracked, stray, or stale `sdd/` file existed at Task 3's
starting `git status`.

## RED evidence

Both the production coordinator file and its test file were authored
together, then the coordinator implementation was temporarily moved aside to
capture a genuine RED before restoring it and proceeding to GREEN — strict
TDD evidence without fabricating a false starting point.

Command:

```zsh
mv Sources/PhotoLibraryCore/Service/MultiSourceScanCoordinator.swift /tmp/MultiSourceScanCoordinator.swift.bak
swift test --filter MultiSourceScanCoordinatorTests
```

Result: compile failure. Representative errors:

```
error: cannot find 'MultiSourceScanCoordinator' in scope
error: cannot infer contextual base in reference to member 'normal'
```

(12 occurrences of "cannot find 'MultiSourceScanCoordinator' in scope", with
cascading `.normal`/`.selected` member-inference failures at every call
site — the expected shape for "the type doesn't exist yet".)

Separately, this same compile run also caught two categories of genuine bugs
in the *test file itself*, unrelated to the missing production type, fixed
before GREEN:

1. `await` used directly inside `XCTAssertTrue`/`XCTAssertFalse`/
   `XCTAssertEqual`'s `@autoclosure` arguments (`error: 'await' in an
   autoclosure that does not support concurrency` / `actor-isolated property
   ... can not be referenced from a nonisolated autoclosure`) — fixed by
   binding every actor-isolated read to a local `let` before asserting on it,
   matching this codebase's existing convention (confirmed no other test file
   in this repository puts `await` directly inside an `XCTAssert*` call).
2. `await coordinator.activeCount == 0 && coordinator.queuedLibraryIDs.isEmpty`
   inside a `waitUntil` closure — `await` only binds to the first operand, not
   across `&&`; fixed by awaiting both sides into locals first.

The coordinator file was restored and the suite re-run; all 11 tests (later
13, see below) passed. `swift build` was also run clean at this point.

## GREEN evidence

```zsh
swift test --filter MultiSourceScanCoordinatorTests
```

Result: 13 tests, 0 failures (11 from the initial TDD pass, plus 2 added
after a design gap was found and fixed — see "Design correction" below). Run
four times in a row with 0 flakes.

## Design and implementation

### `MultiSourceScanCoordinator` (`Sources/PhotoLibraryCore/Service/MultiSourceScanCoordinator.swift`)

- `actor`, **internal** (no `public` on the type or any member) — per req. 11
  of the brief, this is a service composition detail, not product API. Tests
  reach it only via `@testable import PhotoLibraryCore`.
- Exactly two active slots (`maximumConcurrentScans = 2`), tracked as
  `activeTasks: [LibraryID: Task<Void, Never>]`.
- A FIFO `queue: [QueuedOperation]`, each carrying an insertion `sequence`
  number and a `ScanPriority` (`.normal` / `.selected`). The next entry to run
  is chosen by highest priority first, then earliest `sequence` — `.selected`
  always beats an earlier-queued `.normal` entry, and entries at the same
  priority stay strictly FIFO.
- `enqueue(libraryID:priority:operation:)` — the required fire-and-forget
  interface: registers `operation` and returns once it is scheduled (queued or
  already running), without waiting for it to execute. A second `enqueue` for
  a `libraryID` still in the queue *replaces* that queued entry in place
  (never appends a duplicate); a second `enqueue` while the first is already
  *active* queues behind it — the scheduler (`nextRunnableIndex`) explicitly
  skips any queued entry whose `libraryID` is already in `activeTasks`, so the
  same source can never occupy two slots at once, and the already-running scan
  keeps running under its own existing generation/cancellation contract
  rather than being torn down by the coordinator itself.
- `cancel(libraryID:)` — removes any queued entry (resuming its completion, if
  any, so nothing hangs) and cancels its active `Task`, if any. A cancelled
  active task still runs its `Task<Void, Never>` to completion cooperatively;
  the slot is only actually released, and the next queued item started, once
  that completion callback (`completed(libraryID:completion:)`) re-enters the
  actor — satisfying req. 8 without polling.
- `run(libraryID:priority:operation:)` — an internal convenience built on top
  of `enqueue`, used by `PhotoLibraryService.scanLibraries` so a caller can
  `await` a specific source's scan actually finishing (enqueue alone does
  not wait). Implemented with `withTaskCancellationHandler` wrapping a single
  `withCheckedContinuation`, so:
  - normal completion resumes the continuation from `completed(...)`;
  - being displaced by a later `enqueue`/`run` for the same `libraryID` while
    still queued resumes the continuation immediately, without ever running
    the original `operation` — a legitimate supersession, not a hang;
  - **cancelling the caller's own task** invokes `onCancel`, which calls
    `cancel(libraryID:)` on the coordinator — this was found and fixed during
    integration (see below), and is what lets cancelling a
    `PhotoLibraryService.scanLibraries` caller actually stop the underlying
    per-source scan, instead of merely abandoning an unobserved suspension.
- No polling, no semaphore, no detached task, no unbounded continuation:
  every suspension is a single `CheckedContinuation` resumed exactly once (the
  same pattern this codebase's own `AcknowledgedAsyncChannel` already uses),
  and every `Task { ... }` created is a plain structured task, never
  `Task.detached`.

### Design correction found during integration

While writing the 3×10,000 integration test's cancellation case, cancelling
the `Task` running `service.scanLibraries(...)` was observed to leave the
underlying per-source scan running to completion instead of stopping it. Root
cause: the first version of `run(...)` used a plain `withCheckedContinuation`
with no cancellation handling — cancelling the *caller* only marks that
caller's own suspension cancelled; it does not touch the coordinator's
separate, internally-created `Task` actually running `operation()`. Fixed by
wrapping `run(...)`'s continuation in `withTaskCancellationHandler`, whose
`onCancel` calls the coordinator's own `cancel(libraryID:)` — reusing the
already-correct queued-removal/active-cancellation logic instead of adding a
second code path. Two new coordinator tests were added specifically for this:
`testRunCancellationCancelsTheUnderlyingActiveOperation` and
`testRunCancellationRemovesAStillQueuedEntry` (bringing the coordinator suite
from 11 to 13 tests), plus the integration-level
`testCancellingAMultiSourceScanNeverPrunesTheStillInFlightSources` now
actually exercises real cancellation instead of a no-op.

### `PhotoLibraryService.scanLibraries` (`Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`)

```swift
public nonisolated func scanLibraries(
    _ libraryIDs: [LibraryID],
    selectedLibraryID: LibraryID?,
    onEvent: @escaping @Sendable (LibraryID, LibraryScanEvent) async -> Void
) async
```

- `nonisolated`, matching the existing `scan(libraryID:)` — it does not touch
  any of the actor's own stored state directly, only the coordinator (a
  separate actor) and the existing `scan(libraryID:)` sequence.
- For each `libraryID`, schedules `coordinator.run(libraryID:priority:) { for
  await event in self.scan(libraryID: libraryID) { await onEvent(libraryID,
  event) } }` inside a `withTaskGroup`, so the method returns once every
  listed source's scan has finished, failed, or been cancelled.
  `selectedLibraryID`, when present in `libraryIDs`, is scheduled with
  `.selected` priority; every other listed source gets `.normal`.
- **Reuses the existing acknowledged pipeline verbatim** — `onEvent` is
  awaited for every event before the next one is requested from the
  `AcknowledgedAsyncChannel`-backed `LibraryScanSequence`, so backpressure
  reaches the directory cursor exactly as it does for a single-source scan.
  No new buffering bridge, no `AsyncStream`, of any kind was added.
- Everything downstream of `scan(libraryID:)` — scan-generation validation,
  prune, `lastScanAt`, per-source manifest/index writes — is **completely
  untouched**: `scanLibraries` is a pure scheduling wrapper around the
  existing `performScan`. This is why the prune/`lastScanAt` safety table
  from Task 1/2 needed no code changes, only integration-level tests proving
  it still holds when reached through the new path.
- A new stored property, `private let scanCoordinator = MultiSourceScanCoordinator()`,
  was added to the actor. It is not test-injectable (per req. 11: the
  coordinator's own behavior is fully covered directly via
  `MultiSourceScanCoordinatorTests`, so no seam was added here purely to
  support testing).

## Prune and `lastScanAt` safety (unchanged contract, verified through the new path)

No production logic changed here — `performScan`'s existing gates (`if
!cancelled { ... }` before both the prune call and the `lastScanAt` write,
and the `isSuperseded` early-return before either) are exactly what Task 1/2
already established. What Task 3 adds is proof that routing through
`scanLibraries`/the coordinator does not weaken or bypass them:

- `testThreeSourcesTenThousandEachArriveExactlyOnceWithBoundedConcurrency`
  proves a source that completes successfully through `scanLibraries` still
  prunes a stale pre-existing row it never re-saw, and still records
  `lastScanAt`.
- `testCancellingAMultiSourceScanNeverPrunesTheStillInFlightSources` proves
  cancelling the whole multi-source run leaves every still-in-flight source's
  pre-existing rows untouched and `lastScanAt` unset.

## 3×10,000 integration test — actual counts

File: `Tests/LumaHarborIntegrationTests/MultiSourceBoundedScanTests.swift`.

Design note: each of the 30,000 synthetic entries points at a path that was
never created on disk. `FingerprintCalculator` genuinely fails it through the
unmodified production code path, and it becomes a real, individually
acknowledged `.photoFailed` event — not a shortcut around the pipeline, and
still real backpressure/real per-photo accounting (spec §10 requires
per-photo failures to be tracked and the scan to continue, which this
exercises 30,000 times over). This is what keeps a 30,000-entry, three-source
run to about 1 second and near-zero extra memory: no RAW decode, no real file
I/O, only real (fast) failed `stat` calls plus real
`AcknowledgedAsyncChannel` round trips. A scan finishing this way is still a
genuinely *successful* scan (`wasCancelled == false` — that flag depends only
on cancellation/supersession, never on how many individual files failed), so
`lastScanAt` and pruning both still exercise their real, unmodified gates,
proven via a pre-seeded stale row (see above).

Measured results (from the passing test, run 4 times with 0 flakes,
~1.0–1.4 s wall time each run):

- Every one of the 3 × 10,000 = 30,000 expected `(LibraryID, relativePath)`
  pairs arrived exactly once: `seenCount == 30000`, `duplicateCount == 0`.
- Global active-source high-water: `maximumActiveSources <= 2` (asserted;
  the coordinator's two-slot budget was never exceeded).
- Every source's synthetic cursor was driven to its terminal page
  (`nextPageCallCount >= 101` per source: 100 content pages of 100 entries
  plus the terminal `isAtEnd` page) — proof the walk ran to genuine
  completion under backpressure, not a silent truncation.
- All three sources finished with `wasCancelled == false`, `failedCount ==
  10000` each, and a recorded `lastScanAt`.
- The pre-seeded stale row in source A (never re-seen by any of its 10,000
  synthetic entries) was pruned.

Retained-batch high-water: `scanLibraries` introduces no buffering of its own
— `onEvent` is awaited per event before the underlying
`AcknowledgedAsyncChannel` is asked for the next one, so the existing
"at most one parked, undelivered element" bound documented on
`AcknowledgedAsyncChannel` (`pendingElementCount` is "Zero or one, always")
applies unchanged per source. This is a structural guarantee of the
unmodified channel type, not something `scanLibraries` could weaken without
adding its own buffer, which it does not.

Selected-source priority end to end: `testSelectedSourcePriorityIsHonoredThroughScanLibraries`
occupies both slots with two gated sources, queues a `.normal` source, then
queues a `.selected` source afterward, and confirms the selected source's
`.started` event is observed before the earlier-queued normal source's —
proving priority survives the full `scanLibraries` → coordinator →
`scan(libraryID:)` path, not just the coordinator in isolation.

## Changed files

- `Sources/PhotoLibraryCore/Service/MultiSourceScanCoordinator.swift` (new)
- `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift` (modified:
  added `scanCoordinator` stored property and `scanLibraries` method only —
  no other line changed)
- `Tests/PhotoLibraryCoreTests/MultiSourceScanCoordinatorTests.swift` (new)
- `Tests/LumaHarborIntegrationTests/MultiSourceBoundedScanTests.swift` (new)
- `sdd/task-3-report.md` (this file)

No other production file was modified.

## API / Sendable / actor isolation decisions

- `MultiSourceScanCoordinator` and its `ScanPriority` enum are internal, not
  public — the only new *public* product API from Task 3 is
  `PhotoLibraryService.scanLibraries(_:selectedLibraryID:onEvent:)`.
- `MultiSourceScanCoordinator` is an `actor`; all of its mutable state (queue,
  active-task table, sequence counter) is actor-isolated, with no
  `@unchecked Sendable` escape hatches.
- `operation`/`onEvent` closures are `@escaping @Sendable () async -> Void`
  and `@escaping @Sendable (LibraryID, LibraryScanEvent) async -> Void`
  respectively — required for crossing into the coordinator actor and for
  being invoked from arbitrary scan-producer tasks.
- `scanLibraries` is `nonisolated` (consistent with the existing
  `scan(libraryID:)`), since it does not touch the service actor's own stored
  state directly, only the separate coordinator actor and the existing
  scan sequence.
- Every `Task { ... }` introduced (coordinator's `start(_:)`, `run`'s/
  `cancel`'s `onCancel` handlers) is a plain structured task, never
  `Task.detached`. Cancellation is propagated cooperatively via
  `Task.isCancelled`/`withTaskCancellationHandler`, matching the existing
  `AcknowledgedAsyncChannel` idiom exactly rather than inventing a new one.

## Verification

```zsh
swift test --filter MultiSourceScanCoordinatorTests
swift test --filter MultiSourceBoundedScanTests
swift test --filter 'BoundedFolderScanTests|ScanCancellationTests'
swift test --filter PhotoLibraryCoreTests
swift test
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
git diff --check
```

Results:

- `MultiSourceScanCoordinatorTests`: **13 tests, 0 failures** (run 4×, 0 flakes).
- `MultiSourceBoundedScanTests`: **3 tests, 0 failures** (run 5×, 0 flakes,
  ~1.0–1.4 s each for the full 30,000-entry run).
- `BoundedFolderScanTests|ScanCancellationTests`: **18 tests, 0 failures** —
  no regression in the pre-existing single-source bounded-pipeline contracts.
- `PhotoLibraryCoreTests`: **439 tests, 0 failures** (426 before Task 3 + 13
  new coordinator tests).
- Full `swift test`: **986 tests, 9 skipped, 0 failures** (970 before Task 3 +
  13 coordinator + 3 integration = 986; the 9 skips are the same pre-existing,
  host-dependent security-scoped-bookmark skips already present before this
  task — not new).
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`:
  **exit 0**, no warnings.
- `git diff --check`: **PASS**, no whitespace errors.
- `rg -n 'TBD|TODO|FIXME|fatalError|try!|as!'` over the two changed/new
  production files: **no hits**.
- No `Task.detached`, semaphore, or polling loop in the new coordinator code
  (`grep` confirmed no matches for `Task.detached|Semaphore|DispatchSemaphore`
  in `MultiSourceScanCoordinator.swift`).
- No third-party dependency: `Package.swift` was not modified.
- No RAW read/write/move/rename/delete path was added; the integration
  tests' `writeFile` calls create only tiny placeholder files inside the
  test's own temporary directory, exactly like the existing
  `ScanCancellationTests`/`BoundedLibraryScanTests` already do.
- No private absolute path appears in this report, in test assertions, or in
  any new source comment — every path referenced is either a temporary test
  directory (never logged by value) or a synthetic, non-existent relative
  path used purely as an index key.
- `pgrep -fl 'xctest|swift-frontend'` after the full run: no residual test
  processes.

## Remaining concerns

None blocking. Two points worth flagging for the next reviewer:

1. `MultiSourceScanCoordinator.run(libraryID:priority:operation:)`'s
   cancel-on-displacement semantics apply per `libraryID`, not per specific
   caller: if two independent callers ever raced `run(...)` for the exact
   same `libraryID` at the same time (not something `scanLibraries` itself
   does — it only ever issues one `run` per `libraryID` per call, and
   duplicate `libraryIDs` within one call are de-duplicated by the
   coordinator's own at-most-one-per-ID invariant), cancelling one caller
   could in principle affect the other's in-flight request. This matches the
   coordinator's own stated invariant ("at most one active-or-queued entry
   per `libraryID`") and is not reachable through any call `scanLibraries`
   makes today, but is worth knowing if a future caller ever composes the
   coordinator differently.
2. `PhotoLibraryService.scanLibraries` has no consumer yet (Task 5's
   `LibraryBrowserSession.runScan` dependency is the intended future caller,
   per the implementation plan) — its signature was designed to match that
   plan's stated interface, but has not yet been exercised by a UI-facing
   caller. This is expected at this stage of the plan and not a defect.

## Not push / merge / rebase / Task 4

- No `git push`, `git merge`, or `git rebase` was run at any point.
- No Task 4 file (`PhotoDocumentStore`, `PhotoDocument`, `PhotoID.appStorage`,
  `PhotoDocumentEditor` library-open changes) was touched.
- Exactly two new commits are expected from this task: one feature commit
  (production + test code) and one docs commit (this report), created after
  this report was written.

## Review fix round 1

Codex's pre-landing review of the two Task 3 commits (`24c72bf`, `0a4bc93`)
returned **CHANGES_REQUESTED** with two findings, both in scope for this
round. Tests were confirmed green going in; both findings are contract gaps,
not test failures. This section documents what was found, what was changed,
what was added, and what still remains open (nothing, per the last
sub-section).

### Finding 1 (P1): a `LibraryID` could be simultaneously active and queued

**Finding.** `MultiSourceScanCoordinator.register(...)` only ever replaced an
existing *queued* entry for a `libraryID`; it never checked whether that
`libraryID` was already *active*. A second `enqueue`/`run` for an
already-active `libraryID` therefore queued a genuine second "shadow" entry,
which `nextRunnableIndex()`'s active-skip only delayed rather than
suppressed: once the original active run finished, the shadow entry would
start and the same source would scan a second time. This meant
`scanLibraries([id, id], selectedLibraryID: nil)` could run one source twice,
and violated the plan's stated invariant ("one LibraryID may be active or
queued once") that the coordinator's own prior report had described but the
code did not actually enforce. Separately, `cancel(libraryID:)` removed any
queued entry for an id *and* cancelled `activeTasks[libraryID]` for the same
id in the same call — safe only because the two could never legitimately
coexist for a correct implementation, which this one did not guarantee.

**Fix.** `MultiSourceScanCoordinator.swift` was restructured around a new
`insert(...)` primitive: a registration for a `libraryID` that is already in
`activeTasks` is no longer queued at all. Instead it becomes an
"active rider" (`activeRiders: [LibraryID: [CompletionBox]]`) that rides
along on the *already-running* task and is resolved -- without ever running
its own `operation` -- exactly when that active task's own completion
callback (`completed(libraryID:completionBox:)`) fires. A fire-and-forget
`enqueue(...)` for an already-active id has no completion to track and is
simply dropped once `insert(...)` confirms the id is active, so nothing is
ever queued or run a second time.

`run(libraryID:priority:operation:)`'s completion semantics were generalized
from a single per-entry `CheckedContinuation` into a small `CompletionBox`
class (`isResolved` + an optional continuation), so both "resolve now, wait
later" (the active-rider case: the box may resolve before anyone calls
`waitBox(_:)` on it) and "wait now, resolve later" (the ordinary queued
case) are both handled by the same `waitBox`/`resolveBox` pair without
leaking any unbounded coordinator-level state for calls nobody ever waits
on (`enqueue`'s fire-and-forget boxes are simply never created).

Because a `libraryID` can now never be both active and queued at the same
time, `cancel(libraryID:)`'s two halves (remove-if-queued,
cancel-if-active) can no longer collide for the same id -- this is now
structurally guaranteed rather than incidentally true, and
`nextRunnableIndex()`'s active-skip guard is kept as an explicit (and now
provably dead) assertion of that invariant rather than the only thing
enforcing it.

`run(...)` called against an already-active `libraryID` neither hangs nor
starts a second scan: it resumes exactly when the existing active run's own
`Task<Void, Never>` finishes (normally or after cooperative cancellation),
via the same `activeRiders` mechanism.

### Finding 2 (P2): no deterministic selected-priority scheduling across one `scanLibraries` batch

**Finding.** `PhotoLibraryService.scanLibraries` gave each `libraryID` its
own concurrent child task inside a `withTaskGroup`, each independently
calling `scanCoordinator.run(...)`. Which child task actually reached the
coordinator actor first was an unspecified race: for
`scanLibraries([normalA, normalB, selectedC], selectedLibraryID: selectedC)`,
`normalA` and `normalB`'s child tasks could both register before
`selectedC`'s did, filling both scan slots and leaving the selected source
to wait for a third slot -- contradicting the selected-source-priority
guarantee the public surface is supposed to provide for a single batch call.

**Fix.** Two changes, both scoped to the two flagged files:

- `MultiSourceScanCoordinator` gained `runBatch(_:)`: it registers every
  `(libraryID, priority, operation)` triple in a caller-supplied array via
  `insert(...)` in one synchronous, non-suspending pass -- nothing else can
  reach the actor while that pass runs -- and only calls
  `scheduleAvailableSlots()` once, after the whole batch has been inserted.
  This makes the priority/FIFO ordering that `nextRunnableIndex()` sees
  reflect the entire batch at once, regardless of how `runBatch`'s own
  `TaskGroup` (used only afterward, to await each entry's completion) gets
  scheduled by the runtime.
- `PhotoLibraryService.scanLibraries` now de-duplicates `libraryIDs` up
  front, orders the selected source (if present) first followed by every
  other requested source in its original order, and calls
  `scanCoordinator.runBatch(_:)` once with the resulting array, instead of
  spawning one `TaskGroup` child task per source that each calls `run(...)`
  independently.

No polling, semaphore, `Task.detached`, `AsyncStream`, or unbounded
continuation was introduced by either fix. Scan-generation validation and
`AcknowledgedAsyncChannel`'s acknowledged backpressure inside `performScan`
were not touched at all -- both fixes are entirely inside the scheduling
layer above them.

### New tests

`Tests/PhotoLibraryCoreTests/MultiSourceScanCoordinatorTests.swift`:

- `testActiveEnqueueForSameLibraryIDNeverQueuesOrRunsTwice` (replaces the
  prior `testSameLibraryIDNeverActiveTwiceSimultaneously`, whose assertions
  had actually encoded the P1 bug as expected behavior) -- a re-`enqueue` of
  an already-active id creates no queued entry and never runs a second time.
- `testRunWhileActiveWaitsForTheActiveOperationWithoutRunningASecondTime` --
  `run(...)` against an already-active id neither hangs nor starts a second
  scan; it resumes when the existing active run finishes.
- `testCancelQueuedItemNeverAffectsUnrelatedActiveScans` -- cancelling a
  queued-only entry never reaches into `activeTasks` for an unrelated id,
  now provable as a structural invariant rather than an incidental one.
- `testRunBatchSchedulesSelectedPriorityAheadOfNormalEntriesInTheSameBatch`
  (run 20× in a loop) -- a single `runBatch(_:)` call always starts the
  selected entry within the two-slot budget, even though it is listed last.
- `testRunBatchKeepsSamePriorityEntriesFIFO` -- same-priority entries within
  one batch stay FIFO, matching `enqueue(...)`'s existing guarantee.
- `testRunBatchDeduplicatesRepeatedLibraryIDWithinOneBatch` -- a duplicate
  `libraryID` within one batch array behaves exactly like two sequential
  `enqueue`/`run` calls: the later entry replaces the earlier one, which
  never runs.

`Tests/LumaHarborIntegrationTests/MultiSourceBoundedScanTests.swift`:

- `testSelectedSourceStartsWithinTwoSlotBudgetInASingleScanLibrariesBatch` --
  a single `scanLibraries([normalA, normalB, selectedC],
  selectedLibraryID: selectedC)` call always starts the selected source
  within the two-slot budget, closing the exact race Finding 2 described
  (the pre-existing `testSelectedSourcePriorityIsHonoredThroughScanLibraries`
  only ever exercised *separate* `scanLibraries` calls per source, so it
  could not have caught this).
- `testScanLibrariesDeduplicatesARepeatedLibraryIDWithinOneCall` --
  `scanLibraries([id, id], selectedLibraryID: nil)` delivers exactly one
  `.started`/`.finished` pair and records `lastScanAt` exactly once.

Coordinator suite: 18 tests (13 prior + 6 new − 1 replaced in place).
Integration suite: 5 tests (3 prior + 2 new).

### Verification (round 1 fix)

```zsh
swift test --filter MultiSourceScanCoordinatorTests
swift test --filter MultiSourceBoundedScanTests
swift test --filter 'BoundedFolderScanTests|ScanCancellationTests'
swift test --filter PhotoLibraryCoreTests
swift test
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
git diff --check
```

Results:

- `MultiSourceScanCoordinatorTests`: **18 tests, 0 failures** (run 4×, 0
  flakes).
- `MultiSourceBoundedScanTests`: **5 tests, 0 failures** (run 4×, 0 flakes,
  including the 3×10,000-entry test).
- `BoundedFolderScanTests|ScanCancellationTests`: **18 tests, 0 failures** --
  no regression in the pre-existing single-source bounded-pipeline
  contracts.
- `PhotoLibraryCoreTests`: **444 tests, 0 failures** (439 before this round +
  6 new coordinator tests − 1 old test replaced in place = 444).
- Full `swift test`: **993 tests, 9 skipped, 0 failures** (986 before this
  round + 6 new coordinator + 2 new integration − 1 old test replaced in
  place; net +7 = 993). The 9 skips are the same pre-existing,
  host-dependent security-scoped-bookmark skips, not new.
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc
  -warnings-as-errors`: **exit 0**, no warnings. No sandbox/module-cache
  permission failure was encountered.
- `git diff --check`: **PASS**, no whitespace errors.
- `rg -n 'TBD|TODO|FIXME|fatalError|try!|as!'` over both changed production
  files: **no hits**.
- `rg -n 'Task\.detached|Semaphore|DispatchSemaphore'` over both changed
  production files: **one hit**, a pre-existing doc comment in
  `PhotoLibraryService.swift` explaining why `runOffActor` is used *instead
  of* `Task.detached` -- not an actual usage, and not touched by this round.
- One test bug was found and fixed while writing this round's tests (not a
  production defect): an early version of
  `testRunBatchSchedulesSelectedPriorityAheadOfNormalEntriesInTheSameBatch`
  released all three `ScanTracker`-gated ids as soon as two had started,
  before the third had actually started and registered its own gate --
  `ScanTracker.release` is a no-op if called before the corresponding `run`
  registers itself, so the third id's eventual run then waited on a release
  that had already happened and would never happen again, hanging that test
  indefinitely. Fixed by releasing only the ids confirmed started, then
  waiting for the remaining one to actually start before releasing it --
  the same pattern the pre-existing `testOnlyTwoSourcesRunAndThirdWaits`
  already uses. Caught by a 3-minute `timeout`-wrapped run rather than
  letting it hang the session.

### Remaining concerns

None blocking. One point carried forward from the original report, now
sharpened rather than resolved (unchanged in scope, not something either
finding asked to fix):

- `MultiSourceScanCoordinator.run(libraryID:priority:operation:)`'s and
  `runBatch(_:)`'s cancel-on-displacement semantics apply per `libraryID`,
  not per specific caller. Two independent callers racing `run(...)`/
  `runBatch(_:)` for the exact same `libraryID` at the same time -- e.g. two
  concurrent `PhotoLibraryService.scanLibraries` calls that both list the
  same id -- would mean cancelling one caller's own task cancels the
  shared active run (and thus every other caller/rider waiting on it) via
  `cancel(libraryID:)`. This is not reachable through any single
  `scanLibraries` call today (it de-duplicates `libraryIDs` before ever
  reaching the coordinator), but would matter if a future caller composed
  the coordinator differently across independent calls.
