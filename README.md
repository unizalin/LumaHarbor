# LumaHarbor

LumaHarbor 是一套開放原始碼、原生且非破壞式的 macOS／iPadOS RAW 相片編輯器。專案以 SwiftUI、Core Image、CryptoKit 與 SQLite 獨立實作，屬於參考 AwayPhotoRawEditor 功能方向的二次開發專案。

> **目前狀態：**發布前 Alpha。自動建置與測試已涵蓋主要流程，但部分 Mac、外接磁碟、翻譯及 iPad 人工操作仍需驗收。測試時請使用相片副本或已有完整備份的圖庫。

## 功能重點

- 直接瀏覽 RAW 資料夾與外接磁碟，不必先匯入，也不修改來源檔案。
- 提供曝光、色彩、細節、效果、幾何、局部遮色片、漸層、修復與仿製等非破壞式調整。
- 儲存可攜式 sidecar、建立虛擬副本，並管理可重複使用的預設集。
- 支援單張及批次匯出，可設定 JPEG／PNG／HEIC／TIFF、品質、位元深度、尺寸、DPI、EXIF、中繼資料、檔名與檔案衝突處理。
- iPad 可同時管理多個來源；來源離線時仍保留索引與已快取縮圖，重新接上後可驗證身分並連回原來源。
- iPad 採自適應工作區，支援觸控多選、評分、旗標、關鍵字、批次調整、複合復原、資訊面板與工具列。
- iPad 可精確輸入調整數值、複製／貼上調整、套用預設集，並匯出到「檔案」或「照片」。
- 介面支援英文、繁體中文、簡體中文、日文、韓文、德文、法文與西班牙文。
- 所有編輯在本機進行；發行目標不含分析追蹤、帳號系統、雲端後端或 App 層級網路客戶端。

可開啟的 RAW 格式依 Apple 平台的 `CIRAWFilter` 支援範圍而定。專案以 Sony `.ARW` 作為必要的真實素材驗測格式。

## 系統需求

- macOS 14 以上
- 與 Xcode 版本相符的 Command Line Tools
- Xcode Metal Toolchain（`xcodebuild -downloadComponent MetalToolchain`）
- iPad 版需要 iOS／iPadOS 17 以上

## 在 macOS 執行

從專案根目錄執行：

```sh
swift run LumaHarbor
```

若要產生本機 `.app`：

```sh
Scripts/build-app-bundle.sh release
open build/LumaHarbor.app
```

這個指令會建立 ad-hoc 簽章的開發版本，適合本機測試，不是已受 Apple 信任的公開發行版本。分享前請先閱讀[小規模 Alpha 散布指南](docs/testing/beta/SMALL_GROUP_ALPHA.md)。

若要建立可重複產生的 Mac 發行壓縮檔：

```sh
Scripts/package-mac-release.sh release
```

產物會寫入 `dist/`，包含帶版本號的 ZIP 與 SHA-256 checksum。沒有設定簽章環境變數時，腳本會產生 ad-hoc 版本，只適合自己使用或提供給明確信任來源的小規模測試者。

若未來要公開下載並讓 macOS 正常辨識開發者，需要安裝 Developer ID Application 憑證與 `notarytool` Keychain profile，再執行：

```sh
LUMAHARBOR_SIGNING_IDENTITY='Developer ID Application: ...' \
LUMAHARBOR_NOTARY_PROFILE='LumaHarbor-notary' \
Scripts/package-mac-release.sh release
```

簽章身分及 notarization 認證資料只保留在本機，不得寫入 Git。

### 安裝別人提供的 Mac 壓縮檔

1. 從同一個發行位置下載 ZIP 與同名 `.sha256` 檔。
2. 開啟前驗證 ZIP：

   ```sh
   shasum -a 256 LumaHarbor-<version>-<build>.zip
   ```

3. 將終端機算出的結果與 `.sha256` 檔內容比對；相同才繼續。
4. 解壓縮 ZIP，將 `LumaHarbor.app` 移到「應用程式」後開啟。
5. ad-hoc Alpha 版本第一次啟動時，請在 Finder 對 App 按右鍵並選「打開」。若仍被阻擋，確認來源及 checksum 後，到「系統設定 > 隱私權與安全性」選「仍要打開」。

