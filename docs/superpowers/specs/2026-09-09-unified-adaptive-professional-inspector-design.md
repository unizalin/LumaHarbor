# LumaHarbor 統一自適應專業面板設計規格

- 狀態：待使用者審閱
- 日期：2026-09-09
- 目標平台：macOS 14+、iPadOS 17+
- 目標裝置：Apple silicon Mac、M1 或更新 iPad
- 基準分支：`codex/open-source-release-prep`
- 基準提交：`22aedc5`
- 核准方向：A. 統一自適應專業面板
- 關聯文件：`2026-09-09-ipad-studio-rails-mac-feature-parity-design.md`、`2026-09-09-professional-editing-roadmap-design.md`

## 1. 決策摘要

LumaHarbor 的 Mac 與 iPad 編輯器改用同一套面板資訊架構：共用功能域、section、搜尋、收藏、重設與調整識別碼，平台 View 只負責適合滑鼠、鍵盤或觸控的呈現。

新版以照片畫布為主體。使用者透過固定工具軌在 Adjust、Geometry、Local、Preset、Info 五個功能域間切換；Inspector 同一時間只顯示目前功能域，不再把所有調整堆成一條長清單。常用控制可固定在頂部，其他控制透過 section、搜尋與智慧切換快速到達。

本案不新增 RAW 演算法或新的修圖欄位，重點是整理既有能力、消除 Mac／iPad 重複實作、縮短操作路徑並提升窄視窗與觸控可用性。

## 2. 現況問題

### 2.1 Mac

- Inspector 將 Basic、Color、Curve、Detail、Effects、Geometry、Local 串成長捲動清單；功能增加後定位成本持續上升。
- Adjustments、Presets、Metadata 使用頂部分頁，但 Geometry 與 Local 同時又存在 Adjustments 長清單中，資訊層級不一致。
- Reset All 與調整動作占用 header 空間，窄 Inspector 容易壓縮標題或按鈕。
- 展開狀態只屬於 View 本機，無法與搜尋、工具切換或平台共用一致語意。

### 2.2 iPad

- `PadEditorView.swift` 內仍存在私有 `PadToolRail`／`PadInspectorHost`，同時專案中已有獨立同名檔案；新舊實作可能各自演進。
- 某些舊 host 仍保留 Info 未接線 placeholder，與目前已具備 histogram、metadata 與 curation 的功能狀態不一致。
- Expanded／Wide 與 Compact／Standard 雖有不同 presentation，但 header、domain bar、section 與 action 的組成尚未由同一份模型驅動。
- 觸控版若直接沿用桌面長清單，會讓 sheet 過長、畫布過小，且精確數值與局部工具容易被埋沒。

### 2.3 共同問題

- 功能定義、圖示、分組、搜尋名稱與預設展開狀態散落在平台 View。
- 沒有「常用控制」與跨 section 搜尋，使用者必須記住功能所在位置。
- 畫布工具與 Inspector domain 未建立明確的跟隨／鎖定規則。
- 若繼續直接在大型 SwiftUI View 增加條件，測試與維護成本會快速上升。

## 3. 目標與非目標

### 3.1 目標

1. 任一主要功能域最多兩次操作可到達。
2. Mac 與 iPad 共用面板語意與資料流，但保留各自適合的密度與 presentation。
3. 畫布永遠優先；面板不得在窄視窗持續擠壓畫布。
4. 搜尋、收藏、展開狀態與智慧切換不建立 undo、不觸發 autosave、不重新 decode RAW。
5. 所有調整繼續使用既有 stable field ID、EditorSession、sidecar、preset 與 batch 語意。
6. 清除重複的 iPad rail／host，建立唯一可驗證的 composition path。

### 3.2 非目標

- 不新增 AI 遮色、鏡頭 profile、色彩分級或 Phase 2+ 調整演算法。
- 不建立可任意拖曳、浮動或多欄排列的完整自訂工作區。
- 不把 SwiftUI View 或 `AnyView` 存進共用 catalog。
- 不跨裝置同步收藏與面板偏好；第一版只保存於本機 App preferences。
- 不改變 RAW、sidecar 或 preset 檔案格式。

## 4. 統一資訊架構

### 4.1 五個功能域

| Domain | 內容 | 預設圖示 |
| --- | --- | --- |
| Adjust | Light、Color、Detail | `slider.horizontal.3` |
| Geometry | Crop、比例、旋轉、翻轉、拉直 | `crop.rotate` |
| Local | Linear Gradient、Spot Heal、局部物件 | `paintbrush.pointed` |
| Preset | 內建、自訂、收藏、搜尋、匯入匯出 | `sparkles` |
| Info | Histogram、EXIF、評分、旗標、關鍵字、儲存狀態 | `info.circle` |

