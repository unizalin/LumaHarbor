# LumaHarbor 專業修圖完整化與跨裝置一致性規格

- 狀態：已核准，進入分階段實作
- 日期：2026-09-10
- 目標平台：macOS 14+、iPadOS 17+
- 目標裝置：Apple silicon Mac、M1 或更新的 iPad
- 驗證基準：`claude/ipad-curve-inspector-polish`，`1fb3641`
- 發布策略：可分階段開發與提交，所有階段驗收完成後才發布一個新版
- Issue 策略：只保存於專案文件，不建立 GitHub Epic 或 Issue
- 品質閘門：7/10；各 implementation plan 必須在寫程式前補齊該階段的演算法、fixture、狀態機與 evidence 格式

## 1. 背景與目標

LumaHarbor 已具備非破壞式 RAW 編輯、共用調整面板、Histogram、基礎曲線、Geometry、Linear Gradient、Spot Heal、Preset、批次同步及 Mac／iPad 編輯流程，但資料權威、跨平台 Inspector 架構及進階專業工具仍未完整。

本規格的目標是一次定義完整產品範圍，讓後續實作可拆成多份計畫與多個提交，同時維持同一組資料格式、渲染語意、undo、preset、batch、export 與驗收標準。任何平台差異只存在於版面與輸入方式，不得形成第二套功能或資料模型。

## 2. 使用者與完成結果

受影響者為在 Mac 或 M 系列 iPad 上管理、挑選及編修 RAW 的使用者，以及需要在兩台裝置間共用外接來源與 sidecar 的工作流。

完成後，使用者必須能：

1. 在刪除或重建 SQLite 索引後完整恢復 rating、flag、keywords、調整與快照。
2. 使用真正獨立的 Composite、Red、Green、Blue 曲線，而不是只有變色的共用曲線。
3. 在 Mac 與 iPad 使用相同功能集合，並獲得適合滑鼠／鍵盤或觸控／Apple Pencil 的版面。
4. 使用鏡頭校正、色彩分級、Presence、黑白混色、進階遮罩、裝置端主體選取、修復、透視、Snapshot、A／B 比較、色域警告與 Soft Proof。
5. 全程不修改 RAW，不上傳照片，不依賴付費雲端服務。

## 3. 已驗證現況

驗證日期：2026-09-10。

| 領域 | 目前狀態 | 已驗證證據 | 缺口 |
| --- | --- | --- | --- |
| Sidecar | `PhotoSidecar` schema v2 保存 adjustments 與 virtual-copy 關係 | `Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift:25` | 未保存 rating、flag、keywords、snapshot |
| Curation | rating／flag／keywords 由 SQLite API 更新 | `Sources/PhotoLibraryCore/Index/PhotoIndexStore.swift:624` | SQLite 被刪除後不可完整恢復 |
| 曲線 | `AdvancedToneCurve` 只有 `points` | `Sources/RawProcessingCore/Model/AdvancedToneCurve.swift:8` | UI 的 R／G／B 選項仍寫入同一條曲線 |
| 曲線 UI | 具備可拖曳圖與四個 channel 選項 | `Sources/AdjustmentUI/CurveAdjustmentPanel.swift:84` | channel 只有視覺差異，沒有獨立資料與渲染 |
| XMP | 支援 `ToneCurvePV2012` | `Sources/PresetCore/XMP/XMPImportExport.swift:190` | per-channel curves 目前只保留、不套用 |
| Histogram | 已有 RGB／Luminance 與 clipping 提示 | `Sources/AdjustmentUI/HistogramPanel.swift` | 尚未接色域警告與 Soft Proof 狀態 |
| Geometry | 已有 crop、rotate、flip、straighten、水平／垂直透視模型與 renderer | `Sources/RawProcessingCore/Model/GeometryAdjustments.swift:11` | 缺四角校正、網格、吸附與自動建議 |
| Local | 已有 Linear Gradient、Heal／Clone 及非破壞式 renderer | `Sources/RawProcessingCore/Model/LocalAdjustment.swift:15` | 缺 Brush、Radial、range mask、AI mask、opacity 與進階修復 |
| Inspector | Mac 使用 `InspectorView`；iPad 另有內嵌 host／rail | `Sources/LumaHarborApp/Views/InspectorView.swift:9`、`Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift:908` | Catalog、搜尋、收藏、smart follow 與 section state 尚未統一 |
| 發布 | Mac Build 2 已修正資源包與私人路徑問題 | `docs/coordination/CURRENT.md` | 新功能完成後仍需重新做乾淨機器、真機及隱私驗收 |

