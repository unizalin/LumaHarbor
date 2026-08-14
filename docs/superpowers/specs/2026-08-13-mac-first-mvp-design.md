# LumaHarbor：Mac-first RAW 相片編輯器設計規格

- 狀態：已核准
- 日期：2026-08-13
- 第一階段平台：macOS（Apple Silicon）
- 後續平台：iPadOS
- 主要驗證格式：Sony `.ARW`

## 1. 產品摘要

LumaHarbor 是以 Swift 全新實作的 Apple 原生、非破壞式 RAW 相片編輯器。第一階段先完成 macOS App，讓使用者直接瀏覽與編輯外接 SSD 上的 Sony `.ARW`，不需把原始照片匯入 App 私有空間。編輯參數保存在外接照片資料夾的 `.lumaharbor` 目錄，讓未來 iPadOS App 接上同一顆 SSD 時能延續編輯。

本專案不移植 AwayPhotoRawEditor 的 WinForms 程式碼、UI、圖示或素材。該專案僅作為早期產品功能探索的參考來源。

## 2. 目標

Mac-first MVP 必須提供一條可完整驗收的工作流程：

1. 選擇外接 SSD 上的照片資料夾。
2. 掃描、建立索引並顯示 RAW 縮圖。
3. 開啟 Sony `.ARW` 並進行基本調色。
4. 自動保存非破壞式調整。
5. 重新啟動 App 後恢復資料夾權限與編輯結果。
6. 從完整解析度 RAW 匯出 JPEG。
7. 正確處理 SSD 拔除、唯讀磁碟、不支援或損壞的 RAW。

架構不得把 RAW 解碼、影像處理或 sidecar 格式綁死在 macOS UI，確保後續 iPadOS target 能重用核心模組。

## 3. 非目標

以下功能不納入第一階段：

- iPadOS 使用者介面
- 裁切與旋轉
- 局部筆刷、修復、線性或徑向漸層
- 曲線與個別 HSL 通道
- 批次套用與批次匯出
- 風格檔
- 星等、旗標與進階搜尋
- iCloud 或 CloudKit 同步
- LibRaw 後備解碼器
- 外掛系統

這些功能須在 MVP 核心流程通過驗收後，以獨立 spec 規劃。

## 4. 技術路線

第一版採用：

- Swift 與 Swift Concurrency
- SwiftUI 為主要介面
- 必要時以 AppKit 補足 macOS 選單、鍵盤、檔案面板等能力
- `CIRAWFilter` 解碼 RAW
- Core Image 建立調色管線
- `CIContext` 使用 Metal 裝置執行預覽與匯出
- Foundation bookmark 與 security-scoped URL 保存外接資料夾權限
- SQLite 保存本機可重建索引
- JSON 保存可攜式非破壞調整資料

RAW 解碼器必須透過 `RawDecoding` protocol 使用。第一版實作 `CoreImageRawDecoder`；未來可加入 `LibRawDecoder`，而不改動 UI、sidecar 或編輯狀態模型。

## 5. 模組架構

```text
LumaHarbor
├─ LumaHarborApp
│  ├─ SwiftUI App lifecycle
│  ├─ Library browser
│  ├─ Editor workspace
│  ├─ Inspector controls
│  └─ macOS commands and shortcuts
│
├─ PhotoLibraryCore
│  ├─ Security-scoped folder access
│  ├─ Folder bookmark persistence
│  ├─ Incremental folder scanner
│  ├─ Local SQLite index
│  ├─ Portable sidecar repository
│  └─ Thumbnail and preview cache
│
├─ RawProcessingCore
│  ├─ RawDecoding protocol
│  ├─ CoreImageRawDecoder
│  ├─ Adjustment pipeline
│  ├─ Preview scheduler
│  └─ Full-resolution JPEG exporter
│
└─ Tests
   ├─ Unit tests
   ├─ Integration tests
   ├─ RAW fixture tests
   └─ Visual regression tests
```

### 5.1 邊界原則

