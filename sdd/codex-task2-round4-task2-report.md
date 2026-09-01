# Codex Task 2 Round 4 — Task 2 report

## Status

DONE pending independent review. No push, merge, rebase, amend, or product Task 3 work was performed.

## Design delivered

- Added an atomic, Codable single-pending transaction journal at
  `Application Support/LumaHarbor/registry-transactions/pending.json`.
- Journal records contain a transaction UUID, `LibraryID`, bounded operation
  kind (`freshAdd`, `focus`, `relink`, `restoreRefresh`), old/intended bookmark,
  and old/intended index-library snapshots.
- The journal directory is created with other Application Support locations
  and is intentionally excluded from `removeRebuildableData()`.
- Scoped mutations now follow prepare journal → bookmark forward write → index
  forward write → clear journal commit point → nonthrowing actor/access commit.
- Forward or commit-point failure rolls back to the old bookmark/index state.
  Rollback attempts both stores, remains idempotent, and clears the journal only
  after both succeed.
- Failed rollback/cleanup preserves the journal, returns the path-free
  `LibraryError.registryRecoveryRequired`, and blocks add/focus/relink/restore,
  removal, availability mutation, scans, and edit reads/writes until recovery.
- A fresh service using the same Application Support recovers before its first
  restore/add/relink mutation. Public `recoverPendingRegistryChanges()` also
  permits an explicit same-session retry.
- Restore-time stale bookmark refresh and confirmed-ID backfill use the same
  journal. Successful recovery keeps the source old/blocked rather than
  promoting a half-updated source to ready.
- Fresh-add collision checks now include actor state, exact bookmark, SQLite
  library row, and photo rows even when the library row is absent.
- Existing-source rollback preserves exact photo rows. Fresh-add rollback may
  remove all rows only after its collision gate proved no old durable rows.

## TDD evidence

### RED 1 — journal format/location

`swift test --filter LibraryRegistryTransactionTests`

- Expected compile failure: `RegistryTransactionRecord`,
  `LibraryFolderSnapshot`, `FileRegistryTransactionStore`, and
  `registryTransactionsDirectoryURL` did not exist.
- After the smallest implementation, the first runtime attempt exposed Date
  precision in the fixture; the fixture was made deterministic and the
  round-trip became GREEN.

### RED 2 — SQLite collision

`swift test --filter LibraryRegistryTransactionTests`

- Orphan library+photo candidate was incorrectly accepted and overwrote the
  old library metadata.
- Orphan photo-only candidate was incorrectly accepted and created a new
  library row over the existing photo namespace.
- After checking both `index.library(id:)` and `photoCount(inLibrary:)`, both
  cases reject with zero mutation.

### RED/GREEN 3 — durable rollback

Focused failure injection covered:

- journal prepare failure;
- fresh-add index failure plus rollback bookmark-remove failure;
- same-session recovery;
- fresh-service restart recovery in the same Application Support;
- focus index failure plus rollback bookmark-save failure;
- journal cleanup failure after both forward writes;
- journal-only, intended-bookmark-only, and intended-bookmark+index partial
  phases;
- repeated/idempotent recovery;
- old index metadata absent with orphan photos present;
- pending recovery blocking focus, relink, restore, scan, edit read/write, and
  a second add;
- successful add/focus/relink leaving no journal.

All above are GREEN in `LibraryRegistryTransactionTests` (11/11).

## Test updates

- Replaced two old recovery tests that explicitly accepted a failed operation
  becoming the new successful state after restart.
- Restore persistence-failure fixtures now fail only the intended forward
  save, allowing the journal rollback to restore the old bookmark and proving
  the approved rollback-to-old policy.

## Verification

