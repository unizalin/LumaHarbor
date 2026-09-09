# Professional Editing Phase 1 驗證報告

日期：2026-09-09
分支：`codex/open-source-release-prep`

## 已驗證

- `swift test --scratch-path /private/tmp/LumaHarbor-swift-phase1-input --filter 'LibraryBrowserSessionTests/testUpdatePhotoCurationPreservesSelectionAndUpdatesLoadedProjection|PadBatchContractTests|EightLanguageLocalizationGateTests'`：PASS。
- 完整 `swift test`：1,916 tests，9 skipped，0 failures。公開 Xcode 專案未加入本機 Development Team、code-sign identity 或 provisioning profile。
- 全新暫存目錄的 `swift build --configuration release -Xswiftc -strict-concurrency=complete`：PASS；已消除 `PhotoExporter` 的 Sendable 預設函式警告。現有 AdjustmentUI／AppKit actor isolation 警告仍列為後續技術債，未造成建置失敗。
- iPad Release Simulator `xcodebuild`（`CODE_SIGNING_ALLOWED=NO`）：BUILD SUCCEEDED，包含 arm64 模擬器輸出。
- `swift test --filter MacReleasePackagingContractTests`：7 tests，0 failures。
- `git diff --check`：PASS。
- 八語系 localization gate：PASS。
- `README.md` 已更新為繁體中文版，包含 Mac／iPad 安裝、操作、免費簽章限制、SHA-256 驗證與散布流程。
- `.superpowers/` 已加入 `.gitignore`，不會將代理內部工作狀態提交至 Git。

## Mac 發行產物

- 來源提交：`8dfeb0f`。
- `Scripts/package-mac-release.sh release`：PASS；產生 Apple Silicon `arm64`、macOS 14 以上的 ad-hoc Alpha 版本。
- `dist/LumaHarbor-0.1.0-2.zip`：2,402,115 bytes；ZIP 完整性測試 PASS，無 `._*` AppleDouble 項目。
- SHA-256：`76d5732298a5d719d44600e80d1fa1ad0d643059fbfb6f20a25b606b36834982`；checksum 只包含檔名，不包含建置目錄。
- App 已攜帶 `LumaHarbor_Localization.bundle` 與 `LumaHarbor_RawProcessingCore.bundle`，後者包含 `CoreImageKernels.metallib`。
- 從 ZIP 解壓到獨立暫存目錄後執行 `codesign --verify --deep --strict`：PASS；使用 macOS `open` 啟動後程序正常存活十秒，完成冒煙測試後關閉。
- App 封裝前、ZIP 解壓後及 checksum 的全檔案私人絕對路徑掃描均 PASS；掃描失敗會中止封裝。
- 此產物未使用 Developer ID，也未經 Apple notarization；僅供本機或明確信任來源的小規模 Alpha 測試。

先前的 `0.1.0 (1)` Alpha 壓縮檔已撤回，不得再散布。舊包缺少 SwiftPM resource bundle，換到另一台 Mac 可能在啟動時找不到多語系資源，且編譯產物可能保留建置環境資訊。

## 本階段功能

- iPad 精確數值輸入、格式化與範圍 clamp。
- Geometry／Local／Preset／Info editor rail，含 histogram 與安全 metadata 顯示。
- 調整值 copy／paste、選取欄位、Geometry／Local opt-in、批次同步與 compound undo。
- JPEG／PNG／HEIC／TIFF 匯出選項、品質、位元深度、尺寸、DPI、EXIF 與碰撞策略；Files exporter 使用實際匯出格式。
- 圖庫多選的 rating、flag、keyword 批次編輯，以及 Info 面板的單張編輯；資料透過 `PhotoIndexStore` 持久化，關鍵字保留顯示大小寫並以 normalized 值比對。
- 隱私：調整剪貼簿不攜帶 rating、flag、keyword、來源 URL 或 metadata；UI 不顯示絕對路徑。

## 尚未完成

- 未在實體 iPad／Mac 真機上做人工視覺驗收；本報告不將其標記為 PASS。
- 完整 RAW fixture、Apple Pencil Pro 手勢、進階 masking、lens profile 與 Phase 2+ 功能不在本 Phase 1 gate。
- 未來若在 Xcode 選擇 Development Team 進行 iPad 真機測試，產生的本機簽章差異仍應留在工作樹，不得提交至公開 release commit。
