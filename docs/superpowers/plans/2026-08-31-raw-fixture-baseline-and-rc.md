# RAW Fixture Baseline and RC Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reconcile the MVP runner and acceptance template to the approved nine-test RAW fixture baseline, preserve the 2026-08-31 production evidence in its own commit, and produce an exact commit for independent review before RC preparation.

**Architecture:** One shared `RAWFIXTURE_EXPECTED_TEST_COUNT` constant is defined before `run_selftest()` and consumed by both the synthetic self-test and the production gate. The existing acceptance report remains historical evidence and is committed separately from runner behavior. RC preparation is a gate-only phase; it does not create a signed build until Claude review, Beta Test Kit integration, production acceptance, and user-controlled signing are available.

**Tech Stack:** zsh, SwiftPM/XCTest, Markdown, Git.

## Global Constraints

- Work only on `codex/ipad-multi-source-library-durability`.
- Preserve the existing local modification in `Apps/LumaHarborPad.swiftpm/Package.swift`; never stage or commit it.
- Preserve and commit `docs/testing/reports/2026-08-26-ipad-multi-source-library.md` separately from runner behavior.
- Do not modify product Swift source.
- Do not push, merge, rebase, delete branches, or remove worktrees without explicit user authorization.
- Keep `PASS`, `FAIL`, `SKIPPED`, and `NOT RUN` distinct.
- Do not write private user, mount, fixture, provider, or temporary paths into tracked files.
- The approved `RawFixtureTests` baseline is exactly 9 with 0 skipped and 0 failures.

---

## File Structure

- Modify `Scripts/run-mvp-acceptance.zsh`: define one RAW fixture baseline before self-test dispatch and derive under/exact/over cases from it.
- Modify `docs/testing/mvp-acceptance-report-template.md`: list all nine real RAW fixture tests.
- Modify `docs/testing/reports/2026-08-26-ipad-multi-source-library.md`: commit already-collected 2026-08-31 production evidence in a documentation-only commit.
- Read `Tests/LumaHarborIntegrationTests/RawFixtureTests.swift`: authoritative names for the nine tests.
- Read `docs/testing/beta/`: Claude-owned; Codex must not create or modify these files during the parallel phase.

### Task 1: Make self-test and production use the same nine-test baseline

**Files:**
- Modify: `Scripts/run-mvp-acceptance.zsh`
- Modify: `docs/testing/mvp-acceptance-report-template.md`
- Read: `Tests/LumaHarborIntegrationTests/RawFixtureTests.swift`

**Interfaces:**
- Consumes: `evaluate_xctest_log "$logfile" "$required_executed_count"`.
- Produces: top-level integer `RAWFIXTURE_EXPECTED_TEST_COUNT=9`, used by both `run_selftest()` and the production RawFixtureTests gate.

- [ ] **Step 1: Confirm the assigned files and preserved dirty files**

Run:

```bash
git status --short --branch
git diff -- Apps/LumaHarborPad.swiftpm/Package.swift
git diff -- docs/testing/reports/2026-08-26-ipad-multi-source-library.md
```

Expected:

- Branch is `codex/ipad-multi-source-library-durability`.
- `Package.swift` and the multi-source report are modified but unstaged.
- `Scripts/run-mvp-acceptance.zsh` and `docs/testing/mvp-acceptance-report-template.md` are initially clean.

- [ ] **Step 2: Run the regression assertion and confirm RED**

Run:

```bash
set -o pipefail
LUMAHARBOR_RUNNER_SELFTEST=1 Scripts/run-mvp-acceptance.zsh |
  rg -F 'selftest: executed=9, required=9 -> PASS (expected PASS): ok'
```

Expected: non-zero exit because the current self-test reports 8 as the exact required count.

- [ ] **Step 3: Move the approved constant before `run_selftest()`**

Immediately after `ROOT_DIR="${SCRIPT_DIR:h}"`, add:

```zsh
# Approved RawFixtureTests baseline. This is a fixed, human-approved count,
# deliberately separate from `swift test`'s live discovery so adding or
# removing a fixture case cannot silently weaken this gate. Whoever changes
# Tests/LumaHarborIntegrationTests/RawFixtureTests.swift must update this
# constant and docs/testing/mvp-acceptance-report-template.md together.
RAWFIXTURE_EXPECTED_TEST_COUNT=9
```

Delete the later duplicate assignment currently placed after:

```zsh
SUMMARY_FILE="${RUN_DIR}/summary.md"
```

The production call must remain:

```zsh
evaluate_xctest_log "$RAWFIXTURE_LOG" "$RAWFIXTURE_EXPECTED_TEST_COUNT"
```

- [ ] **Step 4: Replace the hard-coded 7/8/9 self-test block**

Replace the current `executed-7.log`, `executed-8.log`, and `executed-9.log` block with:

```zsh
    local rawfixture_under=$((RAWFIXTURE_EXPECTED_TEST_COUNT - 1))
    local rawfixture_over=$((RAWFIXTURE_EXPECTED_TEST_COUNT + 1))

    write_selftest_case "${tmp}/executed-under.log" \
        "Executed ${rawfixture_under} tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds"
    if evaluate_xctest_log "${tmp}/executed-under.log" "$RAWFIXTURE_EXPECTED_TEST_COUNT" >/dev/null; then
        print -r -- "selftest: executed=${rawfixture_under}, required=${RAWFIXTURE_EXPECTED_TEST_COUNT} -> unexpectedly PASSED"
        failures=$((failures + 1))
    else
        print -r -- "selftest: executed=${rawfixture_under}, required=${RAWFIXTURE_EXPECTED_TEST_COUNT} -> FAIL (expected FAIL): ok"
    fi

    write_selftest_case "${tmp}/executed-exact.log" \
        "Executed ${RAWFIXTURE_EXPECTED_TEST_COUNT} tests, with 0 tests skipped, 0 failures (0 unexpected) in 0.001 (0.001) seconds"
    if evaluate_xctest_log "${tmp}/executed-exact.log" "$RAWFIXTURE_EXPECTED_TEST_COUNT" >/dev/null; then
        print -r -- "selftest: executed=${RAWFIXTURE_EXPECTED_TEST_COUNT}, required=${RAWFIXTURE_EXPECTED_TEST_COUNT} -> PASS (expected PASS): ok"
    else
        print -r -- "selftest: executed=${RAWFIXTURE_EXPECTED_TEST_COUNT}, required=${RAWFIXTURE_EXPECTED_TEST_COUNT} -> unexpectedly FAILED"
        failures=$((failures + 1))
    fi

    write_selftest_case "${tmp}/executed-over.log" \
        "Executed ${rawfixture_over} tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds"
    if evaluate_xctest_log "${tmp}/executed-over.log" "$RAWFIXTURE_EXPECTED_TEST_COUNT" >/dev/null; then
        print -r -- "selftest: executed=${rawfixture_over}, required=${RAWFIXTURE_EXPECTED_TEST_COUNT} -> unexpectedly PASSED"
        failures=$((failures + 1))
    else
        print -r -- "selftest: executed=${rawfixture_over}, required=${RAWFIXTURE_EXPECTED_TEST_COUNT} -> FAIL (expected FAIL): ok"
    fi
```

- [ ] **Step 5: Update the RAW fixture report template**

Change:

```markdown
`RawFixtureTests` 8 個既有案例逐一記錄（不得 skip）：
```

to:

```markdown
`RawFixtureTests` 9 個核准案例逐一記錄（不得 skip）：
```

Append this ninth row after the existing preview-scheduler row:

```markdown
| 9 | `testInteractivePreviewLatencyForARealPhoto` | ☐ Pass ☐ Fail | |
```

- [ ] **Step 6: Verify GREEN with the exact baseline output**

Run:

```bash
zsh -n Scripts/run-mvp-acceptance.zsh
LUMAHARBOR_RUNNER_SELFTEST=1 Scripts/run-mvp-acceptance.zsh
```

Expected:

- Syntax command exits 0.
- Self-test exits 0.
- Output contains all three lines:
  - `executed=8, required=9 -> FAIL (expected FAIL): ok`
  - `executed=9, required=9 -> PASS (expected PASS): ok`
  - `executed=10, required=9 -> FAIL (expected FAIL): ok`

- [ ] **Step 7: Confirm names and counts match the authoritative Swift test file**

Run:

```bash
test "$(rg -c '^    func test' Tests/LumaHarborIntegrationTests/RawFixtureTests.swift)" = "9"
rg -n '^    func test' Tests/LumaHarborIntegrationTests/RawFixtureTests.swift
rg -n 'test[A-Za-z0-9]+' docs/testing/mvp-acceptance-report-template.md
```

Expected:

- Swift test count is exactly 9.
- All nine names appear in the template exactly once.
- `testInteractivePreviewLatencyForARealPhoto` is present.

- [ ] **Step 8: Run full verification**

Run:

```bash
swift test
git diff --check -- Scripts/run-mvp-acceptance.zsh docs/testing/mvp-acceptance-report-template.md
```

Expected:

- `swift test`: 1111 executed, 9 fixture-dependent tests skipped, 0 failures when private fixtures are not exported.
- `git diff --check`: exit 0 with no output.

- [ ] **Step 9: Stage only the runner and template**

Run:

```bash
git add Scripts/run-mvp-acceptance.zsh docs/testing/mvp-acceptance-report-template.md
git diff --cached --name-only
git diff --cached --check
```

Expected staged names:

```text
Scripts/run-mvp-acceptance.zsh
docs/testing/mvp-acceptance-report-template.md
```

Neither `Apps/LumaHarborPad.swiftpm/Package.swift` nor the existing multi-source report may appear.

- [ ] **Step 10: Commit the baseline correction**

Run:

```bash
git commit -m "test: align RAW fixture acceptance baseline"
git rev-parse HEAD
```

Expected: a commit containing exactly the runner and report template. Save the full SHA for Claude's independent review handoff.

### Task 2: Preserve the 2026-08-31 production evidence separately

**Files:**
- Modify: `docs/testing/reports/2026-08-26-ipad-multi-source-library.md`

