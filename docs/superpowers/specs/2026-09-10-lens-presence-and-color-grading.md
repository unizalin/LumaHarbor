# P4：Lens、Presence、Color Grading、Black & White、Rendering Profile 實作規格

- 狀態：核准，進入實作
- 日期：2026-09-11
- 依據：`docs/superpowers/specs/2026-09-10-professional-editing-completion-design.md` §6.3、§6.4、§8、§9、§11.2（第 9、10 條）
- 前置：P3（已完成）。
- 範圍鎖定：`PresenceAdjustments`（texture/clarity/dehaze）、`ColorGradingAdjustments`（3-way + global + balance/blending）、`MonochromeAdjustments`（8 色 B&W mixer）、`RenderingProfileSelection`（內建 creative profile）、`LensCorrectionAdjustments`（automatic／manual／bundled-profile／off）。不做 Mask/AI/Repair/Perspective（P5）、Snapshot/Soft Proof（P6）。

## 1. 範圍與刻意排除的項目（先講清楚，避免之後被誤讀為遺漏）

1. **Lensfun 資料庫**：本階段只做「bundled profile」的**解析與比對引擎**（一個可以吃內部 JSON schema、依 maker/model/lens/focalLength/aperture 比對的 `LensProfileDatabase`），**不**內附任何真實 Lensfun profile 資料。原因：真實 Lensfun database 是外部授權資料（CC BY-SA 3.0），需要實際下載、驗證授權文字與資料正確性；此環境沒有可驗證的網路擷取來源，若憑空生成「看起來像」Lensfun 格式的座標資料會是捏造資料，比不做更危險。因此本階段的 bundled-profile 比對永遠回傳「沒有相符 Profile」，自動退回 manual fallback ——這完全符合 §6.4 第 4 點的既定行為，只是「資料庫是空的」。之後若使用者提供真實 Lensfun 資料檔案，只需要塞進 `Resources/LensProfiles/` 且不必修改比對邏輯。
2. **Automatic 模式**是唯一「渲染時機在 RAW decode 階段」的模式（`CIRAWFilter.isLensCorrectionSupported`／`isLensCorrectionEnabled`，Apple 內建、真實 API，不是推測）。Manual／Profile 模式的校正在 decode 之後、`AdjustmentPipeline.apply` 的最前面執行——見下方 D-007。
3. **鏡頭幾何校正只用 Core Image 內建 filter**（`CIPinchDistortion`／`CIBumpDistortion` 做徑向桶狀／枕狀校正,`CIAffineTransform`＋`CIColorMatrix` 做 TCA 逐通道縮放),不寫新的自訂 Metal warp kernel。原因：Core Image 的 `CIWarpKernel` 需要不同於現有 `CIKernel`／`CIColorKernel` 的座標對應簽名,此環境沒有互動除錯工具可驗證新 warp kernel 是否真的编譯並產生正確位移,貿然寫一個無法視覺驗證的座標 warp kernel 風險遠高於用已知穩定的內建 filter 組合。TCA 用「整張畫面均勻縮放紅／藍通道」而非「依半徑非線性縮放」,是刻意簡化但真實存在效果的近似,非空實作。
4. **RenderingProfileSelection 不對應 Adobe `crs:CameraProfile`**（那是外部 DCP 檔案引用,無法重現)。本階段的「camera／creative profile」是 LumaHarbor 內建、版本化的一組 creative style（見 §4)，`crs:CameraProfile` 繼續走既有「no mapping / preserved」路徑（`XMPMappingTests.testCameraProfileHasNoMapping` 既有測試不受影響)。
5. **Color Grading／B&W mixer 的 XMP 對應**：`crs:Texture`／`crs:Clarity2012`／`crs:Dehaze`（Presence）有高信心的真實 Adobe 屬性名稱,本階段原生對應。`crs:ColorGrade*`（Color Grading 面板)、`crs:GrayMixer*`（B&W mixer）在缺乏可驗證來源下不做原生對應,一律走既有「未知 property → preserved,不遺失、下次匯出保留原始 XMP」路徑（既有 `XMPImporter.preview` 對任何未註冊 property 的既定行為，不需要新程式碼)。這不違反 §11.1 第 6 條（不得靜默刪除未知欄位),因為 preserved 保留原始 bytes,只是不會「原生套用」到 LumaHarbor 自己的調整上。

## 2. 決策：渲染順序的必要偏差（D-007）

