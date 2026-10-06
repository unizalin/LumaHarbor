# Brush acceptance completion implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task in the current session. Steps use checkbox syntax for tracking. 非原作者的獨立審查安排在 Task 5。

**Goal:** 補齊筆刷效能與驗收證據，讓每個必要 gate 都有可重算、可追溯的結果；有 FAIL 或 NOT RUN 就維持 `DONE_WITH_CONCERNS`。

**Architecture:** 延用現有 production preview/export API、共同 B/O workload、stage observer 與 schema。先保存既有證據，再執行現成矩陣；需要新增的量測入口按 Task 3、4 各自實作與驗證，不更動 renderer math 來配合測試。

**Tech Stack:** Swift、XCTest、Core Image、Swift concurrency、Bash、Python 3、JSONL。

## 範圍與基準

- 本計畫是[追補 spec](../specs/2026-10-06-brush-raster-correctness-and-verification-followup-spec.md) §7～9 的剩餘工作，不重做已通過的 F1～F3。
- 日期：2026-10-06；本次授權是更新文件與擬定計畫，Task 2～6 尚未執行。
- Writer：Codex；延續已授權候選 `codex/brush-performance-acceptance-repair`，單一 writer。
- 起始 HEAD：`2fdc2562be099490068456074defbd4c2907e276`；起始工作樹乾淨。
- B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`。
- 既有 ABBA 的 O 與 harness：`c425cb7fdc93442e915c13eee913bf175fc15758`。
- 最終回歸／分析器版本：`4e74bf3813ac4e6f6dbdc27b10d8a779c4ef3786`；其後既有提交僅更新文件。
- 此輪未查詢遠端；本機 `origin/main` 為 `82542e73aae8f16b0ba7e4d9d36a8a42451a7319`。延續未合併候選的證據工作，不以此宣稱 main 已整合。

## Global Constraints

- Sidecar v5、rendererVersion 1、mask/stroke 順序、Native fail-closed、recipe/context isolation 與保存語意不變。
- 不降低解析度、不刪點、不改 R8 量化、不放寬 spec 門檻。
- B 的注入只允許 testability／觀測 wrapper；完整 patch 與 content digest 必須保存，不能改 B render math。
- 先完成 B/O 編譯，再序列量測；量測期間不並行編譯、跑 suite 或啟動 Simulator。
- 原始樣本保留失敗、取消與 unavailable；數據缺少使用 null 加原因，不能填零或只保留快樣本。
- 公開資料只含 allowlist 欄位；不含私人 RAW 名稱、路徑、digest、signing 或裝置識別碼。
- 保留 PASS／FAIL／SKIPPED／NOT RUN；沒有原始證據的歷史數字不得冒充本輪重跑。
- 不 push、merge、rebase、安裝或發布；不修改其他工作樹。

## Task 1：文件與歷史樣本保存（本次完成）

**Files:**
- 更新 `docs/superpowers/specs/2026-10-06-brush-raster-correctness-and-verification-followup-spec.md`。
- 更新 `docs/testing/reports/2026-10-06-brush-raster-correctness-followup.md`。
- 更新 `docs/coordination/CURRENT.md` 與 `docs/coordination/2026-10-06-brush-raster-correctness-followup-handoff.md`。
- 新增 `docs/testing/evidence/2026-10-06-brush-warm-abba/{samples.jsonl,gates.json,README.md}`。

**Interfaces:** 既有 96 筆 schema v2 JSONL → 現有 analyzer → 可重算 gates；不修改原始時間與 SHA。

- [x] 核對 `4e74bf3..2fdc256` 僅有文件差異；記完整版本對應。
- [x] 將 spec 的歷史發現與現況分開，修正過期的 SPEC ONLY 與 F1 下一步。
- [x] 檢查所有 sample 欄位及私人字串，原樣保存 96 筆樣本與 SHA-256。
- [x] 執行 analyzer，exit 0、96 records、validation PASS、overall DONE_WITH_CONCERNS。

```sh
python3 Scripts/analyze-brush-performance-abba.py \
  --samples docs/testing/evidence/2026-10-06-brush-warm-abba/samples.jsonl \
  --output "$TASK_GATE_OUTPUT" --expected-per-round 8