## 4. 不可回歸項目

1. RAW 原檔不可修改、搬移或刪除；所有驗收都要比對原檔 SHA-256。
2. Sidecar 持續使用原子寫入；寫入失敗不得顯示為已儲存。
3. SQLite、thumbnail、preview 與 AI 推論 cache 都是可重建資料，不得成為唯一權威來源。
4. 既有 v1／v2 sidecar、schema v1 preset 與舊 Composite 曲線必須可讀。
5. 既有 Geometry、Linear Gradient、Spot Heal、Preset、batch、undo／redo 及 export 行為不可被重寫成平台專屬版本。
6. UI resize、旋轉、Split View、Stage Manager、切換 Inspector 或預覽手勢不得寫 sidecar 或新增 undo。
7. 報告、ZIP、binary、log 與錯誤文案不得包含私人絕對路徑、帳號、Team ID、UDID、bookmark data 或簽章材料。

## 5. 範圍

### 5.1 本次包含

1. Portable curation：rating、flag、keywords 的 sidecar 權威與自動 migration。
2. 真正的 Composite／R／G／B 曲線，包含渲染、Preset、XMP、batch、undo 與 UI。
3. Mac／iPad 共用 Inspector catalog、section、搜尋、收藏、smart follow、pin 與 reset。
4. 自動及手動鏡頭校正：distortion、vignetting、lateral chromatic aberration。
5. Color Grading、Texture、Clarity、Dehaze、Black & White mixer、camera／creative profile。
6. Brush、Radial、Luminance Range、Color Range、Subject、Background 遮罩。
7. 裝置端 AI 主體／背景辨識；照片與遮罩不得送出裝置。
8. Heal／Clone 強化、Red-eye、四角透視、網格、吸附與水平線建議。
9. Snapshot、A／B 比較、clipping／gamut overlay、Soft Proof 與 privacy-safe 批次報告。
10. Mac 與 iPad 的自動化、視覺、真機、效能、資料耐久與發布驗收。

### 5.2 本次不包含

- 生成式填補、文字生圖或雲端 AI。
- 雲端同步、多人協作、帳號系統或伺服器後端。
- Tethered capture、影片編輯、多圖層合成、HDR merge、panorama merge。
- Windows、Android 或 Intel Mac 新增支援。
- Developer ID、notarization、Mac App Store 或 iPad App Store 上架。
- 付費 API、訂閱服務或執行時下載第三方模型。

## 6. 共用資料契約

### 6.1 Curation 權威

新增下列共用模型：

```swift
public struct PhotoCuration: Codable, Equatable, Sendable {
    public var rating: Int                 // 0...5
    public var flag: PhotoFlag             // none, pick, reject
    public var keywords: [PhotoKeyword]    // normalized 唯一，保留 displayValue
    public static let neutral: PhotoCuration
}
```

`PhotoSidecar.currentSchemaVersion` 提升至 3，新增 `curation` 與 `snapshots`。舊 sidecar 缺少欄位時解碼為 `.neutral` 與空陣列。

權威與 migration 規則：

1. v3 sidecar 永遠優先於 SQLite。
2. v1／v2 sidecar 沒有 curation，而 SQLite 有非中性資料時，先以 SQLite 資料建立 v3 sidecar，再更新 migration 狀態。
3. 沒有 sidecar但 SQLite 有 curation 時，建立 v3 sidecar；不得要求照片先被編輯。
4. 外接來源離線或唯讀時保留 SQLite 舊值並標記 migration pending，重新連線後重試。
5. 只有 sidecar 原子寫入成功後才能更新 SQLite 與畫面；SQLite 更新失敗時 sidecar 仍視為成功，下一次掃描重新投影。
6. index rebuild 必須從 sidecar 回填 curation、edit state、virtual copy 與 snapshot summary。
7. Virtual copy 延續現有規則，預設 0 rating、無 flag、空 keywords，但 adjustments 由來源複製。