- `LumaHarborApp` 不直接建立或操作 `CIRAWFilter`。
- `PhotoLibraryCore` 不依賴 SwiftUI。
- `RawProcessingCore` 不負責資料夾掃描、bookmark 或畫面狀態。
- sidecar schema 使用純 `Codable` value types，不能依賴 Core Image 或 UI 型別。
- 縮圖、預覽與 SQLite 索引皆視為可刪除、可重建資料。

## 6. 使用者介面與操作流程

### 6.1 資料庫畫面

- 初次啟動顯示「加入照片資料夾」。
- 系統資料夾選擇器允許使用者選擇外接 SSD 上的一個根目錄。
- 選定後，App 立即顯示掃描進度，並以增量方式加入縮圖，不等待整個目錄完成。
- 縮圖項目顯示預覽、檔名、拍攝時間與失敗狀態。
- 已離線的資料庫仍顯示快取縮圖，但不可進行需要原檔的操作。

### 6.2 編輯畫面

Mac MVP 使用三區配置：

- 左側：目前資料夾與資料庫狀態。
- 中央：主預覽與底部照片列。
- 右側：調整 inspector。

第一版調整項目：

- 曝光
- 白平衡色溫
- 白平衡色調
- 對比
- 高光
- 陰影
- 白色
- 黑色
- 自然飽和度
- 飽和度

每項調整具有明確的預設值、允許範圍及重設操作。畫面提供：

- 按住或切換原圖／編輯後預覽
- Undo
- Redo
- 重設整張照片

拖動滑桿時優先維持互動流暢；停止輸入後再排程較高品質預覽。

### 6.3 匯出

- MVP 每次匯出一張照片。
- 使用者可選擇目的地與 JPEG 品質。
- 匯出使用完整解析度 RAW，不使用畫面預覽快取。
- 若目的地已有同名檔案，預設加入遞增流水號，禁止無提示覆寫。
- 匯出工作可取消，取消後移除未完成的暫存輸出。

## 7. 外接儲存與權限

使用者選擇資料夾後，App 建立 security-scoped bookmark，保存在該 Mac 的 Application Support。每次啟動時：

1. 解析 bookmark。
2. 若 bookmark 有效，呼叫 `startAccessingSecurityScopedResource()`。
3. 使用 `NSFileCoordinator` 執行外部檔案讀寫。
4. 不再需要資源時成對呼叫 `stopAccessingSecurityScopedResource()`。

bookmark 不寫入外接 SSD，也不跨裝置同步。未來每台 Mac 或 iPad 都必須由使用者各自授權一次。

若 bookmark 過期或無法解析，App 顯示重新連結流程，不自行猜測其他磁碟路徑。

## 8. 儲存模型

### 8.1 外接 SSD

```text
Photos/
├─ Trip/
│  ├─ DSC0001.ARW
│  └─ DSC0002.ARW
└─ .lumaharbor/
   ├─ library.json
   └─ edits/
      ├─ <photo-id>.json
      └─ <photo-id>.json
```

`.lumaharbor` 是跨裝置可攜資料的唯一權威來源。RAW 原檔永不修改。

`library.json` 保存：

- sidecar schema 版本
- 資料庫識別碼
- 每張照片的 UUID `photo-id`
- RAW 相對路徑
- 檔案指紋
- 最後成功掃描時間

檔案指紋由檔案大小、前 1 MiB 與後 1 MiB 的 SHA-256 摘要組成。小於 2 MiB 的檔案雜湊完整內容。指紋不取代 UUID，只用於重新連結與變更偵測。

照片首次發現時產生 UUID。若相對路徑改變但指紋唯一吻合，更新既有紀錄；若有多個相同指紋候選，保留為待確認狀態，不自動合併。

### 8.2 調整 sidecar

每張照片的 `<photo-id>.json` 至少包含：