```

`TASK_GATE_OUTPUT` 是執行者建立的本機暫存檔案；與已保存 gates 做 JSON 結構比較。這是重算歷史資料，不是新的 benchmark。

## Task 2：完整 synthetic ABBA（唯一立即下一步）

**Files:** 讀取 `Scripts/run-brush-performance-abba.sh`、`Scripts/analyze-brush-performance-abba.py`、`Tests/RawProcessingCoreTests/BrushPreviewABBAHarnessTests.swift`、`docs/testing/brush-performance-abba-schema.json`；新增本輪 evidence 目錄，更新 report。

**Interfaces:** 現有 runner 接收 `LUMAHARBOR_BRUSH_ABBA_SCENARIOS`／`MASK_COUNTS`／`BLOCKS`／`RUN_ROOT`，輸出 `brush-preview-abba.jsonl` 與 `brush-preview-abba-gates.json`。

- [ ] 核對乾淨 HEAD、單一 writer、供電及 thermal state；建立全新 RUN_ROOT，記錄 OS／Xcode／匿名硬體規格，不填未測 metadata。
- [ ] 執行以下命令，五種 scenario 同輪保存，避免把不同日期 warm 數據混成同一輪。

```sh
TASK_ABBA_ROOT=$(mktemp -d)
LUMAHARBOR_BRUSH_ABBA_BLOCKS=4 \
LUMAHARBOR_BRUSH_ABBA_SCENARIOS='cold warm changed appended stress' \
LUMAHARBOR_BRUSH_ABBA_MASK_COUNTS='0 1 10' \
LUMAHARBOR_BRUSH_ABBA_RUN_ROOT="$TASK_ABBA_ROOT" \
Scripts/run-brush-performance-abba.sh
```

- [ ] 核對 5 scenarios × 3 mask counts × 2 rounds × 2 variants × 8 samples = **480 records**；每輪 BOOB／OBBO 各四區塊，對應 sample ordinal workload 一致，輸出尺寸正確。
- [ ] 在計時外比對同 workload 的 B/O 像素，確認 spec R8／materialized-channel 門檻；僅有 sample 尺寸或 `pixelError=null` 不等於像素 PASS。
- [ ] 分情境記 empty、incremental、preview RSS；p50/p95 是各組分位數相減，不能稱逐筆差值分布。stage coverage、RAW、export、UI 保持未測。
- [ ] 若超標，保留全部資料，定位該情境後提出最小修正；不重抽快樣本、不放寬門檻。保存去識別化 samples／gates／manifest，單獨提交證據。

**完成條件:** 480 筆完整、metadata 一致、像素比較可追溯、每一 gate 有結果；FAIL 也必須報告，不得以 runner exit 0 代替產品通過。

## Task 3：stage coverage 與完整 scheduler 取消／切圖

**Files:** `Tests/RawProcessingCoreTests/BrushMaskCancellationTests.swift`、`BrushMaskPerformanceTests.swift`、`PreviewSchedulerTests.swift`；必要時擴充 `Scripts/run-brush-performance-acceptance.sh`、schema 與 analyzer，對應更新 `docs/testing/brush-performance-abba.md`。

**Interfaces:** 沿用 `BrushMaskRenderEvent` per-invocation request ID、stage、worker started/finished 事件；使用實際 PreviewScheduler production route，不能以 direct renderer 輪替冒充 scheduler。

- [ ] 以既有 `testPreviewSchedulerCancelsRasterizingProductionRequestWithoutLateDelivery` 為入口，先加入能抓到 A 晚到發布、worker 未 join 或切圖 subject 錯誤的失敗案例，再做所需最小修正。
- [ ] 在同程序先 warmup 量 plateau；每次 A 進入 raster barrier → cancel → 切換 B → await/join，執行 50 次。每次核對 image／histogram／error 沒有 A 晚到發布、B generation/mapping 正確。
- [ ] 所有 teardown 解開 barrier、cancel、join；watchdog 只防掛死。記錄 started/finished/active 與 settle 前後 RSS，結束 active=0，settled ≤ plateau +32 MiB。
- [ ] 分開量 preview 8 次、6000×4000 export 8 次，cancel 到父／子全部結束 p95 ≤100 ms；encode/decode 不可搶占區段另列。
- [ ] 補 B/O test-only stage wrapper 與 allowlist patch，記 validation/sampling、coverage、blend/materialization、total wall time；不得把平行 worker 累加冒充 wall time。若無法隔離 stage，維持 NOT RUN 並說明所需接口。

```sh
swift test --scratch-path "$TASK_DEBUG_SCRATCH" \
  --filter 'BrushMaskCancellationTests|PreviewSchedulerTests'
