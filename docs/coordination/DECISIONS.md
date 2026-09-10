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

## D-006 — Sidecar schema v3 ships without `snapshots`

- Date: 2026-09-10
- Decision: `PhotoSidecar.currentSchemaVersion = 3` adds `curation` only. The approved professional editing completion spec's §6.1 bundles `curation` and `snapshots` into one version bump; `docs/superpowers/plans/2026-09-10-curation-sidecar-v3-and-migration.md` implements P1 only (curation) and defers `EditSnapshot`/`snapshots` to P6, where it will ship as its own schema version.
- Reason: The task authorizing that plan explicitly excludes P2 and later phases, including P6 (Snapshot). Defining `EditSnapshot` now, only to satisfy a version-number bundling in the spec text, would be scope creep with no test coverage or consumer.
- Impact: A future P6 plan bumps `PhotoSidecar.currentSchemaVersion` again (to 4) when it adds `snapshots`; that plan must re-verify v1/v2/v3 sidecars all still decode.
