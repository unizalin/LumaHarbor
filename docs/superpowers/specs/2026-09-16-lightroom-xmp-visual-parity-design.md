# Lightroom XMP 視覺還原與廣泛相容設計

日期：2026-09-16

狀態：已確認設計範圍，尚未開始實作

基準版本：`0ebb01f504711d2f47e51bc9cb98b01af3e634f9`

相關文件：

- `docs/superpowers/specs/2026-08-21-preset-xmp-compatibility-design.md`
- `docs/superpowers/specs/2026-09-10-per-channel-tone-curves.md`
- `docs/testing/reports/2026-08-21-preset-xmp-phase1.md`

## 1. 背景

LumaHarbor 已能在 macOS 與 iPadOS 匯入 Lightroom／Adobe Camera Raw 的開發預設 XMP，套用目前已映射的調整，並在再次匯出時保存未支援的 RDF property。2026-09-16 以五份真實 Lightroom XMP 驗證後，解析、Preset preview／commit、未知欄位保存與語意 round-trip 均通過；限定式巢狀 RDF 反覆匯出會增加 `rdf:value` 層級的缺陷亦已修正。

目前的「檔案相容」不等於「畫面相容」。五份實檔各有 66–69 個較新 Adobe property 只被保存，部分 property 對應到 LumaHarbor 已存在但尚未接入 XMP 的模型，另一些依賴 Adobe 專有 Profile、點顏色、AI 遮罩或鏡頭模糊演算法。若只以成功解析、沒有警告或 round-trip 無遺失作為完成條件，使用者仍可能得到和 Lightroom 明顯不同的畫面。

本設計在既有 XMP 相容層上新增兩個連續目標：

1. 讓五份實際 XMP 在 Mac 與 iPad 上都能產生高度接近 Lightroom 的可用結果。
2. 把相同架構擴充為一般 Lightroom／Camera Raw 標準開發預設的廣泛相容層。

## 2. 產品目標

### 2.1 第一階段：五份實檔高度還原

- 五份使用者提供的 XMP 均可在 Mac 與 iPad 匯入、預覽、確認、套用及再次匯出。
- XMP 中影響視覺、且能以公開語意可靠實作的欄位，必須真正進入 render pipeline，不得只存在 model 或匯入摘要。
- 同一 XMP、同一 RAW、同一 LumaHarbor 版本在 Mac 與 iPad 得到相同的調整資料與等價輸出。
- 與 Lightroom 的差異以參考輸出、客觀量測及人工目視共同驗收，不以參數名稱相同推定效果相同。

### 2.2 第二階段：廣泛標準相容

- 將 Process 2012 家族中有公開、穩定語意的常用 Camera Raw 欄位納入版本化能力清單。
- 新 XMP 即使包含未知或未支援欄位，仍可安全匯入；UI 必須清楚顯示哪些已套用、哪些為近似、哪些只保存。
- 新增欄位不得破壞既有 `.lhpreset`、照片 sidecar 或已匯入 XMP 的解碼。
- 後續擴充不需在 Mac 與 iPad 各維護一套映射或渲染邏輯。

## 3. 非目標

- 不承諾與 Lightroom／Camera Raw 逐像素一致。RAW 解碼、demosaic、色彩科學、降噪與局部演算法不同，不能把像素相同當成誠實可達的產品承諾。
- 不逆向破解 Adobe 的專有 Profile、AI 模型、`CompressedSettings` 或未公開資料格式。
- 不宣稱所有 Lightroom 功能均可編輯；不能可靠實作的 property 必須保留並明確標示。
- 不解析 `.lrcat` catalog，不搬移 Lightroom 歷史記錄、virtual copy 或雲端資料。
- 本設計不取代既有照片 XMP sidecar 搬家規格；開發預設與照片 sidecar 可共用能力清單，但仍是不同工作流程。
- 不因追求 Lightroom 相似度而讓 LumaHarbor 原生 Preset 依賴 Adobe 軟體或網路服務。

