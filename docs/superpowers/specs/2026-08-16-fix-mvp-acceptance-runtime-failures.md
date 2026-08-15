# Fix Mac MVP acceptance runtime failures and guarantee terminal reports

## Context

LumaHarbor commit `c114b39` now reaches its first complete-Xcode runtime gate on Apple Silicon. On 2026-08-16, macOS 26.6.2 with Xcode 26.6 (Build 17F113), Swift 6.3.3, 81 Sony ARW fixtures, an APFS scratch directory, and an exFAT scratch directory passed preflight and strict-concurrency compilation. The complete XCTest run did not pass: five independently reproducible tests failed, and the full suite could remain suspended without producing the runner's final `summary.md`.

This blocks the Mac-first MVP gate. The goal is not to hide failures or relax coverage. The goal is to correct invalid test assumptions, fix the local-index rebuild lifecycle, make the cancellation test exercise the race it claims to exercise, and ensure the acceptance runner always terminates with a report.

## Stakeholders and impact

- Maintainer: cannot sign off the MVP while the required acceptance command fails or hangs.
- End users: local-index deletion/rebuild must not corrupt the SQLite lifecycle or lose portable edits.
- Automation: a hung XCTest process must become an explicit timeout failure with a usable summary, never an indefinitely running job.

## Verified current state

Verification environment:

| Item | Observed value |
|---|---|
| Commit | `c114b39` |
| Architecture | `arm64` |
| macOS | 26.6.2 (25G82) |
| Xcode | 26.6 (17F113) |
| Swift | 6.3.3 |
| macOS SDK | 26.5 |
| RAW fixtures | 81 `.ARW` files |
| APFS directory | PASS |
| exFAT directory | PASS |
| Strict-concurrency build | PASS |

The project documentation explicitly states that these tests had previously received source-level validation but had not run under a complete XCTest runtime. The failures below are therefore latent runtime defects exposed by the intended acceptance environment, not evidence that the storage fixture directories were configured incorrectly.

### Failure inventory and root causes

| Area | Reproduction | Root cause | Classification |
|---|---|---|---|
| Shadows render direction | `AdjustmentPipelineTests.testLiftingShadowsBrightensADarkToneWithoutTouchingMidGrey` returns 61 from a base of 64 | The test supplies `0.25` as a linear-light component while describing it as a perceptual 25% shadow. The pipeline converts linear input to gamma-encoded sRGB before applying `CIToneCurve`, so that sample lands near the curve midpoint rather than the 25% control point. | Test fixture uses the wrong color-domain value |
| Bounded cancellation | `BoundedLibraryScanTests.testABatchFullyInspectedBeforeCancellationIsStillDropped` times out, then observes two committed rows | The test sets `gateAfterFileCount = 2` for exactly two files, while `GatedScanDecoder` enters the gate only when `index > gateAfterFileCount`. The gate can only open on a nonexistent third read, so cancellation occurs after the batch has already committed. The helper also performs an unconditional cancellation check after the gate, preventing it from modeling a non-cooperative decoder that returns a completed result. | Test synchronization/helper defect |
| Pinned disk cache | `DiskCacheTests.testPinnedEntriesAreNotEvicted` fails after unpin | With a 150-byte budget, storing a pinned 100-byte entry and another 100-byte entry evicts the unpinned entry immediately. After unpin, only 100 bytes remain, which is under budget; `evictIfNeeded()` correctly keeps it. The test expects eviction without creating budget pressure. | Invalid test expectation |
| JPEG sRGB tag | `JPEGExportTests.testExportedFileIsTaggedSRGB` reports `kCGColorSpaceSRGB` | The exported image is tagged with the Core Graphics sRGB constant. The assertion performs a case-sensitive substring search for `sRGB`, which does not match the constant's string spelling `kCGColorSpaceSRGB`. | String-format assertion instead of semantic comparison |
| Local index rebuild | `LibraryLifecycleTests.testDeletingTheLocalIndexAndCacheStillRebuildsFromTheDrive` throws SQLite `disk I/O error` | `ApplicationSupportLocations.removeRebuildableData()` unlinks `library.sqlite` and its cache while the original `PhotoLibraryService` still owns an open WAL-mode SQLite connection. A second store then opens the same path while the old connection remains alive. | Product lifecycle/API gap, not just a test defect |
| Full-suite suspension | Complete strict `swift test` can remain inside XCTest async waiting after reaching `testScanningAnOfflineLibraryFailsWithSomethingActionable`; the same test passes alone in about 0.01 seconds and the whole `LibraryLifecycleTests` class also completes | The suspension is suite-order/global async-state dependent, not an intrinsic offline-scan failure. Stack sampling shows XCTest waiting for an async expectation while worker queues are idle. Existing failures and cancellation helpers must be corrected first, then the full suite must be stress-rerun to identify any remaining leaked task. Regardless of the remaining trigger, the acceptance runner lacks a timeout/finalization path. | Cross-test async leak or XCTest interaction plus runner resilience gap |

