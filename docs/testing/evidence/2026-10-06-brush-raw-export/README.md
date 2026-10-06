# Brush real RAW preview and full-resolution export evidence

日期：2026-10-06

狀態：`DONE_WITH_CONCERNS`。176 筆矩陣 validation PASS；20 個 gate 中 17 PASS、3 FAIL。三個 FAIL 都是正式真實 RAW warm preview 的 `INTERACTIVE-150`，原始樣本沒有補抽或刪除。

## 版本與環境

- Baseline B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`
- Candidate O／harness／analyzer：`8bc6819cae1ead2225f265116bb6822d9ecf087c`
- Instrumentation digest：`eaf88cd4d0e931af720ef75378b080e337f0ddfc54021973b234991e91217b89`
- 硬體：Apple M4、32 GiB；市電供電。
- 系統：macOS 26.7.1；Xcode 26.6（17F113）。
- 176 筆 sample 的 thermal state 全部是 `nominal`。
- 私有 fixture 由既有授權位置注入；公開資料不含檔名、路徑或來源 digest。runner 在量測前後比對完整來源檔 SHA-256，結果一致，只保存布林結果。

## 前置 fixture 驗證

`RawFixtureTests` 共 10 executed、1 skipped、0 failures。9 個 required RAW case 通過；唯一 skip 是未提供 optional reference export 目錄，與本輪 required fixture 無關。

```sh
LUMAHARBOR_RAW_FIXTURE_DIR="$PRIVATE_RAW_DIR" \
swift test --scratch-path "$TASK_RAW_FIXTURE_SCRATCH" \
  --filter RawFixtureTests
```

## 正式矩陣

runner 先完成 B/O Release 編譯，再依每組 `B O O B` 序列執行，量測期間沒有平行 build、suite 或 Simulator：

- 真實 RAW preview：3 scenarios × 3 mask counts × 2 variants × 8 samples = 144。
- 原尺寸 export：2 sources × 2 mask counts × 2 variants × 4 samples = 32。
- 合計 176；sample `order` 為 0～175，group 內每個 variant 的 `sampleOrdinal` 完整涵蓋預期範圍。

```sh
LUMAHARBOR_RAW_FIXTURE_DIR="$PRIVATE_RAW_DIR" \
LUMAHARBOR_BRUSH_RAW_EXPORT_RUN_ROOT="$TASK_RAW_EXPORT_ROOT" \
LUMAHARBOR_BRUSH_RAW_PREVIEW_SAMPLES=8 \
LUMAHARBOR_BRUSH_EXPORT_SAMPLES=4 \
Scripts/run-brush-raw-export-acceptance.sh
```

preview timer 從 production request 提交到 materialized CGImage；export timer 從 production request 提交到 `PhotoExporter.export` 返回、published JPEG 重新開啟及尺寸驗證完成。實際 decoder 回傳尺寸由只讀 recorder 取得。真實 RAW native 為 6000×4000；preview decoded/output 為 1067×1600，export decoded 為 4000×6000、published output 為 6000×4000，方向差異已以無序長寬比對，沒有縮小。24MP synthetic export 的 native/decoded/output 都是 6000×4000。

## RAW preview

`INTERACTIVE-150` 依規格只判 warm；cold 與 changed 保留絕對時間摘要。

| Masks | O warm p50 | O warm p95 | 預算 | 結果 |
| ---: | ---: | ---: | ---: | --- |
| 0 | 149.303 ms | 155.067 ms | 150 ms | FAIL |
| 1 | 155.957 ms | 160.231 ms | 150 ms | FAIL |
| 10 | 167.483 ms | 172.726 ms | 150 ms | FAIL |

| Scenario | Masks | B p50/p95 | O p50/p95 |
| --- | ---: | ---: | ---: |
| cold | 0 | 205.697 / 208.340 ms | 205.041 / 206.297 ms |
| cold | 1 | 229.884 / 286.822 ms | 214.803 / 220.051 ms |
| cold | 10 | 405.433 / 448.336 ms | 225.694 / 231.695 ms |
| changed | 0 | 162.665 / 168.084 ms | 147.216 / 154.508 ms |
| changed | 1 | 182.417 / 190.891 ms | 155.817 / 162.859 ms |
| changed | 10 | 362.860 / 368.914 ms | 167.127 / 170.251 ms |

`PERF-MEM-PREVIEW` 9/9 PASS；每個 cold/warm/changed × 0/1/10 mask 的 O process peak 都不超過對應 B +32 MiB。

## Full-resolution export

| Source | Masks | B median | O median | O 上限 | 結果 |
| --- | ---: | ---: | ---: | ---: | --- |
| synthetic-24mp | 1 | 0.324965 s | 0.191194 s | 0.341213 s | PASS |
| synthetic-24mp | 10 | 2.733026 s | 0.322321 s | 2.869678 s | PASS |
| real-raw | 1 | 0.574573 s | 0.452315 s | 0.603302 s | PASS |
| real-raw | 10 | 2.277552 s | 0.498927 s | 2.391430 s | PASS |

B 的四組 median 都已低於一／十 masks 的 5／15 秒 absolute budget，因此本輪適用「O 維持 absolute budget 且不比 B 回歸超過 5%」，不是強制改善 50%。`PERF-EXPORT` 4/4 PASS。

| Source | Masks | B peak RSS | O peak RSS | 額外上限 | 結果 |
| --- | ---: | ---: | ---: | ---: | --- |
| synthetic-24mp | 1 | 395,755,520 | 180,502,528 | 768 MiB | PASS |
| synthetic-24mp | 10 | 615,317,504 | 439,091,200 | 768 MiB | PASS |
| real-raw | 1 | 506,478,592 | 284,606,464 | 無；只要求 ≤B | PASS |
| real-raw | 10 | 722,993,152 | 579,223,552 | 無；只要求 ≤B | PASS |

`PERF-MEM-EXPORT` 4/4 PASS。每次 export 都使用新的目的目錄，published JPEG 已重新開啟，byte count >0，且 native／decoded／output 原尺寸一致。

## 完整性與重算

- `brush-raw-export-samples.jsonl`：176 行；SHA-256 `475509638b350051a01f719b13200503ea9732a390030053fcdd3871e60d5256`
- `brush-raw-export-gates.json`：SHA-256 `31bf6393cf4b5f04588de7ceb256cc29485ebda9e530e1e91a80114ecb053e6f`
- Analyzer 單元測試 8/8 PASS，包含缺 fixture、縮小 export、計時邊界、unexpected 私密欄位、短 SHA、複合型別與 real-RAW RSS 規則。
- Release 計時邊界測試 1/1 PASS；24MP full-resolution smoke 1/1 PASS。
- 以 committed analyzer 對 `brush-raw-export-samples.jsonl` 獨立重算，與 `brush-raw-export-gates.json` 逐位元相同。
- 公開 artifact 掃描 `/Users/`、`/Volumes/`、`/private/` 無命中；來源名稱、路徑與 digest 未保存。

矩陣完整與 export/RSS 通過不會覆蓋三個 warm preview FAIL，也不會覆蓋既有 synthetic stress FAIL、`PERF-COVERAGE` NOT RUN、人工裝置或獨立 reviewer 缺口。
