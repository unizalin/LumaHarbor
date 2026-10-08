# LumaHarbor 筆刷預覽效能修正驗收報告

日期：2026-10-08（Asia/Taipei）

狀態：`DONE_WITH_CONCERNS`

本輪已處理原驗收矩陣中的 7 個效能 FAIL。問題集中為兩個根因：warm RAW 每次 render 重複 decode，以及筆刷 coverage 對每個 mask 做全圖 raster／合成。Gemini 唯讀審查指出的 256×256／128×128 規格落差也已修正；程式、自動驗收與獨立審查均已完成。2026-10-08 另以此分支的 Debug app 完成可執行的 Mac 前景驗收；`DONE_WITH_CONCERNS` 保留給未完成的受控滴管矩陣、破壞性刪除操作、中途手勢競態、PERF-UI heartbeat、Simulator／實體裝置／輸入與灰卡項目。

## 根因與分段數據

B/O 現在使用相同、互斥的 monotonic wall-time stage 邊界：RAW decode、global adjustment graph、validation/sampling、coverage raster、per-mask adjustment/blend、final `makeCGImage` materialization。平行 coverage worker 以 interval union 計算 wall time，不累加 CPU duration。Baseline 的 observer 是 test-only Release patch，不改 baseline production math。

Synthetic stress aggregate（兩輪合併，p50／p95，ms）：

| masks | variant | raw decode | global graph | validation/sampling | coverage raster | per-mask adjustment/blend | final materialization | stage total |
| ---: | :---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | B | 0.009 / 0.023 | 0.001 / 0.003 | 0.012 / 0.046 | 175.096 / 192.717 | 0.051 / 0.061 | 3.866 / 4.263 | 179.290 / 196.862 |
| 1 | O | 0.005 / 0.006 | 0.001 / 0.001 | 0.240 / 0.297 | 8.801 / 10.111 | 0.037 / 0.056 | 2.550 / 2.811 | 11.988 / 13.210 |
| 10 | B | 0.011 / 0.012 | 0.001 / 0.001 | 0.077 / 0.092 | 1754.617 / 1814.902 | 0.415 / 0.492 | 7.333 / 7.586 | 1762.474 / 1822.993 |
| 10 | O | 0.006 / 0.007 | 0.001 / 0.001 | 3.097 / 3.813 | 64.776 / 74.801 | 0.108 / 0.113 | 5.169 / 5.363 | 70.664 / 81.013 |

coverage raster 是 synthetic stress 的主要成本；RAW decode 與 per-mask adjustment/blend 不是主要瓶頸。RAW warm 測量則證實 decoded-preview cache 能移除重複 decode 的成本。

## 修改檔案與設計理由

- `Sources/RawProcessingCore/Preview/PreviewRenderInstrumentation.swift`：新增共享 stage model 與 interval-union collector。
- `Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift`：加入 decode、graph、validation、brush、materialization 分段計時；接入 bounded decoded-preview cache；取消後晚到結果不回填錯誤 context。
- `Sources/RawProcessingCore/Preview/DecodedPreviewCache.swift`：bounded LRU actor cache。key 綁定標準化 URL、檔案 size／mtime／generation、decode quality、decoder identifier、resolved RAW recipe、白平衡、lens correction、camera profile 與其他 decode inputs；interactive decode 與 full-resolution export 分離。
- `Sources/RawProcessingCore/Pipeline/BrushMaskRenderer.swift`：固定 128×128 bounded tile scratch／concurrency、相同幾何 coverage reuse、最多兩個 active mask worker，並在 cancellation 後 join 所有已啟動 worker。保留 mask 順序、paint／erase、geometry mapping、不同 mask adjustment、overlap、像素精度與 cancellation checkpoints。
- `Scripts/fixtures/brush-baseline-release-testability.patch`：以同一 stage 邊界讓 baseline B 可觀測，僅供驗收 harness 使用。
- `Scripts/analyze-brush-performance-abba.py`：只有 B/O 七段欄位完整且有限時才產生 `PERF-COVERAGE`；不完整舊 artifact 仍 fail closed 為 `NOT RUN`。
- `Tests/RawProcessingCoreTests/BrushPreviewABBAHarnessTests.swift` 與 analyzer tests：記錄 B/O stage JSON 並驗證完整 coverage matrix。
- `Tests/RawProcessingCoreTests/BrushMaskRendererTests.swift`：加入 128×128 tile acceptance contract，已先以 256 取得預期 RED，再改為 128 取得 GREEN。

沒有降低解析度、刪除筆刷點、跳過調整、改 benchmark workload 或放寬門檻。

## 修改前後效能

### Synthetic stress（1600×1067）

| workload | B p50 / p95 | O p50 / p95 | 門檻 | 結果 |
| --- | ---: | ---: | ---: | --- |
| 1 mask round 1 | 180.794 / 216.295 ms | 12.105 / 13.244 ms | 30 / 60 ms | PASS |
| 1 mask round 2 | 180.506 / 186.025 ms | 12.067 / 13.337 ms | 30 / 60 ms | PASS |
| 10 masks round 1 | 1783.412 / 1824.322 ms | 70.907 / 81.143 ms | 100 / 150 ms | PASS |
| 10 masks round 2 | 1758.894 / 1792.669 ms | 70.099 / 71.513 ms | 100 / 150 ms | PASS |

