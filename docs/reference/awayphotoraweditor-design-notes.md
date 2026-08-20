# 設計參考筆記：AwayPhotoRawEditor（僅供閱讀，非規格）

- 來源：https://github.com/awaysu/AwayPhotoRawEditor （C# / .NET 8 / WinForms，作者 Awaysu，BSD 3-Clause）
- 用途：LumaHarbor MVP 已在 [`2026-08-13-mac-first-mvp-design.md`](../superpowers/specs/2026-08-13-mac-first-mvp-design.md) §15 註明此專案為「早期產品探索參考」。本檔案是把該專案 `CLAUDE.md`（其開發過程的架構/踩坑筆記）裡，**跟 LumaHarbor §14 後續階段路線圖有直接對應**的設計決策整理出來，方便日後寫對應 spec 時當起點。
- **不是規格、不是待辦事項**，這裡沒有任何一條經過使用者核准。真的要做時仍要走 spec → 核准 → 驗收 的既有流程，且一律用 Swift/SwiftUI/Core Image 從零實作，不搬 WinForms 程式碼。
- AwayPhotoRawEditor 用 LibRaw 解碼；LumaHarbor 用 `CIRAWFilter`。凡是 LibRaw P/Invoke、DPI 縮放、WinForms 自繪控制項相關的坑，對 LumaHarbor 都不適用，以下只挑架構/資料模型/UX 邏輯層級、換了解碼器和 UI framework 依然成立的部分。

## 對應 LumaHarbor §14.1（裁切、旋轉、曲線、HSL）

- **裁切角度用滑桿而非數字輸入，且滑桿方向刻意與底層 `CropAngle` 相反**——2026-07 使用者實測要求「往右轉應該要看到畫面往右轉」，UI 值＝−CropAngle，只在綁定處取負，儲存語意不變。這是「內部模型方向」跟「使用者直覺方向」不一定一致的具體案例，LumaHarbor 設計旋轉/拉直 UI 時值得先用真人測一次直覺方向，而非假設數學上直覺的正負號就是 UX 上直覺的方向。
- 裁切工具開啟時，整個預覽會先做「以裁切中心旋轉＋取樣」（`StraightenPreview`），白框內容即最終裁切結果——「所見即所得」的裁切/拉直預覽，而不是裁切完才看得到旋轉效果。

## 對應 LumaHarbor §14.2（批次調整、風格檔、評分與篩選）

這是整份 AwayPhotoRawEditor 筆記裡對 LumaHarbor 最有參考價值的一塊，因為批次同步的正確性坑很細，值得先想清楚再動手：

- **多選批次同步的目標清單，要在「編輯手勢開始」時就擷取，不能在「提交/存檔」時才抓。** 原因：使用者點下一顆縮圖，UI 會先把選取收斂成單張、才觸發載入下一張的流程——如果同步目標在提交當下才讀 `SelectedItems`，讀到的已經不是原本使用者想套用的那群照片了。SwiftUI 下的等價風險是：`Set<Selection>` binding 在你完成一次滑桿手勢之前就可能因為別的互動被改掉，所以批次目標也要在手勢開始（相當於 `onEditingChanged(true)` 或拖曳開始）當下拍照存證，而不是手勢結束時才讀取當下選取狀態。
- **只同步「這次手勢動過的欄位」（delta），不是整份調整全複製。** 好處：不會把你只想調曝光的動作，意外把其他人裁切框、白平衡也覆蓋掉。實作上是「手勢開始時存一份 baseline，手勢結束比對 baseline 算出變動欄位集合，只把這個集合套到其他目標」。局部性調整（裁切、局部修復點位）預設**不**跟著批次同步，只有整體色調類參數才適合批次同步。
- **批次寫入延遲到提交時機一次做完，不要每個拖曳影格都寫檔。** 拖曳中只更新記憶體狀態＋UI 上的「已編輯」標記，真正寫入 sidecar 延到「切照片／匯出／關資料夾」這類提交點才 flush。這對 LumaHarbor 現有的 sidecar 原子寫入模型（§8.2）是相容的，只是要多一層「批次目標 + 待 flush 的變動集合」的暫存狀態。
- **批次 undo 是獨立於單張 undo 的複合結構**（存「目前這張的舊值」+「其他每張的舊值」一起），且**切換照片會清空 undo 堆疊**，批次還原只在「還沒切圖」的當下有效——不是永久可還原的歷史。LumaHarbor MVP 已有 Undo/Redo（§6.2），若之後做批次編輯，這個「批次 undo 只在同一次照片停留期間有效」的邊界值得直接沿用，比做一個真正跨照片、跨時間的批次歷史系統簡單很多，也符合大多數使用者的心智模型。
- **風格檔（preset）覆寫模型**：風格檔檔案只存「跟內建預設不同的欄位」，使用者把值改回跟內建完全相同時**自動移除覆寫**，讓風格檔檔案维持乾淨、不會累積一堆「其實沒差異」的殘留設定。套用風格檔時「優先用使用者覆寫值，沒有才退回內建值」。這個模式如果 LumaHarbor 之後也採，可以直接對應到現有的 `Codable` sidecar 設計：風格檔本身也可以是一份「稀疏」的 `PhotoAdjustments`（只帶非預設欄位），而不是每個風格檔都存一份完整參數。
- **評分/篩選（隱藏）系統的編號規則**：全部照片（含隱藏）先編號，隱藏的照片繼續佔用編號、只是預覽列上跳號顯示——避免「使用者記得#7 那張」但因為前面有照片被隱藏而編號整批往前移，造成溝通時對不上號。匯出一律排除隱藏項目。

## 對應 LumaHarbor §14.3（局部遮罩、Apple Pencil、iPadOS UI）

