# iPad 直向非侵入式 Inspector 設計規格

- 日期：2026-09-15
- 狀態：使用者已核准方向，待書面規格複核
- 目標平台：iPadOS 17+
- 基準分支：`codex/open-source-release-prep`
- 關聯規格：`2026-09-09-unified-adaptive-professional-inspector-design.md`

## 1. 問題與目標

目前直向 Compact／Standard 編輯器把 Inspector 放在不可完全關閉的 bottom sheet 內。最小 detent 仍遮住照片，且橫向 domain bar 在實機只呈現單一「調整」項目，造成 Preset、幾何調整、局部調整與資訊看似消失。

本次目標是讓照片維持主體：直向 Inspector 可完全收起；收起後只留下不占版面的側邊圓形工具按鈕，並保留上方工具列入口。任一入口都能重新開啟同一個 Inspector。展開後五個功能域必須完整且可操作。

## 2. 已核准互動

### 2.1 收起狀態

- Bottom sheet 完全關閉，不保留 220 pt peek，也不為面板預留 canvas inset。
- 畫布側邊顯示一顆 44×44 pt 以上的圓形工具按鈕，圖示使用既有 Inspector／調整語意的 SF Symbol。
- 按鈕置於 safe area 內，預設靠右側垂直置中；不得蓋住上方工具列或 Home Indicator。
- 上方工具列保留另一個開啟 Inspector 的入口。兩個入口執行相同行為並共用 accessibility label。
- 側邊按鈕屬於 overlay，不參與 canvas layout，因此不縮小或推移照片。

### 2.2 展開狀態

- 點擊側邊圓形按鈕或上方入口，開啟同一張 bottom sheet。
- Sheet 提供 medium 與 large detent；不再以固定 220 pt 當成常駐最小狀態。
- 使用者向下關閉 sheet 後回到完全收起狀態，側邊圓形按鈕重新出現。
- 展開與關閉只改變 presentation state，不改動目前照片、調整值、undo／redo、zoom、compare mode 或 autosave。

### 2.3 五個功能域

Sheet 內固定以單列、等寬五欄顯示：

1. 調整（Adjust）
2. Preset
3. 幾何調整（Geometry）
4. 局部調整（Local）
5. 資訊（Info）

每欄至少 44 pt 高；可用寬度平均分配，不讓單一按鈕以無限寬度擠掉其餘項目。每個項目同時具備 SF Symbol、在地化 accessibility label 與 selected trait。切換 domain 只替換同一張 sheet 的內容，不開第二張 sheet。

## 3. 版面與狀態規則

- Expanded／Wide 橫向 trailing dock 維持既有完整五域工具軌，不受本次變更影響。
- Compact／Standard 使用可關閉 bottom sheet、上方入口與側邊圓形入口。
- 旋轉或 Stage Manager resize 到 trailing dock 時，關閉 bottom sheet 並在 dock 中保留目前 domain。
- 從 trailing dock 變回 Compact／Standard 時，不自動遮住照片；預設維持 Inspector 收起，由使用者入口叫出。
- 同一文件內保留目前 domain 與 Adjust submode；切換文件依既有 document-scoped policy 處理，不新增第二份狀態。
- Focus mode 維持既有浮動面板行為；本次側邊按鈕只屬於 work mode 的 Compact／Standard presentation。

## 4. 元件與責任

- `PadEditorLayoutPolicy`：加入純 presentation policy，決定窄版 Inspector 是否應呈現、是否顯示側邊 launcher；不得依裝置名稱或 orientation 判斷。
- `PadEditorView`：擁有可關閉 sheet binding、上方入口與 canvas overlay launcher；不持有第二份調整資料。
- `PadInspectorHost`／domain bar：使用明確的等寬欄位配置，確保五個 domain 同時可見。
- `PadInspectorCoordinator`：繼續作為 active domain 與 Adjust submode 的唯一 presentation state 權威。

不在本次處理共用 catalog、搜尋、收藏或 Mac Inspector 重構；那些工作仍由統一面板規格的後續 phase 管理。

## 5. 無障礙與視覺

- 側邊 launcher 命中區至少 44×44 pt，使用 material／對比背景與圓形外觀，在深色照片上仍清楚可見。
- launcher accessibility label 為「顯示編輯工具」，hint 說明會開啟 Inspector。
- 上方與側邊入口不重複出現在 VoiceOver 的模糊名稱中；兩者名稱一致、位置不同但行為相同。
- 五域按鈕在最大 Dynamic Type 下仍維持完整五欄；視覺可只顯示圖示，名稱由 VoiceOver 與輔助提示提供。
- Reduce Motion 開啟時沿用系統 sheet transition，不增加自訂彈跳動畫。

## 6. 測試與驗收

### 6.1 自動化

- Policy test：Compact／Standard 在 sheet 關閉時顯示 launcher；sheet 開啟時隱藏 launcher；Expanded／Wide 不顯示 launcher。
- State test：sheet 可由側邊與上方入口開啟，也可由使用者 dismiss；關閉後能再次開啟。
- Contract test：domain bar 恰好包含五個 domain，使用等寬欄位，不使用會讓單一 item 獨占寬度的配置。
- Regression test：切換 domain、開關 sheet、旋轉／resize 不更動 EditorSession 調整值或 undo 狀態。
- Focused tests、完整 `swift test`、`git diff --check` 與 generic iOS build 必須執行並分別記錄結果。

### 6.2 實機／視覺

- 11 吋 iPad 直向：收起時照片不被 bottom sheet 遮住，側邊圓形按鈕清楚可點。
- 展開 sheet：調整、Preset、幾何調整、局部調整、資訊五項同時可見且均可切換。
- medium／large 間拖曳不改變照片編輯狀態；向下關閉後畫布恢復完整。
- 上方入口與側邊入口都能反覆開啟同一張 sheet，不疊加面板。
- 橫向、直向往返與 Stage Manager resize 保留目前照片、domain、submode、zoom 與 undo。
- 未實際執行的實機項目必須記為 `NOT RUN`，不得以 source contract 或 simulator 代替。

## 7. 方案取捨

- 採用：完全收起 + 側邊圓形 launcher。最符合「主體不影響到圖片修改」，代價是叫出面板多一次點擊。
- 未採用：固定底部五按鈕。切換較快，但持續占用畫布高度。
- 未採用：可拖曳小型浮動 Inspector。彈性高，但仍可能遮住正在判讀的照片內容。

## 8. 完成條件

本項只有在下列條件成立時完成：

1. 直向收起後不保留 sheet 占位，照片可完整檢視。
2. 上方與側邊圓形入口都能可靠開啟 Inspector。
3. 五個功能域在直向 sheet 中同時可見且能切換。
4. 開關、拖曳、旋轉與 resize 不建立 undo、不修改調整值、不觸發不必要 autosave。
5. 自動化與 build 通過；實機視覺結果以 `PASS`／`FAIL`／`NOT RUN` 如實記錄。
