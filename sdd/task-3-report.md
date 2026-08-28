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