### 6.2 Per-channel Tone Curve

保留既有 `points` 作為 Composite，新增三條 channel：

```swift
public struct AdvancedToneCurve: Codable, Equatable, Hashable, Sendable {
    public var points: [ToneCurvePoint]       // Composite，沿用既有 JSON key
    public var redPoints: [ToneCurvePoint]
    public var greenPoints: [ToneCurvePoint]
    public var bluePoints: [ToneCurvePoint]
}
```

缺少新 key 時三條 channel 為 identity。渲染順序固定為 Composite 後接 R／G／B channel。LUT 必須合成為一張 RGBA 1D texture，一次 kernel pass 完成三色映射並保留 extended-range highlights 與 alpha。

XMP 對應：

| LumaHarbor | Camera Raw property |
| --- | --- |
| Composite | `crs:ToneCurvePV2012` |
| Red | `crs:ToneCurvePV2012Red` |
| Green | `crs:ToneCurvePV2012Green` |
| Blue | `crs:ToneCurvePV2012Blue` |

Preset schema 提升至 v2。舊 preset 自動視為只有 Composite；新 preset、backup、copy／paste、field selection 及 batch sync 必須保留四條曲線。

### 6.3 新增全域調整

所有新欄位加入 `PhotoAdjustments`、`AdjustmentPatch`、stable field ID、Preset、batch policy、sidecar 與 export render request，並提供 neutral default。

| 模型 | 欄位與範圍 |
| --- | --- |
| `PresenceAdjustments` | texture `-100...100`、clarity `-100...100`、dehaze `-100...100` |
| `ColorGradingAdjustments` | shadows／midtones／highlights／global 的 hue `0...360`、saturation `0...100`、luminance `-100...100`，另含 balance `-100...100`、blending `0...100` |
| `MonochromeAdjustments` | enabled、八色 mix `-100...100`；停用時保留彩色調整 |
| `RenderingProfileSelection` | `profileID`、amount `0...100`、fallbackReason；只使用內建、版本化 profile |
| `LensCorrectionAdjustments` | mode、profileID、distortion／vignetting／TCA amount、manual fallback、enabled |

### 6.4 鏡頭 Profile 策略

校正來源依序為：

1. 使用者選擇 Off 時完全停用。
2. Automatic 模式優先使用 `CIRAWFilter.isLensCorrectionSupported` 與 vendor lens correction。
3. Core Image 不支援時，以相機 maker／model、鏡頭、crop factor、焦距及光圈匹配內建 Lensfun profile 資料。
4. 無可靠匹配時顯示「沒有相符 Profile」，改用手動 distortion、vignetting 與 TCA，不得猜測。

不得同時套用 Core Image vendor correction 與 Lensfun correction。Lensfun profile database 固定隨 App 發布，不在執行時連網更新；必須附 CC BY-SA 3.0 attribution、資料版本與更新腳本。不得直接納入 Lensfun LGPL library，第一版只解析必要的 XML profile 資料並由 LumaHarbor renderer 套用。

### 6.5 遮罩與裝置端 AI

`LocalAdjustmentKind` 擴充但保留既有 raw value：

```swift
public enum LocalAdjustmentKind: String, Codable, Sendable {
    case linearGradient, radialGradient, brush
    case luminanceRange, colorRange
    case subject, background
    case spotHeal
}
```

規則：

1. Linear、Radial、Brush、Luminance Range、Color Range 儲存 normalized geometry、stroke 與參數，不儲存畫布座標。
2. Subject／Background 使用 Apple Vision 在裝置端建立遮罩，不傳送照片、不呼叫網路、不記錄來源路徑。
3. AI 遮罩結果以 8-bit grayscale lossless mask 保存於 `.lumaharbor/masks/<photo-id>/<mask-id>.png`；sidecar 只保存相對路徑、source fingerprint、mask digest、Vision revision 與 inversion state。
4. 遮罩檔缺失或 digest 不符時顯示可重建狀態，必須由使用者確認後重新推論，不可靜默改變既有成像。
5. AI 推論失敗時保留目前 edits，並提供 Brush、Radial、Luminance Range 與 Color Range fallback。
6. 每個遮罩可命名、顯示／隱藏、反轉、複製、刪除、重新排序及調整 opacity／feather。