## 4. 相容性的四個層次

匯入成功不得再被籠統稱為「完全支援」。每個 property 或複合功能都必須具備下列狀態之一：

| 狀態 | 定義 | UI 行為 |
| --- | --- | --- |
| `native` | 語意可可靠轉換；可編輯、渲染、反向輸出 | 顯示為已套用 |
| `approximate` | 可套用，但 LumaHarbor 演算法與 Adobe 不同；具參考圖容差測試 | 顯示為近似套用，可於確認前取消 |
| `preserved` | property 與完整 RDF 結構被保存，但不進入 render state | 顯示為已保存、未套用 |
| `rejected` | 檔案不安全、格式損壞或超過限制，無法可靠保存 | 阻止該檔匯入並提供原因 |

一個欄位只有同時具備以下證據，才可從 `preserved` 升級為 `native` 或 `approximate`：

1. 已定義的 XMP 語意與 Process Version 範圍。
2. 可向後相容的 LumaHarbor model／patch 表示。
3. 實際被 preview 與 full-resolution export 共用的 renderer 讀取。
4. importer 與 exporter 的雙向轉換，或明確標示單向限制。
5. 數值、語意 round-trip、渲染及跨平台測試。

只有 model、UI 控制項或 mapping table 任一單項存在，都不得宣稱已支援。

## 5. 五份實檔所需能力

私有原始 XMP 不加入 repository，規格與測試報告以 `fixture-a` 至 `fixture-e` 代稱。檔名、私人絕對路徑、完整 packet 與個人 metadata 不得寫入 Git。

### 5.1 已有映射，需重新校正視覺容差

| 類別 | Camera Raw property | 目標狀態 |
| --- | --- | --- |
| 基本調整 | `Exposure2012`、`Temperature`、`Tint`、`Contrast2012`、`Highlights2012`、`Shadows2012`、`Whites2012`、`Blacks2012`、`Vibrance`、`Saturation` | 曝光、白平衡、自然飽和度與飽和度維持 `native`；tone recovery 維持 `approximate`，以參考圖校正 |
| Presence | `Texture`、`Clarity2012`、`Dehaze` | `approximate`，不得因數值範圍相同改列 `native` |
| HSL | 八色 Hue／Saturation／Luminance | `native` 資料語意；渲染仍須通過色票與實照驗收 |
| 曲線 | `ToneCurvePV2012` 與 Red／Green／Blue | `native`；四條曲線獨立往返與渲染 |
| Split Toning | Shadow／Highlight Hue、Saturation、Balance | 維持相容，並定義與新 Color Grading 同時存在時的優先序 |
| Detail | `Sharpness`、`SharpenRadius` | `approximate` |
| Effects | Post Crop Vignette、Grain Amount／Size／Frequency | `approximate` |

### 5.2 LumaHarbor 已有相關模型，但 XMP 尚未完整接通

| 類別 | Camera Raw property | 要求 |
| --- | --- | --- |
| 黑白 | `ConvertToGrayscale`、八色 `GrayMixer*` | 接到 `MonochromeAdjustments`；關閉時不得套用灰階 mixer；開啟時保留八色權重 |
| Color Grading | Shadows／Midtones／Highlights／Global 的 Hue、Saturation、Luminance，以及 Blending／Balance | 接到 `ColorGradingAdjustments`；舊 Split Toning 與新 Color Grading 必須有確定優先序，不可重複上色 |
| 鏡頭修正 | `AutoLateralCA`、`LensProfileEnable`、`LensProfileSetup`、`LensManualDistortionAmount` | 能可靠交給 decoder 的部分列 `native` 或 `approximate`；缺少鏡頭 profile 時降級並顯示診斷 |
| 細節 | `SharpenDetail`、`SharpenEdgeMasking`、luminance／color noise reduction 欄位 | 只有 renderer 確實獨立使用每個控制後才能升級；沿用單一平均 filter 不算完整支援 |
| Rendering Profile | `CameraProfile`、`Look` | 只能在已建立、可驗證的 profile 對照表中映射；無對照時保持 `preserved` |

