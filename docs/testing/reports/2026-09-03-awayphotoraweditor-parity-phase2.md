# AwayPhotoRawEditor Parity Phase 2 Report

Date: 2026-09-03
Branch: `claude/awayphotoraweditor-parity-phase2-geometry`
Worktree: `/Users/private-builder/github/LumaHarbor/.worktrees/claude-awayphotoraweditor-parity-phase2-geometry`
Base: local `main@fb7109a4fd76035bb9ca3f492b1fa45f511a60ec` (Phase 1 + its independent-review P1 fix, merged; `main` remains unpushed, 27 commits ahead of `origin/main`)
HEAD at report time: `91b425a`
Roadmap: `docs/superpowers/plans/2026-09-02-awayphotoraweditor-parity-roadmap.md` ("Phase 2: Geometry and White Balance Tools")
Design spec: `docs/superpowers/specs/2026-09-02-awayphotoraweditor-parity-design.md`

## Summary

Status: **AUTOMATED VERIFICATION COMPLETE** for Tasks 2.1–2.4 (geometry model/sidecar compatibility, geometry render pipeline + crop preview integration, Mac crop/rotate/straighten UI, white balance eyedropper). Task 2.5 is this report itself: no product code changed in this round, only whole-range verification and this report. Real-device/Simulator/human-eyes manual UI verification for any of Tasks 2.1–2.4 remains `NOT RUN` — see "Not run" below. Independent review by a second agent has not happened for this phase; see "Review request."

## Commits (base..HEAD, 8 commits, 0 behind `main`)

| Commit | Task | Description |
|---|---|---|
| `7d1ea56` | 2.1 | feat: geometry adjustment model and sidecar compatibility |
| `77bf2cd` | 2.1 | docs: record Phase 2 Task 1 evidence in CURRENT.md |
| `36fb7b7` | 2.2 | feat: geometry render pipeline and crop preview integration |
| `c9e8383` | 2.2 | docs: record Phase 2 Task 2 evidence in CURRENT.md |
| `9e93d72` | 2.3 | feat: Mac crop/rotate/straighten UI |
| `a1c178f` | 2.3 | docs: record Phase 2 Task 2.3 evidence in CURRENT.md |
| `3b8bbcf` | 2.4 | feat: white balance eyedropper |
| `91b425a` | 2.4 | docs: record Phase 2 Task 2.4 evidence in CURRENT.md |

Detailed per-task evidence (what changed, RED/GREEN detail, exact test names, known scope boundaries) already lives in `docs/coordination/CURRENT.md`'s "Phase 2 Task 2.1"–"Phase 2 Task 2.4" sections and each task's own commit message; this report focuses on Task 2.5's own whole-phase verification pass and does not duplicate that detail verbatim.

## Task-by-task recap

