# Mainline White Balance and Brush Integration Verification

Date: 2026-10-06
Status: `DONE_WITH_CONCERNS`

## Scope and result

The branch integrates native white-balance entry and eyedropper sessions, Sidecar v5, independent ordered adjustment brushes, source/display geometry mapping, preview/export rendering, editor gesture/save behavior, batch/clipboard/snapshot preservation, and shared Mac/iPad UI. Legacy local brushes remain independent and render through their existing stage.

Correctness, persistence, build, RAW fixture, privacy, packaging, and Simulator launch gates pass. The remaining release concerns are effective brush-load performance and unavailable manual/device checks. No push, merge, rebase, public release, physical-device installation, or daily-app replacement occurred.

## Git and source preservation

- Target branch: `codex/mainline-wb-brush-integration`
- Base: `origin/main` at `82542e73aae8f16b0ba7e4d9d36a8a42451a7319`
- Verified implementation HEAD: `0cd6eba4a8c75746f7c7cefa24a4c7a85f6b114d`
- Ahead/behind `origin/main`: 23/0 at the implementation checkpoint
- Upstream: `origin/main`; the task branch itself was not pushed
- The preserved source worktree remained at `5a80e969fbae94d8ee6db4842f3a2def781329f3` with the same 24 tracked modifications and 10 untracked paths.
- `Apps/LumaHarborPad.xcodeproj/project.pbxproj` has no target-branch diff from the base.

## Functional matrix

| Area | Result | Evidence |
| --- | --- | --- |
| White-balance presentation and legal-value boundary | PASS | Direction, clamping, preset, write-boundary, and decoder suites pass. |
| Eyedropper session safety | PASS | Deferred result, stale-context, cancellation, gesture close, and race-matrix tests pass. |
| Sidecar v1-v5 read / v5 write | PASS | Missing-field migration, experimental v3, curation, snapshot, invalid data, and v6 rejection tests pass without overwrite. |
| Legacy local brush coexistence | PASS | Legacy model and selection remain separate from `brushMasks`; combined workflow and render-order tests pass. |
| Adjustment brush model and validation | PASS | Renderer version, coordinate, stroke, patch, ordering, serialization, and invalid-input tests pass. |
| Geometry and pixel behavior | PASS | White/gray/asymmetric synthetic controls, crop/rotate/flip mapping, radial feather/flow, erase overlap, and same-size unchanged-region assertions pass. |
| Preview/export parity | PASS | Shared recipe, output dimensions, selected brush pixels, and unchanged-region tolerances pass. |
| Editor gesture, save, switch, and races | PASS | Single-commit gesture, cancellation, stale-save invalidation, switch/flush, clipboard, batch, and snapshot suites pass. |
| Mac/iPad UI contracts and localization | PASS | Native input, overlay routing, full-row targets, eight-locale key parity, Mac/iPad wiring, and accessibility contract tests pass. |
| Real RAW fixture suite | PASS WITH 1 SKIP | 10 executed, 1 skipped, 0 failures. The skipped reference-export case requires a separate opt-in output directory. Source fixture inventory was unchanged. |
| Mac manual UI | NOT RUN | Computer Use could not access native apps because the Mac was locked. |
| iPad Simulator launch | PASS | Existing generic Simulator build installed and launched; the first screen rendered a photo, Inspector, and Traditional Chinese UI. App was terminated and Simulator returned to shutdown. |
| Physical iPad / Pencil / VoiceOver / keyboard / rotation / Split View | NOT RUN | No physical-device installation or interactive manual session was authorized or performed. |
| Gray-card D65 Lab / ΔE00 | NOT RUN | No approved paired gray-card reference corpus was available for this run. |
| Formal Lightroom Gate 2 | NOT RUN | Existing fail-closed renderer policy and registry state were not changed by this integration. |

## Commands and counts

All commands ran from the target worktree unless noted.

