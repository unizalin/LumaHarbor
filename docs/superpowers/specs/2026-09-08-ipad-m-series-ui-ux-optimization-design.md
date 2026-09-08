# LumaHarbor M 系列 iPad Adaptive Pro Workspace UI/UX 規格

- 狀態：設計方向已核准，待拆分 implementation plan
- 日期：2026-09-08
- 目標平台：iPadOS，M1 或更新 Apple silicon iPad
- 涵蓋裝置：11 吋與 13 吋 iPad Pro／iPad Air、內建螢幕與外接顯示器
- 基準分支：`codex/open-source-release-prep`
- 基準 commit：`a3fdb35f0937a469c49e596b18915739533471b7e`
- 關聯規格：`docs/superpowers/specs/2026-09-08-editor-workflow-ux-optimization.md`

## 1. 文件定位

本規格定義 LumaHarbor iPad 版的下一階段 UI/UX：以觸控優先、桌面級效率為目標，讓 M 系列 iPad 在全螢幕、直向、Split View、Stage Manager 與外接顯示器上都能形成穩定的專業 RAW 工作區。

本案採用 **Adaptive Pro Workspace**，不把 Mac 介面逐像素搬到 iPad，也不把 iPad 當成放大的 iPhone。既有 RAW 解碼、非破壞 sidecar、外接來源、圖庫索引與輸出核心維持資料權威；本規格主要調整資訊架構、工作區呈現與輸入方式。

## 2. 市場參考與取捨

### 2.1 可借鏡的成熟模式

| 產品／原則 | 值得採用 | LumaHarbor 的取捨 |
| --- | --- | --- |
| Adobe Lightroom Mobile | 長按顯示 Before、雙點滑桿歸零、快速評分／旗標、可切換左右手面板 | 採用可發現且可還原的手勢；關鍵操作仍保留可見按鈕，不做手勢限定功能 |
| Capture One Mobile | 外接儲存／Session 思維、快速挑片、評分標籤、批次套用調整、現場輸出 | 強化 LumaHarbor 已有的外接來源與本機工作流；本階段不加入相機 tethering 或雲端 Session |
| Darkroom | 選取後才出現批次操作列、鍵盤挑片快捷鍵、快速隱藏工具與底部照片帶 | 採用情境式批次列、照片帶與鍵盤操作；避免讓永久工具列過度擁擠 |
| Affinity Photo for iPad | 依任務切換工作區、可收合 Studio、觸控與硬體鍵盤皆能操作 | 保留「圖庫／編輯／專注」三種清楚情境，不引入過多 Persona 或浮動工具群 |
| Apple iPadOS HIG | 視窗可自由縮放、優先保留主內容、變窄時先收第三欄、Pencil／pointer 不取代觸控 | 以實際可用寬度而非裝置名稱決定版面；所有 hover／快捷鍵都必須有觸控替代路徑 |

參考資料：

