# Brush preview performance fix handoff

## Status

`DONE_WITH_CONCERNS`

原驗收矩陣的 7 個效能 FAIL 已完成程式修正與自動驗收。`PERF-COVERAGE` 已由 NOT RUN 解除為 B/O 共同 stage clock 的 4/4 PASS。Gemini 唯讀審查的唯一 minor 已由 Sol 完成 128×128 tile 對齊與全套回歸；Mac 前景可執行 slice 已補跑，但實體裝置、輸入、heartbeat、灰卡與部分人工競態仍未完成，因此保留 `DONE_WITH_CONCERNS`。

## Git state

- Writer：Luna；128×128 follow-up：Sol；worktree owner：本 task 的 Codex workspace。
- Branch：`luna/brush-preview-performance-fix`。
- Validated product／harness HEAD：`7af212512f59768801081765808202fe84a85b25`。
- Base：`origin/main`=`82542e73aae8f16b0ba7e4d9d36a8a42451a7319`。
- Baseline B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`。
- 延續候選父版本：`eae30121ec7ef089b4a048a50151993c205e2686`；這是本 task 的相依例外，不表示已整合到 `main`。
- Branch 已推送至 `origin/luna/brush-preview-performance-fix`；Draft PR [#2](https://github.com/unizalin/LumaHarbor/pull/2) 為 OPEN／CLEAN，GitHub 未回報 checks。遠端 `main` 尚未變動；沒有 merge 或 rebase，不得覆蓋其他 worktree。

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
- 同一批 16 筆兩輪樣本的端到端 `totalDurationSeconds` 合併 p50/p95 為 1 mask `12.084/13.337 ms`、10 masks `70.779/81.143 ms`；這包含 shared stage clock 外的 harness 邊界開銷，不等同 total materialized。
- decode、global graph 與 per-mask adjustment/blend 均是次要 stage；RAW warm 的 cache 修正則把 0／1／10 masks 降到 O `36.285/39.805`、`39.560/49.993`、`56.002/61.015 ms`。

## Verification

- Synthetic stress：64 records，validation PASS；1 mask O round 1／2=`12.105/13.244`、`12.067/13.337 ms`，10 masks=`70.907/81.143`、`70.099/71.513 ms`；`PERF-COVERAGE` 4/4 PASS；preview memory 4/4 PASS。
- RAW／export：352 records，validation PASS；warm `INTERACTIVE-150` 3/3 PASS；preview memory 9/9 PASS；original-size export 4/4 PASS；export memory 4/4 PASS。
- Pixel parity／scalar oracle：PASS，max R8 byte error 0。
- 128×128 acceptance contract：預期 RED 後 GREEN；focused Release 31 tests、0 failures。
- Analyzer unit tests：9/9 PASS。
- 50-cycle scheduler：55/55 workers finished、active after join 0、B delivered 55、A discarded 55、failed 0；settled RSS `49,168,384` bytes，limit `89,735,168` bytes。
- Full Release suite：2715 tests、22 skipped、0 failures。
- Mac Debug 前景：`UI-MAC-01` PASS；`UI-MAC-02`、`UI-BRUSH-01`、`UI-BRUSH-02`、`STORE-01` PARTIAL。paint／erase、兩支筆刷切換、size／feather／flow／density、enable/select、單筆畫 Undo/Redo、autosave、close-to-library／reopen 與 4000×6000 16-bit TIFF export 通過。完整紀錄見 [Mac UI summary](../testing/evidence/2026-10-07-brush-preview-performance-fix/mac-ui-manual-summary.txt)。
- Artifact checksums：見 `docs/testing/evidence/2026-10-07-brush-preview-performance-fix/README.md`。

## Independent review

程式／spec 的 agy → Gemini 3.1 Pro High sanitized read-only review 為 `APPROVED_WITH_CONCERNS`，無 blocking finding。唯一 minor 是 spec 指定第一版固定 128×128 tile，但審查當時實作為 256×256；`7af2125` 已修正並重跑 parity、synthetic stress、RSS、cancellation、RAW/export 與 full Release gates，全數 PASS。完整紀錄見 [程式／spec Gemini review](../testing/reports/2026-10-08-brush-preview-performance-fix-gemini-review.md)。

Mac 文件差異的 Gemini 初審為 `CHANGES_REQUESTED`：`CURRENT.md` 引用兩輪合併的端到端 p50/p95，卻沒有在證據與報告中說明它不同於 stage total。本輪已從 `synthetic-stress-samples.jsonl` 重算並補上兩組數據的來源與邊界；同一模型 follow-up verdict=`APPROVED`、無 finding，並確認沒有 overclaim 或隱私洩漏。完整紀錄見 [Mac 文件 Gemini review](../testing/reports/2026-10-08-brush-preview-performance-fix-mac-ui-gemini-review.md)。

## Remaining bounded action

產品、自動驗收、兩輪獨立唯讀 review 與目前可執行的 Mac 前景 slice 已收尾，並已建立 Draft PR #2 保存整合候選。下一個 bounded action 是裝置恢復可用時執行實體 iPad／Pencil／鍵盤／VoiceOver／旋轉／Split View，具備 heartbeat recorder 與合格色卡後補 `PERF-UI` 30 次 B/O 手勢及灰卡矩陣，再補 Mac 的四色滴管方向、中途手勢競態與破壞性 Delete 操作。必要 gate 未完成前維持 Draft；不要修改門檻或 benchmark。未經使用者另行授權，不 merge、rebase、刪除 branch/worktree 或修改其他 worktree。