- Focused Task 2 suites: 119 tests, 0 failures.
- Relink/lifecycle suites: 26 tests, 0 failures.
- `swift test --filter PhotoLibraryCoreTests`: 418 tests, 0 failures.
- Full `swift test`: 962 tests, 9 skipped, 0 failures.
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`: PASS.
- `git diff --check`: PASS.

## Changed files

- `Sources/PhotoLibraryCore/Access/ApplicationSupportLocations.swift`
- `Sources/PhotoLibraryCore/Access/RegistryTransactionStore.swift`
- `Sources/PhotoLibraryCore/Index/PhotoIndexStore.swift`
- `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`
- `Sources/EditorCore/SafeErrorPresentation.swift`
- `Tests/PhotoLibraryCoreTests/LibraryRegistryTransactionTests.swift`
- `Tests/PhotoLibraryCoreTests/LibrarySourceRecoveryTests.swift`

## Concerns

- The journal intentionally supports one pending registry mutation at a time;
  `PhotoLibraryService` is an actor and recovers that record before preparing
  another mutation.
- The index mutation hook is internal and exists only as a deterministic test
  seam; production never installs it.

## Pre-review self-audit fix

After the first commit, a new RED showed that `resetRebuildableLocalData()`
could close/delete SQLite while an unrecovered journal was pending. The reset
now runs the same fail-closed recovery gate before touching the index. The
pending-recovery matrix directly covers reset along with add/focus/relink/
restore/scan/edit, and the focused test is GREEN.

## Independent review fix round 1

The first independent landing review requested changes for three actor/
evidence gaps and two test-coverage gaps. All were reproduced before the
production fixes:

- A scan blocked after its initial recovery check, while a concurrent focus
  operation left an unrecoverable journal. Before the fix, the resumed scan
  still wrote `lastSuccessfulScanAt` and emitted a normal terminal result.
- A stale bookmark resolving from old root A to new root B, followed by a
  refresh persistence failure, restored bookmark A but then overwrote SQLite
  metadata with B through the disconnected-restore path.
- A syntactically valid journal whose top-level ID was A but previous bookmark
  and index snapshot IDs were B executed rollback against B and cleared itself.

The production changes are:

- Scan rechecks recovery after actor suspension immediately before each batch
  upsert and once more before the final synchronous index/manifest/memory
  commit region. Failed recovery emits `.registryRecoveryRequired` and returns
  without a normal `.finished` event or later mutations.
- Restore-refresh failure now builds its disconnected in-memory diagnostic
  from the prior durable projection and skips the SQLite upsert, preserving the
  journal's exact rollback-to-old metadata.
- Every journal is validated before save and again before rollback mutation.
  Bookmark/snapshot IDs and confirmed manifest IDs must match the top-level
  `LibraryID`; operation kinds must contain the required old-state shape.
  Semantic or syntax corruption remains on disk and fails closed.
- The pending-operation matrix now directly covers removal and availability
  refresh. The prepare-failure test uses an observable access resolver and
  proves no access grant is created.

RED: the new scan race, restore A-to-B rollback, and semantic corruption tests
failed against `9842b0e`. GREEN: `LibraryRegistryTransactionTests` plus
`LibrarySourceRecoveryTests` execute 29 tests with 0 failures.

Post-fix verification: full `swift test` executes 965 tests with 9 skipped and
0 failures; strict-concurrency warnings-as-errors build and `git diff --check`
pass.

---

## Independent review fix round 2 — 2026-08-27

### Status

DONE

- Starting HEAD: `60f270125fedc32da92d33851ad8fd015c7399d0`
- Commit subject: `fix: preserve durable restore state when bookmark refresh creation fails`
- Durable transaction journal redesign, Task 2 reimplementation, and product
  Task 3 were not entered. The three untracked handoff documents
  (`sdd/codex-task2-round4-task1-brief.md`, `sdd/codex-task2-round4-task2-brief.md`,
  `sdd/lumaharbor-task2-claude-handoff.md`) were left exactly as found.

### Remaining defect fixed

In `PhotoLibraryService.restoreLibraries()`, when a stale bookmark resolved
from old durable root A to a new reachable root B, the working `folder`
projection was already re-pointed at B (`folder.rootURL`/`folder.lastKnownPath`
set from `stagedAccess.url`) *before* the stale-refresh branch attempted to
create refreshed bookmark data for B. If that bookmark-data creation itself
threw — a failure that occurs strictly before any registry transaction is
prepared, so there is no journal to roll back — the catch block still called
`commitDisconnectedRestore` with that already-B-pointing `folder` and its
default `persistLibraryProjection: true`. The bookmark store correctly stayed
at A, but SQLite (and actor-visible state) was overwritten with B, producing
exactly the same kind of half-updated durable registry the round 1 journal
fix was meant to prevent — just one step earlier, outside the journal's
coverage.

### Design delivered

- Added `BookmarkDataCreating` (`Sources/PhotoLibraryCore/Access/SecurityScopedBookmark.swift`):
  a minimal `Sendable` protocol seam over creating security-scoped bookmark
  data, with `SystemBookmarkDataCreator` as the production default that calls
  `SecurityScopedBookmark.makeBookmarkData(for:)`. `PhotoLibraryService` now
  takes a `bookmarkDataCreator: any BookmarkDataCreating = SystemBookmarkDataCreator()`
  dependency (both the public and internal initializers), and the previously
  `private static func makeBookmarkData(for:)` became an instance method
  routed through this dependency. All three call sites (`createNewLibrary`,
  `focusExistingLibrary`, and the stale-refresh branch of `restoreLibraries`)
  now go through the same seam — none was left on a separate static helper.
- Fixed the stale-refresh bookmark-data-creation catch block in
  `restoreLibraries()`: instead of committing the already-mutated (B-pointing)
  `folder`, it now rebuilds the blocked result from the last known-good
  durable projection — `index.library(id: folder.id)` when present, otherwise
  `persistedFolder` (the projection derived from the persisted bookmark,
  captured before any mutation) — and calls `commitDisconnectedRestore` with
  `persistLibraryProjection: false`, so B is never written to SQLite and
  never exposed as committed actor state. No `try?` was introduced; the
  `index.library(id:)` read propagates like every other index read in this
  function.

### Required RED test

Added `testStaleBookmarkDataCreationFailureBeforeJournalPreparePreservesOldDurableState`
in `Tests/PhotoLibraryCoreTests/LibrarySourceRecoveryTests.swift`, plus a
`FakeBookmarkDataCreator` test double that fails bookmark-data creation
deterministically for one selected URL (production always calls the real API
for every other URL). The test:

1. Establishes root A with a durable bookmark and SQLite projection, and
   restores it successfully once first so access ownership is real, not
   synthetic.
2. Creates root B with the identical valid manifest identity.
3. Makes the resolver report B as stale and reachable.
4. Injects bookmark-data-creation failure specifically for B.
5. Calls `restoreLibraries()` again and asserts: `.needsAuthorization` with
   `.persistenceFailure`; the returned folder's `rootURL` is exactly A; the
   bookmark record on disk is byte-for-byte the old A record; the SQLite
   library projection is exactly the old A projection (no B path anywhere);
   the previously retained A access handle and the newly staged B access
   handle each stop exactly once; no pending registry transaction journal
   exists (failure occurred before prepare); and root A's on-disk manifest is
   unchanged.

### TDD evidence

1. RED
   - Command: `swift test --filter 'LibrarySourceRecoveryTests.testStaleBookmarkDataCreationFailureBeforeJournalPreparePreservesOldDurableState'`
   - Run with the `BookmarkDataCreating` seam wired in but the
     `restoreLibraries()` catch-block fix *not yet applied* (verified by
     temporarily reverting only that one catch block, keeping the seam so the
     test could compile and exercise the actual production code path).
   - Result: 1 test, 2 expected failures — both directly showing the A/B
     divergence: the blocked folder's `rootURL` was root B instead of root A,
     and the SQLite library projection was the B-rooted `LibraryFolder`
     (`connectionState: .ready`, B's `rootURL`/`lastKnownPath`) instead of the
     old A projection.

2. GREEN
   - Reapplied the catch-block fix.
   - Same command: 1 test, 0 failures.

### Verification

- `swift test --filter 'LibrarySourceRecoveryTests'`
  - PASS: 16 tests, 0 failures.
- `swift test --filter 'LibraryRegistryTransactionTests|LibrarySourceRecoveryTests'`
  - PASS: 30 tests, 0 failures.
- `swift test --filter 'LibrarySource(Identity|Lifecycle|Recovery)Tests|FileBookmarkStoreTests|PhotoIndexStoreTests'`
  - PASS: 110 tests, 0 failures.
- `swift test --filter 'RelinkResolverTests|LibraryLifecycleTests'`
  - PASS: 26 tests, 0 failures.
- `swift test --filter PhotoLibraryCoreTests`
  - PASS: 422 tests, 0 failures. (A first attempt at this exact command hung
    for ~40 minutes with near-zero CPU usage, blocked inside the pre-existing,
    unmodified `PendingLeaseSubprocessTests.testAProcessKilledWithSIGKILLReleasesItsLeaseForReconciliation`
    at `Process.waitUntilExit()` after a `SIGKILL` — confirmed via `sample` on
    the stuck `xctest` process. That single test passed in 0.08s when run in
    isolation immediately afterward, and the full filtered re-run above
    completed cleanly in 2.7s, so this was a one-off sandbox resource-
    contention flake unrelated to this change, not a regression: the file is
    untouched by this fix and its own history predates it.)
- `swift test` (full suite)
  - PASS: 966 tests, 9 skipped, 0 failures (up from 965 at the prior HEAD —
    the one new test added here).
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
  - PASS: exit code 0.
- `git diff --check`
  - PASS: no whitespace errors.
- `git status --short --branch`
  - Only the three expected pre-existing untracked handoff documents plus
    this change's tracked edits; nothing else.

### Changed files

- `Sources/PhotoLibraryCore/Access/SecurityScopedBookmark.swift`
- `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`
- `Tests/PhotoLibraryCoreTests/LibrarySourceRecoveryTests.swift`
- `sdd/codex-task2-round4-task2-report.md`

### Concerns

None within this review-fix scope. The full-suite hang described above is
worth Codex/CI keeping an eye on if it recurs, but it reproduced as a clean
pass twice in isolation/re-run and touches subprocess/lease code this fix
never modified.

---

## Independent review fix round 3 — 2026-08-27

### Status

DONE

- Starting HEAD: `4c3545bf97b07b5fa5e85e89d6a53f4b35f0750c`
- Commit subject: `fix: close stale bookmark compound-failure scope leak`
- Journal redesign, Task 2 reimplementation, and product Task 3 were not
  entered. The four untracked handoff/review documents
  (`sdd/codex-task2-round4-task1-brief.md`, `sdd/codex-task2-round4-task2-brief.md`,
  `sdd/lumaharbor-task2-claude-handoff.md`,
  `sdd/codex-task2-round4-task2-review-fix-round3.md`) were left exactly as
  found.

### Verdict finding fixed

`4c3545b`'s stale-refresh catch block rebuilt the blocked projection with
`folder = try index.library(id: folder.id) ?? persistedFolder` *before*
calling `commitDisconnectedRestore`, which is what actually calls
`stagedAccess.stop()`. If that `index.library(id:)` read itself threw — the
index becoming unavailable at exactly that moment — control exited the catch
block before `commitDisconnectedRestore` ever ran, so the newly staged B
access handle was never stopped: a genuine leak. The old A actor/access
state was untouched in that case (the safe half), but the leak itself was
real and unverified by any test, since the round 2 test's SQLite read always
succeeded.

### Design delivered

Wrapped only the `index.library(id: folder.id)` read in its own `do/catch`
inside the existing stale-refresh catch block (the narrowly-scoped
alternative the spec allows, chosen over hoisting the durable-projection read
above access resolution, since every other `commitDisconnectedRestore` call
site in this function already reads the index later via
`populateRestoreProjection` and was out of this round's scope to touch):

- On success, behavior is unchanged from round 2: rebuild the blocked A
  projection and call `commitDisconnectedRestore` (which stops both the old
  A handle and the staged B handle exactly once, in that single call).
- On failure, the inner catch stops `stagedAccess` (B) exactly once, then
  rethrows the original index error unchanged. `commitDisconnectedRestore`
  is never called on this path, so `access[folder.id]` (the old A handle),
  `libraries[folder.id]` (the old A actor state), `restoreDiagnostics`, the
  bookmark record, SQLite and the registry-transaction journal are all left
  completely untouched — not because they're defensively preserved, but
  because nothing on this path ever writes to them. No `try?`, and no
  `defer` that could double-stop a handle already stopped by
  `commitDisconnectedRestore` on the success path.

No production call site or dependency signature changed beyond this one
`do/catch`; `BookmarkDataCreating`/`SystemBookmarkDataCreator` from round 2
are unchanged and remain the only bookmark-data-creation seam.

### Required RED test

Added `testCompoundBookmarkCreationAndIndexReadFailureStopsStagedHandleAndPreservesA`
in `Tests/PhotoLibraryCoreTests/LibrarySourceRecoveryTests.swift`. Extended
`FakeBookmarkDataCreator` with `setOnFailureAttempt(_:)`, a callback invoked
immediately before the injected bookmark-creation failure is thrown for a
given URL — so a test can prove the B access handle already exists at that
point (asserted inline: `resolver.createdHandles.count == 2`) and inject a
second, compound failure exactly there. **This section originally described
the callback as one-shot, but the implementation at the time left it
installed after firing — this test only ever triggered one failing call, so
the mismatch had no effect here, but the claim was unverified; independent
review evidence fix round 4 below makes the implementation genuinely
one-shot and adds a dedicated test proving it.** The test:

1. Restores root A successfully once (real access ownership).
2. Creates root B with the identical manifest identity; the resolver reports
   it stale and reachable; bookmark-data creation for B is set to fail.
3. The failure-attempt callback closes the service's live `PhotoIndexStore`
   at the exact moment B's bookmark-data creation is attempted — after the B
   handle already exists, not before.
4. Asserts `restoreLibraries()` throws — **at the time this section was
   written, via a broad `catch { }` that accepted any thrown `Error`, which
   does not by itself distinguish the intended `SQLiteError` from a
   regression that stopped B but rethrew the original `BookmarkError`
   instead; independent review evidence fix round 4 below replaces this with
   an exact `SQLiteError.prepareFailed` structural assertion** — the old A
   handle's `stopCallCount == 0` (never touched); the staged B handle's
   `stopCallCount == 1` (stopped, not leaked); `service.library(id:)` is
   still the previous `.ready` A folder (actor state untouched); the restore
   diagnostic is `nil` (never changed — the failed restore never committed
   anything); the bookmark record is unchanged; reopening a fresh
   `PhotoIndexStore` against the same on-disk database shows the exact old A
   projection; no registry-transaction journal exists; and both roots'
   manifest bytes/modification dates and a sentinel source file in each root
   are byte-for-byte unchanged.

### Strengthened existing test

`testStaleBookmarkDataCreationFailureBeforeJournalPreparePreservesOldDurableState`
(the round 2 single-failure test) now additionally asserts: `await
service.library(id:)` — not only the returned array — is based on root A and
is `.needsAuthorization`; both root A's and root B's manifest bytes and
modification dates are captured before the failed restore and compared
unchanged after; and a sentinel source file in each root is captured and
compared byte-for-byte unchanged. No production behavior changed to satisfy
this — only test coverage.

### TDD evidence

1. RED
   - Command: `swift test --filter 'LibrarySourceRecoveryTests.testCompoundBookmarkCreationAndIndexReadFailureStopsStagedHandleAndPreservesA'`
   - Run against unmodified `4c3545b` production code (only the test file and
     the `FakeBookmarkDataCreator` extension were in place).
   - Result: 1 test, 1 failure — `resolver.createdHandles[1].stopCallCount`
     was `0`, expected `1` ("The newly staged B access must still be stopped
     exactly once, never leaked"). Every other assertion in the test already
     passed against unmodified `4c3545b` — confirming the finding's own
     framing that the old A state was already safe and the leak was
     precisely, and only, the missing B `stop()`.

2. GREEN
   - Applied the inner `do/catch` fix.
   - Same command: 1 test, 0 failures.

### Verification

- `swift test --filter 'LibrarySourceRecoveryTests'`
  - PASS: 17 tests, 0 failures.
- `swift test --filter 'LibraryRegistryTransactionTests|LibrarySourceRecoveryTests'`
  - PASS: 31 tests, 0 failures.
- `swift test --filter 'LibrarySource(Identity|Lifecycle|Recovery)Tests|FileBookmarkStoreTests|PhotoIndexStoreTests'`
  - PASS: 111 tests, 0 failures.
- `swift test --filter 'RelinkResolverTests|LibraryLifecycleTests'`
  - PASS: 26 tests, 0 failures.
- `swift test --filter PhotoLibraryCoreTests`
  - PASS: 423 tests, 0 failures, run under an 8-minute wrapper as a
    precaution after the round 2 report's one-off hang. It completed cleanly
    in 3.4 seconds; `PendingLeaseSubprocessTests` did not hang this time, so
    there is nothing further to capture beyond what round 2 already
    recorded.
- `swift test` (full suite)
  - PASS: 967 tests, 9 skipped, 0 failures (up from 966 — the one new
    compound-failure test added here), run under the same timeout wrapper,
    completed in 13.2 seconds with no hang.
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
  - PASS: exit code 0.
- `git diff --check`
  - PASS: no whitespace errors.
- `git status --short --branch`
  - Only this change's tracked edits, plus the four expected pre-existing
    untracked handoff/review documents; nothing else.

### Access-handle stop-count results

- Simple failure (bookmark-data creation fails, index read succeeds — round
  2 scenario, still covered): old A handle stops exactly once, staged B
  handle stops exactly once, both via the single `commitDisconnectedRestore`
  call.
- Compound failure (bookmark-data creation fails, then the recovery
  `index.library(id:)` read also fails — new round 3 scenario): old A handle
  stops zero times (untouched, retained), staged B handle stops exactly once
  (via the new inner `do/catch`, not via `commitDisconnectedRestore`, which
  is never reached on this path).

### Bookmark/index/journal invariants

Both scenarios above leave the bookmark record, the on-disk SQLite
projection (verified in the compound case via a freshly reopened
`PhotoIndexStore`, since the in-process one was deliberately closed), and the
registry-transaction journal directory exactly as they were before the
failed restore — the journal is absent in both, since failure in either case
occurs strictly before `applyRegistryTransaction`/journal prepare is ever
reached.

### Changed files

- `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`
- `Tests/PhotoLibraryCoreTests/LibrarySourceRecoveryTests.swift`
- `sdd/codex-task2-round4-task2-report.md`

### Concerns

None within this review-fix scope. No hang or skip surfaced this round.

---

## Independent review evidence fix round 4 — 2026-08-28

### Status

DONE

- Starting HEAD: `da885c2b321b07ca5dcda8fefdc14dff0502b874`
- No file under `Sources/` was touched — the production scope-leak fix from
  round 3 was verified correct and left exactly as committed. Only
  `Tests/PhotoLibraryCoreTests/LibrarySourceRecoveryTests.swift` and this
  report changed. The five untracked handoff/review documents
  (`sdd/codex-task2-round4-task1-brief.md`,
  `sdd/codex-task2-round4-task2-brief.md`,
  `sdd/codex-task2-round4-task2-review-fix-round3.md`,
  `sdd/codex-task2-round4-task2-review-evidence-round4.md`,
  `sdd/lumaharbor-task2-claude-handoff.md`) were left exactly as found. No
  product source RED was fabricated and no committed production code was
  temporarily broken — this round hardens test evidence for already-correct
  production code, per the review's own evidence protocol.

### Gaps closed

**Important 1 — exact propagated-error assertion.** The compound test's
`catch { }` accepted any thrown `Error`, which would also have passed for a
regression that stopped the B handle but rethrew the original
`BookmarkError` instead of the real `SQLiteError` — it never actually proved
which error propagated. Replaced with:

```swift
} catch let error as SQLiteError {
    guard case .prepareFailed(let sql, let message) = error else {
        XCTFail("Expected SQLiteError.prepareFailed, got SQLiteError.\(error)")
        return
    }
    XCTAssertEqual(message, "database is closed")
    XCTAssertTrue(sql.contains("FROM library"), "…")
} catch {
    XCTFail("Expected SQLiteError.prepareFailed, got \(type(of: error))")
}
```

This matches `PhotoIndexStore.libraries()` → `SQLiteDatabase.prepare(_:_:)`
exactly: `PhotoLibraryService`'s recovery read calls `index.library(id:)` →
`libraries()`, whose `SELECT … FROM library l …` query is prepared against
the just-closed database, hitting the `guard let handle else { throw
SQLiteError.prepareFailed(sql: sql, message: "database is closed") }` branch
in `Sources/PhotoLibraryCore/Index/SQLiteDatabase.swift`. The SQL text is
pattern-matched (`sql.contains("FROM library")`), not hard-coded, and no
`localizedDescription` comparison is used — the structured case and its
`message` field are compared directly. `SQLiteError` is `Equatable` in
production, but the case is unwrapped explicitly (not `XCTAssertEqual(error,
.prepareFailed(...))`) so a wrong-case mismatch reports its own case name
via `XCTFail` rather than only a generic equality failure.

**Important 2 — no real path in the injected error.** `FakeBookmarkDataCreator`
previously threw `BookmarkError.couldNotCreate(path: url.path, reason:
"injected test failure")`, embedding the real temporary directory's absolute
path in the payload. Replaced with fixed synthetic constants:
`path: "<injected-test-path>"`, `reason: "injected bookmark creation
failure"` — never derived from the URL passed in. Added
`testFakeBookmarkDataCreatorInjectedFailurePayloadIsSyntheticAndPathFree`,
which calls the fake directly with a real on-disk `URL`, catches the thrown
`BookmarkError.couldNotCreate`, and asserts: `path == "<injected-test-path>"`;
`reason == "injected bookmark creation failure"`; the payload does not
contain the real URL's path; and the payload does not start with any of
`/Users/`, `/Volumes/`, `/private/var/`, `/private/tmp/`. The production
`SafeErrorPresentation`/diagnostic-mapping code was not touched.

