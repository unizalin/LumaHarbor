# Brush review fixes：既有樣本重算

日期：2026-10-07。狀態：`DONE_WITH_CONCERNS`。

本輪只修正驗收工具與證據描述，沒有重新跑 benchmark、使用私人 RAW 或更動 production Sources。核心分析器／新版 harness SHA：`c9196b64826edb943da558b889af0d9c3c591ae1`；review follow-up 與最新驗證程式 SHA：`b921082bcbb08906c1b8ad709b2abd6ec9ee812a`；分支 `codex/brush-performance-acceptance-repair`。

## 原始資料與版本

原始 JSONL 與歷史 gates 保持原樣。這裡的 `sampleArtifact` 仍指來源目錄內的 basename，來源連結如下：

- Synthetic：[480 筆 samples](../2026-10-07-brush-full-abba-repair/samples.jsonl)，O／harness=`e7d6425d72ceb542d9e130b1eadd8f550afdae2e`。
- RAW／Export：[352 筆 samples](../2026-10-07-brush-raw-export-repair/brush-raw-export-samples.jsonl)，O／harness=`4fdbc1fb3abcfea5abe3b11ed03c267851de9116`。
- 兩者 B=`1de07dcfeb2ed217a75d1c04978da6a5936f379a`。
- `e7d6425` 修正 acceptance contracts／RAW harness；`4fdbc1f` 只修正 synthetic runner scenario mapping。改動來源與執行 HEAD 分開記錄。

## 結果

| Artifact | records | validation | PASS | FAIL | NOT RUN |
| --- | ---: | --- | ---: | ---: | ---: |
| synthetic-revalidated-gates.json | 480 | PASS | 56 | 4 | 7 |
| raw-export-revalidated-gates.json | 352 | PASS | 17 | 3 | 0 |

兩份新舊 artifact 的 summaries、gates 完全相同。Synthetic 新舊檔逐位元相同；RAW 輸出只增加 `contextCountEvidence` 與 `contextCountLimitation`，故新 checksum 與歷史 gates 不同。

Context 次數是依建構路徑宣告的預期值，**實際 allocations 未量測**。Legacy v2 與新版 v3 均不能證明實際 context 建立次數；v3 明確使用 expected 欄位名稱及 declaration 標記。計時邊界與 peak RSS 證據各自保留，不從 context 宣告推論量測結果。

## SHA-256

| 檔案 | SHA-256 |
| --- | --- |
| 來源 synthetic samples.jsonl | `be249c74ab8d1748a13408b45944754dc6687bdb2b088dcb5fef9e0e27e609a5` |
| 來源 brush-raw-export-samples.jsonl | `e64bf0636805b20898fcbdd743d2f86fcf2a574b68fee872354831846d7fb3f6` |
| synthetic-revalidated-gates.json | `2175d908220c4f71d145ca0d6daba941c53a52e5a3f784e928ceb3404e5aa062` |
| raw-export-revalidated-gates.json | `ed8e28f53fe5a79bc98f80310424639d0777cd274309a46f9eaaf39f9d98a97a` |

## 可重現命令

由 repo root 執行，`TASK_VERIFY_ROOT` 是新建的本機暫存目錄：

```sh
TASK_VERIFY_ROOT=$(mktemp -d)
python3 Scripts/analyze-brush-performance-abba.py \
  --samples docs/testing/evidence/2026-10-07-brush-full-abba-repair/samples.jsonl \
  --output "$TASK_VERIFY_ROOT/synthetic-revalidated-gates.json" \
  --expected-per-round 8 \
  --expected-scenario cold-first-open-production-preview \
  --expected-scenario warm-unchanged-production-preview \
  --expected-scenario parameter-changed-production-preview \
  --expected-scenario stroke-appended-production-preview \
  --expected-scenario stress-vectors-production-preview \
  --expected-mask-count 0 --expected-mask-count 1 --expected-mask-count 10
python3 Scripts/analyze-brush-raw-export-acceptance.py \
  --samples docs/testing/evidence/2026-10-07-brush-raw-export-repair/brush-raw-export-samples.jsonl \
  --output "$TASK_VERIFY_ROOT/raw-export-revalidated-gates.json" \
  --expected-preview-samples 8 --expected-export-samples 4
```

兩個 analyzer exit 0；表示資料契約有效，並非所有效能 gate PASS。

## 限制

四個 synthetic stress 與三個 warm RAW INTERACTIVE-150 FAIL 保留。公平 B/O stage coverage、Mac／實體 iPad／heartbeat／輸入／灰卡與完整產品簽核仍待完成。本輪驗收工具修正已由 Gemini 3.8 Flash High 唯讀覆核，spec／quality 均 APPROVED；兩個 minor 於 `b921082` 修正並以相同 832 筆重新驗證，輸出逐位元相同。完整 Debug／Release suite、GUI、效能重新量測：本輪 NOT RUN。詳見[Gemini 最終覆核](../../reports/2026-10-07-brush-gemini-final-review.md)。
