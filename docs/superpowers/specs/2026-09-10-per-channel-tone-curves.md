# P3：Per-channel Tone Curves 實作規格

- 狀態：核准，進入實作
- 日期：2026-09-10
- 依據：`docs/superpowers/specs/2026-09-10-professional-editing-completion-design.md` §6.2、§8（步驟 4）、§9、§11.1（第 2、3 條）、§11.2（第 7、8 條）
- 前置：P0（已完成）。不依賴 P1／P2，可平行，但本輪在 P2 之後才開工（依 branch 實際歷史順序）。
- 範圍鎖定：只做 Composite／Red／Green／Blue 四條獨立曲線的 model、渲染（RGBA LUT／Metal）、undo、Preset／XMP、batch、Mac/iPad UI。不做 Lens/Presence/Color Grading（P4）、Mask/Repair/Perspective（P5）、Snapshot/Soft Proof（P6）。

## 1. 問題與現況缺口

驗證時間：2026-09-10，對照 HEAD `37db11d163fd2fe90b974dbc50ae9476fc3ee9e9`。

1. `AdvancedToneCurve`（`Sources/RawProcessingCore/Model/AdvancedToneCurve.swift:8`）只有一個 `points` 陣列。`Sources/AdjustmentUI/CurveAdjustmentPanel.swift:10` 的 `ToneCurveChannel`（`.rgb/.red/.green/.blue`）只是 UI 顯示用的分段選擇器 tag；不論選哪個 channel，拖曳都寫回同一個 `points`，四個 channel 顯示的是同一條曲線只是描邊顏色不同。這是一個真實功能缺口：使用者無法獨立編輯紅／綠／藍曲線。
2. Metal kernel `advancedToneCurve`（`Sources/RawProcessingCore/Kernels/AdjustmentKernels.metal:51`）只接受單通道（灰階，存在 RGBA8 紋理的 `.r`）LUT，對 R/G/B 三個輸入通道各自用同一張表查表（等同於「只調整整體 tone，不調整顏色」）。
3. XMP 只匯入／匯出 `crs:ToneCurvePV2012`（composite）。`crs:ToneCurvePV2012Red/Green/Blue` 目前完全未被辨識，會落入「preserved / unmapped property」，使用者從 Lightroom 匯入含 per-channel curve 的 preset 時會靜默遺失資料（不會報錯，但也不會套用）。
4. `PresetDocument.currentSchemaVersion`（`Sources/PresetCore/Model/PresetDocument.swift:45`）仍是 `1`。

## 2. 決策：資料模型與相容性

### 2.1 `AdvancedToneCurve`

```swift
public struct AdvancedToneCurve: Codable, Equatable, Hashable, Sendable {
    public var points: [ToneCurvePoint]       // Composite，既有 JSON key "points" 不變
    public var redPoints: [ToneCurvePoint]    // 新 JSON key "redPoints"
    public var greenPoints: [ToneCurvePoint]  // 新 JSON key "greenPoints"
    public var bluePoints: [ToneCurvePoint]   // 新 JSON key "bluePoints"

    public static let neutral: AdvancedToneCurve   // 四條皆空
    public var isIdentity: Bool                    // 四條皆空
}

public enum ToneCurveChannel: String, CaseIterable, Codable, Sendable {
    case composite, red, green, blue
}

extension AdvancedToneCurve {
    public func points(for channel: ToneCurveChannel) -> [ToneCurvePoint]
    public func isIdentity(for channel: ToneCurveChannel) -> Bool
    public func settingPoints(_ points: [ToneCurvePoint], for channel: ToneCurveChannel) -> AdvancedToneCurve
    public func resetting(_ channel: ToneCurveChannel) -> AdvancedToneCurve   // settingPoints([], for: channel)
}
```

`ToneCurveChannel` 移到 `RawProcessingCore`（模型層），因為 XMP 匯入／匯出與 Metal LUT 合成都需要它，而這兩者都不能依賴 `AdjustmentUI`（依賴方向錯誤）。`Sources/AdjustmentUI/CurveAdjustmentPanel.swift` 既有的私有 `ToneCurveChannel`（`.rgb/.red/.green/.blue`）刪除，UI 改用 `RawProcessingCore.ToneCurveChannel`；`.rgb` 案例改名為 `.composite`，UI 標籤沿用既有已翻譯的 "RGB" 文案（第一枚 segmented tab 仍顯示 "RGB"，因為使用者習慣上 composite curve 就叫 RGB curve，不需要新增或替換既有 8 語 key）。

### 2.2 相容性

