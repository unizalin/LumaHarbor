# Brush raster correctness follow-up 交接

日期：2026-10-06

## 目前狀態

- Branch：`codex/brush-performance-acceptance-repair`
- Scalar baseline B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`
- 最終回歸／analyzer SHA：`4e74bf3813ac4e6f6dbdc27b10d8a779c4ef3786`
- ABBA 產品 O／harness SHA：`c425cb7fdc93442e915c13eee913bf175fc15758`
- 文件更新起始 HEAD：`2fdc2562be099490068456074defbd4c2907e276`；本次純文件／證據提交不改產品基準（D-003）。
- Owner：Codex，延續既有候選的單一 writer；起始 dirty files 為零。
- 本機 main 基準：`82542e73aae8f16b0ba7e4d9d36a8a42451a7319`；起始 ahead 34、behind 0，無 upstream，未查遠端。
- 狀態：`DONE_WITH_CONCERNS`
- 未 push、merge、rebase 或 deploy。

Sol 完成四個實作切片：`29718d2` 修正全圖 row mapping、`bc89693` 恢復標準 Release testability、`1ded16a` 建立真正的取消生命週期證據、`c425cb7` 加入 B/O ABBA 與 Release 診斷。Codex root 在整合審查時發現 analyzer 會接受缺少 `maskCount`／`unavailableReasons` 的 record，於 `4e74bf3` 改為 fail closed；沒有再改 renderer 產品邏輯。

## 已驗證

- F1 RED 在原 candidate 出現 61,680／66,049 bytes 的位置差異；修正後直接 R8 與非對稱 blend matrix PASS。
- 完整 Debug 與標準 Release 各 2,708 executed、21 skipped、0 failures。
- strict-concurrency build PASS；有既有 Swift 6 warnings。
- Mac Release app、generic iOS Simulator、generic iOS device build PASS。
- Mac app codesign、release privacy、未發布 ZIP 與 checksum PASS；notarization skipped。
- warm synthetic B/O ABBA 共 96 records，兩輪 empty／1 mask／10 masks preview 與 preview RSS gates PASS，validation PASS。
- preview cancellation p95 0.080 ms、24MP export cancellation p95 0.309 ms；50-cycle direct renderer 診斷 workers 55/55、active 0，settled RSS 增加 16 KiB。
- 完整測試數字、ABBA 表格與 gate 邊界見[驗收報告](../testing/reports/2026-10-06-brush-raster-correctness-followup.md)。規格見[追補規格](../superpowers/specs/2026-10-06-brush-raster-correctness-and-verification-followup-spec.md)。

## 尚未完成

- 最終 SHA 的 `RawFixtureTests`：環境沒有私有 RAW fixture 變數。
- 真實 RAW 0/1/10 masks production preview 與 INTERACTIVE-150。
- B/O 原尺寸真實 RAW export、peak RSS、正式 PERF-EXPORT／PERF-MEM-EXPORT。
- cold、changed、stroke appended、stress 的正式 ABBA 樣本。
- B/O coverage-stage gate、完整 scheduler 50 次切圖 gate、GUI heartbeat。
- Mac 與實體 iPad／Pencil 操作、輸入矩陣、灰卡與獨立 reviewer。

50-cycle 現有測試直接交替 subject 並取消 renderer，不可描述成 50 次完整 PreviewScheduler 切圖；A→B scheduler stale suppression 另有單次 production-route 測試。公開文件不得加入私人 RAW 名稱、路徑或 digest。

## 本次文件／證據更新

- 更新 spec 狀態、report 的完整版本對應、CURRENT 與本交接。
- 新增 `docs/superpowers/plans/2026-10-06-brush-acceptance-completion.md`。
- 新增 `docs/testing/evidence/2026-10-06-brush-warm-abba/samples.jsonl`、`gates.json`、`README.md`；96 筆既有樣本原樣保存，重算 exit 0、validation PASS、overall DONE_WITH_CONCERNS。
- 本次未重跑產品測試；文件連結、差異格式、樣本數、checksum、隱私 allowlist 與重算一致性是本次驗證範圍。
- 原始 build/test log 與取消延遲診斷仍屬先前本機證據；沒有新的獨立覆核。

## Dirty files

本次起始乾淨；僅上述文件／證據由 Codex 修改，於獨立文件提交保存。接手前以 `git status --short` 核對，不覆蓋新出現的他人變更。

## 下一個有界動作

執行[後續計畫 Task 2](../superpowers/plans/2026-10-06-brush-acceptance-completion.md)：在同一參考機器完成 cold／warm／changed／appended／stress、0/1/10 masks 的 synthetic B/O ABBA，核對 480 records 與逐 gate 結果，保存去識別化證據。

此步不需私人 RAW 或實體裝置。接著 Task 3 補完整 scheduler 50-cycle 與 coverage-stage，Task 4 補 RAW/export，Task 5 安排非原作者審查與人工裝置，Task 6 最終回歸。先查核既有已授權 RAW 素材位置；找不到再索取目錄，不能由環境變數未設定推論素材不存在。

維持 `DONE_WITH_CONCERNS`。禁止未授權的 push、merge、rebase、破壞性清理與覆寫其他工作樹。下一步使用 `executing-plans` 執行、`verification-before-completion` 核對結果。