### 6.6 Snapshot 與比較

```swift
public struct EditSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var adjustments: PhotoAdjustments
    public var createdAt: Date
}
```

Snapshot 保存在 photo sidecar。建立、重新命名、複製、刪除與回復都可 undo；回復 Snapshot 是單一 compound undo。A／B 比較只改 session state，不改目前 adjustments 或寫 sidecar。

## 7. UI／UX 契約

### 7.1 共用 Inspector Catalog

`AdjustmentUI` 成為唯一的 domain／section／field catalog。Mac `InspectorView` 與 iPad `PadInspectorHost` 只負責容器與平台適配，不得各自維護第二份工具清單。

每個 section descriptor 至少包含：stable ID、標題 key、symbol、field IDs、搜尋 tokens、是否可收藏、reset 行為、適用平台與可用性診斷。

兩平台共同提供：

- 工具搜尋與清除搜尋。
- 收藏 section／field，收藏只存裝置本機 preferences。
- Smart Follow：使用者在 canvas 選取 crop、mask 或 heal item 時，自動切到對應 section。
- Pin：固定目前 section，暫停 Smart Follow。
- Section reset、domain reset、reset all，所有 destructive reset 都可 undo。
- 相同排序與名稱；平台可以採不同 rail、sheet、popover 或 dock。

### 7.2 Mac

- 支援 1280×800、一般視窗及窄視窗；Inspector 寬度維持 280...420 pt。
- 滑鼠 hover、右鍵、鍵盤 shortcut 與精確數值輸入完整可用。
- 曲線、遮罩、Heal、透視與 Snapshot 操作提供可撤銷的單次 transaction。

### 7.3 iPad

- 依實際 scene width 支援 Compact、Standard、Expanded、Wide，不用硬編碼裝置型號。
- 支援 11 吋與 13 吋 M 系列 iPad、橫直向、Split View、Stage Manager 與外接顯示器。
- 所有必要功能可用觸控完成；Apple Pencil 提供 Brush 壓力輸入，但沒有 Pencil 時功能不缺失。
- 觸控命中至少 44×44 pt；曲線點與遮罩 handle 視覺尺寸固定，縮放不得改變命中語意。
- 外接鍵盤與 pointer 是加速器，不是必要條件。

### 7.4 專業檢視

- Histogram 可切 Luminance、RGB overlay 及單色 channel。
- Highlight／Shadow clipping 與 gamut warning 可分別開關。
- Soft Proof 必須選擇輸出 profile；缺少 profile 時清楚停用並說明原因。
- Overlay、Soft Proof 與 A／B 比較只影響預覽，不得寫入輸出，除非 ExportRequest 明確選取對應色彩 profile。

## 8. 固定渲染順序

渲染順序在 preview 與 full-resolution export 必須一致：

1. RAW decode、orientation、vendor lens metadata。
2. Lens correction 或 manual fallback，兩者互斥。
3. White balance、exposure 與 Basic tone。
4. Composite／R／G／B curve。
5. Presence、HSL、Color Grading、Monochrome、Rendering Profile。
6. Noise reduction、sharpening。
7. Local masks 與局部調整，依 sidecar 順序合成。
8. Heal／Clone／Red-eye。
9. Perspective、rotate、flip、straighten、crop。
10. Vignette、grain。
11. Preview-only clipping／gamut／soft-proof transform。
12. Export resize、output profile、metadata、watermark 與 encoding。

任何順序變更都視為資料格式相容性變更，必須新增 golden image regression test。

## 9. 開發階段與依賴

```text
P0 基準整合與保護測試
 ├─> P1 Sidecar v3 + curation migration
 ├─> P2 Shared Inspector Catalog
 └─> P3 Per-channel curves
       ├─> P4 Lens + Presence + Color
       └─> P5 Mask + on-device AI + Repair + Perspective
P1 + P3 + P4 + P5 ─> P6 Snapshot + professional preview
P1...P6 ─> P7 Cross-device parity, performance, privacy and release
```

