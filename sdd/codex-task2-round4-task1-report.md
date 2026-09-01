# Codex Task 2 Round 4 — Task 1 Report

## Status

DONE

- Worktree: `/Users/private-builder/Documents/ChatGPT/LumaHarbor/codex-ipad-multi-source-library-durability`
- Branch: `codex/ipad-multi-source-library-durability`
- Starting HEAD: `cfc3cebb8fe0e369c70299fb1bcd91c4e7ba9e92`
- Commit subject: `Fix fail-closed library identity restore`
- Commit SHA: reported in the completion response after creating the commit (a commit cannot contain its own SHA).
- Durable transaction journal and product Task 3 were not entered.

## Implemented behavior

### A. Fail-closed bookmark registry

- `FileBookmarkStore.loadAll()` returns an empty array only when the registry directory does not exist.
- Directory listing failures, record read failures, empty files, malformed JSON, and valid JSON of the wrong record shape now throw.
- Non-JSON files remain ignored.
- Unknown `sourceKind`/`scanState` raw strings continue decoding to safe defaults.

### B. Physical relationship matrix

- Matching manifest IDs remain `.same`, independent of path.
- Different known volumes remain `.distinct`.
- Missing-volume matching resource/path/containment evidence now returns `.ambiguous`.
- Natural-case equality/containment is component-aware.
- Case-insensitive volumes use case-folded equality and containment.
- Unknown case sensitivity returns `.ambiguous` when only case folding reveals a possible relationship.
- Root `/` and component boundaries such as `/Photos` versus `/Photos2` are handled explicitly.
- Manifest mismatch upgrades only physically confirmed `.same` to `.conflict`; ambiguous physical evidence stays `.ambiguous`.

### C. Injectable resource identity

- `PhotoLibraryService` accepts `ResourceIdentityResolving`, defaulting to `SystemResourceIdentityResolver`.
- The dependency is used for add candidates, existing live sources, stale-bookmark identity refresh, and relink candidates.
- Service-level coverage verifies different volumes, same-volume siblings, and case-insensitive parent/child overlap.

### D. Fail-closed restore validation

- Restore now stages an access handle and validates with read-only `probeManifest()` before publishing ready/read-only state.
- The accepted matrix covers confirmed-ID equality, safe backfill, and legacy absent-manifest sources.
- Conflict, missing, corrupt, unsupported, unavailable, authorization, and persistence failures produce `.needsAuthorization` with `LibraryRestoreDiagnostic`.
- Diagnostics are path-free structured values exposed through `restoreDiagnostic(for:)`.
- Manifest bytes and modification times are asserted unchanged throughout the restore matrix.
- Blocked/offline sources cannot scan, read adjustments, save adjustments, or bypass the block through `refreshAvailability()`.
- Bookmark backfill/stale refresh saves are required; failures block the source.
- Index reads/upserts in restore propagate errors; restore no longer uses `try?` for them.

### E. Explicit scope lifetime

- Successful restore replaces the handle only after persistence/index success, then explicitly stops the old handle.
- Resolution failure, offline transition, identity/persistence block, and removed bookmark stop/remove old handles.
- Failed staged restore stops the staged handle.
- Index failure preserves the previous valid actor/access state while stopping the staged handle.
- Availability refresh cannot mark a source ready when no committed access handle exists.

## TDD evidence

Each behavior group had an observed RED before its production change (the scope-lifetime suite was also sensitivity-checked against the original direct-replacement baseline):

1. Bookmark registry RED
   - Command: `swift test --filter FileBookmarkStoreTests`
   - Result: 12 tests, 4 expected failures.
   - Failures: malformed JSON, empty file, wrong JSON shape, and injected directory read error did not throw.
   - GREEN: same command, 12 tests, 0 failures.

2. Physical relationship RED
   - Command: `swift test --filter LibrarySourceIdentityTests.testFailClosedPhysicalRelationshipMatrix`
   - Result: 1 test, 7 expected assertion failures.
   - Failures covered missing-volume evidence, case-folded containment, root containment, and ambiguous manifest mismatch.
   - GREEN: `swift test --filter LibrarySourceIdentityTests`, 30 tests, 0 failures.

3. Service identity injection RED
   - Command: `swift test --filter LibrarySourceLifecycleTests.testInjectedResourceIdentityControlsServiceOverlapDecisions`
   - Result: expected compile failure, `extra argument 'resourceIdentityResolver' in call`.
   - After adding the dependency, a test-fixture case-canonicalization miss was corrected without changing production semantics.
   - GREEN: 1 test, 0 failures.