## Proposed change

Deliver the work in four ordered phases. Do not skip directly to the runner timeout: the deterministic failures must be fixed first so a timeout does not merely mask product or test defects.

### Phase 1: Correct invalid runtime tests without weakening behavior

#### 1.1 Use the correct color domain in the shadows test

In `Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift`:

- Add a test-only helper that converts a perceptual sRGB component to its linear-light equivalent using the standard sRGB transfer function.
- Construct the intended 25% perceptual shadow patch with that linear value before sending it through the linear-working-space pipeline.
- Keep both behavioral assertions: full positive shadows must brighten the shadow sample, and the 50% perceptual midpoint must remain within the existing tolerance.
- Do not change `ToneCurveMapping.midpointShift` merely to satisfy the old fixture.
- Keep the pure `ToneCurveMappingTests.testShadowsAndHighlightsMoveTheQuarterPoints` assertion unchanged.

#### 1.2 Compare the JPEG color space semantically

In `Tests/RawProcessingCoreTests/JPEGExportTests.swift`:

- Replace the case-sensitive substring check with equality against the Core Graphics `CGColorSpace.sRGB` name constant, or an equivalent Core Graphics semantic equality check.
- Continue loading the encoded JPEG from disk through ImageIO. Do not replace this with a check of `ImageRenderService.outputColorSpace`, because the test must prove the written file carries the tag.
- Keep the real-JPEG marker and dimensions tests unchanged.

#### 1.3 Exercise cache eviction under actual pressure

In `Tests/PhotoLibraryCoreTests/DiskCacheTests.swift`:

- While the key is pinned, assert that it survives and that the competing unpinned entry is the one evicted.
- After unpinning, create new budget pressure (store another entry or reduce the byte budget below the resident total) before asserting that the formerly pinned key becomes evictable.
- Assert the cache remains at or below its byte budget after the forced eviction.
- Do not alter `DiskCache` or `LRUEvictionPlanner` unless a newly valid test demonstrates a product defect.

#### 1.4 Make the bounded-cancellation helper model the intended race

In `Tests/LumaHarborIntegrationTests/ScanCancellationTests.swift` and `Tests/LumaHarborIntegrationTests/BoundedLibraryScanTests.swift`:

- Preserve the meaning of `gateAfterFileCount`: N reads complete normally, and read N+1 enters the gate.
- For a two-file batch, gate the second read by setting the threshold to 1, not 2.
- When the helper is configured as a non-cooperative decoder, cancellation must not cause its final `Task.checkCancellation()` to throw after the gate is released. It must return valid metadata for the in-flight file so the service's pre-commit cancellation checkpoint, rather than the decoder, is what drops the completed batch.
- Wait for the gate to report that the second read entered, cancel the consumer, release the gate, await the consumer, then assert zero committed rows.
- Keep the complementary test proving that batches committed before cancellation survive.
- Do not add sleeps as the primary synchronization mechanism. Existing short post-completion settling sleeps may remain only where the assertion observes asynchronously finalized state.

### Phase 2: Add a safe product-owned rebuild lifecycle

The app-level operation must coordinate the SQLite connection. Tests must not manually reach into `indexStore.close()` as the shipped solution.

In `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift` and related index/location files:

- Change the service's index reference from immutable to replaceable under actor isolation.
- Add one public `PhotoLibraryService` operation for resetting rebuildable local data. Use a name that describes the user operation, such as `resetRebuildableLocalData()`.
- The operation must reject execution while a scan is active with an actionable `LibraryError`; it must not close SQLite underneath an active scan.
- Track active scans with actor-isolated state and decrement it on every exit path from `performScan`, including cancellation and early failure.
- When idle, the reset operation must:
  1. close the current `PhotoIndexStore`;
  2. delete only `library.sqlite`, its SQLite sidecars, and cache directories while preserving bookmarks;
  3. recreate the required directories and a fresh `PhotoIndexStore`;
  4. reinsert the service's known library records into the fresh index;
  5. leave photo rows empty until the normal scan path rebuilds them from `library.json` and sidecars.
- `ApplicationSupportLocations.removeRebuildableData()` must account for `library.sqlite-wal` and `library.sqlite-shm` if present. It must never remove the bookmarks directory.
- If deletion or recreation fails, return an actionable error and leave the service in a defined state. A subsequent app restart must still be able to recreate the index; do not silently retain a closed store as if it were usable.
- Update `LibraryLifecycleTests.testDeletingTheLocalIndexAndCacheStillRebuildsFromTheDrive` to invoke the service-owned reset operation, rescan using the normal service path, and verify:
  - two photos return;
  - their `PhotoID` values are unchanged;
  - saved adjustments survive from portable sidecars;
  - bookmarks remain available;
  - SQLite database, WAL, and SHM files can be recreated without I/O errors.
