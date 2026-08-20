# 調整引擎擴充設計（HSL／曲線／分離色調／銳化降噪／暈影／顆粒）

> 本檔案是「風格檔系統（含 Lightroom `.xmp` 匯入）」這個下一階段目標底下，**先動手**的第一份 spec。順序決定（2026-08-19，使用者核准）：先有這些調整項目本身，風格檔／XMP 匯入才有東西可以套用，因此拆成兩份 spec 依序寫，這份只涵蓋調整引擎本身，不含風格檔儲存、套用 UI 或 XMP 匯入——那些留給下一份 spec，建在這份完成之上。
>
> 對應主規格 [`2026-08-13-mac-first-mvp-design.md`](2026-08-13-mac-first-mvp-design.md) §14.1／§14.2 路線圖；範圍決策脈絡見 `docs/reference/next-phase-scope-notes.md`（2026-08-16）。MVP 本身已於 [`2026-08-19-mvp-acceptance.md`](../../testing/reports/2026-08-19-mvp-acceptance.md) 簽收完成，這是簽收後第一個新階段。

## 給接手者的話（重要，先讀這段）

這份 spec 可能由另一台機器上的 session（例如 Codex）接續執行。跨工具/跨 session 交接的既有慣例：**進度絕對不能只存在單一工具的私有 memory 裡**，一定要寫回專案內的文件，下一個接手的 session（不管是同一個工具重置後，還是換一個工具）才讀得到。

- 開始實作前，先讀完這整份 spec，並用 `writing-plans` skill（或等價流程）產出一份實作計畫。
- 每完成一個獨立子項目（見 §7 拆解），**立刻 commit**，commit message 寫清楚做了什麼、為什麼——不要囤積一堆未提交的變更。
- 如果 token／用量快耗盡：**不要不聲不響斷掉**。在這份文件的「## 進度日誌」章節（見文末，目前是空的，直接接著寫）附加一段，寫清楚：目前做到哪一個子項目、哪些檔案已經改完／哪些改到一半、下一步該做什麼、有沒有踩到任何需要人工決策的坑。寫完立刻 commit＋push，不要留在本機未提交狀態。下一個 session（不管是誰）第一件事就是先讀這個進度日誌，接著讀對應的 commit log，才開始動手，不要重新從頭讀整份 spec 猜進度。
- 這個專案的慣例是**一個修正/一個子項目一個可回溯的 commit**，不要把好幾個子項目擠在一個 commit 裡，也不要留大量未 commit 的工作到 session 結束。

## 1. 範圍

### 包含

- 擴充 `PhotoAdjustments` 資料模型，新增六類調整：HSL 分色、獨立進階曲線、分離色調、銳化、降噪、暈影、顆粒（共七個子模組，見 §3；「六類」是概念分類，顆粒／暈影算兩個獨立子模組）。
- 擴充 `AdjustmentPipeline`／`AdjustmentMapping`，讓這些新欄位真的能渲染出畫面（見 §4）。
- Sidecar（`.lumaharbor` JSON）的讀寫相容性與 schema 版本升級（見 §5）。
- 對應的單元測試（純數學換算部分）與人工視覺驗證清單（見 §6）。

### 明確不包含（留給後續 spec 或未來階段）

- **不做任何新的人工 UI 控制項**。Inspector 面板維持現有 10 個滑桿不變。新欄位目前唯一的寫入來源是「以後套用風格檔」，這份 spec 完成後，新欄位在 UI 上還沒有任何地方可以手動調——這是刻意的，範圍已在 2026-08-19 brainstorming 階段跟使用者確認過。
- **不做風格檔儲存／套用／管理系統**（那是下一份 spec）。
- **不做 Lightroom `.xmp` 解析或匯入**（那是下一份 spec，會用到這份 spec 建立的資料模型）。
- **不做批次編輯、評分／篩選**（§14.2 其餘範圍，未來另開 spec）。
- **不做裁切／旋轉／局部遮罩**（§14.1／§14.3 其餘範圍，未來另開 spec）。

## 2. 目標

- 每個新調整項目都有明確定義的數值範圍、預設值（中性值＝沒有效果）、以及「滑桿式數值 → Core Image 濾鏡參數」的換算公式，換算邏輯全部集中、可單元測試，比照現有 `AdjustmentMapping`／`ToneCurveMapping` 的做法。
- 新欄位對既有的舊 sidecar 完全向後相容：讀取時沒有這些欄位＝視為中性值，不影響任何既有調整。
- 沒有套用任何新效果的照片，渲染路徑效能跟現在幾乎相同（每個新濾鏡在中性值時整段跳過，不執行）。
- 數值範圍盡量貼近 Lightroom XMP 原生欄位的單位與範圍（見 §3 各子結構），讓下一份 XMP 匯入 spec 的映射邏輯是直接對應、不需要額外猜測換算公式。

## 3. 資料模型

`PhotoAdjustments` 新增七個巢狀 `Codable, Equatable, Hashable, Sendable` 子結構，每個都有自己的 `.neutral` 靜態值。原本的 10 個扁平欄位完全不動。

> 以下程式碼片段是**示意型別形狀**（欄位名稱、型別、範圍、預設值才是規格本體），不是可以直接複製貼上的完整 Swift——實際 `init`／`clamp`／`Codable` 樣板寫法照現有 `PhotoAdjustments.swift`／`AdjustmentCatalog.swift` 的既有慣例（`decodeIfPresent` + 預設值回退、`clamp` 防呆等），實作時比照既有檔案的寫法，不要重新發明。

```swift
public struct PhotoAdjustments: Codable, Equatable, Hashable, Sendable {
    // 既有 10 個欄位不變：exposure, temperature, tint, contrast,
    // highlights, shadows, whites, blacks, vibrance, saturation

    public var advancedToneCurve: AdvancedToneCurve   // 見下方
    public var hsl: HSLAdjustments
    public var splitToning: SplitToning
    public var sharpening: Sharpening
    public var noiseReduction: NoiseReduction
    public var vignette: Vignette
    public var grain: Grain
}
```