### 5.3 需要新增或擴充模型與 renderer

| 類別 | Camera Raw property | 初始策略 |
| --- | --- | --- |
| Calibration | `RedHue`／`RedSaturation`、`GreenHue`／`GreenSaturation`、`BlueHue`／`BlueSaturation`、`ShadowTint` | 新增版本化 calibration model；先以 `approximate` 交付並用標準色票校正 |
| Parametric Curve | `ParametricShadows`／`Darks`／`Lights`／`Highlights` 與三個 split | 新增獨立模型，不能把四個區域值粗略塞進 point curve；確定合成順序後才套用 |
| Defringe | Purple／Green Amount 與 Hue Lo／Hi | 新增色邊偵測／抑制階段；沒有 hue-window renderer 前保持 `preserved` |
| Point Color | `PointColors`、`ColorVariance`、`CurveRefineSaturation` | 需要能保存多個控制點的結構化模型；不得把它降格成八色 HSL |

### 5.4 預設只保存

下列資料在沒有公開且可驗證的等價實作前維持 `preserved`：

- `FilterList`、`CompressedSettings` 以及其內含的 AI／subject／sky／object mask。
- `LensBlur`、Bokeh shape、Cat Eye、Focal Range 與深度相關資料。
- Adobe 專有 Camera Profile digest、`Table_*`、Look table 與無可驗證對照的 Profile。
- 參考影像區域、內部 bounds、排序、相容版本及 Adobe UI metadata。
- 未知 namespace、未知 Process Version 或未列入能力清單的新 property。

這些 property 必須繼續通過語意 round-trip，不可因未渲染而被刪除、攤平或改變陣列／structure／qualifier 結構。

## 6. 架構設計

### 6.1 單一能力清單

在 `PresetCore` 建立版本化的 capability manifest，取代「mapping table 中有名字就算支援」的隱含判斷。每一項至少記錄：

```swift
public struct XMPFeatureCapability: Sendable {
    public var propertyIDs: Set<XMPPropertyID>
    public var processVersionFamily: XMPProcessVersionFamily
    public var feature: XMPFeatureID
    public var level: XMPCompatibilityLevel
    public var direction: XMPMappingDirection
    public var rendererEvidenceID: String?
}
```

- scalar property 可繼續使用 `XMPMappingRegistry`。
- 黑白、Color Grading、Point Color、Parametric Curve 等複合功能由 feature converter 一次讀寫，避免拆成互相矛盾的 scalar。
- importer 摘要、exporter 警告、測試矩陣與 UI badge 都讀同一份 capability manifest。
- manifest 的狀態變更屬相容性變更，必須附測試與文件，不得只改 enum 值。

### 6.2 依賴與共用

既有依賴方向維持不變：

```text
RawProcessingCore
       ↑
  PresetCore
       ↑
PhotoLibraryCore
       ↑
 Mac / iPad UI
```

- `RawProcessingCore` 持有可渲染 model 與跨平台 renderer，不知道 XMP。
- `PresetCore` 負責 XMP property graph、能力清單與 model converter，不知道 SwiftUI。
- Mac 與 iPad 只能提供不同容器與檔案選擇流程，不得複製 mapping 或效果演算法。

### 6.3 Render pipeline 順序

實作前必須把新增階段加入一份可測試的順序契約。建議順序如下：

1. RAW decode、decoder 可原生處理的鏡頭修正與白平衡。
2. 幾何與手動鏡頭失真。
3. Calibration／Rendering Profile。
4. 基本曝光與 tone recovery。
5. Parametric Curve，再合成 Composite 與 RGB point curves。
6. Presence。
7. HSL／Point Color。
8. Monochrome mixer。黑白模式必須先完成各色帶對灰階亮度的混合。
9. Color Grading 或舊 Split Toning。此階段放在 Monochrome 之後，讓黑白 Preset 仍可保留分色調／色彩分級的染色效果。
10. Sharpening、Noise Reduction、Defringe。
11. Vignette、Grain 與其他效果。
12. Local Adjustments、輸出 resize 與色彩空間轉換依既有契約處理。

