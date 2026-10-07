# Brush preview performance fix handoff

## Status

`DONE_WITH_CONCERNS`

原驗收矩陣的 7 個效能 FAIL 已完成程式修正與自動驗收。`PERF-COVERAGE` 已由 NOT RUN 解除為 B/O 共同 stage clock 的 4/4 PASS。UI、實體裝置與獨立 reviewer 尚未執行，因此保留 `DONE_WITH_CONCERNS`。

## Git state

- Writer：Luna；worktree owner：本 task 的 Codex workspace。
- Branch：`luna/brush-preview-performance-fix`。
- Validated product／harness HEAD：`f13de103cec69002666bba389cbf9b6e39cee02f`。
- Base：`origin/main`=`82542e73aae8f16b0ba7e4d9d36a8a42451a7319`。
- Baseline B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`。
- 延續候選父版本：`eae30121ec7ef089b4a048a50151993c205e2686`；這是本 task 的相依例外，不表示已整合到 `main`。
- 沒有 push、merge 或 rebase；不得覆蓋其他 worktree。

## Changes

產品 commits：

- `b640823` — stage instrumentation、bounded decoded-preview cache 與 exact invalidation key。
- `26e7358` — bounded tile raster、repeated-geometry coverage reuse、bounded mask fan-out、cancellation join 與 scalar oracle。
- `f97760a` — B/O 共享 stage coverage gate、baseline test-only stage observer 與完整 stage schema。
- `f13de10` — 以目前 candidate SHA 保存 synthetic／RAW/export evidence 與文件。

主要檔案：

- `Sources/RawProcessingCore/Preview/PreviewRenderInstrumentation.swift`
- `Sources/RawProcessingCore/Preview/DecodedPreviewCache.swift`
- `Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift`
- `Sources/RawProcessingCore/Pipeline/BrushMaskRenderer.swift`
- `Scripts/fixtures/brush-baseline-release-testability.patch`
- `Scripts/analyze-brush-performance-abba.py`
- `Tests/RawProcessingCoreTests/BrushPreviewABBAHarnessTests.swift`
- `Tests/RawProcessingCoreTests/CoreImagePreviewRendererTests.swift`
- `Tests/RawProcessingCoreTests/BrushMaskScalarOracleTests.swift`

設計保證：mask 順序、paint／erase 語意、geometry mapping、不同 mask adjustment、overlap、像素精度與 cancellation checkpoints 保持；沒有降低解析度、刪除筆刷點、跳過調整或放寬 benchmark 門檻。Cache 不跨照片、recipe 或 render context 誤用，且 full-resolution export 不共用 interactive decoded cache。

## Root cause and stage evidence

Shared B/O stage wall time（synthetic stress aggregate p50/p95，ms）：

- 1 mask：B coverage `173.879/176.316`，O `8.871/10.395`；O total materialized `11.922/13.319`。
- 10 masks：B coverage `1736.591/1755.055`，O `62.821/65.111`；O total materialized `68.609/71.059`。
- decode、global graph 與 per-mask adjustment/blend 均是次要 stage；RAW warm 的 cache 修正則把 0／1／10 masks 降到 O `34.636/39.790`、`37.048/42.379`、`55.097/67.036 ms`。

## Verification

- Synthetic stress：64 records，validation PASS；1 mask O round 1／2=`11.998/13.402`、`12.070/12.338 ms`，10 masks=`68.867/71.171`、`68.282/69.940 ms`；`PERF-COVERAGE` 4/4 PASS；preview memory 4/4 PASS。
- RAW／export：352 records，validation PASS；warm `INTERACTIVE-150` 3/3 PASS；preview memory 9/9 PASS；original-size export 4/4 PASS；export memory 4/4 PASS。
- Pixel parity／scalar oracle：PASS，max R8 byte error 0。
- Focused Release：30 tests、0 failures。
- Analyzer unit tests：9/9 PASS。
- 50-cycle scheduler：55/55 workers finished、active after join 0、B delivered 55、A discarded 55、failed 0；settled RSS `58,605,568` bytes，limit `90,849,280` bytes。
- Full Release suite：2714 tests、22 skipped、0 failures。
- Artifact checksums：見 `docs/testing/evidence/2026-10-07-brush-preview-performance-fix/README.md`。

## Remaining bounded action

只需另一個帳號做唯讀 code／spec review；有設備時補 Mac 前景、實體 iPad／Pencil、VoiceOver、灰卡等人工 gate。不要再修改門檻或 benchmark。未經使用者另行授權，不 push、merge、rebase、刪除 branch/worktree 或修改其他 worktree。
