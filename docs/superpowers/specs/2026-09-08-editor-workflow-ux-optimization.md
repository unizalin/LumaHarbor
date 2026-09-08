# LumaHarbor 編輯工作流與圖庫 UX 優化規格

- 狀態：Phase 1 首輪實作中；自動化契約驗證已通過，人工 Mac／iPad 驗收尚未完成
- 日期：2026-09-08
- 目標平台：macOS 與 iPadOS
- 基準分支：`codex/open-source-release-prep`
- 基準 commit：`a3fdb35f0937a469c49e596b18915739533471b7e`
- 關聯總規格：`docs/superpowers/specs/2026-09-02-awayphotoraweditor-parity-design.md`

## 1. 文件定位

這份文件補充既有 AwayPhotoRawEditor parity 總規格，專門處理目前功能已存在、但操作動線仍不夠完整或不易發現的問題。它不改變 RAW 處理演算法，也不取代既有幾何、局部調整、Preset、批次與匯出規格。

本規格分成三個可獨立交付的階段：

1. Phase 1：完成最影響日常使用的編輯、瀏覽與 iPad 輸出流程。
2. Phase 2：補強比較、批次同步入口與專注工作區。
3. Phase 3：加入評分、旗標、關鍵字與進階篩選。

Phase 1 是下一輪實作範圍。Phase 2 與 Phase 3 只在本文件固定產品契約，必須另拆 implementation plan，不能順手混入 Phase 1。

## 2. 使用者與問題

### 2.1 使用者

- 在 Apple Silicon Mac 上整理、編輯與批次輸出 RAW 的攝影使用者。
- 在 iPad 上從 Files、外接儲存或 App Copies 開啟 RAW，完成行動修圖的使用者。
- 維護 LumaHarbor 的開源貢獻者與測試者。

### 2.2 已驗證的目前行為

| 區域 | 目前行為 | 使用者影響 | 程式證據 |
| --- | --- | --- | --- |
| Mac inspector | 單一長 ScrollView 依序顯示直方圖、完整 metadata、Preset，再顯示 Basic 與其他調整 | 開啟照片後，最常用調整不在第一屏 | `Sources/LumaHarborApp/Views/InspectorView.swift:17-50` |
| Mac 預覽 | 圖片只有 `.aspectRatio(contentMode: .fit)` | 無法用 100% 檢查銳化、降噪與修復細節，也不能平移 | `Sources/LumaHarborApp/Views/EditorView.swift:35-45` |
| Mac 圖庫 | 固定縮圖尺寸；工具列只有批次匯出與重新掃描 | 使用者不能直接搜尋、排序或調整資訊密度 | `Sources/LumaHarborApp/Views/LibraryGridView.swift:10-89` |
| Mac 多選 | 只有 `Command + 點擊` 可切換，畫面沒有選取模式與選取數量 | 功能不易發現，也缺 Shift 區間選取與全選 | `Sources/LumaHarborApp/Views/LibraryGridView.swift:29-44` |
| 共用圖庫核心 | 已有 `LibraryQuery`、四種 `PhotoSort`、filename search 與分頁查詢 | Mac 不需重寫 SQLite 查詢語意 | `Sources/PhotoLibraryCore/Model/LibraryQuery.swift` |
| iPad 圖庫 | 已有搜尋、排序與三段縮圖密度 | 可作為 Mac 行為與文案基準 | `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryGrid.swift:35-79` |
| iPad 編輯器 | 已有工作／專注模式與 1x-5x 捏合縮放 | 編輯流程已可用，但沒有輸出成品的入口 | `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift:101-111,214-249` |
| 匯出核心 | `PhotoExporter` 已支援完整解析度輸出、取消、碰撞處理與暫存清理 | iPad 可以重用核心，不能輸出畫面預覽快取代替 | `Sources/RawProcessingCore/Export/PhotoExporter.swift` |

### 2.3 期望結果

使用者應能在不查說明文件的情況下完成以下流程：

1. 在 Mac 圖庫搜尋、排序、調整縮圖大小與選取多張照片。
2. 開啟照片後立即看到常用調整，不需先滑過 EXIF 與 Preset。
3. 在 Mac 預覽使用 Fit、100%、縮放與平移檢查細節。
4. 在 iPad 完成編輯後，以完整解析度匯出並交給 Photos、Files 或系統分享目的地。
5. 所有流程維持非破壞式，RAW 原檔與 sidecar 安全契約不變。