功能域順序在 Mac 與 iPad 一致，不因視窗寬度改變。切換 presentation 時保留目前 domain。

### 4.2 Adjust 子模式

Adjust 頂端使用 Light、Color、Detail segmented control：

- **Light**：Exposure、Contrast、Highlights、Shadows、Whites、Blacks、Tone Curve。
- **Color**：Temperature、Tint、白平衡滴管、Vibrance、Saturation、八色 HSL。
- **Detail**：Sharpening、Noise Reduction、Vignette、Grain。

子模式只負責分類，不建立另一份調整資料。切換子模式時維持畫布、zoom、pan、undo 與未提交工具狀態。

### 4.3 面板垂直結構

Inspector 由下列固定區域組成：

1. **Header**：domain 標題、搜尋、收藏檢視與單一 overflow menu。
2. **Context bar**：Adjust 子模式、Local 目前物件或 Preset scope 等情境控制。
3. **Quick Controls**：使用者收藏的控制；沒有收藏時不保留空白。
4. **Section List**：目前 domain 的完整控制，以 divider 分隔，不使用巢狀卡片。
5. **Status Footer**：儲存狀態、目前 section reset；Reset All 放進 overflow 並要求確認。

Header、Context bar 與 Status Footer 固定；只有 Quick Controls 與 Section List 捲動。如此可在長面板中持續看見目前位置與儲存狀態。

## 5. 排版規格

### 5.1 Mac

- 工具軌固定在畫布與 Inspector 之間，寬度 48–52 pt。
- Inspector 預設 360 pt，可在 300–440 pt 間拖曳；使用既有 workspace preference 保存寬度。
- Header 高度 44 pt。常用命令使用 icon button 與 tooltip，避免窄寬度下堆疊文字按鈕。
- 調整列最小高度 36 pt；名稱、slider、數值欄位使用穩定 grid track，數值改變不得造成水平位移。
- 寬度 380 pt 以上可讓短控制使用雙欄；長 slider、Curve、HSL、Histogram 與 Local 物件永遠全寬。
- 寬度不足時先取消雙欄，再縮短輔助文字；不得縮小字體硬塞。
- 收合 Inspector 時只保留工具軌，畫布取得釋放空間；重新開啟回到原 domain 與 scroll anchor。

### 5.2 iPad Expanded／Wide

- 左手模式關閉時，垂直工具軌位於畫布左側，Inspector 位於右側；左手模式將兩者成對鏡像。
- 工具軌寬 56 pt，每個按鈕至少 44×44 pt。
- Inspector 預設 360 pt，可依可用寬度在 320–420 pt 間調整。
- 13 吋 Wide 可顯示收藏控制與完整 section；11 吋 Expanded 優先保留畫布，只在足夠寬度時使用雙欄短控制。
- Filmstrip 與 Inspector 各自可收合；收合順序遵循 details、filmstrip、Inspector、tool rail，畫布最後縮小。

### 5.3 iPad Compact／Standard

- 五項工具軌移到底部 safe-area inset，高度 56 pt，不遮住畫布或照片內容。
- Inspector 使用 bottom sheet，提供 medium 與 large detent；拖曳高度不得改變 editor state。
- 切換 domain 會替換同一張 sheet 的內容，不疊加第二張 sheet。
- 數值列觸控高度至少 44 pt；數值欄位點擊後使用適合正負數與小數的鍵盤。
- 搜尋啟用時 sheet 自動使用 large detent，結束搜尋後回到先前 detent。

### 5.4 視覺層級

- 畫布、工具軌、Inspector 是三個相鄰區域，不把整個 Inspector 包成浮動卡片。
- Section 使用標題、divider 與適度間距，不使用 card-in-card。
- Selected domain 使用 accent foreground、固定背景槽與 accessibility selected trait；選取不得改變按鈕尺寸。
- Histogram、Curve 與照片預覽維持中性色背景；警告、儲存成功與失敗才使用語意色彩。
- 所有文字 letter spacing 為 0，面板內不使用 hero 尺寸標題。

## 6. 搜尋、收藏與智慧面板

### 6.1 搜尋

- 搜尋涵蓋 domain、section、控制顯示名稱、同義詞與在地化關鍵字。
- 結果仍使用原始控制 View，不建立功能副本。
- 選取結果後切到正確 domain／submode、展開 section、捲動到控制並短暫標示；不修改數值。
- 搜尋不到結果時顯示簡短空狀態與清除按鈕，不顯示教學式功能說明。

### 6.2 收藏常用控制

