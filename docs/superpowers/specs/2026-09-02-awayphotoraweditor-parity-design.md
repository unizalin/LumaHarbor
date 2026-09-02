# LumaHarbor：AwayPhotoRawEditor 功能對標設計規格

- 狀態：草案，等待實作計畫拆分
- 日期：2026-09-02
- 目標平台：macOS 優先，iPadOS 共用核心與後續介面
- 對標來源：`https://github.com/awaysu/AwayPhotoRawEditor`，README observed 2026-09-02
- 基準分支：`codex/ipad-ui-ux-state-feedback-polish`

## 1. 產品定位

LumaHarbor 要從「Mac-first RAW MVP」升級成 Apple 原生的完整 RAW 相片編輯器，功能完整度對標 AwayPhotoRawEditor。使用者允許排版依 macOS / iPadOS 原生操作調整，但功能面要追齊：非破壞式 RAW 編輯、調色、局部修圖、風格檔、批次、多格式匯出、EXIF、浮水印、主題與多語介面。

本專案仍是 Swift / SwiftUI / Core Image 的全新實作。AwayPhotoRawEditor 只能作為功能、資料模型與 UX 行為參考；不得複製 WinForms 原始碼、圖示、圖片素材、字串資產或平台專屬實作。

## 2. 對標範圍

AwayPhotoRawEditor README 明列的使用者可見功能全部納入 LumaHarbor 長期 roadmap：

1. RAW 解碼與一般影像格式讀取。
2. EXIF 讀取與呈現。
3. GPU 加速算圖，失敗時可退回 CPU 或等效安全路徑。
4. 線性光色彩管線，白平衡與曝光在線性域處理。
5. RAW 8-bit / 16-bit 處理精度選項或等效高品質渲染選擇。
6. 基本調整、Kelvin 白平衡、白平衡滴管。
7. 細節調整：銳利度、暗角、降噪。
8. 裁切、旋轉、廣角變形。
9. 多重線性漸層。
10. 局部修護。
11. 風格檔：內建、自訂、可編輯覆寫、備份、還原。
12. 縮圖多選批次編輯。
13. 批次復原。
14. 虛擬副本。
15. 匯出：重新命名規則、尺寸上限、DPI、浮水印、EXIF 保留。
16. 兩套視覺主題：經典深色、暖白相紙；LumaHarbor 可用 Apple 原生樣式重設計，但必須提供同等的深色與暖色閱讀體驗。
17. 八語介面：繁體中文、English、日本語、한국어、简体中文、Deutsch、Français、Español。

## 3. 非目標

- 不移植 Windows UI 佈局、WinForms 自繪控制、DPI 縮放系統、Inno Setup、Authenticode 簽章或 Direct3D 12 實作。
- 不承諾與 AwayPhotoRawEditor、Lightroom 或 LibRaw 的輸出逐像素一致。目標是功能與使用體驗對標，影像結果需由 LumaHarbor 自己的渲染管線定義可驗證容差。
- 不在沒有使用者確認的情況下修改 RAW 原檔、覆寫 sidecar、刪除外接來源資料，或把 `SKIPPED` / `NOT RUN` 記為 `PASS`。
- 不一次把所有功能塞進單一巨大實作分支。這份 spec 定義整體產品範圍；實作必須拆成可測試、可 review、可回退的階段。

## 4. 現況對照

| 功能群 | LumaHarbor 現況 | 對標缺口 |
|---|---|---|
| RAW 圖庫與非破壞式編輯 | Mac-first MVP 已完成；iPad 多來源圖庫已 land 到 `main` | 要把穩定圖庫能力延伸到完整工作流與批次 |
| 基本調色 | 已有曝光、白平衡、對比、高光、陰影、白色、黑色、自然飽和度、飽和度 | 需補白平衡滴管、精度選項與更清楚的顏色管線驗證 |
| 進階調整 | HSL、曲線、分離色調、銳化、降噪、暈影、顆粒已有 model / pipeline 基礎 | 需產品化 UI、驗證視覺容差、與 preset / batch 串起 |
| Preset / XMP | 原生 preset 與 Lightroom develop preset Phase 1 已部分完成 | 需補內建 preset、可編輯覆寫、備份/還原、完整 UI 與 XMP Phase 2 |
| 幾何工具 | 尚未完整產品化 | 裁切、旋轉、拉直、翻轉、廣角變形 |
| 局部工具 | 尚未開始 | 多重線性漸層、局部修護；未來可擴到徑向/筆刷 |
| 批次與虛擬副本 | 尚未完整 | 多選、同步欄位、批次復原、虛擬副本資料模型 |
| 匯出 | 已有單張 JPEG | 需批次、多格式、重新命名、尺寸、DPI、水印、EXIF |
| EXIF / Histogram | 部分 RAW metadata 基礎 | 需使用者可見 EXIF 面板、直方圖與篩選/排序欄位 |
| 主題與多語 | 已有英文與繁中 | 需 2 主題與 8 語本地化流程 |
| 自動化驗證 | 已有 MVP / iPad acceptance runner | 需 headless render/export/selftest、固定輸出基準、UI 截圖回歸 |

