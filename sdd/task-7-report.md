# Task 7 report — Add the paged thumbnail grid, search, sorting and editor return

## Status

DONE — implemented via `superpowers:subagent-driven-development` (fresh
implementer subagent, task-scoped reviewer subagent, one fix round), and
**APPROVED** on re-review of the fix round. No further Task 7 changes
required. Pending Codex pre-landing review of this branch, matching the
pattern already established for Tasks 1-6.

- Baseline HEAD before Task 7 work: `f28e68f` (Task 6 Codex-approved, review
  fix rounds 1-2 landed).
- Task 7 stayed within its own boundary: the three new
  `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/Pad*.swift` files the
  plan names, the modifications it lists, and two new test files. No Task
  8/9 file (`Tests/PhotoLibraryCoreTests/LibraryRemovalSafetyTests.swift`,
  `Tests/LumaHarborIntegrationTests/MultiSourceFailureRecoveryTests.swift`,
  `Tests/LumaHarborAppTests/LibraryViewModelTransitionTests.swift`,
  `Scripts/run-ipad-library-acceptance.zsh`,
  `docs/testing/reports/2026-08-26-ipad-multi-source-library.md`) was
  created or touched. No push, merge, rebase, or amend was performed at any
  point.
- Executed via `superpowers:subagent-driven-development`: one implementer
  subagent built and committed the task; one task-reviewer subagent found 4
  Important findings (0 Critical); one fix subagent addressed all 4 in a
  second commit; the task-reviewer subagent re-reviewed and returned
  **Approved** with no new issues.

## Commit hashes

- `70ca1b6` — feat: browse paged RAW thumbnails on iPad
- `eefe9c3` — fix: close pin/unpin race, surface cache-apply errors, add
  Step 5 test coverage (review round 1 fixes, see below)

## Changed files

- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryGrid.swift`
  (new) — the paged `LazyVGrid`, near-end prefetch, search field and sort/
  density toolbar controls.
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadThumbnailCell.swift`
  (new) — one grid cell: cached-then-live thumbnail fetch, pin/unpin over
  its visible lifetime, accessibility label, non-color status states.
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibrarySettingsView.swift`
  (new) — the thumbnail cache-budget setting (512 MiB/1/2/5/10 GiB).
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryView.swift`
  (modified) — delegates its content area to `PadLibraryGrid`, hoists the
  alert modifier to cover every load state, takes `services`.
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadRootView.swift`
  (modified) — adds the Settings toolbar button/sheet, threads `services`
  into `PadLibraryView`.
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadAppServices.swift`
  (modified) — injectable `userDefaults`, resolves the persisted cache
  budget before constructing `DiskCache` (previously always hardcoded the
  default, silently ignoring an earlier launch's setting), adds
  `thumbnailSourceURL(for:)` for App-copy thumbnail resolution.
- `Sources/EditorCore/LibraryBrowserSession.swift` (modified) — two small,
  fully-tested additions: `folder(for:)` (a `sources.first(where:)` lookup
  consolidated in one place) and `isSortFixedByScope` (true only for
  `.smart(.recentlyEdited)`, so the toolbar can disable its own sort
  control rather than offer a no-op — the actual sort override already
  lives in `PhotoIndexStore`, this is UI-only).
- `Sources/PhotoLibraryCore/Cache/ThumbnailProvider.swift` (modified) —
  `setByteBudget(_:) async throws` passthrough to the underlying
  `DiskCache`, the smallest bridge needed for Step 5 to actually work
  (see "Two bounded gap-closures" below).
- `Sources/Localization/Resources/en.lproj/Localizable.strings` /
  `zh-Hant.lproj/Localizable.strings` (modified) — 21 new keys plus 1 more
  in the fix round (22 total), alphabetically inserted, both languages for
  every new visible string.
- `Tests/EditorCoreTests/LibraryBrowserGridFlowTests.swift` (new) — 7
  tests: near-end sentinel prefetch, rapid scope/search/sort burst showing
  only the final generation, editor-return restoration by `PhotoID`,
  missing-anchor fallback to page one, offline-selection alert, plus
  `folder(for:)`/`isSortFixedByScope` coverage.
- `Tests/AdjustmentUITests/PadLibraryAccessibilityContractTests.swift`
  (new) — source-parsing contract tests (the established pattern for
  `.swiftpm`-package files no test target can compile), extended in the fix
  round with 5 more tests for the cache-budget setting.
- `Tests/PhotoLibraryCoreTests/ThumbnailProviderTests.swift` (modified in
  the fix round) — 1 new test for `setByteBudget(_:)`'s forwarding/eviction
  behavior.
- `sdd/task-7-report.md` (this file)

No other file was modified.

## Requirement-by-requirement mapping (plan Task 7)

### Step 1 — Failing browser flow tests

`LibraryBrowserGridFlowTests.swift`'s 7 tests cover exactly the five named
scenarios (near-end sentinel, rapid-change final-generation-only,
`PhotoID`-based restoration, missing-anchor fallback, offline-selection
alert) plus the two new `LibraryBrowserSession` members this task adds.
TDD evidence (RED with the two new members removed, GREEN restored) is in
the implementer's working report (see "Full working report" below).

### Step 2 — Grid and thumbnail cell

`PadLibraryGrid` uses `LazyVGrid` keyed by `PhotoAsset`'s `PhotoID`-backed
`Identifiable` conformance, and triggers `library.loadNextPage()` once a
visible cell is within the last 20 items of `library.photos` —
`LibraryBrowserSession.loadNextPage()`'s existing synchronous dedup guard
(already tested in Task 5) absorbs any duplicate calls from the resulting
per-cell `onAppear` burst, with no new dedup logic added.

`PadThumbnailCell` ports the Mac app's `ThumbnailView`/`PhotoGridCell`
cached-then-live-fetch pattern (`Sources/LumaHarborApp/Views/ThumbnailView.swift`)
to iOS's `UIImage`/`Image(uiImage:)` in place of AppKit's `NSImage`.
`.task(id: photo.id)` starts the fetch only while the cell is part of the
view tree; the cache entry is pinned only for that same visible lifetime.

### Step 3 — Toolbar query controls

Filename search via `.searchable`, bound through `library.searchText`/
`library.updateSearchText(_:)` — the session's existing 250 ms debounce is
reused as-is, not reimplemented. Four sorts offered from a `Menu`, disabled
while `library.isSortFixedByScope` is true. A grid-density preference
(`PadLibraryGridDensity`: small/medium/large) persisted via `@AppStorage`.

### Step 4 — Accessibility and localisation

`PadThumbnailCell`'s accessibility label joins filename, capture date (when
available), source display name, connection/error status, and edited state
into one `.accessibilityElement(children: .ignore)` label. Offline/error
states each pair a distinct SF Symbol with caption text — never color
alone. 44×44 pt minimum hit regions on the cell, sort menu, density menu,
and Settings button. 21 new strings (22 after the fix round) added
alphabetically to both `en.lproj` and `zh-Hant.lproj`; the working report
records a verification pass confirming both files parse cleanly with
identical key sets and zero duplicates.

### Step 5 — Cache-budget setting

`PadLibrarySettingsView` offers the five plan-mandated discrete choices
(512 MiB/1/2/5/10 GiB), persisted under `UserDefaults` key
`PadLibraryThumbnailCacheByteBudget`, resolving any absent/invalid/
out-of-range stored value to exactly `.gib2` (2 GiB) rather than an
unclamped budget. Selecting a row persists it and calls
`services.thumbnailProvider.setByteBudget(_:)` immediately. Does not import
or reference `Sources/LumaHarborApp/AppServices.swift`'s Mac `CacheBudget`
constants (global constraint: Mac defaults must not change).

### Two bounded gap-closures beyond the plan's literal file list