```json
{
  "schemaVersion": 1,
  "photoID": "UUID",
  "sourceRelativePath": "Trip/DSC0001.ARW",
  "sourceFingerprint": {
    "fileSize": 0,
    "edgeDigest": "sha256"
  },
  "decoder": {
    "kind": "coreImage",
    "version": "system-default"
  },
  "adjustments": {
    "exposure": 0,
    "temperature": 0,
    "tint": 0,
    "contrast": 0,
    "highlights": 0,
    "shadows": 0,
    "whites": 0,
    "blacks": 0,
    "vibrance": 0,
    "saturation": 0
  },
  "createdAt": "ISO-8601",
  "modifiedAt": "ISO-8601"
}
```

文件中的數字只是中性預設值；每個參數的實際 UI 範圍與 Core Image 映射須集中定義並由測試固定，不能散落在 View 中。

sidecar 採原子寫入：先在同一目錄建立暫存檔、同步完成後再替換正式檔。寫入失敗不得更新 UI 的「已儲存」狀態。

### 8.3 Mac 本機資料

```text
Application Support/LumaHarbor/
├─ library.sqlite
├─ bookmarks/
└─ cache/
   ├─ thumbnails/
   └─ previews/
```

SQLite 保存檔案索引、EXIF 摘要、掃描狀態與快取索引。刪除 SQLite 後，App 必須能由外接 SSD 的 RAW 與 `.lumaharbor` 重建資料庫。

快取必須有可設定的容量上限，MVP 預設 10 GiB，採最近最少使用策略清理。正在顯示或匯出的資源不得在工作期間被清理。

## 9. RAW 與影像處理管線

```text
ARW source
→ CIRAWFilter decode
→ linear wide-gamut working image
→ basic adjustment chain
→ display transform
→ Metal-backed CIContext render
```

- App 架構接受 Apple `CIRAWFilter` 能解碼的其他 RAW，但 Sony `.ARW` 是 MVP 的必要驗收格式。
- 預覽使用符合目前顯示尺寸的影像，不固定解碼完整解析度。
- 匯出重新解碼原始 RAW 並套用同一份調整參數。
- 工作色域與輸出色彩設定由處理核心集中管理；MVP 顯示與 JPEG 輸出至少正確標記 sRGB profile。
- 同一張照片同一時間只允許一個有效的互動預覽工作。較新的請求取消並取代較舊請求。
- 切換照片時，前一張照片尚未完成的預覽不得覆蓋目前畫面。

## 10. 狀態與錯誤處理

| 情況 | 預期行為 |
| --- | --- |
| SSD 未連接 | 資料庫標為離線；保留本機縮圖與索引 |
| bookmark 失效 | 顯示重新選擇資料夾流程 |
| RAW 不受支援 | 保留項目並顯示「此相機 RAW 暫不支援」 |
| RAW 損壞 | 標記單張失敗；掃描繼續 |
| SSD 唯讀 | 允許瀏覽；編輯前提示無法保存 sidecar |
| 編輯中拔除 SSD | 保留記憶體內未保存參數，接回後允許重試 |
| sidecar JSON 損壞 | 保留原檔、隔離損壞 sidecar，顯示可診斷錯誤；不靜默覆寫 |
| 磁碟空間不足 | 停止快取或匯出並說明原因；不留下偽完成狀態 |
| 匯出同名 | 自動加入流水號 |
| 預覽請求過期 | 取消舊工作，不顯示過期結果 |

所有使用者可處理的錯誤都必須附帶下一步，例如「重新連結」、「重試」或「選擇其他輸出位置」。內部錯誤可記錄診斷資訊，但不得向使用者顯示敏感路徑以外的不必要技術內容。

## 11. 效能目標

基準裝置為 Apple Silicon Mac mini，測試素材為約 24 MP Sony `.ARW`：

- 已快取縮圖在 300 ms 內顯示。
- 調整滑桿後的預覽更新目標為 150 ms 內；若高品質工作超過此時間，先顯示互動品質結果。
- 資料夾掃描必須串流與分頁處理，不把全部 RAW 或完整 metadata 一次載入記憶體。
- 快速切換照片 100 次後，記憶體不得因未取消工作持續線性成長。
- UI 主執行緒不得執行 RAW 解碼、檔案雜湊或 JPEG 匯出。

