# LumaHarbor iPad Studio Rails 與 Mac 功能對齊規格

- 狀態：版型方向已核准，等待使用者審閱本規格
- 日期：2026-09-09
- 目標平台：iPadOS 17+，M1 或更新 Apple silicon iPad
- 涵蓋裝置：11 吋與 13 吋 iPad Pro／iPad Air、Split View、Stage Manager、外接顯示器
- 核准方向：A. Studio Rails
- 基準分支：`codex/open-source-release-prep`
- 基準 commit：`11f4fc732893a1014b00b182763624d5c1b2cdfe`
- 取代範圍：本文件取代 `2026-09-08-ipad-m-series-ui-ux-optimization-design.md` 中尚未完成的 iPad editor shell、inspector、filmstrip 與 Mac parity 規格；已完成的 width policy、圖庫篩選與 Select mode 不重做

## 1. 決策摘要

LumaHarbor iPad 版採用 **Studio Rails**：以照片畫布為中心，使用固定工具軌切換功能域、情境 inspector 呈現細部控制、底部 filmstrip 進行連續挑片。狹窄視窗將同一套功能自然轉成底部工具軌與可調高度 inspector sheet，不建立功能較少的 compact 版本。

本規格的「與 Mac 一致」定義如下：

1. **資料一致**：Mac 與 iPad 使用相同 `PhotoID`、sidecar、preset、batch、virtual copy、query 與 export schema。
2. **結果一致**：相同來源、相同調整與相同匯出選項，兩平台使用同一渲染／輸出核心並符合既有容差。
3. **能力一致**：目前 Mac 可見的每項圖庫、編輯、Preset、批次、幾何、局部調整、比較、資訊與匯出能力，在 iPad 都有觸控可達入口。
4. **介面不照抄**：iPad 不逐像素複製 Mac，也不要求鍵盤或 pointer；工具位置可依觸控與視窗寬度重組。
5. **不虛報完成**：只完成 shell、按鈕或 source contract 不算功能完成；必須有可操作功能、核心測試、iPad build 與真機證據。

## 2. 問題與現況

### 2.1 2026-09-09 真機觀察

- 最新 iPad 圖庫已有 adaptive sidebar、搜尋、Select、rating／flag／edited 篩選、進階篩選、排序與縮圖密度。
- 最新 iPad editor 已能在寬視窗顯示 trailing inspector，具備 Work／Focus、zoom、undo／redo、儲存狀態與單張完整解析度輸出。
- editor inspector 的三種 presentation（trailing dock、bottom drawer、Focus floating panel）仍只掛載最初的 `BasicAdjustmentPanel`。
- Mac 已有的 Color/HSL、Curve、Detail、Effects、Geometry、Local Adjustments、Preset browser、metadata／histogram 與完整批次入口尚未接到 iPad。
- `PadWorkspaceState.inspectorTab`、`isFilmstripVisible` 與 `usesLeftHandedLayout` 已有資料型別，但多數仍沒有真實畫面效果。
- 圖庫層命令曾洩漏到 editor toolbar；這類 route ownership 問題必須由 shell contract 防止，不靠逐畫面修補。

### 2.2 根因

先前工作優先完成 adaptive policy 與圖庫入口，但沒有先建立 Mac 功能對 iPad surface 的完整矩陣，也沒有建立一個可承載所有 editor domain 的 inspector coordinator。因此 layout state 已存在，實際功能仍散落於 Mac app target，iPad 只能使用已公開的少數共用 panel。

### 2.3 本案目標

- 讓 M 系列 iPad 可以獨立完成「加入來源 → 挑片 → 評分／關鍵字 → 編輯 → 局部修圖 → 套用 preset／同步 → 比較 → 輸出」全流程。
- Mac 與 iPad 共用功能語意與核心服務，平台 View 只負責呈現與輸入。
- 橫向全螢幕具備桌面級資訊密度；直向與多工窄視窗仍保有完整功能。
- 使用者能在兩次操作內到達任何主要 editor domain，不需滑過一條包含所有控制的無限長面板。

## 3. 非目標

