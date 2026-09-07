# Codex Task 2 Round 4 — Task 2 independent review fix round 3

## Verdict on `4c3545b`

The primary A-to-B durability defect is fixed, and its focused test is real.
The commit is not ready to integrate because one compound failure path can
still leak the newly staged security-scope handle.

## Worktree and boundaries

- Worktree:
  `<CODEX_IPAD_DURABILITY_WORKTREE>`
- Branch: `codex/ipad-multi-source-library-durability`
- Expected starting HEAD:
  `4c3545bf97b07b5fa5e85e89d6a53f4b35f0750c`
- The following four untracked review/handoff documents are expected. Preserve
  them exactly and do not add, modify, stash, delete, or commit them:
  - `sdd/codex-task2-round4-task1-brief.md`
  - `sdd/codex-task2-round4-task2-brief.md`
  - `sdd/lumaharbor-task2-claude-handoff.md`
  - `sdd/codex-task2-round4-task2-review-fix-round3.md`
- Do not push, merge, rebase, amend, squash, or start product Task 3.
- Append detailed evidence to
  `sdd/codex-task2-round4-task2-report.md` under
  `Independent review fix round 3`.
- Create a new independent commit after `4c3545b`.

## Important finding: staged scope leaks when the recovery projection read also fails

The new stale-bookmark catch currently performs this sequence:

```swift
folder = try index.library(id: folder.id) ?? persistedFolder
folder.connectionState = .needsAuthorization
folder = try commitDisconnectedRestore(
    folder: folder,
    diagnostic: .persistenceFailure,
    stagedAccess: stagedAccess,
    persistLibraryProjection: false
)
```

`stagedAccess` already exists at this point. If `index.library(id:)` throws,
control exits before `commitDisconnectedRestore` gets the chance to call
`stagedAccess.stop()`. The old actor/access state remains, which is the safe
choice for a pre-commit index failure, but the new B handle is leaked.

This is not covered by the new test because its SQLite read always succeeds.

## Required semantics

There are two distinct cases; do not collapse them into the same result.

### A. Bookmark-data creation fails while the old durable projection is readable

Keep the behavior delivered by `4c3545b`:

- return a blocked folder based on old root A;
- set `.needsAuthorization` and `.persistenceFailure`;
- leave the bookmark and SQLite projection exactly at A;
- stop both the old retained handle and newly staged B handle exactly once;
- leave no registry journal;
- never expose or persist B as committed state.

### B. Bookmark-data creation fails and reading the old SQLite projection also fails

The service cannot safely construct the requested blocked projection, so the
index error must propagate. Do not downgrade it to `.persistenceFailure` and
do not invent a durable result.

Before throwing:

- stop the newly staged B handle exactly once;
- retain the previously valid A actor state and A access handle when safe;
- do not clear or replace the old A access handle;
- do not modify the bookmark record;
- do not modify SQLite;
- do not create a registry journal;
- do not change the restore diagnostic or claim the failed restore committed;
- do not touch RAW files or manifests.

The preferred design is to obtain the previous durable index projection before
acquiring a new access handle and reuse that single snapshot later. If that
would cause an unjustified wider behavioral change, a narrowly scoped
`do/catch` that stops `stagedAccess` before rethrowing the index error is also
acceptable. Whichever design is chosen must be proven by deterministic tests
and must not double-stop a handle.

Do not use `try?`, `defer` that also stops a successfully committed handle, or
a catch-all that converts SQLite failure into a normal blocked restore.

## Strict TDD requirements

### RED 1 — compound failure after the B handle exists

Add a deterministic service-level test. Extend the bookmark-data creator test
double with a one-shot callback or equivalent seam so it can:

1. Observe that stale root B bookmark creation was attempted only after the B
   access handle exists.
2. Close/fail the service index at that exact point.
3. Throw the injected bookmark-creation failure.

Then assert against unmodified `4c3545b`:

- `restoreLibraries()` throws the index error;
- the previously retained A handle has `stopCallCount == 0`;
- the newly staged B handle has `stopCallCount == 1` after the fix (the RED
  against `4c3545b` should show it remains `0`);
- actor-visible `service.library(id:)` is still the previous ready A folder;
- the bookmark record remains exactly the old A record;
- reopening the SQLite database with a fresh store/service shows the exact old
  A projection;
- no pending registry journal exists;
- A and B source files/manifests are unchanged.

Do not merely close the index before calling `restoreLibraries()` if that
causes failure before B is staged; the test must exercise the actual leak by
making index failure occur after the new handle exists.

### Strengthen the existing single-failure test

Extend
`testStaleBookmarkDataCreationFailureBeforeJournalPreparePreservesOldDurableState`
to assert:

- `await service.library(id:)` is based on A and is
  `.needsAuthorization`, not only the returned array value;
- both root A and root B manifest bytes and modification timestamps remain
  unchanged across the failed restore (capture before and compare after);
- a sentinel source file in each root remains byte-for-byte unchanged;
- the journal remains absent.

This strengthening is evidence coverage, not permission to modify source
files in production code.

### Preserve all existing behavior

The following must remain GREEN:

- successful stale bookmark refresh;
- simple bookmark-data creation failure from `4c3545b`;
- transactional forward-save failure and exact rollback to A;
- repeated restore scope-pairing matrix;
- registry transaction recovery and scan reentrancy tests.

## Error/privacy requirements

- Do not add a path-bearing user-facing error.
- The injected test failure may contain a test marker but no real private path.
- Production `SystemBookmarkDataCreator` must remain the default.
- All service-owned bookmark creation call sites must continue to use the same
  injected dependency.

## Verification

Run in this order and record exact counts:

```zsh
swift test --filter 'LibrarySourceRecoveryTests'
swift test --filter 'LibraryRegistryTransactionTests|LibrarySourceRecoveryTests'
swift test --filter 'LibrarySource(Identity|Lifecycle|Recovery)Tests|FileBookmarkStoreTests|PhotoIndexStoreTests'
swift test --filter 'RelinkResolverTests|LibraryLifecycleTests'
swift test --filter PhotoLibraryCoreTests
swift test
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
git diff --check
git status --short --branch
```

If `PendingLeaseSubprocessTests` hangs again, do not silently retry and call it
PASS. Capture the exact test name, process state and a bounded diagnostic;
terminate/reap any child process, then rerun the isolated test once and the
full suite once. Report both the first incident and rerun. A repeated hang is a
separate blocker and must not be dismissed as an unrelated flake.

Skipped tests must be reported as skipped, never as passed.

## Commit and completion response

Create a new commit with subject:

```text
fix: close stale bookmark compound-failure scope leak
```

Do not amend `4c3545b`. Do not push.

Return only:

- Status: DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED
- Commit SHA and subject
- RED command and exact failing assertion
- GREEN focused and full test counts
- Access-handle stop-count results for both failure cases
- Bookmark/index/journal invariants
- Strict build and `git diff --check`
- `git status --short --branch`
- Any hang, skip, or concern

Stop after the commit and response. Codex will perform another independent
read-only review.
