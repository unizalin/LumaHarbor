# iPad multi-source photo library acceptance report

Date: 2026-08-29

Updated: 2026-09-01

Branch: `codex/ipad-multi-source-library-durability`

## Summary

Tasks 1–9 of the iPad multi-source photo library plan are implemented. The latest branch HEAD is `9a798d5`; it includes the external-library edit-persistence fix, visible save-state UI, a stable Xcode project for real-device deployment, the corresponding real-device checksum evidence, and coordination/report updates.

Current status: **BLOCKED for final sign-off**, not because a known automated product test is failing, but because the remaining V2.3 and V4 gates are not complete.

- Full APFS/exFAT/RAW automated fixture acceptance is now PASS at `ffa2c19`, reconfirmed PASS at `a539f4a` after the `removeLibrary` durability fix, reconfirmed PASS at integrated HEAD `0fbca67` after the Beta Test Kit and RAW fixture baseline review were integrated, and reconfirmed PASS at current HEAD `9a798d5`.
- Startup bootstrap failure now renders a user-visible failure state instead of using `try!` at `ed7968d`.
- Real M1+ iPad manual testing now proves APFS persistence, exFAT offline/relink without duplicate sources, three-source browsing, Sony ARW non-destructive edit persistence, and exFAT remove-source destructive safety. Forced Files-provider reauthorisation remains `NOT RUN`.

The report keeps the remaining manual/review items as `NOT RUN`; earlier passing evidence is not used to infer a PASS for gates that were not actually rerun.

The exact remaining gates, commands, pass criteria and evidence format are defined in `docs/testing/2026-08-29-ipad-multi-source-library-verification-spec.md`.

## Product benchmark reference

On 2026-08-30, the user reconfirmed Awaysu's [AwayPhotoRawEditor](https://github.com/awaysu/AwayPhotoRawEditor) as the product benchmark for LumaHarbor's RAW-editing completeness. For this iPad multi-source phase, the benchmark is recorded as a behavior-level comparison target: direct RAW browsing, non-destructive editing, local/advanced adjustments, batch-oriented workflows, presets, export, and visible loading/progress states.

This does not authorize copying or porting AwayPhotoRawEditor source code, UI, icons, artwork, or LibRaw/WinForms implementation details. LumaHarbor remains an independent Swift implementation; benchmark-specific design notes live in `docs/reference/awayphotoraweditor-design-notes.md` and next-phase scope notes live in `docs/reference/next-phase-scope-notes.md`.

## Automated runner

Created:

- `Scripts/run-ipad-library-acceptance.zsh`
- `Scripts/run-ipad-vertical-slice-acceptance.zsh`

The runner writes evidence under `.build/ipad-library/<timestamp-pid-random>/summary.md` and uses `.build/ipad-library-selftest/` for isolated self-test artifacts. Self-test summaries start with `Run mode: SELFTEST`; production summaries start with `Run mode: PRODUCTION`.

Production step order:

1. `swift build -Xswiftc -strict-concurrency=complete`
2. `swift test`
3. iPad Simulator build with `xcodebuild`
4. `swift test --filter MultiSourceBoundedScanTests`
5. `Scripts/run-mvp-acceptance.zsh --preflight-only`
6. `Scripts/run-mvp-acceptance.zsh`
7. `Scripts/run-ipad-vertical-slice-acceptance.zsh`

The runner parses XCTest summaries and only treats a test step as PASS when the summary is present, executed count is non-zero, skipped count is zero and failure count is zero.

## Runner self-test evidence

Commands:

```bash
zsh -n Scripts/run-ipad-library-acceptance.zsh
Scripts/run-ipad-library-acceptance.zsh __selftest
for i in {1..10}; do Scripts/run-ipad-library-acceptance.zsh __selftest || exit $?; done
pgrep -fl 'run-ipad-library-acceptance|xcodebuild|swift-frontend|xctest'
```

Result:

- Syntax check: PASS
- Single `__selftest`: PASS
- Ten consecutive `__selftest` runs: PASS
- Residual process check: PASS after rerunning `pgrep` outside the sandbox; sandboxed `pgrep` could not access the process list.

Self-test coverage includes:

