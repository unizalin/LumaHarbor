# Task 5 report — Build the testable browser state machine in `EditorCore`

## Status

DONE

- Baseline HEAD before Task 5 work: `85b1e03` (`fix: stop App Storage
  projection from leaking local paths and validate App-copy opens`) — Task 4
  has been Codex re-reviewed and **APPROVED**.
- Task 5 stayed strictly within its own boundary: `LibraryBrowserDependencies`,
  `LibraryBrowserSession`, their test file, and the small, necessary
  localization additions the new alerts and errors require. No Task 6 file
  (`PadAppServices.swift`, `PadLibraryModel.swift`, `PadLibraryView.swift`,
  `PadLibrarySidebar.swift`, `PadLibraryGrid.swift`, `PadThumbnailCell.swift`,
  `PadLibrarySettingsView.swift`) was created or touched, and no iPad app
  shell code was modified. No push, merge, rebase, amend, or squash was
  performed.
- Executed via the `superpowers:executing-plans` skill: the plan (Task 5's
  section specifically) was read and reviewed first; this report is that
  skill's completion report. Given the explicit single-task scope
  ("這次只做 Task 5 邊界，不要拆到 Task 6/7"), work was done directly rather
  than fanned out across subagents.

## Commit hash

`7a8d140` — feat: add testable multi-source library browser session
(round-1 review fix commit hash is recorded in "Review fix round 1" below)

## Changed files

- `Sources/EditorCore/LibraryBrowserDependencies.swift` (new)
- `Sources/EditorCore/LibraryBrowserSession.swift` (new)
- `Tests/EditorCoreTests/LibraryBrowserSessionTests.swift` (new)
- `Sources/Localization/Resources/en.lproj/Localizable.strings` (modified —
  new user-facing strings, see below)
- `Sources/Localization/Resources/zh-Hant.lproj/Localizable.strings`
  (modified — Traditional Chinese translations for the same strings)
- `sdd/task-5-report.md` (this file)

No other file was modified. In particular, no Task 1–4 production file
(`PhotoIndexStore.swift`, `LibraryFolder.swift`, `PhotoLibraryService.swift`,
`PhotoDocumentEditor.swift`, etc.) was touched — Task 5 only *consumes*
those, exactly as the plan specifies.

## Requirement-by-requirement mapping

### Produced types/methods

| Plan requirement | Delivered as |
|---|---|
| `LibraryBrowserDependencies` | Exact struct/init shape from the plan's code block, in `LibraryBrowserDependencies.swift`, plus a `.live(service:)` static factory (see below) |
| `LibrarySelection` | Exact enum from the plan, in `LibraryBrowserSession.swift`, with an internal `scope` bridge to `LibraryScope` and an internal `matching(_:)` inverse used by restoration |
| `LibraryBrowserLoadState` | Exact enum from the plan |
| `GridRestorationState` | Exact struct from the plan |
| `LibraryBrowserSession` | `@MainActor final class ObservableObject`, publishing `sources`, `selection`, `sort`, `searchText`, `photos`, `nextCursor`, `loadState`, `sourceProgress`, `alert`, `restorationAnchor` |
| `select(_:)` | `public func select(_ selection: LibrarySelection)` |
| `loadNextPage()` | `public func loadNextPage()` |
| `openAsset(for:)` | `public func openAsset(for photo: PhotoAsset) async -> LibraryOpenAsset?` — takes the full `PhotoAsset` (already in hand from `photos`) rather than a bare `PhotoID`, so the gate check below can read the photo's own `libraryID` directly instead of re-deriving it |

Beyond the plan's literal list, three small additions were needed for the
struct's own dependency closures to actually be exercised by something (an
incomplete deliverable would otherwise leave `addSource`/`relinkSource`/
`removeSource`/`childDirectories`/`runScan` as unused dead weight):

- `addSource(at:sourceKind:)`, `relinkSource(_:to:)`, `removeSource(_:)` —
  thin wrappers with light dedicated test coverage (source-lifecycle
  correctness itself is Task 2's, already tested there).
- `childDirectories(libraryID:parent:)` — thin pass-through for the
  sidebar's lazy folder tree (Task 1's `LibraryDirectoryNode`).
- `scanSource(_:)` — starts Task 3's bounded scan for one source and folds
  its events into `sourceProgress`. Not in the plan's literal "Produces"
  list, but required for test area 7 (per-source progress) to have
  anything to observe; selecting a source does **not** implicitly start
  scanning it — a caller (sidebar action, or an app-launch sweep) decides
  when.

### Consumed APIs