**Minor — genuinely one-shot callback.** `onFailureAttempt` was read but
never cleared, so a second failing call for the same URL would have re-fired
it (this round 3 test only ever made one failing call, so the bug was latent
there, not exercised). `makeBookmarkData(for:)` now copies the callback to a
local and clears the stored one under the same lock acquisition that
observes a failing URL, then releases the lock before invoking the callback
— so the lock is never held across the callback body or, by construction,
across any `XCTest` assertion or `indexStore.close()` a test's callback might
perform. Added
`testFakeBookmarkDataCreatorOnFailureAttemptCallbackFiresExactlyOnceAcrossRepeatedFailingCalls`,
which fails the same URL twice via two separate `makeBookmarkData` calls and
asserts a lock-protected counter (`LockedCounter`, a small `@unchecked
Sendable` helper — a raw captured `var` mutated from the `@Sendable` callback
triggered a real Swift 6 data-race warning under strict concurrency) is
exactly `1`, not `2`, after both.

### Evidence protocol checklist

1. Original broad-catch weakness: documented above and in the corrected
   Round 3 report text (this file).
2. New exact-error assertion passing against unchanged `da885c2` production
   code: confirmed below (RED/GREEN for this round is evidence-only, since
   production was already correct — see next section).
3. Fixed synthetic payload assertion: `testFakeBookmarkDataCreatorInjectedFailurePayloadIsSyntheticAndPathFree`
   passes.
