# Current Coordination State

Updated: 2026-08-31

Updated by: Codex

## Source of truth

- Active integration branch: `codex/ipad-multi-source-library-durability`
- Last fully validated product/evidence commit: `a539f4a8943342e14550e58df5bcbbd27dd78869`
- Coordination design commit: `56e92b326038136e3c6a5728b7387a6dc7589443`
- Base branch: `main`
- Base commit observed during design: `114b1f669f91968137d8519ef4b71b819f277444`
- At design approval the integration branch was 69 commits ahead of `main` and 0 commits behind.
- The integration branch has no configured upstream. Do not push it without explicit user authorization.

The commit recorded above is the latest fully validated product/evidence baseline. Coordination-only commits may appear after it. Before modifying product code, compare the working branch with this file and inspect every later commit.

## Ownership

- Codex owns implementation of the shared coordination files on the active integration branch.
- Claude is review-only for this work until a committed handoff assigns new ownership.
- Product files must never be edited concurrently from two worktrees.

## Latest verified evidence

- Production acceptance runner at `a539f4a8943342e14550e58df5bcbbd27dd78869`: `PASS`.
- Full Swift suite: 1111 executed, 0 skipped, 0 failures.
- MultiSourceBoundedScanTests: 6 executed, 0 skipped, 0 failures.
- iPad Simulator build: `PASS`.
- MVP preflight, MVP acceptance, iPad vertical-slice acceptance, and privacy scan: `PASS`.
- Evidence source: `docs/testing/reports/2026-08-26-ipad-multi-source-library.md` and the repo-ignored production summary generated on 2026-08-31.

## Required real-device gates

All five remain `NOT RUN`:

1. M1+ iPad APFS add, scan, and relaunch.
2. exFAT add, unplug, offline state, and relink.
3. Files provider reauthorisation.
4. Three-source aggregate search, sort, and restoration.
5. Sony ARW edit, autosave, reopen, and original-file checksum.

## Preserved dirty files

- `Apps/LumaHarborPad.swiftpm/Package.swift`: local Xcode-generated signing team and formatting changes. Do not commit without explicit user authorization.
- `docs/testing/reports/2026-08-26-ipad-multi-source-library.md`: uncommitted 2026-08-31 acceptance evidence. Preserve and commit separately from coordination infrastructure.

## Open correction

- Formal `RawFixtureTests` acceptance baseline: 9.
- `Scripts/run-mvp-acceptance.zsh` self-test still hard-codes 8.
- `docs/testing/mvp-acceptance-report-template.md` still says 8 and omits `testInteractivePreviewLatencyForARealPhoto`.
- Reconcile the self-test and template in a separate tested commit before final landing.

## Next action

Complete this shared coordination implementation plan, verify the committed Markdown contains no sensitive paths, then hand off the resulting commit for review. Do not begin unrelated product work in the same commit.