| Phase | 交付內容 | 前置 | 工程估算 |
| --- | --- | --- | --- |
| P0 | 合併 UI 基準、fixture、golden output、保護測試 | 無 | 2...3 日 |
| P1 | Sidecar v3、curation migration、rebuild、錯誤恢復 | P0 | 4...6 日 |
| P2 | Shared catalog、搜尋、收藏、smart follow、pin、移除 iPad 重複 host／rail | P0 | 5...7 日 |
| P3 | 四曲線 model、RGBA LUT、XMP、Preset、UI | P0 | 4...6 日 |
| P4 | Lens、Presence、Color Grading、B&W、Profile | P3 | 10...15 日 |
| P5 | Brush／Radial／Range／AI masks、Repair、四角透視 | P3 | 14...20 日 |
| P6 | Snapshot、A／B、clipping、gamut、Soft Proof | P1、P4、P5 | 7...10 日 |
| P7 | Mac／iPad parity、10k、RAW fixture、真機、隱私、文件、ZIP | 全部 | 6...9 日 |

總量約 52...76 個工程日。可以由多個 implementation plan 與多次提交完成，但不得略過依賴順序或提早發布部分完成版。

## 10. 效能預算

在 Apple silicon Mac 與 M1 iPad、24 MP RAW、最長邊 1600 px 的 warm preview fixture 上：

1. Slider／curve／mask 互動 preview p95 不超過 200 ms；舊 request 完成後不得覆蓋較新的 request。
2. Histogram 更新 p95 不超過 250 ms，切換照片或離開 editor 可取消。
3. 裝置端 subject／background mask 產生 p95 不超過 5 秒；進度可見且可取消。
4. 10,000 張照片的單頁 query、組合篩選與 keyword 搜尋 p95 不超過 250 ms。
5. 開啟包含 100 個 brush strokes 或 25 個 local adjustments 的照片，不得造成 UI 主執行緒超過 500 ms 無回應。
6. 新功能全部 neutral 時，preview 與 export 相較基準的處理時間退化不得超過 5%。

## 11. 驗收條件

### 11.1 資料與相容性

1. v1／v2 sidecar 在新版本開啟後 adjustments 與結果不變。
2. 舊 `AdvancedToneCurve(points:)` 解碼後只設定 Composite，RGB 三條為 identity。
3. 舊 preset／backup 可匯入，新格式可完整 round-trip 四曲線與新增調整。
4. 在備份 SQLite、刪除 index、重新掃描後，100% 恢復 rating、flag、keywords、adjustments、virtual copies 與 snapshots。
5. Migration 遇到離線、唯讀、空間不足或中途取消時不遺失 SQLite 舊值；重新連線可續跑。
6. RAW、sidecar 既有未知欄位與第三方 XMP preserved properties 不被靜默刪除。

### 11.2 功能

7. Composite／R／G／B 任一曲線只改變對應 channel，reset 可分 channel 或全部執行。
8. Preview、Preset、batch sync、undo／redo、autosave、重開與 full export 對四曲線結果一致。
9. Lens automatic、bundled profile、manual fallback 與 off 四種模式可辨識且不重複套用。
10. 每個新 global adjustment 具備 neutral、精確輸入、reset、undo、Preset、batch 與 export 行為。
11. 每種 mask 可新增、編輯、反轉、複製、排序、停用、刪除及重開恢復。
12. Subject／Background mask 在斷網環境可完成；網路封包監測不得出現照片或推論請求。
13. AI mask 失敗、取消或資源缺失時不修改目前 adjustments，且提供手動 fallback。
14. Heal／Clone 在 100% 與 400% zoom 命中位置一致；Red-eye 無有效區域時不可提交空操作。
15. 四角透視與 local mask 在 rotate／crop 前後不漂移超過 1 preview pixel。
16. Snapshot 回復建立一筆 compound undo；A／B 切換不寫 sidecar。
17. Clipping、gamut 與 Soft Proof 僅影響預覽；一般 export 不含 overlay。

### 11.3 跨裝置與 UI