4. One-shot callback count assertion:
   `testFakeBookmarkDataCreatorOnFailureAttemptCallbackFiresExactlyOnceAcrossRepeatedFailingCalls`
   passes.

### Evidence-hardening verification (no product RED — production already correct)

- `swift test --filter 'LibrarySourceRecoveryTests.testCompoundBookmarkCreationAndIndexReadFailureStopsStagedHandleAndPreservesA'`
  - PASS: 1 test, 0 failures — the new exact `SQLiteError.prepareFailed`
    assertion (message `"database is closed"`, SQL containing `"FROM
    library"`) passes against unmodified `da885c2` production code, proving
    the requirement the old broad catch could not.
- `swift test --filter 'LibrarySourceRecoveryTests'`
  - PASS: 19 tests, 0 failures (17 from round 3 + the 2 new
    `FakeBookmarkDataCreator`-only tests added this round).
- `swift test --filter 'LibraryRegistryTransactionTests|LibrarySourceRecoveryTests'`
  - PASS: 33 tests, 0 failures.
- `swift test --filter PhotoLibraryCoreTests`
  - PASS: 425 tests, 0 failures, run under an 8-minute wrapper as a
    precaution given the round 2 one-off hang. Completed cleanly in 3.4
    seconds; `PendingLeaseSubprocessTests` did not hang. No hang to report
    this round.
