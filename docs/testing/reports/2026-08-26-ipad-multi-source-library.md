# iPad multi-source photo library acceptance report

Date: 2026-08-29

Updated: 2026-08-30

Branch: `codex/ipad-multi-source-library-durability`

## Summary

Tasks 1–8 of the iPad multi-source photo library plan are implemented and reviewed through `5bf9c2b` (`docs: record Task 8 APPROVED outcome in its own report`). Task 9 adds the automated acceptance runner and records the current evidence state.

Current status: **BLOCKED for final sign-off**, not because the implemented Task 1–8 feature tests are failing, but because the real-device acceptance gates have not all been run yet.

- Full APFS/exFAT/RAW automated fixture acceptance is now PASS at `ffa2c19`.
- Real M1+ iPad manual checklist is not executed.

The runner records those items as `NOT RUN` / `SKIPPED`, never PASS.

The exact remaining gates, commands, pass criteria and evidence format are defined in `docs/testing/2026-08-29-ipad-multi-source-library-verification-spec.md`.

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

## Real-device checklist

Not executed in this session:

- M1+ iPad APFS add/scan/relaunch: NOT RUN
- exFAT add/unplug/offline/relink: NOT RUN
- Files provider reauthorisation: NOT RUN
- Three-source aggregate search/sort/restoration: NOT RUN
- Sony ARW edit/autosave/reopen/checksum: NOT RUN

These remain required before final merge/sign-off.

## Final sign-off requirements still open

Before claiming the full iPad multi-source library complete:

1. Execute the real M1+ iPad checklist and update this report with concrete PASS/FAIL evidence.
2. Run the final review gate from the implementation plan.

An early static scan for that final review currently has one OPEN hit: the temporary-root fallback in `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/LumaHarborPadApp.swift` uses `try! PadAppServices(...)`. Existing composition tests do not directly exercise failure of both the primary Application Support root and the temporary fallback root. This is not yet classified as a product defect, but it must be resolved or explicitly justified during Gate V4 before approval.