- 每個可收藏控制使用 stable field ID；Geometry、Local 物件命令與危險動作不進收藏。
- 收藏區顯示在目前 domain 頂部，只顯示屬於該 domain 的控制。
- 第一版沒有預設收藏；避免替使用者猜測工作流。
- 收藏順序依加入時間，可透過管理畫面重新排序；拖曳排序不出現在主要 Inspector。
- 收藏保存在裝置本機 preferences，不寫入 sidecar、preset 或照片 metadata。

### 6.3 智慧跟隨與鎖定

- 啟用 Crop、White Balance Eyedropper、Gradient 或 Heal 時，Inspector 自動切到對應 domain／section。
- 使用者可按下 Pin 鎖定目前 domain；鎖定期間工具不強制切換面板，但 active tool 的必要取消／完成控制仍保留在畫布 toolbar。
- 智慧切換只更新 presentation state，不建立 undo 或 autosave。
- 工具 commit／cancel 後回到啟用工具前的 domain，除非使用者期間手動切換或鎖定。

## 7. 共用模型與元件邊界

### 7.1 純資料 catalog

在 `AdjustmentUI` 建立平台中立的描述模型：

- `InspectorDomainID`
- `InspectorSubmodeID`
- `InspectorSectionID`
- `InspectorControlID`
- `InspectorCatalog`
- `InspectorSearchIndex`

Catalog 只保存 ID、順序、圖示名稱、localization key、stable field ID、搜尋 alias 與 capability requirement。它不持有 SwiftUI View、binding、EditorSession 或 closure。

### 7.2 Presentation state

建立單一 `InspectorPresentationState`，負責：

- active domain 與 Adjust submode；
- 展開的 section；
- search query 與搜尋定位目標；
- favorite IDs 與排序；
- pin 狀態、sheet detent、scroll anchor；
- 工具啟用前的返回位置。

它不得持有 `PhotoAdjustments`、照片 URL、metadata 或第二份 undo stack。

### 7.3 平台 composition

- `LumaHarborApp`：Mac rail、resizable Inspector、hover／tooltip、keyboard focus 與 menu command。
- `LumaHarborPadApp`：觸控 rail、bottom sheet、Pencil／touch focus、left-handed layout 與 scene lifecycle。
- `AdjustmentUI`：共用 panel、row、catalog、搜尋與 section header。
- `EditorCore`：調整、工具、save、undo、compare 與 editor intent 的唯一權威。

平台 View 以 switch 或明確 factory 組合既有 typed panel，不使用 `AnyView` registry。

## 8. 重複實作清理

1. 以獨立的 `PadToolRail.swift` 與 `PadInspectorHost.swift` 為唯一檔案。
2. 先補 composition contract，確認 `PadEditorView` 只引用獨立型別。
3. 移除 `PadEditorView.swift` 內的私有同名實作及其舊 placeholder。
4. 將 domain item 清單移到共用 catalog，compact bar 與 vertical rail 不再各自維護圖示與順序。
5. Mac `InspectorTab`／`InspectorGroup` 改用共用 domain／section ID；先維持既有功能，再切換新版 layout。
6. 每一步都必須可獨立編譯與測試，不以一次巨大重寫替換整個 Editor。

## 9. 資料流與行為契約

```text
使用者輸入
  -> 平台 rail / inspector presentation
  -> InspectorPresentationState
  -> typed shared panel
  -> EditorSession / PresetCore / PhotoLibraryCore
  -> preview
  -> commit
  -> undo + autosave + sidecar
```

- Rail、搜尋、收藏、展開、resize 與 sheet detent 停留在 presentation 層。
- Slider／數值輸入沿用 begin gesture、interactive preview、single commit 語意。
- Reset Section 只重設該 section 的 stable field IDs，產生一筆 undo。
- Reset All 需確認，並產生可一次復原的單一 transaction。
- 搜尋結果不得建立第二份 binding；收藏控制與原 section 控制必須同步顯示同一數值。
- 離線照片仍可查看快取 metadata；需要原檔的調整或輸出操作顯示明確 disabled reason。

## 10. 鍵盤、觸控與無障礙

### 10.1 Mac

- `⌘F` 在 Inspector 可見時聚焦面板搜尋；圖庫搜尋仍由既有 context 決定。
- `⌘1` 至 `⌘5` 切換五個 domain，但文字輸入中不得攔截。
- Tab 順序依 Header、Context、Quick Controls、Section List、Footer。
- Icon button 必須有 localized tooltip 與 accessibility label。

### 10.2 iPad

- 所有主要功能可只靠觸控完成，鍵盤與 Pencil 僅提供加速。
- Slider row 提供 VoiceOver adjustable action、目前值、單位與 Reset action。
- Dynamic Type 無法容納垂直 rail 標籤時維持 icon rail，不縮小命中區。
- Reduce Motion 開啟時，domain、sheet 與搜尋定位只使用淡入淡出或無動畫。

