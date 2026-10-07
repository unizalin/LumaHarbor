# Brush raster correctness follow-up 交接

日期：2026-10-06

## 2026-10-07 交接補充（目前權威結果）

- `e7d6425` 修正 synthetic ABBA runner 的正式 scenario mapping 與 strict round/order contract；以 480 筆重新驗證，`validation PASS`，56 PASS／4 FAIL／7 NOT RUN。
- `4fdbc1f` 執行新版 RAW／Export runner；以 schema v2 完成 352 筆雙輪次矩陣，`validation PASS`，`PERF-EXPORT` 4/4、`PERF-MEM-EXPORT` 4/4、`PERF-MEM-PREVIEW` 9/9 PASS，warm RAW `INTERACTIVE-150` 3/3 FAIL。
- 新證據目錄：[full ABBA repair](../testing/evidence/2026-10-07-brush-full-abba-repair/README.md) 與 [RAW/export repair](../testing/evidence/2026-10-07-brush-raw-export-repair/README.md)。舊的 2026-10-06 176 筆 RAW artifact 保留作歷史，不再作目前相對效能的唯一依據。
- 兩份新 gate artifact 已用 committed analyzer 重算逐位元相同；工作樹不得以此狀態宣稱 READY，仍需 Task 5 獨立 reviewer 與人工／實體裝置項目。

## 目前狀態