若 Adobe 實測顯示某效果的順序需要調整，必須以 reference corpus 與回歸測試修改，不得只靠目視猜測。舊 Split Toning 與新 Color Grading 同時存在時，以 XMP 中較新的 Color Grading feature 為主；舊欄位仍保存，除非 Adobe 實檔證明兩者會共同生效。

### 6.4 Preset schema 與遷移

- 新 model 欄位使用缺省值解碼，舊 `.lhpreset` 與照片 sidecar 缺少 key 時等同 neutral。
- 只有 schema 形狀或語意不向後相容時才提高 `PresetDocument.currentSchemaVersion`。
- importer 不可只保存 clamp 後的值；原始 XMP packet 仍是超範圍值與未知資料的 round-trip 來源。
- `merge` 與 `replace` 保持既有語意；複合 feature 必須能區分「未出現」與「明確設為 neutral」。

## 7. 匯入與跨平台 UI

Mac 與 iPad 使用同一份 `XMPImportPreview`，匯入確認畫面至少顯示：

- 預設名稱與來源。
- 原生套用、近似套用、只保存、拒絕的 feature 數量。
- 近似或只保存的功能名稱，例如「Camera Profile：已保存，未套用」。
- 若缺少參考 Profile、鏡頭資料或白平衡 baseline，顯示具體限制而不是泛稱「部分不相容」。
- 使用者可取消 `approximate` feature；`preserved` feature 不得偽裝成可勾選套用。

iPad Files picker 與 Mac open panel 只負責取得 security-scoped URL；後續 parse、preview、commit 與錯誤分類完全共用。兩平台匯入同一檔案後，Preset patch、diagnostics、capability counts 與重新匯出的 XMP 語意必須一致。

## 8. 視覺參考與驗收素材

### 8.1 必要素材

第一階段開始實作前，需準備：

- 至少三張可合法測試的 RAW：日光人像／膚色、室內高反差、夜景或高 ISO。
- 五份私有 XMP。
- 每一組 RAW 在 Lightroom 的 neutral 參考輸出。
- 同一 RAW 套用每份 XMP 後的 Lightroom 參考輸出。
- Lightroom 的版本、Process Version、Profile 名稱、輸出尺寸與色彩空間紀錄。

參考輸出統一使用原尺寸、16-bit TIFF、sRGB、無 resize、無輸出銳化、無浮水印。LumaHarbor 以相同尺寸與 sRGB 產生 TIFF。若 Lightroom 不能輸出完全相同設定，報告必須列出差異。

### 8.2 私有素材規則

- 私有 XMP、RAW 與 Lightroom 輸出以環境變數或 ignored fixture directory 注入，不加入 Git。
- repository 只保留去識別化、人工重建的最小 XMP fixture，以及不含私人影像的合成色票。
- CI 沒有私有素材時，私有 corpus 測試必須明確 `SKIPPED`；不可把沒跑寫成 `PASS`。

## 9. 視覺相似度定義

不同 RAW decoder 的 neutral 畫面本來就可能不同，因此不能只直接比較 Lightroom 與 LumaHarbor 最終像素。驗收同時使用絕對輸出與「Preset 相對 neutral 所造成的變化」。

每個 reference case 產生四張圖：

- `LR-neutral`
- `LR-preset`
- `LH-neutral`
- `LH-preset`

自動比較項目：