SHA-256 只用來核對檔案是否完整，使用者不需要把它輸入 LumaHarbor。請勿要求使用者停用整台 Mac 的 Gatekeeper；完成 Developer ID 簽章與 notarization 的版本不需要上述 Alpha 例外操作。

## 在 iPad 執行

1. 使用 Xcode 開啟 `Apps/LumaHarborPad.xcodeproj`。
2. 選擇 `LumaHarborPad` scheme。
3. 模擬器可直接建置；真實 iPad 請在 **Signing & Capabilities** 選擇自己的 Development Team。
4. 將 iPad 連接到 Mac、解鎖並信任這台電腦，再選擇該 iPad 後按 **Run**。

個人的 Development Team 與 provisioning 設定不得提交到公開 Git。完整設定請參考 [iPad Xcode 操作手冊](docs/development/ipad-xcode-runbook.md)，Mac 與 iPad 的快速流程可參考[繁體中文快速入門](docs/testing/beta/QUICK_START_ZH-HANT.md)。

免費 Apple ID 可以將 App 安裝到自己的 iPad，但憑證通常需要定期由 Xcode 重新簽署。若要交給另一個人免費測試，對方需要取得原始碼，並在自己的 Mac／Xcode 使用自己的 Apple ID 簽章安裝；Mac 版 ZIP 不能直接安裝到 iPad。TestFlight 與正式 Ad Hoc 散布需要 Apple Developer Program。

## 使用方式

### macOS

1. 準備相片副本或已有完整備份的資料夾。Alpha 測試請勿使用唯一一份圖庫。
2. 啟動 LumaHarbor，選擇 **Add Photo Folder…**。
3. 等待索引完成，再從圖庫開啟 RAW 相片。
4. 調整曝光、色彩、細節、效果、幾何或局部調整，也可切換原圖／編輯後比較模式。
5. 使用 **Save Adjustments**（`⌘S`）儲存非破壞式編輯。原始 RAW 不會被改寫；可寫入的來源資料夾可能新增 `.lumaharbor` sidecar。
6. 單張相片使用 **Export JPEG…**，多選相片使用 **Export Selected Photos…**。建議匯出到另一個資料夾，不要與來源 RAW 混放。
7. 圖庫可依評分、旗標、是否已編輯、關鍵字、相機、鏡頭、格式及拍攝日期篩選；需要批次處理時先進入選取模式。

預設集可從目前相片建立，也可匯入或匯出 `.xmp`／`.lhpreset`，並支援預設集備份及還原。

### iPadOS

1. 在圖庫加入 APFS、exFAT 或「檔案」提供者中的 RAW 資料夾。
2. 使用側邊欄切換來源、App 副本或最近編輯，並以搜尋、排序、評分、旗標及關鍵字縮小結果。
3. 點選相片進入編輯器。工具列可切換 Adjust、Geometry、Local、Preset 與 Info；視窗寬度改變時會自動調整為側邊 inspector 或底部面板。
4. Adjust 可輸入精確數值；需要套用到其他相片時，可複製／貼上調整或對多選相片執行批次同步，再使用複合復原撤銷整批操作。
5. Info 可檢視 histogram 與安全中繼資料，也可修改單張相片的評分、旗標及關鍵字；圖庫多選列提供同樣的批次整理功能。
6. Export 可設定 JPEG／PNG／HEIC／TIFF、品質、位元深度、尺寸、DPI、EXIF 與同名檔案處理，再儲存到「檔案」或「照片」。
7. 外接來源離線時保留索引與快取；重新接上後使用重新連接功能，App 會驗證來源身分，避免誤接到同名資料夾。

完整的裝置設定與驗測順序請參考 [iPad Xcode 操作手冊](docs/development/ipad-xcode-runbook.md)，以及[測試者指南](docs/testing/beta/TESTER_GUIDE.md)。

## 分享給其他人

Mac 版可以分享壓縮檔；iPad 版不能直接把 Mac ZIP 拿去安裝。完成驗測後，在專案根目錄執行：

```sh
Scripts/package-mac-release.sh release
```

產物會放在 `dist/`：

- `LumaHarbor-<version>-<build>.zip`
- 同名的 `.zip.sha256`

將 ZIP、checksum 與對應的測試 commit 一起提供。對方只需要驗證 checksum、解壓縮並開啟 `LumaHarbor.app`；ad-hoc Alpha 第一次啟動可能要在 Finder 按右鍵選「打開」，或到「系統設定 > 隱私權與安全性」選「仍要打開」。不需要提供或匯出你的 Apple 開發憑證，也不要要求對方關閉 Gatekeeper。

