# Current Coordination State

Updated: 2026-09-02

Updated by: Codex (AwayPhotoRawEditor parity spec)

## Source of truth

- Active integration branch: `codex/ipad-ui-ux-state-feedback-polish`
- Previous integration branch landed and pushed to `main`: `f38f3ad7968b2d5faaffa96dda17f308a982846d`
- Active UI/UX polish design spec: `docs/superpowers/specs/2026-09-01-ipad-ui-ux-state-feedback-polish-design.md`
- Active UI/UX polish implementation plan: `docs/superpowers/plans/2026-09-01-ipad-ui-ux-state-feedback-polish.md`
- Next product-scope parity spec: `docs/superpowers/specs/2026-09-02-awayphotoraweditor-parity-design.md`
- Task 1 (library operation state contract) commit: `83ff071b434d430a9a8cc878d3b5b8dbde5cfc67`
- Task 2 (library UI copy and source-state rendering) commit: `bbbac5172f3989aa8b8dc395622276defc147aad`
- Latest current-branch product/evidence commit validated by the full fixture runner: `9a798d5852d2688e2b44e87715038d7eb043a091`
- Latest production acceptance run commit: `9a798d5852d2688e2b44e87715038d7eb043a091`
- Last production fixture-validated product commit: `17ddba26f5934d27a05d3e8eccb962ae6b96b1d1`
- External-library edit persistence fix: `31e707e7773b1c7f504330702d007b87759118a9`
- Stable iPad Xcode project: `e876b4565325fc06bfb1824ff7eb391aee94345e`
- Latest real-device evidence update: `8b80a06a5f3e2e41564892e67cff2710829f9a54`
- RAW fixture baseline correction commit: `f5dce94716d740ede6ad46c1632361ccf03efd8b`
- Integrated Beta Test Kit commit: `a853f71822fc38584e1d753e6acdd5cbefbee4cf`
- Integrated RAW baseline review report commit: `2192b4fdbe35aae2951752d4ed64686c9562cffb`
- Coordination design commit: `56e92b326038136e3c6a5728b7387a6dc7589443`
- Coordination state commit: `8e85a6adaab869982686d00fcaae62673378a52b`
- Shared agent entry-point commit: `4fe7574d354067235d872c2c3897a5f2a337c8d2`
- Base branch: `main`
- Base commit observed during design: `114b1f669f91968137d8519ef4b71b819f277444`
- As of the pre-parity-spec baseline on 2026-09-02, the integration branch was 5 commits ahead of `main` and 0 behind (`git rev-list --left-right --count main...HEAD` → `0	5`; the 5 commits were `7eee325`, `ec8797b`, `83ff071`, `bbbac51`, `0cca8e0`). The parity spec is a coordination/product-scope addition on top of that baseline, not a new validated product commit.
- The integration branch has no configured upstream. Do not push it without explicit user authorization.

The latest full APFS/exFAT/RAW production acceptance runner passed at `9a798d5852d2688e2b44e87715038d7eb043a091`, the commit where the previous (multi-source durability) branch landed on `main` as `f38f3ad`. The 4 commits ahead of `main` on this branch are the new UI/UX state feedback polish work (design/plan docs, then Task 1 and Task 2); they have not been re-run through that production fixture runner or on a real device yet.

## Ownership

- Codex owns the active UI/UX polish branch and authored its design spec and implementation plan (`7eee325`, `ec8797b`).
- **Deviation from the design spec's own §11 division of labor** ("Codex: spec/plan/first TDD round; Claude: independent review"): at the user's explicit, detailed instruction, Claude directly executed the implementation plan's Task 1 and Task 2 using TDD, from the shared worktree `/Users/private-builder/github/LumaHarbor` on this same branch (not a separate Claude worktree), and committed both (`83ff071`, `bbbac51`). Codex has not yet independently reviewed this Task 1/Task 2 diff — treat it as implemented-and-tested-by-Claude, not yet reviewed by a second agent.
- Claude completed the Beta Test Kit on `claude/ipad-beta-test-kit`; Codex cherry-picked the reviewed documentation commits onto this branch.
- Claude independently reviewed Codex RAW fixture baseline commit `f5dce94716d740ede6ad46c1632361ccf03efd8b` and reported `APPROVED` in `docs/testing/reports/2026-08-31-raw-fixture-baseline-review.md`.
- Claude independently performed the required V4.3 pre-landing review at HEAD `d24eaae85820d120611a6c75bdd8e6c17b907a18` on 2026-09-01 from a fresh session with no prior context, and reported `APPROVED`. See the V4.3 evidence entry below. This review predates and does not cover Task 1/Task 2.
- Product files must never be edited concurrently from two worktrees.