`docs/coordination/DECISIONS.md` D-007：Automatic 模式的鏡頭校正在 `CoreImageRawDecoder` 內、白平衡烘焙的同時完成（真正符合 §8 step 2 在 step 3 之前)。Manual／Profile 模式因為白平衡已經烘進 demosaic、沒有 decode 前的 hook,改在 `AdjustmentPipeline.apply` 的最前面（在既有的「1. Exposure」之前)執行。這是有紀錄、刻意的偏差,不是遺漏。

## 3. 資料模型

新增至 `Sources/RawProcessingCore/Model/`：

```swift
public struct PresenceAdjustments: Codable, Equatable, Hashable, Sendable {
    public var texture: Double   // -100...100
    public var clarity: Double   // -100...100
    public var dehaze: Double    // -100...100
    public static let neutral: PresenceAdjustments
    public var isIdentity: Bool
}

public struct ColorGradeBand: Codable, Equatable, Hashable, Sendable {
    public var hue: Double         // 0...360
    public var saturation: Double  // 0...100
    public var luminance: Double   // -100...100
}

public struct ColorGradingAdjustments: Codable, Equatable, Hashable, Sendable {
    public var shadows: ColorGradeBand
    public var midtones: ColorGradeBand
    public var highlights: ColorGradeBand
    public var global: ColorGradeBand
    public var balance: Double     // -100...100, shifts shadow/highlight split point
    public var blending: Double    // 0...100, softens the zone transition
    public static let neutral: ColorGradingAdjustments
    public var isIdentity: Bool   // all four bands' saturation == 0 (hue meaningless at sat 0, same convention as SplitToning)
}

public struct MonochromeAdjustments: Codable, Equatable, Hashable, Sendable {
    public var isEnabled: Bool
    public var red: Double, orange: Double, yellow: Double, green: Double
    public var aqua: Double, blue: Double, purple: Double, magenta: Double  // each -100...100
    public static let neutral: MonochromeAdjustments
    public var isIdentity: Bool  // !isEnabled (mix values are irrelevant while disabled, same convention as other "enabled" gated structs)
}

public struct RenderingProfileSelection: Codable, Equatable, Hashable, Sendable {
    public var profileID: String?      // nil = none selected (identity)
    public var amount: Double          // 0...100, blend strength
    public var fallbackReason: String? // set when profileID no longer resolves to a known built-in profile
    public static let neutral: RenderingProfileSelection
    public var isIdentity: Bool  // profileID == nil
}

public enum LensCorrectionMode: String, Codable, Sendable { case off, automatic, manual, bundledProfile }

public struct LensCorrectionAdjustments: Codable, Equatable, Hashable, Sendable {
    public var mode: LensCorrectionMode
    public var profileID: String?           // bundledProfile mode only
    public var distortionAmount: Double     // -100...100, manual/bundledProfile
    public var vignettingAmount: Double     // -100...100
    public var tcaAmount: Double            // -100...100
    public static let neutral: LensCorrectionAdjustments   // mode = .off
    public var isIdentity: Bool  // mode == .off
}
```

全部加入 `PhotoAdjustments`（新增五個欄位,neutral default,`CodingKeys`／`decodeIfPresent ?? .neutral`,沿用既有「新欄位缺席時退化為 neutral」慣例,不需要 `PhotoSidecar` 升版——`PhotoSidecar.adjustments: PhotoAdjustments` 是整包序列化,先例見 P1／P2／P3 都沒有因為 `PhotoAdjustments` 新欄位而動 `PhotoSidecar.currentSchemaVersion`)。

## 4. RenderingProfileSelection 的內建 profile 清單

`RenderingProfileCatalog`（新檔 `Sources/RawProcessingCore/Model/RenderingProfileCatalog.swift`）宣告一組固定、版本化、內建的 creative style,每個 profile 是既有調整量的一組係數（不是新的渲染基元),透過現有 `ColorControls`／`ToneCurve` 語意混合套用：

| profileID | 效果組成（`amount=100` 時的滿值係數） |
| --- | --- |
| `lumaharbor.standard` | 恆等（`amount` 對它無效果,存在是為了讓「有選但無效果」可被 UI 顯示與 reset 區分） |
| `lumaharbor.vivid` | saturation +20、contrast +10 |
| `lumaharbor.flat` | contrast -20、highlights -15、shadows +15 |
| `lumaharbor.portrait` | saturation -5、warmth（temperature-equivalent tint 係數）+5、contrast -5 |