### RAW warm preview

| masks | B p50 / p95 | O p50 / p95 | 門檻 | 結果 |
| ---: | ---: | ---: | ---: | --- |
| 0 | 172.412 / 183.000 ms | 36.285 / 39.805 ms | 150 / 150 ms | PASS |
| 1 | 190.245 / 204.335 ms | 39.560 / 49.993 ms | 150 / 150 ms | PASS |
| 10 | 385.381 / 393.690 ms | 56.002 / 61.015 ms | 150 / 150 ms | PASS |

### Original-size export

`PERF-EXPORT` 4/4、`PERF-MEM-EXPORT` 4/4 PASS。O p50：synthetic 24MP 1／10 masks=`123.601/382.940 ms`；真實 RAW 1／10 masks=`436.667/562.844 ms`。

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
| 128×128 tile acceptance contract | PASS，RED／GREEN 已保存 |
| Focused Release tests | PASS，31/31 |
| Full Release regression | PASS，2715 tests、22 skipped、0 failures |
| Gemini 唯讀審查 | `APPROVED_WITH_CONCERNS`；唯一 minor 已由 `7af2125` 解決 |
| `UI-MAC-01` 原生數值欄位 | PASS；Enter／blur／Escape／±／reset／非法值／焦點中 Undo/Redo 同步／同值外部 revision 使舊草稿失效均通過 |
| `UI-MAC-02` 白平衡滴管 | PARTIAL；啟用、單次取樣提交、明確取消通過；四色方向、切圖與晚到結果未跑 |
| `UI-BRUSH-01` | PARTIAL；paint／erase、兩支筆刷切換、size／feather／flow／density、enable、select、單筆畫 Undo/Redo 與 autosave 通過；Delete 未點擊 |
| `UI-BRUSH-02` | PARTIAL；完成筆畫 Undo/Redo 與 close-to-library／reopen 通過；中途換圖／geometry／snapshot／cancel／close 未手動執行 |
| `STORE-01` | PARTIAL；paint→原尺寸 TIFF export→close→reopen 通過；Local paste、batch／snapshot、刪最後快照未跑 |
| `PERF-UI` | NOT RUN；沒有 16 ms heartbeat 與 30 次 B/O UI gesture recorder |
| `UI-SIM-01` | NOT RUN |
| `UI-DEVICE-01`／`UI-INPUT-01` | NOT RUN；CoreDevice 中 iPad／iPhone 均為 unavailable |
| 灰卡色彩 gate | NOT RUN；未找到合格 RAW 灰卡與受控 ROI reference |

`PERF-COVERAGE` 不再是 NOT RUN；RAW/export harness 沒有把 stage coverage 反推成 gate，仍以其自身的 total wall-time、RSS 與 published-file checks 驗收。

## Mac 前景驗收

Mac 測試固定綁定本 worktree 的 `build/LumaHarbor.app`，configuration=`Debug`，平台為 macOS 26.7.1 arm64／Xcode 26.6；候選產品 SHA=`7af2125`。同機另有已安裝版程序，因此已排除其早期 smoke 觀察，所有正式結果都在精確 app bundle 路徑與暫存 RAW 副本上重跑。

數值欄位各種提交／取消路徑與 Undo 粒度通過。調整筆刷 sidecar 實際保存兩支 mask；第一支依序保存 paint、erase 兩筆，Undo 只移除 erase、Redo 恢復 erase，切換第二支再切回時 exposure 狀態沒有串線。回到相片庫再重開仍保留 masks／strokes；前景匯出產生 4000×6000、16-bit TIFF，沒有降解析度。完整逐項紀錄見 [`mac-ui-manual-summary.txt`](../evidence/2026-10-07-brush-preview-performance-fix/mac-ui-manual-summary.txt)。

## 可重現驗證

完整原始 artifact、環境、SHA、命令、exit code 與 checksum 見[證據目錄](../evidence/2026-10-07-brush-preview-performance-fix/README.md)。

## 尚未完成與 bounded next action

產品效能修正、自動驗收、獨立唯讀 code／spec review 與目前可執行的 Mac 前景 slice 已完成。下一個 bounded action 是在裝置恢復可用後執行實體 iPad／Pencil／鍵盤／VoiceOver／旋轉／Split View，並在具備 heartbeat recorder 與合格色卡後補 `PERF-UI` 30 次 B/O 手勢及灰卡矩陣；Mac 剩餘的四色滴管方向、中途手勢競態與破壞性 Delete 操作也要分列補證。程式面若要整合，先由另一個帳號唯讀確認 `7af2125` 之後的文件差異，再依共用 Git 流程處理。未經使用者另行授權，不 push、merge、rebase 或修改其他 worktree。