## 5. 架構原則

### 5.1 功能模型先於 UI

所有編輯功能都必須先落在可序列化、可測試的 model，再由 macOS / iPadOS UI 呈現。sidecar 仍是非破壞式狀態的唯一權威來源，RAW 原檔永不修改。

### 5.2 macOS 與 iPadOS 共用核心

`RawProcessingCore`、`PhotoLibraryCore`、`PresetCore` 與未來的 batch/export/local-adjustment core 不依賴 SwiftUI 畫面。macOS 可以先交付完整桌面 workflow，iPadOS 之後重用核心能力與必要的操作縮減。

### 5.3 對標不是照抄

LumaHarbor 要保留 AwayPhotoRawEditor 的功能完整度與工作流精神，但採 Apple 原生操作：

- macOS 用 sidebar / inspector / toolbar / sheet / menu commands。
- iPadOS 用 split view、floating panel、Apple Pencil-friendly controls。
- 兩者共用功能語意、sidecar schema、preset schema 與測試基準。

### 5.4 渲染與驗證可重現

每個影像功能都必須有至少一種非互動驗證：

- model / mapping 單元測試；
- fixed fixture render checksum 或容差比較；
- export metadata / size / DPI / watermark 驗證；
- UI source contract 或 screenshot regression；
- real-device gate 只記錄真正跑過的項目。

## 6. 功能需求

### 6.1 圖庫與檔案格式

LumaHarbor 必須能瀏覽 RAW 與常見一般影像格式。RAW 第一階段沿用 `CIRAWFilter`，並維持 `RawDecoding` protocol，以便未來加入 LibRaw 或其他 decoder fallback。一般影像格式可透過 ImageIO / Core Image 讀取，必須跟 RAW 一樣走非破壞式 sidecar，不因格式不同改變編輯儲存模型。

支援格式至少分三層：

- Tier 1：Sony `.ARW`，已是驗收主格式。
- Tier 2：Apple 平台常見 RAW、DNG、JPEG、PNG、TIFF、HEIC。
- Tier 3：其他相機 RAW，由 decoder 能力與 fixture availability 決定；UI 要明確標示不支援或 decode failed。

### 6.2 EXIF、Metadata 與直方圖

編輯畫面必須有 EXIF / metadata 區塊，至少顯示：

- 檔名、格式、像素尺寸、檔案大小；
- 相機、鏡頭、焦距、光圈、快門、ISO；
- 拍攝時間、色彩描述、orientation；
- source 狀態：ready、read-only、offline、needs access；
- sidecar 狀態：saved、unsaved、save failed。

直方圖必須反映目前預覽渲染結果，不可只讀原圖統計。初版可先做 RGB composite + per-channel histogram，後續再加 clipping warning。

### 6.3 基本與進階調整 UI

現有調整模型必須產品化為清楚的 panel：

- Basic：曝光、對比、高光、陰影、白色、黑色、自然飽和度、飽和度。
- Color：Kelvin 白平衡、Tint、白平衡滴管、HSL 八色。
- Curve：基本 tone curve 與進階曲線。
- Detail：銳化、降噪。
- Effects：暗角、顆粒。

每個調整必須有：

- 明確中性值與 reset；
- slider 範圍與 keyboard / precision input；
- Undo / Redo；
- before / after preview；
- autosave 狀態；
- preset / batch 可引用的 stable field ID。

### 6.4 白平衡滴管

滴管選取預覽上的一點或小範圍，根據取樣結果調整 temperature / tint。RAW 來源可使用 as-shot metadata 作 baseline；一般影像格式則以已解碼 RGB 估算。使用者必須能取消滴管，不得在 hover / preview 階段寫入 sidecar。