18. Mac 與 iPad 顯示相同 domain、section、field、Preset 與可用性診斷。
19. iPad 不再內嵌第二份工具 catalog；新增 field 時只需在共用 catalog 宣告一次。
20. 搜尋、收藏、smart follow、pin、section reset 與 domain reset 在兩平台可用。
21. iPad 11／13 吋橫直向、Split View、Stage Manager 及外接顯示器沒有文字截斷、控制重疊或不可達內容。
22. VoiceOver 可讀出 field 名稱、值、單位、狀態與 reset；Dynamic Type 最大級不遮蔽主要操作。
23. Touch、Pencil、pointer 與鍵盤不產生重複 commit；一次連續手勢只建立一筆 undo。

### 11.4 渲染、隱私與發布

24. 同一 fixture、相同 patch 的 Mac／iPad 輸出，在統一 color space 後平均每 channel 誤差不超過 `0.5/255`，p99 不超過 `2/255`。
25. 所有真實 RAW 驗收前後 SHA-256 完全一致。
26. 完整 `swift test`、strict-concurrency release build、iPad simulator build、Mac bundle contract 與 privacy scan 全部 PASS，執行測試數不得為 0。
27. M 系列 iPad 真機與 Apple silicon Mac 人工驗收不得存在 `NOT RUN`。
28. 發布 ZIP 必須包含所有 SwiftPM resource bundle、Lensfun attribution、profile database、mask migration support，並在另一個乾淨帳號環境啟動及開啟 RAW。
29. App、ZIP、checksum、binary strings、診斷報告及 Git 歷史掃描不得包含私人絕對路徑、帳號、Team ID、UDID 或憑證。
30. 全部條件通過後才能更新版本、README 中文使用方式、CHANGELOG 與發布 ZIP；不得以單一 Phase PASS 宣稱完成。

## 12. 測試計畫

| 層級 | 範圍 | 最低新增數 |
| --- | --- | ---: |
| Model unit | Codable、clamp、neutral、migration、curve channels、mask geometry、snapshot | 45 |
| Render unit | LUT、lens、presence、color、mask、heal、perspective、golden pixels | 40 |
| Repository integration | sidecar atomic write、SQLite projection、rebuild、offline resume、mask assets | 25 |
| Preset／XMP | schema v1→v2、四曲線、unknown preserve、new fields、backup | 25 |
| Editor integration | undo、autosave、batch、cancel、stale request、snapshot | 25 |
| UI contract | shared catalog、兩平台入口、localization、accessibility、adaptive layout | 30 |
| End-to-end | 開啟→編輯→儲存→重開→匯出、index rebuild、跨裝置 SSD | 12 |
| 真機人工 | Mac、iPad、APFS、exFAT、Files provider、Pencil、Stage Manager | 1 份完整報告 |

所有新增使用者文字加入現有八語資源；中文與英文必須人工檢查，其餘語言至少通過 key parity 與 fallback gate。

## 13. 錯誤與復原

| 情境 | 必要行為 |
| --- | --- |
| Sidecar 不可寫 | 不更新 SQLite／畫面，保留舊資料，顯示發生原因與下一步 |
| SQLite 更新失敗 | Sidecar 視為已保存；標記待重建 projection，不回滾已成功的 sidecar |
| 新版 sidecar | 拒絕覆寫，顯示版本不支援 |
| Lens profile 無匹配 | 不猜測，自動切 manual fallback，保留 metadata |
| AI 不支援／失敗 | 保留 edits，顯示錯誤，提供手動 mask |
| AI mask asset 損毀 | 隔離損毀檔，保留 sidecar，要求確認後重建 |
| Render 取消 | 舊結果不得上畫面，不寫 sidecar，不建立 undo |
| 外接來源拔除 | 保留 session 與 pending save 狀態，重新連線後由使用者決定重試 |
| 磁碟空間不足 | 原子寫入不得留下半份 sidecar、mask 或 export |

## 14. Rollback

1. 每個 Phase 使用獨立提交與 migration feature flag；發布前可逐 Phase revert。
2. Sidecar v3 migration 在成功寫入前保留原 v1／v2 bytes 與 SQLite curation；migration 不刪除舊資料。
3. 新增模型全部有 neutral default，停用 renderer 時可退回既有畫面結果。
4. Mask asset 採 content digest 與相對路徑；回滾不刪除資產，由後續清理器只移除無 sidecar reference 的 orphan。
5. Lensfun database 可由單一 resource commit 回退，profile ID 必須包含資料版本，舊 sidecar 無匹配時安全退回 manual。
6. 發布後若發現阻斷性資料問題，停止散布 ZIP、保留 RAW／sidecar、發布只讀修復版；不得以降版 App 覆寫較新的 sidecar。