- 舊 sidecar／preset 的 JSON 只有 `points` key：`redPoints/greenPoints/bluePoints` 解碼為 `[]`（identity）。既有 `AdvancedToneCurveTests.testMissingKeyFallsBackToNeutral` 模式延伸到三個新 key。
- `sanitise` 的 clamp／不排序保證比照既有 `points` 邏輯,分別施加於四個陣列。
- `PresetDocument.currentSchemaVersion` 由 `1` 升為 `2`。`validated()` 既有的 `schemaVersion >= 1 && schemaVersion <= currentSchemaVersion` 邏輯不變 — v1 preset 仍可驗證與匯入，因為新 key 缺席時 `AdvancedToneCurve` 解碼自然退化為只有 Composite。新增回歸測試：`schemaVersion == 1` 的既有 `.lhpreset` fixture 匯入後三個新 channel 為 identity，且不拋出 `unsupportedSchemaVersion`。

## 3. 渲染：RGBA 1D LUT，單一 kernel pass

固定順序（design 規格 §8 步驟 4）：Composite 先套用，再套用對應 channel（R 通道先過 Composite 曲線，再過 Red 曲線；G/B 同理）。

### 3.1 `AdvancedToneCurveLUT`

新增：

```swift
public static func buildCombined(
    compositePoints: [ToneCurvePoint],
    channelPoints: [ToneCurvePoint],
    resolution: Int = 256
) -> [Float]
```

實作：分別呼叫既有 `build(from:resolution:)` 取得 `compositeTable`／`channelTable`（兩者皆已 clamp 到 0...1 且非遞減），再以 `compositeTable[i]` 的值當作索引查 `channelTable`（四捨五入到最近整數索引，clamp 到 `0...resolution-1`)。

正確性理由：
- `channelPoints` 為空 ⇒ `channelTable` 是 identity（`table[i] == i/(resolution-1)`），故 `buildCombined[i] == compositeTable[i]`，等同純 Composite。
- `compositePoints` 為空 ⇒ `compositeTable[i] == i/(resolution-1)`，四捨五入後索引仍是 `i`，故 `buildCombined[i] == channelTable[i]`，等同純 Channel。
- 兩個輸入皆為非遞減函式，合成後仍非遞減（不需要再跑一次 `enforceMonotonicNonDecreasing`，但用兩個已經 monotonic 的離散表做合成，理論上可能因四捨五入在極少數樣本出現局部持平但不會反轉——新增測試驗證整條合成表仍非遞減）。

新增測試（`Tests/RawProcessingCoreTests/AdvancedToneCurveLUTTests.swift`）：
- `testBuildCombinedWithEmptyChannelEqualsCompositeAlone`
- `testBuildCombinedWithEmptyCompositeEqualsChannelAlone`
- `testBuildCombinedComposesBothCurves`（已知控制點算出已知中間值）
- `testBuildCombinedIsMonotonicNonDecreasing`
- `testBuildCombinedClampedToZeroOne`

### 3.2 Metal kernel

`Sources/RawProcessingCore/Kernels/AdjustmentKernels.metal` 的 `advancedToneCurve` 簽名不變（`sampler image, sampler lut, float lutWidth`），但 `lut` 現在是一張 RGBA8 紋理，R/G/B 三個 texel 分量各自儲存已合成好的 Red／Green／Blue channel 表：

```metal
float r = lut.sample(lut.transform(float2(rIn * lastIndex + 0.5, lutSize.y * 0.5))).r + (pixel.r - rIn);
float g = lut.sample(lut.transform(float2(gIn * lastIndex + 0.5, lutSize.y * 0.5))).g + (pixel.g - gIn);
float b = lut.sample(lut.transform(float2(bIn * lastIndex + 0.5, lutSize.y * 0.5))).b + (pixel.b - bIn);
```

（原本三個 sample 都讀 `.r`；改成各自讀 `.r/.g/.b`。extended-range highlight 的 `+ (pixel.c - cIn)` 補償邏輯與 alpha passthrough 不變。）這是唯一一次 kernel pass，三個顏色通道各查一次同一張紋理的不同分量,滿足規格「一次 kernel pass 完成三色映射」。

### 3.3 `AdjustmentPipeline.applyAdvancedToneCurve`

```swift
private static func applyAdvancedToneCurve(_ curve: AdvancedToneCurve, to image: CIImage) -> CIImage {
    guard let kernel = advancedToneCurveKernel else { return image }
    let redTable = AdvancedToneCurveLUT.buildCombined(compositePoints: curve.points, channelPoints: curve.redPoints)
    let greenTable = AdvancedToneCurveLUT.buildCombined(compositePoints: curve.points, channelPoints: curve.greenPoints)
    let blueTable = AdvancedToneCurveLUT.buildCombined(compositePoints: curve.points, channelPoints: curve.bluePoints)
    guard let lutImage = Self.makeLUTImage(red: redTable, green: greenTable, blue: blueTable) else { return image }
    ...
}
```

