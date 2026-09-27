# Lightroom Gate 2 Production Hardening Handoff

## Status

`DONE_WITH_CONCERNS`

## Git state

- Writing agent: Codex；worktree owner: `codex/lr-neutral-baseline-v1`。
- Source branch: `codex/lr-neutral-baseline-v1`。
- HEAD: `fb421507bfeed1b2ff146109e3540d91de0eba62`。
- Base: local `main` at `781268329` (full base SHA is available from the local ref); `main...HEAD` is ahead 31, behind 0。
- Local `origin/main` comparison: ahead 39, behind 0；branch 沒有 upstream。
- Scope: task-scoped preserved snapshot。Sol 留下的 dirty files 是既有證據與實作輸入；本輪不得覆蓋、回復或刪除。
- Push、merge、rebase、commit：均未發生；`main` 未修改。

## Changes

- P0：完成 evidence freeze、ownership 與 `CURRENT.md`／report 對齊，新增本交接文件。
- P1：`ResolvedRawRenderRecipe` 在 effective native 時正規化所有 derived execution state；persisted Adobe intent 保留。
- P2：artifact manifest 綁定係數 digest、decoder identifier/version、option vector、工作色域、輸出轉換與 provenance schema；runtime mismatch fail closed；production registry 仍為空。
- P3：comparator 改用 bounded histogram／累加器與無暫存陣列 SSIM；CLI 支援 atomic `--report`，並以 process-level test 驗證清理後 JSON。
- P4：完成完整測試、strict-concurrency build、macOS app bundle、iPad generic Simulator、公開矩陣 validator、diff/privacy gates。
- Sol 原有 dirty files 保留，包含 comparator、16-bit buffer、metadata validator、profile manifest、controlled enablement tests、公開 contract tests 與相關文件；完整清單見下節。

## Verification

- focused regression（最後重跑）：`swift test --filter 'ControlledRendererEnablementTests|ProfileCalibrationArtifactManifestTests|ReferenceComparisonMetricsTests|ReferenceCompareProcessTests'`，22 executed、0 skipped、0 failures。
- 完整 `swift test`：2477 executed、14 skipped、0 failures。
- `swift build -Xswiftc -strict-concurrency=complete`、`Scripts/build-app-bundle.sh debug`、iPad generic Simulator `xcodebuild`：均 PASS。
- 公開矩陣 validator：schema v2、20 cases、80 references PASS；`git diff --check` 與本輪新增文件 privacy scan PASS。
- Lightroom Gate 2 4/4、hold-out、performance、Mac/iPad pixel parity、實體 iPad：`NOT RUN`／`BLOCKED`，因缺真實 paired Lightroom TIFF 與可用實體裝置。

## Dirty files

以下均是 Sol 既有或 Sol 產出的 preserved dirty files；本輪接手後可在不覆蓋既有內容的前提下，以小範圍 append/patch 方式修改與驗證：

```text
Scripts/validate-lr-reference-matrix.zsh
Sources/EditorCore/RawRenderDiagnosticsPresentation.swift
Sources/LumaHarborReferenceCompare/main.swift
Sources/RawProcessingCore/Decoding/CoreImageRawDecoder.swift
Sources/RawProcessingCore/Decoding/RawRenderRecipe.swift
Sources/RawProcessingCore/Decoding/RawRenderRecipeResolver.swift
Sources/RawProcessingCore/Diagnostics/LightroomReferenceThresholds.swift
Sources/RawProcessingCore/Diagnostics/ReferenceComparisonMetrics.swift
Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift
Sources/RawProcessingCore/Profile/CameraProfileFallback.swift
Tests/EditorCoreTests/EditorSessionPasteAdjustmentsTests.swift
Tests/LumaHarborAppTests/LightroomReferenceMatrixContractTests.swift
Tests/LumaHarborAppTests/RawRenderDiagnosticsContractTests.swift
Tests/LumaHarborAppTests/ReferenceCompareCommandContractTests.swift
Tests/RawProcessingCoreTests/BatchExportQueueTests.swift
Tests/RawProcessingCoreTests/CameraProfileRendererTests.swift
Tests/RawProcessingCoreTests/CoreImageRawDecoderPrivateFixtureTests.swift
Tests/RawProcessingCoreTests/ImageRenderServiceColorSpaceTests.swift
Tests/RawProcessingCoreTests/PreviewExportRecipeParityTests.swift
Tests/RawProcessingCoreTests/RawRenderRecipeResolverTests.swift
Tests/RawProcessingCoreTests/ReferenceComparisonMetricsTests.swift
docs/coordination/CURRENT.md
docs/testing/lightroom-xmp-reference-matrix.md
docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md
docs/testing/templates/lightroom-xmp-reference-matrix.json
Sources/RawProcessingCore/Diagnostics/ReferenceImageBuffer.swift
Sources/RawProcessingCore/Diagnostics/ReferenceImageMetadataValidator.swift
Sources/RawProcessingCore/Profile/Generated/ProfileCalibrationArtifactManifestsV1.swift
Sources/RawProcessingCore/Profile/ProfileCalibrationArtifactManifest.swift
Tests/LumaHarborAppTests/ReferenceCompareProcessTests.swift
Tests/RawProcessingCoreTests/ControlledRendererEnablementTests.swift
Tests/RawProcessingCoreTests/ProfileCalibrationArtifactManifestTests.swift
Tests/RawProcessingCoreTests/ReferenceImageBufferTests.swift
Tests/RawProcessingCoreTests/ReferenceImageMetadataValidatorTests.swift
docs/superpowers/plans/2026-09-21-lightroom-gate2-calibration-and-controlled-enablement.md
docs/superpowers/specs/2026-09-21-lightroom-gate2-calibration-and-controlled-enablement.md
docs/superpowers/specs/2026-09-21-lightroom-gate2-production-hardening-and-reference-admission.md
```