沒有付費 Apple Developer 帳號仍可分享 ad-hoc Mac 版本，但 macOS 會顯示未辨識開發者警告。要讓公開下載版本一般雙擊即可開啟，才需要 Developer ID 簽章與 Apple notarization。

## 開發者驗證

```sh
swift build
swift test
swift run LumaHarborDiagnosticsCLI
swift run LumaHarborDiagnosticsCLI --json
```

需要真實 RAW、外接磁碟或實體 iPad 的驗收不包含在一般單元測試內。最新證據與尚未執行的人工 gate 記錄於 [`docs/coordination/CURRENT.md`](docs/coordination/CURRENT.md)。

## 目前限制

- 目前仍是發布前 Alpha，請使用相片副本或已有完整備份的圖庫。
- 預設 Mac App 與 ZIP 使用 ad-hoc 簽章；公開下載版本應改用 Developer ID 簽章與 notarization。
- 目前預先打包的 Mac 版本為 Apple Silicon（`arm64`），需要 macOS 14 以上；從原始碼建置時會依建置主機架構產生。
- iPad 真機需要使用者自己的 Development Team 簽章；外部測試者需使用自己的 Xcode 簽章，或由付費開發者透過 TestFlight／Ad Hoc 散布。
- 日文、韓文、簡體中文、德文、法文與西班牙文含機器輔助翻譯，正式發布前仍需母語使用者複核。
- 部分 iPad 旋轉、Stage Manager、Apple Pencil Pro 與進階遮色片仍需後續人工或功能驗收。

## 資料與隱私

LumaHarbor 只讀取使用者明確選擇的資料夾。依使用流程不同，App 可能在來源相片旁儲存 `.lumaharbor` sidecar，並在使用者的 Application Support 容器保存索引、bookmark、縮圖、預設集與 App 副本。這些本機資料可能包含檔名與中繼資料，LumaHarbor 不會再額外加密。

來源 RAW 應保持不變。若發現涉及安全或隱私的問題，請依 [`SECURITY.md`](SECURITY.md) 的方式回報，不要直接公開在 Issue。

## 設計與開發文件

Mac MVP 設計位於 [`docs/superpowers/specs/2026-08-13-mac-first-mvp-design.md`](docs/superpowers/specs/2026-08-13-mac-first-mvp-design.md)。iPad 多來源設計與實作計畫位於 [`docs/superpowers/specs/2026-08-26-ipad-multi-source-photo-library-design.md`](docs/superpowers/specs/2026-08-26-ipad-multi-source-photo-library-design.md)及 [`docs/superpowers/plans/2026-08-26-ipad-multi-source-photo-library.md`](docs/superpowers/plans/2026-08-26-ipad-multi-source-photo-library.md)。專業修圖後續規劃位於 [`docs/superpowers/specs/2026-09-09-professional-editing-roadmap-design.md`](docs/superpowers/specs/2026-09-09-professional-editing-roadmap-design.md)。

貢獻程式碼時必須維持 RAW 不可變性、發行目標不依賴第三方套件、使用者畫面不顯示私人路徑，並明確區分自動化 `PASS`、素材不足的 `SKIPPED` 與硬體尚未驗證的 `NOT RUN`。

## 授權

LumaHarbor 以 [MIT License](LICENSE) 授權。

## 原始專案標示與二次開發

LumaHarbor 是參考 [AwayPhotoRawEditor](https://github.com/awaysu/AwayPhotoRawEditor) 功能方向，為 macOS／iPadOS 重新獨立實作的二次開發專案。

- **原始專案：**[AwayPhotoRawEditor](https://github.com/awaysu/AwayPhotoRawEditor)
- **原作者：**[Awaysu](https://github.com/awaysu)
- **原始專案授權：**原始儲存庫標示為 BSD 3-Clause

重新散布 LumaHarbor 時請保留上述標示。LumaHarbor 與 AwayPhotoRawEditor 或其作者沒有隸屬或背書關係；本儲存庫不重新散布 AwayPhotoRawEditor 的原始碼、圖稿、圖示或介面素材。LumaHarbor 自行實作的程式碼仍依 [MIT License](LICENSE) 提供。
