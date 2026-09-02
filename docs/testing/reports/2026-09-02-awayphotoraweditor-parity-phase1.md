# AwayPhotoRawEditor Parity Phase 1 Report

Date: 2026-09-02
Branch: `codex/awayphotoraweditor-parity-phase1`
Base: local `main@8a400edb0f07082d157abb28b9c688d18db98f34`
HEAD at report time: `d942ac64d3b78f6c789a8c6276f6a27244b440a5`
Plan: `docs/superpowers/plans/2026-09-02-awayphotoraweditor-parity-phase1.md`
Design spec: `docs/superpowers/specs/2026-09-02-awayphotoraweditor-parity-design.md`

## Summary

Status: **AUTOMATED VERIFICATION COMPLETE** for Tasks 1–4 (metadata/EXIF panel, rendered histogram, Mac adjustment inspector productization, single-photo export options foundation). Task 5 is this report itself: no product code changed in this round, only verification and this report. Real-device/Simulator manual UI verification for any of Tasks 1–4 remains `NOT RUN` — see "Not run" below. Independent review by a second agent has not happened for this phase; see "Review request."

## Commits (base..HEAD, 7 commits, 0 behind `main`)

| Commit | Task | Description |
|---|---|---|
| `a8c1c2c` | — | docs: plan AwayPhotoRawEditor parity phases (pre-existing, authored before this round) |
| `0151561` | 1 | feat: add Mac editor metadata/EXIF snapshot panel |
| `5bbeb06` | 2 | feat: add rendered-preview histogram service |
| `53a8a81` | 3 | feat: productize Mac adjustment inspector into Basic/Color/Curve/Detail/Effects |
| `9c3cb15` | 3 | docs: record Phase 1 Task 3 evidence in CURRENT.md |
| `f0dd922` | 4 | feat: single-photo export options foundation (JPEG/PNG/TIFF/HEIC) |
| `d942ac6` | 4 | docs: record Phase 1 Task 4 evidence in CURRENT.md |

Detailed per-task evidence (what changed, RED/GREEN detail, exact test names) already lives in `docs/coordination/CURRENT.md`'s "Phase 1 Task 3" and "Phase 1 Task 4" sections and is not duplicated verbatim here; this report focuses on Task 5's own full-phase verification pass.

## Task-by-task recap

- **Task 1 — Metadata/EXIF snapshot**: `RawMetadata` carries the Phase 1 visible fields (filename, format, pixel dimensions, file size, camera, lens, focal length, aperture, shutter speed, ISO, capture date, orientation) via `EditorMetadataSnapshot`, rendered in a dedicated `InspectorView` section. Missing EXIF degrades to safe placeholders, never a crash; the shown filename is source-safe (never a raw absolute path).
- **Task 2 — Rendered histogram**: `HistogramComputer` bins the *currently displayed rendered preview*, not fixed RAW statistics; `EditorSession.histogram` is versioned with preview generation so a stale computation can never overwrite a newer frame's histogram. RGB composite + per-channel bins, with localized fallback copy when nothing has rendered yet.
- **Task 3 — Mac adjustment inspector productization**: the inspector groups every existing adjustment into five labeled panels — Basic (unchanged, pre-existing `BasicAdjustmentPanel`, already covers every `AdjustmentKind`), Color (all 8 HSL bands), Curve (advanced tone curve identity + Reset), Detail (sharpening + noise reduction), Effects (vignette + grain). A new shared `AdjustmentSliderRow` gives every new row the same double-click/context-menu reset gesture `BasicAdjustmentPanel` already had. `EditorSession.updateAdjustments(_:)` is the new general edit path for sub-struct fields, going through the same undo/autosave path as `setAdjustment(_:to:)`. No new sidecar schema.
- **Task 4 — Single-photo export options foundation**: `JPEGExporter` renamed and generalized to `PhotoExporter` behind a format-aware `ExportRequest` (JPEG/PNG/TIFF/HEIC), default output byte-for-byte equivalent to the old JPEG-only behavior. New `ExportFormat` (extension/UTI/quality-and-bit-depth applicability/capability detection), `ExportBitDepth` (TIFF 8/16-bit), `ExifRetentionPolicy` (preserveAll/removeAll/partial), `ExportResizing` (max-width/max-height, aspect-preserving, never upscales), `ExportMetadataBuilder` (RawMetadata → ImageIO properties). The exporter refuses an unsupported format before touching disk instead of pretending success, and always decodes at `.full` quality (never the preview cache). `ImageRenderService.writeExport(...)` writes through `CGImageDestination` directly after a real round-trip test showed `CIContext`'s `...Representation` convenience methods silently drop arbitrary ImageIO metadata keys. Mac `ExportSheet` exposes format/quality/bit-depth/max-width/max-height/DPI/EXIF-retention controls.

