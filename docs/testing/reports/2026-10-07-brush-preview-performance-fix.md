# LumaHarbor 筆刷預覽效能修正驗收報告

日期：2026-10-07（Asia/Taipei）

狀態：`DONE_WITH_CONCERNS`

本輪修正了剩餘的筆刷預覽效能 FAIL。必要的 synthetic stress、真實 RAW warm preview、original-size export、記憶體、取消與像素回歸均已通過；公平的 B/O stage coverage 因 baseline 沒有同一套 stage clock，依規則保持 `NOT RUN`。

## 根因與分段數據

先在候選版加入互斥 monotonic wall-time stage collector。平行 coverage worker 的區間以 union 計算，沒有把各 worker CPU duration 相加。Synthetic stress 的 O-only stage 數據顯示 coverage raster 是主要成本：

| masks | raw decode p50/p95 | global graph p50/p95 | validation/sampling p50/p95 | coverage raster p50/p95 | per-mask adjustment/blend p50/p95 | final materialization p50/p95 | total p50/p95 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.005 / 0.006 ms | 0.001 / 0.001 ms | 0.192 / 0.208 ms | 9.221 / 9.582 ms | 0.042 / 0.044 ms | 2.562 / 2.898 ms | 12.180 / 12.574 ms |
| 10 | 0.006 / 0.006 ms | 0.001 / 0.001 ms | 1.855 / 2.130 ms | 87.248 / 131.703 ms | 0.110 / 0.126 ms | 5.308 / 6.878 ms | 95.987 / 141.012 ms |

RAW warm 的 B/O harness 目前只保存 submit-through-materialized wall time，沒有同樣的 stage fields；因此不把 RAW O-only stage 推成正式 `PERF-COVERAGE` regression。RAW 結果仍直接驗證互動總時間與輸出尺寸／發布檔案契約。

## 修改內容與設計理由

- `Sources/RawProcessingCore/Preview/PreviewRenderInstrumentation.swift`：新增六段 stage model 與 interval-union collector，讓平行工作以 wall time 表示。
- `Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift`：記錄 decode、global graph、brush stages 與 `makeCGImage`；新增 decoded preview cache 接線及取消後的晚到結果隔離。
- `Sources/RawProcessingCore/Preview/DecodedPreviewCache.swift`：新增 bounded LRU actor cache。key 綁定標準化 URL、檔案 size／mtime／generation、decode quality、decoder identifier、white balance、lens correction、camera profile、compatibility 與 resolved recipe；只快取有界 interactive decode，full-resolution export 不共用此 cache。
- `Sources/RawProcessingCore/Pipeline/BrushMaskRenderer.swift`：coverage 改用 bounded tile scratch 與 bounded tile concurrency；相同幾何的 paint／erase stroke 在不改變 mask／stroke 順序下重用 coverage；active masks 使用 bounded dynamic task group，並在 cancellation 後 join 所有已啟動 worker。mask order、paint／erase、geometry、overlap、pixel precision 與 cancellation checkpoints 保留。
- `Scripts/run-brush-performance-abba.sh`：baseline 以 legacy instrumentation compile，避免共用 harness 的 candidate-only symbols 污染 B。
- `Tests/RawProcessingCoreTests/BrushMaskScalarOracleTests.swift`：加入 repeated-geometry paint／erase／paint 與獨立 scalar oracle 的 byte parity。
- `Tests/RawProcessingCoreTests/BrushPreviewABBAHarnessTests.swift`、`CoreImagePreviewRendererTests.swift`：加入 stage JSON 與 exact cache-key coverage。

這些修改對應兩個已確認的瓶頸：coverage raster 的全圖 per-mask 計算，以及 warm interactive RAW 重複 decode。沒有降低解析度、刪除筆刷點、跳過調整或放寬門檻。

## 修改前後效能

### Synthetic stress（1600×1067）

