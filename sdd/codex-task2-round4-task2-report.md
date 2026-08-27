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
