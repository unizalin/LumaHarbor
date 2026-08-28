# Task 6 report — Compose iPad services and adaptive library navigation

## Status

DONE — review fix rounds 1 and 2 applied (see below); pending re-review.

- Baseline HEAD before Task 6 work: `9fd22aa` (`fix: invalidate the
  outgoing query's page cursor on search-text change too`) — Task 5 has
  been Codex re-reviewed (round 2) and **APPROVED**.
- Task 6 stayed within its own boundary: the four new
  `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/Pad*.swift` files the
  plan names, plus the two existing app-shell files it explicitly allows
  modifying (`LumaHarborPadApp.swift`, `PadRootView.swift`), the required
  composition contract test, and the small set of new localized strings the
  new UI needs. No Task 7 file (`PadLibraryGrid.swift`,
  `PadThumbnailCell.swift`, `PadLibrarySettingsView.swift`) was created or
  touched. No Task 1–5 production file (`PhotoIndexStore.swift`,
  `LibraryFolder.swift`, `PhotoLibraryService.swift`,
  `PhotoDocumentEditor.swift`, `LibraryBrowserSession.swift`,
  `LibraryBrowserDependencies.swift`, etc.) was modified — Task 6 only
  *composes* those, exactly as the plan specifies. No push, merge, rebase,
  amend, or squash was performed.
- Executed via the `superpowers:executing-plans` skill, continuing directly
  from Task 5's approval ("開始").

## Commit hash

`ca34a4b` — feat: add adaptive iPad library navigation

## Changed files

- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadAppServices.swift`
  (new) — the app-lifetime composition root.
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryModel.swift`
  (new) — `public typealias PadLibraryModel = LibraryBrowserSession`, mirroring
  `PadEditorModel.swift`'s existing pattern.
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibrarySidebar.swift`
  (new) — the source/scope picker.
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryView.swift`
  (new) — the adaptive library container (sidebar + minimal content list).
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/LumaHarborPadApp.swift`
  (modified) — builds one `PadAppServices` in `init()`, never in `body`.
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadRootView.swift`
  (modified) — routes to `PadLibraryView` when nothing is open; renamed
  `model` to `editor` throughout now that a second model (`library`)
  exists; wires `services.refreshAppStorageProjection()`.
- `Tests/EditorCoreTests/PadLibraryCompositionContractTests.swift` (new)
- `Sources/Localization/Resources/en.lproj/Localizable.strings` (modified —
  new user-facing strings, see below)
- `Sources/Localization/Resources/zh-Hant.lproj/Localizable.strings`
  (modified — Traditional Chinese translations for the same strings)
- `sdd/task-6-report.md` (this file)

No other file was modified.

## Requirement-by-requirement mapping (plan Task 6)

### Step 1 — Composition contract tests

- `testPadLibraryModelFileIsOnlyATypealiasNoSecondStateMachine()` — source-
  parses `PadLibraryModel.swift` (via a `#filePath`-relative path computed at
  compile time), asserts it contains the exact typealias line and none of
  `class `, `struct `, `@Published`, `ObservableObject`, `func `.
- `testLibraryAndEditorShareOnePhotoLibraryServiceAndOnePhotoDocumentStore()`
  — the root-package compile/behavior contract: builds one real
  `PhotoLibraryService` and one real `PhotoDocumentStore` in a temp
  directory, constructs `LibraryBrowserSession` via
  `LibraryBrowserDependencies.live(service:)` and `PhotoDocumentEditor` via
  the same full explicit `PhotoDocumentEditorDependencies` initializer
  `PadAppServices` uses, then proves the pair is actually shared — not just
  type-compatible — by committing an App copy through `documentStore`,
  projecting it via `libraryService.refreshAppStorageProjection(from:)`, and
  reading it back through `libraryService.photos(inLibrary: .appStorage)`.
  This is also the first production-shaped exercise of the "no production
  caller yet" gap both Task 4's and Task 5's own reports flagged.
- `testLumaHarborPadAppConstructsServicesInsideInitNeverInBody()` — an
  additional third test (a bounded, deliberate addition beyond the plan's
  literal text): source-parses `LumaHarborPadApp.swift`, confirms
  `PadAppServices(` appears between `init() {` and `var body: some Scene {`,
  and does not appear again after `body` starts. This is what actually
  proves the plan's "never from `body`" requirement — the requirement is
  about the shipped app-shell file, not just something the file's own
  authoring style. Reported as a deliberate addition, matching this
  session's convention of documenting anything added beyond the plan's
  literal text.

  Naming note: the plan's own Task 6 prose says
  `LibraryBrowserDependencies.production(...)`; the already-shipped,
  Codex-approved Task 5 factory is named `.live(service:)`. This report
  uses `.live(service:)` throughout, as does all new code — the shipped
  public API was not renamed to match one inconsistent mention in a later
  task's text.