| workload | B p50 / p95 | O p50 / p95 | 門檻 | 結果 |
| --- | ---: | ---: | ---: | --- |
| 1 mask round 1 | 180.498 / 187.763 ms | 12.293 / 12.624 ms | 30 / 60 ms | PASS |
| 1 mask round 2 | 181.142 / 197.553 ms | 12.266 / 12.680 ms | 30 / 60 ms | PASS |
| 10 masks round 1 | 1761.336 / 1766.906 ms | 96.121 / 141.143 ms | 100 / 150 ms | PASS |
| 10 masks round 2 | 1762.654 / 1769.174 ms | 96.025 / 97.391 ms | 100 / 150 ms | PASS |

### RAW warm preview

| masks | B p50 / p95 | O p50 / p95 | 門檻 | 結果 |
| ---: | ---: | ---: | ---: | --- |
| 0 | 170.456 / 183.210 ms | 35.400 / 40.244 ms | 150 / 150 ms | PASS |
| 1 | 188.495 / 201.920 ms | 38.049 / 44.368 ms | 150 / 150 ms | PASS |
| 10 | 379.444 / 384.029 ms | 56.828 / 58.630 ms | 150 / 150 ms | PASS |

### Export

Original-size synthetic 24MP 與真實 RAW 的 1／10 mask export `PERF-EXPORT` 4/4 PASS；`PERF-MEM-EXPORT` 4/4 PASS。候選 p50 分別為 synthetic 0.119／0.363 秒、real RAW 0.442／0.566 秒，均低於 baseline 的五％ regression limit 與絕對門檻。

## Gate 狀態

| Gate／檢查 | 結果 |
| --- | --- |
| Synthetic stress performance | PASS，4/4 |
| Synthetic preview memory | PASS，4/4 |
| RAW warm `INTERACTIVE-150` | PASS，3/3 |
| RAW preview memory | PASS，9/9 |
| Original-size export | PASS，4/4 |
| Original-size export memory | PASS，4/4 |
| Pixel parity／scalar oracle | PASS，max R8 byte error 0 |
| Cancellation focused matrix | PASS，9/9 |
| 50-cycle worker convergence／RSS | PASS，55/55 joined，active 0 |
| Full Release regression | PASS，2714 tests、22 skipped、0 failures |
| `PERF-COVERAGE` | NOT RUN；B/O 尚無相同且互斥 stage wall-time |
| UI／Mac 前景／實體 iPad／Pencil／VoiceOver／灰卡 | NOT RUN；本輪未取得這些人工驗收證據 |

## 可重現驗證

候選 worktree 的完整原始 artifact 與 checksum 見[證據目錄](../evidence/2026-10-07-brush-preview-performance-fix/README.md)。本輪主要命令如下，全部 exit 0：

```sh
LUMAHARBOR_BRUSH_ABBA_BLOCKS=4 \
LUMAHARBOR_BRUSH_ABBA_SCENARIOS='stress' \
LUMAHARBOR_BRUSH_ABBA_MASK_COUNTS='1 10' \
Scripts/run-brush-performance-abba.sh

LUMAHARBOR_RAW_FIXTURE_DIR='<private RAW fixture directory>' \
LUMAHARBOR_BRUSH_RAW_PREVIEW_SAMPLES=8 \
LUMAHARBOR_BRUSH_EXPORT_SAMPLES=4 \
Scripts/run-brush-raw-export-acceptance.sh

LUMAHARBOR_RUN_BRUSH_PERF_ACCEPTANCE=1 \
swift test -c release \
  --filter BrushMaskPerformanceTests/testOptInFiftyCancellationCyclesSettleWorkersAndMemory

swift test -c release \
  --filter 'BrushMaskScalarOracleTests|BrushMaskCancellationTests|BrushMaskRendererTests|CoreImagePreviewRendererTests'
```

## 尚未完成與 bounded next action

產品效能修正已完成，但 branch 尚未整合。下一位帳號的唯一 bounded action 是：以本報告的 candidate SHA 與 evidence 進行唯讀 code／spec review，確認是否要補上共用 B/O stage clock；若要解除 `PERF-COVERAGE: NOT RUN`，只修改驗收 instrumentation／harness，讓 B/O 共用相同互斥 stage 邊界後重跑 ABBA，不改門檻、不改 benchmark workload。完成 review 前不要 push、merge、rebase 或修改其他 worktree。