## 15. 主要檔案

| 路徑 | 預期變更 |
| --- | --- |
| `Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift` | schema v3、curation、snapshots |
| `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift` | sidecar-first mutation、migration、rebuild |
| `Sources/PhotoLibraryCore/Index/PhotoIndexStore.swift` | projection、migration state、10k query |
| `Sources/RawProcessingCore/Model/AdvancedToneCurve.swift` | Composite／R／G／B curves |
| `Sources/RawProcessingCore/Model/PhotoAdjustments.swift` | 新 global、lens、profile、snapshot-compatible fields |
| `Sources/RawProcessingCore/Model/LocalAdjustment.swift` | mask kinds、brush／range／AI references、repair parameters |
| `Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift` | 固定 render order、新 renderer 接線 |
| `Sources/RawProcessingCore/Pipeline/GeometryRenderer.swift` | 四角透視、座標一致性 |
| `Sources/RawProcessingCore/Pipeline/LocalAdjustmentRenderer.swift` | 新 masks、opacity、repair |
| `Sources/RawProcessingCore/Kernels/AdjustmentKernels.metal` | RGBA curve、presence、color、mask、lens kernels |
| `Sources/PresetCore/Model/*` | schema v2、field IDs、patch、backup |
| `Sources/PresetCore/XMP/*` | per-channel curves、新欄位 mapping／preservation |
| `Sources/AdjustmentUI/*` | shared catalog、共用 panel、搜尋／收藏／pin |
| `Sources/LumaHarborApp/Views/InspectorView.swift` | Mac adaptive host |
| `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift` | 移除重複 catalog／host，接 iPad container |
| `Scripts/run-mvp-acceptance.zsh` | 新資料、渲染、真機與隱私 gate |
| `Scripts/package-mac-release.sh` | profile／license／resource／binary privacy 驗證 |
| `docs/testing/*` | 分階段報告與最終跨裝置驗收 |

## 16. Implementation Plan 文件

核准本規格後，依序建立下列計畫，不建立 GitHub Issue：

1. `2026-09-10-curation-sidecar-v3-and-migration.md`
2. `2026-09-10-shared-professional-inspector-catalog.md`
3. `2026-09-10-per-channel-tone-curves.md`
4. `2026-09-10-lens-presence-and-color-grading.md`
5. `2026-09-10-advanced-masks-ai-repair-and-perspective.md`
6. `2026-09-10-snapshots-soft-proof-and-professional-preview.md`
7. `2026-09-10-cross-device-final-verification-and-release.md`

每份 plan 必須列出逐檔變更、測試先行順序、提交邊界、回滾點及 handoff 格式。P7 完成前不得建立對外發布版本。

## 17. 外部技術依據

- Apple Vision `VNGenerateForegroundInstanceMaskRequest`：裝置端產生前景 instance mask。
- Apple Core Image `CIRAWFilter.isLensCorrectionSupported`：判斷 RAW 是否可使用系統鏡頭校正。
- Lensfun：離線鏡頭資料庫；database 採 CC BY-SA 3.0，程式庫採 LGPL-3.0。本案只使用並標示 database，不直接納入程式庫。

## 18. Definition of Done

1. P0 到 P7 的程式、測試、文件與驗收全部完成。
2. 所有 30 條驗收條件均有 committed evidence，沒有模糊的「應可運作」。
3. 完整自動化為 PASS；所有必要真機項目為 PASS，而非 SKIPPED 或 NOT RUN。
4. Mac 與 iPad 功能集合一致，版面依平台輸入方式適配。
5. 舊資料自動升級且可回復，SQLite 重建不遺失使用者資料。
6. RAW hash 不變，照片不離開裝置，無付費或雲端依賴。
7. 隱私掃描涵蓋 source、Git history、App bundle、binary、ZIP、checksum 與報告。
8. README 中文版、使用方式、其他電腦安裝方式、版本與發布檔同步更新。