- **Task 1**: `LibraryQuery`, `PhotoPage`, `PhotoPageCursor`, `LibraryScope`,
  `PhotoSort`, `LibraryDirectoryNode` — used directly in `fetchPage`/
  `childDirectories`'s signatures and `currentQuery`'s construction.
- **Task 2**: `LibraryFolder.connectionState`/`.sourceKind` — read directly
  in `openAsset(for:)`'s gate and `.live(service:)`'s `resolveOpenAsset`.
- **Task 3**: `LibraryScanEvent` and its five cases — folded into
  `LibrarySourceScanProgress` by `handle(_:for:)`. `.live(service:)`'s
  `runScan` iterates `PhotoLibraryService.scan(libraryID:)` (the existing
  acknowledged `LibraryScanSequence`) directly, `await`ing the handler for
  every event before the next one is produced — never bridged through a
  buffering `AsyncStream` (verified by reading the implementation: the
  `for await event in service.scan(...) { await handler(event) }` loop is
  the entire body).
- **Task 4**: `LibraryOpenAsset` is `openAsset(for:)`'s return type;
  `.live(service:)`'s `resolveOpenAsset` distinguishes a projected App copy
  (`folder.sourceKind == .appStorage` → `.appCopy(documentID:
  photoID.rawValue)`, reusing Task 4's "document UUID *is* the `PhotoID`"
  identity) from an external indexed photo (`.external(url:sourceKind:)`,
  via `service.sourceURL(for:)`). `LibraryBrowserSession` never imports or
  references `PhotoDocumentEditor` itself — the caller (Task 6) is expected
  to hand `openAsset(for:)`'s result to
  `PhotoDocumentEditor.openLibraryAsset(_:)`, keeping the two composed
  rather than coupled.

### Test coverage against the 8 required areas

All in `Tests/EditorCoreTests/LibraryBrowserSessionTests.swift` (26 tests),
against a hand-written `FakeLibraryEnvironment` actor (scriptable
sources/pages/scan events/resolutions, with a level-triggered gate for
deterministic overlap tests — the same `InspectionGate` pattern already
used elsewhere in this codebase's tests, not a new idiom).

1. **Startup restoration** — `testStartupRestoresSourcesAndLoadsFirstPage`,
   `testStartupRestorationFailureSetsFailedLoadStateWithAPathFreeAlert`,
   `testCallingStartTwiceOnlyRestoresOnce`.
2. **Paging** — `testLoadNextPageAppendsToPhotos`,
   `testDuplicateConcurrentLoadNextPageCallsFetchOnlyOnce` (gates the fetch,
   fires `loadNextPage()` three times back-to-back, proves only one fetch
   ever entered), `testLoadNextPageIsANoOpWhenThereIsNoNextCursor`.
3. **Query generation / stale response discard** —
   `testSwitchingSelectionDuringAnOutstandingFetchDiscardsTheStaleResult`,
   `testChangingSortDuringAnOutstandingFetchDiscardsTheStaleResult`.
4. **Search debounce cancellation** —
   `testSearchDebounceOnlyLetsTheLastUpdateReachTheIndex` (four rapid
   `updateSearchText` calls, asserts `fetchPage` only ever saw the last
   one), `testUpdatingSearchTextToTheSameValueDoesNotRequery`.
5. **Page window bound** —
   `testPageSizeDefaultsToOneHundredAndNeverExceedsTwoHundred`,
   `testPhotosArrayStaysBoundedToTheCurrentWindowPlusTwoPrefetchedPages`
   (5 pages of 100 fetched, asserts `photos.count <= 300` and that the
   *oldest* page was evicted, not the newest).
6. **`openAsset(for:)`** —
   `testOpenAssetForAnOnlineExternalSourceResolvesViaTheDependency`,
   `testOpenAssetForAnAppStorageAssetResolvesToAnAppCopy`,
   `testOpenAssetGatesAnOfflineSourceWithoutCallingResolveOpenAsset`,
   `testOpenAssetGatesANeedsAuthorizationSourceWithoutCallingResolveOpenAsset`,
   `testOpenAssetAllowsAReadOnlySourceThrough` (see the bounded concern
   below), `testOpenAssetSurfacesASafeAlertWhenResolutionFails`.
7. **Per-source progress** — `testScanEventsUpdatePerSourceProgress`
   (`.started`/`.photosIndexed`/`.photoFailed`),
   `testScanFailureUpdatesProgressWithASafeAlertAndPathFreeMessage`
   (`.failed`), `testScanningAnAlreadyScanningSourceIsANoOp`. `.finished`
   is exercised structurally (the scan task completing and
   `scanTasks[libraryID]` clearing) but not with a literal
   `LibraryScanEvent.finished(LibraryScanResult(...))` value — see the
   bounded concern below.
8. **Restoration anchor** — `testRestoreGridPositionFindsTheAnchorAcrossMultiplePages`
   (3 scripted pages, anchor on page 2, asserts the walk stops there rather
   than continuing to page 3), `testRestoreGridPositionFallsBackToPageOneWhenQueryRunsOutOfPages`
   (anchor genuinely absent from the query's only page, asserts a fresh
   page one loads and `loadState` never becomes `.failed`),
   `testRestoreGridPositionIsANoOpWithNoRecordedAnchor`.

## Implementation notes

- **Generations.** `queryGeneration: UInt64`, incremented on every
  scope/search/sort change and on `restoreGridPosition()`, mirrors
  `PhotoDocumentEditor.OperationToken` exactly: captured synchronously
  before the first `await` in every operation, checked before every
  `@Published` mutation that operation makes.
- **Debounce.** `updateSearchText(_:)` updates `searchText` immediately
  (so a bound text field stays responsive) but defers the actual re-query
  by 250 ms, cancelling any still-pending debounce `Task` on every call —
  only the last call in a burst ever survives to fire. The interval itself
  (`LibraryBrowserSession.searchDebounceDelay`) is not part of
  `LibraryBrowserDependencies`'s injected surface (the plan's given struct
  shape is followed exactly, with no added properties); it's an
  `internal static let` on the session instead, real 250 ms in tests too
  (no special test seam needed — the debounce tests just wait for it).