- `swift test` (full suite)
  - PASS: 969 tests, 9 skipped, 0 failures (up from 967 — the two new
    evidence tests added here), run under the same timeout wrapper,
    completed in 13.0 seconds with no hang.
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
  - PASS: exit code 0, per the spec's exact required command (which builds
    only the main products, not test targets). Note for completeness: a
    speculative `--build-tests` run under the same flags surfaces pre-existing
    strict-concurrency errors in an unrelated, unmodified file
    (`Tests/RawProcessingCoreTests/JPEGExportTests.swift`, `Task { … }`
    closures flagged under `SendingClosureRisksDataRace`) — outside this
    round's allowed-files list and not something this round introduced or is
    scoped to fix; the spec's exact verification command does not exercise
    this path and passes cleanly.
- `git diff --check`
  - PASS: no whitespace errors.
- `git status --short --branch`
  - Only `Tests/PhotoLibraryCoreTests/LibrarySourceRecoveryTests.swift` and
    this report changed; no file under `Sources/` touched; all five expected
    untracked handoff/review documents preserved exactly.

### Changed files

- `Tests/PhotoLibraryCoreTests/LibrarySourceRecoveryTests.swift`
- `sdd/codex-task2-round4-task2-report.md`

### Concerns

None. No hang, no skip beyond the pre-existing 9, and no `Sources/` file was
modified.

