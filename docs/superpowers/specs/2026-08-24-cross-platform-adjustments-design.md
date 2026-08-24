# LumaHarbor 跨平台專業調整與 iPad 設計

日期：2026-08-24

狀態：設計已由產品決策確認，尚未開始實作。

基準版本：`a78752e`（`claude/preset-xmp-compatibility`）

## 1. 目的

LumaHarbor 要從目前的 macOS RAW 編輯 MVP，演進成可在 Mac 與 Apple Silicon iPad
完整使用的非破壞性照片編輯器。產品要提供與 Lightroom Classic 主要全域調整面板
相對應的功能，但不複製 Adobe 私有演算法、相機描述檔或介面。

本設計涵蓋：

- Mac 與 iPad 共用的調整模型、渲染核心、Preset／XMP 與測試向量。
- iPad 完整照片庫、Files／外接 SSD、匯入 App 儲存、編輯及匯出工作流程。
- 十個全域調整面板的長期完整範圍及依賴順序。
- 橫向停駐、直向抽屜與專注模式浮動面板的自適應介面。
- 完全在裝置上執行的 AI／ML 功能，以及跨裝置一致性與驗收方式。

## 2. 已確認的產品決策

- 長期交付全部十個全域面板：基本、色調曲線、色彩混合器、色彩分級、細節、
  鏡頭校正、變形、鏡頭模糊、效果、校正。分階段是依賴管理，不代表刪除控制項。
- 裁切、修復／移除、紅眼、遮色片與局部調整屬於第二條工具路線，在全域面板後交付。
- iPad 是完整 App，不是 Mac companion；支援照片庫、外接 SSD／Files、全部調整、
  Preset／XMP 與匯出。
- iPad 最低硬體為 M1 或更新的 Apple Silicon iPad。
- 外接檔案預設原地使用，也允許複製到 LumaHarbor 的 iPad 儲存空間後離線編輯。
- 複製到 iPad 時可保留來源連結；重新接上外接磁碟後提供明確的手動匯回／同步，
  不自動覆寫來源或副本。
- 同一照片庫只允許一個寫入者；其他裝置唯讀。第一版不做 last-write-wins 或衝突合併。
- Mac 與 iPad 共用視覺語言，但保留各平台原生外殼和輸入行為。
- 介面採混合配置：工作模式為橫向右側停駐面板／直向底部抽屜；專注模式為可移動、
  可收合浮動面板。
- 觸控、Apple Pencil、鍵盤及觸控板／滑鼠都是一級輸入方式。
- RAW 降噪、景深估算、鏡頭模糊等 AI／ML 功能完全在裝置上執行，照片不需上傳，
  離線可完整使用。

## 3. 非目標與相容性界線

- 不承諾與 Lightroom／Camera Raw 逐像素一致；目標是功能對應、參數語意清楚、結果穩定。
- 不使用或重製 Adobe 私有處理演算法、相機描述檔與介面資產。
- 不在第一版實作多裝置同時編輯、CRDT、自動衝突合併或 last-write-wins。
- 不允許編輯流程改寫 RAW 原檔。
- 不讓 XMP 取代 LumaHarbor 的正式編輯狀態；XMP 是交換與搬家格式。
- 不在本設計內承諾非 Apple 平台。

## 4. 架構

### 4.1 Target 分工

`RawProcessingCore`：

- 持有版本化的調整模型、色彩處理、渲染順序、預覽與完整解析度輸出。
- 不依賴 SwiftUI、AppKit、UIKit、PhotosUI 或 security-scoped resource。
- 為 GPU 與參考實作提供一致的輸入／輸出契約。

`PresetCore`：

- 持有原生 Preset、AdjustmentPatch、XMP codec、mapping registry 與未知欄位保存。
- 與平台 UI、選檔器及照片庫路徑隔離。

`PhotoLibraryCore`：

- 持有圖庫索引、照片身份、編輯交易、來源連結、預覽快取 metadata 與單一寫入者租約。
- 定義檔案存取、bookmark／授權恢復、磁碟事件及 App 儲存所需的協定。
- 不直接依賴 AppKit／UIKit；平台實作由 App shell 注入。

`EditorCore`（新增）：

- 持有平台中立的 editor session、目前照片、transient preview、dirty state、Undo／Redo、
  render scheduling 與使用者 command。
