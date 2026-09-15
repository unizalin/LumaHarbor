# LumaHarbor 專業修圖功能路線圖規格

- 狀態：設計草案，等待使用者審閱
- 日期：2026-09-09
- 目標平台：macOS 與 iPadOS 17+
- 目標裝置：Apple silicon Mac、M1 或更新 iPad
- 基準分支：`codex/open-source-release-prep`
- 關聯規格：`2026-09-09-ipad-studio-rails-mac-feature-parity-design.md`

## 1. 目標

將 LumaHarbor 從「已有 RAW 調整核心的照片編輯器」提升為完整的非破壞式專業修圖工作流。Mac 與 iPad 必須共用調整語意、sidecar、preset、undo、批次同步與匯出 request；平台差異只存在於工具呈現、輸入方式與系統檔案／照片整合。

本案採四階段交付：

1. **Phase 1：既有功能 parity**：把目前核心已支援的調整完整接到 iPad，並補足批次、匯出、Geometry、Local 的實際資料流。
2. **Phase 2：專業色彩與鏡頭**：鏡頭校正、色彩分級、Texture／Clarity／Dehaze、黑白混色與 Profile。
3. **Phase 3：進階遮罩與修復**：筆刷、放射遮罩、亮度／色彩範圍遮罩、Clone 與強化 Spot Heal、透視校正。
4. **Phase 4：專業檢視與版本工作流**：快照版本、A／B 比較、裁切警告、色域警告、軟打樣與進階批次報告。

## 2. 產品原則

- RAW 原檔永遠不修改、搬移或刪除。
- 所有調整都可獨立停用、重設、撤銷與重做。
- 預覽、滑動與遮罩拖曳不直接寫 sidecar；只有 commit／autosave 才寫入。
- Mac 與 iPad 使用相同 stable field ID，不因平台新增同義欄位。
- 不能以只有按鈕或 contract test 的 shell 宣稱完成；每項功能需有成功、取消、失敗與離線行為。
- 不納入生成式 AI、雲端同步、tethered capture 或多圖層合成；這些另立產品規格。

## 3. 現有核心與缺口

### 3.1 已有核心，Phase 1 必須接上 iPad

- Basic：Exposure、Contrast、Highlights、Shadows、Whites、Blacks。
- Color：Temperature、Tint、Vibrance、Saturation、八色 HSL。
- Tone：Advanced Tone Curve。
- Detail：Sharpening、Noise Reduction。
- Effects：Vignette、Grain。
- Geometry：Crop、比例、旋轉、翻轉、拉直的資料模型與 panel。
- Local：Linear Gradient、Spot Heal 的非破壞式資料模型與 overlay。
- Compare、Preset、undo／redo、full-resolution export 與 filmstrip 的共用流程。

### 3.2 Phase 1 交付缺口

- iPad Adjust rail 的 Light／Color／Detail 真實 panel 與精確數值輸入。
- Geometry 與 Local domain 的 canvas overlay、座標轉換、取消與 commit。
- 批次 copy／paste、欄位選取、sync to selected、compound undo 與 partial report。
- JPEG／HEIC／PNG／TIFF 匯出選項、尺寸、品質、DPI、命名、EXIF 與 collision policy。
- viewport Fit／100%／Custom、pan clamp 與 overlay 共用 transform。
- keyword、rating、flag 的批次編輯與持久化權威來源。

## 4. Phase 1：既有能力完整化

### 4.1 Adjust domain

Studio Rails 的 Adjust domain 使用三個互斥子模式：

- **Light**：Basic sliders 與 Tone Curve。
- **Color**：白平衡、Vibrance／Saturation、HSL、白平衡滴管。
- **Detail**：Sharpening、Noise Reduction、Vignette、Grain。

每個控制需提供：滑動、點選數值精確輸入、回到中性值、欄位重設、VoiceOver label／value／unit。拖曳期間只更新互動預覽，結束只產生一筆 undo 與一次 commit。

### 4.2 Geometry domain

- 支援 Fit、1:1、常用比例與自訂比例。
- Crop、rotate、flip、straighten 使用同一 image-to-canvas transform。
- 旋轉與裁切預覽不可寫入 sidecar，取消後完全恢復原狀。
- iPad 以觸控與 Pencil 完成所有命中；外接鍵盤只作加速器。
- 後續透視校正的資料模型必須預留，但 Phase 1 不新增透視演算法。

### 4.3 Local domain

- 多個 Linear Gradient 與 Spot Heal 顯示固定尺寸 handle，不因 badge 或選取狀態改變 layout。
- 支援新增、選取、啟用／停用、複製、刪除、重設幾何與調整值。
- 同一時間只允許一個 active local item 接收 canvas gesture。
- 在縮放、旋轉與窄視窗 sheet 中，overlay 與 panel 使用同一座標轉換。

### 4.4 批次同步

- 來源照片可複製全部或指定欄位；Geometry／Local 必須明確勾選。
- 目標數量、跳過離線來源與失敗數量在執行前後都可見。
- 一次 sync 產生 compound undo；partial failure 保留成功、失敗、跳過清單。
- 貼上與同步不可寫入 RAW，且不得把來源照片的 rating、flag、keyword 靜默覆蓋到目標。

### 4.5 匯出

- 單張與批次共用 `ExportRequest` mapper。
- 格式：JPEG、HEIC、PNG、TIFF；依平台能力顯示可用選項。
- 支援品質／bit depth、長邊或短邊上限、DPI、色彩空間、檔名 token、EXIF policy、碰撞策略。
- 顯示完成／總數、目前檔名、取消、來源離線、權限拒絕、空間不足與格式不支援。
- Files、Photos、Share 與已授權外接來源只負責 destination，不各自重新 encode。

