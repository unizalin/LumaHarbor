# Brush preview performance fix evidence

日期：2026-10-08（Asia/Taipei）

狀態：`DONE_WITH_CONCERNS`

本目錄保存 128×128 tile follow-up 候選版本上的 synthetic stress、真實 RAW／original-size export 原始 JSONL、gate JSON、Mac 前景人工摘要與 checksum。`DONE_WITH_CONCERNS` 表示 Mac 已完成可執行 slice，但實體裝置、輸入、heartbeat、灰卡與部分手動競態仍未完成；本輪必要的程式、效能、記憶體、取消、pixel parity、worker 收斂與獨立唯讀審查已完成。公開 artifact 已掃描，不含私人 RAW 路徑、憑證或個人設定。

## 版本與環境

- Branch：`luna/brush-preview-performance-fix`
- Base：`origin/main`=`82542e73aae8f16b0ba7e4d9d36a8a42451a7319`
- 延續候選父版本：`eae30121ec7ef089b4a048a50151993c205e2686`
- Baseline B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`
- Candidate O：`7af212512f59768801081765808202fe84a85b25`
- Harness：`7af212512f59768801081765808202fe84a85b25`
- Synthetic instrumentation digest：`a29a2e92c11fffa3b9cb05dfbdbc7714a91777b5ee792b41ba4ae6dd125f5f70`
- 平台：macOS arm64e，Release，`thermalState=nominal`

Baseline 的 shared stage observer 是驗收用 test-only patch，保留 baseline production math；B/O 使用相同 stage 邊界與 interval-union wall clock，平行 worker 不累加 CPU duration。

## 執行命令與 exit code

以下命令均在候選 worktree 執行並 exit 0；RAW 目錄以去識別化佔位符表示：

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

swift test -c release
```

## Stage 計時與根因

每筆 B/O 都記錄以下互斥 stage：RAW decode、global adjustment graph、validation/sampling、coverage raster、per-mask adjustment/blend、final `makeCGImage` materialization，以及 stage total。下表為 synthetic stress 的 p50／p95（ms）：

| masks | variant | raw decode | global graph | validation/sampling | coverage raster | per-mask adjustment/blend | final materialization | stage total |
| ---: | :---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | B | 0.009 / 0.023 | 0.001 / 0.003 | 0.012 / 0.046 | 175.096 / 192.717 | 0.051 / 0.061 | 3.866 / 4.263 | 179.290 / 196.862 |
| 1 | O | 0.005 / 0.006 | 0.001 / 0.001 | 0.240 / 0.297 | 8.801 / 10.111 | 0.037 / 0.056 | 2.550 / 2.811 | 11.988 / 13.210 |
| 10 | B | 0.011 / 0.012 | 0.001 / 0.001 | 0.077 / 0.092 | 1754.617 / 1814.902 | 0.415 / 0.492 | 7.333 / 7.586 | 1762.474 / 1822.993 |
| 10 | O | 0.006 / 0.007 | 0.001 / 0.001 | 3.097 / 3.813 | 64.776 / 74.801 | 0.108 / 0.113 | 5.169 / 5.363 | 70.664 / 81.013 |

表中的 `stage total` 是 16 筆兩輪樣本之 `stageDurationsSeconds.totalMaterialized` 合併 p50／p95；同一批樣本的端到端 `totalDurationSeconds` 合併 p50／p95 為 1 mask `12.084/13.337 ms`、10 masks `70.779/81.143 ms`。兩組數字不可互換：前者只涵蓋 B/O 共用互斥 stage clock，後者另含 harness 邊界上的少量開銷。

主要根因是 coverage raster 的全圖 per-mask 計算；RAW decode 與 adjustment／blend 不是 synthetic stress 的主成本。RAW warm 的主要修正則是 bounded decoded-preview cache，cache key 綁定檔案狀態、decode quality、resolved recipe、白平衡、lens correction、camera profile 與其他 decode inputs，且不共用 full-resolution export。Gemini 指出的 tile 規格差異已在 `7af2125` 對齊為固定 128×128，並由合約測試鎖定。

## Gate 結果

### Synthetic stress（64 records）

- 1 mask：O round 1 p50/p95 `12.105/13.244 ms`；round 2 `12.067/13.337 ms`。門檻 `30/60 ms`，PASS。
- 10 masks：O round 1 `70.907/81.143 ms`；round 2 `70.099/71.513 ms`。門檻 `100/150 ms`，PASS。
- 兩輪端到端合併：1 mask `12.084/13.337 ms`；10 masks `70.779/81.143 ms`。這是 `totalDurationSeconds`，不等同上方 stage total。
- `PERF-COVERAGE`：4/4 PASS；B/O 都有相同且互斥 stage clock。
- `PERF-MEM-PREVIEW`：4/4 PASS。
- artifact validation：PASS，64 records。

