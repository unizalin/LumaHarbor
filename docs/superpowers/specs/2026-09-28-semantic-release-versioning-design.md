# LumaHarbor 語意版本與發行命名設計

- 日期：2026-09-28
- 狀態：已核准，待 implementation plan
- 適用平台：macOS、iPadOS
- 目前產品版本：`0.1.0`

## 1. 目標

LumaHarbor 的對外版本只使用標準 `MAJOR.MINOR.PATCH`。目前版本名稱是 `LumaHarbor 0.1.0`，不得把 Apple 內部 build number 組成 `0.1.0 (3)`、`0.1.0-3` 或其他對外版本名稱。

Mac 與 iPad 必須使用相同的產品版本。Apple 要求的 build number 仍保留為內部、單調遞增的部署識別，但不屬於產品命名。

## 2. 版本規則

- `MAJOR`：不相容的資料、工作流程或公開契約變更。
- `MINOR`：向後相容的新功能或重要能力階段。
- `PATCH`：向後相容的錯誤修正、效能、穩定性或發行修補。
- 純文件、coordination-only 或不改變產品產物的提交不提升版本。
- 同一個已散布版本需要重新發布時，必須提升 `PATCH`；不得只改 build number 後再次散布同名版本。
- `Alpha`、`Beta`、代理名稱、日期與 Git SHA 可以出現在狀態說明或技術證據中，但不得加入產品版本字串。

## 3. 顯示與中繼資料

| 用途 | 格式 | 目前值 |
| --- | --- | --- |
| 產品名稱 | `LumaHarbor` | `LumaHarbor` |
| 對外版本 | `MAJOR.MINOR.PATCH` | `0.1.0` |
| Mac App | `LumaHarbor.app` | `LumaHarbor.app` |
| Mac 發行壓縮檔 | `LumaHarbor-MAJOR.MINOR.PATCH.zip` | `LumaHarbor-0.1.0.zip` |
| checksum | 與 ZIP 同名再加 `.sha256` | `LumaHarbor-0.1.0.zip.sha256` |
| Apple 內部 build | 正整數，單調遞增 | 目前為 `3` |

`CFBundleShortVersionString` 與 iPad `MARKETING_VERSION` 是對外產品版本；兩者必須一致。`CFBundleVersion` 與 iPad `CURRENT_PROJECT_VERSION` 是內部 build；兩者也必須一致，但只能出現在部署診斷、驗證報告與裝置版本核對中。

技術報告若必須同時記錄兩者，使用「版本 `0.1.0`，內部 build `3`」，不得把 `0.1.0 (3)` 當成產品名稱。

## 4. 發行流程

1. 產品版本推送前，先依變更類型決定新的 `MAJOR.MINOR.PATCH`。
2. 同步更新 Mac `CFBundleShortVersionString` 與 iPad `MARKETING_VERSION`。
3. 同步遞增 Mac `CFBundleVersion` 與 iPad `CURRENT_PROJECT_VERSION`。
4. 從同一個 `origin/main` SHA 建置 Mac 與 iPad。
5. Mac 發行 ZIP 只使用產品版本命名；既有同名產物必須視為衝突，不能靜默覆蓋已散布版本。
6. 依 `AGENTS.md` 與 `SHARED_GIT_WORKFLOW.md` 更新本機 Mac App，並在 iPad 可連線時安裝同版 App。
7. `CURRENT.md` 分開記錄產品版本、內部 build、commit、Mac 狀態與 iPad 狀態。

## 5. 實作範圍

- `Scripts/package-mac-release.sh`：發行檔名改為只含 `MAJOR.MINOR.PATCH`，並對同名版本採 fail-closed 衝突處理。
- `Tests/LumaHarborAppTests/MacReleasePackagingContractTests.swift`：驗證版本檔名不含 build、同名版本不會被靜默覆蓋。
- 新增或擴充版本契約測試：驗證 Mac／iPad 的產品版本與內部 build 各自一致。
- `README.md`、`AGENTS.md`、`docs/coordination/SHARED_GIT_WORKFLOW.md`：統一對外與內部版本用語。
- `docs/coordination/DECISIONS.md`：追加這項跨代理發行決策。
- `docs/coordination/CURRENT.md`：移除把 `(3)` 當成版本名稱的表達方式，改為分欄敘述。

## 6. 不在本次範圍

- 不改 Bundle Identifier、簽章 Team、provisioning 或裝置識別資訊。
- 不加入 prerelease suffix、日期版號、Git SHA 版號或代理專屬版號。
- 不建立 App Store、TestFlight、notarization 或自動發布服務。
- 不因命名調整宣稱功能、Lightroom parity 或 Gate 2 已通過。

## 7. 驗收條件

- Mac 與 iPad 對外版本都是有效且相同的 `x.y.z`。
- Mac 與 iPad 內部 build 都是相同的正整數，且不出現在產品名稱與發行 ZIP 名稱。
- `Scripts/package-mac-release.sh` 產生 `LumaHarbor-0.1.0.zip` 與同名 checksum，不產生 `LumaHarbor-0.1.0-3.zip`。
- 已存在同名發行 ZIP 時，腳本清楚失敗，不覆蓋既有散布產物。
- README 與共用代理規則不再把 `0.1.0 (3)` 當作版本名稱。
- 契約測試、`git diff --check` 與隱私掃描通過。

## 8. 風險與控制

- **同名覆蓋**：移除檔名中的 build 後可能覆蓋舊 ZIP；以 fail-closed 衝突檢查處理，要求先提升 `PATCH`。
- **平台漂移**：Mac 與 iPad 各自保存版本欄位；以自動契約測試鎖定一致。
- **build 誤當版本**：技術紀錄仍需要 build；文件固定使用「產品版本」與「內部 build」兩個欄位。
- **舊版使用者更新**：保留單調遞增 `CFBundleVersion`／`CURRENT_PROJECT_VERSION`，不影響 Apple 的更新與安裝判斷。