## Latest verified evidence

- Production acceptance runner at `9a798d5852d2688e2b44e87715038d7eb043a091`: `PASS`.
- Full Swift suite: 1112 executed, 0 skipped, 0 failures.
- MultiSourceBoundedScanTests: 6 executed, 0 skipped, 0 failures.
- iPad Simulator build: `PASS`.
- MVP preflight, MVP acceptance, iPad vertical-slice acceptance, and privacy scan: `PASS`.
- Evidence source: `docs/testing/reports/2026-08-26-ipad-multi-source-library.md` and the repo-ignored integrated production summary generated on 2026-09-01.
- Coordination implementation baseline: `swift test` executed 1111 tests, with 9 fixture-dependent tests skipped and 0 failures. This local run did not replace the production fixture evidence above.
- RAW fixture baseline correction: `Scripts/run-mvp-acceptance.zsh` and `docs/testing/mvp-acceptance-report-template.md` now use the approved 9-test baseline. Runner self-test passed with `executed=8` and `executed=10` failing, and `executed=9` passing.
- Beta Test Kit: `docs/testing/beta/` now contains tester guide, real-device checklist, bug report template, privacy rules, and RC checklist.
- Stable iPad Xcode entry point: use `Apps/LumaHarborPad.xcodeproj` for real-device build/run. Do not use `Apps/LumaHarborPad.swiftpm/Package.swift` for ongoing iPad testing because Xcode's App Playground settings can rewrite that generated manifest and remove package-product dependencies.
- Current-HEAD full production fixture acceptance at `9a798d5852d2688e2b44e87715038d7eb043a091`: `PASS`. The runner reported `Run mode: PRODUCTION`, `Overall result: PASS`, `Exit code: 0`, `Privacy scan: PASS`, 1112 XCTest cases executed with 0 skipped and 0 failures, 6 `MultiSourceBoundedScanTests` executed with 0 skipped and 0 failures, and PASS for strict-concurrency build, iPad Simulator build, MVP preflight, MVP acceptance, and iPad vertical-slice acceptance.
- V4.1 spec coverage: `PASS` by local Codex review against design spec §§1-19.
- V4.2 changed-production-file static scan: `PASS` over 34 production Swift files in `150bc7d..HEAD`; no `TBD`, `TODO`, `FIXME`, `fatalError`, `try!`, or `force unwrap` hit, and range `git diff --check` passed.
- V4.3 local pre-landing review (Codex, same session): no unresolved P0/P1 issue found.
- V4.3 independent pre-landing review (Claude, fresh session, no prior context, 2026-09-01, at HEAD `d24eaae85820d120611a6c75bdd8e6c17b907a18`): `APPROVED`, no unresolved P0/P1 finding. Review-only: no file was modified, staged, committed, pushed, merged, or rebased during the review itself. Checks performed directly against source, not only against prior reports:
  - Confirmed branch/HEAD/worktree/dirty-file state matched this file before reviewing; confirmed the four most recent doc commits (`1bebd92`, `2b342ff`, `8b80a06`, `d24eaae`) touch only `docs/coordination/CURRENT.md` and the acceptance report, no product code.
  - Read `LibrarySourceIdentity.swift` in full: manifest-ID priority, fail-closed-to-`.ambiguous` behavior, and overlap/ancestor/descendant rejection match spec §7.
  - Read `PhotoLibraryService.removeLibrary`/`relink`/`restoreLibraries`: remove-source only touches the bookmark store and index rows (no `FileSidecarRepository`, no source-file remover); relink and restore re-validate identity and roll back on failure, with no path that mints a duplicate `LibraryID`.
  - Read the scan-loop prune gate: `index.removePhotos(inLibrary:notSeenSince:)` only runs when `!cancelled`, matching spec §9's "only a fully successful scan may prune" rule.
  - Confirmed via `rg` that no product code under `Sources/`/`Apps/` writes to a photo's source URL; sidecars are read/written only under `.lumaharbor/*.json`. Read `PhotoDocumentStore.committedInPlaceDocument(matching:)` and confirmed the ARW reopen-persistence fix uses fingerprint + full-content digest before reusing a document.
  - Read `LibraryBrowserSession`'s `setSort`/`select`/`updateSearchText`: every query-shape change clears `nextCursor` and bumps `queryGeneration`, so `PhotoPageCursor`'s documented "stale cursor" edge case is not reachable through the only production caller.
  - Confirmed `Scripts/run-ipad-library-acceptance.zsh` only reports a test step `PASS` when `skipped == 0 && failures == 0 && executed != 0`; `docs/testing/beta/RC_CHECKLIST.md` is a blank template with `NOT RUN` placeholders, not a false PASS.
  - `rg` scan for `/Users/|/Volumes/|/private/|7KM4ZM25P3|teamIdentifier:` across `docs/Sources/Apps/Tests`: only synthetic test-fixture paths and pre-existing out-of-diff spec files; no real private path or signing ID introduced by this branch.
  - `git diff --check main..HEAD`: no output (PASS).
  - Ran locally (no external fixtures, no device): `swift build` PASS; `swift test` PASS, 1112 executed / 9 skipped (fixture-dependent, expected) / 0 failures, consistent with the coordination baseline above. Did not rerun strict-concurrency build, iPad Simulator build, or the full RAW/APFS/exFAT production runner — those stay `NOT RUN` by this review and are carried forward only as previously reported manual/production evidence, not re-verified here.
  - Did not re-execute the five real-device gates below; their `PASS` status is carried forward from the manual tester reports already on file, not re-confirmed by this review.