## Automated verification

### Focused tests per task

| Task | Suites | Result | Evidence |
|---|---|---|---|
| 1 | `EditorMetadataSnapshotTests`, `InspectorMetadataContractTests`, `RawMetadataTests` | PASS | 14 executed, 0 failures |
| 2 | `EditorSessionHistogramTests`, `HistogramComputerTests`, `InspectorHistogramContractTests` | PASS | 9 executed, 0 failures |
| 3 | `AdjustmentCatalogTests`, `AdjustmentGroupPanelsContractTests`, `BasicAdjustmentPanelModelTests`, `EditorSessionDocumentPersistenceTests`, `EditorSessionEditingTests`, `InspectorAdjustmentGroupsContractTests` | PASS | 31 executed, 0 failures |
| 4 | `ExportFormatTests`, `ExportResizingTests`, `ExifRetentionPolicyTests`, `ExportMetadataBuilderTests`, `PhotoExportTests`, `ExportSheetContractTests` | PASS | 66 executed, 0 failures |

### Full-phase gates

| Gate | Result | Evidence |
|---|---|---|
| `swift test` (full suite) | PASS | 1212 executed, 9 skipped, 0 failures |
| — skipped tests identity | as expected | all 9 skips are `LumaHarborIntegrationTests.RawFixtureTests` (`testEveryFixtureDecodes`, `testExportingNeverModifiesTheOriginal`, `testFullDecodeReturnsNativeResolution`, `testFullResolutionExportMatchesTheSourceDimensions`, `testInteractivePreviewLatencyForARealPhoto`, `testPreviewDecodeHonoursTheRequestedSize`, `testPreviewSchedulerDeliversARenderedFrameForARealRaw`, `testSonyArwReportsPlausibleMetadata`, `testWhiteBalanceOffsetChangesTheRender`) — all skip with "Set `LUMAHARBOR_RAW_FIXTURE_DIR` to a folder of camera RAW files to run the fixture suite," the same fixture-dependent baseline every prior round on this branch reported, unchanged by this phase |
| `git diff --check` (working tree) | PASS | no output |
| `git diff --check` (full range `8a400ed..HEAD`) | PASS with a pre-existing note | flags trailing-whitespace and blank-line-at-EOF in `docs/superpowers/plans/2026-09-02-awayphotoraweditor-parity-roadmap.md` and `...-phase1.md` — both from `a8c1c2c`, a docs-only commit that predates Task 1 and was authored before this round started; the trailing double-spaces are intentional Markdown hard-line-break syntax in that file's own header block, not a defect this phase introduced. No Task 1–4 source or test file has a `git diff --check` finding. |
| Privacy scan (`rg -n "/Users/\|/Volumes/\|/private/\|7KM4ZM25P3\|teamIdentifier:\|DEVELOPMENT_TEAM"` over `git diff 8a400ed..HEAD`) | PASS | every hit is either (a) this exact `rg` pattern string quoted inside this phase's own `CURRENT.md` prose (i.e. the scan finding itself, not a leaked path), (b) the worktree's own already-public path (`/Users/private-builder/Documents/ChatGPT/LumaHarbor/codex-awayphotoraweditor-parity-phase1`), which the user supplies in-band in every task prompt and which Codex's own pre-existing `CURRENT.md`/roadmap entries already used before this round, or (c) `/private/tmp/...DerivedData` build output paths from this round's own `xcodebuild` commands. Zero hits for the strict signing/device-only patterns (`7KM4ZM25P3`, `teamIdentifier:`, `DEVELOPMENT_TEAM`) or for any real `/Volumes/` mount path — checked separately and confirmed empty. |
| Mac app build (`swift build`) | PASS | `Build complete!` |
| iOS generic build (`xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/LumaHarbor-Phase1Task5-DerivedData CODE_SIGNING_ALLOWED=NO build`) | PASS | `** BUILD SUCCEEDED **`; run because Tasks 3–4 added public API to the shared `EditorCore`/`AdjustmentUI`/`RawProcessingCore` targets the iPad `.swiftpm` package also depends on, even though no iPad UI file references any of the new export/adjustment-panel API directly (confirmed via `rg` before running, so this is belt-and-suspenders, not closing a real usage gap) |
| Strict-concurrency build (`swift build --build-path <isolated dir> -Xswiftc -strict-concurrency=complete`) — **not required by this task's own plan, run as extra diligence** given Task 3/4 added a new actor (`PhotoExporter`) and several `Sendable` closures | PASS with 2 non-blocking warnings | `Build complete!` (isolated build directory used to force a genuine full recompile, not a cache hit). Two warnings, both in files this phase introduced and neither blocking the build: `Sources/EditorCore/EditorMetadataSnapshot.swift:86` (`byteCountFormatter` static let of non-`Sendable` `ByteCountFormatter`, Task 1) and `Sources/AdjustmentUI/AdjustmentSliderRow.swift:27` (a `Slider`'s `set:` closure converted to a `@Sendable` function type, Task 3). Neither is a new pattern this codebase hasn't already accepted elsewhere under this same build mode; not fixed in this verification-only round — flagged here as a follow-up rather than silently left off the record. |
| Local signing/project file | untouched | `Apps/LumaHarborPad.xcodeproj/project.pbxproj` never appeared in `git status` at any point this round; nothing was preserved-but-uncommitted |

