# Brush preview performance fix handoff

## Status

`DONE_WITH_CONCERNS`

原驗收矩陣的 7 個效能 FAIL 已完成程式修正與自動驗收。`PERF-COVERAGE` 已由 NOT RUN 解除為 B/O 共同 stage clock 的 4/4 PASS。Gemini 唯讀審查的唯一 minor 已由 Sol 完成 128×128 tile 對齊與全套回歸；UI 與實體裝置人工 gate 尚未執行，因此保留 `DONE_WITH_CONCERNS`。

## Git state

- Writer：Luna；128×128 follow-up：Sol；worktree owner：本 task 的 Codex workspace。
- Branch：`luna/brush-preview-performance-fix`。
- Validated product／harness HEAD：`7af212512f59768801081765808202fe84a85b25`。
- Base：`origin/main`=`82542e73aae8f16b0ba7e4d9d36a8a42451a7319`。
- Baseline B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`。
- 延續候選父版本：`eae30121ec7ef089b4a048a50151993c205e2686`；這是本 task 的相依例外，不表示已整合到 `main`。
- 沒有 push、merge 或 rebase；不得覆蓋其他 worktree。

## Changes

產品 commits：

- `b640823` — stage instrumentation、bounded decoded-preview cache 與 exact invalidation key。
- `26e7358` — bounded tile raster、repeated-geometry coverage reuse、bounded mask fan-out、cancellation join 與 scalar oracle。
- `f97760a` — B/O 共享 stage coverage gate、baseline test-only stage observer 與完整 stage schema。
- `f13de10` — 以當時 candidate SHA 保存 synthetic／RAW/export evidence 與文件。
- `462b30a` — 保存 agy → Gemini 3.1 Pro High 唯讀審查報告。
- `7af2125` — 將 coverage tile 對齊固定 128×128，並加入 acceptance contract。

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
- `Tests/RawProcessingCoreTests/BrushMaskRendererTests.swift`

設計保證：mask 順序、paint／erase 語意、geometry mapping、不同 mask adjustment、overlap、像素精度與 cancellation checkpoints 保持；沒有降低解析度、刪除筆刷點、跳過調整或放寬 benchmark 門檻。Cache 不跨照片、recipe 或 render context 誤用，且 full-resolution export 不共用 interactive decoded cache。

## Root cause and stage evidence

Shared B/O stage wall time（synthetic stress aggregate p50/p95，ms）：

- 1 mask：B coverage `175.096/192.717`，O `8.801/10.111`；O total materialized `11.988/13.210`。
- 10 masks：B coverage `1754.617/1814.902`，O `64.776/74.801`；O total materialized `70.664/81.013`。
- decode、global graph 與 per-mask adjustment/blend 均是次要 stage；RAW warm 的 cache 修正則把 0／1／10 masks 降到 O `36.285/39.805`、`39.560/49.993`、`56.002/61.015 ms`。

## Verification

- Synthetic stress：64 records，validation PASS；1 mask O round 1／2=`12.105/13.244`、`12.067/13.337 ms`，10 masks=`70.907/81.143`、`70.099/71.513 ms`；`PERF-COVERAGE` 4/4 PASS；preview memory 4/4 PASS。
- RAW／export：352 records，validation PASS；warm `INTERACTIVE-150` 3/3 PASS；preview memory 9/9 PASS；original-size export 4/4 PASS；export memory 4/4 PASS。
- Pixel parity／scalar oracle：PASS，max R8 byte error 0。
- 128×128 acceptance contract：預期 RED 後 GREEN；focused Release 31 tests、0 failures。
- Analyzer unit tests：9/9 PASS。
- 50-cycle scheduler：55/55 workers finished、active after join 0、B delivered 55、A discarded 55、failed 0；settled RSS `49,168,384` bytes，limit `89,735,168` bytes。
- Full Release suite：2715 tests、22 skipped、0 failures。
- Artifact checksums：見 `docs/testing/evidence/2026-10-07-brush-preview-performance-fix/README.md`。

## Independent review

agy → Gemini 3.1 Pro High 已完成 sanitized read-only review，Verdict=`APPROVED_WITH_CONCERNS`，無 blocking finding。唯一 minor 是 spec 指定第一版固定 128×128 tile，但審查當時實作為 256×256；`7af2125` 已修正並重跑 parity、synthetic stress、RSS、cancellation、RAW/export 與 full Release gates，全數 PASS。完整審查與解決紀錄見 [Gemini review](../testing/reports/2026-10-08-brush-preview-performance-fix-gemini-review.md)。

## Remaining bounded action

產品、自動驗收與獨立唯讀審查已收尾。下一個 bounded action 是有設備時補 Mac 前景、實體 iPad／Pencil、VoiceOver、灰卡等人工 gate；若準備整合，先由非原作者唯讀檢查 `7af2125` 之後的文件差異，再依共用 Git 流程處理。不要修改門檻或 benchmark。未經使用者另行授權，不 push、merge、rebase、刪除 branch/worktree 或修改其他 worktree。