**Interfaces:**
- Consumes: existing uncommitted report diff and ignored summary `.build/ipad-library/20260831T064719Z-26714-2183/summary.md`.
- Produces: documentation-only evidence commit that does not change runner behavior.

- [ ] **Step 1: Verify the ignored source summary**

Run:

```bash
sed -n '1,180p' .build/ipad-library/20260831T064719Z-26714-2183/summary.md
```

Expected key lines:

```text
Run mode: PRODUCTION
Overall result: PASS
Exit code: 0
Commit: a539f4a
Privacy scan: PASS
```

Expected step evidence includes 1111 executed, 0 skipped, 0 failures and all five real-device items as `NOT RUN`.

- [ ] **Step 2: Compare the report text with the source summary**

Run:

```bash
git diff -- docs/testing/reports/2026-08-26-ipad-multi-source-library.md
```

Expected:

- The report identifies `a539f4a` as the production evidence commit.
- It records 1111 executed, 0 skipped, 0 failures.
- It keeps all five real-device gates as `NOT RUN`.
- It does not claim overall feature approval.

- [ ] **Step 3: Run privacy and whitespace checks**

Run:

```bash
rg -n '/Users/[^<[:space:]`"]+|/Volumes/[^<[:space:]`"]+|/private/var/folders/|/private/tmp/[^<[:space:]`"]+' \
  docs/testing/reports/2026-08-26-ipad-multi-source-library.md
git diff --check -- docs/testing/reports/2026-08-26-ipad-multi-source-library.md
```

Expected:

- Privacy scan exits 1 with no private concrete path.
- Whitespace check exits 0 with no output.
- Generic redaction rules such as `/Users/` or `/private/tmp/` may remain when they do not include concrete private components.

- [ ] **Step 4: Stage only the report**

Run:

```bash
git add docs/testing/reports/2026-08-26-ipad-multi-source-library.md
git diff --cached --name-only
```

Expected staged name:

```text
docs/testing/reports/2026-08-26-ipad-multi-source-library.md
```

- [ ] **Step 5: Commit the evidence**

Run:

```bash
git commit -m "docs: record current iPad library acceptance evidence"
```

Expected: one documentation-only commit. `Package.swift` remains modified and unstaged.

### Task 3: Prepare the exact review handoff and hold the RC gate

**Files:**
- Read: `docs/testing/beta/` after Claude completes the Beta Test Kit.
- Read: `docs/testing/reports/2026-08-31-raw-fixture-baseline-review.md` after Claude's review.
- Modify later: `docs/coordination/CURRENT.md` in a coordination-only commit.

**Interfaces:**
- Consumes: Task 1 full commit SHA, Task 2 evidence commit, Claude Beta Test Kit commit.
- Produces: bounded Claude review request and an RC eligibility decision; it does not create a signed archive by itself.

- [ ] **Step 1: Produce the Claude review request from the exact Task 1 SHA**

The handoff must state:

```text
Review only the exact Codex baseline-fix commit supplied in this handoff.
Verify that self-test and production share RAWFIXTURE_EXPECTED_TEST_COUNT=9,
under/exact/over are 8/9/10, the report template contains all nine Swift test
names, skip/count mismatches fail closed, and no unrelated file changed.
Write only docs/testing/reports/2026-08-31-raw-fixture-baseline-review.md.
Do not modify Scripts, Sources, Tests, Apps, AGENTS.md, CLAUDE.md,
docs/coordination/CURRENT.md, or the existing multi-source report.
Do not push, merge, or rebase.
```

Generate the exact value immediately after Task 1 commits:

```bash
CODEX_BASELINE_FIX_SHA="$(git rev-parse HEAD)"
git show --stat --oneline "$CODEX_BASELINE_FIX_SHA"
git diff --name-only "${CODEX_BASELINE_FIX_SHA}^" "$CODEX_BASELINE_FIX_SHA"
```

Expected changed files are exactly:

```text
Scripts/run-mvp-acceptance.zsh
docs/testing/mvp-acceptance-report-template.md
```

Include the printed full `CODEX_BASELINE_FIX_SHA` and the diff range formed by
that SHA in the handoff. Never type or infer a different SHA manually.

- [ ] **Step 2: Hold RC until Claude and user gates are available**

Stop this plan after producing the exact review request. Do not inspect or
integrate Claude work until Claude returns real full commit SHAs. At that point,
write a short follow-up integration plan from the actual SHAs; never use a
placeholder or branch tip as evidence.

Required before RC1:

- Claude Beta Test Kit commit changes only the five files under `docs/testing/beta/`.
- Claude review report is `APPROVED`.
- Codex re-review finds no blocking discrepancy against the verification spec.
- User authorizes integration of Claude commits.
- Production acceptance passes at the integrated exact commit.
- The five real-device gates remain explicitly reported; if any are `NOT RUN`, label the build Beta/RC rather than final approval.

- [ ] **Step 3: Do not perform integration or signed distribution without authorization**

Prohibited in this task:

```text
git push
git merge
git rebase
git cherry-pick
git worktree remove
signed Archive export
Ad Hoc provisioning changes
```

These actions require a later explicit user instruction and, for signing, user-controlled Apple credentials.