---

## Round 3 re-review CHANGES_REQUESTED fix — 2026-08-28

### Status

DONE

- Starting HEAD: `cf555055ba4299b7aac5c40b88a6174fbe34f218`
- This round addresses the two `CHANGES_REQUESTED` findings from Codex's
  third re-review round. No Task 3 work was started; no RAW/original source
  file was touched; no push/merge/rebase performed.

### Finding 1 — public test seam removed from product API

`BookmarkDataCreating`, `SystemBookmarkDataCreator`, and the `bookmarkDataCreator`
parameter on `PhotoLibraryService`'s **public** initializer had all been made
`public`, expanding the product's public API surface purely to support test
injection — against the explicit handoff requirement that this stay an
`internal` `Sendable` test seam.

Fix in `Sources/PhotoLibraryCore/Access/SecurityScopedBookmark.swift`:

- `protocol BookmarkDataCreating` and `struct SystemBookmarkDataCreator`
  (with its `init()` and `makeBookmarkData(for:)`) all dropped from `public`
  to the default (internal) access level.

Fix in `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`:

- The **public** initializer no longer accepts a `bookmarkDataCreator`
  parameter at all; it now always forwards `SystemBookmarkDataCreator()` to
  the internal initializer.
- The **internal** initializer (the one that also takes
  `registryTransactionStore:`, already not part of the public surface) keeps
  the `bookmarkDataCreator` parameter with its default, exactly as before.
  This is the only initializer tests use for injection, reached via
  `@testable import PhotoLibraryCore`.

