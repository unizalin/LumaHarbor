# Codex Task 2 Round 4 — Task 1: fail-closed identity and restore

## Context

This is the first of two sequential repair tasks on top of commit `cfc3ceb`. It closes identity/restore/registry/scope gaps. Do not implement the durable transaction journal yet; that is Task 2. Do not start product Task 3.

## Worktree and boundaries

- Worktree: `/Users/private-builder/Documents/ChatGPT/LumaHarbor/codex-ipad-multi-source-library-durability`
- Branch: `codex/ipad-multi-source-library-durability`
- Expected starting HEAD: `cfc3cebb8fe0e369c70299fb1bcd91c4e7ba9e92`
- No push, merge, rebase, amend, squash, or edits outside this worktree.
- Follow strict TDD: add one focused failing test, run it and record the expected RED, then make the minimum production change and re-run GREEN. Repeat by behavior cluster.
- Commit only this task when all focused tests pass.
- Append a report to `sdd/codex-task2-round4-task1-report.md` with RED/GREEN evidence, changed files, decisions, tests, commit and concerns.

## Required behavior

### A. Bookmark registry must not become silently incomplete

`FileBookmarkStore.loadAll()` currently returns `[]` on directory I/O errors and uses `compactMap` to silently drop unreadable/invalid JSON records.

- A missing bookmark directory is still a valid empty registry.
- Any other directory read failure must throw.
- Any `.json` record that cannot be read or decoded must make `loadAll()` throw (a structured aggregate result is acceptable, but mutation/restore must fail closed; a plain throw is the smallest acceptable design).
- Unknown-but-valid enum raw strings remain backward-compatible and decode to safe defaults; they are not corruption.
- Update the old tests that explicitly accepted silent skipping.
- Add tests for missing directory, unreadable directory/read error if deterministically injectable, invalid JSON, empty file, and unknown enums.

### B. Correct physical relationship when volume/case evidence is incomplete

Keep the approved rule that equal confirmed manifest IDs are `.same` even at another path. Keep different known volumes `.distinct`.

- Missing volume + matching resource ID => `.ambiguous`, never `.same` or `.distinct`.
- Missing volume + exact canonical path => `.ambiguous`.
- Missing volume + canonical paths that may be ancestor/descendant => at least `.ambiguous`, never `.distinct`.
- Known case-insensitive volume: case-folded, component-aware equality and containment. `/Photos` vs `/photos/Child` must be ancestor/descendant.
- Known case-sensitive volume: natural-case equality/containment.
- Unknown sensitivity: natural-case exact equality/containment may be used; if only case-folding reveals possible equality/containment, return `.ambiguous`.
- Correctly handle root `/` and component boundaries (`/Photos` is not ancestor of `/Photos2`).
- Manifest mismatch upgrades only a physically confirmed `.same` to `.conflict`; possible/ambiguous physical relation stays `.ambiguous`.

Add a full pure matrix plus service-level overlap cases.

### C. Make resource identity injectable through PhotoLibraryService

Add the smallest `ResourceIdentityResolving` dependency to `PhotoLibraryService` and use it for every candidate/live identity resolution performed by the service. Default remains `SystemResourceIdentityResolver`.

Add actual service-level tests, not helper-only tests:

1. Two candidate directories with injected different volume IDs and different pre-existing valid manifests can both be added.
2. Same injected volume, sibling directories, different pre-existing valid manifests can both be added.
3. Case-insensitive parent/child aliases are rejected through `addLibrary`.

### D. Restore manifest validation must fail closed

Refactor `restoreLibraries()` so a reachable source is not marked `.ready/.readOnly` and no new access handle is committed until bookmark resolution, read-only manifest probe, identity validation, required bookmark persistence and index update all succeed.

Valid states:

- persisted confirmed ID equals valid disk manifest ID: normal.
- persisted confirmed ID is nil, valid disk ID equals `bookmark.libraryID`: persist the backfill; only then normal.
- persisted confirmed ID is nil and manifest is absent: normal legacy/no-manifest source.

Blocked states:

- persisted confirmed ID differs from valid disk manifest.
- persisted confirmed ID exists but manifest is absent.
- persisted ID nil but valid disk ID differs from `bookmark.libraryID`.
- corrupt, unsupported/newer, or probe unavailable on an otherwise resolved/reachable source.
- required backfill/stale-bookmark save failure.

For blocked states:

- connection must be `.needsAuthorization` (the approved enum has no identity-conflict case), never ready/readOnly.
- no scan/edit/source write is allowed.
- source manifest bytes/mtime stay unchanged; do not call mutating `loadManifest()`.
- staged/new access is stopped and not retained.
- preserve a structured per-library restore diagnostic so callers/tests can distinguish authorization failure from manifestConflict, manifestMissing, corruptManifest, unsupportedManifest, manifestUnavailable, and persistenceFailure. Add a minimal query API if needed; do not expose private paths in user-facing text.
- index persistence errors must propagate; do not use `try?`.

### E. Repeated restore must pair scope lifetime explicitly

- Stage a new handle; validate/persist first; then atomically replace and explicitly `stop()` the old handle.
- Resolution failure, unreachable/offline, identity blocked, or a bookmark no longer present must stop/remove any old handle.
- If restore fails before commit, stop the staged handle and retain the previous valid actor/access state when safe.
- Add deterministic stop-count tests for restore→restore success, success→resolution failure, reachable→offline, ready→manifest conflict, and restore save/index failure.

## Focused verification

At minimum:

```zsh
swift test --filter 'LibrarySource(Identity|Lifecycle|Recovery)Tests|FileBookmarkStoreTests|PhotoIndexStoreTests'
swift test --filter 'RelinkResolverTests|LibraryLifecycleTests'
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
git diff --check
git status --short --branch
```

## Completion response

Return only:

- Status: DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED
- Commit SHA and subject
- One-line focused test summary
- Concerns

Write all detailed evidence to the report file and stop after this task.