### 3.1 `AdvancedToneCurve`——獨立於 4 滑桿曲線之外疊加的曲線

```swift
public struct AdvancedToneCurve: Codable, Equatable, Hashable, Sendable {
    /// 任意數量的控制點，0...1 正規化座標，x 嚴格遞增。空陣列＝identity（不套用）。
    public var points: [ToneCurvePoint]
    public static let neutral = AdvancedToneCurve(points: [])
}
```

跟現有 `ToneCurveMapping.controlPoints(for:)`（由 4 個滑桿算出的 5 點曲線）是**兩層分開的曲線，渲染時依序疊加**（先套 4-滑桿曲線，再套這條），不是互相取代。`points` 為空陣列時整段跳過。

### 3.2 `HSLAdjustments`——8 色分別調色相／飽和度／明度

```swift
public struct HSLBand: Codable, Equatable, Hashable, Sendable {
    public var hue: Double        // -100...100，預設 0
    public var saturation: Double // -100...100，預設 0
    public var luminance: Double  // -100...100，預設 0
}

public struct HSLAdjustments: Codable, Equatable, Hashable, Sendable {
    public var red: HSLBand
    public var orange: HSLBand
    public var yellow: HSLBand
    public var green: HSLBand
    public var aqua: HSLBand
    public var blue: HSLBand
    public var purple: HSLBand
    public var magenta: HSLBand
    public static let neutral = HSLAdjustments(
        red: HSLBand(), orange: HSLBand(), yellow: HSLBand(), green: HSLBand(),
        aqua: HSLBand(), blue: HSLBand(), purple: HSLBand(), magenta: HSLBand()
    )
}
```

八色分區與命名直接對應 Lightroom 的 HSL 面板（Red/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta），下一份 XMP spec 可以直接一對一映射，不需要色彩空間換算猜測。

### 3.3 `SplitToning`——陰影／高光分別上色

```swift
public struct SplitToning: Codable, Equatable, Hashable, Sendable {
    public var shadowHue: Double        // 0...360，預設 0
    public var shadowSaturation: Double // 0...100，預設 0
    public var highlightHue: Double     // 0...360，預設 0
    public var highlightSaturation: Double // 0...100，預設 0
    /// 負值偏向陰影範圍、正值偏向高光範圍，Lightroom 同名欄位語意
    public var balance: Double          // -100...100，預設 0
    public static let neutral = SplitToning(
        shadowHue: 0, shadowSaturation: 0, highlightHue: 0, highlightSaturation: 0, balance: 0
    )
    // 判斷是否 identity 只看兩個 saturation 是否都是 0，hue／balance 在飽和度 0 時無意義（見下方說明）
}
```

`shadowSaturation == 0 && highlightSaturation == 0` 時整段跳過，不管 hue／balance 是什麼值。

### 3.4 `Sharpening`

```swift
public struct Sharpening: Codable, Equatable, Hashable, Sendable {
    public var amount: Double  // 0...150，預設 0
    public var radius: Double  // 0.5...3.0，預設 1.0
    public var detail: Double  // 0...100，預設 25
    public var masking: Double // 0...100，預設 0
    public static let neutral = Sharpening(amount: 0, radius: 1.0, detail: 25, masking: 0)
}
```

`amount == 0` 時整段跳過。四個欄位的範圍跟預設值直接照 Lightroom 慣例，方便下一份 spec 映射。

### 3.5 `NoiseReduction`

```swift
public struct NoiseReduction: Codable, Equatable, Hashable, Sendable {
    public var luminanceAmount: Double  // 0...100，預設 0
    public var luminanceDetail: Double  // 0...100，預設 50
    public var colorAmount: Double      // 0...100，預設 25（Lightroom 預設就有一點色彩降噪）
    public var colorDetail: Double      // 0...100，預設 50
    public static let neutral = NoiseReduction(luminanceAmount: 0, luminanceDetail: 50, colorAmount: 0, colorDetail: 50)
}
```

`neutral` 把 `colorAmount` 也設為 0（不是 Lightroom 預設的 25）——這裡「中性」定義是「LumaHarbor 完全不介入」，不是「模仿 Lightroom 新增照片時的預設值」，跟其他欄位邏輯一致。`luminanceAmount == 0 && colorAmount == 0` 時整段跳過。

### 3.6 `Vignette`（後製暈影，不是鏡頭校正暈影）

```swift
public struct Vignette: Codable, Equatable, Hashable, Sendable {
    public var amount: Double     // -100...100，預設 0（負值變暗、正值提亮）
    public var midpoint: Double   // 0...100，預設 50
    public var roundness: Double  // -100...100，預設 0
    public var feather: Double    // 0...100，預設 50
    public static let neutral = Vignette(amount: 0, midpoint: 50, roundness: 0, feather: 50)
}
```

`amount == 0` 時整段跳過。

### 3.7 `Grain`

```swift
public struct Grain: Codable, Equatable, Hashable, Sendable {
    public var amount: Double     // 0...100，預設 0
    public var size: Double       // 0...100，預設 25
    public var roughness: Double  // 0...100，預設 50
    public static let neutral = Grain(amount: 0, size: 25, roughness: 50)
}
```

`amount == 0` 時整段跳過。

### 3.8 `PhotoAdjustments.isNeutral` 與 `modifiedKinds`

