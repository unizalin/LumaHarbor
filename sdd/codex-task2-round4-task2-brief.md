# Codex Task 2 Round 4 — Task 2 independent review fix round 2

## Context

This is a focused repair on top of commit
`60f270125fedc32da92d33851ad8fd015c7399d0`. The first independent review
fixed the transactional stale-bookmark failure that occurs after a journal is
prepared. One earlier failure branch remains unsafe: creating refreshed
bookmark data can fail before `applyRegistryTransaction` is called.

Do not reimplement Task 2, redesign the journal, or start product Task 3.

## Worktree and boundaries

- Worktree:
  `/Users/private-builder/Documents/ChatGPT/LumaHarbor/codex-ipad-multi-source-library-durability`
- Branch: `codex/ipad-multi-source-library-durability`
- Expected starting HEAD:
  `60f270125fedc32da92d33851ad8fd015c7399d0`
- The following three untracked handoff documents are expected at startup;
  preserve them exactly as-is and do not add, modify, stash, delete, or commit
  them:
  - `sdd/codex-task2-round4-task1-brief.md`
  - `sdd/codex-task2-round4-task2-brief.md`
  - `sdd/lumaharbor-task2-claude-handoff.md`
- No push, merge, rebase, amend, squash, or edits outside this worktree.
- Do not start product Task 3.
- Follow strict TDD: first add one deterministic failing service-level test,
  run it against the current production code and record the expected RED,
  then make the minimum production change and rerun GREEN.
- Append detailed evidence to
  `sdd/codex-task2-round4-task2-report.md` under a new
  `Independent review fix round 2` section.
- Create one independent fix commit; do not amend `60f2701`.

## Remaining defect

In `PhotoLibraryService.restoreLibraries()`, a stale bookmark can resolve from
the old durable root A to a new reachable root B. The current code updates the
working `folder` projection to B and then calls
`makeBookmarkData(for: stagedAccess.url)`.

If refreshed bookmark creation itself throws, execution enters the catch at
the stale-bookmark branch before a registry transaction has been prepared.
That catch currently calls `commitDisconnectedRestore` with the B projection
and its default `persistLibraryProjection: true`. As a result:

- the bookmark store correctly remains at old root A;
- there is no journal, because prepare was never reached;
- but SQLite can be overwritten with root B;
- actor memory can also expose B as the durable projection;
- the bookmark and index therefore diverge despite the operation failing.

The existing save-interceptor test covers a later failure: refreshed bookmark
data is successfully created, then the transactional bookmark save fails. It
does not cover this earlier bookmark-data-creation failure.

## Required behavior

### A. Add a deterministic bookmark-creation failure seam

Add the smallest injectable dependency that lets service tests make refreshed
bookmark-data creation fail for a selected URL.

- Production default must continue to call
  `SecurityScopedBookmark.makeBookmarkData(for:)`.
- Keep the seam narrowly scoped and concurrency-safe.
- Route service-owned bookmark creation consistently through this dependency;
  do not leave the stale-refresh branch on a separate static helper.
- Do not expose private paths through a new public error message.

### B. Fail closed before journal prepare

When stale-bookmark refresh data creation fails:

- return the library as `.needsAuthorization`;
- record `.persistenceFailure` as the restore diagnostic;
- stop the newly staged access exactly once;
- stop/remove the previously retained access according to the already
  approved blocked-restore ownership rule;
- retain the exact old bookmark bytes and metadata;
- retain the exact old SQLite `LibraryFolder` projection, including old root,
  display metadata, counts and scan timestamps;
- do not persist the newly resolved B path to SQLite;
- do not expose B as if it were committed durable actor state;
- do not create or leave a registry transaction journal, since failure occurs
  before prepare;
- do not mutate source RAW files or either root's manifest.

Use the prior durable projection (`index.library(id:)` when present, otherwise
the projection derived from the persisted bookmark) for the disconnected
in-memory result. The blocked result may be stored in actor memory with the
diagnostic, but durable bookmark/index state must remain byte-for-byte/logically
unchanged.

Do not solve this by swallowing the error, deleting the source, accepting B,
or writing a compensating B-to-A transaction after the fact.

### C. Preserve existing transactional failure behavior

The already-covered later failure must remain GREEN:

- refreshed bookmark data creation succeeds;
- journal prepare succeeds;
- forward bookmark or index persistence fails;
- rollback restores the exact old bookmark and index projection;
- the source remains blocked with `.persistenceFailure`;
- no half-updated projection becomes ready.

## Required RED test

Add a deterministic service-level test in
`Tests/PhotoLibraryCoreTests/LibrarySourceRecoveryTests.swift` with this full
shape:

1. Establish root A with a durable bookmark and SQLite projection.
2. Restore it successfully once so access ownership is real, not synthetic.
3. Create root B with the same valid manifest identity.
4. Make the resolver return root B with `isStale == true`.
5. Inject bookmark-data creation failure specifically for B.
6. Call `restoreLibraries()`.
7. Assert `.needsAuthorization` and `.persistenceFailure`.
8. Assert the bookmark record is exactly the old A record.
9. Assert the SQLite library projection is exactly the old A projection and
   contains no B path.
10. Assert the actor-visible blocked folder is based on A, not B.
11. Assert old and staged access handles each stop exactly once as required.
12. Assert no pending registry journal exists.
13. Assert source manifests/RAW data are unchanged.

The test must fail against `60f2701` for the actual A/B index divergence. Do
not manufacture RED by changing expectations or temporarily breaking unrelated
production code.

## Verification

At minimum run, in this order:

```zsh
swift test --filter 'LibrarySourceRecoveryTests'
swift test --filter 'LibraryRegistryTransactionTests|LibrarySourceRecoveryTests'
swift test --filter 'LibrarySource(Identity|Lifecycle|Recovery)Tests|FileBookmarkStoreTests|PhotoIndexStoreTests'
swift test --filter 'RelinkResolverTests|LibraryLifecycleTests'
swift test
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
git diff --check
git status --short --branch
```

Report skipped tests honestly. Do not call skipped tests PASS.

## Commit and completion response

Create an independent commit with subject:

```text
fix: preserve durable restore state when bookmark refresh creation fails
```

Do not push. Return only:

- Status: DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED
- Commit SHA and subject
- RED command and exact failure
- GREEN focused/full test summary
- Strict build and `git diff --check` result
- `git status --short --branch`
- Concerns

Write all detailed evidence to the report file. Stop after this fix so Codex
can perform a separate read-only review.
