# Brush preview performance fix evidence

日期：2026-10-08（Asia/Taipei）

狀態：`DONE_WITH_CONCERNS`

本目錄保存同一候選版本上的 synthetic stress 與真實 RAW／original-size export 原始 JSONL、gate JSON 與 checksum。`DONE_WITH_CONCERNS` 只表示 UI／實體裝置／獨立 reviewer 尚未執行；本輪必要的程式、效能、記憶體、取消、pixel parity 與 worker 收斂驗證已完成。公開 artifact 已掃描，不含私人 RAW 路徑、憑證或個人設定。

## 版本與環境

- Branch：`luna/brush-preview-performance-fix`
- Base：`origin/main`=`82542e73aae8f16b0ba7e4d9d36a8a42451a7319`
- 延續候選父版本：`eae30121ec7ef089b4a048a50151993c205e2686`
- Baseline B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`
- Candidate O：`f13de103cec69002666bba389cbf9b6e39cee02f`
- Harness：`f13de103cec69002666bba389cbf9b6e39cee02f`
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
| 1 | B | 0.008 / 0.011 | 0.001 / 0.001 | 0.011 / 0.012 | 173.879 / 176.316 | 0.050 / 0.058 | 3.937 / 4.097 | 177.847 / 180.367 |
| 1 | O | 0.005 / 0.007 | 0.001 / 0.001 | 0.192 / 0.205 | 8.871 / 10.395 | 0.031 / 0.053 | 2.664 / 2.809 | 11.922 / 13.319 |
| 10 | B | 0.010 / 0.011 | 0.001 / 0.002 | 0.074 / 0.079 | 1736.591 / 1755.055 | 0.296 / 0.351 | 7.337 / 7.613 | 1744.289 / 1762.886 |
| 10 | O | 0.006 / 0.006 | 0.001 / 0.002 | 2.429 / 2.694 | 62.821 / 65.111 | 0.106 / 0.112 | 5.277 / 5.658 | 68.609 / 71.059 |

主要根因是 coverage raster 的全圖 per-mask 計算；RAW decode 與 adjustment／blend 不是 synthetic stress 的主成本。RAW warm 的主要修正則是 bounded decoded-preview cache，cache key 綁定檔案狀態、decode quality、resolved recipe、白平衡、lens correction、camera profile 與其他 decode inputs，且不共用 full-resolution export。

## Gate 結果

### Synthetic stress（64 records）

- 1 mask：O round 1 p50/p95 `11.998/13.402 ms`；round 2 `12.070/12.338 ms`。門檻 `30/60 ms`，PASS。
- 10 masks：O round 1 `68.867/71.171 ms`；round 2 `68.282/69.940 ms`。門檻 `100/150 ms`，PASS。
- `PERF-COVERAGE`：4/4 PASS；B/O 都有相同且互斥 stage clock。
- `PERF-MEM-PREVIEW`：4/4 PASS。
- artifact validation：PASS，64 records。

### 真實 RAW warm preview（352 records）

- 0 masks：p50/p95 `34.636/39.790 ms`，PASS。
- 1 mask：`37.048/42.379 ms`，PASS。
- 10 masks：`55.097/67.036 ms`，PASS。
- `INTERACTIVE-150`：3/3 PASS；`PERF-MEM-PREVIEW`：9/9 PASS；artifact validation：PASS。

### Export、取消與像素

- Original-size synthetic 24MP export：1 mask `110.769 ms`、10 masks `354.699 ms`（O p50）；真實 RAW：1 mask `421.932 ms`、10 masks `549.644 ms`（O p50）；`PERF-EXPORT` 4/4 PASS。
- `PERF-MEM-EXPORT`：4/4 PASS；real RAW 10-mask candidate peak RSS `532,824,064` bytes。
- 50-cycle scheduler：PASS；55/55 workers finished、active after join 0、B delivered 55、A discarded 55、failed 0；settled RSS `58,605,568` bytes，limit `90,849,280` bytes。
- Focused regression：30 tests、0 failures；repeated-geometry paint／erase scalar oracle max R8 byte error `0`。
- Full Release suite：2714 tests、22 skipped、0 failures。

## Artifact checksum

| 檔案 | SHA-256 |
| --- | --- |
| `synthetic-stress-samples.jsonl` | `3ce092bebd8f2482bcb55a29c6400b7d91250e8035ba98e168824b5b99d27900` |
| `synthetic-stress-gates.json` | `528074a4625b664a7a0e5ee5c0b2e6f098bf55505c8c21b0605b40fd54f18379` |
| `raw-export-samples.jsonl` | `ffd22667520bb9043ae61bb15efeecd8f280d4b1237871452a2490a3c939e3ac` |
| `raw-export-gates.json` | `b5f4f8339ae9561c3fbd981b45ddf128689a34bc9c46533fd00e9e8ba1154327` |
