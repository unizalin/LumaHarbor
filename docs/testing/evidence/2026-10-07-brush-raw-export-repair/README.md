# Brush real RAW preview and full-resolution export repair evidence

日期：2026-10-07

狀態：`DONE_WITH_CONCERNS`

這是 Task 4 公平性修正後的新一輪雙輪次矩陣。舊的 2026-10-06 176 筆 artifact 保留為歷史資料；本目錄的 352 筆資料才是新版 schema v2 與 context lifecycle 契約的正式證據。

## 矩陣與版本

- Baseline B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`
- Candidate O／harness：`4fdbc1fb3abcfea5abe3b11ed03c267851de9116`
- Instrumentation digest：`0e312a9f77f644fd712785e2b572e5fb92e404a3773eabf170beb64b67adc400`
- Preview：real RAW × `cold`、`warm`、`changed` × 0/1/10 masks × 2 rounds × B/O，各 8 samples，共 288 筆。
- Export：synthetic-24mp 與 real RAW × 1/10 masks × 2 rounds × B/O，各 4 samples，共 64 筆。
- 合計 352 筆；`order` 為 0～351，round 1 為 `B O O B`，round 2 為 `O B B O`。
- 所有 sample 的 thermal state 為 `nominal`；公開 artifact 未含私人 fixture 路徑、檔名或 digest，來源檔量測前後保持不變。

## Context lifecycle 宣告契約（建立次數未實測）

- cold preview：context 在 timed request 內建立；B/O 分別為 `duringTimer=2/1`。
- warm／changed preview：context 在 warmup 前建立並重用；B/O 分別為 `beforeTimer=2/1`、`duringTimer=1/0`。
- export：exporter 在 timed request 內建立；B/O 分別為 `duringTimer=2/1`。

上述數字是依程式建構路徑寫入的預期常數，並非 runtime allocations 觀測。計時器包住 cold renderer／exporter 建立，但不能以這些宣告值證明沒有 context lifecycle regression。歷史 v2 原檔保留；新版 v3 使用 expected 欄位名稱。最新 analyzer 重算另外加入證據限制，見[審查修正證據](../2026-10-07-brush-review-fixes/README.md)，不再預期與本目錄的舊 gates 逐位元相同。

## 結果

- `validation PASS`、`overallResult DONE_WITH_CONCERNS`。
- `PERF-EXPORT`：4/4 PASS。
- `PERF-MEM-EXPORT`：4/4 PASS。
- `PERF-MEM-PREVIEW`：9/9 PASS。
- `INTERACTIVE-150`：warm 0/1/10 masks 三組均 FAIL。O 的 p50/p95 為 150.028/156.140 ms、158.224/171.912 ms、167.918/193.295 ms；150 ms 門檻未放寬。

## 檔案 checksum

| 檔案 | SHA-256 |
| --- | --- |
| `brush-raw-export-samples.jsonl` | `e64bf0636805b20898fcbdd743d2f86fcf2a574b68fee872354831846d7fb3f6` |
| `brush-raw-export-gates.json` | `92a94d2d58a43e63798e0d0dfff7534b346452cad3f1b33e420bb0e4df115e27` |

重算命令：

```sh
python3 Scripts/analyze-brush-raw-export-acceptance.py \
  --samples docs/testing/evidence/2026-10-07-brush-raw-export-repair/brush-raw-export-samples.jsonl \
  --output "$TMPDIR/brush-raw-export-gates-recomputed.json" \
  --expected-preview-samples 8 --expected-export-samples 4
```