1. **幾何與尺寸**：方向、裁切與輸出尺寸一致，否則該 case 直接失敗。
2. **效果方向**：曝光、對比、彩度、黑白轉換、色相與曲線的變化方向必須一致；任何主要控制方向相反直接失敗。
3. **相對效果場**：在 linear sRGB 計算 `(preset - neutral)`；LumaHarbor 與 Lightroom 的效果場平均絕對誤差目標不高於 `0.04`，第 95 百分位不高於 `0.12`。
4. **結構保留**：以 neutral 正規化後的 luminance effect field 計算 SSIM，目標至少 `0.95`，避免把兩套 RAW decoder 原本的基準差異誤判為 Preset 缺陷。對 Grain、Sharpening、Noise Reduction 另使用固定 crop 的頻域／edge metric，不以 SSIM 單獨判定。
5. **色彩**：24 色合成色票或實拍色卡的平均 `ΔE00` 目標不高於 `4.0`，第 95 百分位不高於 `10.0`；Profile 只能近似的 case 可另列已核准例外，但不能併入通過數字。

上述數值是第一輪工程門檻。P0 baseline 建立後若證明某門檻受 decoder 固有差異支配，可調整一次；調整必須附量測報告並同步更新本規格，不得在實作完成後為了讓測試通過而臨時放寬。

### 9.1 人工目視門檻

每份 XMP 至少由一名未參與該效果實作的人員，在同一校色顯示器、100% 與 fit-to-window 各檢查一次：

- 不得出現黑白／彩色模式錯誤、主要色偏、tone curve 方向錯誤、過曝／死黑區域明顯增加或局部結構破壞。
- 允許 Adobe Profile 或專有演算法造成可辨識但已標示的細微差異。
- 只要使用者會合理認為「這不是同一個 Preset」，即使數值門檻通過仍判為失敗。

## 10. 測試策略

### 10.1 Codec 與映射

- 每個新增 scalar 與複合 feature 的 import、export、round-trip、缺值、超範圍、非有限值及錯誤隔離測試。
- 未知 property、array、structure、qualifier 與限定式 `rdf:parseType="Resource"` 連續三次 round-trip 仍語意相等。
- Process Version 未辨識時全部保存、不猜測套用。
- 同時包含 legacy 與 current property 時有固定優先序並輸出 diagnostic。

### 10.2 Model 與 renderer

- neutral 必須是 no-op。
- 每個控制最小值、中點、最大值與代表性負值／正值都有 deterministic pixel test。
- preview 與 full-resolution export 走相同效果邏輯；半徑型效果依既有 scale contract 調整。
- 黑白、Color Grading、Calibration、Parametric Curve 與 Point Color 各自具獨立 fixture，避免只由五份實檔間接覆蓋。
- 性能回歸門檻：在既有標準 RAW corpus 上，新增所有啟用效果後的 preview P95 不得比基準慢超過 20%；單一未啟用 feature 不得增加可量測的 renderer 成本。

### 10.3 工作流程

- Mac 與 iPad 匯入同一 XMP 得到相同 patch、diagnostics 與相容性摘要。
- preview 不寫入 history／sidecar；commit 只形成一筆 Undo。
- app 重開後 Preset 與照片調整結果一致。
- batch、copy/paste、export 與單張套用使用同一份完整調整資料。
- iPad 直向、橫向、Split View 與 Mac 窄／寬 Inspector 均能看完相容性摘要，不遮住必要確認按鈕。

### 10.4 真實 Adobe smoke test

每一交付階段至少執行：

1. Lightroom 匯出 XMP → LumaHarbor 匯入與套用。
2. LumaHarbor 匯出 XMP → Lightroom 匯入，確認 Adobe 可接受格式。
3. Lightroom → LumaHarbor → Lightroom 語意 round-trip，確認未知 property 未遺失。
4. 五份 XMP 與 reference RAW 的視覺矩陣。

Lightroom 未實際執行的項目只能標為 `NOT RUN`，不得以 parser unit test 代替。

## 11. 分階段交付

### P0：基準、能力清單與驗收工具

- 建立 capability manifest 與支援矩陣報告。
- 建立私有 fixture 注入方式、去識別化 fixture 與 reference comparison 工具。
- 鎖定五份 XMP 在目前版本的 native／approximate／preserved 基準。
- 產生 Lightroom neutral／preset 參考輸出；沒有參考輸出前不得宣稱視覺高度還原。

### P1：接通現有模型