- **線性漸層的資料模型**：`List<LinearGradient>`（可疊加多個）+ 執行期的「目前選取索引」，每個漸層自帶「位置、角度、範圍」幾何參數 + 一組獨立的「曝光/對比/亮部/暗部/飽和度」局部調整值——也就是每個局部調整區塊，是「幾何 + 一份 mini 調整參數」的組合，而不是全域調整加一個遮罩圖層堆疊。這跟 Lightroom/Capture One 的漸層濾鏡概念一致，未來 LumaHarbor 做局部遮罩時，「一個遮罩物件自帶自己的幾何定義 + 自己的一份局部調整子集」是比較好維護、也比較容易做 `Codable` sidecar 的模型，優於「全域一份調整 + 額外一張遮罩點陣圖」。
- **修復/仿製點的模式切換是「就地生效」，不是只影響新畫的點**：切換仿製/修補模式時，除了改變之後新建的點的模式，也要把「目前選取中的點」一併轉換模式並重新計算——只改一個狀態變數、UI 按了沒反應，是這類工具常見的坑。iPad + Pencil 的局部工具如果做「當前選取項目」的概念，記得工具模式切換要主動套用到選取項目，而非只影響下一個新物件。
- **點擊 vs 拖曳用位移門檻（4px）區分，而非用「有沒有 mouseMove 事件」判斷**：放開時如果全程移動量小於門檻，視為「點擊」（觸發縮放循環等點擊行為），超過門檻才視為「拖曳」（平移/繪製）。觸控/Pencil 情境下這個門檻判斷更重要，因為手指按下時的自然抖動比滑鼠明顯，沒有門檻會讓使用者的「單純點一下」意外被判成拖曳。

## 對應 LumaHarbor §12.3（視覺與人工驗收）

- **headless 診斷模式**（`--selftest`、`--exporttest`、`--shot`、`--dlgshot`、`--gallery`）是這個專案能被 Claude/Codex 這類 agent 有效驗證的關鍵：不需要真人操作 GUI，就能跑「端到端解碼→調整→匯出」的自我測試，並在離屏視窗截圖比對版面。LumaHarbor 的 MVP 驗收（`Scripts/run-mvp-acceptance.zsh`）已經有 headless 化、可 CI 執行的精神；§12.3 要求的「固定 fixtures + 固定參數產生基準輸出」若要做自動化視覺回歸，這個專案的 `--shot <folder> <png>` 模式（開資料夾、算圖、截圖存證）是具體可抄的介面設計方向，之後可以評估在 LumaHarbor 加一個等價的 headless render-to-PNG 診斷指令。

## 一般性、跨解碼器都成立的 RAW 處理教訓

- **相機廠牌的 RAW 中繼資料不可盡信，要交叉驗證，不能只信任單一訊號。** AwayPhotoRawEditor 踩過「某些機型的 LibRaw margin 回報全 0（看起來沒有需要裁切的遮罩邊），但實際可視範圍其實比 sensor 尺寸小」的坑，最後改成向 ExifTool 額外查詢 `FullImageSize`（且該欄位在 Sony maker notes 裡，不能用快速模式讀取，得走完整查詢）來源交叉比對，而非只信任解碼器回報的單一尺寸欄位，也刻意不用「掃描純黑邊」這種啟發式方法（因為去馬賽克的過渡帶不是純黑，會少裁到）。這跟這次在 LumaHarbor 用 debug print 實測確認 `CIRAWFilter.nativeSize` 與 `outputImage.extent` 對同一張 Sony ARW 給出不同數字（因為 orientation 套用時機不同）是同一類問題的不同表現：**RAW 解碼器的「尺寸」類 API 常常不是單一權威數字，方向、遮罩邊、裁切表都可能讓不同 API 給出不同答案，寫測試/寫程式碼時不能假設它們永遠一致，需要用真實素材實測後才能下結論。** 如果 LumaHarbor 未來真的加 LibRaw 後備解碼器（§14.5），這類「不同解碼器對同一張照片的尺寸/方向定義可能不一致」的風險會直接重現，屆時 `RawDecoding` protocol 的實作要對這點特別小心。
- **RAW 內嵌縮圖/預覽常常是「橫躺儲存、不帶方向標籤」**，需要額外讀取廠牌特定的翻轉旗標（AwayPhotoRawEditor 是讀 LibRaw struct 內部一個沒有官方 getter 的欄位）。`CIRAWFilter`/ImageIO 理論上會處理好這件事，但如果 LumaHarbor 之後要做「不透過 `CIRAWFilter` 直接讀嵌入縮圖」的效能優化路徑（例如縮圖列不想每次都跑完整 RAW 解碼），要記得驗證縮圖本身的方向是否正確，不能假設跟主圖走同一套方向邏輯。

## 明確不建議搬過來的部分

- WinForms 自繪控制項、DPI/`Ui.Scale` 手動縮放系統：SwiftUI + AppKit 在 Retina/多螢幕下原生處理縮放，這整類問題在 macOS 不存在，不需要對應設計。
- LibRaw P/Invoke、64MB 大堆疊執行緒、`libraw.dll` 版本資料夾偵測：`CIRAWFilter` 是系統框架呼叫，沒有對應的部署/版本管理問題。
- Authenticode 簽章、Inno Setup 安裝檔、`awaysu.cc` 下載頁流程：跟 macOS 的 notarization/公證、App Store 或直接散布完全是另一套機制，沒有可搬的部分。
- 八語 UI 字串框架（`Tr` record + `Pick` 消歧義）：LumaHarbor 目前規格沒有多語需求，屆時若要做，SwiftUI 有原生的 `String Catalog`/`.xcstrings` 本地化機制，不需要参考這個自製方案。