## 11. 錯誤與狀態

- 儲存失敗固定顯示在 Status Footer，錯誤內容不得包含絕對路徑。
- Preset、Local、Geometry 或匯出不可用時顯示具體 disabled reason，不靜默無反應。
- Search index 建立失敗時仍可使用 domain 與 section，不阻斷修圖。
- 收藏中遇到已移除或不支援的 field ID 時忽略該項並清理 preferences，不造成啟動失敗。
- 切換照片、來源離線、旋轉或 resize 時，不得遺失已 commit 的調整或建立額外 undo。

## 12. 效能要求

- domain 切換到可互動狀態目標小於 100 ms，不觸發 RAW decode。
- 搜尋 100 個以內控制時每次查詢目標小於 16 ms。
- 收藏與 section 展開不得重建 EditorSession 或清除 preview cache。
- slider 互動期間不因面板 layout 重新計算而低於既有 preview baseline。
- Compact sheet 拖曳只更新 presentation，不重算 full-resolution export。

## 13. 驗收標準

### 13.1 自動化

- Catalog 完整涵蓋五個 domain，stable ID 不重複，八語 localization key 完整。
- 搜尋可由各語言名稱與 alias 找到正確 control，定位不修改調整值。
- 收藏與原 section 使用相同 binding，修改任一入口只產生一筆 undo。
- Reset Section、Reset All、smart follow、pin、resize 與 detent 具備狀態測試。
- Contract test 確認 `PadEditorView.swift` 不再宣告私有 `PadToolRail`／`PadInspectorHost`。
- 完整 `swift test`、strict-concurrency build、Mac build 與 iPad simulator build 均 PASS。

### 13.2 Mac 人工驗收

- 1280×800、1728×1117 與最小視窗寬度。
- Inspector 300、360、440 pt；收合／展開與 App 重啟後狀態。
- 五個 domain、搜尋、收藏、smart follow、pin、Reset Section／All。
- 滑鼠、鍵盤、深色／暖白／系統主題與八語至少 smoke test。

### 13.3 iPad 人工驗收

- 11 吋與 13 吋 M 系列 iPad，橫向、直向、Split View、Stage Manager。
- Expanded／Wide rail 與 Compact／Standard bottom sheet。
- 左手模式、觸控數值輸入、Pencil、鍵盤、VoiceOver、Dynamic Type、Reduce Motion。
- 旋轉與 resize 前後維持 domain、submode、scroll、zoom、pan、undo 與未提交工具狀態。

### 13.4 隱私與發行 gate

- UI、錯誤、診斷與測試報告不得包含私人絕對路徑、Team ID、UDID、bookmark 或 credential。
- Xcode project 不提交個人 signing 設定。
- 真機或人工驗收未執行時必須標記 `NOT RUN`，不能用 simulator 或 source contract 代替。

## 14. 實作階段

### Phase 1：清理與共用基礎

- 建立 catalog、search index 與 presentation state。
- 補 ID、搜尋、收藏與狀態測試。
- 清除 iPad rail／host 重複實作，維持畫面功能不變。

### Phase 2：Mac 新面板

- 導入五域工具軌、固定 header／footer、Quick Controls 與 section layout。
- 接上搜尋、收藏、smart follow、pin 與新的寬度規則。
- 完成 Mac keyboard、tooltip、VoiceOver 與人工 QA。

### Phase 3：iPad 自適應面板

- Expanded／Wide 掛載共用 catalog 與新版 host。
- Compact／Standard 導入單一 bottom sheet 與 detent preservation。
- 完成左手模式、Pencil／touch、rotation／Stage Manager 與真機 QA。

### Phase 4：一致性與發行驗證

- Mac／iPad 對同一 adjustment field 的搜尋、收藏、reset、undo 與 preset 行為做 parity 驗證。
- 執行完整測試、build、strict concurrency、隱私掃描與更新操作文件。
- 只有所有必要 gate 具備證據後，才將本規格標記完成。

## 15. 完成定義

下列條件全部成立才算完成：

1. Mac 與 iPad 都由同一 catalog 定義五個 domain 與 section。
2. `PadEditorView.swift` 不再包含重複 rail／host。
3. 搜尋、收藏、smart follow、pin 與 Reset Section 在兩平台可操作。
4. 視窗變窄時畫布優先，iPad 能在 rail 與 bottom sheet 間無損切換。
5. 所有調整仍由 EditorSession 與既有核心處理，沒有第二份調整或 undo 狀態。
6. 自動化、Mac 人工 QA、iPad 真機 QA、隱私與文件 gate 均有最新證據。
