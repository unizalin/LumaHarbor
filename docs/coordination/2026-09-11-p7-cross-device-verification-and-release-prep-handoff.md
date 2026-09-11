# Handoff: P7 Cross-Device Verification and Release Preparation

依循 `docs/coordination/HANDOFF_TEMPLATE.md`。

## Status

`DONE_WITH_CONCERNS`

## Git state

- Source branch: `claude/professional-editing-completion`
- Base for this phase: `28dac70` ("feat: add snapshots, soft proof, and professional preview (P6)")
- Implementation commit: `feat: cross-device parity, performance verification, and release prep (P7)`
- Ahead / behind: Feature branch 保持領先；嚴格未執行 push、merge 或 rebase。

## Changes

### New files (spec / plan)

- `docs/superpowers/specs/2026-09-11-cross-device-verification-and-release-preparation.md`
- `docs/superpowers/plans/2026-09-11-cross-device-verification-and-release-preparation.md`

### New files (tests)

- `Tests/LumaHarborAppTests/CrossDeviceParityVerificationTests.swift`:
  - 5 項測試：驗證 Mac 與 iPad 跨平台對等性，確認兩平台皆掛載 10 個核心面板（RenderingProfile, Basic, Color/WB, Curve, Presence, ColorGrading, Detail, Geometry, Local, Snapshots）。
  - 驗證兩平台均支援快照工作流程與 A/B 對比模式。
  - 驗證 8 種 Local Adjustment 遮罩類型與 Sidecar v4 統一標準。
- `Tests/PhotoLibraryCoreTests/LibraryPerformanceBudgetTests.swift`:
  - 2 項測試：在 10,000 筆照片索引庫進行分頁載入（50 items）與 deep cursor paging，p95 耗時遠低於 250ms 預算。
  - 驗證評分、旗標、關鍵字與檔名複合搜尋查詢之延遲（<250ms）。
- `Tests/PhotoLibraryCoreTests/RawImmutabilityVerificationTests.swift`:
  - 2 項測試：驗證來源 RAW 檔案在調光、快照、評分變更等整個生命週期中，SHA-256 雜湊與位元完全保持不變（100% 唯讀保護）。
  - 驗證 FAT32 / exFAT 跨檔案系統之安全命名與禁止字元轉換。

### Modified files (documentation)

- `README.md`:
  - 繁體中文使用說明完整更新，詳列 P1 至 P6 完成之全方位專業修圖功能（四通道獨立曲線、風格渲染檔、鏡頭校正、Presence、色調分離、筆刷與離線 AI 前景辨識、去紅眼與透視修正、快照管理與軟體打樣等）。
  - 補充 Mac 與 iPadOS 上的快照操作與 A/B 比較指引。
- `docs/coordination/CURRENT.md`:
  - 記錄 P7 完成狀態與全功能驗證結果。

## Test evidence

- `swift test`：**PASS**（2193 tests executed, 9 skipped, 0 failures, 28.550s）。
- `swift build -Xswiftc -strict-concurrency=complete`：**PASS**（0 warnings, 0 errors）。
- iPad Simulator build：`xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`：**BUILD SUCCEEDED**。
- `swift run LumaHarborDiagnosticsCLI`：**PASS**（4 pass, 0 warning, 0 fail, 3 skipped）。
- `git diff --check`：**PASS**（0 whitespace/merge issues）。
- Privacy scan：**PASS**（無個人絕對路徑、Team ID、UDID 或私密簽章洩漏）。

## Gaps / Not Run Items (Honest Accounting)

- **真機人工視覺驗收（M 系列 iPad 與 Apple Silicon Mac）**：`NOT RUN`（需實體設備連接與螢幕視覺確認）。
- **外部實體儲存空間（APFS / exFAT 實體外接隨身碟與記憶卡插拔）**：`SKIPPED`（CI/開發機無設定實體 `LUMAHARBOR_RAW_FIXTURE_DIR`、`LUMAHARBOR_APFS_TEST_DIR`、`LUMAHARBOR_EXFAT_TEST_DIR`）。
- **發布 ZIP 封裝**：遵照使用者與 spec 約束——**在所有實體硬體人工條件核准前，不封裝對外發布 ZIP 檔案**。