## Concerns and blockers

- Gate 2 4/4 cannot be declared without four paired Lightroom 16-bit sRGB TIFF references from the same RAW inputs.
- Production Adobe registry must remain empty until training and hold-out evidence, artifact binding, performance, and cross-platform checks are complete; the generated registry is intentionally empty.
- P1-P3 hardening is implemented and tested, but it does not constitute Lightroom pixel parity or production admission; the remaining admission gates are still blocked.
- No private RAW, XMP, TIFF, hash, filename, or absolute path may enter Git.

## Next action

P1-P4 are implemented and verified. The next bounded action is to receive four paired Lightroom 16-bit TIFF references in an untracked private directory, run `LumaHarborReferenceCompare --all-neutral --report`, then execute the formal 4/4 and hold-out admission gates. Until that evidence exists, do not alter the fail-closed default, populate the production registry, commit, push, merge, rebase, or modify `main`.

## Execution start update (2026-09-22)

- Baseline rechecked at `fb421507bfeed1b2ff146109e3540d91de0eba62`; existing dirty files remain preserved.
- Adobe feature flag default is false; generated profile fallback and calibration registries remain empty.
- The private source corpus currently has five ARW inputs and five XMP inputs, but no paired Lightroom/LumaHarborPad TIFF references. This is an input fact only and is not copied into tracked reports with private names or paths.
- The implementation plan now includes a reference-generation stage before metadata admission. Formal neutral 4/4, hold-out, performance, Mac/iPad parity and physical iPad remain `NOT RUN`.

## Execution update (2026-09-22)

- Task 1 process hardening and Task 2 tiled metrics are GREEN.
- Synthetic full-resolution performance gate passed with peak RSS below 1.5 GB; the measurement was generated in a temporary directory and is not part of the evidence corpus.
- Export contracts pass, but no paired Lightroom/LumaHarborPad neutral TIFFs or hold-out are available. Formal 4/4, calibration, controlled enablement, and physical iPad acceptance remain `NOT RUN`.
- Keep Adobe feature flag disabled and production registries empty.

## Final verification update (2026-09-22)

- Full `swift test` is green: 2488 executed, 15 skipped, 0 failures. The only intermediate failure was an obsolete source-string assertion expecting the pre-streaming loader; it was updated to assert `ReferenceImageTileReader` and `compareStreaming`, then the full suite passed.
- Task 1 process hardening and Task 2 tiled metrics are green. The synthetic 6000x4000 performance process gate passed with peak RSS `904167424` bytes and aggregate wall time approximately 331 seconds.
- Export preflight is green (50 `PhotoExportTests` + 4 `PadExportOptionsTests`). This does not substitute for real paired Lightroom/LumaHarborPad TIFFs.
- Strict-concurrency build, macOS app bundle, iPad generic Simulator build, `git diff --check`, and changed-diff privacy scan are PASS.
- Formal Lightroom 4/4, XMP target, hold-out, production registry admission, Mac/iPad pixel parity, and physical iPad acceptance remain `NOT RUN`. Final decision is **READY ONLY WITH RENDERER DISABLED**.
- A paired iPad is available, but the current device build is blocked by the project signing requirement for a development team. No app was installed and no real-device RAW/XMP result was inferred; signing identity remains untouched.

## Suggested skills

- `test-driven-development`
- `verification-before-completion`
- `lumaharbor-lightroom-safe-landing`

## Layer-isolation continuation（2026-09-22）

- Corrected 16-bit references were available privately and formal neutral 4/4 was executed; all four cases failed the admission thresholds. A fifth, disjoint hold-out was also executed and failed.
- Decoder ablation showed that the previous all-zero Adobe option vector overwrote valid per-RAW Core Image defaults and caused a severe regression. The v1 vector now preserves decoder defaults and uses a new version ID; private decoder pixel parity is 5/5 against Native.
- Working-space-only ablation produced negligible mixed changes. A runtime-domain linear Display P3 3×3 matrix improved training RMSE by only about 2.2%, failed formal 4/4, and worsened hold-out clipping, so no artifact was admitted.
- Calibration samples now require an explicit `linear-display-p3-v1` domain. Legacy/missing-domain and encoded-sRGB samples fail closed before fitting.
- Renderer state is unchanged: feature flag off, both production registries empty, XMP target validation and physical iPad acceptance not run. Decision remains **READY ONLY WITH RENDERER DISABLED**.

## Layer-isolation verification closeout（2026-09-22）

- Focused calibration/domain/artifact tests: 12/12 PASS. Private RAW fail-closed/preserve-defaults tests: 3/3 PASS. Private XMP fixture tests: 5/5 PASS.
- Full `swift test`: 2496 executed, 17 skipped, 0 failures. Strict-concurrency build, macOS app bundle, iPad generic Simulator, public matrix validator, diff check and changed-diff privacy scan all PASS.
- Formal neutral 4/4 and the disjoint hold-out remain FAIL, so Task 6 was not entered and physical iPad acceptance remains `NOT RUN` by design.
- No commit, push, merge, rebase, reset, stash or `main` modification occurred. Production feature flag and registries remain fail closed/empty.