- **Task 2.1 — Geometry model and sidecar compatibility**: `GeometryAdjustments` (crop/rotation/flip/straighten/perspective), `NormalizedCropRect` (self-clamping `[0,1]` rect), and `CropAspectRatio` added to `RawProcessingCore`. `PhotoAdjustments.geometry` wired in with the same backward-compatible Codable convention every other sub-adjustment uses (`decodeIfPresent(...) ?? .neutral`) — a sidecar written before this field existed, or any Phase-1-era sidecar with every other key present but no `geometry` key, decodes to neutral geometry. Rotation snaps to the nearest 90° and wraps into `[0,360)`; straighten clamps ±45; perspective clamps ±100; crop rect validation keeps the requested size and slides the origin back into frame rather than shrinking it, floors width/height at a minimum (`0.01`), and falls back to the full frame for non-finite input. `AdjustmentMapping.renderParameters(for:)` deliberately did not read `geometry` yet, pinned by a regression test.
- **Task 2.2 — Geometry render pipeline and crop preview integration**: `GeometryRenderer` applies crop → rotate 90°/flip → straighten → perspective (the roadmap's documented order) to a `CIImage`, wired into both `CoreImagePreviewRenderer` (so the interactive preview reflects geometry) and `PhotoExporter` (so full-resolution export applies the identical geometry, from the same code path, not a separate implementation). Rotation is expressed as clockwise degrees, the opposite sign of `CGAffineTransform(rotationAngle:)`'s native convention in Core Image's y-up space — verified empirically against real rendered output, not assumed. Straighten/perspective are clamped back to their input canvas rather than growing it, trading auto-fit for an exactly metadata-predictable output size (`GeometryRenderer.appliedPixelSize(of:geometry:)`). A real bug was caught and fixed in this same round: the export's resize-fitting transform was fitting `maximumWidth`/`maximumHeight` against the *uncropped* native decode size; it now fits against the geometry-adjusted extent.
- **Task 2.3 — Mac crop/rotate/straighten UI**: the first on-canvas gesture this app has. `EditorToolMode` (`.adjust`/`.crop`) is the first "what tool is active" concept in this codebase. `GeometryAdjustmentPanel` (Inspector's sixth group) exposes rotate-left/right, flip horizontal/vertical, a straighten slider, an aspect-ratio picker (records intent only, does not yet constrain dragging), and localized non-destructive safety copy. `CropOverlayView` draws a dimmed scrim, border, and four corner-handle drag targets on the photo itself, with all direction/fixed-corner math in the pure, unit-tested `CropDragMath`. `AspectFitRect` reproduces the preview's own `.aspectRatio(contentMode: .fit)` layout as a testable `CGRect`, so the overlay lines up with the photo exactly.
- **Task 2.4 — White balance eyedropper**: `WhiteBalanceEyedropper` is a pure, self-contained RGB-to-slider-delta estimate — deliberately does not call `CIRAWFilter`'s own `neutralLocation`/`neutralTemperature` (unused anywhere in this codebase, proprietary, unverifiable without a real RAW fixture in this environment); works from already-decoded/rendered RGB instead, matching the design spec's own "一般影像格式則以已解碼 RGB 估算" framing. `PixelSampler` promotes this codebase's existing test-only pixel-reading technique to production code. `EditorSession` gained `previewEyedropper(sample:)`/`cancelEyedropperPreview()`/`commitEyedropper()`, extending the exact non-committing preview pattern already established for presets — hover/drag preview never touches `history`/`saveState`; only release commits, satisfying the spec's own "不得在 hover / preview 階段寫入 sidecar" and "使用者必須能取消滴管" requirements.

## Automated verification

### Focused tests per task

| Task | Suites (representative) | Result | Evidence |
|---|---|---|---|
| 2.1 | `GeometryAdjustmentsTests`, `NormalizedCropRectTests`, `CropAspectRatioTests`, `PhotoAdjustmentsTests`, `AdjustmentMappingTests` | PASS | 77 executed, 0 failures |
| 2.2 | `GeometryRendererTests`, `PhotoExportTests`, `CoreImagePreviewRendererTests`, `AdjustmentPipelineTests` | PASS | 97 executed, 0 failures |
| 2.3 | `CropOverlayContractTests`, `AdjustmentGroupPanelsContractTests`, `InspectorAdjustmentGroupsContractTests`, `CropDragMathTests`, `AspectFitRectTests` | PASS | 32 executed, 0 failures |
| 2.4 | `WhiteBalanceEyedropperTests`, `PixelSamplerTests`, `EyedropperOverlayContractTests`, `EditorSessionEditingTests` | PASS | 45 executed, 0 failures |
| 2.3+2.4 localization | `LocalizationSmokeTest` | PASS | 7 executed, 0 failures |

Re-run fresh for this report (not carried over from each task's own round) — every number above matches what each task's own commit message/`CURRENT.md` entry already claimed.

### Full-phase gates

| Gate | Result | Evidence |
|---|---|---|
| `swift test` (full suite) | PASS | 1354 executed, 9 skipped, 0 failures |
| — skipped tests identity | as expected | all 9 skips are `LumaHarborIntegrationTests.RawFixtureTests` (`testEveryFixtureDecodes`, `testExportingNeverModifiesTheOriginal`, `testFullDecodeReturnsNativeResolution`, `testFullResolutionExportMatchesTheSourceDimensions`, `testInteractivePreviewLatencyForARealPhoto`, `testPreviewDecodeHonoursTheRequestedSize`, `testPreviewSchedulerDeliversARenderedFrameForARealRaw`, `testSonyArwReportsPlausibleMetadata`, `testWhiteBalanceOffsetChangesTheRender`) — the same fixture-dependent baseline (`LUMAHARBOR_RAW_FIXTURE_DIR` unset in this environment) every prior round on this project has reported, unchanged by Phase 2 |
| `git diff --check` (working tree) | PASS | no output |
| `git diff --check` (full range `fb7109a..HEAD`) | PASS | no output at all — cleaner than Phase 1's own equivalent gate, which flagged pre-existing whitespace in a docs commit that predates Phase 2 entirely; Phase 2 touched none of those files |
| Privacy scan (`rg -n "/Users/\|/Volumes/\|/private/\|7KM4ZM25P3\|teamIdentifier:\|DEVELOPMENT_TEAM"` over `git diff fb7109a..HEAD`) | PASS | every hit is inside `docs/coordination/CURRENT.md`'s own prose, referencing this worktree's own already-public path (the same pattern every prior round accepted) or the old Claude worktree's already-documented preserved-signing-file path; zero hits for the strict signing/device-only patterns (`7KM4ZM25P3`, `teamIdentifier:`, `DEVELOPMENT_TEAM`) and zero real `/Volumes/` mount paths |
| Mac app build (`swift build`) | PASS | `Build complete!` |
| iOS generic build (`xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/LumaHarbor-Phase2Task5-DerivedData CODE_SIGNING_ALLOWED=NO build`) | PASS | `** BUILD SUCCEEDED **`; run because every task this phase touched shared `RawProcessingCore`/`EditorCore`/`AdjustmentUI`/`Localization` API the iPad `.swiftpm` package also depends on |
| Local signing/project file | untouched | `Apps/LumaHarborPad.xcodeproj/project.pbxproj` never appeared in `git status` at any point across all four tasks or this verification round |

## Not run

- **Every real-device/Simulator/human-eyes manual check for Tasks 2.1–2.4.** No device or Simulator was available in this environment. This specifically covers, per the roadmap's own Task 2.5 checklist:
  - **Crop direction** — dragging a corner handle actually resizes from the expected fixed corner, on screen, not just in `CropDragMathTests`' own coordinate math.
  - **Rotate direction** — clicking "rotate right" actually turns the photo clockwise on screen, not just in `GeometryRendererTests`' quadrant-marker-image assertions.
  - **Flip direction** — flip horizontal/vertical mirror the expected axis on screen.
  - **Straighten slider** — the fine-angle slider visibly rotates the photo in the expected direction and the transparent-corner behavior (canvas clamped, not grown) reads as sensible rather than broken.
  - **Eyedropper cancel/apply** — clicking a warm/cool/green/magenta area of a real photo actually nudges the image the expected direction, the ring marker tracks the cursor sensibly, and toggling the tool off mid-preview visibly reverts.
  - The roadmap's own §6.5 text is explicit about this gap: "裁切與旋轉的 UI 正負方向必須用真人或 screenshot fixture 驗證，不能只用數學座標直覺決定" (crop/rotate UI sign convention must be verified by a human or screenshot fixture, not math intuition alone). Every direction claim landed this phase is backed by a synthetic-image or pure-math unit test with an explicitly stated expected outcome (not "trust the formula by inspection"), which is a real, deliberate substitute for *some* of that requirement, but is not the human/screenshot verification itself.
- **`LumaHarborIntegrationTests.RawFixtureTests`** (9 tests, listed above) — `SKIPPED`, not `NOT RUN`: the existing, unchanged fixture-dependent baseline (requires `LUMAHARBOR_RAW_FIXTURE_DIR`, and this environment has no real camera RAW fixtures to point it at).
- **Aspect-ratio-locked dragging** (Task 2.3) — the picker records the lock preference only; it does not yet constrain a live drag or auto-apply a centered rect on selection. Recorded as a scope decision in Task 2.3's own `CURRENT.md` evidence, repeated here for completeness.
- **Continuous hover-before-click eyedropper preview** (Task 2.4) — only a press-and-hold drag live-updates the preview; there is no `.onContinuousHover`-driven preview before the first click.
- **Calibration of the eyedropper's temperature/tint sensitivity constants** (Task 2.4) — a first-guess value, not measured against any reference target.

## Independent review

No second agent has independently reviewed this phase's diff (`fb7109a..HEAD`) from a fresh session with no prior context. Per this repo's established practice (see `docs/coordination/CURRENT.md`'s prior "independent review" entries for precedent, e.g. Phase 1's own P1 finding on `ExportMetadataBuilder`), this phase should not be treated as ready to land until that happens. Suggested focus areas for that review:

- whether `GeometryRenderer`'s documented transform order (crop in the source's own pre-rotate coordinates → rotate/flip → straighten → perspective) is actually the right order for how Task 2.3's UI lets a user compose these edits in practice — e.g. cropping first, in un-rotated source coordinates, when the crop overlay is drawn and dragged in already-rotated/straightened screen space, is a real (documented) mismatch worth a second pair of eyes;
- whether `CropDragMath`'s "floor at minimum size, don't swap handle identity" behavior when a corner is dragged past its opposite corner is an acceptable first-version limitation or worth fixing before Task 2.3 is considered done;
- whether `WhiteBalanceEyedropper`'s self-defined, self-consistent direction convention (not verified against `CIRAWFilter`'s actual behavior) is close enough to correct to ship, or whether it needs adjustment once tested against a real photo;
- whether `previewedEyedropperAdjustments` as a field genuinely separate from `previewedPresetAdjustments` (rather than a shared/generalized preview slot) was the right call, given the two are already mutually exclusive in practice via `toolMode`;
- whether the aspect-ratio picker recording intent without enforcing it is confusing enough in practice to need at least a "not yet enforced" affordance before Task 2.3 ships, even as a stopgap.

## Landing readiness

Not landed, merged, rebased, or pushed. `claude/awayphotoraweditor-parity-phase2-geometry` remains a separate branch/worktree at `/Users/private-builder/github/LumaHarbor/.worktrees/claude-awayphotoraweditor-parity-phase2-geometry`, unpushed, with no signing/local-project setting committed. Recommended next step: independent review (see above), then either continue to Task 2.5's remaining item (none — this report is Task 2.5) → next phase (Phase 3: Preset, Batch, Virtual Copy) per the roadmap, or land this phase per the user's own merge process. Local `main` itself remains at `fb7109a`, 27 commits ahead of `origin/main`, unpushed — unaffected by this branch.