- 協調 `RawProcessingCore`、`PresetCore` 與 `PhotoLibraryCore`，但不建立視圖、選檔器或平台視窗。
- Mac 與 iPad 必須使用同一套 session state machine，避免兩個 App shell 各自複製 view model。

`AdjustmentUI`（新增）：

- 共用十個面板的 SwiftUI 元件、參數顯示、數值輸入、Undo intent、重設與可及性語意。
- 元件必須能在停駐面板、底部抽屜與浮動容器中使用，不持有平台視窗物件。
- 不直接讀寫檔案或呼叫 Core Image；只向 `EditorCore` command contract 發出意圖。

`LumaHarborMacApp`：

- macOS 視窗、AppKit 選檔器、選單、鍵盤命令、拖放與 security-scoped resource 實作。

`LumaHarborPadApp`（新增）：

- iPadOS scene、PhotosPicker／file importer、文件授權、touch／Pencil 行為、分享與背景工作。

### 4.2 依賴方向

```text
RawProcessingCore ← PresetCore ← PhotoLibraryCore
        ↑               ↑              ↑
        └──────────── EditorCore ───────┘
                        ↑
                  AdjustmentUI
                    ↗       ↖
          LumaHarborMacApp   LumaHarborPadApp
```

箭頭指向被依賴的 target。`PhotoLibraryCore` 沿用現況，依賴 `PresetCore` 與
`RawProcessingCore`；`EditorCore` 協調三個 core；`AdjustmentUI` 只依賴 editor contract。
不允許 core 反向依賴 UI。平台差異透過協定及 shell adapter 隔離，不得把大量
`#if os(macOS)`／`#if os(iOS)` 散落於功能核心。

### 4.3 漸進遷移

不一次重寫現有 Mac App。先把現有 editor session／view model 邏輯抽到 `EditorCore`，
再把十個基本調整的 UI 元件抽到 `AdjustmentUI`，最後建立 iPad shell；每次抽離都須保持
現有 Mac 行為與測試通過。

## 5. 儲存、來源身份與非破壞性編輯

### 5.1 兩種來源模式

1. **原地使用（預設）**：照片留在 Files 或外接 SSD，LumaHarbor 經持久授權直接讀取。
2. **複製到 App**：將使用者選取的原檔複製到 LumaHarbor 管理的 iPad 儲存，供離線使用。

兩種模式均保持 RAW 原檔不可變。圖庫保存索引、預覽快取、編輯狀態、來源身份與匯出紀錄；
最終成品寫成新檔。

### 5.2 複製與來源連結

- 複製必須採 copy → checksum／size 驗證 → repository transaction commit；中途失敗不得產生完整匯入紀錄。
- iPad 副本與外接來源是兩個檔案身份，不能因檔名相同而自動互相覆寫。
- 可保存來源 volume identifier、file identifier、相對路徑、檔案大小及必要的內容 fingerprint。
- 重新掛載來源後，只有身份驗證通過才顯示「匯回」或「更新來源」動作。
- 同步第一版由使用者明確觸發，先顯示方向、將寫入的檔案與衝突摘要。

### 5.3 外接磁碟中斷

- 停止對該來源的新寫入，保留上一個完整交易。
- 尚未保存的參數放入本機復原區，不宣稱已寫回來源。
- 預覽快取仍可顯示，但 UI 明確標示原檔離線。
- 重新掛載並驗證身份後才可恢復；同名 volume 或同路徑不足以證明是原來源。

### 5.4 單一寫入者租約

- 同一照片庫同時只有一個有效寫入租約，其他裝置唯讀但仍可瀏覽及匯出。
- 租約包含 library ID、writer device/session ID、建立時間、續租時間及 schema version。
- 正常關閉或使用者主動釋放時撤銷租約；異常退出由有限期限及復原檢查判斷。
- 無法可靠判定租約失效時維持唯讀，不提供強制覆蓋捷徑。
- 所有編輯以原子交易提交；重啟時只恢復至最後完整交易。

## 6. 十個全域面板與交付波次

每一波都必須在 Mac 與 iPad 同時可用，並包含 UI、model、render、Preset／XMP、Undo、
舊編輯重開與驗收；不能只增加看得到但不參與渲染的控制項。

### Wave 0：跨平台基礎