`makeLUTImage` 改參數為三個 `[Float]`（`red/green/blue`），封包進同一張 RGBA8 `CIImage`（A 固定 255）。呼叫端 `isAdvancedToneCurveIdentity` gate 不變（四條曲線皆 identity 時完全跳過，維持既有 5% 效能退化預算）。

Golden-pixel 迴歸測試（`AdjustmentPipelineTests`）新增：
- 只設 `redPoints`（Composite 空）：輸出只有紅通道改變，G/B 不變（與純 composite 基準比對像素）。
- Composite ≠ identity 且 `bluePoints` ≠ identity：輸出等於「先套 composite 再套 blue」的手算像素（用小張 1×1 或 4×4 合成圖跑 `AdjustmentPipeline`，避開真實 RAW 檔案依賴，比照既有 `AdjustmentPipelineTests` 手法）。
- 四條皆 identity：輸出與跳過 kernel 路徑（`isAdvancedToneCurveIdentity == true`）逐 pixel 相同（確認 gate 不變色）。

## 4. XMP 與 Preset

### 4.1 XMP 映射

| LumaHarbor channel | Camera Raw property |
| --- | --- |
| Composite | `crs:ToneCurvePV2012` |
| Red | `crs:ToneCurvePV2012Red` |
| Green | `crs:ToneCurvePV2012Green` |
| Blue | `crs:ToneCurvePV2012Blue` |

`XMPImporter.preview`：四個 property ID 各自嘗試解析為 `[ToneCurvePoint]`（沿用既有 `importToneCurve` 的 0...255→0...1 換算與錯誤處理),並用 `AdvancedToneCurve.settingPoints(_:for:)` 疊加到 `AdjustmentPatchBuilder.advancedToneCurve`（初值 `.neutral`）。`nativeFields.append(.advancedToneCurve)` 只在該 field 尚未加入時才 append（避免四次重複）。任一 channel 解析失敗時該 channel 維持 identity、記一筆 `malformedToneCurve` diagnostic 並把該 property 放進 `preservedProperties`，不影響其他三個 channel（獨立失敗、獨立保留，比照現有單一 composite 的錯誤處理原則）。

`XMPExporter.export`：Composite 的匯出行為完全不變（只要 `patch.advancedToneCurve != nil` 就輸出 `ToneCurvePV2012`，即使是空陣列 —— 與既有測試 `testExportOfXMPImportedPresetRoundTripsAllMappedCategories` 相容）。新增：Red/Green/Blue 各自「非 identity 才輸出」（避免對純 composite-only 的既有 preset 塞入空的 Red/Green/Blue property，維持既有 fixture 的 byte-level 期待不受影響）。

### 4.2 Preset schema v2

`PresetDocument.currentSchemaVersion = 2`。新建立的 preset（copy/paste、CreatePresetSheet、batch apply）一律標記 v2；v1 既有 `.lhpreset` 檔匯入、驗證、套用行為不變（`redPoints/greenPoints/bluePoints` 解碼為空)。

## 5. Mac / iPad UI

`Sources/AdjustmentUI/CurveAdjustmentPanel.swift`：

1. `ToneCurveEditorModel.points(for:channel:)` 改吃 `(AdvancedToneCurve, ToneCurveChannel)`，回傳 `curve.points(for: channel)`（少於 2 點時回退到 `ToneCurveMapping.identity`，與既有邏輯相同，只是逐 channel 判斷)。
2. `CurveAdjustmentPanel.body` 的 `onChange` 寫入改成 `editor.updateAdjustments { $0.advancedToneCurve = $0.advancedToneCurve.settingPoints(points, for: selectedChannel) }`（只改當前選取的 channel，不再整條覆寫)。
3. 既有單一 "Reset" 按鈕拆成兩顆，滿足規格 §11.2 第 7 條「reset 可分 channel 或全部執行」：
   - "Reset Channel"（新 L10n key）：`editor.updateAdjustments { $0.advancedToneCurve = $0.advancedToneCurve.resetting(selectedChannel) }`，`disabled` 條件為 `editor.adjustments.advancedToneCurve.isIdentity(for: selectedChannel)`。
   - "Reset All"（新 L10n key）：維持既有 `$0.advancedToneCurve = .neutral`，`disabled` 條件為整體 `isIdentity`。
4. `statusText` 改用 `curve.points(for: selectedChannel).count` 與 `curve.isIdentity(for: selectedChannel)`，逐 channel 顯示控制點數與「未套用」狀態。
5. Graph 顏色（`channelColor`）沿用既有 switch，只把 `.rgb` 改成 `.composite`。