### 2.4 為什麼現在做

現有影像處理、Preset、批次與匯出能力已足以支撐完整工作流。繼續增加調整工具之前，應先讓既有能力可被找到並能從瀏覽一路走到輸出，否則功能數量增加只會讓 inspector 更長、操作成本更高。

## 3. 成功定義

Phase 1 完成時必須同時符合：

1. Mac 開啟照片後，Basic 調整在 inspector 的第一個可見畫面內，不需垂直捲動。
2. Mac 提供 Fit、100%、放大、縮小、觸控板捏合與平移；裁切、滴管、漸層與修復 overlay 在任意縮放下仍命中正確影像座標。
3. Mac 圖庫提供檔名搜尋、四種既有排序與三段縮圖密度。
4. Mac 圖庫提供可見的多選模式、選取數量、Command 切換、Shift 區間選取、全選與清除。
5. iPad 可將目前照片以完整解析度輸出，能選擇 Photos、Files 或系統分享；分享取消不顯示失敗。
6. 匯出、查詢、縮放與選取不修改 RAW；調整仍只透過既有 sidecar 儲存。
7. 新增行為具備 model／policy 測試、UI contract 測試、Mac 人工畫面驗收與 iPad 實機驗收證據。

## 4. 全域產品與架構原則

### 4.1 非破壞式與資料權威

- RAW 原檔永不修改、搬移或刪除。
- inspector 分頁、展開狀態、zoom、pan、搜尋文字、排序、密度與多選都是 UI／工作階段狀態，不得寫入照片 sidecar。
- Phase 1 不變更 sidecar schema。
- 搜尋與排序只能查詢可重建的 SQLite index，不得掃描 RAW 內容來回應每次 UI 輸入。
- iPad 匯出必須從 `PhotoDocument.workingURL` 重新解碼完整解析度來源，並套用 `EditorSession` 已提交的目前調整。

### 4.2 共用核心優先

- Mac 搜尋與排序重用 `LibraryQuery`、`PhotoSort` 與 `PhotoIndexStore`，不得建立第二套字串比對或排序規則。
- iPad 匯出重用 `RawProcessingCore.PhotoExporter` 與既有 `ExportRequest`。
- 平台 View 只負責狀態呈現、手勢與系統 picker／share sheet 接線。
- 可純計算的 zoom、pan、座標轉換、選取範圍與 inspector 狀態規則必須放在可單元測試的 policy／model，不埋在巨大 SwiftUI `body`。

### 4.3 狀態與錯誤

- 長時間輸出必須顯示文字狀態、進度或目前檔名，不能只顯示無標籤 spinner。
- 使用者可處理的失敗必須包含下一步，例如重新連接來源、允許 Photos 權限、釋放空間或改選目的地。
- 錯誤訊息不得顯示私人絕對路徑、bookmark data、Team ID 或 provider 內部資訊。
- `PASS`、`FAIL`、`SKIPPED`、`NOT RUN` 必須分開記錄。

## 5. Phase 1 詳細需求

### 5.1 Mac inspector 資訊架構

#### 5.1.1 版面

右側 inspector 改為三個互斥分頁：

- `調整`：直方圖、Basic、Color、Curve、Detail、Effects、Geometry、Local Adjustments。
- `Preset`：現有 `PresetBrowserView` 的完整功能。
- `資訊`：完整 metadata、來源狀態與 sidecar 儲存狀態。

分頁使用 segmented control，置於 inspector 標題下方。不能使用三個外觀相同的圓角文字按鈕代替。

#### 5.1.2 調整分頁

- 直方圖固定在頂部，維持目前 80 pt 高度；無資料時保留同尺寸 placeholder，避免版面跳動。
- `Basic` 預設展開且排在第一個調整群組。
- Mac 的 Basic 顯示 Exposure、Contrast、Highlights、Shadows、Whites、Blacks、Vibrance、Saturation；Temperature 與 Tint 移到 Color 並與白平衡滴管、HSL 放在同一群組。底層仍使用相同 stable adjustment field，不改 sidecar 或 render mapping。
- 其他群組使用 disclosure group，預設狀態為：Color 展開，其餘收合。
- 展開狀態在切換照片時保留，在 App 重啟後可回到預設；Phase 1 不要求永久保存。
- `Reset All` 只在調整分頁顯示，維持現有 disabled 規則與 undo 行為。
- 切換 inspector 分頁不得建立 undo、觸發 autosave 或重新解碼 RAW。

