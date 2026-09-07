# LumaHarbor 快速入門（繁體中文）

這份文件是給第一次拿到 LumaHarbor 的人看的簡短上手指南，涵蓋 Mac 與 iPad 兩種平台。詳細背景與完整測試流程請見 [`SMALL_GROUP_ALPHA.md`](SMALL_GROUP_ALPHA.md)、[`TESTER_GUIDE.md`](TESTER_GUIDE.md) 與 [iPad Xcode runbook](../../development/ipad-xcode-runbook.md)。

> LumaHarbor 目前是 pre-release alpha 軟體。請一律使用複製或已完整備份的照片資料夾測試，不要拿唯一一份照片原檔冒險。

## Mac：第一次開啟

1. 下載 ZIP 後，先在 Terminal 用 `shasum -a 256` 驗證 SHA-256 是否和發布者提供的值完全一致，再解壓縮。SHA-256 不符就不要開啟，改向發布者確認。
2. 這是 ad-hoc 簽章的開發用 build，沒有 Developer ID 也沒有 Apple notarization，macOS 的 Gatekeeper 很可能在第一次雙擊時直接阻擋。
3. 確認來源可信之後，可以：
   - 在 Finder 對 `LumaHarbor.app` 按右鍵（或 Control-點擊），選「打開」；或
   - 若仍被擋下，先嘗試開啟一次，再到「系統設定 > 隱私權與安全性」，在安全性區塊選「仍要打開」。
4. 不要執行 `spctl --master-disable`，也不要為了這個 build 關閉整台 Mac 的 Gatekeeper。

## Mac：加入照片並開始編輯

1. 準備一份**複製或已完整備份**的照片資料夾，不要直接指向唯一一份原始照片。
2. 在 App 裡加入該資料夾，等待索引完成。
3. LumaHarbor 只讀取你明確選擇的資料夾，RAW 原始檔案不會被改寫。
4. 所有調整都是非破壞式編輯：曝光、對比、色彩、細節、效果、幾何、局部遮罩、漸層、修復筆刷等調整都不會動到原始像素資料。
5. 編輯時可以用 `⌘Z` 復原、`⇧⌘Z` 重做，確認每一步都可以往回走。
6. 調整完成後，關閉 App 再重新開啟同一張照片，確認編輯結果有正確保留（自動儲存生效）。

## Mac：匯出照片

1. 匯出前，先建立一個**新的空白資料夾**，不要匯出到原始照片所在的資料夾，避免和來源檔案混在一起。
2. 依需求選擇尺寸、位元深度、metadata、檔名規則、遇到同名檔案時的處理方式、DPI 與浮水印文字等選項。
3. 匯出完成後，建議抽查匯出結果的尺寸與 metadata 是否符合預期。

## iPad：從 Xcode 安裝到自己的 iPad

LumaHarbor 的 iPad App 已經存在，並且在實體 iPad 上完成過安裝、啟動與多來源編輯的手動驗證。要在自己的 iPad 上安裝開發版：

1. 用 Xcode 開啟穩定的專案進入點：

   ```text
   Apps/LumaHarborPad.xcodeproj
   ```

   不要用 `Apps/LumaHarborPad.swiftpm/Package.swift`；那是 Xcode 自動產生、可能被 Xcode UI 改寫的 App Playground manifest，改寫後會遺失套件相依關係並出現找不到模組的錯誤。
2. 選擇 `LumaHarborPad` scheme。
3. 選擇你自己的實體 iPad 作為執行目的地（不是模擬器）。
4. 在 Signing & Capabilities 分頁選擇**你自己的** Development Team。這是本機簽署設定，不能提交進 Git。
5. 按 Run，等待建置、簽署、安裝並在 iPad 上啟動。

更完整的設定步驟與疑難排解，見 [iPad Xcode runbook](../../development/ipad-xcode-runbook.md)。

## iPad：提供給其他測試者

**Mac ZIP 不能安裝到 iPad**——那是 macOS App bundle，架構與簽署方式都跟 iOS/iPadOS App 不同，不能直接拿去裝在 iPad 上。要讓別人在自己的 iPad 上使用 LumaHarbor，目前有三條路：

1. **TestFlight**：需要付費的 Apple Developer 帳號。不需要公開上架 App Store，但第一個外部測試 build 需要通過 Apple 的 beta review，且每個 build 有效期有限。
2. **Ad Hoc 分發**：需要先收集每一台受測 iPad 的裝置 UDID，並針對這些 UDID 重新產生 provisioning profile；裝置清單變動時要重新產生。Development Team、憑證、profile、UDID 都不能放進 Git。
3. **請對方自行用 Xcode 簽署**：把原始碼或專案交給對方，由對方在自己的 Mac 上用**自己的** Apple ID 開啟 `Apps/LumaHarborPad.xcodeproj`、選擇自己的 Development Team 後自行建置安裝。這條路不需要你的簽署身分，但對方需要自己有 Xcode 與 Apple ID。

目前**沒有**現成的 IPA 檔案或任何公開下載連結可以直接提供給測試者；上面三條路都需要至少一方（你或對方）用 Xcode 或 App Store Connect 走過簽署流程。

## 資料安全與移除

- LumaHarbor 不會直接改寫 RAW 原始檔案。
- 對可寫入的照片資料夾，App 可能會在旁邊建立 `.lumaharbor` sidecar 檔案，用來儲存非破壞式編輯紀錄。
- 索引、書籤、縮圖、預設集與 app-copy 文件會存放在使用者的 Application Support 容器內。
- 移除 App（不論 Mac 或 iPad）**不會**自動刪除上述 `.lumaharbor` sidecar 或 Application Support 裡的資料，需要的話要自行清除。
- 這些本機記錄可能包含檔名與 metadata，LumaHarbor 本身不會另外加密這些檔案。
- 不要提供私人 RAW 樣本、真實 sidecar、Application Support 資料庫、憑證、provisioning profile 或其他使用者的本機資料給第三方。
