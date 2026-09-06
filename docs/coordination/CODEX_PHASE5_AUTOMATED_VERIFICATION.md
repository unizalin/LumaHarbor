# Codex Phase 5 Automated Verification

**Date**: 2026-09-06

**Verifier**: Codex

**Branch**: `claude/awayphotoraweditor-parity-phase2-geometry`

**Verified HEAD**: `9ba07cf686d39b730da31facd75e8bf6bbdf5641`

**Scope**: automated verification and independent source review only. No GUI
manual QA, no physical keyboard A11 verification, no Phase 4.6 final manual
acceptance, and no iPad hands-on checklist were attempted.

## What Codex Could Verify

| Gate | Result | Evidence |
|---|---|---|
| Worktree state | PASS | `git status --short --branch` showed a clean `claude/awayphotoraweditor-parity-phase2-geometry` worktree before and after verification. |
| Mac Swift build | PASS | `swift build` completed successfully. |
| Diagnostics CLI, default environment | PASS | `swift run LumaHarborDiagnosticsCLI` exited 0 with 4 pass / 3 skipped. |
| Diagnostics CLI, JSON contract | PASS | `swift run LumaHarborDiagnosticsCLI --json` exited 0 and included `overallStatus` plus `summary`. |
| Diagnostics CLI, available fixture env | PASS/PARTIAL | With the private RAW fixture directory and APFS scratch directory configured, diagnostics reported 6 pass / 1 skipped. The remaining skipped check was exFAT, because no exFAT test directory was present. |
| iOS generic build | PASS | `xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` completed with `** BUILD SUCCEEDED **`. Only non-blocking Xcode warnings were observed. |
| Real RAW fixture tests | PASS | `swift test --filter RawFixtureTests` ran 9 real-fixture tests with 0 failures. The performance test printed cold/warm timings for human review; it deliberately has no hard threshold because hardware varies. |
| Full test suite with available RAW/APFS env | PASS | `swift test` ran 1721 tests with 0 failures. With RAW/APFS env configured, the previously skipped RAW fixture tests executed; no XCTest skips were reported in this run. |
| Diff whitespace | PASS | `git diff --check 5702c9a^..HEAD` produced no output. |
| Static risk scan | PASS | Phase 5 source/test diff scan found no product-code `fatalError`, `try!`, `TODO`, `FIXME`, `TBD`, signing identifiers, or provisioning strings. The only placeholder-token hits were the localization gate's own test constants and docs describing the scan. |
| Privacy scan | PASS | Phase 5 diff scan found only documented synthetic path strings used in privacy-regression tests and docs quoting those synthetic fixtures. No real user path, Team ID, UDID, or provisioning profile was found. |

## Real RAW Fixture Notes

The private RAW fixture directory was present and contained 81 `.ARW` files.
`RawFixtureTests` exercised real decode, preview sizing, native-resolution
decode, full-resolution export dimensions, original-file immutability, metadata,
white-balance render changes, preview scheduling, and the opt-in performance
measurement.

Observed performance output from the full run:

```text
[Gate F performance] interactive preview decode, 1600px target, spec §11 target ≤150ms:
  cold: approximately 152ms
  warm: approximately 143ms, 144ms, 143ms
```

The test source explicitly states this is not a hard pass/fail threshold; the
numbers are evidence for human review against the target.

## MVP Acceptance Preflight

`Scripts/run-mvp-acceptance.zsh --preflight-only` was run with the available
RAW/APFS fixture environment. It passed machine, Xcode, Swift, RAW fixture, and
APFS checks, then failed preflight because `LUMAHARBOR_EXFAT_TEST_DIR` was not
set. Therefore full MVP acceptance remains **NOT RUN / BLOCKED BY MISSING EXFAT
TEST DIRECTORY**, not failed product behavior.

## Independent Review Findings

Codex reviewed the Phase 5 diff range and the RC report scope. No new
code/test/documentation issue was found that met the threshold for a corrective
patch in this verification round.

The prior known limitations remain accurate:

- A11 physical-keyboard verification is still `NOT RUN`.
- Phase 4.6 final manual acceptance is still `NOT RUN`.
- Manual Mac visual QA is still `NOT RUN`.
- Six machine-assisted languages still need native-speaker review and visual
  truncation checks.
- The naming template's preset-name option still falls back because the app does
  not track the last-applied preset per photo.
- The diagnostics CLI is still a health/capability check, not a full real RAW
  `exporttest` replacement.
- `shot`/`gallery` and iPad subset checklist remain unrun.

## What This Changes

This closes three items that Claude's RC report had left for another verifier:

- iOS generic build is now verified as PASS for this branch/HEAD.
- Independent Codex automated/source review is now complete with no new findings.
- Real RAW fixture tests are now verified as PASS in this environment.

It does **not** close the exFAT-dependent MVP acceptance gate, A11, Phase 4.6,
manual visual QA, language review, or iPad hands-on checklist.
