# Lightroom 相容 Neutral RAW Baseline v1 規格

- 狀態：已確認，implementation plan 已建立，待實作
- 日期：2026-09-19
- 範圍：`C0` Neutral RAW／Profile baseline
- 上位規格：`docs/superpowers/specs/2026-09-18-lightroom-xmp-rendering-parity-recovery.md`
- 驗測契約：`docs/testing/lightroom-xmp-reference-matrix.md`
- 目前證據：`docs/testing/reports/2026-09-17-lightroom-xmp-application-fix.md`

## 1. 目的

先讓同一張未調整 RAW 在 Lightroom Classic 與 LumaHarbor 之間具有可接受的一致基準，再繼續校正 XMP 的 Basic tone、Presence、Calibration、Parametric Curve 與 Detail。

目前四張 Neutral RAW 的 `neutralDirect` 全部未通過 Gate 2；512 px smoke comparison 平均 Mean 為 `0.069503`、P95 為 `0.279412`、SSIM 為 `0.536303`。這表示差異已存在於 XMP 套用之前，不能再以曝光、對比、曲線或其他 preset slider 補償。

本規格只取代上位規格中 C0／Gate 2 的實作細節，不取代 XMP 保存、effect comparison、final comparison、Detail、人工目視與跨平台契約。

## 2. 已確認的現況

1. `RawRenderingCompatibility` 已可由 Adobe XMP 傳入 preview 與 full export，但 `CoreImageRawDecoder` 尚未依該值改變任何解碼設定。
2. `CoreImageRawDecoder` 目前使用每台系統的最新預設 decoder version，並保留 `CIRAWFilter` 對 tone boost、shadow boost、noise reduction、sharpness、detail、local tone map、gamut mapping 等項目的影像預設值。
3. As Shot 白平衡由 `CIRAWFilter.neutralTemperature`／`neutralTint` 取得並套用，方向正確，但目前沒有保存可稽核的來源、實際值與 fallback 狀態。
4. `ImageRenderService` 的工作色域是 `extendedLinearSRGB`；它在 pipeline 完成前已限制為 sRGB primaries，不適合作為 Lightroom／ProPhoto 類來源的長期相容工作空間。
5. `AdobeProfileRegistry` 只辨識 `Adobe Standard` 與 `Adobe Color`，目前均為 `preserved`，沒有 renderer 可使用的 fallback。
6. `PhotoAdjustments.isNeutral` 直接比較整個 value；若把 RAW 顯色政策當成預設基準，可能把「未調整」誤判為「有編輯」。
7. Mac library 沒有 sidecar 時回傳 `.neutral`；iPad document store 也相同，因此新舊照片目前都落在 `.native`。

## 3. 使用者目標

### 3.1 必須達成

- 新匯入的 RAW 在沒有任何調整或 XMP 時，就使用版本化的 Lightroom 相容 neutral baseline。
- 套用舊 Lightroom XMP 時，不需要先手動補曝光、白平衡、Profile 或輸出色彩設定。
- Preview、full export、single export、batch export、Mac 與 iPad 使用同一份 resolved render recipe。
- 既有照片預設維持目前外觀；只有明確套用 Adobe XMP 或使用者主動升級顯色版本時才切換。
- 每次輸出都能說明實際 decoder、As Shot 白平衡、Profile／fallback、工作色域與 output transform。

### 3.2 本輪非目標

- 不校正 Process 2012 的 Contrast、Highlights、Shadows、Whites、Blacks。
- 不校正 Texture、Clarity、Dehaze、Calibration、Parametric Curve 或 Detail 子控制。
- 不逆向、內嵌或散布 Adobe DCP、digest、`Table_*`、Look table 或其他專有資產。
- 不承諾所有相機與所有 Lightroom Profile 立即等價；v1 先讓 reference corpus 的相機／Profile 通過 Gate 2，再以 registry 擴充。
- 不改變 JPEG、PNG、TIFF 等已解碼影像的顯色行為。

## 4. 核心產品契約

### 4.1 顯色政策

`RawRenderingCompatibility` 必須成為真正有行為的版本化契約：

