# Brush raster correctness follow-up 交接

日期：2026-10-06

## 目前狀態

- Branch：`codex/brush-performance-acceptance-repair`
- Scalar baseline B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`
- 最終已驗產品／證據 SHA：`4e74bf3`
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

## 下一個有界動作

提供私有 RAW fixture 環境後，在同一參考機器以相同 B/O harness 執行：

1. 真實 RAW production preview 0/1/10 masks，分 cold、warm、changed。
2. 一／十 mask 原尺寸 export，各至少三次，記 total、encode/close/publish 與 peak RSS。
3. 補跑 cold、changed、appended、stress 的兩輪 ABBA。

上述 artifact 通過後，再安排非 writer reviewer 與人工裝置驗收；在此之前維持 `DONE_WITH_CONCERNS`。