## Not run

- **Every real-device/Simulator manual check for Tasks 1–4.** No device or Simulator was available in this environment. This specifically covers: seeing the metadata/EXIF panel, histogram, and the five grouped adjustment panels actually render correctly on screen; exercising the export sheet's format/quality/bit-depth/resize/DPI/EXIF controls by hand; confirming an exported JPEG/PNG/TIFF/HEIC file opens correctly in another app; and confirming the RAW original's checksum is unchanged after a real export on hardware (the automated `PhotoExportTests`/`RawFixtureTests` cover this synthetically and via fixture-gated tests respectively, not on a physical device).
- **`LumaHarborIntegrationTests.RawFixtureTests`** (9 tests, listed above) — `SKIPPED`, not `NOT RUN`: this is the existing, unchanged fixture-dependent baseline (requires `LUMAHARBOR_RAW_FIXTURE_DIR`, and this environment has no real camera RAW fixtures to point it at).
- **Precision/keyboard-adjustable slider input** (Task 3) — every adjustment row, old and new, still uses a plain `Slider` with no text-field precision entry; recorded as a scope decision in Task 3's own `CURRENT.md` evidence, repeated here for completeness.
- **An interactive curve-graph editor for `AdvancedToneCurve`** (Task 3) — this phase only exposes curve identity status and a Reset button.
- **Batch export, rename templates, watermarking, non-sRGB color space** (Task 4) — explicitly out of scope for this task per the plan.

## Independent review

No second agent has independently reviewed this phase's diff (`8a400ed..HEAD`) from a fresh session with no prior context. Per the plan's own Task 5 step ("ask for independent review before landing") and this repo's established practice (see `docs/coordination/CURRENT.md`'s prior "Claude independently reviewed..." entries for precedent), this phase should not be treated as ready to merge until that happens. Suggested focus areas for that review:

- whether `ExifRetentionPolicy.partial`'s specific choice of fields to strip (capture date, camera make/model, lens model — keeping ISO/shutter/aperture/focal length/orientation) is the right reading of the design spec's undefined "partial" EXIF policy, given `RawMetadata` has no GPS field to strip instead;
- whether routing DPI/EXIF through `CGImageDestination` directly (rather than `CIContext`'s `...Representation` methods, which were confirmed by hand to drop this metadata silently) has any subtle interaction with color management or orientation handling that the current `PhotoExportTests` round-trip assertions don't cover;
- whether the two new strict-concurrency warnings above are worth fixing now or genuinely benign given how the affected values are actually used (`byteCountFormatter` only ever read on the main actor via SwiftUI; the `Slider` binding only ever invoked from the main-actor view body);
- whether `MacExportOptions`/`ExportSheet`'s UI choices (which options are grouped, what "(Not Supported)" looks like, the EXIF picker's three-way label wording) match the design spec's intent well enough to ship as a first version, independent of the automated source-contract tests already passing.

## Landing readiness

Not landed, merged, rebased, or pushed. `codex/awayphotoraweditor-parity-phase1` remains a separate branch/worktree at `/Users/private-builder/Documents/ChatGPT/LumaHarbor/codex-awayphotoraweditor-parity-phase1`, unpushed, with no signing/local-project setting committed. Recommended next step: independent review (see above), then either continue to Phase 2 (`docs/superpowers/plans/2026-09-02-awayphotoraweditor-parity-roadmap.md`) or land this phase per the user's own merge process.
