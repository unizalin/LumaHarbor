# Brush preview performance fix evidence

日期：2026-10-07（Asia/Taipei）

狀態：`DONE_WITH_CONCERNS`

這份目錄保存本次修正後的原始 synthetic stress 與 RAW／export JSONL，以及由同一次執行產生的 gate JSON。公開 artifact 已掃描，不含私人 fixture 路徑、使用者目錄或憑證。

## 版本與環境

- Branch：`luna/brush-preview-performance-fix`
- Base：`origin/main`=`82542e73aae8f16b0ba7e4d9d36a8a42451a7319`
- 延續候選父版本：`eae30121ec7ef089b4a048a50151993c205e2686`
- Baseline B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`
- Candidate O／harness：`26e7358fcf5019b246588d1bb3baa8a6005548cd`
- Synthetic instrumentation digest：`1bf08395a149875e9c3b0fe5a8ef4473761c7abf3d785ac464096fe94ca292fe`
- 平台：macOS arm64e，Release，`thermalState=nominal`

## 執行命令

以下命令均在候選 worktree 執行並 exit 0；`<private RAW fixture directory>` 是本機私有目錄的去識別化佔位符。

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

## Stage 計時診斷

候選版使用互斥 monotonic wall-time span，平行 worker 以 interval union 計算，不累加 CPU duration。Synthetic O 的中位數／p95 如下：

| masks | raw decode | global graph | validation/sampling | coverage raster | per-mask adjustment/blend | final makeCGImage | total materialized |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 p50 / p95 ms | 0.005 / 0.006 | 0.001 / 0.001 | 0.192 / 0.208 | 9.221 / 9.582 | 0.042 / 0.044 | 2.562 / 2.898 | 12.180 / 12.574 |
| 10 p50 / p95 ms | 0.006 / 0.006 | 0.001 / 0.001 | 1.855 / 2.130 | 87.248 / 131.703 | 0.110 / 0.126 | 5.308 / 6.878 | 95.987 / 141.012 |

主要成本確定在 coverage raster；RAW decode 與 adjustment／blend 不是 synthetic stress 的主因。B 仍是舊版 renderer，沒有相同 stage observer，因此 `PERF-COVERAGE` 保持 `NOT RUN`，不把 O-only stage 拿來宣稱 B/O coverage regression。

## Gate 結果

### Synthetic stress

- 1 mask：O p50 `12.293 ms`、p95 `12.624 ms`（round 1）；p50 `12.266 ms`、p95 `12.680 ms`（round 2）。門檻 `p50 ≤30 ms`、`p95 ≤60 ms`，PASS。
- 10 masks：O p50 `96.121 ms`、p95 `141.143 ms`（round 1）；p50 `96.025 ms`、p95 `97.391 ms`（round 2）。門檻 `p50 ≤100 ms`、`p95 ≤150 ms`，PASS。
- 4 個 synthetic `PERF-MEM-PREVIEW` gate：PASS；candidate peak RSS 為 58.97／84.18／59.26／78.23 MB。
- artifact validation：PASS，64 records。
- `PERF-COVERAGE`：`NOT RUN`，B/O 沒有相同 stage clock。

### 真實 RAW warm preview

- 0 masks：p50 `35.400 ms`、p95 `40.244 ms`，PASS。
- 1 mask：p50 `38.049 ms`、p95 `44.368 ms`，PASS。
- 10 masks：p50 `56.828 ms`、p95 `58.630 ms`，PASS。
- `INTERACTIVE-150`：3/3 PASS；preview memory：9/9 PASS；artifact validation：PASS，352 records。

### Export、取消與像素

- Synthetic／real RAW original-size export：`PERF-EXPORT` 4/4 PASS。
- Export memory：`PERF-MEM-EXPORT` 4/4 PASS。
- 50-cycle scheduler：PASS；55/55 workers finished、active after join 0、B delivered 55、A discarded 55、failed 0；settled RSS `58,605,568` bytes，limit `90,816,512` bytes。
- Focused regression：30 tests、0 failures；cancellation 9/9、renderer 9/9、scalar oracle 5/5、preview renderer 7/7。
- Full Release suite：2714 tests、22 skipped、0 failures。
- Repeated-geometry paint／erase scalar oracle：max R8 byte error `0`。

## Artifact checksum

| 檔案 | SHA-256 |
| --- | --- |
| `synthetic-stress-samples.jsonl` | `7c0422a5f2723a689ba88f012a627ee04b1e8822f2ba155dd15e31d4add210db` |
| `synthetic-stress-gates.json` | `b9c894283899de3912fe6a4eb0e4adfa001ad0488415480726a93eeea00585f5` |
| `raw-export-samples.jsonl` | `c1cfc8a5e23940257f77331dcbbc6b844acf8012b0496fab768a45ce168578fd` |
| `raw-export-gates.json` | `92a70e477a8fd52e9b579e049bbe9f0573cb41dd4108b94bb147884df29e8603` |