效能目標以自動量測與 Instruments 驗證；硬體與 RAW 內容差異須記錄於測試報告。

## 12. 測試策略

> 2026-08-14 補充：Thumbnail cache identity、編輯離開前保存與掃描取消，以 [`2026-08-14-thumbnail-scan-cancellation-hardening.md`](2026-08-14-thumbnail-scan-cancellation-hardening.md) 為準；lossless bounded 掃描管線的固定架構與驗收，另以 [`2026-08-14-lossless-bounded-scan-pipeline.md`](2026-08-14-lossless-bounded-scan-pipeline.md) 為準。

### 12.1 單元測試

- sidecar JSON 編解碼與預設值
- schema version 拒絕未知的較新重大版本
- 原子寫入成功與失敗
- 指紋產生與照片重新連結
- 相同指紋歧義不自動合併
- Undo／Redo 狀態轉移
- 調整參數範圍與 Core Image 映射
- 快取容量與 LRU 清理

### 12.2 整合測試

- 授權資料夾後掃描、建立索引及重啟恢復
- `.ARW` 解碼、預覽與完整尺寸 JPEG 匯出
- SSD 離線與重新連結
- 唯讀資料夾
- 損壞 RAW 與損壞 sidecar
- 預覽工作取消與過期結果隔離
- 匯出取消與暫存檔清理

### 12.3 視覺與人工驗收

- 固定 Sony ARW fixtures 與固定調整參數產生基準輸出。
- 比較輸出時允許 OS RAW decoder 造成的小幅像素差異，但不得出現方向、色域、曝光或尺寸錯誤。
- 使用至少一顆 APFS SSD 與一顆 exFAT SSD 完成實機測試。
- 測試 App 重啟、SSD 拔除／重接與資料夾重新命名。

測試 RAW 不直接提交大型原始檔至主 Git 歷史。公開授權的小型 fixture 可使用 Git LFS；私人相機樣本則由測試腳本透過本機路徑提供，且不得上傳。

## 13. MVP 驗收條件

以下條件全部成立才視為 Mac-first MVP 完成：

1. 可選擇外接 SSD 目錄並在 App 重啟後恢復授權。
2. 可增量掃描並顯示 Sony `.ARW` 縮圖。
3. 第 6.2 節列出的所有調整都能即時預覽。
4. 原圖比較、Undo、Redo 與重設皆有測試。
5. 調整自動保存至 `.lumaharbor`，重新啟動後結果一致。
6. 原始 `.ARW` 的內容與修改時間不被 App 改變。
7. 可從完整解析度 RAW 匯出帶有 sRGB profile 的 JPEG。
8. SSD 拔除、不支援 RAW、損壞 RAW 或唯讀磁碟不會導致 App 崩潰。
9. 本機 SQLite 與快取刪除後可以重建。
10. 核心單元與整合測試通過，且沒有已知資料損毀問題。

## 14. 後續階段

MVP 完成後依序規劃：

1. 裁切、旋轉、曲線與 HSL。
2. 批次調整、風格檔、評分與篩選。
3. 局部遮罩、Apple Pencil 與 iPadOS UI。
4. 可選的 iCloud metadata 同步。
5. 當 Apple RAW 支援不足時評估 LibRaw 後備解碼器。

每個階段都需獨立設計與驗收，不預先擴張 MVP。

## 15. 開源、授權與致謝

LumaHarbor 使用 MIT License。所有新程式碼、圖示與介面都從零製作。

README 必須保留以下意思的致謝：LumaHarbor 是獨立 Swift 實作；早期產品探索部分參考 Awaysu 的 AwayPhotoRawEditor；兩個專案與作者之間沒有隸屬或背書關係。

目前不複製 AwayPhotoRawEditor 的程式碼，因此不把其 BSD 3-Clause License 作為 LumaHarbor 主授權的一部分。若未來實際引用或改寫任何該專案程式碼，必須先審查來源、在相應散布物保留其著作權與 BSD 3-Clause 條款，並不得暗示原作者背書。
