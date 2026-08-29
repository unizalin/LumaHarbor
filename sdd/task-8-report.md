# Task 8 report — Harden source operations, privacy and Mac regressions

## Status

DONE — implemented via `superpowers:subagent-driven-development` (fresh
implementer subagent, task-scoped reviewer subagent), one Important finding
from review fixed directly by the controller (a genuine concurrency defect
requiring careful analysis of Swift structured-concurrency semantics).
Pending Codex pre-landing review of this branch, matching the pattern
established for Tasks 1-7.

- Baseline HEAD before Task 8 work: `aae9866` (Task 7 fully Codex
  pre-landing-review APPROVED).
- Task 8 stayed within its own boundary, with two file-list entries
  concluded to need no change after reading them in full (documented
  below) rather than being touched speculatively. No Task 9 file
  (`Scripts/run-ipad-library-acceptance.zsh`,
  `docs/testing/reports/2026-08-26-ipad-multi-source-library.md`) was
  created or touched. No push, merge, rebase, or amend was performed at
  any point.

## Commit hashes

- `8de5e44` — fix: harden multi-source library lifecycle (implementer)
- `378f471` — fix: correct the provider-timeout cancellation race
  (controller's fix for the reviewer's Important finding; see below)

## Changed files

- `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift` — three new
  hardening behaviors (provider-request timeout, no-prune-on-offline-mid-scan,
  no-prune-on-index-write-failure), plus the `InspectionRace` concurrency
  fix from review.
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibrarySidebar.swift`
  — Remove (with confirmation), Reconnect…, and Rescan actionable commands.
- `Sources/Localization/Resources/en.lproj/Localizable.strings` /
  `zh-Hant.lproj/Localizable.strings` — 3 new keys, both languages.
- `Tests/PhotoLibraryCoreTests/LibraryRemovalSafetyTests.swift` (new) — 5
  tests proving `removeLibrary(id:)` never touches the source root.
- `Tests/LumaHarborIntegrationTests/MultiSourceFailureRecoveryTests.swift`
  (new) — 4 tests covering scan-time drive removal, provider timeout +
  generation-based retry, index-write-failure prune-safety, and
  multi-source corrupt-RAW continuation.
- `Tests/LumaHarborIntegrationTests/ScanCancellationTests.swift` (modified
  in review-fix round, not in the plan's literal file list — see "Review
  fix" below) — 1 new test proving the timeout mechanism's cancellation
  bridge actually works.
- `Sources/EditorCore/LibraryBrowserSession.swift`: **deliberately not
  modified** — see "Requirement mapping" below.
- `Tests/LumaHarborAppTests/LibraryViewModelTransitionTests.swift`:
  **deliberately not modified** — pre-existing 12-test Mac regression
  suite, read in full, confirmed unaffected by this task's changes; kept
  green as a gate, not extended.
- `sdd/task-8-report.md` (this file)

No other file was modified.

## Requirement-by-requirement mapping (plan Task 8)

### Step 1 — Destructive-safety and failure tests

All five named scenarios covered:

- **Scan-time drive removal**: `FileManager.DirectoryEnumerator` can't
  distinguish "reached the end of the folder" from "the folder vanished
  mid-walk" — both simply stop yielding items, so an interrupted scan
  previously looked like an ordinary complete one and reached the
  destructive prune differential. Fixed with a re-check right before that
  differential: `if !cancelled, !repository.isAvailable { emit(.failed(.offline(...))); return }`,
  mirroring the existing guard that already refuses to *start* a scan on
  an offline source. Tested by `testScanTimeDriveRemovalReportsOfflineAndNeverPrunesExistingRows`
  (RED: 3 of 4 rows pruned after the drive vanished — a real destructive
  bug; GREEN after the fix).
- **30-second provider request timeout via injected clock**: new
  `PhotoLibraryService.providerRequestTimeout: Duration = .seconds(30)`
  and an injectable `providerTimeoutSleep: @Sendable (Duration) async throws -> Void`
  seam (production default: real `Task.sleep`; tests inject a
  deterministically-triggered fake — no real 30-second wait anywhere).
- **Retry generation**: deliberately no dedicated retry loop or counter —
  a timeout resolves to an ordinary `.failure`, so a *later* scan (a fresh
  generation, the same mechanism `queryGeneration` already uses elsewhere
  in this codebase) simply re-inspects the file from scratch. Tested by
  `testProviderRequestTimeoutFailsThatFileThenARetryOnANewGenerationRecoversIt`.
- **Corrupt RAW continuation**: already correct at the single-source
  level (established since Task 3); `testCorruptRawInOneSourceDoesNotAffectAConcurrentlyScanningSource`
  adds coverage at the multi-source/concurrent granularity specifically,
  which had none before.
- **No prune except on complete success**: cancellation was already
  covered (`ScanCancellationTests.testCancelledScanDoesNotPruneExistingRows`).
  Offline-mid-scan (above) and a mid-scan index-write failure are new
  fixes — the latter's existing `catch` around `index.upsert(...)`
  already emitted a failure event but let the scan continue as if nothing
  serious happened; now sets the same `cancelled` flag a genuine
  cancellation already relies on, skipping the differential/manifest/
  `lastScanAt` writes. Tested by `testIndexWriteFailureDuringAScanIsNeverReportedAsACleanCompletion`
  (RED: reported as a clean completion with `lastScanAt` stamped; GREEN
  after the fix).

### Step 2 — Actionable source commands

`PadLibrarySidebar.swift` gained Remove (swipe + context menu, driving a
new `.confirmationDialog` whose message text explicitly states RAW files
and sidecars remain), Reconnect… (context menu, offered only for
`.offline`/`.needsAuthorization` sources, reusing the existing
`.fileImporter` pattern), and Rescan (context menu). All three call
straight into `library` (`LibraryBrowserSession`) — confirmed by reading
the full diff that no `FileManager`/`URL` filesystem API was added to the
view itself. Relink reuses Task 2's existing identity preflight
unchanged (`PhotoLibraryService.relink(libraryID:to:)`); rescan reuses
the existing `scanSource(_:)`/`sourceProgress` path unchanged.

### `LibraryBrowserSession.swift` — confirmed unnecessary, not touched

`removeSource(_:)`, `.relinkSource(_:to:)`, and `.scanSource(_:)` already
existed from Tasks 3/5/6, already route exclusively through
`LibraryBrowserDependencies`'s closures, and already have test coverage.
The new provider-timeout mechanism surfaces as an ordinary
`LibraryScanEvent.photoFailed`, which `handle(_:for:)` already folds into
`sourceProgress[libraryID].failedCount` — no new session-level state was
needed. Read in full before concluding this; not a change made by
omission.

### `removeLibrary(id:)` and cache pruning — confirmed / judgment call

`removeLibrary(id:)` was already correct (only touches `access`/
`libraries`/`restoreDiagnostics` in memory, the bookmark file, and the
SQLite index — never a `FileSidecarRepository` or the source root), now
proven by `LibraryRemovalSafetyTests.swift`'s recording `FileManager`.
Cache pruning on removal was deliberately left out of scope: `DiskCache`
is already a byte-budgeted LRU (`LRUEvictionPlanner`) that self-bounds
regardless of which library a cached thumbnail belongs to — a removed
library's orphaned entries are not a safety issue (nothing private is
newly exposed) and are already bounded, just not *immediately* reclaimed.

## Review round 1 (task-reviewer subagent)

**Verdict on the initial commit (`8de5e44`): Needs fixes** — spec-compliant
overall (all five Step 1 scenarios and all three Step 2 commands genuinely
and correctly implemented, RAW immutability fully preserved, localization
complete, destructive-safety tests real and not restating doc comments),
but 1 Important finding, 0 Critical:

**The provider-timeout race broke real cancellation forwarding for every
file, not just timed-out ones.** `inspectWithTimeout` raced
`Self.inspect(...)` against the timeout via two independent, *unstructured*
`Task { }` blocks. Unstructured tasks don't inherit their enclosing task's
cancellation, so `Self.inspect`'s own `runOffActor` call (whose entire
purpose, per its doc comment, is forwarding "the caller's cancellation...
to the work") never actually received it — cancelling a scan no longer
interrupted whichever file was currently mid-inspection; it just ran to
completion (or hit the 30s timeout) regardless. This didn't corrupt data
(a separate, correctly-placed `!Task.isCancelled` guard before
`index.upsert` already prevented that), so it wasn't Critical, but it
silently defeated a documented, previously-working guarantee.

Several Minor findings were also recorded: an unneeded live 30-second
background sleep task per healthy file (self-resolving once the fix
below lands), a small duplicated destructive-button definition in the
sidebar (swipe action + context menu), and `PhotoLibraryService.swift`'s
already-large file size continuing to grow — none blocking, none fixed in
this round.

## Review fix (commit `378f471`)

Fixing the Important finding took two attempts, both instructive:

**First attempt (rejected before committing):** raced the two sides via a
structured `TaskGroup` instead of unstructured tasks — `TaskGroup`
children *do* inherit cancellation, which fixes the forwarding gap. But a
`TaskGroup` cannot resolve and return before *every* child finishes,
which reintroduces exactly the "block on a non-cooperative provider"
stall the timeout exists to prevent: verified this by actually running
the existing `testNonCooperativeInspectionDiscardsItsResultAndStopsThere`
test against it, which deadlocked (confirmed via `ps` — the test process
sat alive at near-zero CPU for minutes rather than crashing outright).
Diagnosed and discarded before ever being committed.

**Actual fix:** a `withTaskCancellationHandler`-wrapped `InspectionRace`
class that keeps the original fire-and-forget shape (the loser is never
awaited) while bridging real cancellation in: `cancel()` (called from
`onCancel`) immediately resolves the race with `.cancelled` — so
`inspectWithTimeout` never blocks its own return on how long the loser
takes — *and* calls `.cancel()` on the inspection's own `Task` handle,
which `Self.inspect`'s `runOffActor` call does observe, so a *cooperative*
decoder still notices and stops promptly. A genuinely non-cooperative
decoder is simply left running, forgotten, exactly as before.

**New test** (`Tests/LumaHarborIntegrationTests/ScanCancellationTests.swift`
— not in Task 8's literal file list, added as a bounded, documented
addition per this branch's established convention, since the existing
`testCancellingDuringMetadataReadStopsTheScan` calls `gate.release()`
immediately after cancelling and so can't distinguish "cancellation
reached the in-flight decode promptly" from "the gate was released
anyway"):
`testCancellingWhileACooperativeDecodeIsInFlightInterruptsItWithoutEverReleasingTheGate`
— cancels a scan mid-inspection and never releases the gate at all,
asserting the scan settles in well under 1 second (the gate's own
internal ceiling is 5 seconds). RED confirmed against the original
unstructured-`Task` shape (elapsed 5.006s — the gate's ceiling, proving
cancellation never reached it); GREEN against the fix (elapsed 0.015s).

### Verification (review fix)

- `swift test --filter 'ScanCancellationTests'` — 7/7 pass (6 pre-existing
  + 1 new), including `testNonCooperativeInspectionDiscardsItsResultAndStopsThere`
  (0.23s, no hang).
- `swift test --filter 'MultiSourceFailureRecoveryTests|LibraryRemovalSafetyTests'`
  — 9/9 pass.
- `swift test` (full suite) — 1090 tests / 9 skipped / 0 failures (1089 →
  1090).
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
  — succeeds, no warnings.
- `git diff --check` — clean.
- `(cd Apps/LumaHarborPad.swiftpm && xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build)`
  — **BUILD SUCCEEDED**.

## Verification (full task, both rounds)

- `swift test --filter 'LibraryRemovalSafetyTests|MultiSourceFailureRecoveryTests'`
  — 9/9 pass.
- `swift test --filter 'LibraryViewModelTransitionTests|LibraryLifecycleTests|ThumbnailProviderTests'`
  — 49/49 pass; no Mac selection/autosave/cache/scan test changed output.
- `swift test --filter 'ScanCancellationTests'` — 7/7 pass.
- `swift test` (full suite) — 1090 tests / 9 skipped (pre-existing,
  unrelated environment skips) / 0 failures.
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
  — succeeds, no warnings.
- `git diff --check` — clean.
- `(cd Apps/LumaHarborPad.swiftpm && xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build)`
  — **BUILD SUCCEEDED**.

Full RED/GREEN transcripts for every new test, and the implementer's own
detailed working notes, are preserved in this worktree's internal scratch
report (not repo-tracked, per this session's `subagent-driven-development`
convention): `sdd/task-8-report.md` under
`.git/worktrees/codex-ipad-multi-source-library-durability/`.

## An environment flake investigated and ruled out

During verification, `swift test` intermittently crashed with
`SIGBUS`/`EXC_BAD_ACCESS` inside Foundation's `URLResourceValues`
handling, always inside the unrelated, pre-existing
`PadLibraryCompositionContractTests` test. Bisected by disabling each new
test and even the entire `PhotoLibraryService.swift` diff — still
reproduced, then vanished permanently after `swift package clean` (6
clean runs afterward, with and without the new tests, all passed). A
controller-run, fully isolated `swift test` (no other `swift-build`/
`swift-test` process contending for the `.build` directory) also passed
cleanly with 0 failures, independently corroborating the toolchain/lock-
contention diagnosis rather than a logic defect. Multiple concurrent
`swift-test`/`xctest` processes were observed contending for the same
`.build` lock during this task's review, which independently explains
both this flake and an intermittent build-lock stall the reviewer hit —
not a defect in the diff.

## Remaining concerns

- **Minor findings from review round 1 not fixed**: a duplicated
  destructive-button definition in `PadLibrarySidebar.swift` (swipe
  action + context menu, idiomatic for SwiftUI and low-value to
  deduplicate); `PhotoLibraryService.swift`'s continued growth (1911+
  lines) — worth splitting scan-inspection concerns into their own file
  in a future task if it keeps growing.
- **Cache pruning on `removeLibrary`** remains an intentional non-goal,
  covered above — flagged for the record, not an action item.
- **`LibraryViewModelTransitionTests.swift` and `LibraryBrowserSession.swift`**
  were both read in full and deliberately left unmodified after concluding
  neither needed a change for this task — noted here so a reviewer doesn't
  mistake the absence of a diff in either file for an oversight.

## Not push / merge / rebase / Task 9

- No `git push`, `git merge`, `git rebase`, or `git commit --amend` was
  run at any point, across any commit in this task.
- No Task 9 file was created or modified.
- Commits from this task: `8de5e44` (implementation), `378f471`
  (review fix), and `<this commit>` (this report).
