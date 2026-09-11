# iPad／Mac 視覺一致性與曲線編輯器體驗規格

**日期：** 2026-09-11  
**狀態：** READY FOR CLAUDE IMPLEMENTATION  
**範圍：** `AdjustmentUI` 共用元件、Mac Inspector、iPad Inspector／底部工作表  
**目標平台：** macOS 14+、iPadOS 17+；Apple silicon Mac 與 M 系列 iPad

## 1. 背景與問題

真機 iPad 驗收顯示目前的調整面板仍有三類可見問題：

1. 數值輸入欄位是過寬的純黑矩形，和深色面板融在一起，焦點、可編輯狀態與重設動作不夠清楚。
2. 色調曲線預設顯示五個錨點，使用者容易誤以為曲線只能有五個控制點；曲線編輯也缺少專業工具常見的新增、刪除與精準選取回饋。
3. 直方圖在高反差 RAW 或窄面板中會出現視覺破圖：單一裁切尖峰壓扁其他細節、端點貼邊，RGB 疊圖辨識度不足。

本規格要求一次完成視覺層級、互動回饋與可驗證的曲線／直方圖行為。不得以改變 RAW 原檔、sidecar schema 或既有調整語意來換取視覺效果。

## 2. 目標

- Mac 與 iPad 使用同一套欄位、曲線與直方圖視覺語言；平台差異只體現在容器與輸入方式。
- 使用者可一眼辨認標籤、目前值、焦點、重設狀態及未儲存狀態。
- 曲線可建立任意數量的中間控制點，五點只保留為中性曲線的預設錨點。
- 直方圖在 RGB／Luminance、高裁切比例、空資料與窄寬度下都不重疊、不出界、不呈現空白破圖。
- 觸控與 Apple Pencil 命中區符合 44×44 pt，滑鼠／鍵盤操作仍精準。
- 所有可見文字維持八語本地化與 Dynamic Type／VoiceOver 可用性。

## 3. 不在本次範圍

- 不更改 `AdvancedToneCurve`、sidecar、Preset、XMP 的資料格式；若現有模型已支援多點，只補足 UI 與互動。
- 不更改 RAW 解碼、渲染品質、匯出色彩或直方圖資料來源。
- 不修改 `DEVELOPMENT_TEAM`、provisioning、簽章、Bundle ID 或 `.xcodeproj` 的本機設定。
- 不新增第三方 UI 套件；優先使用 SwiftUI、Core Graphics／Canvas 與既有 `AdjustmentUI` 元件。

## 4. 視覺與版面契約

### 4.1 共用 Inspector

- 面板背景使用既有深色材質層級；內容區、輸入控制與分隔線要有可辨識但低干擾的對比。
- 標題、分組標題、欄位標籤、數值與說明文字建立固定字級階層，不以放大標題填補空白。
- 所有控制列在 320 pt 寬的 iPad Inspector 仍能完整顯示，禁止文字截斷、水平溢出與控制互相覆蓋。
- Mac 可在窄視窗縮排；iPad 11／13 吋橫直向、Split View、Stage Manager 與外接顯示器都要使用相同元件而非第二套 catalog。
- 面板狀態（搜尋、收藏、釘選、reset、undo／redo、儲存）不得因旋轉或拖曳面板而寫入 sidecar 或新增 undo。

### 4.2 數值輸入欄位

- 欄位寬度以 80–96 pt 為上限，數值右對齊、使用等寬數字；標籤與欄位之間保留一致間距。
- 欄位不可使用無邊界的純黑填色。使用低對比材質／填色、細邊框與明確焦點環；深色模式下仍與面板背景分層。
- 重設使用熟悉的 circular arrow 圖示按鈕，命中區至少 44×44 pt；不可把整個欄位誤當成重設按鈕。
- 進入編輯時保留部分輸入內容；提交時 clamp 到既有 range，無效值回復上一個合法值；滑桿更新不可破壞正在輸入的小數。
- iPad 顯示數字鍵盤／標點鍵盤，Return、點擊面板外與 VoiceOver 調整都要提交同一條路徑。
- `accessibilityLabel` 必須包含調整名稱，`accessibilityValue` 必須反映目前格式化值；焦點狀態不可只靠顏色。

### 4.3 Slider row

- 滑桿軌道、thumb 與數值欄位在同一視覺群組內；thumb 不得因文字長度改變位置或列高。
- 保留既有範圍與步進；顯示值與輸入欄位使用同一格式化規則。
- 每列至少 44 pt 高，列與列之間留出足夠呼吸空間；在窄寬度下優先換行，不得壓縮到不可操作。

## 5. 色調曲線 UX

### 5.1 行為

- 中性曲線可使用五個預設錨點（0、0.25、0.5、0.75、1）；五點不是上限。
- 點擊曲線空白區新增控制點，新增點依 x 排序並禁止與端點／既有點重疊。
- 拖曳控制點時維持 x 嚴格遞增與 y 範圍 0...1；端點不可被拖離畫布。
- 長按／右鍵控制點提供「刪除控制點」；端點不可刪除，刪除至少保留兩點。刪除、插入、拖曳各自形成一筆可復原的 compound undo。
- 命中區至少 44×44 pt，視覺圓點可小於命中區；最近點選取必須有選取回饋，不得因點距離太近而拖錯點。
- `Reset Channel` 只重設目前 Composite／Red／Green／Blue channel；`Reset All` 重設全部 channel。