`amount` 對 0...100 線性插值套用上表係數（`amount=0` 等同未選）。`profileID` 不在 `RenderingProfileCatalog.allProfileIDs` 時,渲染端不套用任何效果,`fallbackReason` 由呼叫端（UI／preset apply）設為 `"unknownProfile"`,不猜測。

## 5. 渲染

### 5.1 Presence（`AdjustmentPipeline`,置於既有「5. Vibrance」之後、Advanced curve 之前——歸屬於同一個 perceptual 階段,符合 §8 step 5「Presence、HSL、Color Grading、Monochrome、Rendering Profile」同組)

- **Texture**：`CISharpenLuminance` 的低半徑（細節層次)版本,`amount` 映射到一個小半徑（約 1...2 px）的銳化係數,正值增加中頻細節,負值改用等量的 `CIGaussianBlur` 弱化中頻（近似「negative texture = 柔化」）。
- **Clarity**：既有 Lightroom 語意是「局部對比」,近似作法：`CIUnsharpMask`（大半徑,約 20...60 px,依 `scaleFactor` 縮放,呼應既有 sharpening 的 scaleFactor 慣例）,`amount` 映射到 `intensity`。
- **Dehaze**：近似作法（業界常見公式）：對比拉伸 + 飽和度提升的組合,用既有 `CIFilter.colorControls()`（`contrast`／`saturation`）與一個由 `CIFilter.toneCurve()`（黑點抬升/highlight roll-off，模擬去霧的暗部對比）組成。正值去霧（提升暗部對比與飽和)、負值反向（模擬霧感）。

三者共用一個 `isPresenceIdentity` gate（全 0 時完全跳過)。

### 5.2 Color Grading（`applyColorGrading`,仿照既有 `applySplitToning` 的 flat-color + luminance-mask blend 手法,擴充為三段）

1. 用同一個 `flatColor(hue:saturation:)` 輔助函式（從 `applySplitToning` 抽成共用 private helper,兩者共用)產生 shadows／midtones／highlights／global 四張純色圖層。
2. 用 `CIColorMatrix` 算出 luminance mask（同 split-toning 手法),依 `balance` 位移,再依 `blending`（映射到既有 `CIGaussianBlur` 的 mask 模糊半徑,`blending=0` 得到銳利分界,`blending=100` 得到最平滑過渡)模糊化，切出 shadow-mask、highlight-mask,midtone-mask 為 `1 - shadow - highlight`（clamp 到 0...1)。
3. 依序用 `CIBlendWithMask` 疊 shadows → midtones → highlights,最後疊 global（`global` 的 mask 是全 1,等於均勻套用,對應 Lightroom Color Grading 面板的「全域」滾輪)。
4. Global 飽和度為 0 且三段飽和度皆 0 時整體 identity（`ColorGradingAdjustments.isIdentity`)。

### 5.3 Monochrome（`applyMonochrome`,新 Metal kernel `monochromeMixer`,復用既有 `hslAdjust` 的 8-band 三角形 falloff 權重數學——同一份「hue 屬於哪個 band 多少比例」邏輯,重新用在不同輸出上)

- 對每個 pixel：算出其 hue 對 8 個 band 的三角形 falloff 權重（與 `hslAdjust` 完全相同的表)、算出 luminance（Rec.709 係數,與既有 `applySplitToning` 的 lumaVector 一致)。
- 輸出灰階 = `luminance * (1 + Σ(weight_i * mix_i / 100 * mixStrength))`,`mixStrength` 是一個防止極端值死黑/死白的固定係數（同 `hslAdjust` 對 luminance 調整的封頂手法),再 clamp 到 0...1（保留 extended-range highlight 的加回邏輯與 `advancedToneCurve` kernel 一致)。
- `isEnabled == false` 時完全跳過（不呼叫 kernel),此時色彩調整（HSL／Color Grading）不受影響——「停用時保留彩色調整」（§6.3 表格原文)。

### 5.4 Lens Correction