### Step 2 — `PadAppServices`

- Owns exactly one `ApplicationSupportLocations`, one `PhotoLibraryService`,
  one 2 GiB `DiskCache`/`ThumbnailProvider` pair, one `PhotoDocumentStore`,
  one `PadLibraryModel`, and one `PadEditorModel` — built once in
  `LumaHarborPadApp.init()`.
- Deliberately does **not** use `PhotoDocumentEditorDependencies.live(applicationSupportURL:)`
  for the editor side: that convenience mints its own private
  `PhotoDocumentStore`, which would leave the library side with no shared
  store to read committed App copies from. `PadAppServices` instead builds
  `PhotoDocumentEditorDependencies` via its full explicit initializer,
  replicating `.live`'s own internals exactly, with the one shared
  `documentStore` injected instead of a second one being minted.
- `refreshAppStorageProjection()` — the new method that actually wires
  `PhotoDocumentStore.committedDocuments()` (Task 4) into
  `PhotoLibraryService.refreshAppStorageProjection(from:)` (Task 4) in
  production for the first time. Best-effort (a failure never blocks
  browsing already-indexed external sources) and idempotent, matching Task
  4's own documentation of that method.
- `LumaHarborPadApp.init()` tries the real Application Support URL first;
  if `PadAppServices.init(applicationSupportURL:)` throws, it falls back to
  a fresh temporary directory rather than crashing on launch — the same
  "never crash on launch" philosophy `PadEditorModel`'s own pre-existing
  Application Support lookup already follows for the URL-lookup case, now
  extended to cover a services-construction failure too.

### Step 3 — Adaptive route container

- `PadRootView.content` now has four branches: an open document
  (`PadEditorView`), a pending relink prompt (unchanged from Task 4/pre-Task
  6), a document actively being prepared (unchanged), and — replacing the
  old static "Open a RAW photo" placeholder — `PadLibraryView` when nothing
  is open and nothing is preparing.
- `PadLibraryView` is regular-width vs. compact-width adaptive via
  `@Environment(\.horizontalSizeClass)`: regular width shows
  `PadLibrarySidebar` as a permanently visible 280pt-wide column; compact
  width shows the *same* `PadLibrarySidebar` presented from a toolbar
  button's sheet, exactly as the plan specifies ("presents the same
  `PadLibrarySidebar` from a toolbar button").
- The existing single-file "Open RAW…" toolbar button in `PadRootView` is
  untouched and remains available regardless of which route is showing —
  the plan's required secondary action.
- `PadRootView`'s own `model` property was renamed `editor` throughout
  (a pure rename, no behavior change) now that a second model (`library`)
  is also present — keeping `model` would have been ambiguous about which
  of the two it referred to.

### A bounded addition beyond the plan's literal text: closing the loop