## 5. Phase 2：專業色彩與鏡頭

### 5.1 鏡頭校正

- profile-based distortion、vignetting、chromatic aberration correction。
- 自動偵測相機／鏡頭；無 profile 時提供手動 fallback。
- 校正參數納入 preset 與批次同步，但不複製來源照片的 metadata。
- 預覽與 full-resolution export 必須使用同一校正順序。

### 5.2 色彩分級

- Shadows、Midtones、Highlights 各自提供 hue、saturation、luminance。
- Global color balance 與強度控制。
- Black & White mode 與八色混色器；切換模式可撤銷且不遺失既有彩色調整。
- Camera／creative profile 具有相容性診斷；不支援的 profile 顯示安全 fallback。

### 5.3 Texture、Clarity、Dehaze

- 以 stable field ID 加入 `texture`、`clarity`、`dehaze`。
- 預設 neutral，不影響既有 sidecar 解碼。
- 互動預覽使用低成本縮圖，匯出使用完整解析度渲染。
- 設定極值時顯示裁切或 halo 風險提示，不阻擋使用者提交。

## 6. Phase 3：進階遮罩、修復與透視

### 6.1 遮罩

- Brush：size、feather、flow、density、erase。
- Radial mask：橢圓、羽化、反轉。
- Luminance range 與 color range mask，提供可視化範圍預覽。
- 遮罩可命名、停用、複製、反轉與重新排序。
- 遮罩只儲存 normalized coordinates 與參數，不儲存臨時畫布像素。

### 6.2 修復

- Clone source point 可固定、重新指定與拖曳。
- Spot Heal 支援複製、羽化、opacity 與多個取樣模式。
- 紅眼移除僅在偵測到有效區域時啟用；不引入雲端辨識。
- 任何修復工具都必須能在 100% 與 400% viewport 精確操作。

### 6.3 透視與變形

- 垂直／水平透視、四角校正、網格與吸附輔助線。
- 自動水平線只提供建議值，必須由使用者確認才 commit。
- Geometry 與 Local 的座標順序固定，避免透視變換後遮罩漂移。

## 7. Phase 4：檢視與版本

- Snapshot 可命名、複製、刪除與回復；回復為 compound undo。
- A／B 比較可固定兩個 snapshot，不改變目前 commit。
- 高光／陰影 clipping overlay、RGB channel histogram 與色域警告可獨立開關。
- Soft proof 使用目前 display profile；無 profile 時顯示明確 fallback。
- 批次匯出報告可匯出 privacy-safe JSON／CSV，不含絕對路徑、帳號、Team ID、UDID 或 bookmark data。

## 8. 共用架構

### 8.1 權威模組

| 能力 | 權威模組 |
| --- | --- |
| stable adjustment fields、render 順序 | `RawProcessingCore` |
| patch、preset、XMP、backup | `PresetCore` |
| undo、save、preview、compound transaction | `EditorCore` |
| panel、coordinate transform、layout policy | `AdjustmentUI` |
| source、query、rating、flag、keyword、virtual copy | `PhotoLibraryCore` |
| Mac AppKit bridge | `LumaHarborApp` |
| iPad touch／Pencil／Files／Photos bridge | `LumaHarborPadApp` |

### 8.2 版本相容

- 新欄位全部提供 neutral default 與 migration test。
- 舊 sidecar 讀取後不得因未知欄位失敗；匯出時保留可 round-trip 的欄位。
- Preset 匯入需顯示 unsupported fields，但可套用其餘相容欄位。
- 任何新增 mask／lens／profile 欄位都必須加入 preset field selection 與 batch sync policy。

## 9. 錯誤、效能與資料安全

- 所有長時間 render、匯出與批次操作可取消；取消不是失敗。
- 最新 render request 取代舊 request；舊結果不得覆蓋新結果。
- overlay 操作不得因 resize、切換 inspector 或進背景而遺留 security-scoped URL。
- 錯誤文案不可露出原始路徑、bookmark data、帳號、Team ID、UDID 或 provider internal identifier。
- RAW、sidecar、preset backup 與診斷輸出不得意外進 Git。

## 10. 驗收與測試

每個 Phase 必須同時具備：

1. shared-core 單元測試：neutral、範圍、migration、round-trip、undo。
2. UI contract 測試：domain 入口、成功／取消／失敗狀態、無障礙 label、localized key。
3. iPad simulator build；在可用時補 M 系列真機驗收。
4. Mac 實機驗收：至少 1280×800 與窄視窗。
5. privacy scan：不含 signing material、帳號、絕對私人路徑與裝置識別資訊。

Phase 1 的 release gate：

- 同一張 RAW 在 Mac／iPad 的相同 adjustment patch，預覽與 full-resolution export 的像素差異在既有容差內。
- 每個新增 domain 都能完成「開啟 → 調整 → 預覽 → 取消或 commit → undo／redo → autosave → 重開」流程。
- 批次同步與匯出能提供成功、失敗、跳過的可辨識摘要。
- 真機測試未完成時，文件只能標記 `NOT RUN`，不得標記 `PASS`。

## 11. 實作順序

1. 先完成 Phase 1 的 shared coordinator、數值輸入、Geometry／Local overlay 與 batch sync。
2. 接著完成完整 Export request 與 report，補上 Mac／iPad parity 測試。
3. Phase 1 通過 build 與可用真機後，再開始 Phase 2 的鏡頭與色彩欄位 migration。
4. Phase 3、Phase 4 各自建立獨立 implementation plan，不在同一個巨大 SwiftUI view 中堆疊。

本文件通過審閱後，才建立對應 implementation plan 與逐項變更。