兩顆新按鈕與既有單一 undo-per-gesture 規則一致：reset 呼叫 `updateAdjustments`（既有的單次 undo 路徑，與 P2 的 section/domain reset 相同模式),不新增第二套 undo 機制。

iPad：`CurveAdjustmentPanel` 是 `AdjustmentUI` 的共用元件,Mac 與 iPad 皆透過既有掛載點（Mac `InspectorView` 的 `.curve` DisclosureGroup；iPad `PadInspectorHost` 的 `.light` submode，依 P2 catalog 表 `curve` section）引用同一個 View，不需要在 `PadEditorView.swift`/`PadInspectorHost.swift` 額外接線 — P2 已把 curve section 收斂成單一掛載點。

## 6. 測試計畫（最低新增數）

| 層級 | 檔案 | 內容 |
| --- | --- | --- |
| Model unit | `AdvancedToneCurveTests.swift` | 四 channel neutral／非 identity／JSON round-trip／缺 key 退化／`resetting`／`settingPoints`／`points(for:)` |
| Render unit | `AdvancedToneCurveLUTTests.swift` | `buildCombined` 五個案例（§3.1） |
| Render unit | `AdjustmentPipelineTests.swift` | 三個 golden-pixel 案例（§3.3） |
| Preset/XMP | `XMPMappingTests.swift`／`XMPImportExportTests.swift` | Red/Green/Blue import／export／round-trip／malformed-channel-is-isolated／v1 preset 無新 key 仍匯入 |
| Preset | `AdjustmentPatchTests.swift`／`AdjustmentPatchExtractionTests.swift` | `advancedToneCurve` 全值仍是單一 whole-value leaf，四 channel 隨 copy/paste／batch 整體搬移 |
| Preset | 新增 `PresetDocumentSchemaVersionTests.swift`（或併入既有檔）| `currentSchemaVersion == 2`；v1 preset 驗證通過；新建 preset 預設為 2 |
| UI contract | `ToneCurveEditorModelTests.swift` | 逐 channel `points(for:)`／`movingPoint`／`nearestPointIndex` 不互相污染 |
| UI contract | `AdjustmentGroupPanelsContractTests.swift`（或新檔） | Reset Channel／Reset All 兩顆按鈕存在、disabled 條件、L10n key 存在於 8 語 |

最低新增測試數：Model 8、Render 8、Preset/XMP 10、UI 6，共 32+，對齊 design 規格 §12 的比例（新規格範圍較小,不要求整體 45/40/25 全部落在本 phase）。

## 7. 驗收條件（對應 design 規格 §11.1 第 2、3 條、§11.2 第 7、8 條）

1. 舊 `AdvancedToneCurve(points:)`（只有一個 key）解碼後只設定 Composite，RGB 三條為 identity 且能通過 XMP／sidecar round-trip。
2. Composite／R／G／B 任一曲線只改變對應 channel 的渲染輸出（golden pixel 驗證），reset 可分 channel 或全部執行。
3. Preview、Preset、batch sync、undo/redo、autosave、重開與 full export 對四曲線結果一致（沿用既有 `advancedToneCurve` 作為單一 whole-value field 的既有基礎設施,不需要新的 batch/undo 程式碼）。
4. `swift test`、`swift build -Xswiftc -strict-concurrency=complete`、iPad Simulator `xcodebuild` 全部 PASS，執行測試數不得為 0，且相較 P2 基準（2039 executed）淨增至少 32。
5. 8 語 `Localizable.strings` 新增 "Reset Channel"／"Reset All" 兩個 key,zh-Hant 與 en 人工撰寫,其餘 6 語為真實翻譯（沿用 P2 的 `LocalizationKeyParityContractTests` gate)。
6. 隱私掃描（git diff + 新檔案）不含私人絕對路徑、Team ID、UUID 帳號等。

## 8. Rollback

- 單一提交邊界：P3 實作為一個 commit（比照 P0/P1/P2 慣例）。回退此 commit 即完整回到 P2 basline，因為 `AdvancedToneCurve` 新欄位皆有 `[]` neutral default,不影響 P1（curation)／P2（catalog）resource。
- `PresetDocument.currentSchemaVersion` 回退到 1 不會使任何已存在的 v2 preset 失效（`validated()` 的檢查方向是「檔案版本 ≤ app 支援版本」,降版 app 讀到 v2 檔案會被 `unsupportedSchemaVersion` 明確拒絕,不會靜默裁切 Red/Green/Blue 資料 — 這是既有 guard 的既有行為,不需新程式碼)。

## 9. Handoff

完成後於 `docs/coordination/2026-09-10-p3-per-channel-tone-curves-handoff.md` 記錄逐檔變更、測試證據（PASS/FAIL/SKIPPED/NOT RUN）、golden-pixel 驗證方法與下一步（P4 起始點）。