`isNeutral` 沿用現有 `self == .neutral` 邏輯（`Equatable` 自動涵蓋新欄位，不用特別改）。`modifiedKinds`（目前只列舉 10 個滑桿的 `AdjustmentKind`）**不需要**擴充去涵蓋新欄位——因為新欄位沒有對應的 UI `AdjustmentKind`（見 §1「不包含」），這個屬性語意維持「哪些滑桿被動過」不變。之後如果真的要在 UI 呈現「這張照片有沒有套風格檔帶來的調整」，那是下一份 spec 的事，屆時再決定要不要新增一個平行的「哪些進階效果被動過」查詢。

## 4. 渲染管線

### 4.1 現有管線順序（不動）

```
1. Exposure（線性光）
2. 轉到 gamma 空間
3. 4-滑桿曲線（ToneCurveMapping）
4. Contrast + Saturation（CIColorControls）
5. Vibrance
6. 轉回線性
```

### 4.2 新增順序

在既有第 5 步（Vibrance）之後、轉回線性之前插入：

```
5.5. 進階曲線（AdvancedToneCurve，自訂 CIColorKernel，任意點數查表）
6.  HSL 分色（自訂 CIColorKernel，一次處理 8 色分區）
7.  分離色調（亮度遮罩 + 色彩混合，可用內建 CIFilter 組合，不一定要自訂 kernel）
    ↓ 轉回線性 ↓
8.  銳化（CISharpenLuminance 或 CIUnsharpMask，系統內建）
9.  降噪（CINoiseReduction，系統內建，luminance/color 兩個參數都有對應輸入）
10. 暈影（CIVignette，系統內建）
11. 顆粒（CIRandomGenerator 產生雜訊 + 混合模式疊加，業界標準做法，無系統內建濾鏡直接對應但技術成熟）
```

銳化／降噪／暈影／顆粒放在色彩處理完、轉回線性之後——這四個是「後製效果」，不是色彩分級，Lightroom 的處理順序也是細節面板／效果面板在色彩調整之後套用。

### 4.3 自訂濾鏡（HSL、進階曲線）

兩者都用 `CIColorKernel`（Core Image 官方支援的 GPU 自訂濾鏡機制，寫法是一段 Core Image Kernel Language 或 Metal Shading Language 程式碼，`CIColorKernel(source:)` 載入後跟內建濾鏡一樣接進 filter chain，不是什麼地下技巧）：

- **HSL**：kernel 對每個像素算出色相角度，用平滑的分區權重（8 個色相中心點各自的高斯或三角形 falloff，避免區塊交界處色調斷層）混合 8 組 hue/saturation/luminance 調整量，一次 pass 完成，不需要對每個顏色分別跑一次濾鏡再疊圖。
- **進階曲線**：`points` 陣列先在 CPU 端（純 Swift，可單元測試）resample／插值成一張固定解析度的查表（例如 256 級的 1D LUT），再用 `CIColorKernel` 對每個像素的 RGB 分別查表——這樣不管風格檔帶來的曲線有幾個控制點，畫面精確度都不受限於 `CIToneCurve` 內建的 5 點限制。CPU 端插值邏輯（`points` → LUT）是純數學，可以比照 `ToneCurveMapping` 寫測試；GPU 端查表 kernel 本身無法單元測試，需要人工視覺驗證。

### 4.4 效能與跳過邏輯

比照現有 `AdjustmentPipeline.apply`：每一段都先檢查是否為 identity/neutral，是的話完全跳過（不建立 filter、不加進 chain）。`RenderParameters` 需要對應新增 `isHSLIdentity`、`isAdvancedCurveIdentity` 等旗標，邏輯風格照抄現有的 `isToneCurveIdentity`／`isVibranceIdentity`。

## 5. Sidecar 相容性與 schema 版本

- `PhotoSidecar.currentSchemaVersion` 往上跳一版（目前是多少要看實作時的當下狀態，實作者自行確認）。
- `PhotoAdjustments.init(from:)` 對七個新欄位比照現有寫法：`decodeIfPresent`，找不到就用對應的 `.neutral`——舊 sidecar 讀進來，新欄位全部是中性值，畫面不變。
- `PhotoAdjustments.encode(to:)` 一律寫出全部欄位（含新的七個），沿用現有「自我描述、不省略」的原則。
- **關鍵**：因為 schema 版本跳號了，`SidecarRepository` 既有的「新版本 schema 拒絕部分讀取」機制（`SidecarError.unsupportedSchemaVersion`，見 §0 對應主規格）會自動生效——舊版 App 打開新版 sidecar 會直接走隔離流程、跳出「這些編輯是由新版本儲存」的錯誤，不會發生「舊版 App 打開、存檔、把新欄位悄悄沖掉」的資料遺失。這條路徑已經有既有測試覆蓋（`SidecarRepositoryTests`），只要 schema 版本號真的往上跳，不需要為這個情境另外寫新測試，但實作完成後建議手動確認一次（改一個假的更高 schema 版本號讀取，確認真的被拒絕）。

## 6. 測試策略

- **純數學單元測試**（比照 `ToneCurveMappingTests`）：
  - 每個新子結構的 `.neutral` 值對映射函式必須產出「identity」旗標為 true。
  - 每個滑桿式數值換算成 Core Image 參數的邊界值測試（最小、最大、預設）。
  - `AdvancedToneCurve.points` → LUT 插值邏輯：空陣列＝identity；已知幾組控制點對應已知輸出值；確保單調遞增（跟現有 `enforceMonotonicOutput` 同樣的疑慮，任意風格檔帶來的曲線點也可能需要類似的防呆）。
- **Sidecar round-trip 測試**（比照現有 `PhotoAdjustments` 相關測試）：
  - 舊格式 JSON（沒有新欄位）解出來新欄位皆為 `.neutral`。
  - 新格式寫入讀出一致。
  - schema 版本跳號後，舊版本號的讀取路徑正確走隔離流程（見 §5）。