The plan's Step 3 says routing switches to `PadEditorView` "when the editor
owns a document" but Task 6's own file list explicitly excludes the actual
thumbnail grid (`PadLibraryGrid.swift` is Task 7's). Without *something*
that can actually hand a photo to the editor, the adaptive route container
this task is about would have nothing to demonstrate it with. `PadLibraryView`
therefore includes a minimal, deliberately non-final content list (plain
filenames, not a grid) whose row tap calls `library.openAsset(for:)` and,
on success, `editor.openLibraryAsset(_:)` — proving the full library → editor
→ (on close) back-to-library round trip end to end, without anticipating
Task 7's grid UI. `PadLibraryView.body` also calls `library.start()` and
`library.restoreGridPosition()` in its own `.task {}`; the latter is a
no-op on first launch (no `restorationAnchor` yet) and restores the saved
query/anchor on every return from the editor.

`PadLibrarySidebar`'s "Add Source" flow also triggers one `scanSource(_:)`
call immediately after a source is successfully added — without this, a
newly added folder would sit permanently empty until some other, unrelated
trigger scanned it, which would make the source-adding feature look broken
end to end even though every underlying piece (Task 3's scan, Task 5's
`addSource`) works correctly in isolation.

## New localized strings

Added to both `en.lproj` and `zh-Hant.lproj` (alphabetically inserted,
matching the existing flat-list convention): `"Add Source"`, `"Library"`,
`"Needs Access"`, `"No sources yet"`, `"Read-only"`, `"Recently Edited"`,
`"Sources"`. `"All"`, `"App Copies"`, `"Offline"`, `"OK"`, `"Close"` already
existed and are reused as-is (no duplicate keys added).

## Verification

- `swift build` — succeeds (root package).
- `swift test --filter PadLibraryCompositionContractTests` — 3/3 pass.
- `swift test --filter EditorCoreTests` — 98/98 pass, 0 failures.
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
  — succeeds, no warnings.
- `git diff --check` — clean, no whitespace errors.
- `swift test` (full suite) — 1048 tests executed, 9 skipped, 0 failures,
  0 unexpected. No hang this run (the `PendingLeaseSubprocessTests` hang
  noted as a known, pre-existing risk in earlier tasks' reports did not
  recur here).
- `(cd Apps/LumaHarborPad.swiftpm && xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build)`
  — **BUILD SUCCEEDED**, no `error:` lines in the full log. This is the
  only way to compile-verify the `.swiftpm` app package itself (plain
  `swift build` inside `Apps/LumaHarborPad.swiftpm` fails with
  `no such module 'AppleProductTypes'` — an Xcode-toolchain-only module,
  confirmed as an environment limitation, not a code issue).

## Remaining concerns

- **Eventual consistency on `refreshAppStorageProjection()` timing.**
  `PadRootView`'s `.task {}` calls it once at launch (after
  `editor.performStartupSequence()` kicks off, not after it completes —
  that call is fire-and-forget by design) and again on every
  `editor.document?.id` change. A photo copied to this iPad during the
  current session shows up in the App Copies smart scope without a
  relaunch, but there is a small window between a copy committing and the
  next projection refresh where the App Copies scope could show a stale
  count if the user is looking at it at that exact moment. Not a
  correctness bug — bounded, self-healing on the next refresh.
- **Periodic/automatic rescanning of already-known sources is out of
  scope for Task 6.** Only a freshly-added source is scanned once,
  immediately, from `PadLibrarySidebar`. Rescanning existing sources (on
  launch, on a timer, or via an explicit "Rescan" affordance) is left for
  a later task — nothing in the Task 6 plan text calls for it, and adding
  it would have meant guessing at UI Task 7 is explicitly responsible for.
- **`PadLibraryView`'s content list is intentionally not the final UI.**
  It is a plain, alphabetically-unsorted filename list — no thumbnails, no
  search, no explicit sort control, no per-source scan-progress display.
  This is by design (Task 7 owns `PadLibraryGrid.swift`), not an oversight,
  but it means Task 6 alone does not yet deliver a browsable-looking
  library — only a functionally correct, testable one.
- **The two Task 5 bounded concerns the user already carried forward**:
  read-only source intent still cannot cross into `LibraryOpenAsset` (Task
  4's interface has no case for it) — unchanged, still out of scope; and
  `LibraryScanResult` having no public initializer for cross-module test
  construction — **resolved in review fix round 1** below, as a byproduct
  of that round's own new tests needing to construct a `.finished(...)`
  scan event from `EditorCoreTests`.

## Review fix round 1

Codex pre-landing review of `ca34a4b`/`c35c9fe` (range `9fd22aa..HEAD`)
returned **CHANGES REQUESTED** with one blocking finding: a source added and
scanned via `PadLibrarySidebar.addSource(at:)` indexes its photos into
SQLite, but nothing invalidated whatever query the grid already had loaded.
`.smart(.all)` (or that same source/folder) could already be showing an
empty `.loaded` page fetched before the scan wrote anything, and
`scanSource(_:)`/`handle(_:for:)` only ever updated `sourceProgress` —
never `photos`/`nextCursor`/`loadState`. The user would see "No RAW files
found in this folder" until manually changing scope, sort, or search, or
leaving and returning — contradicting Task 6's own stated goal (quoted
above) that a freshly added folder must not sit permanently empty.

### Fix