| 情境 | 顯色政策 |
| --- | --- |
| 舊 sidecar 缺少相容欄位 | `native`，外觀不變 |
| 舊 catalog／document record 缺少預設值 | `native`，外觀不變 |
| 功能上線後新匯入／新發現的 RAW | `adobeProcess2012V1` |
| Adobe XMP preview／commit | `adobeProcess2012V1`；Undo 還原套用前政策 |
| 非 RAW 檔案 | `native` |
| Unknown Adobe Profile | 保持 `adobeProcess2012V1`，使用明確 neutral fallback 並顯示 `profilePreservedNotApplied` |

Swift case 可改名為 `adobeProcess2012V1`，但已存在的 wire value `"adobeProcess2012"` 必須繼續解碼。未來任何會改變像素的 policy 必須新增版本，不得在同一版本內靜默改寫。

### 4.2 新舊照片邊界

- Mac `PhotoRecord` 新增可選的預設顯色政策；缺值代表 legacy native，新建立 record 寫入 `adobeProcess2012V1`。
- iPad `PhotoDocumentRecord` 使用相同規則；缺值代表 legacy native，新建立 document 寫入 `adobeProcess2012V1`。
- 有 sidecar 時，以 sidecar 中的政策為準；沒有 sidecar 時，以 catalog／document record 的預設值建立 runtime neutral adjustments。
- 升級時先把既有 record 視為／回填為 `native`，再切換新 record 的預設值。Migration 必須可重跑、不可部分改變照片外觀。
- 離線、唯讀或無法完成 migration 的 library 保持 `native`，不得只升級部分照片。
- Virtual copy、copy/paste、batch apply 與 duplicate 必須明確繼承來源政策。

### 4.3 Neutral 與「有編輯」必須分離

- `rawRenderingCompatibility` 參與 render cache key、Undo、sidecar round-trip 與 equality。
- 「是否有使用者調整」不可再由 `PhotoAdjustments == .neutral` 推導；必須使用忽略 baseline policy 的明確判斷。
- 新照片使用 `adobeProcess2012V1` 時仍顯示未調整，不建立假的 edit badge、history 或 dirty state。
- Reset All 回到該照片的預設顯色政策，而不是無條件回到 `.native`。

## 5. Resolved Raw Render Recipe

新增一個 plain-value、`Codable`、`Equatable`、`Hashable`、`Sendable` 的 resolved recipe，由 preview 與 export 共用。至少包含：

- policy ID／version。
- decoder kind、requested decoder version、resolved decoder version。
- orientation。
- decode quality 與 scale factor。
- As Shot white-balance source、temperature、tint；若 fallback，需記錄原因。
- lens correction mode 與實際是否啟用。
- requested Camera Profile name。
- resolved fallback profile ID／version／compatibility level。
- decoder option vector ID／version。
- working color-space ID／version。
- output transform ID／version。
- diagnostics。

同一張照片、同一份 adjustments 與同一品質設定必須產生相同 recipe。Recipe 是 render cache key 的一部分；任何欄位改變都不得重用舊 preview。

`DecodedRawImage` 必須回傳實際 decode provenance，不能只回傳 CIImage 與兩個白平衡數值。若 requested 與 resolved 值不同，必須可在診斷與測試中看見。

## 6. Deterministic Core Image RAW Policy

### 6.1 Decoder version

- `native` 保持目前 system-default 行為。
- `adobeProcess2012V1` 不得只依賴「目前作業系統最新版本」。實作階段需為 reference camera 鎖定可在支援的 Mac／iPad OS 共用的 decoder version。
- 若固定版本不支援該 RAW，才可退回 system-default，並輸出 `rawDecoderVersionFallback`；該 case 不得算作正式 Gate 2 PASS，除非 reference report 核准該 fallback。
- OS 更新造成 resolved decoder version 或像素改變時，視為 renderer compatibility change，需重新跑 Gate 2。

### 6.2 Option vector

`adobeProcess2012V1` 必須明確設定、記錄並測試下列 `CIRAWFilter` 參數，不得接受 per-image 預設值後又宣稱 deterministic：