#### 5.1.3 Preset 與資訊分頁

- Preset 分頁保留搜尋、收藏、建立、匯入、匯出、備份與還原，不縮減現有功能。
- 資訊分頁使用現有 `EditorMetadataSnapshot`，缺少的 EXIF 值顯示 `-`，不 crash。
- 資訊分頁不得直接顯示 `sourceURL.path`。
- 沒有選取照片時，三個分頁共用「選擇一張照片開始編輯」空狀態。

#### 5.1.4 驗收

- 在 1280 x 800 的 Mac 視窗中，開啟照片後不捲動即可看到完整直方圖、Basic 標題及至少曝光與對比控制。
- 切換三個分頁 20 次後，照片、調整值、undo stack 與 save state 不變。
- Metadata 與 Preset 不再出現在調整分頁的 ScrollView。

### 5.2 Mac canvas 縮放與平移

#### 5.2.1 模式與範圍

提供以下明確狀態：

- `Fit`：完整照片位於可見 canvas 內。
- `100%`：一個影像 pixel 對應一個實體 display pixel，計算時納入 `displayScale`。
- `Custom`：10% 至 800%，超出範圍時 clamp。

工具列提供 Fit、100%、縮小、目前百分比與放大。百分比可由選單直接選擇 25%、50%、100%、200%、400%。

鍵盤操作：

- `Command + 0`：Fit。
- `Command + 1`：100%。
- `Command + +`／`Command + -`：依 10%、25%、50%、100%、200%、400%、800% 階梯縮放。

#### 5.2.2 手勢

- 觸控板捏合以游標或 gesture focal point 為中心縮放。
- 按住 Space 拖曳，或使用觸控板雙指捲動平移。
- 圖片小於 viewport 時自動置中，不能被平移到畫面外。
- 圖片大於 viewport 時，pan offset 必須 clamp，至少保留影像覆蓋 viewport，不讓使用者把整張照片推失。
- 雙擊 canvas 在 Fit 與 100% 間切換，以點擊位置為 100% 中心。

#### 5.2.3 文件與渲染狀態

- 開啟不同照片時回到 Fit。
- 同一照片切換 inspector 分頁或工作區顯示狀態時保留 zoom／pan。
- 視窗 resize 時，Fit 重新計算；100% 與 Custom 保持倍率並重新 clamp offset。
- zoom／pan 不進入照片 undo stack、不觸發 sidecar autosave。
- 當目前預覽 pixel dimension 不足以支撐新倍率時，要求較高解析度預覽；舊請求必須取消，只有最新請求可更新畫面。
- 載入更高解析度預覽期間保留現有畫面，不清成空白；可顯示非阻塞式解碼狀態。

#### 5.2.4 Overlay 座標契約

裁切、白平衡滴管、線性漸層與 spot heal 必須共用同一個 `image-to-canvas` transform：

1. 先計算 aspect-fit 基準 rect。
2. 以基準 rect 中心或 gesture anchor 套用 zoom。
3. 套用 pan offset。
4. 將 pointer location 反轉換回 normalized image coordinate。
5. 所有 normalized coordinate clamp 在 `0...1`。

不得讓每個 overlay 各自重算倍率與 offset。

#### 5.2.5 驗收

- 25%、100%、400% 與 800% 顯示倍率和工具列百分比一致。
- Retina display 下 100% 使用 pixel 對 pixel 定義，不以 SwiftUI point 當作 image pixel。
- 在 400% 下對影像四角執行滴管、裁切、漸層與修復命中測試，誤差不超過 normalized coordinate `0.002`。
- 快速連續縮放 30 次後，只允許最後一次高解析度預覽結果顯示。

### 5.3 Mac 圖庫搜尋、排序與密度

#### 5.3.1 搜尋