- successful simulated run;
- failing simulated command;
- fail-closed privacy grep semantics, including grep exit 2;
- private path redaction, including Unicode/space-bearing log names;
- permanent summary publish `mv` failure;
- concurrent simulated runs;
- isolated SELFTEST run tree.

`Scripts/run-ipad-vertical-slice-acceptance.zsh` was integrated from the previously reviewed vertical-slice acceptance worktree (`1f3283c`, plus a local `BG_NICE` self-test-noise guard). Syntax checking passed. A full `Scripts/run-ipad-vertical-slice-acceptance.zsh __selftest` run with process-list access completed successfully: parser, redaction, signal, timeout, publish-loop, correction-marker, concurrent-run, isolation, fingerprint and nested parallel full-selftest coverage all passed. No residual runner, fake helper, `xcodebuild`, `swift-frontend`, `xctest` or long-sleep helper processes remained after completion.

## Production runner evidence from 2026-08-29

Command:

```bash
LUMAHARBOR_RAW_FIXTURE_DIR=<RAW_FIXTURE_DIR> \
LUMAHARBOR_APFS_TEST_DIR=<APFS_TEST_DIR> \
Scripts/run-ipad-library-acceptance.zsh
```

Result summary:

```text
Run mode: PRODUCTION
Overall result: FAIL
Exit code: 1
Privacy scan: PASS

- strict-concurrency build: PASS
- swift test: PASS
  XCTest: 1090 executed, 0 skipped, 0 failures
- iPad Simulator build: PASS
- MultiSourceBoundedScanTests: PASS
  XCTest: 6 executed, 0 skipped, 0 failures
- MVP preflight: NOT RUN (fixture directories unavailable)
- MVP acceptance: SKIPPED (MVP preflight not run because fixture directories are unavailable)
- iPad vertical-slice acceptance: SKIPPED (MVP preflight not run because fixture directories are unavailable)
```

The failure is expected for this environment: the exFAT fixture directory was unavailable, so the runner stopped before the MVP and vertical-slice gates rather than fabricating success.

## Production runner evidence from 2026-08-30

Gate V0 was rerun after the external test device was connected:

- Branch: `codex/ipad-multi-source-library-durability`
- Commit: `ffa2c191e7ef215189fcf3940fe6b9b2133a8755`
- Worktree: clean
- Architecture: `arm64`
- Xcode: 26.6 (`17F113`)
- Xcode developer directory: full Xcode.app toolchain
- RAW fixture: Sony `_DSC1896.ARW`, SHA-256 `50e2afadcfc2598342576ac716a37113397d40c824729d6d43376705a83d8487`
- External fixture volume: USB ExFAT, safe label `EXFAT_FIXTURE`
- Privacy rule: no private fixture or mount paths were written to this report or to the production summary.

Two acceptance-infrastructure defects were found before the final V1 PASS and fixed in separate commits:

- `8910f57` (`test: bound pending lease subprocess waits`): `PendingLeaseSubprocessTests` could hang forever after a SIGKILL scenario because the test used unbounded `Process.waitUntilExit()`. The test now uses a `TrackedProcess` termination semaphore with bounded waits, so a helper termination problem becomes an explicit test failure instead of a silent suite hang. Focused verification: `swift test --filter PendingLeaseSubprocessTests` PASS, 4 executed, 0 failures.
- `ffa2c19` (`test: update raw fixture acceptance count`): `Scripts/run-mvp-acceptance.zsh` still expected exactly 8 `RawFixtureTests`, but the suite now contains 9 passing tests. The runner now uses `RAWFIXTURE_EXPECTED_TEST_COUNT=9`. Focused verification: `swift test --filter RawFixtureTests` PASS, 9 executed, 0 failures.

Final V1 command:

```bash
LUMAHARBOR_RAW_FIXTURE_DIR=<RAW_FIXTURE_DIR> \
LUMAHARBOR_APFS_TEST_DIR=<APFS_TEST_DIR> \
LUMAHARBOR_EXFAT_TEST_DIR=<EXFAT_FIXTURE_DIR> \
Scripts/run-ipad-library-acceptance.zsh
```

Result summary:

```text
Run mode: PRODUCTION
Overall result: PASS
Exit code: 0
Commit: ffa2c19
Architecture: arm64
Privacy scan: PASS

- strict-concurrency build: PASS
- swift test: PASS
  XCTest: 1090 executed, 0 skipped, 0 failures
- iPad Simulator build: PASS
- MultiSourceBoundedScanTests: PASS
  XCTest: 6 executed, 0 skipped, 0 failures
- MVP preflight: PASS
- MVP acceptance: PASS
- iPad vertical-slice acceptance: PASS
```

Post-run checks:

- No residual `run-ipad-library-acceptance`, `run-ipad-vertical-slice-acceptance`, `run-mvp-acceptance`, `xcodebuild`, `swift-frontend` or `xctest` process remained.
- `git status --short --branch` showed a clean worktree.
- The production summary contained no `/Users/`, `/Volumes/`, `/private/var/` or `/private/tmp/` path.

## Production runner evidence from 2026-08-31

Gate V0 was rerun at the current durability-branch HEAD after the `remove library` durability fix, using the same three fixture directories as the 2026-08-30 run (RAW/APFS fixtures on the local APFS volume, exFAT fixture on an external drive).

- Branch: `codex/ipad-multi-source-library-durability`
- Commit: `a539f4a` (`fix: keep remove library state durable on failures`)
- Worktree: clean except the local, non-product `Apps/LumaHarborPad.swiftpm/Package.swift` Xcode signing/formatting noise (not committed)
- Architecture: `arm64`
- Privacy rule: no private fixture or mount paths were written to this report or to the production summary.

Command:

```bash
LUMAHARBOR_RAW_FIXTURE_DIR=<RAW_FIXTURE_DIR> \
LUMAHARBOR_APFS_TEST_DIR=<APFS_TEST_DIR> \
LUMAHARBOR_EXFAT_TEST_DIR=<EXFAT_FIXTURE_DIR> \
Scripts/run-ipad-library-acceptance.zsh
```

Result summary:

```text
Run mode: PRODUCTION
Overall result: PASS
Exit code: 0
Commit: a539f4a
Architecture: arm64
Privacy scan: PASS

- strict-concurrency build: PASS
- swift test: PASS
  XCTest: 1111 executed, 0 skipped, 0 failures
- iPad Simulator build: PASS
- MultiSourceBoundedScanTests: PASS
  XCTest: 6 executed, 0 skipped, 0 failures
- MVP preflight: PASS
- MVP acceptance: PASS
- iPad vertical-slice acceptance: PASS
```

Test count rose from 1090 (2026-08-30 run) to 1111 executed, 0 skipped — consistent with the additional coverage landed since then (case-varied overlap tests, `removeLibrary` durability tests, startup bootstrap failure rendering tests, and the iPad UI/UX state-contract overlay-copy test), not a regression in fixture availability.

Post-run checks:

- Summary explicitly recorded `Privacy scan: PASS` and a repo-worktree fingerprint; no `/Users/`, `/Volumes/`, `/private/var/` or `/private/tmp/` path appeared in the production summary.
- Real-device checklist section of the summary correctly reported all five items as `NOT RUN` — no real M1+ iPad was available for this run.

## Integrated production runner evidence from 2026-08-31

Gate V0 was rerun at integrated HEAD after the Beta Test Kit, RAW fixture baseline correction, Claude review report, and coordination-state update had all been integrated.

- Branch: `codex/ipad-multi-source-library-durability`
- Commit: `0fbca67` (`docs: update integrated beta validation state`)
- Worktree: clean except the local, non-product `Apps/LumaHarborPad.swiftpm/Package.swift` Xcode signing/formatting noise (not committed)
- Architecture: `arm64`
- Privacy rule: no private fixture or mount paths were written to this report or to the production summary.

Command:

```bash
LUMAHARBOR_RAW_FIXTURE_DIR=<RAW_FIXTURE_DIR> \
LUMAHARBOR_APFS_TEST_DIR=<APFS_TEST_DIR> \
LUMAHARBOR_EXFAT_TEST_DIR=<EXFAT_FIXTURE_DIR> \
Scripts/run-ipad-library-acceptance.zsh
```

Result summary:

