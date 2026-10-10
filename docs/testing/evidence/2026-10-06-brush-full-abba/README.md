# Full synthetic brush ABBA evidence

日期：2026-10-06

狀態：`DONE_WITH_CONCERNS`

## 環境與版本

- Baseline B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`
- 正式修正後 candidate／harness：`a4278c15606ed6e79d414fcf646acb37c30b223f`
- 初次矩陣 candidate／harness：`60618dd892f1b1b5646e61fd96efcbdf6274eb7f`
- 硬體：Apple M4、32 GiB；市電供電。
- 系統：macOS 26.7.1；Xcode 26.6（17F113）。
- 所有 960 筆 timed samples 的 thermal state 均為 `nominal`。

## 資料集

`initial/` 保存第一次 480 筆矩陣。它找出 changed 情境的 0-mask 對照也套用 ±0.05 exposure，不符合 neutral control 契約；資料完整保留，不作正式 changed 判定。

`corrected/` 是修正後正式矩陣：cold、warm、changed、appended、stress × 0/1/10 masks × 2 rounds × B/O 各 8 samples，共 480 筆。每輪順序、sample ordinal、1600×1067 輸出尺寸、單一 instrumentation digest 與 product/harness SHA 均已核對；analyzer exit 0、validation PASS。

| 檔案 | SHA-256 |
| --- | --- |
| `initial/samples.jsonl` | `f67b73f956526656c0fe40d619ea6e82553d62abc6e96a7c19e645a2df638471` |
| `initial/gates.json` | `900ef712cbf74e94084f52f959de0000c6e8ab1b425f0176582e7081e7fb9aec` |
| `corrected/samples.jsonl` | `7834dc9727ad75ea3a83951a2ebbe6249d6a0a886d5b7450b7eb634c14bf0bed` |
| `corrected/gates.json` | `85a99fcf9cd0f735ed65dc4703e4cc63051cc29d8908ee29c8b251ddb7e67e15` |
| `parity/parity.json` | `fc9d404ccaa56e2d5d2e7f53642a5b621790a1126393cde34238889a299c0f91` |
| `parity/manifest.json` | `bb30be33d18a64ae4ee72ceeb058f613130f73a0aa51d6f4a09111d31fbbff8f` |

## 正式結果

- PERF-EMPTY：10/10 PASS。
- PERF-PREVIEW：16/20 PASS。cold、warm、changed、appended 全部通過。
- PERF-MEM-PREVIEW：30/30 PASS；最接近門檻的是 stress round 1、10 masks，O 比 B 高 31,408,128 bytes，仍低於 B + 32 MiB。
- FAIL：stress 的 1 mask、10 masks 在兩輪均超過 preview incremental budget。
- NOT RUN：coverage stage、真實 RAW、export、export RSS、完整 scheduler 50-cycle、正式 cancellation artifact、UI。

| Scenario | Round | 1 mask p50 / p95 | 10 masks p50 / p95 |
| --- | ---: | ---: | ---: |
| cold | 1 | 12.038 / 11.749 ms PASS | 24.796 / 29.253 ms PASS |
| cold | 2 | 11.925 / 12.152 ms PASS | 25.315 / 26.610 ms PASS |
| warm | 1 | 11.864 / 11.621 ms PASS | 24.145 / 24.101 ms PASS |
| warm | 2 | 11.973 / 11.924 ms PASS | 26.597 / 28.906 ms PASS |
| changed | 1 | 12.173 / 12.319 ms PASS | 24.417 / 26.468 ms PASS |
| changed | 2 | 12.204 / 12.162 ms PASS | 24.702 / 25.434 ms PASS |
| appended | 1 | 12.535 / 12.483 ms PASS | 24.095 / 24.095 ms PASS |
| appended | 2 | 12.452 / 12.544 ms PASS | 24.834 / 25.573 ms PASS |
| stress | 1 | 81.211 / 82.507 ms FAIL | 132.794 / 144.226 ms FAIL |
| stress | 2 | 81.314 / 81.308 ms FAIL | 133.732 / 135.118 ms FAIL |

預算為 1 mask p50/p95 ≤30/60 ms，10 masks ≤100/150 ms。incremental p50/p95 是各組分位數減 empty 同分位數，不是逐筆差值分布。

## Untimed pixel parity

`Scripts/run-brush-output-parity.py` 從 immutable B/O archive 建立獨立快照，在計時外核對相同 workload。B 只加入 `parity/B-renderer-observation.patch` 記錄的 test-only R8 byte wrapper；O 使用既有 `_testRenderCoverageBytes`。

- B capture：1 executed、0 skipped、0 failures。
- O capture：1 executed、0 skipped、0 failures。
- 18 份 production preview RGBA8：最大 byte error 0，門檻 ≤1。
- 66 份 direct coverage R8：最大 byte error 0，門檻 0。
- `parity/manifest.json` 保存 B/O 各 84 份、共 168 份本機 raw buffer 的 checksum；兩側組成 84 組比較。raw buffers 與 compiler logs 不提交。

因此 stress FAIL 是效能問題，沒有觀察到畫面或 coverage 差異。