- **Automatic**：`CoreImageRawDecoder.decode` 新增：讀取 `request.lensCorrection`（新欄位,傳入 `LensCorrectionAdjustments`),當 `mode == .automatic` 時，`if filter.isLensCorrectionSupported { filter.isLensCorrectionEnabled = true }`；`mode == .off` 時明確 `filter.isLensCorrectionEnabled = false`（不依賴系統預設值);`.manual`／`.bundledProfile` 也明確設為 `false`（避免系統內建校正與手動校正疊加,符合 §6.4「不得同時套用」)。
- **Manual／Bundled Profile**（`applyLensCorrection`,`AdjustmentPipeline.apply` 最前面新增的步驟,見 §2 D-007）：
  - Distortion：`amount > 0` 用 `CIFilter.pinchDistortion()`（校正桶狀畸變),`amount < 0` 用 `CIFilter.bumpDistortion()`（校正枕狀畸變),`scale`／`radius` 由 `abs(amount)` 映射,中心點固定在畫面中心。
  - Vignetting：仿照既有 `applyVignette` 的 `CIRadialGradient` 徑向遮罩 + 乘法補光,但只有 `amount` 一個參數（無 midpoint/roundness/feather——校正鏡頭原生失光比藝術性暈影更接近固定半徑曲線),正值補償失光（提亮邊角),負值加深（模擬鏡頭原生暈影未校正的狀態,供使用者手動抵消 profile 誤判)。
  - TCA：對原圖分別用 `CIColorMatrix` 抽出只有 R（G=B=0）、只有 B（R=G=0）的圖層,個別套用一個以畫面中心為錨點的 `CIAffineTransform` 均勻縮放（`1 + tcaAmount * k`／`1 - tcaAmount * k`),再用 `CIColorMatrix` 之後 `CIAdditionCompositing` 疊加回「只保留 G」的原圖層,重組成最終 RGB。這是均勻縮放（非逐半徑非線性),為刻意簡化,已在 §1 第 3 點聲明。
  - `LensCorrectionAdjustments.isIdentity`（`mode == .off`)時三者完全跳過。
  - `bundledProfile` 模式：先用 `LensProfileDatabase.match(cameraMake:cameraModel:lensModel:focalLengthMM:aperture:)`（新型別,§1 第 1 點)找係數；找不到時整條退回「視同 manual、但係數全 0」（等於沒有校正),同時要求呼叫端（UI／render request 組裝處)把 `fallbackReason` 設成 `"noMatchingProfile"`，不得猜測、不得套用最接近但不符合的 profile。

## 6. 固定渲染順序落地對照

| 設計規格 §8 | 本階段實作位置 |
| --- | --- |
| 2. Lens correction | Automatic：`CoreImageRawDecoder`（decode 時)。Manual／Profile：`AdjustmentPipeline.apply` 最前面（D-007 偏差) |
| 5. Presence、HSL、Color Grading、Monochrome、Rendering Profile | 既有 perceptual 階段內,循序：Vibrance → Presence → Advanced curve → HSL → Color Grading → Monochrome → Rendering Profile → Split Toning（既有位置不變) |

Rendering Profile 放在 Monochrome 之後、Split Toning 之前——因為 profile 的係數只調整既有 contrast/saturation/warmth,語意上等同再疊加一層「基礎調」,早於使用者自己刻意做的 split toning。

## 7. Preset／XMP

**修正決策（實作階段,取代本節原先規劃的 33 個逐欄位 field ID)**：

- `PresenceAdjustments` 維持逐欄位 granular（`presenceTexture`／`presenceClarity`／`presenceDehaze`,3 個 scalar Double field ID),因為它們需要透過既有 `XMPMappingRegistry`（scalar mapping table,鍵入單一 `AdjustmentFieldID` → Double）原生對應 `crs:Texture`／`crs:Clarity2012`／`crs:Dehaze`,這個既有架構要求每個原生對應的 property 都是可獨立定址的 scalar field ID,不能透過 whole-value leaf 表達。
- `ColorGradingAdjustments`／`MonochromeAdjustments`／`RenderingProfileSelection`／`LensCorrectionAdjustments` 這四組改為 whole-value leaf——`colorGrading`、`monochrome`、`renderingProfile`、`lensCorrection`,每個對應整個新 struct,比照既有 `.advancedToneCurve` 的「whole-value leaf」慣例（`AdjustmentPatch.scalarValue(for:)` 對這類 leaf 回傳 `nil`,`contains` 另外特判)。

理由：這四組新調整在使用者心智模型上都是「一整組設定」（一次選定的 creative profile、一次選定的鏡頭校正模式與其對應參數、一次配置好的三區色彩分級、一次配置好的 8 色黑白混色),不像 Basic 滑桿或 HSL 8 band 有「使用者常常只想複製其中一個滑桿」的既有先例,也不像 Presence 三個欄位需要逐一原生對應到 Adobe scalar property。逐欄位 field ID 對這四組沒有額外使用者價值,卻讓 `AdjustmentPatchBuilder`、`PhotoAdjustmentsFieldAccess`、XMP export 的 switch-case 平白增加大量重複分支,提高日後維護與出錯成本。這符合設計規格 §6.3「所有新欄位加入...stable field ID」的字面要求——whole-value leaf 本身就是一個 stable field ID,規格並未要求逐 slider 拆分。