- **Page window.** `trimmedWindow(appending:to:)` appends then drops rows
  from the *front* once the total exceeds `pageSize * 3` (current page plus
  two prefetched ones) — verified to evict the oldest page first, keep the
  newest, and never grow past the cap even after many `loadNextPage()`
  calls.
- **`.live(service:)`.** A production dependency factory in
  `LibraryBrowserDependencies.swift`, mirroring
  `PhotoDocumentEditorDependencies.live(...)`'s existing precedent exactly
  (same file, same pattern) — every closure delegates directly to
  `PhotoLibraryService`/`PhotoIndexStore` with no logic of its own to test
  independently. Not unit-tested here for the same reason
  `PhotoDocumentEditorDependencies.live` isn't: it has no behavior beyond
  what those already-tested types provide.
- **No new state machine.** `LibraryBrowserSession` is the *only* new
  state-holding type Task 5 adds; it does not duplicate or shadow anything
  `PhotoDocumentEditor` already owns, and never touches a RAW file, a
  bookmark, or a sidecar directly — everything I/O-adjacent goes through
  `LibraryBrowserDependencies`.

## New localized strings

Both `en.lproj` and `zh-Hant.lproj` `Localizable.strings` gained the same
seven new keys the new alerts/errors need: `"Can't open this photo"`,
`"This source isn't currently reachable."`, `"Couldn't load your library"`,
`"Couldn't load photos"`, `"Couldn't add this source"`,
`"Couldn't reconnect this source"`, `"Couldn't remove this source"`,
`"This source couldn't finish scanning."`. `"Reconnect the source, then try
again."` (the offline-gate alert's `nextStep`) already existed from Task 4
and was reused as-is.

## Verification

```zsh
swift test --filter LibraryBrowserSessionTests
swift test --filter EditorCoreTests
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test
git diff --check
```

Results:

- `LibraryBrowserSessionTests`: **26 tests, 0 failures** (run 3×, 0 flakes).
- `EditorCoreTests` (full target): **90 tests, 0 failures**.
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc
  -warnings-as-errors`: **exit 0**, no warnings. No sandbox/module-cache
  permission failure was encountered.
- Full `swift test`: **1,040 tests, 9 skipped, 0 failures**, run 2× — **both
  runs completed and exited cleanly** (17.6–17.8 s each), including
  `PendingLeaseSubprocessTests.testAProcessKilledWithSIGKILLReleasesItsLeaseForReconciliation`
  (0.029 s, passed both times). The hang Codex reported on the prior round
  did **not** reproduce here — this session's environment ran the full
  suite twice with no hang and no residual `xctest`/`swift-frontend`
  process afterward (`pgrep -fl 'xctest|swift-frontend'` → none). Per the
  user's instruction, this is reported as observed, not assumed away: the
  full suite is confirmed to complete cleanly in this environment on this
  attempt, not asserted to be hang-proof everywhere.
- `git diff --check`: **PASS**, no whitespace errors.
- `rg -n 'TBD|TODO|FIXME|fatalError|try!|as!'` over both new production
  files: **no hits**.
- No RAW read/write/move/rename/delete path was added — `LibraryBrowserSession`
  never touches a file directly, only `LibraryBrowserDependencies`'s
  closures, which delegate to already-audited Task 1–4 code.
- No third-party dependency was added (`Package.swift` untouched this
  round).

## Remaining concerns

None blocking. Three bounded points worth flagging for Task 6/7:

1. **Read-only intent cannot cross into `LibraryOpenAsset`.** Per this
   task's explicit instruction, `openAsset(for:)` allows a `.readOnly`
   source's photos to open (only `.offline`/`.needsAuthorization` are
   gated) but has no way to signal "open this read-only" through Task 4's
   `LibraryOpenAsset`/`PhotoDocumentEditor.openLibraryAsset(_:)` — neither
   has a read-only case or parameter, and Task 5 was explicitly told not to
   expand Task 4's editor API to add one. A read-only source's photo
   therefore currently opens exactly like a fully-writable one; whether
   that needs a Task 4 API change or a different mechanism is a decision
   for whichever task next needs to enforce it, not made here.
2. **`LibraryScanEvent.finished(LibraryScanResult)` couldn't be
   constructed in this test file.** `LibraryScanResult` (`PhotoLibraryCore`)
   has no explicit `public init` — Swift's synthesized memberwise
   initializer for a `public` struct is `internal`, even when every stored
   property is `public`, unless the type defines its own public
   initializer. `EditorCoreTests` is a different module than
   `PhotoLibraryCore`, so it cannot construct one to script a `.finished`
   event directly. `handle(_:for:)`'s `.finished` branch is simple (one
   line, matching every other case's shape) and the scan-task-completion
   lifecycle around it is covered without literally needing that one case's
   payload, but a literal test asserting `sourceProgress[id]?.phase ==
   .finished` from a real `.finished` event was not possible here. Not a
   defect in Task 5's own code; flagged in case a future task wants
   `LibraryScanResult` to gain a public initializer for testability.
3. **No production caller yet.** `LibraryBrowserSession`/
   `LibraryBrowserDependencies` have no call site outside their own test
   file — Task 5's scope, per the plan, only produces this state machine;
   composing it with `PhotoDocumentEditor` and a SwiftUI shell is Task 6's
   job and was deliberately not anticipated or duplicated here.

## Review fix round 1

Codex's pre-landing re-review of the Task 5 commit (`7a8d140`) returned
**BLOCKED** with two findings, both in `LibraryBrowserSession.swift`.

### Finding 1 (P1, blocking): startup could permanently lose `sources` on a generation change

**Finding.** `restoreSourcesAndLoadFirstPage()` captured `queryGeneration`
before calling `dependencies.restoreSources()`, then gated *both*
`sources = restored` and the default first-page load behind
`guard generation == queryGeneration else { return }`. Since `start()` is a
one-shot no-op after its first call (`guard startupTask == nil else {
return }`), a `select(_:)`/`setSort(_:)`/`updateSearchText(_:)` call that
arrived before `restoreSources()` itself returned would bump
`queryGeneration` and cause the whole startup result — including `sources`
— to be discarded, with nothing left to ever populate `sources` again. This
conflated two different things under one guard: "don't let a stale *page
query* result land" (correct) and "don't let stale *source list* data land"
(wrong — `sources` isn't a query result at all, it doesn't go stale the way
a page of photos does).

**Fix.** `restoreSourcesAndLoadFirstPage()` now publishes `sources`
unconditionally, with no generation guard at all. Only the *default first
page* this call would otherwise load remains generation-gated: if a newer
query has already begun by the time `restoreSources()` resolves, that
query's own task already owns `photos`/`nextCursor`/`loadState`, so the
default query's page one is never even fetched (the guard is checked
*before* calling `loadFirstPage`, not after). The failure path was fixed
the same way: a `restoreSources()` throw is still reported as a
`loadState = .failed(...)` alert, but only if nothing newer has already
taken over `loadState`.

### Finding 2 (P1, blocking): `updateSearchText(_:)` left a stale-commit window until the debounce fired

**Finding.** `updateSearchText(_:)` updated `searchText` immediately but
left `queryGeneration` unchanged until the 250 ms debounce timer itself
called `beginNewQuery()`. For the entire debounce window, a fetch already
in flight (a first-page or next-page fetch started by an earlier
selection/sort/search) still carried the *current* (unchanged) generation.
If that stale fetch happened to resolve during the window, its generation
check (`guard generation == queryGeneration`) still passed, and it could
commit its result to `photos`/`nextCursor`/`loadState` — even though
`searchText` had already visibly moved on to what the user just typed. This
directly violated the plan's own stated requirement ("capture it in every
task and discard late results") for the search-text case specifically.

**Fix.** `updateSearchText(_:)` now calls a new `invalidateCurrentQuery()`
synchronously, on every actual text change, *before* scheduling the
debounce task: it bumps `queryGeneration` and cancels `pageTask`
immediately, invalidating whatever is currently outstanding right away.
The debounce timer's `beginNewQuery()` (unchanged) still does the second
half — bump again, reset `photos`/`nextCursor`, and actually start the new
fetch — but only once the delay has elapsed. Splitting these into two
named steps (`invalidateCurrentQuery()` bumps-and-cancels-only;
`beginNewQuery()` bumps-and-starts) is what keeps "invalidate now" and
"fetch later" from being conflated the way the single previous call was.
`select(_:)`/`setSort(_:)` were already correct (they call
`beginNewQuery()` directly, with no debounce in between) and needed no
change.

### New tests

`Tests/EditorCoreTests/LibraryBrowserSessionTests.swift` (+4 tests, 26 → 30):

- `testStartupPublishesSourcesEvenWhenAQueryChangeArrivesWhileRestoringSources`
  — gates `restoreSources()`, calls `select(_:)` while it's still stuck,
  then releases it: asserts `sources` still publishes, the newer
  selection's own photos survive, and the stale default query is never
  even fetched (`fetchQueries.filter { $0.scope == .all }.count == 0`).
- `testStartupRestorationFailureAfterBeingSupersededDoesNotOverwriteTheNewerLoadState`
  — same setup but `restoreSources()` fails instead of succeeding: asserts
  the newer query's `.loaded` state survives the stale failure.
- `testUpdatingSearchTextDuringAnOutstandingFirstPageFetchDiscardsItEvenBeforeDebounceFires`
  — gates a first-page fetch, calls `updateSearchText(_:)` while it's
  stuck, releases it *well before* the 250 ms debounce could have fired:
  asserts the stale result never commits, and the debounced fetch for the
  new search text still applies once it actually runs.
- `testUpdatingSearchTextDuringAnOutstandingNextPageFetchDiscardsItEvenBeforeDebounceFires`
  — same shape, but the stuck fetch is a `loadNextPage()` call instead of
  a first-page one, per the review's explicit "first-page 或 next-page"
  requirement.

`FakeLibraryEnvironment` gained a `restoreSources()`-specific gate
(separate from the existing `fetchPage` gate), matching the same
level-triggered `InspectionGate`-style pattern already used for paging.

### Verification (review fix round 1)

```zsh
swift test --filter LibraryBrowserSessionTests
swift test --filter EditorCoreTests
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
git diff --check 85b1e03..HEAD
swift test
```

Results:

- `LibraryBrowserSessionTests`: **30 tests, 0 failures** (run 4×, 0
  flakes; 4 new since the prior round).
- `EditorCoreTests` (full target): **94 tests, 0 failures** (90 before
  this round + 4 new).
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc
  -warnings-as-errors`: **exit 0**, no warnings. No sandbox/module-cache
  permission failure was encountered.
- `git diff --check 85b1e03..HEAD`: **PASS**, no whitespace errors.
- Full `swift test`: **1,044 tests, 9 skipped, 0 failures**, completed and
  exited cleanly in 18.7 s (1,040 before this round + 4 new = 1,044).
  `PendingLeaseSubprocessTests.testAProcessKilledWithSIGKILLReleasesItsLeaseForReconciliation`
  passed (0.097 s), and no residual `xctest`/`swift-frontend` process
  remained afterward. As in the prior round, this is reported as observed
  on this attempt in this environment, not asserted to be hang-proof
  everywhere.

### Remaining concerns

None blocking.

## Not push / merge / rebase / Task 6

- No `git push`, `git merge`, or `git rebase` was run at any point.
- No Task 6 file was created or modified: `PadAppServices.swift`,
  `PadLibraryModel.swift`, `PadLibraryView.swift`, `PadLibrarySidebar.swift`,
  `PadLibraryGrid.swift`, `PadThumbnailCell.swift`,
  `PadLibrarySettingsView.swift` all remain untouched (most do not exist
  yet). No file under `Apps/LumaHarborPad.swiftpm/` was touched.
- No Task 7/8/9 file was touched either.
- Exactly one commit is expected from this task (production + test code +
  this report together, matching the single-commit pattern the user's
  instructions specify), created after this report was written.