- 圖庫工具列加入系統搜尋欄，placeholder 為「依檔名搜尋」。
- 搜尋沿用 `LibraryQuery.filenameSearch` 的 Unicode normalization、case-insensitive 與 `%`／`_` literal escaping 契約。
- 輸入立即反映在欄位，查詢使用既有 250 ms debounce 語意。
- 查詢期間可保留舊結果，但不能讓舊 query 的延遲結果覆蓋新 query。
- 無結果時顯示專用空狀態與清除搜尋入口。

#### 5.3.2 排序

排序選單重用既有四種 `PhotoSort`：

- 拍攝時間，新到舊。
- 拍攝時間，舊到新。
- 檔名 A-Z。
- 檔名 Z-A。

排序改變後，畫面回到結果頂端；選取集合依 5.4 的規則處理。

#### 5.3.3 縮圖密度

提供三段固定選項並以 `@AppStorage` 保存：

| 選項 | adaptive minimum | adaptive maximum |
| --- | ---: | ---: |
| 緊密 | 140 pt | 200 pt |
| 標準 | 180 pt | 260 pt |
| 大型 | 240 pt | 340 pt |

預設使用「標準」，與目前 180-260 pt 行為相同。調整密度不得改變目前 query 或選取內容。

#### 5.3.4 驗收

- 以 10,000 筆 synthetic index 在基準 Apple Silicon Mac 測試，250 ms debounce 結束後第一頁查詢 p95 不超過 300 ms。
- 快速輸入 10 個字元只允許最後一個 query 結果落地。
- 四種排序與 SQLite tie-breaker 結果穩定，重新執行不跳序。
- 三種密度切換時沒有 cell overlap、文字截斷或選取遺失。

### 5.4 Mac 可見多選工作流

#### 5.4.1 入口與行為

- 工具列加入「選取」模式；進入後顯示 `已選取 N 張`、全選、清除與完成。
- 不在選取模式時，普通點擊維持開啟照片。
- 在選取模式時，普通點擊切換項目，不開啟 editor。
- `Command + 點擊` 在任何模式都切換單張選取。
- `Shift + 點擊` 依目前畫面排序，從 selection anchor 到目標做連續區間選取。
- `Command + A` 選取目前搜尋、來源與排序結果中的全部照片，不只 viewport 內已繪製的 cell。
- 第一次選取建立 selection anchor；後續普通切換不改變 anchor，Shift range 完成後以 range 目標作為新 anchor。`Command + A` 以目前排序第一張作為 anchor。
- 搜尋文字或來源 scope 改變時清除批次選取，避免對不可見照片執行批次操作。
- 只改排序或密度時保留 selected IDs；anchor 保留同一個 photo ID，區間索引依新排序重新計算。

#### 5.4.2 批次操作列

選取至少一張照片時，顯示固定操作列：

- 批次匯出。
- 編輯所選照片；至少選取兩張時啟用，開啟 selection anchor 作為編輯來源並保留完整選取集合。
- 建立虛擬副本；Phase 1 只允許單一選取時啟用。
- 清除選取。

操作列不得遮住最後一列縮圖；grid 必須保留對應 bottom inset。

從「編輯所選照片」進入 editor 後，工具列或 inspector 頂端必須持續顯示「調整將同步到其他 N 張照片」，並提供取消批次選取入口。這只是把現有自動 batch sync 行為顯性化，不能新增另一套同步規則。離開 editor 回到圖庫時保留選取集合，直到使用者清除、切換來源或改變搜尋。

#### 5.4.3 驗收

- 所有選取方式產生相同的 `selectedPhotoIDs` 語意。
- Shift range 在正向、反向、排序切換後皆有單元測試。
- 全選後執行批次匯出，目標數與 UI 顯示數完全一致。
- 從「編輯所選照片」進入 editor 後，來源照片仍在 selected IDs 內，第一次調整手勢只同步到其餘 N 張。
- 搜尋／切換來源清除選取後，批次按鈕立即 disabled。
- VoiceOver 能讀出檔名、是否已選取及目前選取總數。

### 5.5 iPad 完整解析度匯出與分享

#### 5.5.1 Phase 1 範圍

iPad Phase 1 只處理目前開啟的單張照片，不含 iPad 多選與批次匯出。提供：

