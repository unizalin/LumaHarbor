# P7 跨裝置驗收與發布準備實作計畫

- 計畫日期：2026-09-11
- 負責代理：Gemini
- 目標：完成 P7 跨裝置功能對等性測試、效能基準驗證、RAW SHA-256 不變性防護測試、隱私掃描與繁中文件更新。

## 1. 任務拆解

### Task 1: 建立跨裝置對等性自動化測試套件
- 檔案：`Tests/LumaHarborAppTests/CrossDeviceParityVerificationTests.swift`
- 驗證內容：
  - Mac `InspectorView` 與 iPad `PadEditorView` / `PadInspectorHost` 對 8 個 Catalog Section 的完整覆蓋。
  - Mac 與 iPad 均支援 Snapshots 與專業預覽（高光/陰影裁切、軟體打樣、A/B 比較）。
  - Mac 與 iPad 的 Local Adjustments 支援相同的遮罩家族（Linear, Radial, Brush, Range, Subject, Background）。
  - 兩平台使用的 Sidecar schema 版本均一致為 4。

### Task 2: 建立 10k 圖庫效能與預覽防抖測試
- 檔案：`Tests/PhotoLibraryCoreTests/LibraryPerformanceBudgetTests.swift`
- 驗證內容：
  - 建立含 10,000 筆資料的記憶體內 / 暫存 SQLite 資料庫，測試單頁查詢、評分/旗標過濾與文字搜尋，確認耗時遠低於 250ms 預算。
  - 驗證預覽請求的取消與節流行為（舊請求被取消，不覆蓋新結果）。

### Task 3: 驗證 RAW 檔案 SHA-256 不變性保護
- 檔案：`Tests/PhotoLibraryCoreTests/RawImmutabilityVerificationTests.swift`
- 驗證內容：
  - 建立模擬 RAW 檔案並計算 SHA-256。
  - 執行讀取、建立 Sidecar、編輯保存、建立 Snapshot、多次匯出後，再次檢驗來源 RAW 檔案的 SHA-256，確認 100% 一致無任何字節變更。

### Task 4: 更新專案繁體中文使用說明 (README.md)
- 檔案：`README.md`
- 內容：
  - 說明 P1~P6 完成的專業修圖能力（四通道曲線、色調分離、鏡頭校正與風格設定檔、進階筆刷與離線 AI 前景辨識、去紅眼與透視修正、快照版本管理與軟體打樣）。
  - 說明 Mac 與 iPad 跨平台協同工作流程與 Sidecar 檔案結構。

### Task 5: 執行完整測試、嚴格並發檢查、Simulator 編譯與隱私掃描
- 執行 `swift test`。
- 執行 `swift build -Xswiftc -strict-concurrency=complete`。
- 執行 iPad Simulator `xcodebuild`。
- 執行 `git diff --check`。
- 執行隱私與敏感路徑掃描。
- 更新 `CURRENT.md` 與撰寫 P7 handoff。
- 建立 P7 phase commit。