- Add a focused test proving reset is refused while a scan is active and succeeds after that scan ends or is cancelled.

### Phase 3: Guarantee acceptance-runner termination and reporting

In `Scripts/run-mvp-acceptance.zsh`:

- Add `LUMAHARBOR_STEP_TIMEOUT_SECONDS`, defaulting to 900 seconds. Validate that an override is a positive integer during preflight.
- Apply the timeout to strict build, complete strict `swift test`, and `RawFixtureTests`.
- Implement the watchdog using tools available on stock macOS plus complete Xcode. Do not add Homebrew or package dependencies.
- Launch each logged step under a dedicated wrapper process. On timeout, recursively identify only that wrapper's descendants, send `TERM`, wait a short grace period, then send `KILL` to survivors. Never use a broad process-name kill.
- Record timeout as `FAIL (timed out after Ns; see <log basename>)`.
- Refactor summary generation into an idempotent function and install `INT`, `TERM`, and `HUP` traps so interruption or timeout still produces `summary.md`.
- Write summaries atomically through a temporary file followed by rename.
- A timed-out full test must cause `RawFixtureTests` to be marked `SKIPPED (full swift test failed)` rather than run on top of a wedged or partially terminated test process.
- Extend the runner's internal self-test with a synthetic fast command and a synthetic hanging command. The hanging case must time out within a few seconds, leave no child process running, and produce a FAIL summary.
- Preserve current privacy behavior: never print the three fixture/storage environment-variable values or private absolute paths into the summary.

### Phase 4: Eliminate any remaining full-suite async leak

After Phases 1 and 2 pass individually:

- Run the complete strict suite at least twice consecutively.
- If it still suspends, bisect by test-class filters to identify the predecessor class that causes the later async test to stop completing.
- Capture an XCTest stack sample only when a run exceeds the expected duration.
- Trace and fix the leaked producer, iterator, continuation, or cancellation state at its owner. Do not add arbitrary sleeps or skip the affected test.
- Keep `LibraryLifecycleTests.testScanningAnOfflineLibraryFailsWithSomethingActionable`; it passes in isolation and is valid coverage.

## Ordering and dependencies

```text
Correct deterministic test assumptions
                |
                +--> Repair bounded cancellation test helper
                |
                +--> Implement safe SQLite reset lifecycle
                                |
                                v
                    Repeat complete strict suite
                                |
                 remaining suspension, if any
                                |
                                v
                  trace and fix async leak owner
                                |
                                v
                 add/verify runner finalization
                                |
                                v
                    complete MVP acceptance
```

The deterministic failures come first because they obscure later suite behavior. SQLite lifecycle comes before interpreting the full-suite suspension because an unexpected thrown test can change teardown timing. Runner timeout comes after root-cause fixes so it remains a safety boundary rather than a substitute for correctness.

## Files reference

| File | Required work |
|---|---|
| `Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift` | Build perceptual shadow fixtures in the correct linear domain |
| `Tests/RawProcessingCoreTests/JPEGExportTests.swift` | Compare encoded color-space identity semantically |
| `Tests/PhotoLibraryCoreTests/DiskCacheTests.swift` | Force real budget pressure before expecting post-unpin eviction |
| `Tests/LumaHarborIntegrationTests/ScanCancellationTests.swift` | Let the non-cooperative decoder return an in-flight result after cancellation |
| `Tests/LumaHarborIntegrationTests/BoundedLibraryScanTests.swift` | Correct gate threshold and assert the pre-commit cancellation checkpoint |
| `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift` | Own the SQLite reset lifecycle and active-scan guard |
| `Sources/PhotoLibraryCore/Access/ApplicationSupportLocations.swift` | Remove database sidecars and caches without touching bookmarks |
| `Sources/PhotoLibraryCore/Index/PhotoIndexStore.swift` | Reuse the existing explicit close path; change only if lifecycle needs a well-defined closed state |
| `Scripts/run-mvp-acceptance.zsh` | Add timeout, process-tree cleanup, traps, and atomic summary finalization |
| Runner self-tests or new script-level test file | Verify successful command, timeout, child cleanup, and summary generation |

## What is working and must not be weakened