### 6.5 裁切、旋轉、拉直與廣角變形

幾何工具必須是非破壞式調整的一部分，寫入 sidecar。功能包含：

- 裁切框拖曳；
- 固定比例與自由比例；
- 旋轉 90 度；
- 水平 / 垂直翻轉；
- 拉直角度 slider；
- 所見即所得的旋轉後裁切預覽；
- 廣角變形 / perspective correction，至少水平與垂直方向。

裁切與旋轉的 UI 正負方向必須用真人或 screenshot fixture 驗證，不能只用數學座標直覺決定。

### 6.6 多重線性漸層

支援一張照片多個線性漸層。每個漸層包含：

- 位置、角度、範圍、羽化；
- 啟用 / 停用；
- 局部 mini adjustments：曝光、對比、高光、陰影、白色、黑色、飽和度、色溫、色調；
- 選取、拖曳、刪除與複製。

sidecar 使用結構化陣列保存，不使用不可 diff 的遮罩點陣圖作第一版資料模型。iPadOS 後續要支援 Apple Pencil / touch hit target。

### 6.7 局部修護

局部修護第一版至少支援 spot heal：

- 新增修護點；
- 移動 target / source；
- 大小與羽化；
- heal / clone 模式；
- 刪除與選取；
- 模式切換時，當前選取點必須立即更新，不只影響下一個新點。

修護必須在匯出時以完整解析度重算，不得把預覽 bitmap 當最終輸出。

### 6.8 Preset 系統

Preset 必須包含：

- 內建 preset；
- 使用者自訂 preset；
- 從目前照片建立 preset；
- 編輯 preset 覆寫欄位；
- preset group / favorite / search；
- hover 或選取時暫時預覽；
- 合併套用與完整取代；
- 備份與還原；
- 匯入 / 匯出原生 `.lhpreset`；
- Lightroom / Camera Raw `.xmp` develop preset 匯入與相容層。

Preset 檔案使用稀疏 patch：只保存明確覆寫的欄位。把欄位改回內建值時，應從覆寫 patch 移除，而不是留下無意義的值。

### 6.9 批次編輯與批次復原

縮圖列必須支援多選。批次同步規則：

- 使用者開始拖曳 slider 或開始套用 preset 時，立即 snapshot 當下選取目標。
- 只同步這次手勢或這次操作改動過的欄位，不複製整份調整。
- 批次寫入延後到 commit 點，不在每個拖曳 frame 寫 sidecar。
- 批次 undo 是 compound undo，包含目前照片與其他目標照片的舊值。
- 切換照片後可清空短期 undo stack，但不得讓 sidecar 進入半套用狀態。
- 局部修護、裁切與幾何變形預設不參與批次同步，除非使用者明確選擇。

### 6.10 虛擬副本

虛擬副本允許同一 RAW 有多份不同調整，不複製 RAW 原檔。需求：

- 每個 virtual copy 有自己的 identity、name、createdAt、adjustments、rating/flag；
- 圖庫中與原照片相鄰顯示，可展開/收合或以 badge 標示；
- 匯出、preset、批次、搜尋都能選到 virtual copy；
- 刪除 virtual copy 不刪 RAW 原檔，也不刪其他 copy；
- sidecar schema 能區分原始 photo identity 與 copy identity。

### 6.11 匯出

匯出必須從完整解析度來源重新渲染，不使用預覽快取。功能包含：

- 單張與批次匯出；
- JPEG、TIFF、PNG、HEIC；
- JPEG / HEIC 品質；
- TIFF 8-bit / 16-bit；
- 色彩空間選擇，初版至少 sRGB；
- 長邊 / 短邊 / 寬高上限；
- DPI metadata；
- 重新命名規則：原檔名、序號、日期、preset name、virtual copy name；
- 浮水印：文字、位置、不透明度、大小；
- EXIF 保留、移除或部分保留；
- 同名檔處理：遞增流水號、詢問、或跳過；
- 取消後清理暫存檔；
- per-file 成功/失敗報告。

### 6.12 評分、旗標、篩選與搜尋

為支援批次工作流，圖庫需加入：