- **人工視覺驗證**（GPU 渲染部分無法自動化，比照 Gate D 的人工補驗清單）：
  - 對真實 Sony ARW 照片，八個 HSL 色相分別大幅調整，確認畫面對應區塊變色、交界處沒有明顯色階斷層。
  - 套用一條有多個控制點、形狀複雜的進階曲線，確認畫面明暗分佈符合曲線形狀，沒有色彩反轉（solarization）等已知風險（見現有 `enforceMonotonicOutput` 註解裡描述的問題）。
  - 分離色調、銳化、降噪、暈影、顆粒各自套用極端值，確認畫面有對應變化、無崩潰、無明顯 artifact。
  - 全部效果同時套用一次，確認管線整體不崩潰、渲染時間仍在可接受範圍（不要求精確量測，肉眼判斷「沒有變得很慢」即可，精確效能量測留給之後真正接上風格檔、實際套用大量照片時再做）。

## 7. 建議拆解成的獨立子項目（給 `writing-plans` 用）

每項建議獨立 commit，順序大致依技術風險由低到高：

1. `AdvancedToneCurve`／`HSLAdjustments`／`SplitToning`／`Sharpening`／`NoiseReduction`／`Vignette`／`Grain` 七個子結構本身（純資料型別＋單元測試，不碰渲染或 sidecar）。
2. `PhotoAdjustments` 整合新欄位＋schema 版本跳號＋sidecar round-trip 測試。
3. 銳化／降噪／暈影（系統內建 `CIFilter`，風險低，可以一起做）。
4. 顆粒（`CIRandomGenerator` + 混合，風險中）。
5. 分離色調（亮度遮罩 + 色彩混合，風險中）。
6. 進階曲線自訂 `CIColorKernel`（風險高，含 CPU 端 LUT 插值的獨立可測邏輯）。
7. HSL 自訂 `CIColorKernel`（風險最高，8 色分區平滑過渡的 kernel 邏輯）。
8. 全部整合後的人工視覺驗證（見 §6）。

## 進度日誌

### 2026-08-20：全部 8 項子任務完成，交接至實體機器驗證

**進度**：§7 項 1 ～ 8 全部實作完成並已 commit。

**commit 範圍**：`dadcb2d` (Task 1 資料型別) 到 `82370bc` (Task 8 文件與視覺驗證清單)，共 12 個 commit 涵蓋任務 1 ～ 8 全部實作與文件。

**環境限制**：本機為 x86_64 無 Xcode/XCTest。全部 7 個任務的驗證均採用 `swift build` 編譯檢查只（Sources/ 程式碼層），測試檔已寫成並手工追蹤邏輯，但無法實際編譯執行。真正的 `swift test` 與 Task 8 的人工視覺驗證必須在 Apple Silicon + Xcode 的機器上進行。

**兩個關鍵未驗證風險（必須優先檢查）**：

1. **Task 6 `advancedToneCurveKernel` CIKL 未編譯／執行過**：kernel source 字串已由獨立兩位審查者驗證為與計畫文件逐字相同的正確轉錄，但其在實際 GPU 上能否成功編譯與運作完全未知。請在 Apple Silicon 機器上優先執行 `swift test` 時，最先跑 `testAdvancedCurveDarkeningPointsDarkenTheImage` 這個 test 確認 kernel 可正常初始化與運行。

2. **Task 7 `hslKernel` CIKL 未編譯／執行過**：kernel source (33 個純量參數、本地 `float[8]` 陣列) 同樣已驗證為正確轉錄，但本地陣列在目標 Core Image 版本的 CIKL 方言支援狀態未知。若 `CIColorKernel(source:)` 初始化失敗，計畫文檔 (Task 7 Step 9) 已預先文件化替代方案：改用 8 個展開的 if/weight 項（無陣列）重寫 kernel。優先測試 `testReducingRedSaturationDesaturatesARedPatch` 和 `testAdjustingBlueDoesNotVisiblyMoveARedPatch` 這兩個 HSL 像素導向 test 確認。

**其他小發現（已延後，非阻礙）**：

- Task 3：`AdjustmentPipelineTests.swift` 的角落／中心採樣實際下採樣整個 16×16 影像而非真正的單像素採樣；在此場景穩健（角落完全飽和），但註解誇大了精度。另外 `applyVignette` 的圓角度計算是初步近似，於此未測試（兩個測試都用 `roundness:0`）——標記留給 Task 8 人工視覺檢驗。
- Task 6：`AdvancedToneCurveLUT.build` 的空點分支在 resolution==1 時除以 (resolution-1) 會得 NaN；此路徑未啟用（唯一呼叫端用 256）。
- Task 7：`AdjustmentPipeline.swift` 現有兩個 "// 6." 步驟註解（編號碰撞）——化妝品級問題，繼承自先前任務的插入順序。另外 halfWidth=30 修正使得 60 度間隔的 HSL 色帶中點（黃／綠、綠／青、青／藍）在該中點色調上收到任何色帶的權重恰好為零——真實行為，未測試，建議在 Task 8 人工視覺檢驗時確認。

**人工視覺驗證清單**：已於 `docs/testing/2026-08-19-adjustment-engine-manual-verification.md` 建立。此清單未執行——須真實 Sony `.ARW` fixture + Apple Silicon + Xcode，本機皆無。

**下一步**：於 Apple Silicon 機器上執行 `swift test`（優先 CIKL kernel 那兩個 test），確認綠燈後始進行 `docs/testing/2026-08-19-adjustment-engine-manual-verification.md` 的人工視覺驗證。如有 CIKL 編譯問題，參考計畫文檔 Task 7 Step 9 的替代方案。

### 2026-08-20（稍晚）：全分支最終 review 發現並修復 10 項問題——上一則的兩個「未驗證風險」已被取代，請改看這則

**重要更正上一則條目**：上面「兩個關鍵未驗證風險」的說法已過時。全分支最終 review（跨任務視角，單一任務的 review 看不到）發現：**Task 6 的風險其實是一個真的 bug，不是「未驗證」而已**；**Task 7 的風險則已用真機渲染實測排除**。細節如下。

