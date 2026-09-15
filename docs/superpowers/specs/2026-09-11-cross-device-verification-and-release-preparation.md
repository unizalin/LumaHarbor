# P7 跨裝置驗收與發布準備規格書

- 文件日期：2026-09-11
- 負責代理：Gemini
- 狀態：DRAFT -> REVIEWED

## 1. 概述

本階段為 LumaHarbor 專業 RAW 編輯器系列的最終整合驗證與發布準備（Phase 7）。整合 P0 至 P6 的所有功能（Sidecar v3/v4、Shared Inspector Catalog、四通道調光曲線、鏡頭校正與風格渲染檔、進階遮罩與離線 AI 前景辨識、去紅眼與透視校正、快照與專業預覽軟體打樣），完成跨裝置功能對等性檢核、10k 照片圖庫效能預算測試、RAW 唯讀完整性（SHA-256）防護、二進位與隱私掃描，以及繁體中文使用說明更新。

## 2. 驗收核心要求

### 2.1 跨裝置對等性（Mac & iPad Parity）
1. **Catalog 與調整項目**：兩平台透過 `InspectorCatalog` 共用 8 個調整分組（Basic、White Balance、Curve、Presence、Color Grading、Detail、Effects、Geometry、Local），不得有某一平台獨缺的滑桿或功能。
2. **快照與專業預覽**：Mac 的 `InspectorTab.snapshots` 與 iPad 的 Info domain / compare menu 均提供快照建立、還原、重新命名、刪除與 A/B 對比；兩平台皆支援高光／陰影裁切與色彩空間軟體打樣。
3. **無損與 Sidecar 相容性**：兩平台產生的 Sidecar v4 在另一平台開啟時 100% 呈現相同編輯參數。

### 2.2 效能預算（Performance Budget）
1. **10k 圖庫查詢**：在 10,000 張照片的資料庫中，單頁載入、評分/旗標篩選及關鍵字搜尋的 p95 響應時間低於 250 ms。
2. **預覽防抖與取消**：快速變更滑桿時，舊渲染請求必須及時取消，不得覆蓋最新編輯結果。

### 2.3 資料安全性與唯讀保護
1. **RAW 不變性**：在所有編輯、快照、元資料儲存與匯出流程中，原始 RAW 檔案的內容與 SHA-256 雜湊嚴禁發生任何變更。
2. **跨檔案系統相容**：在 APFS、exFAT 與一般外接裝置上，Sidecar 寫入維持原子性，且安全檔名替換避免非法字元。

### 2.4 隱私與簽章合規
1. 原始碼、設定檔及發布產物中不得洩漏本機使用者目錄（`/Users/...`）、Apple 開發者 Team ID、Provisioning Profile 或私鑰標頭。
2. 保持本機環境的 Git 安全：禁止執行 push、merge、rebase 或非授權之簽章更動。

### 2.5 發布準備約束
1. 補齊 `README.md` 完整繁體中文使用指南與變更紀錄。
2. 依據 spec 與交接規範：**在所有真機與外部檔案系統實體檢驗核准前，嚴禁封裝對外發布 ZIP 檔案**。
