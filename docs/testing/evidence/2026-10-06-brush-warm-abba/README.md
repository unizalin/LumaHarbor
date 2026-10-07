# Warm synthetic ABBA evidence

- 量測日期：2026-10-06；本次只保存既有資料並重算，不宣稱重新量測。
- `samples.jsonl`：96 筆，原樣保存，所有 top-level 欄位符合 schema v2 allowlist；無私人路徑、RAW 名稱或憑證。
- SHA-256：`c1ea0746b7184deb6c91ca29d4e8de1699754397d2bd71c7790ce2aa236a9bc4`。
- B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`。
- O／harness：`c425cb7fdc93442e915c13eee913bf175fc15758`。
- Analyzer：`4e74bf3813ac4e6f6dbdc27b10d8a779c4ef3786`。
- instrumentation digest：`1991fa4faabf21166143f766fb646a80c97e51b35fec5081d7669b210adbff6d`。
- `gates.json`：使用該 analyzer 重算，exit 0、validation PASS、recordCount 96、overall DONE_WITH_CONCERNS。

```sh
python3 Scripts/analyze-brush-performance-abba.py \
  --samples docs/testing/evidence/2026-10-06-brush-warm-abba/samples.jsonl \
  --output "$TASK_GATE_OUTPUT" --expected-per-round 8 \
  --expected-scenario warm-unchanged-production-preview \
  --expected-mask-count 0 --expected-mask-count 1 --expected-mask-count 10
```

`TASK_GATE_OUTPUT` 由操作者指定為新的本機暫存輸出；與 `gates.json` 比較 JSON 結構。p50/p95 incremental 分別是有遮罩組分位數減空遮罩組分位數，不是逐筆 delta 的分位數，因此 incremental p95 可能小於 incremental p50。

範圍只有 warm synthetic 1600×1067、0/1/10 masks、兩輪各 B/O 八筆。pixelError／workerCounts／cancelOutcome 為 null，不代表零；RAW、export、coverage stage、UI 等未測 gates 保持 NOT RUN。主機／電源／OS／Xcode 的完整當時環境清單未隨此樣本保存，不能由目前環境反推；新矩陣須補記匿名環境 metadata。
