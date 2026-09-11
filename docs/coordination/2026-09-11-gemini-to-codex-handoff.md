# LumaHarbor 專業修圖全階段完成交接文件（Gemini 交付 Codex）

- 日期：2026-09-11
- 交付來源：Gemini
- 接收對象：Codex
- 遵循規範：`AGENTS.md`、`docs/coordination/CURRENT.md`、`docs/coordination/DECISIONS.md`、`docs/coordination/HANDOFF_TEMPLATE.md`

---

## 1. 目前 Git 狀態

- **Worktree 路徑**：`<USER_HOME>/Documents/ChatGPT/LumaHarbor/.worktrees/claude-professional-editing-completion`
- **當前分支**：`claude/professional-editing-completion`
- **當前 HEAD SHA**：`3ccf3e5d8c0ed5131fa46e824e7fdfcfb8b00130` (`3ccf3e5`)
- **起始基準 (Base)**：`4cdf40f`（P4 完成後之基準）
- **本輪完成之 Phase Commits**：
  1. `3905ec7`：`feat: add advanced masks, AI repair, and perspective (P5)`
  2. `28dac70`：`feat: add snapshots, soft proof, and professional preview (P6)`
  3. `3ccf3e5`：`feat: cross-device parity, performance verification, and release prep (P7)`
- **工作樹狀態**：`nothing to commit, working tree clean`。
- **安全宣告**：未執行 `git push`、`git merge`、`git rebase`，未刪除分支或工作樹，未修改任何 Xcode 簽章設定（`CODE_SIGNING_ALLOWED=NO`）。

---

## 2. P5 ~ P7 實作內容摘要

### P5（進階遮罩、AI 修復、透視校正）
- **核心模型**：`LocalAdjustment` 支援 Radial、Brush、Luminance Range、Color Range、Subject、Background 遮罩；支援自訂名稱、反轉（`isInverted`）與不透明度（`opacity`）。
- **離線 AI 分割**：`VisionSegmentationService` 封裝 Apple Vision 離線前景分割，含 SHA-256 指紋與無網路合成 fallback。
- **演算法**：去紅眼瞳孔脫色變暗修復、`CIPerspectiveCorrection` 四角透視校正（`cornerPins`）。
- **雙平台適配**：補齊 iPad Inspector 掛載缺失（Rendering Profile、Presence、Color Grading）。

### P6（快照管理、軟體打樣、專業預覽）
- **Sidecar v4**：落實 `DECISIONS.md` D-006，`PhotoSidecar.currentSchemaVersion` 升至 4，支援 `snapshots: [EditSnapshot]`，向前無損相容 v1/v2/v3。
- **渲染與軟體打樣**：`ProfessionalPreviewRenderer` 提供高光溢出標記（紅）、陰影死黑標記（藍）、目標色域警告（黃）與 sRGB / Display P3 / Adobe RGB 色彩空間模擬。預覽與匯出管線隔離，不影響匯出品質。
- **復原與 A/B 比較**：快照還原採單一 Compound Undo 交易（單次 undo 回滾還原前狀態）；A/B 比較僅變更畫布，不寫入 sidecar 與歷史。
- **雙平台 UI 與在地化**：Mac 掛載 Snapshots 面板，iPad 於 Info domain 與頂部 Compare Menu 支援快照 A/B 比較；8 國語言（`en`, `zh-Hant`, `zh-Hans`, `ja`, `ko`, `de`, `fr`, `es`）補齊 22 個新鍵值。

### P7（跨裝置驗收、效能預算、發布準備）
- **跨裝置對等性**：`CrossDeviceParityVerificationTests` 驗證 Mac 與 iPad 完整掛載 10 個核心調光面板，共享 `InspectorCatalog`、快照工作流與 8 種遮罩。
- **10k 圖庫效能預算**：`LibraryPerformanceBudgetTests` 驗證 10,000 筆相片資料庫的單頁查詢與複合篩選耗時遠低於 250ms p95 預算。
- **RAW 唯讀保護**：`RawImmutabilityVerificationTests` 驗證來源 RAW 檔案在編輯、快照、評分等操作前後，byte-by-byte SHA-256 雜湊 100% 不變；FAT32/exFAT 安全命名過濾。
- **說明文件**：更新 `README.md` 繁體中文全功能指南與雙平台快照操作流程。

---

## 3. 品質閘門驗證證據（Verification Evidence）

- `swift test`：**PASS**（**2193** executed tests, 9 skipped, **0 failures**, 28.55s）。
- 嚴格並發建置：`swift build -Xswiftc -strict-concurrency=complete` **PASS**（0 warning, 0 error）。
- iPad 模擬器建置：`xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` **BUILD SUCCEEDED**。
- 診斷 CLI：`swift run LumaHarborDiagnosticsCLI` **PASS**（4 pass, 0 warning, 0 fail, 3 skipped）。
- 格式檢查：`git diff --check` **PASS**（0 空白字元或衝突問題）。
- 隱私與簽章掃描：**PASS**（無 `/Users/...` 個人路徑、Team ID、UDID 或私鑰洩漏）。

---

## 4. 誠實揭露之未執行項目 (Honest Accounting)

依據專案規範，嚴格區分 `SKIPPED` 與 `NOT RUN`，不可宣稱未經實體驗證的項目為通過：
1. **M 系列 iPad 與 Apple Silicon Mac 真機人工視覺驗收**：`NOT RUN`（需連接實體真機檢查螢幕顯色、手勢連續性與 Dynamic Type 最大字級）。
2. **APFS / exFAT 實體外接隨身碟與記憶卡插拔驗收**：`SKIPPED`（本機無掛載實體外接磁碟環境變數）。
3. **對外發布 ZIP 封裝**：`NOT RUN`（嚴格遵循專案規定：在實體真機與外接磁碟人工檢核完成前，禁止封裝對外發布 ZIP 檔案）。

---

## 5. Codex 建議之接續行動 (Next Action)

1. 核對 `docs/coordination/CURRENT.md` 與本交接文件。
2. 檢查 `3ccf3e5` 的 commit diff 與架構完整性。
3. 若需進行 release 封裝，請在使用者於實體設備完成真機人工驗收並授權後，再執行發布腳本。
