# LumaHarbor 0.1.0 Alpha 驗測與分發報告

報告日期：2026-09-07  
測試產物：`LumaHarbor-0.1.0-alpha-853b837.zip`  
對應修正 commit：`853b837`  
用途：少量、已知身分測試者的 macOS alpha 測試，不是正式發行版

## 結論

這個 ZIP 可以提供給使用 Apple Silicon Mac、macOS 14 或更新版本的已知測試者。ZIP 完整、解壓後的 App 簽章結構有效，已在實際 App 中完成 RAW 開啟、編輯及實體鍵盤 Undo/Redo 驗證，相關自動化測試也全部通過。

但它只有 ad-hoc 簽章，沒有 Developer ID、Team ID 或 Apple notarization。收件人的 Gatekeeper 很可能阻止第一次直接雙擊；對方必須先確認檔案來源與 SHA-256，再透過 Finder 的「打開」或「系統設定 > 隱私權與安全性 > 仍要打開」明確授權。請勿要求測試者關閉整台 Mac 的 Gatekeeper。

因此，本報告的判定是：

- **可用於小範圍、受信任的 alpha 測試：YES**
- **保證收件人解壓後直接雙擊即可開啟：NO**
- **適合公開提供給一般使用者：NO**
- **已達正式版／production-ready：NO**

## 產物驗證

| 項目 | 結果 |
|---|---|
| ZIP 大小 | 約 2.0 MB |
| ZIP 完整性 | PASS，`unzip -t` 無錯誤 |
| SHA-256 | `50125d3fcf03a12d8535c197aa0bb6f85f7114797816a4155356e7c359518af9` |
| App 版本 | `0.1.0 (1)` |
| Bundle ID | `org.lumaharbor.LumaHarbor` |
| 最低 macOS | macOS 14.0 |
| CPU 架構 | arm64，僅 Apple Silicon |
| 解壓後 `codesign --verify --deep --strict` | PASS |
| 簽章類型 | ad-hoc |
| Team ID | 未設定 |
| Apple notarization | 無 |
| Gatekeeper `spctl` assessment | 未通過；本機回報 Code Signing subsystem error，不能視為已獲 Gatekeeper 接受 |
| ZIP 內容 | 僅 `LumaHarbor.app`，不含 RAW、fixture、資料庫、sidecar 或簽署憑證 |

## 功能與測試結果

### 自動化驗證

- Release app bundle build：PASS。
- Phase 4 focused tests：90 tests，0 failures。
- 完整 `swift test`（帶 RAW/APFS fixture）：1725 tests，0 failures，0 skipped。
- `RawFixtureTests`：9 tests，0 failures。
- Diagnostics：6 pass、1 skipped；skipped 項目是未掛載的 exFAT 測試磁碟。
- `git diff --check`：PASS。
- tracked-file 安全掃描：未發現真實 API key、private key、Team ID、UDID、provisioning profile 或真實私人絕對路徑。

### App 與真人驗證

- 真 Release App 可啟動並開啟 RAW 照片。
- 編輯曝光後，CUA 合成 `⌘Z`／`⇧⌘Z` 可正確復原與重做，且 Undo/Redo 狀態同步更新。
- 使用者在相同修正版以實體鍵盤按 `⌘Z`／`⇧⌘Z`，確認復原與重做都有作用；A11 為 PASS。
- Phase 4 手動清單 A1-A13、B1-B13 均為 PASS；相關 sidecar、截圖與匯出像素證據記錄於 `PHASE4_MANUAL_CHECKLIST.md`。

## 尚未完成與相容性限制

- 尚未在另一台獨立的 Apple Silicon Mac 上做「收到 ZIP、下載、解壓、首次開啟」完整流程，因此不能保證每台 Mac 的安全提示完全相同。
- 不支援 Intel Mac，因為執行檔只有 arm64 架構。
- 完整 MVP acceptance 尚未完成：目前缺少已掛載的 exFAT 測試目錄；這是測試環境阻塞，不是已知產品 failure。
- 六個新增語言仍是機器輔助翻譯，未經母語審校，也未完成所有視窗的長字串截斷檢查。
- iPad hands-on checklist 尚未執行；本 ZIP 只包含 Mac App。
- 尚未完成 Developer ID 簽章、Hardened Runtime、notarization 或 stapling。
- Alpha 軟體不應直接用在唯一一份照片資料上。

## 給測試者的檔案

請一起提供：

1. `LumaHarbor-0.1.0-alpha-853b837.zip`
2. 本報告
3. SHA-256：`50125d3fcf03a12d8535c197aa0bb6f85f7114797816a4155356e7c359518af9`

不要提供私人 RAW fixture、真實 sidecar、Application Support 資料庫、憑證、provisioning profile 或其他使用者的本機資料。

## 測試者開啟步驟

1. 確認 Mac 是 Apple Silicon，系統為 macOS 14 或更新版本。
2. 下載 ZIP 後，在 Terminal 驗證：

   ```sh
   shasum -a 256 ~/Downloads/LumaHarbor-0.1.0-alpha-853b837.zip
   ```

3. 確認結果與本報告的 SHA-256 完全一致，再解壓縮。
4. 第一次先雙擊 `LumaHarbor.app`。
5. 若 macOS 因無法驗證開發者而阻止開啟，確認檔案來源可信後，可在 Finder 對 App 按右鍵並選「打開」。若仍被阻擋，先嘗試開啟一次，再前往「系統設定 > 隱私權與安全性」，在安全性區域選擇「仍要打開」。
6. 不要執行 `spctl --master-disable`，也不要全域關閉 Gatekeeper。
7. 使用複製或已有完整備份的照片資料夾測試。

## 資料行為提醒

- LumaHarbor 不會直接改寫 RAW 原檔。
- 對可寫入的照片資料夾，App 可能在旁邊建立 `.lumaharbor` sidecar 資料。
- 索引、bookmark、縮圖、preset 與 app-copy 文件會存放在使用者的 Application Support。
- 移除 App 不會自動刪除上述資料。
- 匯出時請選擇新的空白資料夾，避免和原始照片混在一起。

## 建議回報格式

```text
Mac 型號／晶片：
macOS 版本：
是否能開啟 App：
是否出現 Gatekeeper 訊息：
測試的 RAW 相機型號：
匯出格式與結果：
問題重現步驟：
錯誤訊息或截圖：
```

回報時請遮蔽私人姓名、完整本機路徑、照片內容、磁碟名稱與其他敏感資料。

## 正式直接分發前的必要工作

若希望一般使用者下載後能以正常的 Gatekeeper 流程開啟，而不需要手動「仍要打開」，應加入 Apple Developer Program，使用 `Developer ID Application` 憑證與 Hardened Runtime 簽署，提交 Apple notarization 並 staple ticket，再於另一台乾淨 Mac 重跑下載、解壓與首次開啟測試。這不要求把 App 上架 Mac App Store。

參考：

- [Apple Developer: Signing Mac Software with Developer ID](https://developer.apple.com/developer-id/)
- [Apple Developer: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple Support: Open a Mac app from an unknown developer](https://support.apple.com/guide/mac-help/mh40616/mac)

