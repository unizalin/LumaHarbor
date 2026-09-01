# LumaHarbor iPad 多來源照片圖庫設計

日期：2026-08-26

狀態：產品設計已確認，尚未開始實作

基準版本：`114b1f6`（`main`，Task 7 adaptive iPad workspace 已整合）

## 1. 目的

目前 iPad App 已能從 Files 或外接來源開啟單張 RAW、選擇原地編輯或複製到 iPad、使用十個基本調整並非破壞式自動保存。下一階段要把這條單張垂直切片擴充成可日常使用的多照片圖庫：使用者能授權多個資料夾或外接磁碟，從同一個 iPad 圖庫增量瀏覽、搜尋及開啟照片；來源離線時仍看得到索引與快取縮圖，重新連結後可繼續工作。

對標參考：Awaysu 的 [AwayPhotoRawEditor](https://github.com/awaysu/AwayPhotoRawEditor) 作為功能完整度與驗測清單的產品參考，重點是「直接瀏覽 RAW、非破壞式編輯、局部/進階調整、批次工作流、風格檔、匯出與清楚等待狀態」這些使用者可見能力。LumaHarbor 仍是獨立 Swift／SwiftUI／Core Image 實作；不得移植 AwayPhotoRawEditor 的 C#、.NET、WinForms、LibRaw 綁定程式碼、UI、圖示或素材。既有閱讀筆記見 `docs/reference/awayphotoraweditor-design-notes.md` 與 `docs/reference/next-phase-scope-notes.md`。

本設計只涵蓋多來源瀏覽基礎。它不宣稱完成評分、相簿、批次操作、Preset／XMP 圖庫 UI、完整匯出或進階調色。

## 2. 已驗證的現況

| 能力 | 現況 | 主要位置 |
|---|---|---|
| 多個授權資料夾 | core 已能保存與恢復多個 `LibraryFolder`，Mac UI 主要以單一選取來源查詢 | `Sources/PhotoLibraryCore/Model/LibraryFolder.swift`、`Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift` |
| 增量掃描 | 已有 lossless bounded pipeline、generation 防晚到寫入與分批索引 | `Sources/PhotoLibraryCore/Scanning/FolderScanner.swift`、`Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift` |
| 本機索引 | SQLite schema v1 已保存 library、photo、metadata、status 與 `hasEdits` | `Sources/PhotoLibraryCore/Index/PhotoIndexStore.swift` |
| 縮圖快取 | 已有可刪除、可重建、容量受限且採 LRU 的快取 | `Sources/PhotoLibraryCore/Cache/DiskCache.swift`、`Sources/PhotoLibraryCore/Cache/ThumbnailProvider.swift` |
| 來源恢復 | 已有 security-scoped bookmark、stale bookmark refresh 與 relink resolver | `Sources/PhotoLibraryCore/Access/`、`Sources/PhotoLibraryCore/Scanning/RelinkResolver.swift` |
| Mac 圖庫 | 已有側欄、網格、filmstrip 與 flush-before-selection 狀態機 | `Sources/LumaHarborApp/Views/`、`Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift` |
| iPad App | 目前是單張 `Open RAW…` 流程，尚無圖庫 model、來源側欄或照片網格 | `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadRootView.swift` |
| iPad 編輯 | 已有 `PadEditorModel`、既有 `EditorSession`、原地／App 副本與自適應 workspace | `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/`、`Sources/EditorCore/` |

本功能應擴充既有 core，不建立 iPad 專用的第二套掃描、索引、快取或來源身份邏輯。

## 3. 已確認的產品決策

1. 一個圖庫聚合多個已授權資料夾、Files provider 來源、外接磁碟與 iPad App 內儲存。
2. 橫向與寬版使用常駐來源側欄；直向與窄版將同一側欄收成可叫出的來源面板。
3. 第一版優先完成可靠瀏覽：來源／資料夾、所有照片、最近編輯、縮圖、檔名搜尋、日期／檔名排序。
4. 圖庫列出 Apple `CIRAWFilter` 可解碼的 RAW；Sony `.ARW` 是必要驗收格式。
5. 外接來源離線時保留索引與快取縮圖，但不能編輯或匯出。離線編輯使用既有「複製到此 iPad」明確建立 App 副本。
6. RAW 原檔永不修改。移除來源也不能刪除 RAW、`.lumaharbor`、sidecar 或外接磁碟上的任何內容。
7. Mac 與 iPad 共用 `PhotoLibraryCore`；本階段不重做 Mac UI。

## 4. 使用者流程

### 4.1 首次使用與加入來源

1. 圖庫空狀態顯示主要動作「加入來源」。
2. 使用者透過 Files picker 選擇一個資料夾。單檔選擇仍保留在編輯器的「開啟 RAW」流程，不當成圖庫來源。
3. App 建立持久授權、確認來源身份、在本機 registry 與 SQLite 寫入來源，再開始掃描。
4. 已完成索引的 batch 立即出現在網格；使用者不必等待整個來源掃描完。
5. 重複加入同一個可驗證來源時聚焦既有來源，不建立副本。身份無法確定時要求使用者確認，不靠名稱或路徑猜測。
6. 若新來源與已加入來源能被可靠判定為父子資料夾，拒絕加入並要求選擇不重疊的根目錄，避免同一檔案被掃描兩次。不同來源中內容相同的 RAW 視為不同資產，不依 fingerprint 自動去重。

### 4.2 瀏覽與編輯

- 側欄固定提供「所有照片」、「最近編輯」、「iPad 內儲存」，下方列出每個來源及其狀態。
- 選取來源後可展開其資料夾階層；資料夾只作為查詢條件，不搬動磁碟內容。
- 「所有照片」跨所有來源聚合；離線來源的已索引照片仍包含在結果中。
- 點擊可用照片後交給既有 `PadEditorModel`／`EditorSession`。返回時恢復原查詢、排序、選取與捲動 anchor。
- 掃描未完成時也能開啟已索引照片；同一照片的選取與離開仍遵守既有 flush-before-transition 契約。

### 4.3 離線、重新授權與移除

- 來源離線：保留來源、索引與已快取縮圖；禁止需要原檔的開啟、完整預覽、編輯與匯出。
- bookmark 失效：來源改成 `needsAuthorization`，提供「重新授權」。
- 重新授權／重新連結：新選擇必須通過 §7 的身份驗證才接回原 `LibraryID`。
- 移除來源：先顯示只會移除本機授權、索引與快取；完成後不對來源根目錄執行任何刪除。

## 5. 資訊架構與介面

### 5.1 自適應容器

- regular width：`NavigationSplitView` 類型的常駐來源側欄加主照片網格。
- compact width：同一份來源內容由 toolbar button 開啟 drawer／sheet；選取後關閉並回到網格。
- 旋轉、Split View 與 Stage Manager 尺寸切換不得重建查詢或清除選取。

### 5.2 側欄

順序固定如下：

1. 所有照片
2. 最近編輯
3. iPad 內儲存
4. 來源清單（依使用者顯示名稱本地化排序）

每個來源顯示名稱、照片數、連線狀態（`ready／readOnly／offline／needsAuthorization`）及獨立掃描狀態（`idle／queued／scanning／partialFailure`）。來源可展開相對資料夾樹；私人絕對路徑不作為一般 UI label。

### 5.3 網格與工具列

- 使用 lazy／virtualized grid；資料由固定大小 page 供應，不持有全部查詢結果。
- toolbar 提供加入來源、重新掃描、搜尋、排序與縮圖尺寸。
- 支援排序：拍攝時間新到舊、拍攝時間舊到新、檔名 A–Z、檔名 Z–A。
- 搜尋採「檔名包含」語意，比對前對檔名與 query 做 NFC 正規化及 locale-independent case folding；`%`、`_` 與 escape 字元都當一般文字，不得改變 SQL pattern。第一版不搜尋 EXIF、資料夾或 sidecar 內容。
- 縮圖先顯示中性 placeholder，再讀快取或背景解碼。狀態與編輯 badge 必須有文字／符號與 VoiceOver label，不能只靠顏色。
- 第一版只允許單一選取，不顯示評分、旗標、色標或批次操作。

## 6. Core 架構與元件邊界

```text
Files／外接 SSD／App 儲存
            ↓
      PhotoLibraryService actor
      ├─ bookmark／source registry
      ├─ multi-source scan coordinator
      ├─ FolderScanner bounded pipeline
      ├─ PhotoIndexStore schema v2
      └─ ThumbnailProvider + DiskCache
            ↓ paged query + events
    LibraryBrowserSession @MainActor
      ├─ sidebar selection
      ├─ query generation
      ├─ page window／scroll anchor
      └─ per-source progress
            ↓ iPad typealias／view adapter
       PadLibraryModel
            ↓ selected PhotoDocument
     PadEditorModel／EditorSession
```

### 6.1 `PhotoLibraryCore`

- 是來源、掃描、索引、縮圖與查詢的唯一權威。
- 不依賴 SwiftUI、UIKit、AppKit、PhotosUI 或 Files picker。
- 平台 shell 負責取得 URL；core 負責 bookmark、identity、狀態與資料操作。
- 現有 actor isolation、scan generation、transaction 與 bounded backpressure 契約不得放寬。

### 6.2 `LibraryBrowserSession` 與 `PadLibraryModel`

- 可測的狀態機新增於 root package 的 `EditorCore`，命名為 `LibraryBrowserSession` 並標記 `@MainActor`；這延續既有 `PhotoDocumentEditor` 的邊界，讓 `swift test` 能真正執行 generation、paging 與 selection tests。
- iPad App target 只用 `typealias PadLibraryModel = LibraryBrowserSession` 保留平台名稱，並在 composition root 注入 production dependencies；不得把另一份狀態機複製到 nested app package。
- 持有 UI query state，不持有 SQLite handle、security scope 或解碼器。
- 查詢變更遞增 generation；任何舊 page、舊縮圖或舊 scan event 晚到時不得覆寫目前畫面。
- 導航到 editor 前保存 grid restoration state；editor 返回後以 `PhotoID` 為 anchor 恢復，不依賴可能已改變的整數 offset。

### 6.3 與既有編輯器整合

- 圖庫不得複製 `PhotoDocumentStore`、autosave、preview scheduling 或 adjustments state。
- 圖庫把來源與 `PhotoAsset` 解析成既有 `PhotoDocument`，再交給 `PadEditorModel`。
- 來源離線或唯讀限制必須在 core command 邊界再次驗證，不能只靠按鈕 disabled。

## 7. 來源模型與身份驗證

`LibraryFolder` 沿用為公開來源模型，新增：

```swift
public enum LibrarySourceKind: String, Codable, Sendable {
    case externalFolder
    case filesProvider
    case appStorage
}

public enum LibraryConnectionState: String, Codable, Sendable {
    case ready
    case readOnly
    case offline
    case needsAuthorization
}

public enum LibraryScanState: String, Codable, Sendable {
    case idle
    case queued
    case scanning
    case partialFailure
}
```

`LibraryFolder` 增加 `sourceKind`、`connectionState` 與 `scanState`；連線能力與最近掃描結果不得塞進同一個 enum，`partialFailure` 不能意外停用仍在線且可寫的來源。`rootURL` 只存在 runtime model，不成為可攜身份。現有 `isOnline`／`isWritable` 在遷移期間可保留為 computed compatibility properties，所有新邏輯改讀 `connectionState`。SQLite 只持久化 `idle` 或 `partialFailure`；App 重啟時把中斷留下的 `queued`／`scanning` 正規化為 `idle`。

身份優先序：

1. 可讀取的 `.lumaharbor/library.json` 之 `LibraryID`。
2. 已保存 bookmark 解析後取得的 file resource identifier、volume identifier 與既有 `LibraryID`。
3. 唯讀／provider 無穩定 identifier 時，使用本機保存的 bookmark identity 加 bounded root fingerprint；只用於要求使用者確認，不能自動宣稱同一來源。

同名磁碟、同一 `lastKnownPath` 或相同資料夾名稱永遠不足以自動接回。身份衝突時維持原來源離線，讓使用者取消、加入為新來源或選擇其他位置；不得覆蓋既有 sidecar。

## 8. SQLite schema v2 與查詢契約

本機 index 是可刪除、可重建資料，不成為編輯或來源身份的唯一權威。schema v1 升級到 v2 必須在單一 transaction 內完成；失敗時保留舊資料庫並回報可重建錯誤，不留下半套 schema。

### 8.1 欄位與索引

`library` 新增：

- `source_kind TEXT NOT NULL`
- `connection_state TEXT NOT NULL`
- `scan_state TEXT NOT NULL`

`photo` 新增：

- `filename_normalized TEXT NOT NULL`
- `relative_directory TEXT NOT NULL`
- `last_edit_at REAL NULL`

新增索引：

- `(capture_date DESC, photo_id)`：所有照片穩定分頁
- `(library_id, capture_date DESC, photo_id)`：單一來源
- `(library_id, relative_directory, capture_date DESC, photo_id)`：資料夾
- `(filename_normalized, photo_id)`：檔名搜尋
- `(last_edit_at DESC, photo_id) WHERE last_edit_at IS NOT NULL`：最近編輯

`last_edit_at` 是 sidecar `modifiedAt` 的可重建投影。儲存編輯成功後立即更新；重掃時由 sidecar 重新建立。neutral adjustments 對應 `has_edits = 0` 與 `last_edit_at = NULL`。

### 8.2 查詢介面

```swift
public enum LibraryScope: Sendable, Equatable {
    case all
    case source(LibraryID)
    case folder(libraryID: LibraryID, relativePath: String)
    case appStorage
    case recentlyEdited
}

public enum PhotoSort: Sendable, Equatable {
    case captureDateDescending
    case captureDateAscending
    case filenameAscending
    case filenameDescending
}

public struct LibraryQuery: Sendable, Equatable {
    public var scope: LibraryScope
    public var filenameSearch: String?
    public var sort: PhotoSort
}

public struct PhotoPage: Sendable, Equatable {
    public var photos: [PhotoAsset]
    public var nextCursor: PhotoPageCursor?
}
```

- page size 固定預設 100，可由測試注入，但 production 不得超過 200。
- 使用穩定 keyset cursor，不使用高 offset 作為主要分頁機制；排序值相同時以 `PhotoID` 作 tie-breaker。
- 查詢、排序與分頁在 SQLite 完成，不把全表載入 Swift 後處理。
- `PhotoPageCursor` 只包含排序鍵與 `PhotoID`，不得包含絕對路徑。
- `.folder` scope 包含該相對資料夾及其所有子資料夾；空相對路徑代表來源根目錄。
- `.recentlyEdited` 固定依 `last_edit_at DESC, photo_id` 排序，不顯示其他排序選項；其他 scope 預設使用 `captureDateDescending`。
- 沒有拍攝日期的照片在日期升冪與降冪都排在有日期照片之後，再以 `PhotoID` 穩定排序。

## 9. 多來源掃描與一致性

- 每個來源同時最多一個有效 scan generation。
- 全 App 最多兩個來源同時掃描；其餘排隊。使用者目前選取的來源優先，但已開始的 batch 不被粗暴中斷。
- 每一層 pipeline 仍只允許 consumer 正在處理的一個 batch 加一個 pending batch，retained batch count `<= 2`。
- 每個完整 inspected batch 以 transaction upsert，完成後才發布 UI event。
- 取消前已提交 batch 可保留；未完整 inspected batch 不寫入。
- 只有完整成功掃描才能 prune 本次未見的舊 rows、更新 `lastScanAt` 與 successful manifest state。
- 取消、離線、授權失效或 partial failure 不 prune，避免把暫時看不到的照片誤判為刪除。
- 單張 unsupported／corrupt／metadata failure 產生 per-photo 狀態並繼續；source summary 明確列出成功與失敗數。
- App 進背景時停止排入新來源；已進行工作依 iPad background budget 收尾或取消，不宣稱 background execution 一定完成。

## 10. 縮圖、離線與容量

- 沿用 `ThumbnailProvider` 與 `DiskCache`；cache key 必須包含 `PhotoID`、fingerprint、pixel dimension、decoder identity 與 render version。
- iPad 預設縮圖快取預算為 2 GiB，設定可調範圍 512 MiB–10 GiB；Mac 既有 10 GiB 預設不變。
- 快取採 LRU；畫面可見與正在產生的項目 pin，完成或離開可見範圍後 unpin。
- cache miss 且來源離線時回傳可理解的 offline placeholder，不反覆重試解碼。
- 快取、SQLite 與 bookmark 均位於 App container／Application Support；RAW bytes 與完整預覽不因加入來源而自動複製。
- 「複製到此 iPad」仍是唯一建立離線可編輯完整副本的流程。

## 11. 錯誤與復原

| 情境 | 必要行為 | 禁止行為 |
|---|---|---|
| 單一來源離線 | 保留索引／縮圖，停用原檔操作，提供重新連結 | 讓整個聚合圖庫失效 |
| bookmark 失效 | 標成 `needsAuthorization`，提供重新授權 | 靜默刪除來源 |
| 掃描時拔碟 | 取消 generation，保留完整 batch，不 prune | 將中斷標成成功 |
| 單張 RAW 損壞／不支援 | 標記單張並繼續 | 中止整個來源 |
| Files provider timeout | 單一 resource／metadata request 30 秒未完成即取消該 request、記錄 per-file failure 並提供重試；重試建立新 generation | 永久 spinner 或無限 retry |
| index migration 失敗 | 關閉失敗 DB，保留可重建資料並提供重建 | 使用半遷移 schema |
| 移除來源 | 刪本機 bookmark、index rows、cache entries | 刪 RAW、sidecar、manifest |
| 身份不符 | 保持舊來源離線，要求重新選擇或加入新來源 | 依名稱／路徑自動接回 |

所有使用者可見錯誤包含「發生什麼、哪些資料未被修改、下一步」。診斷使用安全代號、`LibraryID` 與 basename；不得輸出私人絕對路徑。

## 12. 可及性與本地化

- VoiceOver 讀出檔名、拍攝日期、來源顯示名稱、連線狀態、是否已有編輯與錯誤狀態。
- 狀態不得只靠紅／綠或 badge 顏色；必須有 symbol、文字或 accessibility value。
- 所有互動目標至少 44×44 pt，支援 Dynamic Type、Reduce Motion、鍵盤與觸控板導航。
- 新字串加入英文與繁體中文資源；不得把 enum raw value 或技術錯誤直接顯示給使用者。

## 13. 效能與資源界線

- 三個來源、每個 10,000 筆 synthetic index 下，跨來源 page 不得遺失、重複或順序漂移。
- 10,000 synthetic scan 的每層 retained batch high-water 必須 `<= 2`；待處理檔案增加時 queue 不得線性成長。
- 已有 SQLite index 時，M1+ iPad 啟動後第一頁 100 張在 1 秒內可操作。
- 已快取縮圖在 request 後 300 ms 內顯示。
- 網格快速捲動、切來源、搜尋與排序不得在 main actor 執行 RAW decode 或同步 SQLite 全表查詢。
- query generation 切換後，舊 page／thumbnail 結果不得改寫新畫面。
- 效能 gate 使用 instrumented counters 與 signpost／clock measurement；不只依靠肉眼或不穩定 RSS 峰值。

## 14. 測試策略

### 14.1 Unit

- schema v1→v2 成功、失敗 rollback、重開與可重建。
- `LibraryQuery` 四種 scope、四種排序、Unicode filename search、穩定 cursor 與同排序鍵 tie-break。
- source identity 的 manifest、bookmark identity、唯讀 ambiguous 與同名磁碟拒絕案例。
- connection state transition、移除來源不觸碰來源檔案。
- `LibraryBrowserSession` generation、page merge、scroll anchor 與離線 command gate；iPad `PadLibraryModel` typealias 必須編譯連到同一型別。

### 14.2 Integration

- 三來源各 10,000 synthetic rows 的跨來源分頁完整性。
- 兩個掃描進行、第三個排隊；slow consumer 下 retained batch `<= 2`。
- scan 中取消、拔碟、provider error、partial file failure 與 late generation。
- 完整掃描才 prune；取消／離線／partial failure 均不 prune。
- cached thumbnail 離線可讀、uncached thumbnail 離線回 actionable error。
- 圖庫選取 → 既有 EditorSession → autosave → 返回 → `last_edit_at`／badge 更新。

### 14.3 UI 與 Simulator

- 空狀態加入來源、常駐側欄、compact drawer、來源狀態與網格增量更新。
- 橫直向、Split View、Stage Manager 切換保留 query、selection 與 anchor。
- 搜尋、排序、縮圖尺寸、掃描中開啟已索引照片。
- 離線照片不能進入假成功 editor；重新連結後可開啟。
- VoiceOver labels、Dynamic Type 與 44×44 pt targets。

### 14.4 真實裝置與檔案系統

至少在一台真實 M1+ iPad 上驗證：

1. APFS 外接來源加入、掃描、重啟恢復。
2. exFAT 外接來源加入、掃描、拔除、離線瀏覽、重新連結。
3. 一個真實 Files provider 來源授權、失效後重新授權。
4. 三來源聚合、搜尋、排序與返回網格狀態恢復。
5. 真實 Sony `.ARW` 進入既有編輯器、十項調整、autosave、重開，操作前後 RAW checksum 不變。

## 15. 自動驗收 runner

新增獨立 runner，不改寫既有 Task 8 證據：

1. `swift build -Xswiftc -strict-concurrency=complete`
2. `swift test`
3. iOS Simulator `.app` build
4. PhotoLibraryCore multi-source synthetic integration tests
5. 既有 Mac MVP acceptance preflight 與 acceptance
6. 既有 iPad vertical-slice runner
7. repo state 與 privacy scan

summary 必須逐步記錄 PASS／FAIL／NOT RUN、exit code、實際測試數與安全的相對 evidence path。signal、timeout、子程序清理及 privacy 規則沿用已強化的 iPad runner evidence protocol，不複製一套較弱實作。

## 16. Completion Gate

本功能只有在以下條件全部成立時才可標為完成：

1. 多個來源可加入、保存、重啟恢復並在一個「所有照片」查詢聚合。
2. 來源與資料夾、最近編輯、檔名搜尋及四種排序皆有穩定分頁結果。
3. 橫向常駐側欄與直向來源面板可用，尺寸切換保留 UI state。
4. 掃描增量顯示，bounded 與 generation 契約通過壓力測試。
5. 離線來源保留索引與快取縮圖；重新授權／連結必須驗證身份。
6. 移除來源不修改或刪除 RAW、sidecar、manifest。
7. 真實 APFS、exFAT、Files provider 與 Sony `.ARW` 裝置 gate 完成。
8. 既有 Mac 與 iPad 編輯、autosave、匯出及 RAW checksum regression 全綠。
9. 最新自動 summary 為 PASS，實機報告沒有把 NOT RUN 當 PASS，log 無私人絕對路徑。

## 17. 明確不在本階段

- 評分、旗標、色標、相簿、智慧相簿及任意 metadata 編輯。
- 批次選取、批次調整、批次改名與批次匯出。
- Preset browser、XMP 匯入／匯出 UI。
- JPEG、HEIC、PNG 或影片資產管理。
- 自動建立離線完整副本；完整副本只透過使用者明確選擇「複製到此 iPad」。
- 多裝置同時寫入、lease 接手、衝突合併與自動雙向同步。
- 新的調色面板、裁切、修復、遮色片或其他局部工具。
- Mac 圖庫介面重做。

## 18. 交付切分與相依順序

```text
1. schema v2 + paged cross-source query
              ↓
2. source identity + connection-state migration
              ↓
3. multi-source scan coordinator
              ↓
4. PadLibraryModel + grid data source
              ↓
5. adaptive sidebar／grid UI
              ↓
6. editor navigation + restoration
              ↓
7. automated runner + real-device gates
```

先完成可獨立測試的 core，再接 UI；不允許先用 App target 內的暫存陣列做 demo，最後才補真正索引。Task 8 的實機驗收證據仍可在另一條 branch 補做；本功能可以先開發，但整合時不得把 Task 8 的 NOT RUN 誤寫為 PASS。

## 19. 回復策略

- 每個交付切分使用獨立 commit，core migration 與 UI 不混在同一 commit。
- schema v2 index 仍是可重建 cache；若 migration 在測試或 beta 發現問題，可關閉新 UI、刪除並由來源重建 index，不修改 RAW 或 sidecar。
- `PhotoSidecar` schema 本階段不變，因此回退 App 版本不需遷移使用者編輯資料。
- 來源 registry 欄位採向後可忽略的本機資料；回退後舊版仍能使用既有 bookmark 與單來源流程。