- `LibraryBrowserSession.handle(_:for:)`
  (`Sources/EditorCore/LibraryBrowserSession.swift`): once a scan's
  `.finished` event arrives, calls the new private
  `isSelectionAffected(byScanOf:)` to check whether the *currently selected*
  query draws from the scanned `libraryID` — `.smart(.all)` (any source
  affects the cross-source "All" scope), `.source(libraryID)`, or
  `.folder(libraryID: libraryID, _)`. If so, it calls the existing
  `beginNewQuery()` — the same generation-bump-and-refetch path
  `select(_:)`/`setSort(_:)` already use — so the reload participates in
  the exact same staleness guard every other query change already gets, with
  no new state introduced. `.smart(.appStorage)` and `.smart(.recentlyEdited)`
  are deliberately excluded: neither is populated by an external source's
  scan (only an App-copy import or an edit changes those), so a scan
  completion must never force-reload them. Incremental `.photosIndexed`
  events during the scan do **not** trigger a reload — only `.finished` does
  — so a large scan's grid doesn't visibly flicker/reset once per batch.
- This intentionally reuses `beginNewQuery()` rather than inventing a
  separate refresh path, per the review's own suggested direction: the
  reload gets `queryGeneration` bump + `pageTask` cancellation + `photos`/
  `nextCursor` reset for free, and is automatically superseded by any
  newer selection/search/sort change the same way an ordinary `select(_:)`
  call already would be.
- `PhotoLibraryCore.LibraryScanResult` (`Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`)
  gained an explicit `public init(...)` — its previous auto-generated
  memberwise initializer was `internal`, so `EditorCoreTests` (a different
  module) could not construct a `.finished(LibraryScanResult(...))` scan
  event to exercise this fix at all. This also resolves the pre-existing
  "no public initializer for cross-module test construction" bounded
  concern this report already flagged above, under Task 6's original
  "Remaining concerns."
- `PadLibrarySidebar.swift`/`PadLibraryView.swift` needed no change — the
  fix lives entirely in `LibraryBrowserSession`, per the review's own
  guidance to put it there rather than as a SwiftUI-layer workaround.

### New tests (`Tests/EditorCoreTests/LibraryBrowserSessionTests.swift`)