No other public product API changed: `FolderAccessResolving` /
`SystemFolderAccessResolver` and `ResourceIdentityResolving` /
`SystemResourceIdentityResolver` were already public before this task and are
untouched (they are legitimate product seams the app target itself
constructs, unlike `BookmarkDataCreating`, which existed solely for test
injection).

Test-side fallout: three call sites in
`Tests/PhotoLibraryCoreTests/LibrarySourceRecoveryTests.swift` constructed
`PhotoLibraryService` with a `bookmarkDataCreator:` label and no
`registryTransactionStore:` label, which resolved to the (now nonexistent)
public overload. All three — the shared `makeService` helper and two direct
constructions in the stale-bookmark-creation-failure tests — were updated to
pass `registryTransactionStore: nil` explicitly, selecting the internal
initializer, exactly as the round 2/3 tests already did implicitly.

### Finding 2 — `commitDisconnectedRestore` partial-commit window

Previously, `commitDisconnectedRestore` stopped `stagedAccess`, removed and
stopped the library's existing `access` entry, and wrote `libraries`/
`restoreDiagnostics` — all nonthrowing actor-state mutations — *before*
calling the throwing `populateRestoreProjection(&folder)` and (when
requested) `index.upsert(library:)`. If either of those later calls threw
(a second SQLite read/write failure), the method rethrew with the actor's
`access`, `libraries`, and `restoreDiagnostics` already partially updated to
a state that was never durably committed to SQLite — a real partial-commit
window distinct from the caller-side `priorProjection` read failure already
covered by
`testCompoundBookmarkCreationAndIndexReadFailureStopsStagedHandleAndPreservesA`.