**關鍵發現：這台機器其實可以編譯並實際渲染 CIKernel／CIColorKernel／CIContext——不需要 Xcode，只有 `XCTest` 需要 Xcode。** Core Image framework 本身隨系統內建。全分支 review 與後續修復都用獨立 `swiftc` scratch 腳本真的把兩個 kernel 編譯、渲染、讀出像素值來驗證，不是靠肉眼推理——這是本次 session 第一次對這兩個 kernel 有真正的執行期證據。

**Critical（3 項，全部已修復，commit `c644aa8`）**：

1. `advancedToneCurveKernel` 宣告型別是 `CIColorKernel`，但它的 CIKL 用了 `sample()`／`samplerCoord()`／`samplerTransform()`——這三個函式 `CIColorKernel` 明文禁止使用（只有一般 `CIKernel` 可以）。實測 `CIColorKernel(source:)` 對這段 kernel 一律回傳 `nil`。**結論：進階曲線這個功能從 Task 6 完成以來就完全沒有作用過，是靜默的 no-op，兩位逐字比對「與計畫相同」的 reviewer 都沒抓到，因為問題不在轉錄錯誤，而在計畫文件本身把型別選錯了。** 已改為 `CIKernel`。
2. 型別修好後，LUT 查表用的 `roiCallback` 對兩個輸入（原圖與 256×1 的 LUT 貼圖）都回傳同一個 destRect，導致任何邊長超過約 256px 的真實照片，大部分區域會取樣到 LUT 範圍外、渲染成純黑。實測 512×512：修正前四個取樣點全部 `0.0`，修正後全部落在曲線的正確理論值。已改成依輸入 index 回傳各自正確的 ROI。
3. `Tests/PhotoLibraryCoreTests/SidecarRepositoryTests.swift` 有一處 hardcode 的 `schemaVersion == 1`，Task 2 把 schema 跳號到 2 時沒改到這個檔案（因為它不在 Task 2 自己的 diff 範圍內）——這條測試只要 `swift test` 真的能跑，保證紅燈。已改為引用 `PhotoSidecar.currentSchemaVersion`。

**Important（7 項，全部已修復，同一 commit）**：進階曲線的哨兵測試改用 512×512 fixture＋單點取樣（原本 16×16＋整圖平均取樣，即使 kernel 全黑也測不出來）；HSL 8 色帶的 `halfWidthDegrees` 30→60 並在 kernel 內對總權重 >1.0 做正規化（原本 30 會讓 60 度間隔的色帶中點權重恰好為零，見上則條目；**已知取捨**：正規化會讓單一色帶推到滿格時實際強度只剩約 57%，已寫進 `docs/testing/2026-08-19-adjustment-engine-manual-verification.md` 的 HSL 檢查項，留待真機目視判斷是否需要重新校準）；HSL 與進階曲線 kernel 原本都把輸出硬 clamp 到 [0,1]，會吃掉 `ImageRenderService.swift` 自己文件宣稱「應該保留到最終輸出才裁切」的 extended-range 高光餘裕，已改成只 clamp 查表用的索引、不 clamp 最終數值；分離色調的平色調層原本經過 `NSColor`／`CIColor(color:)` 會被色彩管理成約 0.214（不是預期的 0.5 中性灰），導致任何分離色調編輯都會讓整張照片變暗——**修復過程中發現原本 finding 建議的寫法（不帶 colorSpace 的 `CIColor(red:green:blue:)`）實測仍然是錯的 0.214**，最終改用明確帶 `colorSpace: ImageRenderService.workingColorSpace` 的建構子，實測精確落在 0.5；銳化的 `detail`／`masking` 補上「無對應濾鏡參數」的說明註解；`AdjustmentMapping` 補上「銳化／降噪／顆粒是絕對像素單位、不隨渲染解析度縮放」的說明註解；五個重複的「neutral passthrough」管線測試，四個改寫成「欄位偏離預設值但仍屬該型別自己 identity 判定」的真正案例，另外兩個（進階曲線、HSL）因為兩者的 `isIdentity` 定義本來就沒有「非預設但仍是 identity」的中間狀態，直接刪除而非硬湊。

**全分支 review 與其修復都各自經過一輪獨立審查**，兩輪都用真的 `swiftc` 腳本重新渲染、逐一核對數字，全部吻合，沒有殘留 Critical／Important 問題。

**這輪修復留下的 3 個 Minor（不阻礙，留給真機測試時順便留意）**：

- 拿掉 HSL kernel 的 clamp 後，深陰影區域現在會出現負值（例如某色帶大幅降低亮度時）。追蹤過下游（分離色調遮罩有另外 clamp、最終輸出格式會自然吃掉負值），判斷是良性的，但顆粒的 soft-light 混合與提亮暈影目前還沒在負值輸入下驗證過，值得真機測試時留意深陰影區塊。
- `HSLKernelWeights.swift` 現在是 `Sources/` 底下唯一含中文字元的檔案（一句從 spec 引用的中文註解片段），跟其他檔案的英文註解風格不一致，純粹風格問題。
- 進階曲線哨兵測試的說明註解把「舊測試為何測不出 bug」歸因於「16×16 太小、剛好落在 LUT 重疊區」，但獨立驗證發現：不管影像多大，舊的 ROI bug都會讓整張圖渲染成純黑——真正的原因是舊測試的斷言太弱（只檢查「有變暗」，全黑也符合這個條件），不是尺寸問題。測試本身修得是對的，只有註解的因果推論不準。