- `儲存到照片`：輸出 JPEG，品質預設 0.9。
- `儲存到檔案`：讓使用者透過系統 file exporter 選擇目的地。
- `分享`：產生暫存輸出後交給 system share sheet。
- 格式選項：JPEG、HEIC、PNG、TIFF；不支援的格式顯示原因並 disabled。
- JPEG／HEIC 品質、TIFF 8／16-bit 與 EXIF policy 沿用現有核心契約。

#### 5.5.2 服務接線

- `PadAppServices` 建立並持有與現有 decoder、pipeline、render service 相容的 `PhotoExporter`。
- iPad export coordinator 從 `PadEditorModel.document.workingURL`、目前照片 identity 與 `EditorSession.adjustments` 建立 `ExportRequest`。
- 匯出前先 flush pending adjustments；flush 失敗時禁止開始匯出，保留未儲存狀態並顯示下一步。
- external in-place 文件匯出期間必須持有現有 document security scope，不能重新猜測 URL 或建立第二個 bookmark。
- 暫存分享檔放在 App 自己的 temporary directory；share sheet 完成或取消後清理。

#### 5.5.3 狀態

狀態至少包含：

- idle
- preparing
- exporting(progress 可未知，但必須有文字)
- presentingDestination
- succeeded
- cancelled
- failed(path-safe alert)

同一時間只允許一個輸出工作。再次觸發時不得建立並行 full-resolution render。

#### 5.5.4 Photos 權限與失敗模式

- Photos 權限使用 add-only request；拒絕時說明可以改用 Files 或分享。
- iPad target 必須宣告 `NSPhotoLibraryAddUsageDescription`，並以 `InfoPlist.strings` 提供八語對應文案；不需要讀取相簿時不得要求 read/write library 權限。
- 分享表單被使用者關閉記為 cancelled，不顯示錯誤 alert。
- 磁碟空間不足、來源離線、bookmark 失效、唯讀輸出位置與格式不支援，都要映射成可處理且不含私人路徑的訊息。
- 取消或失敗後不得留下看似完成的輸出檔或 `.tmp`。

#### 5.5.5 驗收

- 使用 Sony `.ARW`，iPad 輸出像素尺寸來自 full-resolution render，不等於畫面 preview 尺寸。
- 曝光、幾何與局部調整都出現在輸出檔。
- 匯出前後 RAW SHA-256 完全一致。
- Photos、Files、分享成功各有一次真機 PASS 證據。
- 拒絕 Photos 權限、取消 share sheet、輸出中斷與空間不足至少各有自動化或可控制的整合測試。

## 6. Phase 2 產品契約

Phase 2 不納入下一輪實作，但先固定以下範圍。

### 6.1 Before／After 比較

- 保留目前按住顯示原圖與點擊固定原圖的行為。
- 新增左右並排與垂直 wipe；清楚標示「原始」與「編輯後」。
- 兩側共用 zoom 與 pan，不能在比較時看不同位置。
- 比較狀態不進 undo、不寫 sidecar。

### 6.2 複製、貼上與同步調整

- 提供可見的「複製調整」「貼上調整」「同步到所選照片」。
- 預設複製 global adjustments；Geometry 與 Local Adjustments 必須由使用者明確勾選。
- 貼上與同步沿用 stable field ID 與現有 `BatchAdjustmentSyncService`，不得整份盲目覆寫。
- 批次操作產生 compound undo 與成功／失敗／略過摘要。

### 6.3 Mac 專注工作區

- 左側 sidebar、右側 inspector 與底部 filmstrip 可個別顯示／隱藏。
- inspector 寬度可在 280-420 pt 調整。
- focus mode 隱藏非必要 chrome，但 Undo、Redo、比較與離開仍可達。
- 顯示狀態可保存為 App preference，不寫照片 sidecar。

## 7. Phase 3 產品契約

Phase 3 需要資料模型與 SQLite schema migration，必須獨立設計與備份／rollback 驗證。

### 7.1 評分與旗標

- 星等 0-5。
- 旗標：未設定、Pick、Reject。
- Mac 鍵盤快捷鍵：`0...5` 設星等，`P` Pick，`X` Reject，`U` 清除旗標；文字輸入焦點存在時不得攔截。
- 圖庫 cell 顯示 rating／flag，但不能遮住檔名與編輯狀態。

### 7.2 關鍵字