- `testScanFinishingRefreshesTheCurrentAllQueryFromEmptyToVisible` —
  selection is `.smart(.all)`, loaded as empty; a source is scanned and its
  `.finished` event fires; asserts `photos` moves from empty to the newly
  indexed photo, `selection` is untouched by the reload, and exactly two
  `.all`-scoped fetches occurred (startup's + the one reload).
- `testScanFinishingDoesNotDisruptAnUnaffectedSelection` — selection is
  `.smart(.appStorage)`, already showing an app-copy photo; an unrelated
  external source's scan finishes; asserts `photos`/`selection` are
  untouched and no additional `.appStorage`-scoped fetch was issued.
- `testUserSwitchingSelectionDuringAScanCompletionReloadDiscardsTheStaleResult`
  — a scan's `.finished`-triggered reload of `.smart(.all)` is gated
  in-flight; the user calls `select(.source(otherSourceID))` before it
  resolves; asserts the newer selection's own result wins and the stale
  `.all` reload never overwrites it — the same generation-based guarantee
  `testSwitchingSelectionDuringAnOutstandingFetchDiscardsTheStaleResult`
  already proves for an ordinary `select(_:)` race, now proven for a
  scan-triggered one too.

### Verification (review fix round 1)

- `swift build` — succeeds.
- `swift test --filter LibraryBrowserSessionTests` — 34/34 pass (31
  pre-existing + 3 new).
- `swift test --filter PadLibraryCompositionContractTests` — 3/3 pass
  (unaffected by this fix).
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
  — succeeds, no warnings.
- `git diff --check` — clean.
- `swift test` (full suite) — 1051 tests executed (1048 + 3 new), 9
  skipped, 0 failures, 0 unexpected.
- `(cd Apps/LumaHarborPad.swiftpm && xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build)`
  — **BUILD SUCCEEDED**.

### Commit hash

`3d416e4` — fix: refresh the current library query after a source finishes
scanning

### Not push / merge / rebase / amend / Task 7 (round 1 fix)

- No `git push`, `git merge`, `git rebase`, or `git commit --amend` was run.
- No Task 7 file was touched.
- Exactly one fix commit is expected for the production + test changes
  above, separate from Task 6's original `ca34a4b`/`c35c9fe`.

## Review fix round 2

Codex re-review of round 1's fix (`3d416e4`/`68ab1c2`, range `c35c9fe..HEAD`)
returned **CHANGES REQUESTED** with one blocking finding: round 1's
`isSelectionAffected(byScanOf:)` excluded `.smart(.recentlyEdited)` from the
scan-completion reload, on the reasoning that only an App-copy import or an
edit populates that scope, never an external source's scan. That reasoning
was wrong for `.recentlyEdited` specifically (it holds for `.appStorage`,
which stayed excluded): `PhotoLibraryService`'s scan path re-reads each
photo's sidecar on every scan and rewrites `hasEdits`/`lastEditAt` on the
indexed row from it — those two SQLite columns are a rebuildable projection
of the sidecar, not the source of truth, and are exactly what
`.recentlyEdited`'s query filters and sorts on. A source with pre-existing
sidecar edits could therefore turn `.recentlyEdited` from empty to populated
purely by finishing a scan, with no new photo ever appearing — the same
stale-UI failure mode round 1 fixed for `.all`, just triggered by edit-state
rebuild instead of indexing, and left unfixed for this one scope.

### Fix

- `LibraryBrowserSession.isSelectionAffected(byScanOf:)`
  (`Sources/EditorCore/LibraryBrowserSession.swift`): `.smart(.recentlyEdited)`
  now returns `true` alongside `.smart(.all)`. `.smart(.appStorage)` remains
  the one excluded cross-source smart scope, since it's populated only by
  `refreshAppStorageProjection(from:)` projecting App-copy commits out of
  `PhotoDocumentStore` — a path an external source's scan never touches.
- Rewrote the doc comment on `isSelectionAffected(byScanOf:)` to explain
  *why* `.recentlyEdited` qualifies (the sidecar-rebuild mechanism above,
  citing `PhotoLibraryService`'s rescan path) instead of the round 1 comment
  that incorrectly asserted a scan never affects it.
- No other file changed — the fix is a one-case correction to round 1's own
  logic and comment, with no new state or control flow.

### New test (`Tests/EditorCoreTests/LibraryBrowserSessionTests.swift`)

- `testScanFinishingRefreshesTheCurrentRecentlyEditedQueryFromEmptyToVisible`
  — selection is `.smart(.recentlyEdited)`, loaded as empty; a source scan's
  `.finished` event fires after re-scripting that same query's page to
  include a `hasEdits: true`/`lastEditAt`-set photo (simulating the scan's
  sidecar-driven edit-state rebuild); asserts `photos` moves from empty to
  that photo, `selection` is untouched by the reload, and exactly two
  `.recentlyEdited`-scoped fetches occurred (the initial `select(_:)`'s plus
  the one reload) — the same shape as round 1's `.all` test, now proven for
  this scope too.
- `makePhoto(...)` in the same file gained optional `hasEdits`/`lastEditAt`
  parameters (defaulting to `false`/`nil`, so every existing call site is
  unaffected) so this test can construct an edited fixture at all.
- The existing `testScanFinishingDoesNotDisruptAnUnaffectedSelection`
  (`.appStorage`) test from round 1 is unchanged and still passes, proving
  that scope's exclusion is still correct.

### Verification (review fix round 2)

- `swift build` — succeeds.
- `swift test --filter LibraryBrowserSessionTests` — 35/35 pass (34 from
  round 1 + 1 new).
- `swift test --filter PadLibraryCompositionContractTests` — 3/3 pass
  (unaffected by this fix).
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
  — succeeds, no warnings.
- `git diff --check c35c9fe..HEAD` — clean.
- `swift test` (full suite) — 1052 tests executed (1051 + 1 new), 9
  skipped, 0 failures, 0 unexpected.
- `(cd Apps/LumaHarborPad.swiftpm && xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build)`
  — **BUILD SUCCEEDED**.

### Commit hash

`<pending — recorded in a follow-up docs commit, matching this task's own
established `ca34a4b`+`c35c9fe` / `3d416e4`+`68ab1c2` pattern>`

### Not push / merge / rebase / amend / Task 7 (round 2 fix)

- No `git push`, `git merge`, `git rebase`, or `git commit --amend` was run.
- No Task 7 file was touched.
- Exactly one fix commit is expected for the production + test changes
  above, separate from round 1's `3d416e4`/`68ab1c2`.

## Not push / merge / rebase / Task 7

- No `git push`, `git merge`, or `git rebase` was run at any point.
- No Task 7 file was created or modified: `PadLibraryGrid.swift`,
  `PadThumbnailCell.swift`, `PadLibrarySettingsView.swift` all remain
  untouched (none exist yet).
- No Task 8/9 file was touched either.
- Exactly one commit is expected from this task (production + test code +
  this report together, matching the single-commit pattern established in
  Tasks 3–5), created after this report was written.