- `AdjustmentPatch` 新增：`presence: PresencePatch?`（`texture`／`clarity`／`dehaze` 三個 optional Double,比照既有 `SplitToningPatch` 慣例)、`colorGrading: ColorGradingAdjustments?`／`monochrome: MonochromeAdjustments?`／`renderingProfile: RenderingProfileSelection?`／`lensCorrection: LensCorrectionAdjustments?`（比照既有 `advancedToneCurve: AdvancedToneCurve?` 的 optional-whole-value 慣例)。
- XMP：只原生對應 `crs:Texture`／`crs:Clarity2012`／`crs:Dehaze`（§1 第 5 點,透過既有 `XMPMappingRegistry` scalar mapping)。ColorGrading／Monochrome／RenderingProfile／LensCorrection 一律 preserved-only,不新增原生 mapping。

## 8. UI（Mac／iPad 共用,透過 P2 `InspectorCatalog`）

`InspectorCatalog` 新增兩個 section：`presence`（併入既有 `.detail` section? 不——`.detail` 目前只有 sharpening/noiseReduction,語意上 Presence 更接近全域 tone,新增獨立 section `presence`,`titleKey="Presence"`)與 `colorGrading`（獨立於既有 `hsl`,`titleKey="Color Grading"`)。`monochrome` 併入 `hsl` section 的同一個 disclosure group（因為兩者互斥式共用「顏色」語意,B&W 開關時 HSL 直觀上該視覺上一起呈現,同一個 group 內用一個 toggle 分隔),`lensCorrection` 併入既有 `geometry` section（鏡頭校正在使用者心智模型上更接近「修正相機/鏡頭造成的幾何與失光問題」,與既有透視/裁切同一個群組),`renderingProfile` 併入 `basic` section 最上方（作為「起點濾鏡」的心智位置,與其他 8 個 section 一致不新增獨立 section 保持 catalog 精簡)。

`InspectorSectionID` 因此只新增兩個 case：`presence`、`colorGrading`。八語 `Localizable.strings` 新增本階段所有面板需要的字串（Texture/Clarity/Dehaze/Shadows/Midtones/Highlights/Global/Balance/Blending/Black & White/8 色名稱沿用既有 HSL 面板已有的 Red/Orange/Yellow/Green/Aqua/Blue/Purple/Magenta key、Lens Correction/Automatic/Manual/Bundled Profile/Off/Distortion/Vignetting/Chromatic Aberration/Rendering Profile/Standard/Vivid/Flat/Portrait/No Matching Profile)。

## 9. 測試計畫（最低新增數）

| 層級 | 內容 |
| --- | --- |
| Model unit | 5 個新 struct 的 neutral/clamp/identity/JSON round-trip/缺 key 退化,`LensCorrectionMode` |
| Render unit | Presence 3 個方向測試、Color Grading 3-zone + balance + blending、Monochrome 8-band 方向測試（含停用時保留彩色)、Rendering Profile 4 個內建 profile 的方向測試、Lens distortion/vignetting/TCA 方向測試、Automatic 模式對 `CIRAWFilter` 屬性設定的分支測試（不需要真實 RAW,測 `CoreImageRawDecoder` 的邏輯分支/mode 傳遞) |
| Preset/XMP | 新 field ID round-trip、Texture/Clarity/Dehaze 原生 XMP mapping、其餘新欄位的「未知 property 保留」回歸測試 |
| UI contract | 新 catalog section、8 語 key parity |

## 10. 驗收條件（對應 §11.2 第 9、10 條）

1. Lens automatic／bundled profile（空資料庫,永遠回退)／manual／off 四種模式可辨識,不重複套用（同時只有一種校正路徑生效)。
2. 每個新 global adjustment 具備 neutral、精確輸入、reset、undo、Preset、batch 與 export 行為。
3. `swift test`、strict-concurrency build、iPad Simulator build 全部 PASS,執行測試數不得為 0。
4. 8 語 `Localizable.strings` 新字串通過既有 `LocalizationKeyParityContractTests`。
5. 隱私掃描 PASS。

## 11. Rollback

單一實作 commit;回退即完整回到 P3 baseline（新欄位皆有 neutral default,不影響既有 curve/curation/catalog)。

## 12. Handoff

完成後於 `docs/coordination/2026-09-10-p4-lens-presence-color-grading-handoff.md` 記錄,下一步指向 P5。
