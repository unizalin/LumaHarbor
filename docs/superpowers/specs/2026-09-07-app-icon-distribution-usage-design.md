# LumaHarbor App Icon、使用與小範圍分發設計

日期：2026-09-07  
狀態：使用者已核准視覺方向，待實作

## 目標

1. 為 macOS 與 iPadOS App 建立一致、可辨識的 LumaHarbor 圖示。
2. 讓新使用者能依文件完成 Mac ZIP 開啟、照片加入、編輯、復原與匯出。
3. 清楚說明 iPad 版目前可如何安裝、哪些方式可以提供給別人，以及 Mac ZIP 為何不能安裝到 iPad。
4. 保持目前「少量已知測試者、不上架 App Store」的分發前提，不假裝已完成 Developer ID、notarization、TestFlight 或 Ad Hoc provisioning。

## 視覺設計

採用單一品牌主圖，再輸出兩個平台所需資產。

- 主題：港灣地平線結合相機光圈，對應 Luma（光）與 Harbor（港灣）。
- 構圖：中央光圈形成港灣入口，地平線與水面提供方向感；縮到小尺寸時仍保留一個清楚輪廓。
- 色彩：深墨色作底、青綠水面、暖金色光線，避免單一藍紫色調。
- 風格：精緻、安靜、偏專業攝影工具；不使用照片拼貼、文字、字母、細小刻度或過度寫實元素。
- 輸出：1024×1024、不透明 PNG 主圖。iPad 交由系統套用平台遮罩；圖面本身不烘焙透明圓角。
- Mac：由同一主圖產生完整 `.iconset` 尺寸與 `.icns`，保留適合 Dock 顯示的安全留白。
- iPad：建立 `Assets.xcassets/AppIcon.appiconset`，以 1024×1024 universal iOS marketing icon 為主，依目前 Xcode asset catalog 規格宣告。

## 平台接線

### macOS

- 將主圖與產生後的 `.icns` 放在 repository 的公開資產目錄。
- `Scripts/build-app-bundle.sh` 在組裝 `.app` 時複製 `.icns` 到 `Contents/Resources`。
- `Resources/Info.plist` 宣告 `CFBundleIconFile`。
- 產物需通過 `plutil`、`iconutil`／圖檔尺寸檢查、Release build 與 `codesign --verify --deep --strict`。

### iPadOS

- 在 `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp` 對應 target 下新增 asset catalog。
- 更新 `Apps/LumaHarborPad.xcodeproj/project.pbxproj`，把 asset catalog 接入 Resources build phase，並設定 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`。
- 不寫入個人 Development Team、UDID、provisioning profile 或憑證。
- generic iOS Simulator 與 generic iOS unsigned build 必須成功。

## 使用文件

新增一份面向測試者的繁中快速入門，並從現有 alpha 報告與 README 連結：

### Mac 使用流程

1. 驗證 ZIP SHA-256。
2. 解壓並處理未 notarize build 的 Gatekeeper 首次開啟流程。
3. 加入已備份或複製的照片資料夾。
4. 選取 RAW、調整、使用 `⌘Z`／`⇧⌘Z`。
5. 關閉再開啟以確認 sidecar 調整保留。
6. 匯出到新的空白資料夾。
7. 說明 `.lumaharbor` sidecar 與 Application Support 資料位置及移除行為。

### iPad 自用流程

1. Mac 安裝 Xcode，開啟 `Apps/LumaHarborPad.xcodeproj`。
2. 選擇 `LumaHarborPad` scheme 與實體 iPad。
3. 在 Signing & Capabilities 選自己的 Development Team。
4. 讓 iPad 信任開發者模式與該開發簽章，從 Xcode Run 安裝。
5. 在 iPad 內選擇 Files 可存取的照片資料夾進行測試。

### iPad 提供給別人

- Mac ZIP 不能安裝到 iPad。
- 少量外部測試者的推薦方式是 TestFlight；需要 Apple Developer Program、App Store Connect 設定與外部 beta review，但不等於公開上架 App Store。
- Ad Hoc 是替代方案；需要事先收集並註冊每台 iPad 的 UDID、建立 provisioning profile、簽署並輸出 IPA。裝置清單與簽署資料不得進 Git。
- 在沒有 Apple Developer 帳號與簽署材料前，本輪只提供準確文件與可由 Xcode 安裝的專案，不產生不可驗證的 IPA。

## 驗證

- 主圖為 1024×1024、RGBA/RGB、不透明，沒有意外文字或浮水印。
- 所有產生尺寸存在且像素尺寸正確。
- Mac `.icns` 可由 `iconutil` 讀取，Release app 內含圖示並由 Info.plist 指向它。
- Mac app build、`codesign --verify --deep --strict`、ZIP 重建與 `unzip -t` 通過。
- iPad asset catalog 由 Xcode 編譯成功；generic simulator 與 unsigned generic device build通過。
- 現有完整 `swift test` 不受影響。
- `git diff --check` 與 changed-content 隱私／秘密掃描通過。
- 以 Finder／Dock 或 build product 檢查 Mac 圖示非空白；以 iPad Simulator build product 或 asset catalog 編譯結果確認 iPad 圖示接線。

## 不做事項

- 不建立 App Store 商品頁、不送審、不上架。
- 不購買或建立 Apple Developer 憑證。
- 不寫入任何個人 Team ID、UDID 或 provisioning profile。
- 不宣稱目前 Mac build 已 notarize，也不宣稱 iPad App 已可直接提供下載。
- 不改動照片處理、匯出或資料模型功能。

## 成功條件

- Mac 與 iPad target 共用一致的新品牌圖示，兩邊 build 均通過。
- 新測試者能僅依文件理解 Mac 如何使用、iPad 如何自行安裝，以及若要提供 iPad 版給別人需要哪種分發方式。
- 所有分發限制、資料寫入行為與尚未完成的簽署工作均被誠實揭露。