- 不加入目前 Mac 也沒有的 AI 遮色、生成式修復、雲端同步、tethered capture 或像素圖層。
- 不重寫 RAW decoder、render mapping、sidecar schema 或 export codec，除非為修正既有跨平台資料缺口所必需。
- 不逐像素複製 Mac 視窗配置、AppKit menu 或 hover-only 行為。
- 不要求多 App 視窗同時編輯不同圖庫。
- 不包含 Developer ID、notarization、TestFlight 或 App Store 發行工作。
- 不以 M2 以上專屬 API 取代 M1 基準能力。

## 4. Studio Rails 資訊架構

### 4.1 Editor 區域

Editor 由五個穩定區域組成：

1. **Top toolbar**：返回圖庫、檔名與儲存狀態、undo／redo、Before／After、Work／Focus、Export。
2. **Tool rail**：Adjust、Preset、Geometry、Local、Info 五個互斥 domain。
3. **Canvas**：照片、zoom／pan、crop／eyedropper／gradient／heal overlay 的唯一主互動區。
4. **Inspector**：目前 tool domain 的控制；同一時間只顯示一個 domain，不混入其他 domain 的長清單。
5. **Filmstrip**：目前 query 或 selection 的相鄰照片，顯示 rating、flag、edit 與 virtual-copy 狀態。

### 4.2 Tool rail

Tool rail 固定使用 SF Symbols、44x44 pt 以上命中區與清楚 selected state：

| Domain | 內容 | 預設圖示語意 |
| --- | --- | --- |
| Adjust | Light、Color、Detail 三個子模式 | sliders |
| Preset | 內建／自訂／收藏／搜尋／匯入匯出 | wand |
| Geometry | crop、比例、rotate、flip、straighten、perspective | crop/rotate |
| Local | linear gradient、spot heal 與物件清單 | mask/dotted circle |
| Info | histogram、EXIF、來源、sidecar 與診斷狀態 | info |

- Expanded／Wide 預設 rail 在畫布左側、inspector 在右側。
- 左手模式將 rail 與 inspector 成對鏡像，不只移動其中一個。
- Compact／Standard 將 rail 轉為底部五項工具列；Inspector 以 detent sheet 顯示。
- 長按或 pointer hover 顯示 localized 名稱；必要功能不能只靠長按或 hover。
- 切換 domain 只更新 UI state，不建立 undo、不 autosave、不重新 decode RAW。

### 4.3 Adjust 子模式

Adjust inspector 頂端使用 segmented control：

- **Light**：目前 preview histogram、Exposure、Contrast、Highlights、Shadows、Whites、Blacks、Curve。
- **Color**：Temperature、Tint、白平衡滴管、Vibrance、Saturation、八色 HSL。
- **Detail**：Sharpening、Noise Reduction、Vignette、Grain。

這個分組只重排 iPad 呈現，不改 stable adjustment field ID。群組內使用 disclosure section；常用群組預設展開，狀態在同一 scene 內保存。

### 4.4 Top toolbar

- Library 命令（Open RAW、Settings、加入來源）不得出現在 editor toolbar。
- Expanded／Wide：左側返回；中央顯示檔名與 save state；右側顯示 undo、redo、compare、Focus、Export。
- Compact／Standard：返回、undo、redo、compare、Export 保持可見；save state、Focus 與低頻命令放入一層 overflow。
- 編輯器使用 inline title，不顯示大型 `LumaHarbor` 導覽標題。
- Export 是單一入口；成功產生檔案後再顯示 Photos、Files、Share 與外接目的地。

### 4.5 Filmstrip

- Expanded／Wide 預設顯示 88-104 pt 高的底部 filmstrip；使用者可收合。
- Standard 預設收合，工具列可叫出；Compact 以半高照片帶 sheet 呈現。
- 資料直接來自目前 `LibraryQuery`／排序或進入 editor 前的 selected PhotoIDs，不維護第二份照片陣列。
- 顯示目前照片、rating、flag、adjusted、offline 與 virtual copy badge；badge 出現不得改變 cell 尺寸。
- 點擊、左右 swipe、鍵盤方向鍵都可切換照片；gesture 尚未 commit 時先完成或取消，再切片。
- 返回圖庫時回到同一 `PhotoID` 與 grid scroll anchor。

## 5. Responsive Layout Contract

Layout 一律使用 safe-area 後的可用寬度，不依裝置名稱或 orientation 猜測。