- 每張 photo identity 可有零到多個正規化關鍵字。
- 關鍵字大小寫不敏感比對，但保留使用者第一次輸入的顯示形式。
- 不允許空白關鍵字；前後空白在保存前移除。
- Virtual copy 是否繼承關鍵字必須在 Phase 3 design 中另行定義，不能猜測。

### 7.3 篩選

- 依 rating、flag、has edits、格式、相機、鏡頭與日期篩選。
- 篩選條件可組合，並與檔名搜尋共同形成一個 query fingerprint。
- 預設批次匯出排除 Reject；使用者明確勾選時才包含。
- schema migration 失敗必須整筆 rollback；舊 index 可安全重建。

## 8. 明確不納入範圍

- 新的 RAW decoder、LibRaw fallback 或相機支援矩陣擴張。
- 新調整演算法、新局部工具或既有渲染效果重寫。
- iCloud、CloudKit、跨裝置即時同步與多人協作。
- Windows、Android 或 Web 版本。
- Developer ID、notarization、TestFlight 與 App Store 上架流程。
- 重新設計 App icon、品牌識別或行銷 landing page。
- 對六個機器輔助語言做母語內容校對；但本規格新增字串仍必須通過八語 key coverage gate。
- Phase 1 的 iPad 多選與批次匯出。

## 9. 預計觸及模組

### 9.1 Phase 1 主要檔案

- `Sources/LumaHarborApp/Views/RootView.swift`
- `Sources/LumaHarborApp/Views/InspectorView.swift`
- `Sources/LumaHarborApp/Views/EditorView.swift`
- `Sources/LumaHarborApp/Views/LibraryGridView.swift`
- `Sources/LumaHarborApp/Views/ThumbnailView.swift`
- `Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift`
- `Sources/LumaHarborApp/LumaHarborCommands.swift`
- `Sources/EditorCore/LibraryBrowserSession.swift`，只在需要抽出共用 query coordination 時修改
- `Sources/PhotoLibraryCore/Model/LibraryQuery.swift`
- `Sources/PhotoLibraryCore/Index/PhotoIndexStore.swift`
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadAppServices.swift`
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift`
- 新增 iPad export coordinator／share bridge 檔案
- iPad target 的 `NSPhotoLibraryAddUsageDescription` 與八語 `InfoPlist.strings`
- `Sources/Localization/Resources/*/Localizable.strings`

### 9.2 不應修改

- Phase 1 不修改 `PhotoAdjustments` schema 與既有 sidecar migration。
- Phase 1 不修改 RAW kernel、調色 mapping 或 geometry render order。
- Xcode project 只允許加入 Photos usage description／resource wiring；不得改動使用者的 signing、Team ID 或 provisioning 設定。
- Xcode 自動產生的個人 signing 變更維持 local-only。

## 10. 實作拆分與順序

每個 task 必須使用 TDD，先 RED，再 GREEN，再跑 focused tests；不得一次提交整個 Phase 1。

1. Task 1：Inspector tab／group state policy 與 source contract tests。
2. Task 2：Inspector 三分頁 UI，保留 Preset 與 metadata 既有功能。
3. Task 3：Canvas viewport model、倍率／offset clamp 與座標轉換測試。
4. Task 4：Mac zoom／pan UI 與四種 overlay 共用 transform。
5. Task 5：Mac query controls、搜尋 debounce、排序與 grid density。
6. Task 6：多選 state machine、Shift range、全選與批次操作列。
7. Task 7：iPad export coordinator 與 exporter dependency wiring。
8. Task 8：iPad Photos／Files／share UI 與失敗狀態。
9. Task 9：全套自動化、Mac 手動 QA、iPad 實機驗收與報告。

Task 1-2、Task 3-4、Task 5-6、Task 7-8 各自形成可 review 的功能單位。Task 7 必須先完成，Task 8 才能開始；其他功能單位可依不同 worktree 平行開發，但不可共用可寫工作目錄。

## 11. 測試與驗證

### 11.1 自動化