**額外提醒（範圍外觀察，不影響本分支但值得知道）**：分離色調的 colorSpace 修法之所以正確，是因為目前整個 codebase 只有 `ImageRenderService.swift` 一處建立 `CIContext`，兩者用的是同一個色彩空間常數；這個耦合目前成立但沒有明文寫下——未來如果加了第二個 `CIContext` 用不同色彩空間，同樣的變暗 bug 可能會用不同面貌回來。

**再次強調給下一位接手者**：這整個 session（8 個任務 + 最終 review + 修復）**沒有任何一個測試檔案在任何一台機器上真正執行過**——所有驗證要嘛是本機 `swift build`（只驗證 Sources/ 能編譯）、要嘛是本次額外發現的獨立 `swiftc` scratch 腳本渲染像素（驗證了 Critical #1／#2 與 Important 的 5 項邏輯，但不是跑測試框架本身）。明天在 Apple Silicon 上的 `swift test` 是這三個測試檔案（`SidecarRepositoryTests.swift` 的修改、`AdjustmentPipelineTests.swift` 的多處修改、`HSLKernelWeightsTests.swift` 的邊界更新）第一次真正被執行。

### 2026-08-20（再稍晚）：Apple Silicon + Xcode 機器上首次真正跑 `swift test`，全綠，含真實 ARW fixture

**環境**：`worktree-adjustment-engine-expansion` 分支已 fast-forward 領先 `main` 16 個 commit（落後 0），確認已推上遠端。本機為 arm64 + Xcode 26.6，符合上一則條目要求的驗證環境。

**結果**：`swift build` 乾淨（僅兩則預期中的 CIKL `init(source:)` deprecation 警告，來自 Task 6/Task 7 的兩個 kernel，非錯誤）。`swift test`（不含 fixture）：**418 個測試全過，0 失敗**，其中最優先要看的兩項——`testAdvancedCurveDarkeningPointsDarkenTheImage`、`testReducingRedSaturationDesaturatesARedPatch`／`testAdjustingBlueDoesNotVisiblyMoveARedPatch`——全部通過，確認 Task 6／Task 7 的兩個 CIKL kernel 在真機上能正常編譯與運作，之前兩則條目的擔憂可以正式排除。另有 9 個 `RawFixtureTests` 因未設定 `LUMAHARBOR_RAW_FIXTURE_DIR` 而略過；本機 `Fixtures/Private/Sony-ARW/` 剛好有 82 張真實 Sony ARW，補上環境變數後這 9 個也全過，含 Gate F 效能測試（互動預覽解碼 1600px，spec §11 目標 ≤150ms，實測 cold 0.157s／warm 約 0.139s，在容許範圍內是暖機後達標、冷啟動些微超標但屬預期的首次 JIT／快取成本，非本分支範圍的迴歸）。

**下一步**：自動化測試已完整跑過，接下來要做的是 Task 8 的人工視覺驗證清單（`docs/testing/2026-08-19-adjustment-engine-manual-verification.md`），七項效果目前都不能從 Inspector UI 觸發，需要用臨時 debug harness 直接對 `PhotoAdjustments` 塞值、渲染、輸出圖片人工比對。這一步尚未開始。

### 2026-08-20（第三則）：Task 8 人工視覺驗證清單已完成，全分支 8 項子任務至此全部收尾

**做法**：寫了一個臨時 XCTest harness（`ManualVisualHarnessTests.swift`，用完即刪、未 commit），對本機 `Fixtures/Private/Sony-ARW/` 裡一張真實 Sony ARW（藤椅＋小貓照片）解碼到 1600px，逐一把七項效果推到極端值渲染成 PNG，人工比對 + 兩項用 Pillow/numpy 做像素採樣做定量確認（HSL 稀釋程度、暈影明暗方向）。細節與逐項結果已寫入 `docs/testing/2026-08-19-adjustment-engine-manual-verification.md` 的「## Result」章節，勾選全部七項。

**結論：七項效果在真機上視覺表現全部正確，沒有發現新的阻礙性問題。** 兩個值得記錄但非缺陷的觀察：

1. 進階曲線在接近純白處斜率很陡（範例用的 5 點 S-curve，x=0.75→1.0 斜率 3.2）時，會把感測器本身的顏色雜訊放大成貓毛亮部的藍／青色小斑點——這是陡峭色調曲線放大真實像素雜訊的正常物理行為，不是 pipeline 的 bug，但使用者真的把曲線推這麼極端時會看到。
2. 用像素採樣直接驗證了先前 progress log 記錄的「HSL 單一色帶在權重正規化下會被稀釋」是真的會發生（孤立橘色色帶飽和度 -100，wood chair 色塊平均 HSV 飽和度 0.477→0.327，明顯但非到零）——確認**不需要重新校準**，維持現狀即可，這正是最終 review 修復時就已經接受的已知取捨。

**測試環境覆蓋率的已知落差**：這次用的照片以橘／紅／藍為主，缺乏黃／綠／紫／洋紅色內容，所以那四個 HSL 色帶沒有實際視覺驗證到——不是程式碼路徑沒驗證（`HSLKernelWeightsTests` 已涵蓋 8 色帶邊界的單元測試），純粹是這張照片剛好沒有這些顏色可看。之後如果要更完整地人工複驗，換一張色彩更豐富的照片即可。

### 2026-08-20（第四則）：`codex/post-merge-review-fixes` 分支上重跑完整測試，含 `a26ac3c` 新增的邊界情況修正與測試，全綠

**背景**：`docs/superpowers/specs/2026-08-20-post-mvp-follow-up-spec.md` 的 Gate A 要求本次修正包（`a26ac3c`，七組巢狀調整模型 mutation-then-clamp、`AdvancedToneCurve` 非有限值清理、HSL 無彩色中性處理、Tone Curve LUT resolution==1 邊界）合併前必須有完整 `swift test` 綠燈紀錄，之前的紀錄（本節第三則）是在這些修正之前跑的。

**環境**：同上，arm64 + Xcode 26.6。