- `exposure`
- `baselineExposure`
- `shadowBias`
- `boostAmount`
- `boostShadowAmount`
- `isGamutMappingEnabled`
- `luminanceNoiseReductionAmount`
- `colorNoiseReductionAmount`
- `sharpnessAmount`
- `contrastAmount`
- `detailAmount`
- `moireReductionAmount`
- `localToneMapAmount`
- `extendedDynamicRangeAmount`
- 支援平台上的 `isHighlightRecoveryEnabled`

初始校正原則是關閉 decoder 內不可觀測的創意 tone／detail 增強，將 tone、Profile 與 Detail 留給可版本化的 LumaHarbor stage。`baselineExposure`、EDR、highlight recovery 與 gamut mapping 的最終值必須由四張 neutral reference 的消融測試鎖定；一旦通過 Gate 2，整組值以單一 `decoderOptionVectorID` 固定。

### 6.3 Orientation、lens 與白平衡

- 明確由 metadata 設定 TIFF orientation，不依賴 filter 的隱含預設。
- Neutral reference 使用 As Shot 白平衡；不允許在 decode 後再用 `CITemperatureAndTint` 補償。
- 白平衡 offset 仍相對於 decoder 回報的 baseline，避免改變既有 slider 單位。
- Adobe policy 的 neutral lens 行為必須與 reference metadata 一致；使用 automatic 時要記錄 supported／enabled 結果。
- 溫度、tint、orientation 或 lens metadata 缺失時不得 crash；使用固定 fallback diagnostic，該 case 不得默默算 PASS。

## 7. Working Space 與 Output Transform

- `native` 繼續使用既有 `extendedLinearSRGB`，避免舊照片外觀改變。
- `adobeProcess2012V1` 使用版本化的 wide-gamut linear working space；不得在 Profile／Calibration／tone stage 前限制到 sRGB primaries。
- v1 優先採公開定義、可在 Core Graphics 建立且可跨 Mac／iPad重現的 linear wide-gamut space。若使用自訂 linear ROMM／ProPhoto 定義，白點、primaries、transfer function 與 chromatic adaptation 必須由單元測試鎖定。
- 正式 reference output 統一為原尺寸、16-bit TIFF、sRGB、無 resize、無輸出銳化、無浮水印。
- Preview 與 export 可有不同位元深度與尺寸，但必須使用相同 working-space 與 output-transform ID；preview 不得另走未記錄的 display-only 色彩補償。
- ICC profile 必須正確嵌入輸出；缺少或錯誤 profile 的檔案直接 FAIL。

## 8. Adobe Profile Fallback v1

### 8.1 Registry ownership

- Profile 解析與 render mapping 移到 `RawProcessingCore` 或其他不造成依賴反轉的共用層；`PresetCore` 只負責把 XMP 名稱轉成 profile request。
- Registry entry 至少包含 source name、camera make/model match、fallback ID／version、compatibility level、provenance 與可散布授權。
- 不得以名稱相同為由，把 LumaHarbor 既有 creative profile 假裝成 Adobe Profile。

### 8.2 v1 支援範圍

- 至少辨識 `Adobe Color` 與 `Adobe Standard`。
- 對 reference corpus 中的 camera model，提供各自可驗證的 `approximate` fallback。
- Neutral Lightroom reference 使用的實際 Profile 必須寫入 matrix metadata；LumaHarbor 必須記錄對應的 resolved fallback ID。
- 對尚未校正的相機，使用 system neutral fallback、完整保存 XMP 原值並顯示 `profilePreservedNotApplied`；不得標成 approximate 或 native。

### 8.3 Fallback 資料來源

- 允許使用公開色彩標準、自有色票量測、使用者擁有的 RAW／Lightroom reference pair 產生數值矩陣或 LUT。
- 不得提交私人 RAW、Lightroom 輸出、私人路徑或 Adobe 專有 table；只提交可散布的係數、生成器、版本與去識別化證據摘要。
- 不得為單張照片加入特例。係數至少以 camera model + source profile 為單位，並以未參與擬合的 hold-out neutral reference 驗證。
- Profile stage 位於 decode／white balance 之後、Exposure／Basic tone 之前。

## 9. Preview、Export 與跨平台一致性