| Command | Exit | Result |
| --- | ---: | --- |
| Focused post-fix tests for UI/schema contracts | 0 | 19 executed, 0 failures |
| Task 7 UI-focused fresh suite | 0 | 84 executed, 0 failures |
| `swift test` with fresh module caches and scratch | 0 | 2,687 executed, 17 skipped, 0 failures |
| `swift build -Xswiftc -strict-concurrency=complete` with fresh scratch | 0 | PASS; existing warnings remain outside this task |
| `Scripts/build-app-bundle.sh release` with fresh scratch | 0 | Mac Release app built and ad-hoc signed |
| `xcodebuild ... -destination 'generic/platform=iOS Simulator' ... CODE_SIGNING_ALLOWED=NO build` | 0 | `BUILD SUCCEEDED` |
| `xcodebuild ... -destination 'generic/platform=iOS' ... CODE_SIGNING_ALLOWED=NO build` | 0 | `BUILD SUCCEEDED` |
| `swift test --filter RawFixtureTests` with private fixture injection | 0 | 10 executed, 1 skipped, 0 failures |
| `Scripts/verify-release-privacy.sh build/LumaHarbor.app` | 0 | PASS |
| Branch-diff private-path/credential scan | 0 | PASS |
| `Scripts/package-mac-release.sh release` with a fresh temporary output directory | 0 | ZIP built, extracted, rescanned, and checksum produced |
| `shasum -a 256 -c LumaHarbor-0.1.0.zip.sha256` | 0 | ZIP checksum OK |
| `simctl` boot/install/launch/screenshot/terminate/shutdown | 0 | iPad Simulator launch smoke PASS |
| `git diff --check` | 0 | PASS before the test-fix commit; rerun after final docs below |

The private RAW directory, filenames, and digests are intentionally omitted. The package was local-only, unnotarized, and unpublished.

## Performance evidence

Hardware: Apple M4, 32 GB RAM, arm64, macOS 26.7.1. Preview target: 1600 px. Each mask used 10 paint strokes with 100 normalized points per stroke. The renderer and Core Image context were reused within each eight-sample run. Baseline/current neutral runs were interleaved across two rounds after one warmup.

| Scenario | Round | n | p50 | p95 | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Baseline, empty brush | 1 | 8 | 159.252 ms | 162.997 ms | 506.0 MiB* |
| Current, empty brush | 1 | 8 | 151.625 ms | 155.080 ms | 518.4 MiB* |
| Baseline, empty brush | 2 | 8 | 154.145 ms | 157.590 ms | 139.1 MiB |
| Current, empty brush | 2 | 8 | 153.781 ms | 157.638 ms | 139.4 MiB |
| Current, one mask | 1 | 8 | 933.909 ms | 946.079 ms | 161.7 MiB |
| Current, one mask | 2 | 8 | 943.847 ms | 974.744 ms | 161.2 MiB |
| Current, ten masks | 1 | 8 | 7,993.114 ms | 8,052.909 ms | 193.3 MiB |
| Current, ten masks | 2 | 8 | 8,008.038 ms | 8,030.047 ms | 192.8 MiB |

`*` Round-one peak RSS includes the incremental Swift test build process and is not a renderer-only memory figure.

The empty-brush budget is `max(5 ms, baseline p50 × 5%)`: 7.963 ms in round 1 and 7.707 ms in round 2. Current is 7.627 ms faster in round 1 and 0.364 ms faster in round 2, so empty brushes pass the regression budget. The absolute current p50 straddles the existing 150 ms interaction target, so this machine does not establish a universal ≤150 ms claim.

Cancellation of a ten-mask preview had p50 32.509 ms and p95 153.295 ms across eight samples. The high sample matches the documented limitation that Core Image RAW decode cannot be preempted mid-flight; cancellation completes at the next stage boundary.

Full-resolution 6000×4000 exports completed without OOM:

| Scenario | n | Time | Peak RSS | Result |
| --- | ---: | ---: | ---: | --- |
| One mask | 1 | 9,106.195 ms | 484.7 MiB | Completed |
| Ten masks | 1 | 87,181.560 ms | 691.2 MiB | Completed |

The effective brush-load numbers are not interactive. This is the principal concern preventing an unqualified `DONE`: the current CPU coverage rasterizer scales approximately with mask count and must be optimized before claiming fluid one- or ten-mask editing.

## Privacy and release boundary

- App bundle byte scan: PASS.
- Branch diff scan for private absolute paths, signing identities, credentials, and private-key material: PASS.
- Extracted test ZIP scan and checksum verification: PASS.
- Local ad-hoc signing only; notarization was skipped.
- The test ZIP stayed in an isolated temporary output directory and was not uploaded or published.
- Product version and internal build remained unchanged.

## Remaining concerns

1. `BrushMaskRenderer` effective-load performance is too slow for interactive use with the mandated path density. Clear this by replacing or batching the CPU coverage rasterization while preserving current pixels, validation, geometry, ordering, and cancellation tests, then rerun the same matrix.
2. Mac manual interaction could not run while the host was locked. Clear this with an unlocked isolated-app smoke covering numeric input, eyedropper direction, brush paint/erase, geometry, undo/redo, save/reopen, and export.
3. Physical iPad checks remain unavailable. Clear them with an explicitly authorized test deployment and manual Pencil, touch, keyboard, VoiceOver, orientation, and Split View matrix.
4. Gray-card D65 Lab/ΔE00 and formal Lightroom Gate 2 remain separate evidence gates and must not be inferred from synthetic or RAW smoke tests.