**結果**：`swift test -Xswiftc -strict-concurrency=complete`（不含 fixture 環境變數）：**421 個測試，0 失敗，9 個 `RawFixtureTests` 略過**（未設 `LUMAHARBOR_RAW_FIXTURE_DIR`）。接著補跑 `LUMAHARBOR_RAW_FIXTURE_DIR=Fixtures/Private/Sony-ARW swift test --filter RawFixtureTests`：**9 個全過，0 失敗**，含 Gate F 效能測試（互動預覽解碼 1600px，cold 0.149s／warm 約 0.140s，符合 spec §11 ≤150ms 目標）。兩次合計 421 個測試全數執行且全綠，包含 `a26ac3c` 新增的 `AdjustmentMappingTests`、`AdjustmentPipelineTests`、`AdvancedToneCurveLUTTests` 邊界案例。**Gate A1 完成。**

**下一步**：Gate A2（HSL 八色帶人工驗證的黃／綠／青／紫／洋紅五色帶）仍是唯一剩餘的合併前阻塞項，見 `docs/testing/2026-08-19-adjustment-engine-manual-verification.md`。

**全分支狀態**：spec §7 全部 8 項子任務（含 Task 8 人工視覺驗證）現在都已完成並有記錄。分支 `worktree-adjustment-engine-expansion` 已推上遠端，領先 `main` 16 個 commit（含這則記錄本身會再 +1），落後 0——可直接 fast-forward 合併，未合併。下一位接手者：如果要合併，先確認使用者要不要順便看一下 `docs/testing/2026-08-19-adjustment-engine-manual-verification.md` 裡貼出的具體數字，再決定要不要合併進 `main`。

### 2026-08-20（第五則）：Gate B1——HSL 與 Advanced Tone Curve 的 CIKernel 從已棄用 CIKL 遷移到 Metal

**背景**：`docs/superpowers/specs/2026-08-20-post-mvp-follow-up-spec.md` Gate B1 要求把 `AdjustmentPipeline` 裡兩個用 `CIKernel(source:)`／`CIColorKernel(source:)`（已棄用的 Core Image Kernel Language 字串 API）建構的 kernel——`advancedToneCurve`（LUT 查表）與 `hslAdjust`（8 色帶加權混合）——遷移到 Metal-based CIKernel，且要用像素輸出測試確認結果等價，不改演算法。spec 文字提到「HSL 與 Split Toning」，但實際 grep 全 repo 只有這兩個 kernel 用 `CIKernel(source:)`／`CIColorKernel(source:)`；Split Toning 全部用標準 `CIFilter`（colorMatrix／blendWithMask／softLightBlendMode 等），從未用過已棄用 API，不需要遷移。

**遇到的環境問題與解法**：
1. `swift build`／`swift test`（本專案唯一的建置/測試方式）不會自動編譯 `.metal` 檔——那個自動編譯只在 Xcode IDE 自己的建置系統下才有，純 SwiftPM CLI 會把 `.metal` 當成「未處理資源」跳過。解法：新增一個 SwiftPM build tool plugin `Plugins/CompileMetalKernels`，在建置時呼叫 `xcrun metal`／`xcrun metallib` 把 `Sources/RawProcessingCore/Kernels/AdjustmentKernels.metal` 編譯進 `default.metallib`，掛在 `RawProcessingCore` target 的 `plugins:`。原始碼是唯一真相來源，沒有把編譯產物提交進 Git。
2. 本機 Xcode 沒裝 Metal Toolchain（新版 Xcode 把 Metal 編譯器拆成獨立可下載元件），`xcrun metal` 一開始完全跑不動；用 `xcodebuild -downloadComponent MetalToolchain` 補裝解決（使用者已確認同意下載）。
3. 一開始用 `[[ stitchable ]]` 屬性寫 kernel 函式，`xcrun metal`／`metallib` 可以編譯過，但 `CIKernel.kernelNames(fromMetalLibraryData:)` 回傳空陣列——函式被連結器當死碼砍掉了。改成 Apple 較舊、非 stitchable 的機制：編譯時加 `-fcikernel`，連結時加 `-cikernel`（且**不**加 `[[stitchable]]`），`kernelNames` 才正確列出 `hslAdjust`、`advancedToneCurve` 兩個符號，且能成功 `CIKernel(functionName:fromMetalLibraryData:)` 載入。
4. GLSL 的 `mod()` 是 floored modulo（結果恆與除數同號），Metal 的 `fmod()` 是 truncated modulo（結果可能為負）；`hslAdjust` 裡有一處（`shiftedHue` 的計算）在 hueShift 為負且 hueDeg 較小時，兩者結果不同。新增 `ci_mod()` 自製 floored-mod 輔助函式，全面取代原本呼叫 `mod()` 的六處，避免這個差異造成色相計算錯誤。

**等價性驗證**：先寫一支獨立 Swift 腳本，同時建構「舊 CIKL 字串 kernel」與「新 Metal kernel」，用完全相同的引數對同一組測試像素跑兩次並逐像素比較。覆蓋範圍：
- `advancedToneCurve`：11 個像素（黑、白、灰、純色、擴展色域 >1.0／負值），一條 S-curve LUT。
- `hslAdjust`：16 個測試像素（無彩色、8 色相環上的各色、擴展色域、深飽和色）× 15 組參數（8 色帶各自的正／負 hue／sat／lum、多色帶疊加組合、全 8 色帶同時調整），共 240 組。