- `CoreImagePreviewRenderer` 與 `PhotoExporter` 不可各自解析 policy；兩者只接收同一 resolver 產生的 recipe。
- Interactive、high-quality preview 與 full export 的 decoder option vector、WB、Profile 與色彩空間必須相同；只允許 scale、draft mode 與輸出位元深度不同。
- Mac 與 iPad 對同一 RAW／adjustments 的 serialized recipe 必須相同；平台不支援項目要形成明確 diagnostic，而非靜默採不同值。
- Batch export 不得回到 `.neutral` 或 native policy；每個 target 使用自己的 persisted／resolved policy。
- Import preview 不寫 sidecar／history；commit 只形成一筆 Undo。

## 10. 診斷與產品呈現

本輪不新增另一套調整 UI。現有資訊／匯入摘要至少能顯示：

- `LumaHarbor Native` 或 `Lightroom-compatible v1`。
- As Shot white balance 是否成功。
- Requested Profile 與實際 fallback 名稱。
- `Profile 已保存，未套用`、decoder fallback 或 metadata fallback。

診斷必須使用固定 identifier，使用者文案可在地化。UI 不得只顯示原 Adobe Profile 名稱，讓使用者誤以為已原生套用。

## 11. Failure Handling 與 Rollback

- Recipe resolution 失敗時不 crash；退回該照片原本的 persisted policy，並顯示固定 diagnostic。
- 任何 neutral case 未過 Gate 2，不升級 manifest compatibility level，也不進 C1 slider 校正。
- Renderer feature flag 只控制是否使用新 stage，sidecar／record 必須在 flag 關閉時仍可解碼。
- Rollback 必須能把新照片切回 `native` 而不刪除 adjustments、XMP preservation data、history 或 originals。
- 若 migration 中斷，重新啟動後必須繼續或完整回復；不可讓同一 library 的舊照片隨機混用新舊預設。
- 若新路徑造成既有 native render hash 改變，視為 blocker。

## 12. 測試與驗收

### 12.1 Unit tests

- Policy resolution table：legacy record、新 record、sidecar override、Adobe XMP、Undo、Reset All、non-RAW。
- Codable／migration：舊 sidecar、舊 manifest、舊 iPad document record、unknown future policy。
- `hasUserEdits` 不受 baseline policy影響；equality／cache key 仍會辨識 policy 差異。
- Decoder option vector 每個欄位都有固定值、availability 與 fallback test。
- As Shot WB、orientation、lens status 與 decode provenance。
- Working／output color-space definition、ICC tag 與 render recipe round-trip。
- Profile alias、camera match、unknown profile、unknown camera、fallback provenance。

### 12.2 Integration tests

- Preview／full export 取得相同 recipe。
- Mac／iPad serialized recipe equality。
- 新 import 預設 `adobeProcess2012V1`；既有資料缺欄位仍為 `native`。
- Adobe XMP preview 不寫資料；commit 一筆 Undo；Undo 還原原政策。
- Reopen、copy/paste、virtual copy、batch export、single export 保持政策與 Profile。
- 既有 native golden render hash 不變。

### 12.3 Gate 2 正式 reference

四張 RAW 每張都以原尺寸、16-bit TIFF、sRGB、無輸出銳化執行 `neutralDirect`，每一張都必須同時達成：

- Mean absolute pixel error `<= 0.04`。
- P95 absolute pixel error `<= 0.12`。
- Luminance direct SSIM `>= 0.95`。
- Highlight／shadow clipping fraction 與 Lightroom 差異各 `<= 2` 個百分點。
- 報告包含 Lightroom version、Process Version、Profile、LumaHarbor policy、decoder version、option vector、As Shot WB、fallback profile、working space 與 output transform。

不得用四張平均值掩蓋單張失敗。缺 reference、使用縮圖、位元深度不符、ICC 不符或使用未核准 fallback 時皆為 `NOT RUN`／`FAIL`，不是 PASS。

### 12.4 跨平台與效能