- 星等評分；
- pick / reject 或等效旗標；
- 隱藏 rejected；
- 搜尋檔名、日期、相機、鏡頭、rating、flag、format；
- 排序：拍攝時間、檔名、評分、修改時間；
- 匯出預設排除 hidden / rejected，除非使用者明確包含。

照片序號若顯示給使用者，隱藏項目仍保留原序號，避免討論「第 7 張」時因篩選而變號。

### 6.13 主題與多語

主題需求：

- 經典深色：適合長時間修圖，壓低非照片區域亮度。
- 暖白相紙：適合看成品、整理與比較，背景溫暖但不得影響色彩判斷。
- 跟隨系統與手動切換。

多語需求：

- 繁體中文；
- English；
- 日本語；
- 한국어；
- 简体中文；
- Deutsch；
- Français；
- Español。

所有使用者可見字串必須走 localization，不得在 SwiftUI view 裡散落硬編未登錄字串。初期可先用現有 `.strings`，之後評估搬到 `.xcstrings`。

### 6.14 設定與診斷

設定至少包含：

- 渲染品質 / 效能模式；
- GPU / CPU fallback 狀態顯示；
- RAW 處理精度；
- cache 大小與清除；
- sidecar / preset 備份；
- 語言與主題；
- privacy-safe diagnostic export。

診斷命令需對標 AwayPhotoRawEditor 的 headless spirit，提供 LumaHarbor 等效模式：

- selftest：確認 decoder、render、sidecar、export 基本可用；
- exporttest：固定 fixture + 固定調整輸出，檢查 metadata 與像素容差；
- shot：打開 fixture library 並產生 UI 截圖；
- gallery：產生縮圖/預覽回歸證據。

## 7. 資料模型

### 7.1 Sidecar

現有 `.lumaharbor/edits/*.json` 要升級為可承載完整對標功能：

- global adjustments；
- geometry adjustments；
- local adjustments；
- preset application history summary；
- virtual copy identity；
- rating / flag / hidden；
- export defaults；
- compatibility diagnostics。

Sidecar 必須向後相容。舊 sidecar 讀取時缺欄位一律視為中性值或預設 metadata，不得 crash。

### 7.2 Local Adjustment

第一版局部調整 model：

```swift
public struct LocalAdjustment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: LocalAdjustmentKind
    public var isEnabled: Bool
    public var geometry: LocalAdjustmentGeometry
    public var adjustments: LocalAdjustmentPatch
}
```

`kind` 初期包含 `.linearGradient` 與 `.spotHeal`。未來可加入 `.radialGradient`、`.brushMask`。

### 7.3 Virtual Copy

```swift
public struct PhotoVariant: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var sourcePhotoID: PhotoID
    public var name: String?
    public var createdAt: Date
    public var adjustments: PhotoAdjustments
    public var rating: Int?
    public var flag: PhotoFlag
}
```

現有 `PhotoAsset` 可代表 RAW 原始檔；`PhotoVariant` 代表同一原始檔的不同編輯版本。實作計畫需決定是否把預設版本也顯式建成 variant。

### 7.4 Batch Operation

批次操作需保存 transaction 訊息：

- operation id；
- target variant ids；
- modified field ids；
- before values；
- after values；
- per-target write result。

這份 transaction 可用於短期 undo 與錯誤報告，不要求永久保留完整歷史。

## 8. UI/UX 要求

### 8.1 macOS 主畫面

macOS 版保留專業修圖三區式工作流：

- 左側：Library / folders / albums / filters / source status。
- 中央：主預覽、zoom、pan、before-after、crop/local tool overlay。
- 下方或左側：thumbnail filmstrip / grid，多選與 virtual copy badge。
- 右側：Histogram、EXIF、調整 panels、preset browser、export queue。

排版可以不同於 AwayPhotoRawEditor，但同等功能必須在一到兩次操作內可達，不可藏到難找的 menu 深處。

### 8.2 iPadOS 主畫面

iPadOS 版以已完成的 multi-source library 為基礎：

- split view 圖庫；
- floating inspector；
- touch / Pencil hit target；
- 檔案來源 offline / needs access 狀態；
- local tools 可用 Pencil 精準操作；
- 匯出與批次可先晚於 macOS，但 core schema 不可阻擋 iPadOS 使用。

### 8.3 狀態與安全文案

任何會讓使用者擔心照片安全的操作都要明說：

