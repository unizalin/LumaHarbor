# Task 4 report — Project committed App copies into the library and open indexed documents

## Status

DONE

- Baseline HEAD before Task 4 work: `f839439` (`docs: record Task 3 rider
  cancellation review fix`) — Task 3 has been Codex re-reviewed and
  **APPROVED**.
- Task 4 stayed strictly within the plan's scope: `PhotoDocumentStore`,
  `PhotoDocument`, `PhotoID`, `PhotoLibraryService`, `PhotoDocumentEditor`,
  and their tests, plus two small, necessary support changes (see
  "Additional files touched" below). No Task 5 file
  (`LibraryBrowserDependencies.swift`, `LibraryBrowserSession.swift`) was
  created or modified. No push, merge, rebase, amend, or squash was
  performed.

## Design and implementation

### `LibraryID.appStorage` (`Sources/PhotoLibraryCore/Model/PhotoID.swift`)

A fixed, hardcoded `LibraryID` (`6C554D41-4841-5242-4F52-000000000001`),
exposed as a `static let` computed once via a closure that guards the UUID
parse with `preconditionFailure` rather than a force-unwrap — the literal is
known-good, but the codebase's own convention (confirmed via
`rg 'try!|as!'` returning no hits anywhere touched) avoids force-unwraps
even for values this certain. Every launch, on every device, resolves to
the exact same `LibraryID`, which is what lets `LibraryScope.appStorage`
(Task 1) — `JOIN library l ON p.library_id = l.id` + `WHERE
l.source_kind = 'appStorage'` — always find the same synthetic source row.

### `LibraryOpenAsset` (`Sources/PhotoLibraryCore/Documents/PhotoDocument.swift`)

```swift
public enum LibraryOpenAsset: Sendable, Equatable {
    case external(url: URL, sourceKind: LibrarySourceKind)
    case appCopy(documentID: UUID)
}
```

Added next to `PhotoDocument`'s other supporting types, exactly as the
plan's file list calls for. `.external`'s `url` is documented as
runtime-only and never persisted/logged by this type.

### `PhotoDocumentStore.committedDocuments()` (`Sources/PhotoLibraryCore/Documents/PhotoDocumentStore.swift`)

Enumerates `Records/*.json` — the same directory
`reconcileOrphanedImports(activePointer:)`'s own pass 2 already reads —
with the same lenient per-entry handling: a record that fails to decode, or
whose `id` field doesn't match its filename, is reported in the new
`PhotoDocumentListing.failures` (keyed by `UUID`, fixed path-free
diagnostic text, never `NSError.localizedDescription`); a `.pending` record
is skipped entirely — never promoted, never deleted, never even reported —
matching the plan's explicit requirement and the existing
`reconcileOrphanedImports` contract that only that dedicated,
active-pointer-gated pass may ever touch a pending creation. A committed
record whose resolved working file is missing (deleted, disk corruption) is
also reported as a failure rather than silently listed or silently dropped.
Legacy app-copy records missing `workingPathComponents` are opportunistically
migrated via the existing `migrateLegacyAppCopyRecordIfPossible` helper,
exactly as `loadDocument` already does. Results are sorted by ascending
`id.uuidString` for a stable, deterministic order. This is a pure read —
unlike `reconcileOrphanedImports`, it never acquires the root import lock or
any per-document lease, since every record write already goes through
`AtomicFileWriter` and nothing here mutates anything.

`PhotoDocumentListing` (new `Equatable, Sendable` struct, defined alongside
`PhotoDocumentReconciliationReport`) carries `documents: [PhotoDocument]`
and `failures: [UUID: String]`.

### `PhotoLibraryService.refreshAppStorageProjection(from:)` (`Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`)

