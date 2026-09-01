# Current Coordination State

Updated: 2026-09-01

Updated by: Codex

## Source of truth

- Active integration branch: `codex/ipad-multi-source-library-durability`
- Latest current-branch product/evidence commit validated by the full fixture runner: `9a798d5852d2688e2b44e87715038d7eb043a091`
- Latest production acceptance run commit: `9a798d5852d2688e2b44e87715038d7eb043a091`
- Last production fixture-validated product commit: `17ddba26f5934d27a05d3e8eccb962ae6b96b1d1`
- External-library edit persistence fix: `31e707e7773b1c7f504330702d007b87759118a9`
- Stable iPad Xcode project: `e876b4565325fc06bfb1824ff7eb391aee94345e`
- Latest real-device evidence update: `1bebd929eb9e1714564a62764ac02c0f0a2374d5`
- RAW fixture baseline correction commit: `f5dce94716d740ede6ad46c1632361ccf03efd8b`
- Integrated Beta Test Kit commit: `a853f71822fc38584e1d753e6acdd5cbefbee4cf`
- Integrated RAW baseline review report commit: `2192b4fdbe35aae2951752d4ed64686c9562cffb`
- Coordination design commit: `56e92b326038136e3c6a5728b7387a6dc7589443`
- Coordination state commit: `8e85a6adaab869982686d00fcaae62673378a52b`
- Shared agent entry-point commit: `4fe7574d354067235d872c2c3897a5f2a337c8d2`
- Base branch: `main`
- Base commit observed during design: `114b1f669f91968137d8519ef4b71b819f277444`
- After this coordination-only update, the integration branch is 88 commits ahead of `main` and 0 commits behind.
- The integration branch has no configured upstream. Do not push it without explicit user authorization.

The latest full APFS/exFAT/RAW production acceptance runner has now passed at current HEAD. Product code has not changed since `17ddba26f5934d27a05d3e8eccb962ae6b96b1d1`; later commits through `9a798d5852d2688e2b44e87715038d7eb043a091` are documentation and coordination updates.

## Ownership

- Codex owns the active integration branch.
- Claude completed the Beta Test Kit on `claude/ipad-beta-test-kit`; Codex cherry-picked the reviewed documentation commits onto this branch.
- Claude independently reviewed Codex RAW fixture baseline commit `f5dce94716d740ede6ad46c1632361ccf03efd8b` and reported `APPROVED` in `docs/testing/reports/2026-08-31-raw-fixture-baseline-review.md`.
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

## Required real-device gates

Current manual real-device evidence:

1. M1+ iPad APFS add, scan, and relaunch: `PASS` by manual tester report on 2026-08-31.
2. exFAT add, unplug, offline state, and relink: `PASS` by manual tester report on 2026-08-31; no duplicate source was created.
3. Files provider reauthorisation: normal provider-source open flow `PASS`; forced authorisation-loss and reauthorisation recovery remains `NOT RUN`.
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

Close the forced Files-provider reauthorisation gate and the independent V4 pre-landing review. Do not push, merge, rebase, remove the worktree, or commit personal signing settings without explicit user authorization.
