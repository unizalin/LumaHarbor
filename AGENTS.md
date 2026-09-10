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
- Gemini spec reading protocol: `docs/superpowers/specs/2026-09-10-gemini-project-spec-reading-protocol.md`

## Completion and handoff

- Run verification proportional to the change before reporting completion.
- Update `CURRENT.md` whenever the validated product baseline, ownership, dirty files, test evidence, blockers, or next action changes.
- A handoff must identify branch, full HEAD SHA, base, commits, changed files, tests, skipped or unrun gates, dirty files, concerns, and one bounded next action.
- Handoff records supplement Git commits, plans, specs, and reports; they do not replace them.