- UI/UX polish Task 1 (`83ff071b434d430a9a8cc878d3b5b8dbde5cfc67`, Claude, TDD): added `LibraryBrowserOperationState` (`.idle`/`.addingSource`/`.scanningSource(LibraryID)`/`.reconnectingSource(LibraryID)`/`.removingSource(LibraryID)`) and a published `LibraryBrowserSession.operationState`, set/reset around `addSource`/`relinkSource`/`removeSource`/`scanSource`. RED confirmed via genuine compile failures (`operationState` did not exist) before implementation. `LibraryBrowserSessionTests`: 42 executed, 0 failures (34 pre-existing + 8 new, including failure-path and `sourceProgress`-semantics-preserved cases beyond the plan's own minimum). Full `swift test`: 1119 executed, 9 skipped (fixture-dependent, unchanged baseline), 0 failures. `git diff --check`: clean. Only `Sources/EditorCore/LibraryBrowserSession.swift` and `Tests/EditorCoreTests/LibraryBrowserSessionTests.swift` changed.
- UI/UX polish Task 2 (`bbbac5172f3989aa8b8dc395622276defc147aad`, Claude, TDD): `PadLibraryView`'s global operation overlay now derives from `library.operationState` first (distinct title/message per case), falling back to `sourceProgress`-driven scan feedback only while `operationState == .idle`; removed the now-redundant `isRegisteringSource` view-local flag. `PadLibrarySidebar` source rows now distinguish a partially-failed scan (`Partial issue`, when `indexedCount > 0 || failedCount > 0`) from a fully-failed one (`Scan problem`), and the remove-source confirmation dialog now explicitly names the `.lumaharbor` manifest alongside RAW files/sidecars. `PadLibraryGrid`'s empty state now branches on the selected source's own connection state (offline / needs-authorization / no-supported-RAW), search-text-present, or no-sources-at-all — a `.smart` (aggregate) selection is never misattributed to one source's offline/needs-access state, and `.folder` scope resolves the same as `.source`. RED confirmed by stashing only the three `.swiftpm` app files (`git stash push -u -m "task2-red-check-appfiles"`, SHA `af8fd89f87d09075f2134dc7d1b983acefb1102f`) and running the new tests against the pre-Task-2 implementation before restoring via `git stash apply` (not `pop`) and dropping the entry. `PadLibraryCompositionContractTests`: 6 executed, 0 failures. `PadLibraryAccessibilityContractTests`: 29 executed, 0 failures (25 pre-existing, 4 of which were updated in place because they hard-coded implementation details Task 2 intentionally superseded — e.g. `libraryProgressTitle`/`isRegisteringSource` no longer exist, and the sidebar's `Scan problem`-only branch is now `Partial issue`/`Scan problem` — plus 1 genuinely new required test). Full `swift test`: 1122 executed, 9 skipped, 0 failures. `git diff --check`: clean. `rg` privacy scan (`/Users/|/Volumes/|/private/|7KM4ZM25P3|teamIdentifier:|DEVELOPMENT_TEAM`) over the Task 2 diff: no hits. Changed exactly the 7 files the task authorized: `PadLibraryView.swift`, `PadLibrarySidebar.swift`, `PadLibraryGrid.swift`, both `Localizable.strings` (15 new keys each, en + zh-Hant, verified equal unique-key counts), `PadLibraryCompositionContractTests.swift`, `PadLibraryAccessibilityContractTests.swift`.
- **`NOT RUN` for both Task 1 and Task 2**: `xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS' build` (the implementation plan's own Task 4 Step 2 gate). Neither Task 1 nor Task 2 touched a file `swift build`/`swift test` actually compiles from `Apps/LumaHarborPad.swiftpm` — those three views are only checked by source-parsing contract tests — so an actual Swift-compiler pass over `PadLibraryView.swift`/`PadLibrarySidebar.swift`/`PadLibraryGrid.swift` has not happened yet. Do not treat the passing contract tests as proof the app package compiles.
- **`NOT RUN`**: any real-device or Simulator check of the new Task 1/Task 2 UI copy itself (the `Adding source…`/`Scanning source…`/`Reconnecting source…`/`Removing source…` overlay, the `Partial issue`/`Scan problem` row text, the new empty-grid states). The five real-device gates below cover the underlying multi-source library feature, not this UI polish round.

## Required real-device gates

Current manual real-device evidence:

1. M1+ iPad APFS add, scan, and relaunch: `PASS` by manual tester report on 2026-08-31.
2. exFAT add, unplug, offline state, and relink: `PASS` by manual tester report on 2026-08-31; no duplicate source was created.
3. Files provider reauthorisation: `PASS` by manual tester report on 2026-09-01. Forced authorisation-loss recovery preserved the source identity, created no duplicate source, and allowed the tester to open photos after reauthorisation.
4. Three-source aggregate search, sort, and restoration: `PASS` by manual tester report on 2026-08-31.
5. Sony ARW edit, autosave, reopen, and original-file checksum: `PASS` by manual tester report on 2026-09-01 after `31e707e` and `e876b45`. The corrected app showed save-state text, preserved the adjusted exposure value after close/reopen and app relaunch, and checksum testing found that the original `.ARW` content was not modified.

Additional required manual gate:

- V3 remove-source destructive-safety check: `PASS` by manual tester report and Mac-side before/after fingerprint comparison on 2026-09-01. Removing the exFAT source from the iPad app left all checked RAW files, the library manifest, and edit sidecars present with unchanged SHA-256 values.

## Preserved dirty files

- `Apps/LumaHarborPad.xcodeproj/project.pbxproj`: local Xcode signing/project-formatting change created while running the app on the user's iPad. It contains the user's Development Team and must not be committed unless the user explicitly authorizes committing local signing settings.

## Resolved correction

- Formal `RawFixtureTests` acceptance baseline: 9.
- `Scripts/run-mvp-acceptance.zsh` self-test now derives under/exact/over cases from `RAWFIXTURE_EXPECTED_TEST_COUNT=9`.
- `docs/testing/mvp-acceptance-report-template.md` now lists all nine `RawFixtureTests`, including `testInteractivePreviewLatencyForARealPhoto`.
- Claude review result for this correction: `APPROVED`.

## Next action

Task 1 and Task 2 of `docs/superpowers/plans/2026-09-01-ipad-ui-ux-state-feedback-polish.md` are done (see the Handoff section below for full evidence). Codex's next bounded objective is Task 3 (Editor RAW open and save-state copy, in `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift` — rename `Not saved` to `Save failed`, add the RAW-safety hint), then Task 4 (final verification, the `docs/testing/reports/2026-09-01-ipad-ui-ux-state-feedback-polish.md` report, and this file). Given the Ownership-section deviation from the design spec's original division of labor, Codex should decide for itself whether to review the Task 1/Task 2 diff (`83ff071..bbbac51`) before continuing, or continue Task 3 directly and let a later review cover all three tasks together — either is acceptable; this file does not mandate one. Do not push, merge, rebase, remove the worktree, or commit personal signing settings without explicit user authorization.

The next major product direction is now documented in `docs/superpowers/specs/2026-09-02-awayphotoraweditor-parity-design.md`: LumaHarbor should target functional parity with AwayPhotoRawEditor while staying a native Swift/SwiftUI/Core Image implementation. Do not start large parity implementation work until the current UI polish branch is closed cleanly and a phase-specific implementation plan is written.

## Handoff to Codex (2026-09-02, from Claude)

Full closing report for Task 1 + Task 2, per `docs/coordination/HANDOFF_TEMPLATE.md`.

### Status

`DONE` for Task 1 and Task 2 of the implementation plan. `NOT RUN`/not started for Task 3 and Task 4.

### Git state

- Source branch: `codex/ipad-ui-ux-state-feedback-polish`.
- HEAD: `bbbac5172f3989aa8b8dc395622276defc147aad`.
- Base branch: `main`, at `f38f3ad7968b2d5faaffa96dda17f308a982846d` (the already-landed multi-source durability work).
- 4 commits ahead of `main`, 0 behind.
- No configured upstream.
- No push, merge, rebase, or cherry-pick occurred during this work.

### Changes

- `7eee325` `docs: specify iPad UI state feedback polish` and `ec8797b` `docs: plan iPad UI state feedback polish` — pre-existing, authored by Codex before this handoff.
- `83ff071` `feat: expose iPad library operation state` (Task 1, Claude): see the Task 1 evidence bullet above for the exact behavior change and files.
- `bbbac51` `feat: clarify iPad library feedback states` (Task 2, Claude): see the Task 2 evidence bullet above for the exact behavior change and files.
- No file outside the plan's Task 1/Task 2 file lists was touched.

### Verification

See the two Task 1/Task 2 bullets under "Latest verified evidence" above for exact commands, executed/skipped/failure counts, and the `NOT RUN` items (`xcodebuild` generic iOS build; real-device/Simulator check of the new UI copy). Do not upgrade either `NOT RUN` item to `PASS` without actually running it.

### Dirty files

- `Apps/LumaHarborPad.xcodeproj/project.pbxproj`: unchanged by this handoff. Still the user's local Xcode signing state (see "Preserved dirty files" below) — do not commit it.
- No other dirty file. `git status --short --branch` was clean immediately after each of the two commits above.

### Concerns and blockers

- Neither Task 1 nor Task 2 has been independently reviewed by a second agent (see the Ownership-section deviation note above). Not a blocker for continuing Task 3, but should be resolved before final sign-off.
- `xcodebuild` generic iOS build has not been run against either commit — the three modified `.swiftpm` app files are not compiled by `swift build`/`swift test` at all, only source-parsed by contract tests. A real compile error in `PadLibraryView.swift`/`PadLibrarySidebar.swift`/`PadLibraryGrid.swift` would not be caught by anything that has actually run so far.
- The new UI copy has not been exercised on a real device or Simulator. The plan's own Task 4 Step 1-2 and its manual-verification section are the gates that would catch this.
- `PadLibrarySidebar` still keeps its own local `reconnectingSourceID`/`removingSourceID` overlay (pre-existing, locked in by existing passing tests) alongside the new global `operationState`-driven overlay in `PadLibraryView`. At regular (non-compact) width, both can show near-duplicate text at once. Not fixed in Task 2 because doing so would require loosening tests outside Task 2's stated scope; flagged here for whoever picks this up next to decide whether it's worth a follow-up.
- The localization key `"Scanning this folder so photos can appear as they are indexed."` is now unreferenced by any Swift file (its only caller, `PadLibraryView`'s old `libraryProgressMessage`, was removed in Task 1/2's refactor) but was left in both `Localizable.strings` files rather than deleted, since Task 2's scope was additive strings work, not cleanup.

### Next action

Continue with Task 3 of `docs/superpowers/plans/2026-09-01-ipad-ui-ux-state-feedback-polish.md` — files in scope: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift`, both `Localizable.strings` files, `Tests/EditorCoreTests/PadLibraryCompositionContractTests.swift`, `Tests/EditorCoreTests/EditorSessionDocumentPersistenceTests.swift`. Use TDD (RED before implementation, as demonstrated for Task 1/Task 2 above). Verification gates in scope: the plan's own Task 3 Step 5 focused tests, then this file's usual `swift test` + `git diff --check`. Still prohibited without explicit user authorization: push, merge, rebase, removing the worktree, committing `Apps/LumaHarborPad.xcodeproj/project.pbxproj` or any signing setting.

### Suggested skills

- `test-driven-development` for Task 3's implementation.
- `verification-before-completion` before reporting Task 3 done.
- `handoff` again once Task 3 (or Task 3+4) ownership changes.
