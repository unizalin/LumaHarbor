# Shared Codex and Claude Coordination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Git-backed Markdown coordination layer that gives Codex and Claude the same rules, validated project state, durable decisions, and handoff format while they continue using separate branches and worktrees.

**Architecture:** Stable collaboration rules live in root `AGENTS.md`; root `CLAUDE.md` imports that file instead of duplicating it. Frequently changing state lives under `docs/coordination/`, where `CURRENT.md` points to the most recent fully validated product/evidence commit rather than its own containing commit, avoiding recursive self-reference.

**Tech Stack:** Git, Markdown, shell-based validation with `git`, `rg`, `test`, and `git diff --check`.

## Global Constraints

- All user-facing coordination text is Traditional Chinese (`zh-TW`).
- Codex and Claude use separate Git branches and worktrees whenever either one is editing.
- A shared worktree permits one writer only; the other agent is review-only.
- Do not push, merge, rebase, delete branches, or remove worktrees without explicit user authorization.
- Do not overwrite, restore, or delete user or other-agent uncommitted changes.
- Keep `PASS`, `SKIPPED`, and `NOT RUN` distinct.
- Do not store credentials, chat history, tool caches, private fixture paths, or private absolute paths in committed coordination files.
- Do not stage or commit the existing local changes in `Apps/LumaHarborPad.swiftpm/Package.swift` or `docs/testing/reports/2026-08-26-ipad-multi-source-library.md` as part of this plan.
- No product Swift source or test behavior changes are in scope.

---

## File Structure

- Create `docs/coordination/CURRENT.md`: mutable source-of-truth state, validated evidence baseline, ownership, dirty files, and next action.
- Create `docs/coordination/DECISIONS.md`: append-only cross-agent decisions.
- Create `docs/coordination/HANDOFF_TEMPLATE.md`: required handoff fields and evidence semantics.
- Create `AGENTS.md`: stable project rules and canonical artifact index consumed by both agents.
- Create `CLAUDE.md`: one-line import of `AGENTS.md`.

### Task 1: Add the coordination state, decisions, and handoff contract

**Files:**
- Create: `docs/coordination/CURRENT.md`
- Create: `docs/coordination/DECISIONS.md`
- Create: `docs/coordination/HANDOFF_TEMPLATE.md`

**Interfaces:**
- Consumes: approved design `docs/superpowers/specs/2026-08-31-shared-agent-coordination-design.md`; validated product baseline `a539f4a8943342e14550e58df5bcbbd27dd78869`; coordination design baseline `56e92b326038136e3c6a5728b7387a6dc7589443`.
- Produces: stable Markdown paths that root `AGENTS.md` will require every agent to read.

- [ ] **Step 1: Confirm the pre-existing dirty files are still preserved**

Run:

```bash
git status --short --branch
```

Expected output includes these pre-existing tracked modifications and no staged files:

```text
 M Apps/LumaHarborPad.swiftpm/Package.swift
 M docs/testing/reports/2026-08-26-ipad-multi-source-library.md
```

- [ ] **Step 2: Create `docs/coordination/CURRENT.md`**

Create the file with this complete content:

```markdown
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
```

- [ ] **Step 3: Create `docs/coordination/DECISIONS.md`**

Create the file with this complete content:

```markdown
# Cross-Agent Decisions

This file is append-only. When a decision is replaced, retain the original entry and add a link to the replacing decision.

## D-001 — Git-backed Markdown is the shared coordination source

- Date: 2026-08-31
- Decision: Project rules, current validated state, durable decisions, and handoff requirements live in committed Markdown.
- Reason: Both Codex and Claude can read the same versioned content without sharing internal tool state.
- Impact: Chat summaries and temporary files may assist a session but are not authoritative project state.

## D-002 — Agents edit through separate worktrees

- Date: 2026-08-31
- Decision: Codex and Claude use separate branches and worktrees whenever either agent edits files.
- Reason: Concurrent writes in one worktree can overwrite uncommitted user or agent changes.
- Impact: If a worktree is shared, one agent is the sole writer and the other is review-only.

## D-003 — `CURRENT.md` records the last validated baseline

- Date: 2026-08-31
- Decision: `CURRENT.md` records the full SHA of the latest fully validated product/evidence commit, not the SHA of the commit containing `CURRENT.md` itself.
- Reason: A file cannot contain its own final Git commit SHA without creating recursive self-reference.
- Impact: Coordination-only commits after the recorded baseline must be inspected before product editing begins.

## D-004 — Evidence states remain distinct

- Date: 2026-08-31
- Decision: `PASS`, `FAIL`, `SKIPPED`, and `NOT RUN` are recorded as separate states.
- Reason: Unavailable fixtures or hardware do not prove product behavior.
- Impact: Final sign-off remains blocked while any required real-device gate is `NOT RUN`.

## D-005 — Local settings and sensitive data stay outside coordination commits

- Date: 2026-08-31
- Decision: Credentials, chat state, private fixture paths, private absolute paths, tool caches, and local Xcode signing changes are not committed as shared coordination data.
- Reason: The agents need shared project facts, not shared identity or machine-private state.
- Impact: Handoffs use repository-relative paths and redact private filesystem details.
```