The plan's Task 7 file list does not include `ThumbnailProvider.swift` or
`PadAppServices.swift`, but Step 5 cannot work without touching one of
them (`ThumbnailProvider` held its `DiskCache` as `private let cache`, and
`PadAppServices` only exposed `thumbnailProvider`, not the raw cache).
Anticipated and pre-authorized before dispatch, matching the established
convention (Task 6's report documents the same kind of bounded addition)
of documenting anything added beyond the plan's literal text rather than
silently expanding scope:

1. `ThumbnailProvider.setByteBudget(_:) async throws` — a one-line forward
   to `cache.setByteBudget(_:)`. No other new surface on `ThumbnailProvider`.
2. `PadAppServices.thumbnailSourceURL(for:) async -> URL?` — not
   pre-flagged by name, but the same shape of gap: rendering a thumbnail
   needs a source file URL, and `PhotoLibraryService.sourceURL(for:)`
   documents itself as unsafe for a projected App-copy photo (its `rootURL`
   is a synthetic placeholder). Mirrors `resolveOpenAsset`'s existing
   `.appStorage` vs. everything-else split rather than inventing a new one,
   and adds no new public surface to `PhotoLibraryCore` or `EditorCore`.

## New localized strings

22 new keys total (21 from the initial implementation, 1 more —
`"Couldn't update the cache size"` — from the fix round), inserted
alphabetically into both `en.lproj` and `zh-Hant.lproj` `Localizable.strings`,
matching the existing flat-list convention. Both files verified to parse
cleanly with identical key sets and zero duplicates after every change.

## Verification

- `swift test --filter 'LibraryBrowserGridFlowTests|PadLibraryAccessibilityContractTests'`
  — 16/16 pass (initial implementation).
- `swift test --filter 'LibraryBrowserGridFlowTests|PadLibraryAccessibilityContractTests|ThumbnailProviderTests'`
  — 40/40 pass (after the fix round).
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
  — succeeds, no warnings (both rounds).
- `git diff --check` — clean (both rounds).
- `swift test` (full suite) — 1068 tests / 9 skipped / 0 failures (initial),
  1074 tests / 9 skipped / 0 failures (after the fix round: +1
  `ThumbnailProviderTests`, +5 `PadLibraryAccessibilityContractTests`).
- `(cd Apps/LumaHarborPad.swiftpm && xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build)`
  — **BUILD SUCCEEDED**, both rounds.

Full TDD evidence (RED/GREEN transcripts for every new test) and the
implementer/fix-subagent working notes are preserved in this worktree's
internal scratch report (not repo-tracked, per this session's
`subagent-driven-development` convention):
`sdd/task-7-report.md` under `.git/worktrees/codex-ipad-multi-source-library-durability/`.

## Review round 1 (task-reviewer subagent)

**Verdict on the initial commit (`70ca1b6`): Needs fixes** — spec-compliant
structurally (all 6 steps produced, no Task 8/9 file touched, Mac
`CacheBudget` untouched, no RAW-mutation path, single commit), but 4
Important findings, 0 Critical:

1. **Pin/unpin race** (`PadThumbnailCell.swift`) — `.task(id:)`'s `pin()`
   and a separate `.onDisappear { Task { unpin() } }` were two
   independently-scheduled tasks with no ordering guarantee; a fast
   appear/disappear could unpin before pin ever landed, permanently
   stranding a pinned cache entry (pinned entries are exempt from
   eviction), progressively defeating Step 5's own cache-budget setting
   over a long scroll session.
2. **Silently swallowed cache-apply error** (`PadLibrarySettingsView.swift`)
   — `apply(_:)` used `try?`, discarding any `setByteBudget` failure with
   no user-facing indication.
3. **No test for the new `ThumbnailProvider.setByteBudget(_:)`** — shipped
   with zero coverage despite living in a normal, fully-testable SPM
   target.
4. **Zero test coverage for Step 5's settings screen** — the five exact
   byte constants, default-to-2GiB fallback, and immediate-apply behavior
   were entirely untested.

Several Minor findings were also recorded (two independent 2 GiB constants
with nothing keeping them in sync, one small pre-existing-pattern
duplication between `PadLibraryGrid`/`PadLibrarySidebar` status messages, a
necessary test-fixture duplication justified by the file-list constraint,
an O(n) prefetch scan not correctness-breaking at page-size-100 scale, and
zh-Hant leaving unit abbreviations like "1 GB" untranslated) — none
blocking, none fixed in this round, recorded for the record only.

## Review round 1 fixes (commit `eefe9c3`)

All 4 Important findings fixed, none of the Minor findings touched:

1. **Pin/unpin race** — replaced the two independently-scheduled modifiers
   with a single `.task(id:)` that sequences both:
   ```swift
   .task(id: photo.id) {
       await provider.pin(photoID: photo.id)
       defer { Task { await provider.unpin(photoID: photo.id) } }
       await load()
   }
   ```
   `.onDisappear` deleted entirely. `defer`'s body is only *registered*
   after `pin()`'s `await` already returned, and only *dispatched* once
   `load()`'s scope exits — so `unpin` can never be dispatched before
   `pin` has completed for the same cell lifecycle. No new test possible
   (same `.swiftpm`-package tooling constraint as elsewhere); verified by
   walked-through ordering argument and a clean strict-concurrency build.
2. **Silently swallowed cache-apply error** — `apply(_:)` now does
   `do { try await services.thumbnailProvider.setByteBudget(...) } catch { alert = SafeErrorPresentation.alert(...) }`,
   wired to a `.alert(item:)` in the same shape `PadLibraryView` already
   uses. New localized string in both languages.
3. **`ThumbnailProvider.setByteBudget(_:)` test** — added
   `testSetByteBudgetForwardsToTheUnderlyingCacheAndPrunesImmediately` to
   `Tests/PhotoLibraryCoreTests/ThumbnailProviderTests.swift`, a genuine
   forwarding/eviction behavioral test (RED against a stubbed no-op,
   GREEN against the real passthrough). Error-propagation was verified by
   code-reading rather than a forced-failure test: `DiskCache.setByteBudget`'s
   only fallible step is already internally `try?`-swallowed and cannot
   practically throw today — an explicitly allowed judgment call.
4. **Step 5 test coverage** — extended
   `PadLibraryAccessibilityContractTests.swift` with 5 new source-parsing
   tests: the five exact byte constants, the exact `.gib2` default, the
   non-force-unwrap fallback, the `setByteBudget` call site, and (tied to
   finding #2) that a real `do`/`catch`+alert exists rather than `try?`.

## Review round 2 (post-fix, task-reviewer subagent)

**Verdict: Approved.** All 4 Important findings independently re-verified
as genuinely fixed (not superficially) with file:line evidence for each;
the reviewer independently re-derived the pin/unpin ordering argument
rather than trusting the fix report, and independently confirmed the
"`DiskCache.setByteBudget` cannot practically throw today" claim by
reading `DiskCache.swift`'s `setByteBudget`/`evictIfNeeded` directly. No
new Critical/Important issue introduced by the fix round. One pre-existing,
out-of-scope structural note was recorded (non-ref-counted pin `Set` could
in principle race across two *different* cell instances for the same
`photo.id` torn down and remounted quickly — a Task 5/6 pin-API property,
untouched by this task, not part of this round's diff) but explicitly not
treated as a new finding.

## Remaining concerns

- **The pin/unpin non-ref-counting property noted in review round 2** is
  pre-existing (`DiskCache.pinnedKeys` has been a plain `Set` since Task 3)
  and out of this task's scope — flagged for awareness, not an action item
  here.
- **Fixture duplication**: `LibraryBrowserGridFlowTests.swift`'s
  `GridFlowFakeEnvironment` duplicates a meaningful subset of
  `LibraryBrowserSessionTests.swift`'s private `FakeLibraryEnvironment`,
  since the latter's fixtures are `private` and that file isn't in this
  task's file list to widen access on. Worth extracting to a shared
  fixture module if a future task adds another `LibraryBrowserSession`
  test file.
- **Minor duplication left as-is**: `PadLibraryGrid.sourceStatusMessage(for:)`
  duplicates `PadLibrarySidebar.statusMessage(for:)`'s 4-case switch;
  `PadLibrarySidebar.swift` isn't in this task's file list.
- **Accessibility contract tests are source-text pattern matching, not
  real view instantiation** — the same `.swiftpm`-package tooling
  constraint every prior task's own equivalent tests have documented;
  cannot confirm actual runtime tap-target sizes or the exact
  VoiceOver-composed string without on-device/simulator UI testing.
- **zh-Hant leaves unit abbreviations ("1 GB", "2 GB", etc.) identical to
  English** — conventional for unit abbreviations in Traditional Chinese
  UI copy, not treated as a real translation gap.

## Not push / merge / rebase / Task 8

- No `git push`, `git merge`, `git rebase`, or `git commit --amend` was run
  at any point, across either commit.
- No Task 8 or Task 9 file was created or modified.
- Two commits are expected from this task: `70ca1b6` (implementation) and
  `eefe9c3` (review round 1 fixes).