### 真實 RAW warm preview（352 records）

- 0 masks：p50/p95 `36.285/39.805 ms`，PASS。
- 1 mask：`39.560/49.993 ms`，PASS。
- 10 masks：`56.002/61.015 ms`，PASS。
- `INTERACTIVE-150`：3/3 PASS；`PERF-MEM-PREVIEW`：9/9 PASS；artifact validation：PASS。

### Export、取消與像素

- Original-size synthetic 24MP export：1 mask `123.601 ms`、10 masks `382.940 ms`（O p50）；真實 RAW：1 mask `436.667 ms`、10 masks `562.844 ms`（O p50）；`PERF-EXPORT` 4/4 PASS。
- `PERF-MEM-EXPORT`：4/4 PASS；real RAW 10-mask candidate peak RSS `503,316,480` bytes。
- 50-cycle scheduler：PASS；55/55 workers finished、active after join 0、B delivered 55、A discarded 55、failed 0；settled RSS `49,168,384` bytes，limit `89,735,168` bytes。
- Focused regression：31 tests、0 failures；repeated-geometry paint／erase scalar oracle max R8 byte error `0`；128×128 acceptance contract PASS。
- Full Release suite：2715 tests、22 skipped、0 failures。

### Mac 前景人工 slice

- Debug app 綁定本 worktree 的精確 bundle 路徑；macOS 26.7.1 arm64、Xcode 26.6。另有已安裝版同名程序，已排除其早期 smoke 觀察後重跑正式步驟。
- `UI-MAC-01` PASS：Enter、blur、Escape、±、reset、非法值、焦點中的 Undo／Redo 同步，以及同值外部 revision 使舊草稿失效均通過。
- `UI-MAC-02` PARTIAL：滴管啟用、單次取樣提交與明確取消通過；受控四色方向、切圖與晚到結果未跑。
- `UI-BRUSH-01` PARTIAL：paint／erase、兩支筆刷切換、size／feather／flow／density、enable/select、單步 Undo／Redo 與 autosave 通過；Delete 未執行。
- `UI-BRUSH-02` PARTIAL：完成筆畫 Undo／Redo 與 close-to-library／reopen 通過；中途競態未手動執行。
- `STORE-01` PARTIAL：前景原尺寸 16-bit TIFF 匯出為 4000×6000、144,013,192 bytes，重開保存通過；其餘 clipboard／batch／snapshot 子項未跑。
- `PERF-UI`、Simulator、實體裝置／輸入與灰卡維持 NOT RUN。CoreDevice 的相關 iPad／iPhone 均 unavailable；fixture inventory 沒有可識別的合格灰卡。
- 詳細步驟與邊界見 `mac-ui-manual-summary.txt`。

## Artifact checksum

| 檔案 | SHA-256 |
| --- | --- |
| `synthetic-stress-samples.jsonl` | `f3b44e38c01b2beeb3a2e8e630889385407f226219248d4334225418d711e2f5` |
| `synthetic-stress-gates.json` | `ce790aa609dd569f7ef1ce0e86701320b8ad0e9daa6eb2e18c60df6e15cb07fb` |
| `raw-export-samples.jsonl` | `e25b61a8f844e2df94dda1bb1e9c0045c01a983a1600bbcb302fb59cf1488e27` |
| `raw-export-gates.json` | `1648821519d3d45e21bcf830b530da2f031ce8ea2d1c914992d3d13e0c3da103` |
| `verification-summary.txt` | `3c4d813d9466b5eb3e2859383bad46c5bc0d9882a30bf5c08374275aa2a4b87d` |
| `mac-ui-manual-summary.txt` | `368e231192e184880e5b85d20200e0504bdf475682f1e1a05f810aa9da2b575d` |

`verification-summary.txt` 另保存 128×128 合約的 RED／GREEN、focused regression、50-cycle 與完整 Release suite 的命令、exit code 與摘要。

2026-10-08 的 Mac 文件差異另經 agy → Gemini 3.1 Pro High 唯讀審查。初審指出 `CURRENT.md` 未說明端到端合併值與 stage total 的差異；本文件補上兩組數據的來源與邊界後，follow-up verdict=`APPROVED`、無 finding。完整紀錄見[Mac 文件 Gemini review](../../reports/2026-10-08-brush-preview-performance-fix-mac-ui-gemini-review.md)。
