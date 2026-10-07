# LumaHarbor 筆刷預覽效能修正驗收報告

日期：2026-10-08（Asia/Taipei）

狀態：`DONE_WITH_CONCERNS`

本輪已處理原驗收矩陣中的 7 個效能 FAIL。剩餘問題集中為兩個根因：warm RAW 每次 render 重複 decode，以及筆刷 coverage 對每個 mask 做全圖 raster／合成。程式與自動驗收已完成；`DONE_WITH_CONCERNS` 僅保留 UI／實體裝置／獨立 reviewer 尚未執行的限制。

## 根因與分段數據

B/O 現在使用相同、互斥的 monotonic wall-time stage 邊界：RAW decode、global adjustment graph、validation/sampling、coverage raster、per-mask adjustment/blend、final `makeCGImage` materialization。平行 coverage worker 以 interval union 計算 wall time，不累加 CPU duration。Baseline 的 observer 是 test-only Release patch，不改 baseline production math。

Synthetic stress aggregate（兩輪合併，p50／p95，ms）：

| masks | variant | raw decode | global graph | validation/sampling | coverage raster | per-mask adjustment/blend | final materialization | stage total |
| ---: | :---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | B | 0.008 / 0.011 | 0.001 / 0.001 | 0.011 / 0.012 | 173.879 / 176.316 | 0.050 / 0.058 | 3.937 / 4.097 | 177.847 / 180.367 |
| 1 | O | 0.005 / 0.007 | 0.001 / 0.001 | 0.192 / 0.205 | 8.871 / 10.395 | 0.031 / 0.053 | 2.664 / 2.809 | 11.922 / 13.319 |
| 10 | B | 0.010 / 0.011 | 0.001 / 0.002 | 0.074 / 0.079 | 1736.591 / 1755.055 | 0.296 / 0.351 | 7.337 / 7.613 | 1744.289 / 1762.886 |
| 10 | O | 0.006 / 0.006 | 0.001 / 0.002 | 2.429 / 2.694 | 62.821 / 65.111 | 0.106 / 0.112 | 5.277 / 5.658 | 68.609 / 71.059 |

coverage raster 是 synthetic stress 的主要成本；RAW decode 與 per-mask adjustment/blend 不是主要瓶頸。RAW warm 測量則證實 decoded-preview cache 能移除重複 decode 的成本。

## 修改檔案與設計理由

- `Sources/RawProcessingCore/Preview/PreviewRenderInstrumentation.swift`：新增共享 stage model 與 interval-union collector。
- `Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift`：加入 decode、graph、validation、brush、materialization 分段計時；接入 bounded decoded-preview cache；取消後晚到結果不回填錯誤 context。
- `Sources/RawProcessingCore/Preview/DecodedPreviewCache.swift`：bounded LRU actor cache。key 綁定標準化 URL、檔案 size／mtime／generation、decode quality、decoder identifier、resolved RAW recipe、白平衡、lens correction、camera profile 與其他 decode inputs；interactive decode 與 full-resolution export 分離。
- `Sources/RawProcessingCore/Pipeline/BrushMaskRenderer.swift`：bounded tile scratch／concurrency、相同幾何 coverage reuse、最多兩個 active mask worker，並在 cancellation 後 join 所有已啟動 worker。保留 mask 順序、paint／erase、geometry mapping、不同 mask adjustment、overlap、像素精度與 cancellation checkpoints。
- `Scripts/fixtures/brush-baseline-release-testability.patch`：以同一 stage 邊界讓 baseline B 可觀測，僅供驗收 harness 使用。
- `Scripts/analyze-brush-performance-abba.py`：只有 B/O 七段欄位完整且有限時才產生 `PERF-COVERAGE`；不完整舊 artifact 仍 fail closed 為 `NOT RUN`。
- `Tests/RawProcessingCoreTests/BrushPreviewABBAHarnessTests.swift` 與 analyzer tests：記錄 B/O stage JSON 並驗證完整 coverage matrix。

沒有降低解析度、刪除筆刷點、跳過調整、改 benchmark workload 或放寬門檻。

## 修改前後效能

### Synthetic stress（1600×1067）

| workload | B p50 / p95 | O p50 / p95 | 門檻 | 結果 |
| --- | ---: | ---: | ---: | --- |
| 1 mask round 1 | 178.746 / 181.240 ms | 11.998 / 13.402 ms | 30 / 60 ms | PASS |
| 1 mask round 2 | 178.873 / 180.672 ms | 12.070 / 12.338 ms | 30 / 60 ms | PASS |
| 10 masks round 1 | 1746.476 / 1763.953 ms | 68.867 / 71.171 ms | 100 / 150 ms | PASS |
| 10 masks round 2 | 1745.098 / 1748.845 ms | 68.282 / 69.940 ms | 100 / 150 ms | PASS |

### RAW warm preview

| masks | B p50 / p95 | O p50 / p95 | 門檻 | 結果 |
| ---: | ---: | ---: | ---: | --- |
| 0 | 164.579 / 176.565 ms | 34.636 / 39.790 ms | 150 / 150 ms | PASS |
| 1 | 184.257 / 192.003 ms | 37.048 / 42.379 ms | 150 / 150 ms | PASS |
| 10 | 366.840 / 390.928 ms | 55.097 / 67.036 ms | 150 / 150 ms | PASS |

### Original-size export

`PERF-EXPORT` 4/4、`PERF-MEM-EXPORT` 4/4 PASS。O p50：synthetic 24MP 1／10 masks=`110.769/354.699 ms`；真實 RAW 1／10 masks=`421.932/549.644 ms`。

## Gate 狀態

| Gate／檢查 | 結果 |
| --- | --- |
| Synthetic stress performance | PASS，4/4 |
| Synthetic preview memory | PASS，4/4 |
| B/O `PERF-COVERAGE` | PASS，4/4；共同互斥 stage clock 已具備 |
| RAW warm `INTERACTIVE-150` | PASS，3/3 |
| RAW preview memory | PASS，9/9 |
| Original-size export | PASS，4/4 |
| Original-size export memory | PASS，4/4 |
| Pixel parity／scalar oracle | PASS，max R8 byte error 0 |
| Cancellation focused matrix | PASS，9/9 |
| 50-cycle worker convergence／RSS | PASS，55/55 joined，active 0 |
| Analyzer unit tests | PASS，9/9 |
| Focused Release tests | PASS，30/30 |
| Full Release regression | PASS，2714 tests、22 skipped、0 failures |
| UI／Mac 前景／實體 iPad／Pencil／VoiceOver／灰卡 | NOT RUN |

`PERF-COVERAGE` 不再是 NOT RUN；RAW/export harness 沒有把 stage coverage 反推成 gate，仍以其自身的 total wall-time、RSS 與 published-file checks 驗收。

## 可重現驗證

完整原始 artifact、環境、SHA、命令、exit code 與 checksum 見[證據目錄](../evidence/2026-10-07-brush-preview-performance-fix/README.md)。

## 尚未完成與 bounded next action

產品效能修正與自動驗收已完成。下一個帳號只需做一次唯讀 code／spec review，並在有設備時補 Mac 前景、實體 iPad／Pencil、VoiceOver、灰卡等人工 gate；不需再修改效能門檻或 benchmark。未經使用者另行授權，不 push、merge、rebase 或修改其他 worktree。
