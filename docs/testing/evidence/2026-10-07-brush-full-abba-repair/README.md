# Full synthetic brush ABBA repair evidence

日期：2026-10-07

狀態：`DONE_WITH_CONCERNS`

這是 `e7d6425` 修正後重新執行的五情境完整矩陣。舊的 2026-10-06 證據保留為歷史資料；本目錄保存的 O／harness 為 e7d6425；scenario mapping 的 runner 修正另位於 4fdbc1f。2026-10-07 審查發現 README 使用舊 checksum，現已依原檔更正，gates.json 未改動。加嚴 analyzer 的重算見[審查修正證據](../2026-10-07-brush-review-fixes/README.md)。

## 矩陣與版本

- Baseline B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`
- Candidate O／harness：`e7d6425d72ceb542d9e130b1eadd8f550afdae2e`
- Instrumentation digest：`7a53cf6ceffe63889700c47172e00fa72d99963f030fef0f078281630f5b2eef`
- `cold`、`warm`、`changed`、`appended`、`stress` × 0/1/10 masks × 2 rounds × B/O，各 8 samples，共 480 筆。
- Round 1 順序為 `B O O B`，round 2 為 `O B B O`；`order` 為 0～479，兩個 variant 的 ordinal 依輪次連續。

## 結果

- `validation PASS`、`overallResult DONE_WITH_CONCERNS`。
- `PERF-EMPTY`：10/10 PASS。
- `PERF-PREVIEW`：16/20 PASS；stress 的 1 mask 與 10 masks 兩輪共 4 個 FAIL，未放寬門檻。
- `PERF-MEM-PREVIEW`：30/30 PASS。
- `PERF-COVERAGE`、RAW、export、scheduler 50-cycle、cancellation 與 UI 相關 gate 在此 synthetic artifact 維持 `NOT RUN`。

這批資料只表示矩陣、ABBA 順序、SHA 一致性與 synthetic preview gate 可重算；stress 延遲問題和真實 RAW warm `INTERACTIVE-150` 失敗仍須在總報告中保留。

## 檔案 checksum

| 檔案 | SHA-256 |
| --- | --- |
| `samples.jsonl` | `be249c74ab8d1748a13408b45944754dc6687bdb2b088dcb5fef9e0e27e609a5` |
| `gates.json` | `2175d908220c4f71d145ca0d6daba941c53a52e5a3f784e928ceb3404e5aa062` |

重算命令：

```sh
python3 Scripts/analyze-brush-performance-abba.py \
  --samples docs/testing/evidence/2026-10-07-brush-full-abba-repair/samples.jsonl \
  --output "$TMPDIR/brush-preview-abba-gates-recomputed.json" \
  --expected-per-round 8 \
  --expected-scenario cold-first-open-production-preview \
  --expected-scenario warm-unchanged-production-preview \
  --expected-scenario parameter-changed-production-preview \
  --expected-scenario stroke-appended-production-preview \
  --expected-scenario stress-vectors-production-preview \
  --expected-mask-count 0 --expected-mask-count 1 --expected-mask-count 10
```