- RAW originals are never modified；
- remove source only forgets the source from LumaHarbor；
- sidecar / manifest handling；
- export writes new files；
- batch action affected N selected photos；
- failed / skipped / not run 不得偽裝成成功。

## 9. 分階段交付

### Phase A：收斂目前 UI polish 分支

完成 `codex/ipad-ui-ux-state-feedback-polish`：

- Task 2 review fix；
- Task 3 editor save failure copy；
- Task 4 verification report；
- 更新 `CURRENT.md`；
- Claude final review。

### Phase B：Mac Parity Foundation

先把 macOS 做成對標主戰場：

- EXIF / histogram panel；
- 調整 panel 產品化；
- 白平衡滴管；
- crop / rotate / straighten；
- 多格式單張匯出。

### Phase C：Preset 與 Batch

- 內建 preset library；
- 自訂 preset 編輯覆寫；
- preset 備份 / 還原；
- 多選批次同步；
- 批次 undo；
- virtual copy；
- 批次匯出。

### Phase D：Local Retouching

- 多重線性漸層；
- spot heal / clone；
- local adjustment sidecar；
- full-resolution export render；
- screenshot / fixture regression。

### Phase E：iPadOS Parity

- 將 Phase B-D 的核心能力接到 iPadOS；
- Apple Pencil-friendly local tools；
- iPad export workflow；
- real-device gate。

### Phase F：Polish、Themes、Languages、Diagnostics

- 經典深色 / 暖白相紙；
- 八語 localization；
- headless diagnostics；
- release checklist；
- About / acknowledgements 明確標示 AwayPhotoRawEditor inspiration，但不宣稱 affiliation。

## 10. 驗收標準

每個 phase 必須有：

- 一份 implementation plan；
- 每個 task 的 RED / GREEN 測試證據；
- `swift test` 或合理範圍測試；
- `git diff --check`；
- privacy scan；
- 對影像輸出的 fixture 證據；
- 對 UI 的 screenshot 或 manual checklist；
- 明確列出 `PASS`、`FAIL`、`SKIPPED`、`NOT RUN`。

整體 parity 版本達成條件：

- 使用者能從資料夾開啟 RAW，完成基本/進階/局部修圖，建立或套用 preset，多選批次調整，建立 virtual copy，並批次匯出含命名、尺寸、DPI、浮水印與 EXIF 設定的成品。
- 同一份 RAW 原檔在所有流程中 checksum 不變。
- 重新啟動 App 後圖庫、sidecar、preset、virtual copy、batch 結果可恢復。
- Offline / read-only / needs access / disk full / corrupt file 都有可理解錯誤與下一步。
- macOS 完整通過 automated + manual checklist；iPadOS 至少通過該 phase 宣告支援的 parity subset。

## 11. 風險與決策

- LibRaw vs Core Image：短期繼續 Core Image；若格式支援或 metadata 差異阻擋 parity，再開 LibRaw fallback spec。
- ExifTool：若 Apple metadata API 不足以達到 AwayPhotoRawEditor 等級，需評估內嵌或呼叫 ExifTool 的授權、部署與 sandbox 風險。
- GPU / CPU：Apple 平台以 Core Image / Metal 為主，不做 Direct3D 對應；要定義可觀測 fallback 與品質一致性測試。
- XMP 相容：不承諾 Lightroom 像素一致，但要保存未知欄位，不丟資料。
- Local retouching：修護演算法品質是最大未知，需以最小 spot heal 開始，避免先做太大的 AI 修圖承諾。
- 多語：八語會擴大維護成本；需要 key coverage tests 與翻譯缺漏 gate。

## 12. 下一步

1. 先完成 Phase A，把目前 `codex/ipad-ui-ux-state-feedback-polish` 收乾淨。
2. 寫 Phase B implementation plan：Mac Parity Foundation。
3. Phase B 完成後再切 Phase C-D，不要讓 batch / local tools 先污染尚未穩定的 geometry / export schema。

## 13. 來源

- AwayPhotoRawEditor README：`https://github.com/awaysu/AwayPhotoRawEditor`
- LumaHarbor existing reference notes：`docs/reference/awayphotoraweditor-design-notes.md`
- LumaHarbor next-phase scope notes：`docs/reference/next-phase-scope-notes.md`
- LumaHarbor Mac-first MVP design：`docs/superpowers/specs/2026-08-13-mac-first-mvp-design.md`