| Profile | 可用寬度 | Library | Editor |
| --- | ---: | --- | --- |
| Compact | `< 700 pt` | grid；來源／篩選使用 sheet | canvas；底部 tool rail；inspector detent sheet |
| Standard | `700-1099 pt` | grid；來源 overlay | canvas；底部 tool rail；半高／全高 inspector sheet |
| Expanded | `1100-1359 pt` | 可收合 source sidebar + grid | rail + canvas + 320-360 pt inspector；filmstrip 可見 |
| Wide | `>= 1360 pt` | source + grid + optional details | rail + canvas + 360-420 pt inspector + filmstrip |

共通規則：

- 變窄時依序收合 details、filmstrip、inspector、source sidebar；canvas／grid 最後才縮小。
- profile 切換保留照片、query、selection、scroll anchor、tool domain、adjust submode、zoom、pan、未提交 gesture 與 undo stack。
- resize／旋轉不得重建 `EditorSession`、寫 sidecar 或建立 undo。
- inspector、filmstrip、toolbar 的顯示隱藏使用短系統轉場並尊重 Reduce Motion。
- Dynamic Type 無法容納固定 rail 時轉成 bottom tool rail，不縮小字體或命中區硬塞。

## 6. Mac 功能對齊矩陣

以下每一列都必須在 iPad 有觸控入口，並使用相同核心語意：

| 功能群 | Mac 能力基準 | iPad Studio Rails 位置 | 共用權威 |
| --- | --- | --- | --- |
| 多來源圖庫 | App Copies、Files、外接來源、離線／重連／移除索引 | Library source sidebar／sheet | `PhotoLibraryCore` |
| 搜尋排序密度 | filename、四種排序、三段 density | Library toolbar | `LibraryQuery`／`PhotoSort` |
| 評分旗標關鍵字 | 0-5、Pick／Reject、keyword editor | cell context menu、batch bar、details | `PhotoIndexStore` |
| 進階篩選 | rating、flag、edited、format、camera、lens、date、keyword | filter menu／sheet／Wide details | `LibraryQuery` |
| 多選批次 | Select、range／all、批次 metadata／edit／export | selection mode + bottom batch bar | `LibraryBrowserSession` |
| 虛擬副本 | 建立、命名、相鄰顯示、獨立 edits | batch More／filmstrip／cell menu | virtual-copy core |
| Histogram／Metadata | current preview histogram、EXIF、source／save state | Info domain；Light 顯示精簡 histogram | shared snapshot/model |
| Basic／Light | exposure、contrast、highlights、shadows、whites、blacks | Adjust > Light | `EditorSession` |
| Color | temperature、tint、eyedropper、vibrance、saturation、HSL | Adjust > Color | `EditorSession`／render core |
| Curve | 目前 Mac 的 curve status／reset；若共用 editor 升級則兩平台同步 | Adjust > Light > Curve | `PhotoAdjustments` |
| Detail | sharpening、luminance／color noise reduction | Adjust > Detail | `PhotoAdjustments` |
| Effects | vignette、grain | Adjust > Detail > Effects | `PhotoAdjustments` |
| Geometry | crop、ratio、rotate、flip、straighten、perspective | Geometry domain + canvas overlay | geometry model／transform |
| Local adjustments | multiple linear gradients、spot heal、enable／duplicate／delete | Local domain + canvas overlay | local-adjustment model |
| Preset | built-in／user、favorite、search、create／edit、merge／replace、backup／restore、`.lhpreset`／XMP | Preset domain | `PresetCore` |
| Clipboard／同步 | copy、paste、field selection、sync to selected、partial summary | More menu／batch bar／inspector command | batch sync service |
| Undo／Redo | single gesture one undo、compound batch undo | top toolbar + keyboard | `EditorSession`／batch transaction |
| Compare | hold Before、lock、side-by-side、wipe，共用 zoom／pan | top toolbar + canvas gesture | compare／viewport state |
| Viewport | Fit、100%、10-800%、zoom／pan | canvas + zoom menu | viewport policy |
| Export | single／batch、format、quality、size、DPI、rename、watermark、EXIF、collision、report | Export sheet／batch export | `PhotoExporter`／export options |
| Theme／language | system、classic dark、warm paper；八語 | Settings | localization／preferences |
| Settings／diagnostics | quality、GPU/CPU status、precision、cache、backup、privacy-safe diagnostics | Library Settings | shared settings／diagnostics core |

### 6.1 Parity gate