Takes `documents: [PhotoDocument]` directly — `PhotoDocument` is a public
type in the same module (`PhotoLibraryCore`), so this needs no new
cross-module dependency; the caller (a future composition root, per the
plan's "Consumes: committed `PhotoDocument` records") is expected to pass
`PhotoDocumentStore.committedDocuments().documents`. Filters to
`.appCopy` only — an `.inPlace` document's working file is an external RAW,
already projected through its own indexed source's scan if it lives inside
one; this is not a second, competing path for it.

Ensures a `LibraryFolder` row exists for `.appStorage`
(`sourceKind: .appStorage`, created once, idempotently) so the `JOIN`
`LibraryScope.appStorage` requires has something to match. Projects each
app copy as a `PhotoAsset` (`id: PhotoID(document.id)`, reusing the same
document-UUID-as-PhotoID identity `saveAdjustments` already establishes;
`fingerprint: document.workingFingerprint`). Reuses the exact same
"re-seen vs. pruned" pattern a folder scan already uses for deleted files:
every call captures one `Date()` (`projectedAt`), stamps every currently-
committed app copy's `lastSeenAt` with it, then calls the existing
`index.removePhotos(inLibrary:notSeenSince:)` with that same value —
anything not just re-seen (rolled back, removed, no longer committed since
the last call) carries an older timestamp and is pruned. Idempotent and
rebuildable, matching the plan's "local and rebuildable" requirement
exactly, and reusing infrastructure Task 1/3 already built rather than
inventing new prune logic.

`relativePath`/`rootURL` are chosen so `PhotoLibraryService.sourceURL(for:)`
still resolves correctly for a projected app copy without this actor ever
holding a reference to `PhotoDocumentStore`'s own `rootURL` (the two
components are intentionally decoupled): `rootURL` is the filesystem root
(`/`), and each asset's `relativePath` is `document.workingURL.path` with
its leading `/` stripped, so `rootURL.appendingPathComponent(relativePath)`
reconstructs the exact original `workingURL`. This is not required by any
listed test, but it costs nothing and keeps the projection genuinely
useful rather than a dead-end field, for whenever a later task (thumbnails)
needs it.

### `PhotoDocumentEditor.openLibraryAsset(_:)` (`Sources/EditorCore/PhotoDocumentEditor.swift`)

Dispatches on `LibraryOpenAsset`:

- **`.appCopy(documentID:)`** (`openLibraryAppCopy(documentID:)`): loads the
  existing record via `store.loadDocument(id:)` — never `importCopy`.
  Structurally parallel to `commitDocument(token:document:scope:photo:
  adjustments:)` (used by restore/relink), but — unlike those, which only
  ever run while `document` is already `nil` — this can happen while a
  *different* document is open and dirty, so it also flushes-and-replaces
  first: `flushCurrentDocumentIfDirty()` → `retryFinalizeIfNeeded()` (for
  whatever the *old* document's own outstanding creation might be) →
  `saveActiveDocumentID(_:)` → atomic in-memory hand-off, in that order,
  matching `openFreshSelection`'s phase-2 exactly. No new creation is ever
  minted, so there is nothing to roll back on failure.
- **`.external(url:sourceKind:)`** (`openLibraryExternalAsset(url:)`):
  reuses the full two-phase-switch machinery `openFreshSelection(url:
  scope:mode:)` already established for `.inPlace` mode — same
  cancellation-generation token, same phase-1-build-then-phase-2-switch
  ordering, same `discard(_:sourceScope:)` rollback, same
  `unfinalizedCreation`/finalize-durability gating — minus the
  import-choice dialog, since an already-indexed external source is always
  opened in place. Offline/unreachable detection is two-layered, both
  mapped to the same actionable alert
  (`nextStep: L10n.t("Reconnect the source, then try again.")`), and
  neither ever mints a token or touches `document`/`openingTask` before
  the source is proven reachable:
  1. The security scope itself failing to open
     (`dependencies.makeScope(url).isAccessing == false`) — checked first,
     before anything else.
  2. Any *other* failure while actually reading/fingerprinting the file
     inside `store.openInPlace(...)` — the more realistic offline case in
     practice, since a stale sandbox grant can still nominally "open"
     against a volume that is no longer mounted. Mapped via a small local
     `LibraryAssetOpenError.sourceUnreachable` control-flow error, careful
     to rethrow a genuine `CancellationError` first so a superseded
     operation is never misreported as "offline."

Neither path lets `document` become visible before `loadEditorState(for:)`
(decode + adjustments load) has already succeeded and, for `.external`,
before `flushCurrentDocumentIfDirty()`/`retryFinalizeIfNeeded()`/
`saveActiveDocumentID(_:)` have all already succeeded too — the same
"nothing visible until fully validated" guarantee `openFreshSelection`
already provides. No second document/open state machine was added: both
paths are new private methods on the existing `PhotoDocumentEditor`,
calling its existing `discard`/`recordIfIncomplete`/`retryFinalizeIfNeeded`/
`loadEditorState`/`flushCurrentDocumentIfDirty` helpers directly. (A literal
call into `openFreshSelection` itself was considered for `.external`, but
rejected: its single generic catch-all would show `SafeErrorPresentation
.alert(...)` for an offline source instead of the specific "reconnect"
message the plan's own test requires, and threading a bypass through that
already delicate, heavily-tested method risked a regression for no real
duplication saving — the `.external` path is deliberately parallel code,
not a fork of a shared state machine.)

## Additional files touched (small, necessary, in scope)

Two files outside the plan's explicit list were touched, both minimal and
directly required by the plan's own listed test content:

- `Package.swift`: added `Localization` to `EditorCoreTests`'
  dependencies. The plan's own Step 4 test asserts
  `editor.alert?.nextStep == L10n.t("Reconnect the source, then try
  again.")` — comparing against a hardcoded English literal instead would
  be locale-dependent and could fail on a machine whose system language
  isn't English; calling the same `L10n.t(...)` the production code calls
  is what makes the assertion locale-independent, and that requires the
  module to be importable from the test target (it wasn't).
- `Sources/Localization/Resources/{en,zh-Hant}.lproj/Localizable.strings`:
  added `"App Copies"` (the new `.appStorage` `LibraryFolder`'s
  `displayName`) and `"Reconnect the source, then try again."` (the new
  offline-external-asset alert's `nextStep`) to both locales — required by
  the global constraint that user-facing strings are localised in English
  and Traditional Chinese, and directly exercised by the new tests.

No other production file outside the plan's list was modified.

## New tests

`Tests/PhotoLibraryCoreTests/PhotoDocumentStoreListingTests.swift` (7 tests):

- `testCommittedDocumentsReturnsOnlyCommittedReadableRecordsInStableUUIDOrder`
  — the exact plan scenario: one committed app copy, one committed
  in-place record, one pending record, one corrupt record. Only the two
  committed ones come back, in stable UUID order; the corrupt one is
  reported in `failures` and only it; the pending record's on-disk state
  (`lifecycleState: "pending"`, its `Documents/<id>` copy) is completely
  untouched.
- `testCommittedDocumentsNeverPromotesOrDeletesAPendingRecordAcrossRepeatedCalls`
  — repeated reads never mutate a pending record.
- `testCommittedDocumentsReportsAMissingWorkingFileAsAFailureNotADocument`
  — a committed app copy whose working file was deleted out from under it
  is reported as a failure, never silently listed as readable.
- `testCommittedDocumentsReturnsEmptyBeforeAnythingHasEverBeenCreated` — no
  `Records/` directory yet is "no documents," not an error.
- `testRefreshAppStorageProjectionOnlyProjectsAppCopyDocuments` — an
  `.inPlace` document passed in is never projected; the app copy is,
  reachable both through `photos(inLibrary:)` and through the real
  `LibraryQuery(scope: .appStorage, ...)` join path.
- `testRefreshAppStorageProjectionPrunesDocumentsNoLongerCommitted` — a
  second call with a smaller `documents` array prunes the row for the
  document that dropped out, proving the rebuildable/idempotent contract.
- `testRefreshAppStorageProjectionHandlesNoCommittedAppCopiesAtAll` — an
  empty (or fully pruned) input never throws and leaves the scope empty.

`Tests/EditorCoreTests/PhotoDocumentEditorLibraryOpenTests.swift` (7 tests):

- `testOpeningIndexedAppCopyDoesNotImportAgain` — the plan's required
  scenario. Verified two ways since the real `PhotoDocumentStore` has no
  call-counter seam to intercept: the exact same document `id` comes back
  (a fresh `importCopy` always mints a new `UUID`), and the `Documents/`
  directory's entries are byte-for-byte unchanged (no new copy directory
  appeared).
- `testOpeningLibraryAppCopyFlushesTheCurrentlyOpenDocumentFirst` —
  switching to a library app copy while a different document is open and
  dirty flushes it to disk before the switch.
- `testOfflineExternalAssetLeavesCurrentDocumentUntouched` — the plan's
  required scenario, using a URL with no file ever written to model
  "offline." The current document survives unchanged; the alert's
  `nextStep` matches `L10n.t("Reconnect the source, then try again.")`.
- `testOfflineExternalAssetWithNoCurrentDocumentShowsAlertAndOpensNothing`
  — the same offline case with nothing open yet: no document is fabricated.
- `testExternalIndexedAssetOpensAsInPlaceDocument` — a reachable external
  asset opens as `.inPlace`, with `workingURL == sourceURL == url`.
- `testOpeningExternalLibraryAssetFlushesTheCurrentlyOpenDocumentFirst` —
  flush-before-switch for the external-indexed path too.
- `testOpeningExternalLibraryAssetThatFailsToDecodeLeavesTheOldDocumentUntouchedAndRollsBack`
  — rollback semantics end to end: a metadata decode failure for the new
  library asset leaves the old document exactly as it was (still open,
  active pointer never moved), leaves no orphaned record for the failed
  attempt, and the old document's own edit — made before the failed
  switch — still flushes and persists normally afterward.

One test bug was found and fixed while writing this round's tests (not a
production defect): an early version of
`testOpeningExternalLibraryAssetThatFailsToDecodeLeavesTheOldDocumentUntouchedAndRollsBack`
set `harness.decoder` to a selectively-failing decoder *after* calling
`harness.makeEditor()` — but `PhotoDocumentEditorDependencies` is a
value-type snapshot captured once, at `makeEditor()` time, so the swap
never reached the already-constructed editor and the "failing" open
actually succeeded. Fixed by setting `harness.decoder` before
`makeEditor()`, matching the exact ordering the existing
`PhotoDocumentEditorTests.swift` harness already requires (confirmed by
re-reading its own tests, which always set `harness.decoder` first).

## Verification

```zsh
swift test --filter 'PhotoDocumentStoreListingTests|PhotoDocumentEditorLibraryOpenTests'
swift test --filter 'PhotoDocumentStoreTests|PhotoDocumentEditorTests'
swift test --filter PhotoLibraryCoreTests
swift test --filter EditorCoreTests
swift test
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
git diff --check
```

Results:

- `PhotoDocumentStoreListingTests`: **7 tests, 0 failures** (run 3×, 0
  flakes).
- `PhotoDocumentEditorLibraryOpenTests`: **7 tests, 0 failures** (run 3×, 0
  flakes).
- `PhotoDocumentStoreTests|PhotoDocumentEditorTests` (pre-existing
  coverage): **105 tests, 0 failures** — no regression.
- `PhotoLibraryCoreTests` (full target): **453 tests, 0 failures** (446
  before this task + 7 new).
- `EditorCoreTests` (full target): **62 tests, 0 failures** (55 before this
  task + 7 new).
- Full `swift test`: **1,010 tests, 9 skipped, 0 failures** (996 before
  this task + 14 new = 1,010). The 9 skips are the same pre-existing,
  host-dependent security-scoped-bookmark skips, not new.
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc
  -warnings-as-errors`: **exit 0**, no warnings. No sandbox/module-cache
  permission failure was encountered.
- `git diff --check`: **PASS**, no whitespace errors.
- `rg -n 'TBD|TODO|FIXME|fatalError|try!|as!'` over the five changed
  production files: **no hits**.
- No RAW read/write/move/rename/delete path was added beyond what
  `PhotoDocumentStore` already does; no source file is ever written to.
- No private absolute path appears in any new alert message, log, or
  diagnostic — the offline-source alert carries no path, and the app-copy
  projection's `relativePath` (which does encode an absolute path, by
  design — see "Design and implementation" above) is stored only in the
  local, rebuildable SQLite index, never surfaced through any log or
  report this task added.

## Remaining concerns

None blocking. Two points worth flagging for the next reviewer/task:

1. `PhotoLibraryService.refreshAppStorageProjection(from:)` has no
   production caller yet — Task 4's own scope only produces the interface,
   per the plan's "Produces" list. A future composition root (plausibly
   Task 6's `PadAppServices`, or a periodic refresh hook) is expected to
   call `store.committedDocuments()` and feed the result in; that wiring
   is out of scope here and intentionally not anticipated or duplicated.
2. `PhotoDocumentEditor.openLibraryAsset(.appCopy(documentID:))` does not
   validate that the loaded record's `storageMode` is actually `.appCopy`
   before using it directly (no scope acquisition or bookmark resolution
   is attempted). This mirrors the plan's literal contract — `.appCopy`
   asset values are expected to only ever be constructed from data Task 4's
   own app-storage projection produced, which is `.appCopy`-only by
   construction — but if a future caller ever passed a mismatched
   `documentID` (e.g. an `.inPlace` document's id) through `.appCopy(...)`
   by mistake, this would attempt to read an external file with no
   security scope rather than failing cleanly with an actionable message.
   Not reachable through any caller this task adds; worth a defensive
   check if `openLibraryAsset` ever gains additional callers with less
   controlled input.

   **Update (review fix round 1):** this predicted exact scenario is
   exactly what Codex's re-review found and required fixing — see "Review
   fix round 1" below. It is resolved: a mismatched `documentID` now fails
   closed with a safe alert, and the currently open document, its scope,
   and the active pointer are all left untouched.

## Review fix round 1

Codex's pre-landing re-review of the Task 4 commit (`974aa9a`) returned
**BLOCKED** with two findings.

### Finding 1 (P1, blocking): the App-storage projection leaked local absolute paths into `PhotoAsset.relativePath`

**Finding.** `refreshAppStorageProjection(from:)` derived a projected app
copy's `relativePath` from `document.workingURL.path` (with only the
leading `/` stripped) and set the synthetic library's `rootURL` to the
real filesystem root (`/`). Since `relativePath` is not an internal-only
field — `PhotoIndexStore`'s page, folder, and filename-search queries all
read it directly, and it is meant to eventually reach a library browser UI
— this meant a real, local, private path (`Users/<name>/Library/
Application Support/LumaHarbor/PhotoDocuments/Documents/<id>/<filename>`)
could end up displayed through the `.appStorage` scope, and a folder-tree
query over it would surface fake `Users`/`<name>`/... nodes built from
this device's own directory names, not anything user-meaningful.

**Fix.** `PhotoLibraryService.swift`:

- `appStorageRelativePath(for:)` now returns a purely synthetic
  `"<document id>/<filename>"` string, built only from the document's own
  UUID and its working file's last path component — never any other part
  of `workingURL`. The document UUID is already a stable identifier that
  reveals nothing about the local filesystem, and keeps same-named files
  from different documents distinct.
- `appStorageProjectionRootURL` changed from the real filesystem root to a
  fixed, obviously-synthetic literal (`/LumaHarborAppStorage`) — written as
  an already-absolute path string specifically so it never resolves
  against this *process's* current working directory the way a relative
  `URL(fileURLWithPath:)` would.
- Both call sites' doc comments were rewritten to state plainly that
  `sourceURL(for:)` must never be relied on for a projected App copy:
  opening one always goes through `PhotoDocumentEditor.openLibraryAsset
  (.appCopy(documentID:))` → `PhotoDocumentStore.loadDocument(id:)`, which
  reads the real `workingURL` from the store's own durable record, never
  reverse-derived from this projected index path. (`sourceURL(for:)`
  itself was not changed — it still combines `rootURL` +
  `relativePath` exactly as before, for every source kind; App-copy rows
  now simply produce a harmless synthetic, non-existent path if it is ever
  called against one, rather than a real user path.)

### Finding 2 (P2, blocking): `openLibraryAsset(.appCopy(documentID:))` didn't validate the loaded record's storage mode

**Finding.** `openLibraryAppCopy(documentID:)` called
`store.loadDocument(id:)` and used the result directly without checking
`storageMode`. A `documentID` that actually names an `.inPlace` record
would be opened as if it were an App copy: `documentScope` is always set
to `nil` on this path (an App copy needs none), so an `.inPlace` document's
external `workingURL` would be read with no security scope at all, and
`LibraryOpenAsset`'s case-based separation between "always in place, needs
a scope" and "always a local App copy, never needs one" would be silently
violated for a caller's mistake instead of caught.

**Fix.** `PhotoDocumentEditor.swift`: `openLibraryAppCopy(documentID:)` now
checks `loadedDocument.storageMode == .appCopy` immediately after loading
the record, before touching anything else (before `loadEditorState`,
before flushing the current document, before any active-pointer write).
On a mismatch it throws a new `LibraryAssetOpenError.notAnAppCopy`, caught
by a dedicated branch that fails closed: no flush, no switch, no active
pointer write, and a safe `EditorAlert` (`"This isn't a saved App copy."`,
localised in English and Traditional Chinese) instead. Because the check
happens before any mutation, the currently open document, its scope, and
the durable active-document pointer are all left byte-for-byte untouched
— verified directly in the new tests (scope `stopCount == 0`, still
`isAccessing`, unchanged document id, unchanged active pointer).

`LibraryAssetOpenError` (previously scoped to only
`openLibraryExternalAsset(url:)`'s `sourceUnreachable` case) gained the new
`notAnAppCopy` case and an updated doc comment describing both.

### New tests

`Tests/PhotoLibraryCoreTests/PhotoDocumentStoreListingTests.swift` (+2):

- `testRefreshAppStorageProjectionRelativePathNeverContainsLocalPathFragments`
  — a working URL deliberately shaped like a real on-disk location (a
  fake home-directory name, `Library/Application Support`, the store's own
  `Documents/<id>` layout) is projected; the resulting `relativePath` is
  asserted to equal exactly `"<id>/<filename>"` and to contain none of
  those real path fragments — nor the temp/App-container root itself.
  Also checks the synthetic library's `rootURL.path` doesn't contain the
  real root either.
- `testRefreshAppStorageProjectionChildDirectoriesExposeOnlyTheVirtualDocumentUUID`
  — a real `childDirectories(libraryID: .appStorage, parent: "")` query
  (the folder-tree primitive a library browser would actually call)
  returns exactly one node, named after the document's UUID, and
  contains none of `Users`/the home-directory name/`Application Support`.

`Tests/EditorCoreTests/PhotoDocumentEditorLibraryOpenTests.swift` (+2):

- `testOpeningAppCopyWithAMismatchedInPlaceDocumentIDFailsClosed` — an
  `.inPlace` document opened through `.appCopy(documentID:)` while a
  different document is already open: the open document's id, its scope
  (`stopCount == 0`, still `isAccessing`), the `Documents/` directory
  contents, and the active pointer are all asserted unchanged; a safe
  alert appears instead.
- `testOpeningAppCopyWithAMismatchedInPlaceDocumentIDWithNoCurrentDocumentOpensNothing`
  — the same mismatch with nothing open yet: no document is fabricated,
  the active pointer stays unset.

### Verification (review fix round 1)

```zsh
swift test --filter 'PhotoDocumentStoreListingTests|PhotoDocumentEditorLibraryOpenTests'
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test
git diff --check f839439..HEAD
```

Results:

- `PhotoDocumentStoreListingTests|PhotoDocumentEditorLibraryOpenTests`:
  **18 tests, 0 failures** (9 + 9, run 3×, 0 flakes; 4 new since the prior
  round).
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc
  -warnings-as-errors`: **exit 0**, no warnings. No sandbox/module-cache
  permission failure was encountered.
- Full `swift test`: **1,014 tests, 9 skipped, 0 failures** (1,010 before
  this round + 4 new = 1,014). The 9 skips are the same pre-existing,
  host-dependent security-scoped-bookmark skips, not new.
- `git diff --check f839439..HEAD`: **PASS**, no whitespace errors.
- `rg -n 'TBD|TODO|FIXME|fatalError|try!|as!'` over the two changed
  production files: **no hits**.

### Remaining concerns

None blocking.

## Not push / merge / rebase / Task 5

- No `git push`, `git merge`, or `git rebase` was run at any point.
- No Task 5 file (`LibraryBrowserDependencies.swift`,
  `LibraryBrowserSession.swift`, `LibrarySelection`, `LibraryBrowserLoadState`,
  `GridRestorationState`) was created or touched.
- Exactly one commit is expected from this task (production + test code +
  this report together, per the user's explicit single-commit request),
  created after this report was written.