- 相同 16-bit TIFF 設定下，Mac／iPad Mean `<= 0.001`、P95 `<= 0.003`，尺寸與方向完全一致。
- High-quality preview P95 相對既有 baseline 惡化 `<= 20%`。
- 四張約 7008 × 4672 RAW 可完成 full-resolution 16-bit TIFF export，不 OOM、不降尺寸。
- `swift test -Xswiftc -strict-concurrency=complete` 無新增 failure。
- macOS build、iPad generic build、實體 iPad smoke gate、`git diff --check` 與隱私掃描 PASS。
- 目前完整 suite 的 `CurationDurabilityTests` signal 11 必須另行釐清；在它被證明與本功能無關或修正前，最終 release sign-off 不得宣稱全綠。

## 13. 實作階段與停止條件

### Phase 0：基準與觀測

- 產生正式 4 張 Lightroom neutral reference 與現況 LumaHarbor output。
- 加入 decode provenance／recipe，不改像素。
- 記錄每張 RAW 的 `CIRAWFilter` default option vector，確認主要差異來源。

停止條件：reference metadata、尺寸、ICC 或 hash 不可信時不得進 Phase 1。

### Phase 1：Policy 與 migration

- 實作 v1 policy resolution、new／legacy 邊界、record persistence、neutral edit-state 語意與 Undo／Reset All。
- 此階段 native render hash 必須完全不變。

停止條件：任何既有照片被自動切換或 migration 非原子時立即回退。

### Phase 2：Deterministic decode／WB

- 鎖定 decoder version、option vector、orientation、As Shot WB 與 lens behavior。
- 每次只改一組參數並重跑四張 neutral 消融比較。

停止條件：以 per-photo 特例或 XMP slider 補償時立即停止。

### Phase 3：Wide-gamut／output transform

- 導入版本化 wide-linear working space 與共同 output transform。
- 驗證 preview／export 與 Mac／iPad recipe 一致。

停止條件：ICC 缺失、platform recipe 分歧或 native hash 改變時立即回退。

### Phase 4：Profile fallback

- 移動 registry ownership，加入 reference camera 的 Adobe Color／Adobe Standard fallback。
- 使用 hold-out case 驗證，不加入單張照片例外。

停止條件：沒有合法 provenance、unknown camera 被誤標相容，或只有 training case 改善時不得合併。

### Phase 5：正式 Gate 2

- 執行 4/4 原尺寸 16-bit neutral matrix、跨平台、效能、完整回歸與人工目視。
- 只有 Gate 2 全數通過後，才可另開 C1 Process 2012 Basic tone／Presence 開發。

## 14. 預期修改範圍

主要檔案／模組：

- `Sources/RawProcessingCore/Decoding/RawDecoding.swift`
- `Sources/RawProcessingCore/Decoding/CoreImageRawDecoder.swift`
- `Sources/RawProcessingCore/Model/PhotoAdjustments.swift`
- `Sources/RawProcessingCore/Pipeline/ImageRenderService.swift`
- `Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift`
- `Sources/RawProcessingCore/Export/PhotoExporter.swift`
- `Sources/PresetCore/XMP/AdobeProfileRegistry.swift`（移動或改為 adapter）
- `Sources/PhotoLibraryCore/Sidecar/LibraryManifest.swift`
- `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`
- `Sources/PhotoLibraryCore/Documents/PhotoDocumentStore.swift`
- 對應的 RawProcessingCore／PresetCore／PhotoLibraryCore／App contract tests。

若實作需要修改 adjustment slider mapping、Parametric Curve、Calibration、Detail、mask 或 UI panel layout，表示已超出本規格，必須停止並另開 spec。

## 15. Definition of Done

只有同時滿足以下條件才完成：

1. 新 RAW 預設使用 `adobeProcess2012V1`，既有 RAW 外觀不變。
2. Mac／iPad preview、single export 與 batch export 使用相同 resolved recipe。
3. Adobe Color／Adobe Standard 對 reference camera 有合法、可散布、可稽核的 fallback；unsupported 狀態誠實顯示。
4. 四張正式 neutral reference 全部通過 Gate 2，沒有平均值豁免。
5. Native golden hash、舊 sidecar、Undo／Reset、reopen、copy/paste、virtual copy 與 export 回歸通過。
6. 必要 build／test／真機／效能／隱私 gate 有實際證據；未執行項目維持 `NOT RUN`。
7. C1 尚未開始，沒有用 tone／Presence／curve 補償 neutral baseline。