- Inspector state model tests。
- Inspector、LibraryGrid、toolbar 與 iPad export UI source contract tests。
- Canvas zoom、pan clamp、anchor preservation、Retina 100% 與 coordinate transform tests。
- Crop、eyedropper、linear gradient、spot heal 在 zoom／pan 下的 regression tests。
- Search debounce、stale result rejection、四種排序與 query change selection tests。
- Shift selection、全選、清除、批次目標一致性與 accessibility tests。
- iPad exporter request mapping、flush-before-export、single-flight、cancel cleanup 與 path-safe error tests。
- `swift build -Xswiftc -strict-concurrency=complete`。
- `swift test`。
- `xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`。
- `Scripts/build-app-bundle.sh release`。
- `git diff --check` 與 privacy／signing scan。

### 11.2 人工畫面驗收

Mac：

- 1280 x 800 與 1728 x 1117 視窗。
- 深色與暖白相紙主題。
- 空圖庫、圖庫有資料、單張 editor、離線來源、decode failure。
- 三種密度、多選操作列、100%／400% canvas、四種 overlay。
- 鍵盤、滑鼠與觸控板各自完成主要流程。

iPad：

- 11-inch 與 13-inch 尺寸的 simulator layout。
- portrait、landscape 與 Split View。
- 真機完成 Photos、Files、share 三種輸出。
- 外接來源拔除、Photos 權限拒絕、分享取消與輸出中斷。

### 11.3 視覺回歸

若 `shot`／`gallery` runner 尚未完成，相關項目記為 `NOT RUN`，不得用 source contract 取代真實畫面證據。Phase 1 至少保存下列人工截圖：

- Mac inspector 三分頁。
- Mac grid 三種密度與多選狀態。
- Mac Fit、100%、400% 預覽。
- iPad 匯出 menu、輸出中與成功狀態。

## 12. 失敗模式與 rollback

| 失敗 | 必要行為 | Rollback |
| --- | --- | --- |
| Inspector 新結構遺漏舊功能 | contract tests 必須列出原有調整群組、Preset 與 metadata | 回退 View 組合，不涉及資料 migration |
| Zoom transform 讓 overlay 命中錯位 | 禁止發布；四種 overlay 的 normalized coordinate tests 必須全綠 | feature flag 回到 fit-only canvas |
| Mac query 出現 stale result | generation/token 驗證丟棄舊結果 | 回到既有 library reload，不修改 index schema |
| 多選對隱藏照片執行批次 | scope／search change 強制清除選取 | 關閉選取模式；不改 sidecar schema |
| iPad 匯出中來源離線 | 停止、清理 temp、保留 RAW 與調整，提示重新連接 | export coordinator 回到 idle，可安全重試 |
| Photos 權限拒絕 | 提供 Files／分享替代入口 | 不變更系統權限，不重複彈 request |
| 分享取消 | 清理 temp，記為 cancelled | 無使用者資料 rollback |
| 完整解析度輸出失敗 | 不留下最終檔，不宣稱成功 | 既有 `PhotoExporter` 原子輸出契約處理 |

Phase 1 沒有持久資料 schema migration，因此可由功能層 commit 逐一回退。若實作中發現必須修改 sidecar 或不可重建資料，停止該 task，另寫 migration spec，不得在本規格下直接實作。

## 13. Definition of Done

Phase 1 只有在以下項目全部成立時才可標示完成：

1. 5.1 至 5.5 的驗收條件全部有證據。
2. 所有 focused tests、完整 `swift test`、strict concurrency build、Mac app bundle 與 unsigned iOS generic build 均 PASS。
3. Mac 人工 QA 與 iPad 真機 Photos／Files／share checklist 均 PASS，沒有必要項目為 `NOT RUN`。
4. Sony RAW 在編輯與匯出前後 SHA-256 相同。
5. 八語 localization key coverage PASS；未完成母語審校需保留為已知限制。
6. changed-file privacy scan 沒有私人路徑、Team ID、UDID、provisioning profile、憑證或 secret。
7. `docs/coordination/CURRENT.md`、驗證報告與使用者文件已更新。
8. 使用者核准實際畫面與操作結果。

## 14. 核准後下一步

1. 將 Phase 1 拆成逐 task implementation plan，標出 RED test、production files、focused commands 與 commit 邊界。
2. 優先實作 Inspector Task 1，不與目前尚未提交的 Preset 安全強化變更混在同一 commit。
3. 每完成一個功能單位先 review 與驗證，再進下一單位。
