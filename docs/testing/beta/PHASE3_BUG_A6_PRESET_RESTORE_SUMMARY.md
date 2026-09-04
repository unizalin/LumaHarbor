# Phase 3 Manual Bug — A6 Preset Restore Summary

## 摘要

- 標題：Restore Presets 完成後沒有顯示可讀的完成摘要
- 嚴重度：High
- 首次發生日期／時間：2026-09-04 11:00 CST
- 是否可穩定重現：已在本輪隔離 Mac app 驗測中重現 1 次；尚未跑第二輪確認。

## Build 與環境

- Build：Debug `.app` bundle built with `Scripts/build-app-bundle.sh debug`
- Commit（完整 SHA）：9593582d9acbfa1115df039c7b82b399cfca5644
- Mac 型號／macOS：Mac mini (Mac16,10), Apple M4, 32 GB, macOS 26.6.2 (25G82)
- 來源類型：APFS-TMP-001
- 網路狀態：不適用

## 重現步驟

1. 以前景方式啟動同一個 debug `.app`，並將 Application Support 指向隔離測試 home。
2. 加入 `APFS-TMP-001` 測試圖庫，確認主視窗顯示 3 張 RAW 測試照片。
3. 開啟 `RAW-001`，在 Preset Browser 中對 built-in `Flat (Low Contrast)` 執行 `Copy to My Presets`。
4. 透過 `Backup My Presets...` 匯出 `.lhpresetbackup` 到測試工作目錄，確認檔案存在且可用 `plutil` 讀取。
5. 透過 `Restore Presets...` 選取同一份 `.lhpresetbackup`，按 `Open`。

## 預期結果

Restore 完成後，Mac app 視窗應顯示「還原完成」alert，並以中文清楚列出新增、保留副本、已存在略過或失敗的摘要，例如 `1 already present` 對應的中文訊息。

## 實際結果

Open panel 關閉並回到主視窗，但沒有出現「還原完成」或任何新增/略過/失敗摘要 alert。隔離 My Presets 目錄仍只有原本 1 份 preset 檔案，因此這次流程至少沒有可見地建立副本；重點是使用者沒有得到完成摘要，A6 的「摘要文字清楚可讀」無法通過。

## 頻率與影響

- 發生頻率：本輪 1/1。
- 是否阻擋繼續測試：是。依 `PHASE3_MANUAL_CHECKLIST.md` 停止條件，A6 為必要項目，FAIL 後停止把 build 當作可上線候選。
- 是否造成閃退、資料遺失或錯誤編輯：未觀察到閃退、資料遺失或錯誤編輯；目前是完成回饋/摘要呈現缺失。

## 原檔完整性

- RAW 原檔 checksum 是否改變：未檢查。
- RAW 原檔大小是否改變：未檢查。
- 是否發生重新命名、移動、覆寫或刪除：未觀察到對 RAW 測試副本的重新命名、移動、覆寫或刪除。

## 證據

- 截圖／錄影代號：CUA-Phase3-A6-20260904
- 去識別化 log 代號：無；app 前景輸出無錯誤文字。
- 相關 checklist ID：A6

## 隱私確認

- [x] 未包含 Apple ID、Team ID、UDID、憑證或 provisioning profile。
- [x] 未包含真實使用者名稱、完整本機路徑、磁碟名稱或提供者帳號。
- [x] 未附上未經授權的 RAW 原檔。
- [x] 截圖與 log 以代號記錄；本文件未保存照片內容。