- 矩陣中任何一列若只有按鈕但沒有成功／取消／失敗資料流，狀態為 `INCOMPLETE`。
- Mac-only AppKit 命令必須有 iPad touch 等價入口；iPad keyboard command 只能是加速器。
- 若功能核心目前只存在 `LumaHarborApp` target，先抽出平台中立 coordinator／model，不可在 iPad 複製商業邏輯。
- 若 Mac 本身仍是受限功能（例如目前 Curve 只有狀態與 Reset），iPad 先達到同等能力；擴充功能需另立 shared-core task，同時惠及兩平台。

## 7. 詳細互動契約

### 7.1 調整 slider 與數值

- 可視 slider 軌可較細，但整列觸控高度至少 44 pt。
- 數值可點擊後使用系統數字鍵盤精確輸入；範圍、步進與中性值取自 `AdjustmentCatalog` 或對應模型。
- 雙點 thumb 回到中性值；每個 section 另有可見 Reset Section，Reset All 必須二次確認。
- drag 開始呼叫 `beginAdjustmentGesture()`，連續 preview，放開只產生一筆 undo 與一次 commit。
- 旋轉、resize、切 inspector domain 不可中斷成多筆 undo。
- VoiceOver 提供名稱、目前值、單位、增加／減少與 reset action。

### 7.2 Canvas、比較與工具 overlay

- 支援 Fit、100%、Custom 10%-800%；100% 依 display scale 定義 pixel-to-pixel。
- 雙指捏合以焦點縮放；放大後一指拖曳平移；雙點在 Fit／100% 間切換。
- 長按 canvas 暫時顯示 Before；工具列可鎖定 Before、side-by-side 或 wipe。
- Crop、eyedropper、gradient、spot heal 共用一個 image-to-canvas transform，不自行計算座標。
- Local／Geometry domain 啟用時，canvas gesture 優先交給 active tool；Pan 有明確暫時切換入口。
- Pencil hover 只預覽命中；沒有 Pencil 或 hover 的裝置仍可完成全部操作。

### 7.3 Preset

- Preset list 支援搜尋、group、favorite、built-in／user badge 與目前相容性狀態。
- 單點選取顯示 preview；明確 Apply 才 commit，取消恢復先前調整且不寫 sidecar。
- 建立／編輯 preset 時可勾選欄位，Geometry／Local 預設不納入。
- Backup／Restore／`.lhpreset`／XMP 使用 Files picker；取消不是錯誤。
- 不把 Mac `PresetBrowserView` 直接條件編譯到 iPad；共用 coordinator，平台各自呈現。

### 7.4 多選、同步與虛擬副本

- 選取至少一張時 batch bar 提供 rating、flag、keyword、copy／paste、sync、virtual copy、export。
- 執行前顯示實際 target count；Reject 預設不匯出，可明確覆寫。
- Sync 預設只含 global adjustments；Geometry／Local 必須明確勾選。
- 一次同步產生 compound undo 與 affected／failed／skipped 摘要；partial failure 不留下無法辨識的半套用狀態。
- Virtual copy 不複製 RAW，擁有獨立 identity、名稱、調整、rating／flag；刪除 copy 不刪來源。

### 7.5 Export

- Export sheet 支援 JPEG、HEIC、PNG、TIFF；使用與 Mac 相同的 format availability。
- 支援 JPEG／HEIC quality、TIFF bit depth、色彩空間、長／短邊或寬高上限、DPI、rename tokens、文字 watermark、EXIF policy、collision policy。
- 單張與批次共用 request mapper；iPad 不另寫一套 encode。
- 目的地支援 Photos、Files、Share 與已授權外接來源。
- 顯示檔名、完成／總數、取消與 per-file report；進背景再回來保留可恢復狀態。
- Share／Files picker 取消記為 `cancelled`；空間不足、來源離線、權限拒絕與格式不支援分開顯示。

## 8. Library 完整工作區

### 8.1 Expanded／Wide

- 左側 260-300 pt source sidebar；中央 grid；Wide 可選 280-340 pt details。
- Toolbar：sidebar、目前來源、搜尋、filter、sort、density、Select；Add Source 與 Settings 依寬度顯示圖示或 overflow。
- Details 顯示 metadata、keywords、source 與 sidecar 狀態，不預設壓縮 grid。
- Grid cell 顯示 filename、rating、flag、adjusted、virtual copy 與 offline；所有 badge 使用固定 overlay slot。