### 5.2 視覺

- 圖表固定最小高度 170 pt、圓角與面板背景分層；加入四等分網格與中性對角線。
- Composite 使用 accent color，Red／Green／Blue 使用對應色，但曲線與控制點需有足夠亮度與白色外框，避免在深色照片上消失。
- 顯示目前 channel、控制點數量與簡短操作提示；提示必須由本地化字串提供，不在程式中硬編英文。
- 圖表在 320 pt 窄欄位與 Dynamic Type 大字級下仍完整可見；不要讓 Reset 按鈕擠壓 channel picker。
- 若平台允許，提供目前選取點的輸入值／座標輔助；不可新增第二套曲線資料模型。

### 5.3 無障礙

- VoiceOver 可依序讀取 channel、曲線狀態、控制點數量與可用動作；對控制點提供增加、移動、刪除與重設動作名稱。
- 不依賴紅／綠／藍單一色差辨識 channel，需同時提供文字標籤。
- Apple Pencil 與手指拖曳使用相同 clamp／undo 語意。

## 6. 直方圖 UX

- RGB 與 Luminance 使用 segmented control；目前模式與圖例有清楚選取狀態。
- 繪圖區有穩定高度與左右內縮，最後一個 bin 不得貼邊或被裁切。
- 對單一極端裁切尖峰使用有界的 log／percentile 顯示壓縮，保留峰值相對關係並讓低頻細節可見；原始 clipping count 仍照實顯示。
- RGB 疊圖採半透明填色＋輪廓線；不可因三條線重疊而變成一塊不可辨識的灰塊。
- Shadow／Highlight clipping 以圖示、顏色與數值同時呈現；空資料顯示本地化 empty state，不畫出 NaN、負高度或越界 Path。
- 高對比模式、深色模式與窄 Inspector 下，圖表與圖例不得和下一個 section 重疊。

## 7. 工程與協作要求

- 修改集中在 `Sources/AdjustmentUI` 及必要的 Mac／iPad host；優先共用元件，不要複製另一份 iPad catalog。
- 保留目前使用者與 Codex 未提交的簽章變更；不得 reset、checkout、clean 或覆寫其他 agent 的 dirty files。
- 先閱讀 `docs/coordination/CURRENT.md`、`docs/coordination/DECISIONS.md` 與本 spec，再開始編輯。
- 如現有 agent 不適合視覺或真機工作，可關閉該 agent；需要時自行尋找並啟用合適的 iOS design review／iOS QA agent。不同 agent 不得同時編輯同一工作樹。
- 不執行 `git push`、`git merge`、`git rebase`；完成後更新 `CURRENT.md`，列出 dirty files、測試、真機 gate 與未完成事項。

## 8. 驗證計畫

### 自動化

1. 新增／更新 `AdjustmentValueInput` 測試：格式化、invalid commit、range clamp、reset、editing 中的外部更新。
2. 新增／更新曲線模型測試：五點 neutral、任意點插入、端點／重複拒絕、嚴格 x 排序、刪除限制、四 channel reset、undo 單筆交易。
3. 新增／更新 histogram 測試：空資料、負值清理、單一極端尖峰、RGB／Luminance、所有顯示高度皆在 0...1。
4. 執行：
   - `swift test`
   - `swift build -Xswiftc -strict-concurrency=complete`
   - iPad Simulator `xcodebuild ... CODE_SIGNING_ALLOWED=NO build`
   - `git diff --check`
   - 隱私掃描（不得命中私人絕對路徑、Team ID、UDID、私鑰）

### 真機人工驗收

- M 系列 iPad 11／13 吋：開啟 RAW、切換四 channel、插入／拖曳／刪除控制點、Undo／Redo、切換 RGB／Luminance、調整數值欄位與重設。
- Mac Apple silicon：同一 fixture 重做上述流程，確認面板與 iPad 的欄位、曲線與直方圖語意一致。
- 橫向、直向、Split View、Stage Manager：不得有文字截斷、曲線／直方圖破圖、控制重疊、不可達按鈕或鍵盤遮蔽輸入欄位。
- 手指、Apple Pencil、滑鼠與鍵盤各完成一次；VoiceOver 至少巡覽曲線與三個數值欄位。
- 每個驗收項目記錄 PASS／FAIL／SKIPPED／NOT RUN，不以模擬器建置成功代替真機視覺驗收。

## 9. 完成定義

- 本 spec 的所有自動化測試通過，且沒有把既有 signing contract failure 誤報為產品回歸。
- iPad 截圖中數值欄位不再是難辨識的純黑長框，曲線可超過五點並可刪除，直方圖不再貼邊或被極端尖峰壓成平線。
- Mac／iPad 共享實作與在地化 key parity 維持通過。
- `CURRENT.md` 有本階段摘要與精確驗證證據；未完成的真機／外接裝置 gate 明確列出。
- Claude 回報實際修改檔案、測試結果與是否使用／關閉額外 agent；不得只回覆「看起來完成」。
