# Brush preview performance fix handoff

## Status

`DONE_WITH_CONCERNS`

## Git state

- Writer：Luna；worktree owner：本 task 的 Codex workspace。
- Branch：`luna/brush-preview-performance-fix`。
- Validated product HEAD：`26e7358fcf5019b246588d1bb3baa8a6005548cd`。
- Base branch：`origin/main`；base SHA：`82542e73aae8f16b0ba7e4d9d36a8a42451a7319`。
- 使用者已授權延續的候選父版本：`eae30121ec7ef089b4a048a50151993c205e2686`；這是本 task 的相依例外，不代表它已整合到 `main`。
- 相對 `origin/main`：ahead 53、behind 0；沒有 upstream。
- Branch 是 task-scoped worktree；沒有 push、merge 或 rebase。

## Changes

產品 commits：

- `b640823` — `perf: instrument preview stages and cache decoded previews`
- `26e7358` — `perf: reduce repeated brush coverage work`

主要變更檔案：

- `Sources/RawProcessingCore/Preview/PreviewRenderInstrumentation.swift`
- `Sources/RawProcessingCore/Preview/DecodedPreviewCache.swift`
- `Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift`
- `Sources/RawProcessingCore/Pipeline/BrushMaskRenderer.swift`
- `Scripts/run-brush-performance-abba.sh`
- `Tests/RawProcessingCoreTests/BrushPreviewABBAHarnessTests.swift`
- `Tests/RawProcessingCoreTests/CoreImagePreviewRendererTests.swift`
- `Tests/RawProcessingCoreTests/BrushMaskScalarOracleTests.swift`

驗收／交接文件與去識別化 artifact：

- `docs/testing/reports/2026-10-07-brush-preview-performance-fix.md`
- `docs/testing/evidence/2026-10-07-brush-preview-performance-fix/`
- `docs/coordination/CURRENT.md`
- `docs/coordination/2026-10-07-brush-preview-performance-fix-handoff.md`

## Verification

- Synthetic stress ABBA：64 records，validation PASS；1 mask O p50/p95 `12.293/12.624 ms`，10 masks `96.121/141.143 ms`，四個 performance gate PASS，四個 preview memory gate PASS。
- RAW／export ABBA：352 records，validation PASS；warm 0/1/10 masks `35.400/40.244`、`38.049/44.368`、`56.828/58.630 ms`，均 PASS；export 4/4 與 export memory 4/4 PASS。
- Focused Release：30 tests、0 failures；cancellation 9/9、renderer 9/9、scalar oracle 5/5、preview renderer 7/7。
- Full Release suite：2714 tests、22 skipped、0 failures。
- 50-cycle scheduler：PASS；55 started／55 finished、active after join 0、55 B delivered、55 A discarded、failed 0；settled RSS 58,605,568 bytes，limit 90,816,512 bytes。
- Normal opt-in workload：PASS；5 samples、0／1／10 masks。
- Stage instrumentation：candidate O-only diagnostic PASS；`PERF-COVERAGE` `NOT RUN`，因 B/O 沒有共同 stage clock。
- `git diff --check` 與公開 artifact 私密路徑掃描：PASS（文件 commit 前完成）。

詳細數據、命令與 checksum：[2026-10-07 brush preview performance fix report](../testing/reports/2026-10-07-brush-preview-performance-fix.md)。

## Dirty files

目前文件仍在本次 coordination commit 前的工作狀態；所有 dirty files 都由本 task writer 產生，沒有其他代理或使用者的 dirty path。完成文件 commit 後應為 clean。

## Concerns and blockers

- `PERF-COVERAGE` 維持 `NOT RUN`：baseline B 使用 legacy renderer，沒有與 O 相同且互斥的 stage wall-time observer。要清除這個限制，必須在不改產品 math／benchmark 門檻下補共同 test-only clock 並重新跑 B/O。
- 真實 RAW harness 的 warm timing 是完整 render wall time，未把每個 RAW stage 分開；不能從總時間反推 decode、adjustment 或 materialization 的單獨成本。
- Mac 前景、實體 iPad、Pencil、VoiceOver、灰卡與獨立 reviewer 本輪未執行，仍是 `NOT RUN`。

## Next action

請下一個帳號以本 branch 的產品 SHA、報告與 evidence 做唯讀 review；若 review 要解除 `PERF-COVERAGE`，只新增 B/O 共用 stage clock、重跑 ABBA 並更新報告，維持現有門檻與像素／取消契約。不要 push、merge、rebase、刪除 branch/worktree，亦不要修改其他 worktree。