### 8.2 Compact／Standard

- Source、filter、details 使用 sheet／popover；grid 始終是主內容。
- Select mode 底部 batch bar 為 grid 保留 safe-area inset，不遮住最後一列。
- 搜尋或來源改變依既有契約清除跨 scope selection；排序／density 改變保留 selected IDs。

### 8.3 Keyword durability prerequisite

目前 keyword 只在可重建 SQLite index 中保存，index rebuild 可能遺失。完整 parity 上線前必須建立共享、可備份的 keyword 權威來源，並讓 Mac／iPad 使用相同 migration／restore 行為；不得讓 iPad 擴大既有資料遺失風險。

## 9. 架構與資料流

### 9.1 Ownership

| 層級 | 責任 |
| --- | --- |
| `RawProcessingCore` | decode、render、full-resolution export、image transform input |
| `PhotoLibraryCore` | source、bookmark、index、query、rating／flag／keyword、virtual copy |
| `PresetCore` | preset schema、patch、codec、XMP、backup／restore |
| `EditorCore` | document、adjustments、save、undo、batch sync、compare intent |
| `AdjustmentUI` | 跨 Apple 平台可重用 panel、control、viewport／layout policy |
| `LumaHarborApp` | Mac-specific composition、menu、AppKit bridge |
| `LumaHarborPadApp` | Studio Rails composition、touch／Pencil、iPad picker、scene lifecycle |

### 9.2 必要抽取

- 將 Histogram／Metadata snapshot 的可重用 View 或 view data 移到 `AdjustmentUI`／`EditorCore`，避免 iPad 重算。
- GeometryAdjustmentPanel 與 LocalAdjustmentsPanel 延續 `AdjustmentUI` 公開 API，補 iPad hit target／overlay adapter，不建立 iPad model。
- 從 Mac `PresetBrowserView`／view model 抽出 platform-neutral `PresetBrowserCoordinator`；Mac 與 iPad View 共享它。
- 將 export option mapping、batch report 與 destination-independent state 抽到 shared coordinator；Photos／Files／Share bridge 留在 iPad target。
- 建立 `PadInspectorCoordinator`，只管理 domain、submode、expanded section、presentation 與 active tool；不得持有第二份 `PhotoAdjustments`。

### 9.3 Scene state

`PadWorkspaceState` 擴充但只保存 presentation：

- active domain、Adjust submode、inspector visible／detent、filmstrip visible；
- source sidebar／details visible、Work／Focus、left-handed layout；
- zoom mode／pan 與 floating panel offset 依文件限定保存。

以下狀態不得放進 `PadWorkspaceState`：調整值、rating、flag、keyword、preset patch、batch transaction、export bytes、security-scoped URL。

### 9.4 Route ownership

- Library toolbar 只由 library route 提供；Editor toolbar 只由 editor route 提供。
- 切 route 不得讓父層殘留另一個 route 的 navigation title、toolbar item、sheet 或 alert。
- 任何同時只允許一份的 operation（import、relink、export、preset preview）由明確 coordinator single-flight 管理。

## 10. 狀態、錯誤與資料安全

- RAW 原檔永不修改、搬移或刪除；移除來源只移除索引與授權。
- autosave failed 時保留 unsaved 狀態、undo 與可重試 action；不得顯示假 `Saved`。
- source offline 時保留 thumbnail／metadata；只有需要原檔的 edit／export 被阻擋並提供 reconnect。
- Batch partial failure 顯示 affected／failed／skipped，且可匯出 privacy-safe report。
- 錯誤文案不得顯示絕對路徑、bookmark data、Team ID、UDID、Apple Account 或 provider internal identifier。
- security-scoped access 只在 operation lifetime 持有；不得因 resize、切 tab 或進背景而重複 acquire 且未 release。
- Development `.ipa`、`.mobileprovision`、`.p12` 與 signing identity 不進 Git 或測試附件。
- 所有 destructive action 使用 role、影響數量與明確確認；取消永遠不是失敗。

## 11. 輸入、無障礙與在地化

### 11.1 觸控與 Pencil

