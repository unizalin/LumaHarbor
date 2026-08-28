# Codex Task 2 Round 4 — Task 2 review evidence fix round 4

## Verdict on `da885c2`

The production fix is correct. This round is limited to closing two Important
test/evidence gaps and one report mismatch before integration. Do not modify
production source code.

## Worktree and boundaries

- Worktree:
  `/Users/private-builder/Documents/ChatGPT/LumaHarbor/codex-ipad-multi-source-library-durability`
- Branch: `codex/ipad-multi-source-library-durability`
- Expected starting HEAD:
  `da885c2b321b07ca5dcda8fefdc14dff0502b874`
- Do not modify any file under `Sources/`.
- Allowed tracked files:
  - `Tests/PhotoLibraryCoreTests/LibrarySourceRecoveryTests.swift`
  - `sdd/codex-task2-round4-task2-report.md`
- Preserve all five untracked review/handoff files exactly; do not add, modify,
  stash, delete, or commit them:
  - `sdd/codex-task2-round4-task1-brief.md`
  - `sdd/codex-task2-round4-task2-brief.md`
  - `sdd/codex-task2-round4-task2-review-fix-round3.md`
  - `sdd/codex-task2-round4-task2-review-evidence-round4.md`
  - `sdd/lumaharbor-task2-claude-handoff.md`
- No push, merge, rebase, amend, squash, or product Task 3 work.
- Create one independent evidence-hardening commit after `da885c2`.

## Important 1: prove the propagated error is the SQLite index error

The compound test currently accepts any thrown `Error`:

```swift
do {
    _ = try await service.restoreLibraries()
    XCTFail("Expected the index read failure to propagate")
} catch {
    // expected
}
```

This does not prove the requirement or the report's claim. A regression that
stops B but rethrows the original `BookmarkError` would still pass.

Replace the broad catch with exact structural verification:

- the error must be `SQLiteError`;
- it must be `.prepareFailed` from querying the deliberately closed database;
- its message must be exactly `"database is closed"`;
- the SQL text may be pattern-matched without hard-coding the entire query,
  but it must be non-empty and correspond to the library lookup;
- a `BookmarkError` or any other error type must call `XCTFail` with the
  unexpected type/case, without printing a private filesystem path.

Do not compare `localizedDescription`; compare the structured `SQLiteError`
case and safe fields.

After this assertion, retain every existing scope/durable/source invariant in
the test.

## Important 2: injected errors must not contain a real absolute path

`FakeBookmarkDataCreator` currently throws:

```swift
BookmarkError.couldNotCreate(path: url.path, reason: "injected test failure")
```

This puts the real temporary absolute path into the error payload, contrary to
the round 3 requirement. Replace it with fixed synthetic values, for example:

```swift
BookmarkError.couldNotCreate(
    path: "<injected-test-path>",
    reason: "injected bookmark creation failure"
)
```

Do not use `url.path`, the repository path, `/Users/`, `/Volumes/`,
`/private/var/`, or `/private/tmp/` anywhere in the injected error payload.

Add a focused assertion on the fake itself, or expose a deterministic captured
error in the existing test, proving its associated `path` and `reason` are the
fixed markers and do not contain private-path prefixes. Do not weaken the
production privacy mapper.

## Minor: make the callback actually one-shot

The report calls `onFailureAttempt` one-shot, but the implementation leaves it
installed. Make the implementation match the report:

- while holding the lock, copy `onFailureAttempt` to a local and clear the
  stored callback when a failing URL consumes it;
- release the lock before invoking the callback;
- repeated bookmark attempts must not rerun the index-closing callback;
- do not hold the lock across XCTest assertions or `indexStore.close()`.

Add a small deterministic count assertion proving two failing calls consume
the callback only once. The calls may both still throw the injected bookmark
error; only the side-effect callback is one-shot.

## Evidence protocol

This round hardens tests for already-correct production code. Do not fabricate
a product RED or temporarily break committed production code.

Record:

1. The original broad-catch test's weakness.
2. The new exact-error assertion passing against unchanged `da885c2`
   production code.
3. The fixed synthetic payload assertion.
4. The one-shot callback count assertion.

Update the Round 3 report text so it no longer overclaims evidence that the old
test did not establish. Append a new `Independent review evidence fix round 4`
section with exact commands and counts.

## Verification

Run:

```zsh
swift test --filter 'LibrarySourceRecoveryTests.testCompoundBookmarkCreationAndIndexReadFailureStopsStagedHandleAndPreservesA'
swift test --filter 'LibrarySourceRecoveryTests'
swift test --filter 'LibraryRegistryTransactionTests|LibrarySourceRecoveryTests'
swift test --filter PhotoLibraryCoreTests
swift test
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
git diff --check
git status --short --branch
```

Required results:

- exact SQLite error assertion passes;
- fake error payload has no private path;
- callback count is exactly one across two failing attempts;
- full suite has 0 failures;
- report all skipped tests honestly;
- no recurring subprocess hang. If a hang recurs, capture and report it under
  the existing bounded diagnostic policy instead of silently retrying.

## Commit and completion response

Create a new commit:

```text
test: prove stale restore compound failure evidence
```

Do not amend `da885c2`. Do not push.

Return only:

- Status: DONE / DONE_WITH_CONCERNS / BLOCKED
- Commit SHA and subject
- Exact SQLiteError assertion used
- Synthetic injected-error payload assertion
- One-shot callback evidence
- Focused/full test counts and skipped count
- Strict build and `git diff --check`
- `git status --short --branch`
- Concerns

Stop afterward for Codex's final read-only review.