- [Apple Multitasking](https://developer.apple.com/design/human-interface-guidelines/multitasking)
- [Apple Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [Apple Pencil and Scribble](https://developer.apple.com/design/human-interface-guidelines/apple-pencil-and-scribble)
- [Apple Pointing Devices](https://developer.apple.com/design/human-interface-guidelines/pointing-devices)
- [Lightroom Mobile Gestures](https://helpx.adobe.com/sg/lightroom/mobile/get-started/gesture-controls-in-lightroom-for-mobile.html)
- [Capture One Mobile](https://www.captureone.com/en/products/capture-one-mobile)
- [Darkroom Batch Actions](https://darkroom.co/help/manage/batch-actions)
- [Affinity Photo 2 iPad Help](https://affinity.help/photo2ipad/English.lproj/)

### 2.2 明確不照搬的做法

- 不以大量小圖示填滿左右兩側，避免降低觸控命中率與學習性。
- 不把專業功能藏成只有手勢才能觸發的捷徑。
- 不要求登入、訂閱或雲端同步才能使用圖庫與編輯流程。
- 不為了視覺接近 Mac 而固定三欄；狹窄視窗必須自然退化。
- 不在這個 UI 專案中加入 AI 遮色片、生成式修復或新的 RAW 演算法。

## 3. 現況與主要問題

### 3.1 已有能力

- `PadRootView` 已能在圖庫、準備中、重新連接與編輯器間切換，並支援直接開啟 RAW。
- `PadLibraryView` 已區分 compact／regular size class，regular 模式使用固定 280 pt 來源側欄。
- `PadLibraryGrid` 已有檔名搜尋、四種排序、三段縮圖密度、分頁與預先載入。
- `PadEditorView` 已有 Work／Focus 模式、浮動面板、1x-5x 捏合縮放、完整解析度輸出、Photos／Files／Share 目的地。
- `PadEditorLayoutPolicy` 已用 900 pt 分界切換 trailing dock 與 bottom drawer，且具備 policy tests。
- 圖庫核心已具備 rating、flag、keyword 與進階篩選所需的共用 model／query；iPad 不需建立第二套資料語意。

### 3.2 需要改善的問題

1. 目前以 size class 與單一 900 pt 斷點判斷版面，無法完整描述 Stage Manager、外接螢幕與可自由縮放視窗。
2. regular 圖庫固定 280 pt 側欄，不能由使用者收合，也未依可用內容寬度配置詳細資料欄。
3. iPad 圖庫尚未完整承接 Mac 已有的評分、旗標、關鍵字、進階篩選與顯性批次工作流。
4. 圖庫與編輯器之間缺少連續挑片動線；進入編輯器後不容易快速切換相鄰照片或保留選取脈絡。
5. Work／Focus 已存在，但常用工具、檢查器與畫布的層級仍可更清楚，且窄視窗 bottom drawer 會長期占用畫布。
6. Apple Pencil、鍵盤與 pointer 尚未形成一份一致、可驗收的輸入契約。
7. 外接來源的斷線／重連功能存在，但缺少適合現場工作的一致狀態列與不中斷操作回饋。

## 4. 產品目標與非目標

### 4.1 目標

1. 使用者能從外接 SSD／記憶卡加入來源，完成瀏覽、挑片、評分、編輯與輸出，不依賴 Mac。
2. 11 吋與 13 吋 M 系列 iPad 在橫向全螢幕能呈現專業多區工作台；直向與多工窄視窗仍能完成同一流程。
3. 觸控為完整基線；Apple Pencil、鍵盤、觸控板與滑鼠提升精度及效率，但不形成必要條件。
4. 圖庫到編輯器保持目前 query、排序、選取與照片位置，往返時不讓使用者重新找照片。
5. 長時間掃描、產生縮圖與匯出都有進度、取消或可恢復狀態，不阻塞主要導覽。
6. UI 最佳化不改變 RAW 原檔、sidecar schema、render mapping 或批次同步語意。

### 4.2 非目標

- 相機有線／無線 tethered capture。
- 多使用者即時協作、雲端圖庫與跨裝置同步。
- AI 遮色片、生成式移除、臉部辨識或內容分類。
- Photoshop／Affinity 等像素圖層式編輯。
- 在第一階段支援多個同 App 視窗同時編輯不同圖庫。
- 重設 Mac 版 UI；共用核心接線除外。

## 5. Adaptive Pro Workspace

### 5.1 以視窗寬度決定版面

不得以「11 吋／13 吋」或 orientation 作為唯一判斷。Layout policy 使用扣除 safe area 後的實際可用寬度：

| Profile | 可用寬度 | 圖庫 | 編輯器 |
| --- | ---: | --- | --- |
| Compact | `< 700 pt` | 單一 grid；來源與篩選用 sheet | 全畫布；工具與 inspector 使用可收合 bottom sheet |
| Standard | `700-1099 pt` | grid 為主；來源側欄用 overlay／popover | 畫布為主；inspector 使用半高／全高 bottom sheet |
| Expanded | `>= 1100 pt` | 260-300 pt 可收合來源欄 + grid；足夠時可開 details | 畫布 + 320-380 pt trailing inspector；照片帶可見 |
| Wide | `>= 1360 pt` | 來源欄 + grid + 280-340 pt details | 可同時顯示照片帶、畫布與 inspector；不得單純放大控制項 |

規則：

- Profile 切換必須由純 policy 決定並可單元測試。
- 斷點前後保留目前照片、query、選取、捲動 anchor、zoom、pan、inspector tab 與未提交調整。
- 視窗變窄時依序收合 details、來源欄、inspector；畫布／grid 永遠是最後保留的主內容。
- 版面變更不得重建 `EditorSession`、新增 undo step 或觸發 sidecar autosave。
- Layout transition 不使用大幅彈跳動畫；只允許短距離、尊重 Reduce Motion 的系統轉場。

### 5.2 導覽層級

頂層資訊架構只有三個狀態：

1. **圖庫**：來源、搜尋、篩選、挑片與批次操作。
2. **編輯**：照片畫布、調整、裁切、局部工具與輸出。
3. **專注**：隱藏非必要 chrome，以檢查照片與精細操作為主。

圖庫與編輯使用同一個 workspace scene，不用層層 modal 包住主流程。設定、來源授權、關鍵字編輯與輸出選項才使用 sheet／popover。

## 6. 圖庫 UX

### 6.1 頂部工具列

工具列固定提供：

- 顯示／隱藏來源欄。
- 目前來源名稱與線上／離線狀態。
- 系統搜尋欄。
- 篩選按鈕；啟用時顯示 accent 狀態與條件數。
- 排序選單。
- 縮圖密度選單。
- `Select`／`Done` 選取模式。
- 加入來源與設定移入 overflow menu；Expanded profile 可直接顯示加入來源圖示。

不得同時顯示一排帶文字的圓角按鈕。熟悉命令使用 SF Symbols，hover 或長按顯示 tooltip；重要且不熟悉的行為用 icon + 短標籤。

### 6.2 來源側欄

- 分組顯示 App Copies、Files／iCloud Drive、外接儲存與離線來源。
- 每個來源顯示名稱、照片數、掃描狀態與離線 badge；不顯示私人絕對路徑。
- 點選來源立即切換 query；長按／右鍵提供重新掃描、重新連接與移除索引。
- 「移除來源」不得刪除 RAW；確認文案明確說明只移除 LumaHarbor 索引與存取權。
- 掃描期間允許瀏覽既有結果；狀態列顯示已處理數量並提供取消。
- Compact／Standard 使用可關閉的 overlay 或 sheet；選完來源後自動回到 grid。

### 6.3 Grid 與縮圖

- 使用現有三段密度，確保最小縮圖資訊仍可讀；cell 尺寸不得因 rating、旗標或進度 badge 出現而位移。
- cell 顯示檔名、rating、pick／reject、已調整狀態與來源離線狀態；其他 metadata 留在 details。
- 單點在一般模式開啟照片；選取模式切換選取。
- 長按開啟 context menu：評分、旗標、關鍵字、複製／貼上調整、匯出、顯示資訊。
- pointer 支援標準 hover、Command toggle 與 Shift range；觸控提供 Select 模式，不要求外接鍵盤。
- 搜尋／來源改變時依既有契約清除跨範圍選取；只改排序或密度時保留 PhotoID 選取。

### 6.4 篩選與詳細資料

- 快速篩選：rating、pick／reject、has edits、格式。
- 進階篩選：相機、鏡頭、日期、關鍵字；條件使用既有 `LibraryQuery` AND 語意。
- Compact／Standard 以 detent sheet 呈現；Expanded／Wide 可用 trailing details／filter column。
- details 顯示直方圖摘要、EXIF、關鍵字、來源與 sidecar 狀態；不得搶占 grid 初始空間。
- 清除全部篩選需單一步驟完成，並讓空結果畫面可直接執行。

### 6.5 多選與批次操作

選取至少一張照片後，畫面底部顯示固定 batch bar，並為 grid 預留 inset：

- 顯示 `已選取 N 張`。
- Pick／Reject、rating、加入關鍵字。
- 複製／貼上調整。
- 批次匯出。
- More menu：全選目前結果、清除、建立虛擬副本等低頻操作。

批次動作必須在執行前顯示實際目標數。Reject 預設不納入批次匯出，但使用者可在匯出確認畫面覆寫。

## 7. 編輯器 UX

### 7.1 編輯器結構

編輯器由四個可獨立顯示的區域組成：

1. **Top toolbar**：返回圖庫、undo、redo、before／after、Work／Focus、輸出。
2. **Canvas**：照片、zoom／pan 與 overlay 的唯一主互動區。
3. **Inspector**：調整、Preset、資訊三個分頁。
4. **Filmstrip**：目前 query／selection 的相鄰照片；可收合。

Expanded profile 顯示 canvas + trailing inspector；Standard／Compact 使用 bottom sheet。Filmstrip 在 Expanded 預設顯示，在 Standard 預設收合，在 Compact 由工具列按鈕呼叫。

### 7.2 Inspector

- 分頁使用 segmented control：`Adjust`、`Preset`、`Info`。
- Adjust 第一屏固定顯示 histogram、Basic 標題、Exposure 與 Contrast；不必先滑過 metadata。
- 調整群組依 Mac 共用資訊架構排列，Basic 預設展開，其餘群組記住目前 session 的展開狀態。
- slider 觸控軌高度至少 44 pt，視覺軌可較細；數值可點擊後用鍵盤輸入。
- 雙點 slider thumb 回到該參數預設值；Reset group／Reset all 仍有可見命令與確認層級。
- 開始拖曳時產生連續 preview，放開時只建立一筆 undo；旋轉或 resize 不得拆成額外 undo。
- 允許「左手模式」，將 trailing inspector／浮動工具移到左側；位置偏好只屬 UI 設定。

### 7.3 Canvas、縮放與比較

- 支援 Fit、100%、Custom 10%-800%；以 display scale 定義 100% pixel-to-pixel。
- 雙指捏合以手勢焦點縮放；一指拖曳只在已放大或特定 overlay 工具中作用，避免與返回手勢衝突。
- 雙點照片在 Fit 與 100% 間切換；工具列仍提供明確 Fit／100% 選單。
- 長按 canvas 顯示 Before，放開恢復 After；工具列按鈕提供鎖定比較，供無法長按者使用。
- 支援並排與分割線比較時，兩側共用 zoom／pan，不各自維護座標。
- 既有裁切、滴管、線性漸層與 spot heal 共用同一 image-to-canvas transform。
- 高倍率預覽採 latest-request-wins；載入高解析度時保留現有預覽，不閃白。

### 7.4 Work 與 Focus

- **Work**：顯示 inspector 與必要工具，作為預設模式。
- **Focus**：隱藏 inspector、filmstrip 與非必要 chrome；點一下或移動 pointer 暫時叫回控制列。
- Focus 中的浮動面板只保留目前工具的必要控制，不複製完整 inspector。
- 浮動面板可以拖移，但至少保留 44 pt 可見邊緣；左右手模式各自保存位置。
- 離開照片後，文件限定的 zoom、pan、floating offset 依既有 policy 重設；App 層級的左右手與 filmstrip 偏好保留。

### 7.5 照片帶與連續挑片

- filmstrip 使用目前圖庫 query 與排序，不自行建立第二份照片陣列。
- 顯示目前照片、rating、flag、adjusted badge；點擊切換照片。
- 左右 swipe 或鍵盤方向鍵前後移動；有未完成 gesture 時先結束／取消該 gesture 再換片。
- 從多選進入編輯器時，filmstrip scope 使用 selected PhotoIDs，並清楚顯示「調整將同步到其他 N 張」。
- 返回圖庫後回到原照片與原 grid scroll anchor。

### 7.6 輸出

- Export 使用單一入口，再選 Photos、Files、Share 或外接來源目的地。
- 預設沿用最後一次非敏感輸出設定；不得永久保存 security-scoped 絕對路徑文字。
- 匯出過程顯示檔名、完成數、總數與取消；切到其他 App 後回來能恢復狀態。
- 空間不足、來源離線、Photos 權限拒絕與分享取消要分開處理；取消不是失敗。
- 完成後提供「顯示於 Files」或再次分享等下一步，不使用阻塞式成功 alert。

## 8. 輸入方式契約

### 8.1 觸控

- 所有命令與狀態都可只用觸控完成。
- 互動目標至少 44x44 pt；相鄰破壞性與主要動作保留足夠間距。
- swipe、長按、雙點皆有可見替代控制；第一次使用可用一次性、可關閉提示，不在畫面常駐教學文字。
- 不能重新定義 iPadOS 系統邊緣、多工或返回手勢。

### 8.2 Apple Pencil

- Pencil 可操作全部一般控制，也可精確操作裁切、滴管、漸層與修復 overlay。
- hover 只做預覽或命中提示，沒有 hover 的 Pencil 仍能完成相同行為。
- Pencil Pro squeeze 可選擇叫出目前工具的 context palette；預設關閉且不得執行破壞性動作。
- double tap 預設在目前工具與 pan／view tool 間切換，使用者可關閉。
- 不使用 barrel roll 觸發無關 UI 命令。
- 左右手模式避免手掌遮住 inspector、context palette 與完成／取消控制。

### 8.3 鍵盤與 pointer

第一階段必要快捷鍵：

| 動作 | 快捷鍵 |
| --- | --- |
| Undo／Redo | `Command-Z`／`Shift-Command-Z` |
| Fit／100% | `Command-0`／`Command-1` |
| 放大／縮小 | `Command-+`／`Command--` |
| 搜尋 | `Command-F` |
| 全選目前結果 | `Command-A` |
| 複製／貼上調整 | `Command-C`／`Command-V`（焦點不在文字欄時） |
| 前／後一張 | Left／Right Arrow |
| Pick／Reject | `P`／`X` |
| 1-5 星 | `1`-`5`，`0` 清除 |
| 顯示 Before | 按住 `\` |
| 切換 Focus | `Shift-F` |
| 匯出 | `Command-E` |

- 所有快捷鍵加入 iPadOS command discoverability，長按 Command 可看到。
- 文字輸入焦點優先於照片快捷鍵，避免搜尋或關鍵字欄誤觸動作。
- pointer 支援標準 context menu、hover highlight、Shift range 與 Command toggle。
- 不用 pointer hover 才顯示唯一可用的必要命令。

## 9. 視覺與互動規範

- 使用安靜、中性的攝影工作區背景，讓照片色彩保持主角；accent 僅用於選取、啟用篩選與進度。
- 不使用裝飾漸層、orb、過大 hero text 或巢狀 card。
- Panel 邊界以系統 material、分隔線與階層間距表達，不把每個 section 做成浮動卡片。
- 卡片圓角不超過 8 pt；縮圖圓角 4-6 pt，避免裁掉可檢查的影像內容。
- Compact 工具列避免顯示超過五個同級命令，多餘項目進入 overflow menu。
- 固定工具列、filmstrip、batch bar 與 inspector 尺寸，badge／進度出現時不得造成 layout shift。
- 支援 Dynamic Type；較大字級時優先增加 panel 寬度或改為單欄，不縮小文字硬塞。
- 所有顏色狀態同時有圖示、形狀或文字，不只靠顏色辨認。

## 10. 狀態、錯誤與資料安全

- RAW 原檔永不修改、搬移或刪除；所有破壞性文案都需明確指出實際影響範圍。
- 來源離線時保留已索引的縮圖與 metadata；需要原檔的編輯／匯出才顯示 reconnect CTA。
- 重新授權成功後回到原照片、query 與工作區，不跳回圖庫首頁。
- 掃描、預覽與輸出錯誤顯示可行下一步，不能只顯示技術錯誤碼。
- UI 不顯示私人絕對路徑、bookmark data、Team ID、裝置識別碼或 provider 內部資訊。
- App 進入背景或視窗 resize 時保存可恢復的 UI context；不把暫時 workspace state 寫進照片 sidecar。

## 11. 效能與 M 系列硬體使用

以目前可用的 M1 iPad Pro 11 吋作為最低實機效能基準；更新晶片只能更快，不能成為正確性依賴。

- 圖庫查詢沿用 SQLite index、debounce 與 request generation；不得在主執行緒逐張讀 RAW。
- 10,000 筆 synthetic index 的第一頁 query，在 debounce 結束後 p95 不超過 300 ms。
- 快速捲動 grid 時，離屏 thumbnail task 必須取消；cell reuse 不得顯示前一張照片。
- slider／overlay gesture 的 UI state 回應應維持即時；昂貴渲染可降採樣 preview，手勢結束後再補完整品質。
- 同一照片只允許最新 preview request 更新畫面；舊請求完成不得倒蓋。
- 記憶體警告時先釋放可重建 preview／thumbnail cache，不丟失調整、選取或匯出工作。
- 長批次掃描與匯出需限制 concurrency，避免持續高溫造成 UI 無回應。
- 外接顯示器不得只是鏡像拉伸；應依 Wide profile 增加可用欄位與畫布空間。

## 12. 無障礙與在地化

- VoiceOver 讀出縮圖檔名、rating、flag、是否已調整、是否選取與來源離線狀態。
- slider 提供名稱、目前數值、單位與增減 action；Reset 的影響範圍可被讀出。
- Switch Control 與 Full Keyboard Access 能到達所有工具列、grid、inspector 與 sheet 動作。
- Reduce Motion 關閉 panel 大幅位移動畫；Increase Contrast 下仍能辨識選取與分隔。
- 支援現有八語；Compact、Split View 與最大 Dynamic Type 不可截斷關鍵命令。
- icon-only 按鈕必須有 localization key 對應的 accessibility label 與 tooltip。

## 13. 架構與檔案責任

### 13.1 重用既有核心

- 圖庫 query、rating、flag、keyword：`PhotoLibraryCore`。
- 編輯狀態、undo、批次同步：`EditorCore`。
- 調整控制與 layout 純 policy：`AdjustmentUI`。
- 完整解析度輸出：`RawProcessingCore.PhotoExporter`。
- iPad View 只處理呈現、輸入、scene lifecycle 與系統 picker／share sheet。

### 13.2 建議修改點

| 檔案／模組 | 責任 |
| --- | --- |
| `PadRootView.swift` | 以 adaptive workspace shell 統一圖庫／編輯 route 與 scene context |
| `PadLibraryView.swift` | 改由可用寬度 policy 配置來源欄、grid、details |
| `PadLibraryGrid.swift` | rating／flag／keyword、篩選、多選與 batch bar 接線 |
| `PadLibrarySidebar.swift` | 分組來源、狀態列、重連與安全移除 |
| `PadEditorView.swift` | top toolbar、canvas、inspector、filmstrip 與 Focus composition |
| `PadEditorLayoutPolicy.swift` | 由單一 900 pt 分界演進為 Compact／Standard／Expanded／Wide policy |
| 新增 `PadWorkspaceState` | scene-scoped route、sidebar、inspector tab、filmstrip、handedness；不得包含照片調整資料 |
| 新增純 policy／model tests | width profile、選取、shortcut focus、panel persistence、route restoration |

不建立 iPad 專用的 rating、flag、keyword 或 adjustment schema。若共用核心缺少 API，先在核心補一個平台中立介面，再由 Mac／iPad 共用。

## 14. 分階段交付

### Phase 1：Adaptive Shell 與圖庫專業化

- 建立四級 width profile 與 workspace state。
- 改造來源側欄、工具列、grid 狀態與 details。
- 接上 rating、flag、keyword、快速／進階篩選。
- 完成 Select mode、batch bar 與鍵盤挑片基礎。
- 保留既有來源生命週期與安全刪除契約。

完成定義：在四種 profile 中可從外接來源完成搜尋、篩選、挑片及開啟編輯器，沒有遮擋、狀態遺失或 RAW 寫入。

### Phase 2：編輯器工作區

- 建立 top toolbar、三分頁 inspector 與 adaptive dock／sheet。
- 完成 Fit／100%／10%-800% zoom、pan、Before／After。
- 加入 filmstrip 與圖庫往返 scroll restoration。
- 整理 Work／Focus 與浮動 context panel。
- 整合現有完整解析度輸出入口與進度。

完成定義：使用者能連續挑片、調整、比較與輸出，resize／旋轉不破壞 editor state 或 undo。

### Phase 3：多輸入效率與 Wide 工作台

- 完成 Apple Pencil、左手模式、keyboard command 與 pointer multi-selection。
- 完成 Wide profile details、外接顯示器與高密度照片帶。
- 補齊效能 signpost、記憶體壓力與長批次壓力測試。
- 完成八語、VoiceOver、Full Keyboard Access 與 Reduce Motion 人工驗收。

完成定義：只用觸控可完成全部流程；加入 Pencil 或鍵盤／pointer 後效率提升，但結果語意完全一致。

## 15. 測試與驗收矩陣

### 15.1 自動化

1. Layout policy：每個 breakpoint 的下界、上界、`-0.5 pt`／`+0.5 pt` 與 width／height 交換。
2. Workspace state：resize、旋轉、切照片、返回圖庫、來源離線與 App background／foreground。
3. Selection：tap、Select mode、Command toggle、Shift range、全選、query 改變與排序改變。
4. Query wiring：rating、flag、keyword、格式、相機、鏡頭與日期組合條件。
5. Editor：zoom clamp、100% 計算、pan clamp、transform、Before／After 與 latest-request-wins。
6. Undo：slider 一次 gesture 一筆 undo；workspace／panel／resize 零筆 undo。
7. Export：Photos、Files、Share、取消、來源離線、空間不足與多檔進度。
8. Accessibility contract：44x44、label、value、selected state、Dynamic Type 與 localization keys。

### 15.2 實機畫面矩陣

至少在 M1 11 吋與一台 13 吋 M 系列 iPad 或對應 simulator 尺寸驗證：

| 情境 | 必驗內容 |
| --- | --- |
| 11 吋橫向全螢幕 | Expanded workspace、來源欄、grid、editor inspector、filmstrip |
| 11 吋直向全螢幕 | Standard workspace、overlay sidebar、bottom inspector、無畫布遮擋 |
| 13 吋橫向全螢幕 | Wide workspace、details、最大畫布與多欄資訊密度 |
| Split View 1/2、1/3、2/3 | profile transition、搜尋鍵盤、sheet detent、batch bar inset |
| Stage Manager 最小至最大寬度 | 連續 resize、狀態不重設、無跳動或控制重疊 |
| 外接顯示器 | Wide profile、pointer、keyboard、視窗移動與顯示比例 |
| Apple Pencil | hover fallback、overlay 精度、左右手、double tap／squeeze 可關閉 |
| VoiceOver + 最大字級 | 導覽順序、slider action、縮圖狀態、無截斷 |

### 15.3 端到端驗收旅程

1. 接上外接 SSD，加入包含真實 RAW 的資料夾。
2. 掃描期間繼續瀏覽，篩出未評分照片。
3. 以觸控選取多張，設定 Pick、rating 與 keyword。
4. 從 selection 進入 editor，以 filmstrip 逐張檢查。
5. 用 Pencil／觸控調整曝光、裁切與局部工具，執行 undo／redo。
6. 長按比較 Before，切到 Focus 檢查 100% 細節。
7. 將調整同步到 selection，批次匯出至外接儲存。
8. 匯出中切到另一個 App 再返回，確認進度與 selection 保留。
9. 拔除來源，確認離線狀態與 reconnect CTA；重新連接後回到原照片。
10. 比對 RAW 雜湊，確認原檔未變；重新啟動 App，確認 rating、flag、keyword、sidecar 與可持久 UI 偏好正確。

## 16. 完成條件

本規格只有在以下條件全部具備時才能標記完成：

- Phase 1-3 各自有 implementation plan、程式碼審查與測試證據。
- generic iOS build、focused tests、完整 Swift tests 與 `git diff --check` 通過。
- M1 11 吋實機完成端到端旅程；13 吋尺寸與所有多工寬度至少完成 simulator visual QA。
- 外接 APFS／exFAT 來源的加入、拔除、重連、編輯與輸出均有真檔案證據。
- 觸控、Pencil、keyboard／pointer、VoiceOver 與最大 Dynamic Type 的必要清單完成。
- 沒有私人路徑、簽章識別、裝置識別碼或安全範圍 bookmark 洩漏。
- RAW 原檔雜湊不變，既有 sidecar 與 renderer compatibility tests 通過。
- 所有未執行項目明確標成 `NOT RUN`／`BLOCKED`，不能以自動測試替代真人 UI 驗收。

## 17. 建議優先順序

先做 **Phase 1 的 adaptive shell + iPad curation 接線**，因為它直接重用已完成的共用圖庫能力，也會建立後續 editor 版面需要的 width policy 與 workspace state。第二步再改 editor，避免圖庫與編輯器同時大幅重構。Apple Pencil Pro 特有手勢與 Wide 外接顯示器工作台留在 Phase 3，不阻擋基本觸控流程交付。
