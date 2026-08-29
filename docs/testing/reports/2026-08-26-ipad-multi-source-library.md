# iPad multi-source photo library acceptance report

Date: 2026-08-29

Branch: `codex/ipad-multi-source-library-durability`

## Summary

Tasks 1–8 of the iPad multi-source photo library plan are implemented and reviewed through `5bf9c2b` (`docs: record Task 8 APPROVED outcome in its own report`). Task 9 adds the automated acceptance runner and records the current evidence state.

Current status: **BLOCKED for final sign-off**, not because the implemented Task 1–8 feature tests are failing, but because the full fixture/device acceptance gates are not all runnable in this session:

- exFAT fixture directory is not mounted.
- Real M1+ iPad manual checklist is not executed.

The runner records those items as `NOT RUN` / `SKIPPED`, never PASS.

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

`Scripts/run-ipad-vertical-slice-acceptance.zsh` was integrated from the previously reviewed vertical-slice acceptance worktree (`1f3283c`, plus a local `BG_NICE` self-test-noise guard). Syntax checking passed. Its full `__selftest` was started with process-list access and progressed through parser, redaction, signal, timeout, publish-loop, correction-marker, concurrent-run, isolation and fingerprint checks, but was interrupted during the final nested parallel full-selftest section after several minutes rather than being counted as PASS. No residual runner, fake helper, `xcodebuild`, `swift-frontend` or `xctest` processes remained after interruption. The library runner therefore integrates the vertical-slice gate, but this report does not claim the vertical runner's own full self-test as complete in this branch.

## Production runner evidence from this session

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

1. Mount/export the exFAT fixture directory and rerun `Scripts/run-ipad-library-acceptance.zsh`.
2. Complete a dedicated full `Scripts/run-ipad-vertical-slice-acceptance.zsh __selftest` run in this branch, or review/fix the long-running nested parallel self-test section before counting it as PASS.
3. Execute the real M1+ iPad checklist and update this report with concrete PASS/FAIL evidence.
4. Run the final review gate from the implementation plan.