- 觸控可完成所有功能；命中區至少 44x44 pt。
- swipe、長按、雙點與 Pencil gesture 都有可見替代按鈕。
- Pencil 可精確操作 crop、eyedropper、gradient、heal；hover／double tap／squeeze 為可關閉加速器。
- 左手模式調整 rail、inspector、floating palette 與完成／取消位置，避免手掌遮擋。

### 11.2 鍵盤與 pointer

- Undo／Redo：`Command-Z`／`Shift-Command-Z`
- Fit／100%：`Command-0`／`Command-1`
- 搜尋：`Command-F`
- Copy／Paste adjustments：`Command-C`／`Command-V`（文字欄無焦點時）
- 前後照片：Left／Right Arrow
- Rating：`0`-`5`；Pick／Reject／Unflag：`P`／`X`／`U`
- Before：按住 `\`；Focus：`Shift-F`；Export：`Command-E`
- 長按 Command 顯示 discoverability；文字輸入焦點永遠優先。

### 11.3 Accessibility／localization

- VoiceOver 可讀出 tool domain、selected state、slider value／unit、照片 rating／flag／edits／offline。
- Full Keyboard Access 與 Switch Control 可到達 rail、toolbar、canvas tool、filmstrip、inspector 與 sheet。
- 支援 Dynamic Type、Reduce Motion、Increase Contrast 與 Differentiate Without Color。
- 所有新增字串進既有八語 key gate；`InfoPlist.strings` 包含 Photos add-only 權限文案。
- 最大字級或長語系無法容納時改變 layout，不縮字或截斷主要命令。

## 12. 效能門檻

以 M1 iPad Pro 11 吋為最低實機基準：

- 10,000 筆 synthetic index：debounce 完成後第一頁 query p95 <= 300 ms。
- slider／overlay 輸入立即更新本地 UI；working preview 可降採樣，手勢結束後補品質。
- warm RAW working preview 以既有約 145 ms 證據為基準，不得回退超過 25%。
- 快速切換 30 張照片時只有最新 preview request 可落地，canvas 不閃成空白。
- 快速 grid scroll 取消離屏 thumbnail task，不顯示錯 cell 的舊 thumbnail。
- 記憶體警告先釋放可重建 cache，不丟失 adjustment、selection、sidecar 或 export transaction。
- 長批次限制 concurrency；UI 在掃描／匯出期間仍可捲動、取消與查看進度。
- 旋轉與 Stage Manager resize 不可有可見 control overlap、無限 layout loop 或狀態重置。

## 13. 分階段交付

每一階段必須先有逐檔 implementation plan，採 RED → GREEN → focused regression → generic iOS build → 真機 checkpoint。

### Phase 0：Baseline 與 route 修正

- 固定目前真機截圖揭露的 editor toolbar／large-title ownership regression。
- 建立 Mac-to-iPad parity inventory test fixture 與 build/version 可辨識方式。
- 保存目前 signing 設定為 local-only，不納入提交。

完成條件：圖庫與 editor toolbar 不互相洩漏；實機能辨識正在跑的 build。

### Phase 1：Shared surface extraction

- 抽出 Histogram／Metadata data、Preset coordinator、export option mapper。
- 確認 Color、Curve、Detail、Effects、Geometry、Local panels 可在 iOS 編譯。
- 建立 `PadInspectorCoordinator` 與 state tests。

完成條件：iPad target 能在不複製調整／preset／export 商業邏輯下取得所有 parity surface。

### Phase 2：Studio Rails shell

- 實作 tool rail、responsive inspector、top toolbar 與 filmstrip。
- 接上 left-handed layout、Work／Focus 與 route restoration。
- Compact／Standard／Expanded／Wide 使用同一 state identity。

完成條件：五個 domain、filmstrip 與四種 width profile 可操作，resize 不遺失狀態。

### Phase 3：Global adjustments parity

- 完成 Light、Color、Detail，含 Histogram、WB eyedropper、HSL、Curve、sharpening、noise、vignette、grain。
- 補數值輸入、reset section／all、gesture undo 與 save state。
- 完成 Before／After、side-by-side、wipe、zoom／pan。

完成條件：Mac 所有 global adjustment field 在 iPad 可編輯、undo、保存、重開與完整解析度輸出。

### Phase 4：Geometry 與 Local parity

- 完成 crop／ratio／rotate／flip／straighten／perspective。
- 完成 multiple gradients 與 spot heal 的 add／select／move／duplicate／enable／delete。
- 所有 overlay 共用 transform，支援 touch／Pencil／pointer。

完成條件：實機方向與命中經 screenshot fixture／真人確認；輸出結果含完整 geometry／local edits。

### Phase 5：Preset、Batch 與 Virtual Copy parity

- 完成 Preset browse／preview／apply／create／edit／favorite／backup／restore／native import-export／XMP。
- 完成完整 batch bar、clipboard、field selection、sync、compound undo／report。
- 完成 virtual copy UI 與 keyword durability prerequisite。

完成條件：圖庫多選到 editor 同步、virtual copy、返回 grid 的完整旅程有自動化與真機證據。

### Phase 6：Export、Settings、Themes 與 Languages

- 完成 Mac export option parity 與 Photos／Files／Share／external destination。
- 完成 render quality、GPU／CPU status、precision、cache、backup、diagnostics。
- 完成 system／classic dark／warm paper 與八語／InfoPlist localization。

完成條件：單張／批次輸出矩陣、取消／失敗、主題與八語 gate 全數通過。

### Phase 7：Performance、Accessibility 與 Release QA

- 完成 M1、11／13 吋、四個 width profile、rotation、Split View、Stage Manager、外接顯示器。
- 完成 touch、Pencil、keyboard／pointer、VoiceOver、Full Keyboard Access、Dynamic Type。
- 完成外接 APFS／exFAT 加入、拔除、重連、編輯、批次與輸出。

完成條件：第 15 節所有 gate 有可稽核證據，沒有以 simulator 或 source contract 取代真機手動項目。

## 14. 測試策略

### 14.1 自動化

- Layout：每個 breakpoint 邊界、旋轉、Stage Manager 連續 resize、left-handed mirror。
- Route：Library／Editor toolbar、title、sheet、alert 不互漏。
- Inspector：domain／submode／section persistence，切換不產生 undo／save／decode。
- Adjustment：每個 stable field ID、range、neutral、precision input、gesture single undo。
- Canvas：Fit／100%／10-800%、pan clamp、focal zoom、compare shared transform。
- Overlay：crop／eyedropper／gradient／heal 在 25／100／400／800% 的 normalized coordinate。
- Preset：preview cancel、apply mode、field patch、backup／restore、`.lhpreset`／XMP。
- Batch：target snapshot、partial failure、compound undo、Reject policy、virtual copy。
- Export：所有 format／option mapping、full-resolution、destination、cancel cleanup、report。
- Library：10k query、selection、filter composition、keyword migration／rebuild durability。
- Accessibility：labels、values、actions、44x44、focus order、localization keys。
- 全套：strict concurrency、`swift test`、generic iOS build、privacy／signing scan、`git diff --check`。

### 14.2 視覺與真機矩陣

| 情境 | 必驗內容 |
| --- | --- |
| M1 11 吋橫向全螢幕 | Expanded rail、canvas、inspector、filmstrip、所有 domain |
| M1 11 吋直向 | Standard bottom rail／sheet、canvas 不被永久遮住 |
| 13 吋尺寸 simulator／實機 | Wide inspector、filmstrip、details、最大字級 |
| Split View 1/3、1/2、2/3 | profile transition、sheet detent、keyboard、selection |
| Stage Manager 最小到最大 | 連續 resize、無 toolbar 重疊、狀態不重置 |
| 外接顯示器 | Wide、display scale、pointer、keyboard、視窗移動 |
| Pencil | crop、eyedropper、gradient、heal 精度與左手模式 |
| VoiceOver + 最大字級 | rail 順序、slider action、filmstrip、sheet、無截斷 |
| Classic dark／warm paper | 照片色彩不被背景干擾、contrast、clipping |
| 八語 | toolbar、segmented control、錯誤、batch／export report |

### 14.3 端到端旅程

1. 從外接 SSD 加入真實 RAW 資料夾，掃描中繼續瀏覽。
2. 搜尋並組合 rating／flag／keyword／camera filter，挑選照片。
3. 以觸控完成 rating、Pick、keyword、多選與建立 virtual copy。
4. 由 selection 進入 editor，以 filmstrip 連續挑片。
5. 完成 Light、Color、Detail、Geometry、gradient 與 heal，逐步 undo／redo。
6. Preview／套用 preset，copy 調整並只同步指定欄位到 selection。
7. 使用 Before、side-by-side、wipe、Focus 與 100／400% 檢查。
8. 批次匯出不同格式到外接來源，另做 Photos／Files／Share 單張輸出。
9. 匯出中切到其他 App 再回來；取消一筆並檢查沒有 `.tmp` 殘留。
10. 拔除／重連來源，返回原照片與 query；重啟 App，驗證 sidecar、metadata 與可持久偏好。
11. 比較 RAW SHA-256，必須完全不變；匯出像素／metadata 符合選項。

## 15. 完成條件

只有以下項目全部成立，才可標記 `iPad MAC FEATURE PARITY COMPLETE`：

- 第 6 節矩陣每一列都有 iPad touch path、shared-core test 與成功／取消／失敗證據。
- Phase 0-7 各自有 implementation plan、review、focused tests 與提交。
- 完整 `swift test` 零 failure；skipped 有原因且不冒充 PASS。
- generic iOS build、signed M1 device build／install／launch 全部 PASS。
- M1 11 吋完成端到端旅程；13 吋與所有多工尺寸完成 visual QA。
- Geometry／Local 的方向與命中有真機／screenshot fixture，不只數學測試。
- Photos、Files、Share、external 的單張／批次輸出與取消／失敗矩陣完成。
- RAW hash 不變，sidecar／preset／keyword／virtual copy 重啟與 rebuild 後仍持久。
- VoiceOver、Full Keyboard Access、Dynamic Type、Reduce Motion 與八語 gate 完成。
- 沒有私人路徑、Team ID、UDID、profile、credential 或 bookmark data 進入 Git／報告。
- 所有未實際執行項目標為 `NOT RUN`／`BLOCKED`；不以 source contract、build 或 simulator 代替真人驗收。

## 16. 風險與控制

| 風險 | 控制 |
| --- | --- |
| 把 Mac View 直接搬到 iPad，造成 AppKit／小命中區 | 只抽 coordinator／model／跨平台 panel，iPad composition 獨立 |
| Studio Rails 只完成外框 | Parity matrix 每列要求完整資料流與真機證據 |
| SwiftUI profile 切換重建 state | 單一 stable content identity + pure layout policy tests |
| 巨大 `PadEditorView` 難維護 | 拆 `PadStudioShell`、`PadToolRail`、`PadInspectorHost`、`PadFilmstrip`、domain views |
| Batch／Preset 複製商業邏輯 | 先抽 shared coordinator，再接 iPad View |
| Keyword rebuild 遺失 | Phase 5 前完成 shared durable authority／migration |
| Geometry／Local 手勢和 pan 衝突 | active-tool gesture router + shared transform + explicit Pan mode |
| M1 記憶體／熱量壓力 | bounded concurrency、可重建 cache 優先釋放、signpost／stress gate |
| 本機 signing 污染 Git | project signing 維持 unstaged；clean-HEAD build 與 privacy scan |

## 17. 建議元件邊界

- `PadStudioShell.swift`：依 profile 組合 rail、canvas、inspector、filmstrip。
- `PadToolRail.swift`：五個 domain 與左右手／compact presentation。
- `PadInspectorCoordinator.swift`：presentation state 與 active tool lifecycle。
- `PadAdjustmentInspector.swift`：Light／Color／Detail composition。
- `PadPresetInspector.swift`：Preset coordinator 的 iPad View。
- `PadGeometryInspector.swift`：共用 Geometry panel 與 canvas overlay 接線。
- `PadLocalInspector.swift`：local object list、tool options 與 overlay 接線。
- `PadInfoInspector.swift`：Histogram／metadata／source／save state。
- `PadFilmstrip.swift`：query／selection-backed photos 與 route restoration。
- `PadExportCoordinator.swift`：shared export mapping + iPad destination bridge。
- `PadCommandMenu.swift`：keyboard discoverability 與 focus-aware routing。

元件名稱可在 implementation plan 隨現有模組調整，但 ownership 不得重新集中回單一巨大 `PadEditorView`。

## 18. 後續步驟

本規格經使用者審閱核准後，下一步只能先建立逐檔 implementation plan。實作從 Phase 0／1 開始，不直接跳到畫面組裝；每一階段完成後先在已連接的 M1 iPad checkpoint，再進入下一階段。