- Preflight correctly verifies Apple Silicon, complete Xcode, Swift, ARW fixtures, APFS, and exFAT.
- Strict-concurrency compilation succeeds.
- `ToneCurveMapping` pure arithmetic tests pass and should not be tuned around the incorrect linear fixture.
- JPEG output is a real full-resolution JPEG and reports the Core Graphics sRGB constant.
- LRU planning correctly protects pinned entries under pressure.
- The service already has a pre-commit cancellation checkpoint; the repaired test must prove it rather than bypass it.
- Offline scanning produces an actionable error and passes in isolation.
- RAW fixtures and both scratch directories are read-only inputs to the runner. No implementation may delete, chmod, format, mount, or unmount them.

## Acceptance criteria

1. Each previously deterministic failure passes when run alone with strict concurrency:
   - `AdjustmentPipelineTests.testLiftingShadowsBrightensADarkToneWithoutTouchingMidGrey`
   - `BoundedLibraryScanTests.testABatchFullyInspectedBeforeCancellationIsStillDropped`
   - `DiskCacheTests.testPinnedEntriesAreNotEvicted`
   - `JPEGExportTests.testExportedFileIsTaggedSRGB`
   - `LibraryLifecycleTests.testDeletingTheLocalIndexAndCacheStillRebuildsFromTheDrive`
2. The bounded cancellation focused test passes 20 consecutive runs without timeout, committed rows, skipped runs, or leaked test processes.
3. Resetting rebuildable data while a scan is active returns a documented actionable error and does not corrupt or close the live index.
4. Resetting while idle preserves bookmarks and portable edits, recreates SQLite cleanly, and restores identical photo IDs after rescan.
5. `swift build -Xswiftc -strict-concurrency=complete` exits 0 with no new concurrency diagnostics.
6. `swift test -Xswiftc -strict-concurrency=complete` completes twice consecutively with zero failures and zero skipped tests. Neither run may exceed the configured acceptance timeout.
7. `LUMAHARBOR_RUNNER_SELFTEST=1 Scripts/run-mvp-acceptance.zsh` covers both normal completion and a synthetic hang; the hang is terminated and reported as FAIL without leaving descendants.
8. With the established RAW/APFS/exFAT environment variables, `Scripts/run-mvp-acceptance.zsh --preflight-only` passes.
9. With the same variables, `Scripts/run-mvp-acceptance.zsh` terminates and writes `summary.md` with every step classified. Success requires overall PASS, exactly eight executed `RawFixtureTests`, zero failures, and zero skipped tests.
10. Interrupting or forcing the runner's synthetic timeout still leaves a parseable, atomically written `summary.md`.
11. `git diff --check` passes and no RAW fixture, private absolute path, `.build` output, or test-volume content is added to Git.

## Testing plan

| Layer | What | Required repetitions |
|---|---|---:|
| Unit | Shadow domain, sRGB tag, DiskCache pressure | Each focused test once after red-green validation |
| Integration | Completed-batch cancellation and SQLite reset/rebuild | Cancellation 20 times; rebuild at least twice |
| Suite | Complete strict-concurrency XCTest | 2 consecutive clean runs |
| Runner self-test | Success, timeout, descendant cleanup, atomic summary | 1 deterministic self-test run |
| Hardware acceptance | Preflight, full suite, 8 real ARW fixture tests across APFS/exFAT setup | 1 final full acceptance run |

## Rollback plan

- Keep the work on a dedicated local branch until all acceptance criteria pass.
- If the SQLite reset API causes regressions, revert the product-lifecycle commit independently; do not retain a test-only manual-close workaround as the final state.
- If the runner watchdog behaves incorrectly, revert the watchdog/finalization commit independently while retaining deterministic test and product fixes.
- Never roll back by deleting tests, adding skips, raising timeouts without evidence, or weakening assertions to match current output.

## Out of scope

- New photo-editing features or UI redesign.
- Changing RAW rendering aesthetics beyond correcting the test's color-domain fixture.
- Supporting non-Apple-Silicon hosts for this MVP gate.
- Formatting, mounting, unmounting, or modifying external test volumes.
- Upgrading Xcode, Swift, package dependencies, or the package deployment target solely to make failures disappear.
- Publishing, pushing, merging, or deploying without separate user authorization.

## Claude execution contract

1. Work from the repository root on a dedicated local branch; do not modify `main` directly.
2. Read this entire spec and the referenced implementation/tests before editing.
3. Use red-green-refactor per failure. Run the focused failing test before its change and record the observed failure.
4. Implement one root cause at a time. Do not batch unrelated speculative refactors.
5. Do not edit, move, or expose the private RAW fixtures or scratch-volume contents.
6. Do not push or merge. Leave the branch and working tree ready for review.
7. Final report must include:
   - branch and final commit/working-tree state;
   - files changed and why;
   - focused-test results;
   - two complete strict-suite results;
   - runner self-test result;
   - final MVP `summary.md` contents;
   - sanitized failure excerpts for anything still failing;
   - explicit list of any acceptance criterion not met.