LUMAHARBOR_BRUSH_PERF_SCRATCH_PATH="$TASK_PERF_SCRATCH" \
LUMAHARBOR_BRUSH_PERF_SAMPLES=8 Scripts/run-brush-performance-acceptance.sh
```

**完成條件:** functional tests 不依賴速度；Release 數據另判定。coverage 一／十 mask p50 ≤20／80 ms，若 B 已達標則回歸 ≤max(2 ms,B×5%)。正式新增測試名稱與 artifact schema 在此切片提交時一併記錄。

## Task 4：真實 RAW 與原尺寸 export/RSS

**Files:** `Tests/LumaHarborIntegrationTests/RawFixtureTests.swift`、`BrushMaskPerformanceAcceptanceTests.swift`、`Tests/RawProcessingCoreTests/BrushPreviewABBAHarnessTests.swift`、`Scripts/run-brush-performance-abba.sh`、schema／analyzer／操作說明。

**Interfaces:** RAW 只由 `LUMAHARBOR_RAW_FIXTURE_DIR` 私有注入；preview 走 `CoreImagePreviewRenderer`，export 走 `PhotoExporter`；沿用相同 seed、recipe、B/O workload 與 sample metadata。

- [ ] 先檢查先前已授權的 fixture 位置或本機設定；環境變數未設定不代表檔案不存在。若仍找不到，再請使用者提供目錄；不公開列印檔名與 hash。
- [ ] 有 fixture 後跑既有 RawFixtureTests，將 required fixture 與 optional reference skip 分列。

```sh
swift test --scratch-path "$TASK_DEBUG_SCRATCH" --filter RawFixtureTests
```

- [ ] 先新增缺 fixture 不會誤標 PASS、原尺寸不被縮小、encode/close/publish 未結束不會停表的失敗測試；再補 preview/export benchmark 入口與相應 schema。現有 synthetic runner 尚不能宣稱支援 RAW/export，操作命令須隨該切片提供。
- [ ] RAW preview 測 0/1/10 masks、cold/warm/changed；每輪 B/O 各至少 8 samples。記 native/decoded/output 尺寸，warm 絕對 p50/p95 均 ≤150 ms 才通過該情境。
- [ ] 24MP synthetic 加真實 RAW 原尺寸 export；每輪 B/O 一／十 masks 各至少三次，新目的檔；time 含 encode、close、atomic publish，逐程序 peak RSS 含所有 worker。
- [ ] export median 比 B 改善 ≥50%；若 B 已 ≤5／15秒，O 必須維持 absolute budget 且回歸 ≤5%。export RSS ≤B，24MP 同時 ≤768 MiB；preview RSS ≤B+32 MiB。
- [ ] 保存去識別化 evidence 與來源檔未變的私有驗證結果，不提交原圖或私人識別資訊。

**完成條件:** synthetic／RAW、preview／export 各自判定，不能用取消測試代替完整 export 效能。缺素材不阻擋 Task 2、3、5 的可執行部分。

## Task 5：非原作者審查與人工操作

**Files:** report／handoff；沿用 `docs/testing/beta/REAL_DEVICE_CHECKLIST.md`、主線整合 spec 與本追補 spec。

- [ ] 安排非原作者唯讀審查 B→O 的像素、allocation、取消、recipe isolation、benchmark 公平性與 fail-closed；finding 附 commit／檔案／重現方式，修正後重驗受影響 gate。
- [ ] Mac 與實體 iPad 分列筆刷操作、Pencil、鍵盤、VoiceOver、旋轉／Split View；保存產品 SHA、步驟與結果，generic build 不代替實機。
- [ ] 同裝置至少 30 次操作量 16 ms heartbeat：額外延遲 p95 ≤50 ms、max ≤100 ms，warm preview p95 不比 B 差 >10%。
- [ ] 依原主線規格的灰卡 D65 Lab／ΔE00 流程驗收；不能從 synthetic brush 測試推論色彩通過。

**完成條件:** 每項適用操作有證據；無硬體、素材或 reviewer 保持 NOT RUN，列具體解除條件。安裝與簽章配置如有需要，依專案既有授權規則處理。

## Task 6：最終回歸與交接

**Files:** report、spec 狀態、CURRENT、handoff；證據目錄與 manifest。

- [ ] 對最後產品 SHA 跑 spec §9 的完整 Debug／標準 Release、strict-concurrency、Mac Release、generic Simulator/device、RAW、privacy、ZIP checksum；純文件追加只驗文件與樣本，不無故重跑產品 suite。
- [ ] 每項保存 exact command、exit、executed/skipped/failures、完整 product/harness/analyzer SHA；樣本重算與 checksum 通過。
- [ ] 非原作者覆核 findings 全數處理；必要 FAIL 或 NOT RUN 尚存時保留 DONE_WITH_CONCERNS。
- [ ] 更新 CURRENT 與 handoff，保持單一下一步與文件連結一致，依精確路徑提交；產品是否整合／發布另行決定。

## 執行順序與狀態

Task 1 已完成；**Task 2 是下一個有界工作**。接著 Task 3，再 Task 4；素材可用性可以提早查核，但量測不可彼此並行。Task 5 的程式碼審查可在候選穩定後進行，人工操作待設備可用；最後 Task 6 收尾。不承諾固定工時，以每項完成條件推進。