```text
Run mode: PRODUCTION
Overall result: PASS
Exit code: 0
Commit: 0fbca67
Architecture: arm64
Privacy scan: PASS

- strict-concurrency build: PASS
- swift test: PASS
  XCTest: 1111 executed, 0 skipped, 0 failures
- iPad Simulator build: PASS
- MultiSourceBoundedScanTests: PASS
  XCTest: 6 executed, 0 skipped, 0 failures
- MVP preflight: PASS
- MVP acceptance: PASS
- iPad vertical-slice acceptance: PASS
```

Post-run checks:

- No residual `run-ipad-library-acceptance`, `run-ipad-vertical-slice-acceptance`, `run-mvp-acceptance`, `xcodebuild`, `swift-frontend` or `xctest` process remained.
- Summary explicitly recorded `Privacy scan: PASS`; no private user, mount, or temporary path appeared in the production summary.
- Real-device checklist section of the summary correctly reported all five items as `NOT RUN`; these remain required before final sign-off.

## Real-device checklist

Manual beta evidence collected on a real iPad on 2026-08-31:

- M1+ iPad APFS add/scan/relaunch: PASS. The tester reported that photos/thumbnails appeared and the source remained after relaunch.
- exFAT add/unplug/offline/relink: PASS. The tester reported that the source could be added, thumbnails appeared, unplugging showed an offline state, reconnect/relink worked, and no duplicate source was created.
- Files provider reauthorisation: PARTIAL PASS. The tester reported normal provider-source behavior as expected. Forced reauthorisation still needs an explicit repeat if final sign-off requires that narrower recovery path.
- Three-source aggregate search/sort/restoration: PASS by tester report.
- Sony ARW edit/autosave/reopen/checksum: FAIL before the local correction. The tester reported that adjusted slider values did not persist after reopening and that the editor showed no save-state prompt.

Follow-up correction, not yet committed at the time of this note:

- Added a regression test proving that reopening the same external-library RAW must restore saved adjustments from the existing in-place document rather than minting a new neutral document.
- Added `PhotoDocumentStore.committedInPlaceDocument(matching:)`, which reuses a committed in-place document only when the current file URL, sampled fingerprint, and full-content digest still match. If multiple matching documents already exist from prior buggy runs, the picker prefers a document with saved non-neutral adjustments and then the newest sidecar.
- Updated `PhotoDocumentEditor.openLibraryAsset(.external)` to use that existing document path before creating a new in-place document.
- Added visible save-state UI to the iPad editor panels: Saved, Unsaved, Saving…, and Not saved.

Post-correction automated evidence:

- `swift test --filter PhotoDocumentEditorLibraryOpenTests/testReopeningTheSameExternalLibraryAssetRestoresSavedAdjustments`: PASS.
- `swift test --filter PhotoDocumentEditorLibraryOpenTests`: PASS, 11 tests / 0 failures.
- `swift test --filter EditorCoreTests`: PASS, 115 tests / 0 failures.
- `swift test`: PASS, 1112 tests / 9 skipped / 0 failures.
- `xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`: PASS.
- `git diff --check`: PASS.

Stable iPad Xcode project follow-up:

- The nested `Apps/LumaHarborPad.swiftpm/Package.swift` App Playground manifest was found to be an unstable real-device entry point because Xcode rewrote it and removed package-product dependencies.
- `e876b45` added `Apps/LumaHarborPad.xcodeproj` as the stable iPad build/run entry point and documented the workflow in `docs/development/ipad-xcode-runbook.md`.
- `xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`: PASS.

Post-correction real-device evidence from 2026-09-01:

- The corrected app was installed to the iPad from `Apps/LumaHarborPad.xcodeproj`.
- Opening the test Sony `.ARW` displayed `Saved`.
- Changing Exposure displayed `Unsaved` or `Saving…`, then returned to `Saved`.
- Closing and reopening the same `.ARW` preserved the adjusted Exposure value.
- Quitting and reopening the app still preserved the adjusted Exposure value.
- Checksum testing found that the original `.ARW` content was not modified.

The mandatory Sony ARW edit/autosave/reopen/checksum gate is now PASS by manual real-device evidence. The remaining real-device requirement is the forced Files-provider authorisation-loss/recovery path, which remains `NOT RUN`.

