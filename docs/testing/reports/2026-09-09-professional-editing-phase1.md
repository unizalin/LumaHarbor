# Professional Editing Phase 1 驗證報告

日期：2026-09-09
分支：`codex/open-source-release-prep`

## 已驗證

- `swift test --scratch-path /private/tmp/LumaHarbor-swift-phase1-input --filter 'LibraryBrowserSessionTests/testUpdatePhotoCurationPreservesSelectionAndUpdatesLoadedProjection|PadBatchContractTests|EightLanguageLocalizationGateTests'`：PASS。
- 完整 `swift test`：1,909 tests，9 skipped，0 failures。公開 Xcode 專案已移除本機 Development Team、code-sign identity 與 provisioning profile 設定，原本的 `AppIconAssetContractTests` 失敗已修正。
- `swift build -Xswiftc -strict-concurrency=complete`：PASS。metadata 檔案大小格式化改用無共享狀態的 Foundation API，消除 Swift 6 並行安全警告。
- `xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -sdk iphonesimulator -configuration Debug -derivedDataPath /private/tmp/LumaHarborPad-release-verification build CODE_SIGNING_ALLOWED=NO -quiet`：PASS。
- `git diff --check`：PASS。
- 八語系 localization gate：PASS。
- `README.md` 已更新為繁體中文版，包含 Mac／iPad 安裝、操作、免費簽章限制、SHA-256 驗證與散布流程。
- `.superpowers/` 已加入 `.gitignore`，不會將代理內部工作狀態提交至 Git。

## Mac 發行產物

- 來源提交：`2f8c640`。
- `Scripts/package-mac-release.sh release`：PASS；產生 Apple Silicon `arm64`、macOS 14 以上的 ad-hoc Alpha 版本。
- `dist/LumaHarbor-0.1.0-1.zip`：2,533,072 bytes；ZIP 完整性測試 PASS，無 `._*` AppleDouble 項目。
- SHA-256：`558ae1ef272294087a96f3beabbffb4cfd8f9f477cf2c085c56f6f2dc9d6106a`。
- 從 ZIP 解壓後執行 `codesign --verify --deep --strict`：PASS；使用 macOS `open` 啟動後程序正常存活，完成冒煙測試後關閉。
- 診斷期間曾直接執行 bundle 內的 `Contents/MacOS/LumaHarbor`；該程序在 AppKit／HIServices 註冊階段中止，尚未進入 LumaHarbor 程式碼。此啟動方式不屬於使用者流程，改用 Finder 等效的 LaunchServices `open` 後 PASS，因此未列為產品 crash。
- 此產物未使用 Developer ID，也未經 Apple notarization；僅供本機或明確信任來源的小規模 Alpha 測試。

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