4. Restore validation RED
   - Command: `swift test --filter LibrarySourceRecoveryTests.testReachableRestoreBlocksAnAlreadyConfirmedIDWhenDiskDisagreesWithoutMutatingManifest`
   - Initial result: expected compile failure because `restoreDiagnostic(for:)` did not exist.
   - Blocked-scan RED: 4 expected failures; scan started, no failure event was emitted, and manifest bytes/mtime changed.
   - Refresh bypass RED: 5 expected failures; `refreshAvailability()` changed conflict to ready and allowed the manifest mutation.
   - GREEN: conflict remained `.needsAuthorization`, diagnostic was `.manifestConflict`, refresh stayed blocked, scan failed before start, bytes/mtime were unchanged.
   - Full validation matrix GREEN: 1 matrix test covering 9 valid/blocked rows, 0 failures.

5. Repeated restore/scope RED
   - Command: `swift test --filter LibrarySourceRecoveryTests.testRepeatedRestorePairsEveryStagedAndReplacedScopeExactlyOnce`
   - Result against the original direct-replacement/no-stop baseline: 1 test, 10 expected stop-count failures.
   - Offline refresh RED: 1 expected failure; path reachability incorrectly restored ready without a handle.
   - GREEN: all success/failure transitions and exact stop counts passed.

## Changed files

- `Sources/PhotoLibraryCore/Access/BookmarkStore.swift`
- `Sources/PhotoLibraryCore/Scanning/LibrarySourceIdentity.swift`
- `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`
- `Tests/PhotoLibraryCoreTests/FileBookmarkStoreTests.swift`
- `Tests/PhotoLibraryCoreTests/LibrarySourceIdentityTests.swift`
- `Tests/PhotoLibraryCoreTests/LibrarySourceLifecycleTests.swift`
- `Tests/PhotoLibraryCoreTests/LibrarySourceRecoveryTests.swift`
- `sdd/codex-task2-round4-task1-report.md`

## Focused verification

- `swift test --filter 'LibrarySource(Identity|Lifecycle|Recovery)Tests|FileBookmarkStoreTests|PhotoIndexStoreTests'`
  - PASS: 106 tests, 0 failures.
- `swift test --filter 'RelinkResolverTests|LibraryLifecycleTests'`
  - PASS: 26 tests, 0 failures.
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
  - PASS: build completed with exit code 0.
- `git diff --check`
  - PASS before report creation; rerun at the final gate.
- `git status --short --branch`
  - Rerun at the final gate before commit.

## Self-review and decisions

- Restore diagnostics intentionally contain no paths or raw error descriptions.
- Persistence failure is represented as a blocked per-library result; index failure propagates because the index write is the final commit gate.
- Identity/persistence blocks remove access because retaining it would allow source operations; an index failure before successful commit retains the previous valid actor/access state.
- `refreshAvailability()` is not allowed to manufacture authorization: a diagnostic or missing handle remains blocked/offline until restore or relink succeeds.
- No mutating `loadManifest()` call was introduced into restore.
- No durable transaction journal or product Task 3 code was added.

## Concerns

None within this task's scope.

---

## Independent review fix round — 2026-08-27

### Status

DONE

- Starting HEAD: `48234da5d3871bd275792baaf42925e289034352`
- Commit subject: `Fix fail-closed source metadata reads`
- Commit SHA: reported in the completion response; a commit cannot contain its own SHA without an additional commit or amend.
- Durable transaction journal, product Task 3, and the untracked review brief were not modified.

### Review findings fixed

- `FileBookmarkStore.loadAll()` now attempts the directory listing directly. It returns `[]` only for explicit Cocoa no-such-file errors or POSIX `ENOENT`; permission, metadata, listing, record-read, and decoding failures throw.
- `FileSidecarRepository.probeManifest()` now reads `library.json` directly. Only explicit no-such-file errors map to `.absent`; every other lookup/read failure maps to `.unavailable`, without quarantine or mutation.
- Shared `FileSystemError.isNoSuchFile(_:)` narrowly recognizes Cocoa `.fileNoSuchFile`/`.fileReadNoSuchFile`, POSIX `ENOENT`, and a bounded underlying-error chain. Other I/O errors are never treated as absence.
- Restore coverage now proves a source with `confirmedManifestLibraryID == nil` and an unavailable manifest becomes `.needsAuthorization` with `.manifestUnavailable`.
- The same blocked-restore test directly verifies both `adjustments(for:)` and `saveAdjustments(_:for:)` reject access, while RAW bytes and the failing manifest path remain unchanged.
- Bookmark coverage now verifies a single `*.json` record whose data cannot be read makes `loadAll()` throw.

### TDD evidence