V3 remove-source destructive-safety evidence from 2026-09-01:

- The tester removed the exFAT source from the iPad app.
- Before removal, Mac-side fingerprinting recorded relative-path SHA-256 values for all non-resource-fork fixture files in the exFAT test source, including 12 Sony `.ARW` files, `.lumaharbor/library.json`, and 5 edit sidecars.
- After removal, the same relative-path SHA-256 list was regenerated.
- Result: PASS. The RAW files, library manifest, and edit sidecars were still present and every checked SHA-256 value matched the before-removal fingerprint exactly.

## Current-HEAD verification snapshot from 2026-09-01

Validated commit: `17ddba26f5934d27a05d3e8eccb962ae6b96b1d1`.

- `swift test`: PASS, 1112 tests reported, 9 fixture-dependent skips, 0 failures.
- `swift build -Xswiftc -strict-concurrency=complete`: PASS.
- `xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`: PASS.
- `git diff --check`: PASS.
- V4.2 changed-production-file scan over 34 Swift files in `150bc7d..17ddba2`: PASS; no `TBD`, `TODO`, `FIXME`, `fatalError`, `try!`, or `force unwrap` hit, and range `git diff --check` passed.
- Worktree state after removing local Xcode signing and generated-manifest noise: clean.
- Full `Scripts/run-ipad-library-acceptance.zsh` with RAW, APFS, and exFAT fixtures at this commit: superseded by the current-HEAD production runner PASS below.

## Current-HEAD production runner evidence from 2026-09-01

Gate V1 was rerun after the exFAT fixture volume and iPad were connected for continued validation.

- Branch: `codex/ipad-multi-source-library-durability`
- Commit: `9a798d5` (`docs: organize iPad final sign-off state`)
- Worktree: clean before and after the run
- Architecture: `arm64`
- Privacy rule: no private fixture or mount paths were written to this report or to the production summary.

Command:

```bash
LUMAHARBOR_RAW_FIXTURE_DIR=<RAW_FIXTURE_DIR> \
LUMAHARBOR_APFS_TEST_DIR=<APFS_TEST_DIR> \
LUMAHARBOR_EXFAT_TEST_DIR=<EXFAT_FIXTURE_DIR> \
Scripts/run-ipad-library-acceptance.zsh
```

Result summary:

```text
Run mode: PRODUCTION
Overall result: PASS
Exit code: 0
Commit: 9a798d5
Architecture: arm64
Privacy scan: PASS

- strict-concurrency build: PASS
- swift test: PASS
  XCTest: 1112 executed, 0 skipped, 0 failures
- iPad Simulator build: PASS
- MultiSourceBoundedScanTests: PASS
  XCTest: 6 executed, 0 skipped, 0 failures
- MVP preflight: PASS
- MVP acceptance: PASS
- iPad vertical-slice acceptance: PASS
```

Post-run checks:

- No residual `run-ipad-library-acceptance`, `run-ipad-vertical-slice-acceptance`, `run-mvp-acceptance`, `xcodebuild`, `swift-frontend` or `xctest` process remained.
- Summary explicitly recorded `Privacy scan: PASS`; no private user, mount, or temporary path appeared in the production summary.
- The runner's built-in real-device checklist remains informational and `NOT RUN`; current manual real-device evidence is tracked separately above.

## Final sign-off requirements still open

Before claiming the full iPad multi-source library complete:

1. Force Files-provider authorisation loss, complete reauthorisation, and record the identity-preserving recovery result.
2. Complete V4.1 spec coverage and an independent V4.3 pre-landing review over `150bc7d..HEAD` with no unresolved P0/P1 finding. V4.2 static scan is PASS at `17ddba2` and must be rerun if later product code changes.

The earlier static-scan hit in `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/LumaHarborPadApp.swift` has been fixed at `ed7968d`: the temporary-root fallback no longer uses `try! PadAppServices(...)`. Application Support failure first attempts a fresh temporary fallback; if that also fails, `PadStartupFailureView` presents localized recovery guidance instead of force-crashing before SwiftUI renders. Gate V4 still needs to rerun the full changed-production-file scan over `150bc7d..HEAD` and document any new hits.