- 新增 iPad App、`EditorCore`、`AdjustmentUI` 與平台服務協定。
- 接通現有基本調整、Undo／Redo、Preset／XMP、匯出與預覽。
- 完成外接原地使用、複製到 iPad、來源連結、圖庫索引及單一寫入者。
- 建立 Mac／iPad 相同 render state 的一致性測試基線。

### Wave 1：已有引擎、主要缺 UI

- **色調曲線**：先接通現有 master curve，再擴充 RGB 分色曲線。
- **色彩混合器**：接通現有八色 HSL。
- **效果**：接通現有暗角與顆粒。
- **基本**：保留現有控制並補齊紋理、清晰度、去朦朧及對應渲染。

### Wave 2：擴充現有處理能力

- **色彩分級**：陰影、中間調、高光、全域、混合與平衡；取代僅有陰影／高光的限制。
- **細節**：銳利化 amount／radius／detail／masking，以及獨立明度與彩色雜訊抑制。
- **校正**：版本化相機／色彩基線與 RGB 原色 hue／saturation 調整。

### Wave 3：描述檔與幾何

- **鏡頭校正**：描述檔選擇、色差、變形及鏡頭暗角修正。
- **變形**：旋轉、水平、垂直、長寬比例、縮放及自動透視；定義裁切外區域處理。

### Wave 4：裝置端 ML

- **鏡頭模糊**：裝置端景深圖、焦點選擇、焦距範圍及散景控制。
- RAW 降噪可共用同一 ML 基礎設施，但是獨立、可取消的工作，不阻塞一般調整。

### 後續工具路線

- 裁切與旋轉。
- 修復／移除。
- 紅眼。
- 遮色片與局部調整。

工具路線須使用相同的編輯交易、版本化及非破壞性原則，但不能為了工具路線延後
已承諾的十個全域面板。

## 7. 自適應介面與輸入

### 7.1 工作模式

- Mac 與橫向 iPad：右側停駐調整面板，中央為影像畫布。
- 直向 iPad：同一面板內容放入可調高度的底部抽屜。
- 工具列依可用空間收合；面板可收合、重新排序並保存每台裝置的介面偏好。
- iPad split view 與 Stage Manager 改變尺寸時，依 size class／實際寬度切換容器，
  不銷毀 editor session。

### 7.2 專注模式

- 最大化畫布，使用可移動、可收合的浮動調整面板。
- 工作／專注模式切換保留照片、選取面板、調整值、縮放與視口。
- 介面切換不是影像編輯，不改 dirty state，也不增加 Undo。

### 7.3 一級輸入

- 觸控：滑桿、雙指縮放、拖動畫布、長按重設。
- Apple Pencil：曲線控制點的精細操作，後續支援遮色片／修復筆刷。
- 鍵盤：方向鍵微調、數值輸入、工具快捷鍵、Undo／Redo。
- 觸控板／滑鼠：hover 預覽、滾輪微調與 context menu。
- 所有 hover 功能必須有可見的觸控替代入口。
- 精密控制須有放大編輯區、控制點防遮擋與直接數值輸入。
- 控制元件提供 VoiceOver label、value、adjustable action、焦點順序及動態字級策略。

## 8. 渲染、版本與裝置端 AI

### 8.1 渲染契約

- Mac 與 iPad 共用 `PhotoAdjustments` schema、運算順序、工作／輸出色彩空間與 render version。
- 優先使用 Metal／Core Image GPU 路徑；保留可測試的 CPU／參考路徑。
- 拖曳時可用降解析度、節流與 region update；停止互動後補高品質預覽。
- 完整匯出必須從原檔執行正式品質管線，不沿用快速預覽 raster。
- 運算順序與行為變更必須提升 render version；舊照片預設沿用舊版本外觀。

### 8.2 跨裝置一致性

- 同一 fixture、參數、render version 與 model version，在 Mac／iPad 輸出須落在預先定義的
  像素、色差及結構相似度容差。
- 浮點或 GPU 差異以容差驗證，不用脆弱的逐 byte 比較。
- Preset／XMP 未知欄位繼續依既有 compatibility layer 保存，不得因 iPad 往返遺失。

### 8.3 AI／ML

- 模型推論、輸入前處理及結果套用完全在裝置上，不上傳照片、預覽或特徵。
- 模型隨 App 版本管理，Mac 與符合最低硬體的 iPad 使用相同 model version。
- 模型升級不自動改變既有照片；使用者明確選擇重新處理後才更新結果及版本。
- 長工作提供進度、取消與可恢復狀態；取消保留上一個完整結果。
- 記憶體壓力、進入背景或 thermal state 變化時可降低並行度，不得產生半套用狀態。