- 黑白與八色 mixer。
- Color Grading，並解決 Split Toning 優先序。
- Lens correction 可可靠映射的部分。
- 獨立 Sharpening／Noise Reduction 控制；renderer 沒有使用的欄位繼續保存。
- 五份 XMP 的 applicability count、畫面及跨平台一致性不得退化。

### P2：常用標準欄位擴充

- Calibration。
- Parametric Curve。
- Defringe。
- Profile 對照與明確 fallback。
- 完成常用 Process 2012 Camera Raw 標準欄位矩陣，不以五份 XMP 是否剛好包含作為唯一範圍。

### P3：進階顏色與視覺校正

- Point Color／Color Variance／Curve Refine Saturation。
- 依 reference corpus 校正 approximate converter 與 render parameters。
- 五份 XMP 全矩陣達成本規格第 9 節門檻，並完成 Mac／iPad 人工驗收。

### P4：後續廣泛相容

- 依真實使用者 corpus 新增 Process Version family 與標準 property。
- Lens Blur、AI masks、專有 Profile 等仍採獨立設計與授權評估；不得因本階段名稱為「廣泛相容」自動納入。

每一階段可獨立提交與回退；不得以一次大型重寫替換現有 XMP codec、Preset workflow 與 render pipeline。

## 12. 完成條件

### 12.1 第一階段完成

- 五份私有 XMP 全部成功匯入，零 crash、零資料結構遺失。
- 所有列為 `native`／`approximate` 的 feature 都有 model、renderer、匯入、匯出及測試證據。
- 五份 XMP × 至少三張 RAW 的 reference matrix 符合第 9 節自動與人工門檻；核准例外逐項列出，不得只寫整體通過。
- Mac 與 iPad 的 patch、diagnostics、Preset 套用、重新啟動與 full export 結果一致。
- 實體 iPad 直向、橫向與 Split View 完成人工匯入、套用、Undo、重開驗證。

### 12.2 第二階段完成

- capability manifest 列出的常用 Process 2012 標準功能均有支援狀態與測試證據，沒有「未知但顯示已套用」的情況。
- 新增至少一組不屬於原五份 XMP 的外部標準 corpus，證明架構不是只對五個檔案特判。
- 未支援或專有 property 保持語意 round-trip，並在 Mac／iPad UI 顯示具體限制。
- 完整 strict-concurrency build／test、Mac build、iPad generic build、實體 iPad build／install／launch 與 Adobe smoke test 均有紀錄。
- `git diff --check`、隱私掃描與 private fixture exclusion 全部通過。

## 13. 風險與緩解

| 風險 | 緩解方式 |
| --- | --- |
| Adobe 與 LumaHarbor RAW baseline 不同，視覺比較失真 | 同時比較 neutral 與 preset，使用相對效果場與人工審查 |
| 名稱相似但語意不同 | 沒有公開語意與 reference evidence 就維持 `preserved` |
| 為五份 XMP 特判 | 以 feature capability 與額外 corpus 驗證，不以檔名或 UUID 分支 |
| 新 model 破壞舊 sidecar | 缺 key 解碼為 neutral、加入舊 schema fixture 回歸測試 |
| Profile／AI 功能無法等價 | 明確保存與揭露，不假裝套用；另立後續設計 |
| approximate 門檻被任意放寬 | P0 鎖定基準；門檻修改必須附報告並更新規格 |
| Mac 與 iPad 行為漂移 | 核心 mapping／renderer 共用，跨平台 contract test 比對同一 patch 與輸出 |

## 14. 第一個實作計畫的邊界

本規格核准後，第一份 implementation plan 只涵蓋 P0：

- capability manifest；
- 私有 fixture 注入與去識別化測試資料；
- Lightroom reference matrix 格式；
- 視覺比較工具與目前支援基準報告。

P0 不改變任何照片渲染結果。P1 之後每一個功能群組都必須在 P0 證據上另行規劃、實作與驗收，避免一次改動過多效果而無法定位視覺偏差。