1. RED
   - Command: `swift test --filter 'FileBookmarkStoreTests.testFileExistsFalseDoesNotHideDirectoryListingPermissionFailure|SidecarRepositoryTests.testProbeManifestDoesNotTreatAFileExistsFalseNegativeAsAbsent|LibrarySourceRecoveryTests.testUnavailableManifestProbeBlocksRestoreAndBothEditAPIsWithoutTouchingRAWBytes|FileBookmarkStoreTests.testJSONRecordDataReadFailureMakesLoadAllThrow|SidecarRepositoryTests.testProbeManifestReturnsAbsentForAGenuinelyMissingManifest'`
   - Result: 5 tests executed; 2 expected failures.
   - Bookmark failure: injected `fileExists == false` hid `CocoaError.fileReadNoPermission` and returned `[]`.
   - Manifest failure: injected `fileExists == false` hid a deterministic manifest data-read failure and returned `.absent` instead of `.unavailable`.
   - Genuine missing-directory/manifest behavior, the JSON-record read failure, and service-level blocked restore already passed.

2. GREEN
   - Same command after the minimal production change.
   - Result: 5 tests, 0 failures.

### Changed files

- `Sources/PhotoLibraryCore/Access/BookmarkStore.swift`
- `Sources/PhotoLibraryCore/Sidecar/SidecarRepository.swift`
- `Sources/PhotoLibraryCore/Storage/FileSystemError.swift`
- `Tests/PhotoLibraryCoreTests/FileBookmarkStoreTests.swift`
- `Tests/PhotoLibraryCoreTests/SidecarRepositoryTests.swift`
- `Tests/PhotoLibraryCoreTests/LibrarySourceRecoveryTests.swift`
- `sdd/codex-task2-round4-task1-report.md`

### Verification

- `swift test --filter 'LibrarySourceRecoveryTests|FileBookmarkStoreTests|SidecarRepositoryTests'`
  - PASS: 52 tests, 0 failures.
- `swift test --filter 'LibrarySource(Identity|Lifecycle|Recovery)Tests|FileBookmarkStoreTests|PhotoIndexStoreTests'`
  - PASS: 109 tests, 0 failures.
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
  - PASS: exit code 0. The first sandboxed invocation could not write the user-level clang module cache; the identical approved invocation completed successfully.
- `git diff --check`
  - Run at the final pre-commit gate.

### Concerns

None within this review-fix scope.

---

## Independent review fix round 2 — 2026-08-27

### Status

DONE

- Starting HEAD: `00afc571dd1230f92cda1dd39fce95b82ba94f0d`
- Commit subject: `Narrow missing-file error classification`
- Commit SHA: reported in the completion response; a commit cannot contain its own SHA without an additional commit or amend.
- The untracked review brief was not modified.

### Review finding fixed

- `FileSystemError.isNoSuchFile(_:)` now treats recognized Cocoa and POSIX domains as authoritative: Cocoa `.fileNoSuchFile`/`.fileReadNoSuchFile` and POSIX `ENOENT` return `true`; every other code in those domains returns `false` immediately.
- Only an unknown/wrapper error domain may inherit a no-such-file classification from `NSUnderlyingErrorKey`.
- A Cocoa permission error or POSIX `EACCES` can no longer be reclassified as missing merely because it wraps POSIX `ENOENT`.
- `FileBookmarkStore.loadAll()` coverage proves a wrapped Cocoa permission error propagates instead of returning an empty registry. Existing manifest probe tests continue to exercise the same shared helper through `FileSidecarRepository`.

### TDD evidence

1. RED
   - Command: `swift test --filter 'FileBookmarkStoreTests.testNoSuchFileClassificationMatrixDoesNotLetKnownPermissionErrorsInheritENOENT|FileBookmarkStoreTests.testWrappedCocoaPermissionErrorStillMakesLoadAllThrow'`
   - Result: 2 tests, 3 expected failures.
   - The direct matrix misclassified Cocoa permission→ENOENT and POSIX EACCES→ENOENT as missing; `loadAll()` consequently failed to throw the wrapped permission error.

2. GREEN
   - Same command after the two short-circuit changes.
   - Result: 2 tests, 0 failures.

### Direct helper matrix

- Cocoa `.fileReadNoSuchFile` → `true`
- POSIX `ENOENT` → `true`
- Unknown wrapper → POSIX `ENOENT` → `true`
- Cocoa `.fileReadNoPermission` → POSIX `ENOENT` → `false`
- POSIX `EACCES` → POSIX `ENOENT` → `false`

### Changed files

- `Sources/PhotoLibraryCore/Storage/FileSystemError.swift`
- `Tests/PhotoLibraryCoreTests/FileBookmarkStoreTests.swift`
- `sdd/codex-task2-round4-task1-report.md`

### Verification

- `swift test --filter 'LibrarySourceRecoveryTests|FileBookmarkStoreTests|SidecarRepositoryTests'`
  - PASS: 54 tests, 0 failures.
- `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`
  - PASS: exit code 0.
- `git diff --check`
  - Run at the final pre-commit gate.

### Concerns

None within this review-fix scope.