## 9. 錯誤處理

- 空間不足：寫入前估算並檢查，失敗時指出未完成項目，不留下假成功紀錄。
- RAW／Preset／XMP 損壞：隔離單檔並輸出安全診斷，不阻止其他照片或 Preset 使用。
- XMP 未支援欄位：保存並標示，不能默默丟棄或假裝已套用。
- 渲染／AI 中斷：顯示可重試／取消狀態，維持上一個完整渲染結果。
- 圖庫租約衝突：明確顯示唯讀狀態及目前 writer，不允許繞過交易保護。
- App crash／kill：重新開啟後回到最後完整交易；復原區內容需由明確流程重新套用。
- 錯誤、log、測試報告與 diagnostics 不包含私人絕對路徑或原始 XMP 敏感內容。

## 10. 測試策略

### 10.1 單元與整合測試

- 十個面板每個 leaf 的範圍、neutral、canonicalization、Codable migration 及參數 version。
- 調整、重設、複製貼上、Preset 套用皆以正確粒度形成 Undo／Redo。
- Preset／XMP 匯入、匯出、往返與未知欄位保存。
- 固定 fixture 的運算順序與 golden image 容差。
- GPU 與參考路徑、Mac 與 iPad 的跨裝置容差。
- 外接磁碟中斷／重掛、檔案身份不符、空間不足、租約競爭及 crash recovery。
- 原地來源、App 儲存及經確認的手動匯回。
- AI 進度、取消、背景恢復、model version、離線及記憶體壓力。
- 大量照片切換與批次輸出的記憶體上限、thermal behavior 及子程序清理。

### 10.2 人工矩陣

- macOS 與至少兩種 M 系列 iPad 尺寸。
- iPad 橫向、直向、split view、Stage Manager。
- 觸控、Apple Pencil、鍵盤、觸控板與滑鼠。
- Sony RAW fixtures、JPEG、TIFF、原生 Preset 與 Lightroom 產生的 XMP。
- APFS、真正的 exFAT、Files provider 與 iPad App 儲存。
- Lightroom Classic 作功能與 XMP 行為比較基準，但不以 Adobe 私有顯色逐像素一致為 gate。

### 10.3 效能指標

每個交付波次記錄且比較：

- 滑桿／曲線互動 frame pacing 與 input latency。
- 首張 RAW 預覽時間。
- 相片切換與快取命中時間。
- 完整解析度匯出時間及 peak resident memory。
- 長批次的 thermal throttling、取消延遲與穩定性。

初始基準可先測量現況；正式數值門檻須在 Wave 0 以目標裝置實測後鎖定，不在沒有
硬體證據時捏造。

## 11. 階段驗收條件

一個面板或波次只有在以下條件全部成立時才算完成：

- 對應功能在 Mac 與 M1+ iPad 都可操作，且沒有只在單一平台存在的隱藏路徑。
- 控制項確實參與 render，Preset／XMP／Undo／舊編輯 migration 的語意一致。
- RAW 原檔未被改寫，失敗與取消不留下部分交易。
- 自動測試、真實裝置矩陣及既有 MVP acceptance 通過。
- summary 與 log 不含私人絕對路徑；`SKIPPED` 不得當作 `PASS`。
- 已知相容差異、演算法近似與效能退化均寫入驗收報告。

## 12. 實作起點

第一份實作計畫只涵蓋 Wave 0，不同時開發十個面板。建議最小垂直切片為：

1. 將目前 editor session、基本調整狀態與 command 抽入平台中立的 `EditorCore`。
2. 將 SwiftUI control 抽入只依賴 editor contract 的 `AdjustmentUI`。
3. 建立可編譯的 iPad App shell，顯示同一 editor session 與十個現有基本滑桿。
4. 建立平台檔案服務協定，完成單張 RAW 從 Files／外接來源原地開啟。
5. 完成複製到 App 儲存、來源連結與非破壞性 sidecar。
6. 加入單一寫入者租約及唯讀 UI。
7. 接通 Preset／XMP、匯出、跨平台渲染容差與真實裝置驗收。

Wave 0 通過後，才依第 6 節順序為每個後續面板建立獨立實作計畫與驗收報告。