- [ ] **Step 4: Create `docs/coordination/HANDOFF_TEMPLATE.md`**

Create the file with this complete content:

```markdown
# Agent Handoff Template

Copy the headings below into a handoff report and replace every instruction sentence with concrete evidence. Do not omit a section; write `None` only when the section genuinely has no entries.

## Status

State exactly one of: `DONE`, `DONE_WITH_CONCERNS`, `BLOCKED`, or `IN_PROGRESS`.

## Git state

- Record the source branch.
- Record the full HEAD commit SHA.
- Record the base branch.
- Record ahead and behind counts.
- State whether the branch has an upstream.
- State explicitly whether push, merge, or rebase occurred.

## Changes

- List every commit created during the task.
- List every modified, added, moved, or deleted file.
- Explain behavior changes without copying the entire diff.

## Verification

- List each command that actually ran.
- Record exit code, executed test count, skip count, and failure count when available.
- Record unavailable tests as `SKIPPED` or `NOT RUN`; never report them as `PASS`.
- Link to committed reports or repository-relative ignored evidence paths without exposing private absolute paths.

## Dirty files

- List each remaining dirty file.
- Identify its owner or origin.
- State whether the next agent may modify it.

## Concerns and blockers

- Describe each known correctness, durability, privacy, performance, or verification concern.
- State the exact condition required to clear each blocker.

## Next action

- Give the next agent one bounded objective.
- Name the files and verification gates in scope.
- Repeat prohibited operations, including push, merge, rebase, destructive cleanup, and modification of preserved dirty files when those restrictions still apply.

## Suggested skills

- Name only the skills that directly apply to the next bounded objective.
- Use `using-git-worktrees` before isolated implementation work.
- Use `test-driven-development` for product behavior changes.
- Use `verification-before-completion` before reporting completion.
- Use `handoff` whenever ownership changes again.
```

- [ ] **Step 5: Validate the coordination documents**

Run:

```bash
test -f docs/coordination/CURRENT.md
test -f docs/coordination/DECISIONS.md
test -f docs/coordination/HANDOFF_TEMPLATE.md
rg -n 'TBD|TODO|FIXME|/Users/|/Volumes/|/private/' docs/coordination
git diff --check -- docs/coordination
```

Expected:

- All three `test` commands exit 0.
- `rg` exits 1 with no matches.
- `git diff --check` exits 0 with no output.

- [ ] **Step 6: Commit only the coordination documents**

Run:

```bash
git add docs/coordination/CURRENT.md docs/coordination/DECISIONS.md docs/coordination/HANDOFF_TEMPLATE.md
git diff --cached --name-only
git commit -m "docs: add shared agent coordination state"
```

Expected staged names before commit:

```text
docs/coordination/CURRENT.md
docs/coordination/DECISIONS.md
docs/coordination/HANDOFF_TEMPLATE.md
```

### Task 2: Add shared agent entry points and validate the complete contract

**Files:**
- Create: `AGENTS.md`
- Create: `CLAUDE.md`
- Read: `docs/coordination/CURRENT.md`
- Read: `docs/coordination/DECISIONS.md`
- Read: `docs/coordination/HANDOFF_TEMPLATE.md`

**Interfaces:**
- Consumes: the three coordination documents committed in Task 1.
- Produces: one shared root rules file consumed by Codex and a one-line Claude import that prevents rule duplication.

- [ ] **Step 1: Create root `AGENTS.md`**

Create the file with this complete content:

```markdown
# LumaHarbor Agent Rules

## Language

- All user-facing replies, progress updates, questions, and summaries use Traditional Chinese (`zh-TW`).
- Code, commands, paths, identifiers, and original error messages may remain in English with a Traditional Chinese explanation.

## Required startup reading

Before modifying this repository, every agent must read:

1. `docs/coordination/CURRENT.md`
2. `docs/coordination/DECISIONS.md`
3. The plan, spec, verification spec, and report linked under Canonical project artifacts below.

Confirm the current branch, HEAD, worktree, and dirty files against `CURRENT.md`. If they disagree, stop writing and resolve the source-of-truth mismatch first.

## Codex and Claude collaboration

- This file is the shared project-rule source for Codex and Claude.
- Claude imports this file through root `CLAUDE.md`; do not duplicate these rules there.
- When both agents edit the project, use different Git branches and worktrees.
- If a worktree is shared, only one agent may edit; the other is review-only.
- Do not overwrite, restore, or delete another agent's or the user's uncommitted changes.
- Before transferring ownership, update `docs/coordination/CURRENT.md`, use `docs/coordination/HANDOFF_TEMPLATE.md`, and commit the handoff state.

## Git and worktree safety

- Do not push, merge, rebase, delete branches, remove worktrees, or perform destructive cleanup without explicit user authorization.
- Preserve unrelated dirty files and stage files by exact path.
- Use a separate commit for coordination-only changes when they need independent review.
- Never treat a branch as integrated only because its patch has a different SHA; inspect ancestry, equivalent behavior, tests, and remaining unique changes.

## Verification evidence

- Keep `PASS`, `FAIL`, `SKIPPED`, and `NOT RUN` distinct.
- Do not claim completion while a required automated or real-device gate remains `NOT RUN`.
- Record exact commands, exit codes, executed tests, skips, failures, branch, and validated commit.
- Prefer repository-relative links to committed reports and ignored evidence artifacts.

## Privacy and local-only state

- Do not commit credentials, provisioning secrets, chat history, tool caches, internal state databases, or private fixture paths.
- Redact private user, mount, temporary, and fixture paths from reports and summaries.
- Treat Xcode-generated signing team and local package-formatting changes as local-only unless the user explicitly authorizes committing them.
- Keep Codex-specific settings in `.codex/` and Claude-specific settings in `.claude/`; never merge credentials or internal state between them.

## Canonical project artifacts

- Multi-source implementation plan: `docs/superpowers/plans/2026-08-26-ipad-multi-source-photo-library.md`
- Shared coordination design: `docs/superpowers/specs/2026-08-31-shared-agent-coordination-design.md`
- Shared coordination implementation plan: `docs/superpowers/plans/2026-08-31-shared-agent-coordination.md`
- Multi-source verification spec: `docs/testing/2026-08-29-ipad-multi-source-library-verification-spec.md`
- Multi-source acceptance report: `docs/testing/reports/2026-08-26-ipad-multi-source-library.md`
- iPad UI/UX state contract: `docs/superpowers/specs/2026-08-30-ipad-ui-ux-state-contract.md`
- Current coordination state: `docs/coordination/CURRENT.md`
- Cross-agent decisions: `docs/coordination/DECISIONS.md`
- Handoff template: `docs/coordination/HANDOFF_TEMPLATE.md`

## Completion and handoff

- Run verification proportional to the change before reporting completion.
- Update `CURRENT.md` whenever the validated product baseline, ownership, dirty files, test evidence, blockers, or next action changes.
- A handoff must identify branch, full HEAD SHA, base, commits, changed files, tests, skipped or unrun gates, dirty files, concerns, and one bounded next action.
- Handoff records supplement Git commits, plans, specs, and reports; they do not replace them.
```

- [ ] **Step 2: Create root `CLAUDE.md`**

Create the file with exactly one line and a trailing newline:

```text
@AGENTS.md
```

- [ ] **Step 3: Validate imports and every canonical path**

Run:

```bash
test "$(wc -l < CLAUDE.md | tr -d ' ')" = "1"
test "$(sed -n '1p' CLAUDE.md)" = "@AGENTS.md"
for path in \
  docs/superpowers/plans/2026-08-26-ipad-multi-source-photo-library.md \
  docs/superpowers/specs/2026-08-31-shared-agent-coordination-design.md \
  docs/superpowers/plans/2026-08-31-shared-agent-coordination.md \
  docs/testing/2026-08-29-ipad-multi-source-library-verification-spec.md \
  docs/testing/reports/2026-08-26-ipad-multi-source-library.md \
  docs/superpowers/specs/2026-08-30-ipad-ui-ux-state-contract.md \
  docs/coordination/CURRENT.md \
  docs/coordination/DECISIONS.md \
  docs/coordination/HANDOFF_TEMPLATE.md; do
  test -f "$path"
done
rg -n 'TBD|TODO|FIXME|/Users/|/Volumes/|/private/' AGENTS.md CLAUDE.md docs/coordination
git diff --check -- AGENTS.md CLAUDE.md docs/coordination
```

Expected:

- Both `CLAUDE.md` assertions exit 0.
- Every canonical path exists.
- `rg` exits 1 with no matches.
- `git diff --check` exits 0 with no output.

- [ ] **Step 4: Stage only shared entry points**

Run:

```bash
git add AGENTS.md CLAUDE.md
git diff --cached --name-only
```

Expected staged names:

```text
AGENTS.md
CLAUDE.md
```

Confirm neither `Apps/LumaHarborPad.swiftpm/Package.swift` nor `docs/testing/reports/2026-08-26-ipad-multi-source-library.md` appears.

- [ ] **Step 5: Commit the shared entry points**

Run:

```bash
git commit -m "docs: share project rules across Codex and Claude"
```

Expected: one commit containing only `AGENTS.md` and `CLAUDE.md`.

- [ ] **Step 6: Run final non-product verification**

Run:

```bash
git diff --check HEAD~2 HEAD
git status --short --branch
git show --stat --oneline HEAD~2..HEAD
```

Expected:

- `git diff --check` exits 0.
- The worktree still shows only the two preserved pre-existing dirty files.
- The two implementation commits contain five new Markdown files and no Swift or product files.

No Swift test or Xcode build is required because this plan changes documentation and agent-discovery files only; product source, package dependencies, and test behavior remain unchanged.