Fix in `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`
(`commitDisconnectedRestore`): reordered so every throwing step runs first,
against a local `folder` copy only:

```swift
var folder = initialFolder
do {
    try populateRestoreProjection(&folder)
    if persistLibraryProjection {
        try index.upsert(library: folder)
    }
} catch {
    stagedAccess?.stop()
    throw error
}

stagedAccess?.stop()
access.removeValue(forKey: folder.id)?.stop()
libraries[folder.id] = folder
if let diagnostic {
    restoreDiagnostics[folder.id] = diagnostic
} else {
    restoreDiagnostics.removeValue(forKey: folder.id)
}
return folder
```

`stagedAccess` was never inserted into the actor's `access` map by this
method, so stopping it in the failure branch only releases a resource this
call never published — it does not create or resolve a durable/actor-state
mismatch, and skipping it would leak a security-scoped access. On failure,
the actor's existing `access[folder.id]`, `libraries[folder.id]`, and
`restoreDiagnostics[folder.id]` are left completely untouched, matching
whatever was last durably committed; on success, all nonthrowing commits
happen atomically only after both throwing steps have already succeeded.

Added `testCommitDisconnectedRestoreSecondProjectionReadFailurePreservesAllState`
to `Tests/PhotoLibraryCoreTests/LibrarySourceRecoveryTests.swift`, exercising
a call path the existing compound test does not: a library that restores
successfully once (real access, real durable projection), then goes
*offline* on the next pass with the index already closed. Nothing before
`commitDisconnectedRestore` touches the index on the offline path (no
stale-bookmark refresh, no caller-side `priorProjection` rebuild), so the
only index access on this pass is `commitDisconnectedRestore`'s own
`populateRestoreProjection` — specifically its first statement,
`photoCount(inLibrary:)`. The test asserts:

- the thrown error is exactly `SQLiteError.prepareFailed` with message
  `"database is closed"` and SQL containing `"FROM photo"` — proving it is
  `photoCount`'s read, not the `"FROM library"` read the existing compound
  test already covers, i.e. a genuinely different failure window;
- the previously-retained A access handle's `stopCallCount` stays `0` (never
  touched);
- the newly staged (offline) handle's `stopCallCount` is exactly `1` (not
  leaked);
- `service.library(id:)` still reports the old `.ready` folder at root A,
  unchanged;
- `service.restoreDiagnostic(for:)` is still `nil`;
- the bookmark store still holds the old record;
- reopening a fresh `PhotoIndexStore` against the same on-disk database file
  shows the SQLite projection is still exactly the old A projection — the
  failed offline commit was never written.

### Verification

- `swift build`
  - PASS: exit 0.
- `swift test --filter 'LibrarySourceRecoveryTests'`
  - PASS: 20 tests, 0 failures (19 from round 4 + the 1 new test this round).
- `swift test --filter 'LibraryRegistryTransactionTests|LibrarySourceRecoveryTests|FileBookmarkStoreTests'`
  - PASS: 50 tests, 0 failures.
- `swift test --filter 'PhotoLibraryCoreTests'`
  - PASS: 426 tests, 0 failures.
- `swift test` (full suite)
  - PASS: 970 tests, 9 skipped (pre-existing, host-dependent bookmark tests),
    0 failures.
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
  - PASS: exit 0.
- `git diff --check`
  - PASS: no whitespace errors.
- `git status --short --branch`
  - Only `Sources/PhotoLibraryCore/Access/SecurityScopedBookmark.swift`,
    `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`,
    `Tests/PhotoLibraryCoreTests/LibrarySourceRecoveryTests.swift`, and this
    report changed. The five untracked handoff/review documents were left
    exactly as found.

### Changed files

- `Sources/PhotoLibraryCore/Access/SecurityScopedBookmark.swift`
- `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`
- `Tests/PhotoLibraryCoreTests/LibrarySourceRecoveryTests.swift`
- `sdd/codex-task2-round4-task2-report.md`

### Concerns

None. No hang, no new skips, no `Sources/` RAW-handling file touched, and no
further public API surface added — the public initializer's parameter list
is now strictly smaller than before this round.