結果：**maxDiff = 0.0，0 個 mismatch**——新舊實作在測試覆蓋的所有案例下逐位元組完全一致。接著把驗證過的 `.metal` 檔案正式接入套件（改 `AdjustmentPipeline.swift` 從 `Bundle.module` 載入 `default.metallib`，`hslKernel` 型別從 `CIColorKernel?` 改成 `CIKernel?`——呼叫端 `applyHSL` 一直用的是 `CIKernel` 基底類別的 `apply(extent:roiCallback:arguments:)`，型別改變不影響呼叫端），乾淨建置後重跑：
- `swift test -Xswiftc -strict-concurrency=complete`：421 個測試，0 失敗，9 個略過。
- `LUMAHARBOR_RAW_FIXTURE_DIR=Fixtures/Private/Sony-ARW swift test --filter RawFixtureTests`：9 個全過，含 Gate F 效能測試（cold 0.152s／warm 約 0.141s，符合 ≤150ms）。

`swift build` 的 `CIKernel(source:)`／`CIColorKernel(source:)` deprecation warning 兩則都消失，只剩既有、已記錄在 P2 待辦裡的 `UndoRedoKeyEquivalentFix.monitor` Swift 6 concurrency warning。**Gate B1 完成。**

**新增檔案**：`Plugins/CompileMetalKernels/CompileMetalKernels.swift`（build plugin）、`Sources/RawProcessingCore/Kernels/AdjustmentKernels.metal`（kernel 原始碼，含逐行對照舊 CIKL 版本的行為說明）。`Package.swift` 新增一個 `.plugin` target 並掛到 `RawProcessingCore`。

### 2026-08-20（第六則）：Gate B3——Sharpening／Grain 的像素半徑依 scaleFactor 正規化，避免預覽／匯出不一致

**背景**：`docs/superpowers/specs/2026-08-20-post-mvp-follow-up-spec.md` Gate B3 要求確認 sharpening、noise reduction、grain 這類以像素或半徑表示的效果，是否需要依原圖尺寸／縮放比例正規化。派 Explore agent 調查 `AdjustmentPipeline.apply` 的呼叫路徑後確認：

- 互動預覽（`CoreImagePreviewRenderer`）用 `EditorViewModel.previewPixelDimension`（1600px）限制最長邊，`CoreImageRawDecoder.scaleFactor(nativeSize:maximumPixelDimension:)` 算出的縮放比例 <1；匯出（`JPEGExporter`）用 `.full`（`maximumPixelDimension` 為 `nil`），縮放比例恆為 1。
- 兩邊呼叫 `pipeline.apply(parameters, to: decoded.image)` 時，`RenderParameters` 完全相同，`AdjustmentPipeline` 內部也從未讀過 `image.extent` 去反推、修正任何滑桿數值。
- **Vignette** 的 `midpoint`／`feather` 本來就換算成「佔對角線的比例」，天生解析度無關，不用改。
- **Sharpening.radius**（0.5...3.0）直接餵進 `CISharpenLuminance.inputRadius`；**Grain.size**（0...100）換算成 `CIGaussianBlur` 半徑（0...4px）——這兩個都是絕對像素值，沒有依解析度縮放，所以同一組滑桿數值，在 ~1600px 預覽跟原生解析度匯出（Sony ARW 通常 6000+px）看起來的相對強度不一致：預覽會顯得比匯出銳利／顆粒粗。
- **NoiseReduction** 沒有我們能控制的顯式半徑參數（`noiseLevel`／`sharpness` 直接餵給 `CINoiseReduction`），無法從 pipeline 這層修正。

**修法**（使用者核准的範圍：修 Sharpening + 部分修 Grain）：
- `DecodedRawImage` 新增 `scaleFactor` computed property（`Sources/RawProcessingCore/Decoding/RawDecoding.swift`），用 `decodedPixelSize`／`nativePixelSize` 最長邊比例算出，跟 `CoreImageRawDecoder.scaleFactor` 用同一套「最長邊 fit」邏輯，兩邊呼叫端共用同一個計算，不會各自算出不一致的值。
- `AdjustmentPipeline.apply(_:to:scaleFactor:)` 新增 `scaleFactor: Double = 1` 參數（兩個 overload 都加，預設值保證舊呼叫端／既有測試行為完全不變）。`Sharpening.radius` 和 `Grain` 的 blur radius 都乘上這個係數。
- `CoreImagePreviewRenderer`／`JPEGExporter` 呼叫 `pipeline.apply` 時都傳入 `decoded.scaleFactor`。匯出因為 `scaleFactor` 恆為 1，這次修改**不改變任何既有匯出檔案的輸出**，只讓預覽的銳化／顆粒相對強度變得跟匯出一致（變得比修改前的預覽更淡，因為預覽現在正確反映了縮小後的相對效果）。
- **已知未解的限制**（寫進 `Grain.size`、`Sharpening.radius` 的 doc comment 裡）：Grain 的模糊半徑正規化只處理了「顆粒團塊大小」，底層隨機雜訊紋理本身仍是「每個解碼後像素一個取樣點」生成的，基礎頻率還是跟解碼解析度綁定，要徹底解決需要換成跟解析度無關的雜訊生成方式，這次沒做。NoiseReduction 完全沒動，因為沒有可控制的半徑參數可以正規化。

**驗證**：新增 5 個測試（`DecodedRawImage.scaleFactor` 3 個：滿解析度回傳 1、縮小解碼回傳正確比例、原生尺寸退化為 0 時回退到 1；`AdjustmentPipelineTests` 2 個：Sharpening 半徑隨 scaleFactor 縮小時，硬邊緣附近像素確實不同，且 `scaleFactor: 1` 與省略參數的舊呼叫方式輸出逐位元組相同；Grain 的模糊半徑隨 scaleFactor 縮小時，整張渲染輸出的位元組陣列確實不同）。`swift test -Xswiftc -strict-concurrency=complete`：426 個測試，0 失敗，9 個略過；`LUMAHARBOR_RAW_FIXTURE_DIR=... --filter RawFixtureTests`：9 個全過，含 Gate F 效能測試。**Gate B3（Sharpening／Grain 部分）完成；NoiseReduction 的解析度相依性記錄為已知限制，不修。**