- Branch：`codex/brush-performance-acceptance-repair`
- Scalar baseline B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`
- ABBA 最終回歸／analyzer SHA：`4e74bf3813ac4e6f6dbdc27b10d8a779c4ef3786`
- ABBA 產品 O／harness SHA：`c425cb7fdc93442e915c13eee913bf175fc15758`
- 完整五情境 benchmark／parity SHA：`a4278c15606ed6e79d414fcf646acb37c30b223f`；只修改 test harness，產品 renderer 等同 `4e74bf3`。
- Scheduler quiescence SHA：`2b3acc4dbab87d91684ef127608a873173fbf7e5`；production-route harness SHA：`cf50e5695c2ee02e8fd006e50160293f834c7a0a`；Release acceptance analyzer／artifact SHA：`5170fb18d06b49415dc6b1c56bf9dca250c05abd`。
- 真實 RAW／原尺寸 export harness、runner 與 analyzer SHA：`8bc6819cae1ead2225f265116bb6822d9ecf087c`。
- 文件更新起始 HEAD：`2fdc2562be099490068456074defbd4c2907e276`；本次純文件／證據提交不改產品基準（D-003）。
- Owner：Codex，延續既有候選的單一 writer；起始 dirty files 為零。
- 本機 main 基準：`82542e73aae8f16b0ba7e4d9d36a8a42451a7319`；起始 ahead 34、behind 0，無 upstream，未查遠端。
- 狀態：`DONE_WITH_CONCERNS`
- 未 push、merge、rebase 或 deploy。

Sol 完成四個實作切片：`29718d2` 修正全圖 row mapping、`bc89693` 恢復標準 Release testability、`1ded16a` 建立真正的取消生命週期證據、`c425cb7` 加入 B/O ABBA 與 Release 診斷。Codex root 在整合審查時發現 ABBA analyzer 會接受缺少 `maskCount`／`unavailableReasons` 的 record，於 `4e74bf3` 改為 fail closed；其後 `2b3acc4` 修正 scheduler quiescence，`5170fb1` 再修正 Task 3 analyzer 會接受缺欄位、unexpected 私密欄位、損壞 JSON 與短 SHA 的問題。renderer math 沒有再變更。

## 已驗證

- F1 RED 在原 candidate 出現 61,680／66,049 bytes 的位置差異；修正後直接 R8 與非對稱 blend matrix PASS。
- 完整 Debug 與標準 Release 各 2,708 executed、21 skipped、0 failures。
- strict-concurrency build PASS；有既有 Swift 6 warnings。
- Mac Release app、generic iOS Simulator、generic iOS device build PASS。
- Mac app codesign、release privacy、未發布 ZIP 與 checksum PASS；notarization skipped。
- warm synthetic B/O ABBA 共 96 records，兩輪 empty／1 mask／10 masks preview 與 preview RSS gates PASS，validation PASS。
- 完整五情境正式 ABBA 480 records validation PASS：56 gates PASS、4 FAIL、7 NOT RUN；四個 FAIL 均為 stress preview 延遲。18 preview 與 66 direct R8 B/O 最大 byte error 0。
- 目前正式 preview cancellation p95 0.052000 ms、6000×4000 export cancellation p95 0.370416 ms；完整 production PreviewScheduler 5 warmup＋50 measured：B 55/55 delivered、A 55/55 discarded、errors 0、mapping/histogram 55/55、workers 55/55、active 0；warm plateau 77,135,872 bytes、settled 69,959,680 bytes，低於 110,690,304 bytes 上限。
- `RawFixtureTests` 10 executed、1 optional reference skipped、0 failures；required RAW case 全部通過。
- 真實 RAW／原尺寸 export 176 records validation PASS、thermal 176/176 nominal；PERF-EXPORT 4/4、PERF-MEM-EXPORT 4/4、PERF-MEM-PREVIEW 9/9 PASS。warm RAW 0/1/10 masks 的 INTERACTIVE-150 皆 FAIL：O p50/p95 分別為 149.303/155.067、155.957/160.231、167.483/172.726 ms。
- 完整測試數字、ABBA 表格與 gate 邊界見[驗收報告](../testing/reports/2026-10-06-brush-raster-correctness-followup.md)。規格見[追補規格](../superpowers/specs/2026-10-06-brush-raster-correctness-and-verification-followup-spec.md)。

## 尚未完成

- warm RAW INTERACTIVE-150：0/1/10 masks 三組都已實測 FAIL，後續若修正產品需重跑同一矩陣。
- stress preview 效能修正：一 mask 約 81 ms，十 masks 約 133 ms 的 p50 增量超標；其餘四情境通過。
- B/O coverage-stage gate與 GUI heartbeat。Scheduler 50 次切圖 gate 已完成。
- Mac 與實體 iPad／Pencil 操作、輸入矩陣、灰卡與獨立 reviewer。

`PERF-COVERAGE` 維持 NOT RUN：B/O 沒有共同且互斥的 validation、sampling、raster、blend/materialization wall-time 入口；O-only `coverageIncludingSampling` 不可冒充正式 B/O stage gate。公開文件不得加入私人 RAW 名稱、路徑或 digest。

## 本次文件／證據更新

- 更新 spec 狀態、report 的完整版本對應、CURRENT 與本交接。
- 新增 `docs/superpowers/plans/2026-10-06-brush-acceptance-completion.md`。
- 新增 `docs/testing/evidence/2026-10-06-brush-warm-abba/samples.jsonl`、`gates.json`、`README.md`；96 筆既有樣本原樣保存，重算 exit 0、validation PASS、overall DONE_WITH_CONCERNS。
- `a4278c1` 新增 changed neutral-control 契約測試；RED 1 test／16 assertions failure，GREEN 2 tests／1 skipped／0 failures。
- 新增 `Scripts/run-brush-output-parity.py` 與完整 ABBA evidence；第一次與修正後各 480 筆均保留，正式矩陣 56 PASS／4 FAIL／7 NOT RUN，pixel parity 84/84 PASS。
- `2b3acc4` 新增 scheduler live-task quiescence；RED 1 test／2 failures，GREEN cancellation＋scheduler 19/19 PASS。
- `cf50e56` 將 50-cycle 改為真正 production scheduler route；`5170fb1` 新增嚴格 Release allowlist analyzer／schema、6 個 analyzer 測試與 fresh run-root 防覆寫，保存 `docs/testing/evidence/2026-10-06-brush-scheduler-cancellation/acceptance.json`。PERF-CANCEL 與 PERF-MEM-50-CANCEL PASS，PERF-COVERAGE NOT RUN；artifact checksum 為 `b79e0d238be7d885c12dde38a760aa7bcf89fad5b20f043439b2396214da8b1d`。
- `8bc6819` 新增 actual-decoded-size recorder、真實 RAW／原尺寸 export ABBA runner、schema 與 analyzer。Task 4 保存 `docs/testing/evidence/2026-10-06-brush-raw-export/{brush-raw-export-samples.jsonl,brush-raw-export-gates.json,README.md}`；176 筆公開 artifact 無私人路徑，來源量測前後完整 digest 一致，獨立重算逐位元相同。
- 本次未重跑完整產品 regression suites；Task 2 另執行 Release focused harness、完整 synthetic ABBA 與 untimed parity capture。Task 3 最終另跑 scheduler／cancellation 19/19、analyzer 6/6、Release acceptance 3/3。Task 4 另跑 RawFixtureTests、analyzer 8/8、Release 計時邊界 1/1 與正式 176-record matrix。文件連結、差異格式、樣本數、checksum、隱私 allowlist 與 gate 重算一致性也已核對。
- 原始 build/test log 與取消延遲診斷仍屬先前本機證據；沒有新的獨立覆核。

## Dirty files

本次起始乾淨；Task 3 產品、harness、analyzer 與文件均以獨立提交保存。接手前以 `git status --short` 核對，不覆蓋新出現的他人變更。

## 下一個有界動作

執行[後續計畫 Task 5](../superpowers/plans/2026-10-06-brush-acceptance-completion.md)：安排非原作者唯讀審查 B→O 的像素、allocation、取消、recipe isolation、benchmark 公平性與 fail-closed；再依設備可用性分列 Mac／實體 iPad、heartbeat、輸入與灰卡人工項目。

公平 stage coverage 另需 B/O 共同 production stage clock；已知 synthetic stress 與 warm RAW FAIL 不得放寬門檻或改標 PASS。Task 6 最後做最終回歸與交接。

維持 `DONE_WITH_CONCERNS`。禁止未授權的 push、merge、rebase、破壞性清理與覆寫其他工作樹。下一步使用 `executing-plans` 執行、`verification-before-completion` 核對結果。
