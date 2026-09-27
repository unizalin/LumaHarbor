# Lightroom XMP 渲染相容修復規格

- 日期：2026-09-18
- 狀態：Active，Phase A4 三層比較、Phase B renderer、C0 相容性 plumbing 與 D1 Parametric Curve approximate slice 已實作；neutral/profile gate 仍未通過
- 適用平台：macOS、iPadOS
目標 Process Version：Camera Raw Process 2012 family，首輪以 `15.4` corpus 驗證

相關文件：

- `docs/superpowers/specs/2026-09-16-lightroom-xmp-visual-parity-design.md`
- `docs/testing/lightroom-xmp-reference-matrix.md`
- `docs/testing/reports/2026-09-17-lightroom-xmp-application-fix.md`
- `docs/superpowers/specs/2026-09-10-per-channel-tone-curves.md`

## 1. 問題與證據

LumaHarbor 已能解析五份實際 Lightroom XMP，並把曝光、白平衡、HSL、point curve、黑白、Color Grading、鏡頭校正開關與部分 Detail 欄位寫入共用調整資料。私有 fixture 測試為 5/5 PASS；這證明檔案能讀入，但不代表畫面已相容。

2026-09-18 使用四張私有 ARW × 五份私有 XMP 建立 20 組 Lightroom／LumaHarbor 相對效果比較。150 × 100、8-bit sRGB 診斷矩陣結果如下：

| 指標 | 目前平均 | 設計門檻 |
| --- | ---: | ---: |
| Mean absolute effect error | 0.118019 | <= 0.04 |
| P95 absolute effect error | 0.381961 | <= 0.12 |
| Luminance effect SSIM | 0.109177 | >= 0.95 |

20/20 均未達門檻。四份含 Grain 的 XMP 暫時關閉 LumaHarbor Grain 後，Mean 從 0.123907 降至 0.097845，SSIM 從 0.073237 升至 0.229551，但仍是 0/16 通過。沒有 Grain 的 fixture 仍不通過，證明問題至少包含兩層：

1. Grain／Sharpening／Noise Reduction 在不同 decode／輸出尺寸下不一致。
2. Basic tone、Presence、Monochrome、point curve、Profile 及未實作欄位造成低頻明暗與色彩差異。

同日補做三層診斷後，確認原規格只比較 neutral-normalized effect field 不足以代表使用者看到的畫面：

| 比較層 | 案例 | Mean 平均 | P95 平均 | SSIM 平均 | 結果 |
| --- | ---: | ---: | ---: | ---: | --- |
| Neutral RAW 直接比較 | 4 | 0.056280 | 0.210784 | 0.779461 | 0/4 PASS |
| XMP 相對效果比較 | 20 | 0.118019 | 0.381961 | 0.109177 | 0/20 PASS |
| 最終成品直接比較 | 20 | 0.095714 | 0.289608 | 0.589074 | 0/20 PASS |

Neutral RAW 的四個 case 全部失敗，且 Mean 由 0.038576 到 0.073907 隨照片而變，證明問題不只在 preset converter；RAW decoder 輸出、白平衡、Camera Profile／fallback 與 baseline colour science 必須先被獨立驗收。最終成品數字使用 Phase B Grain 修正前的 LumaHarbor 診斷輸出，只用來證明 direct-final gate 的必要性，不得視為 Phase B 修正後的正式成績。

本規格承接 2026-09-16 的總體相容設計，不取代其中的 XMP 保存、安全、跨平台與非目標契約；本規格把這次實測轉成可執行的修復順序與驗收 gate。

## 2. 使用者與產品目標

### 2.1 受影響使用者

- 從 Lightroom Classic／Adobe Camera Raw 匯入 XMP preset 的 Mac 與 iPad 使用者。
- 需要在兩個平台看到一致調整結果的攝影工作流程。
- 開發與驗測人員，需要明確知道哪些欄位已套用、近似套用或僅保存。

### 2.2 目標行為

1. 同一 RAW 在未套用任何 XMP 時，Lightroom 和 LumaHarbor 的方向、白平衡、基礎明暗與色彩先通過 neutral baseline gate。
2. 同一 RAW 與 XMP 在 Lightroom 和 LumaHarbor 產生方向一致、視覺上可辨認為同一 preset 的結果。
3. Preview、100% 檢視與 full-resolution export 的 Grain、Sharpening、Noise Reduction 不因 decode 尺寸而改變可見尺度或強度。
4. 五份 corpus 中會實際影響畫面的公開標準欄位，依本規格分階段進入 renderer。
5. Mac 與 iPad 使用同一份 model、XMP converter、render order 與 capability manifest。
6. 無法合法或可靠重現的 Adobe Profile／Look／Table、AI mask 與 Lens Blur 繼續完整保存，並顯示明確限制。

### 2.3 完成定義

- 4 個 Neutral RAW direct case、4 RAW × 5 XMP 的 20 個 effect case 與 20 個 final-output case 全部通過本規格第 11 節；不得以平均值掩蓋單一失敗。
- Mac／iPad 的 import patch、diagnostics、render parameters 完全一致，輸出符合跨平台容差。
- 五份 XMP 的匯入、套用、Undo、重開、單張輸出與 batch 輸出無資料遺失。
- 所有升級為 `native` 或 `approximate` 的 capability 都有 importer、model、renderer、exporter／preservation 與測試證據。

## 3. 非目標

- 不承諾與 Adobe RAW decoder、DCP、Look Table 或 AI 演算法逐像素一致。
- 不破解或重新散布 Adobe 專有 `Table_*`、Camera Profile digest、`CompressedSettings`、AI mask 或 Lens Blur 資料。
- 不處理 Lightroom catalog、歷史記錄、virtual copy、雲端同步或 preset 管理 UI 重設計。
- 不在本規格加入 iPhone 版 UI。
- 不一次支援所有歷史 Process Version；未辨識版本必須保存，不得猜測套用。
- 不把 Point Color 與 Defringe 列為第一個修復階段；目前 corpus 中 Point Color 為 sentinel／空控制狀態，Defringe amount 為 0。

## 4. 相容性狀態契約

沿用 `native`／`approximate`／`preserved`／`rejected` 四層狀態，並新增以下約束：

1. `native` 代表資料語意、render order、跨平台結果與 round-trip 均有證據，不代表與 Adobe 專有演算法逐像素一致。
2. `approximate` 必須有版本化 converter、reference threshold 與 UI 說明；不得只因數值已進入 `PhotoAdjustments` 就宣稱已套用。
3. 只有 import + render、尚無可編輯 UI 的新模型，第一版標記為 `approximate` + `importOnly`。
4. Profile 名稱已辨識但無可驗證 mapping 時，仍是 `preserved`，不得套用名稱相近的內建風格。
5. Capability level 變更必須同時更新 manifest、測試、UI 摘要與本規格的 reference evidence ID。

## 5. 修復優先順序

### Phase A：驗測基準與門檻單一來源

#### A1. 單一門檻設定

- 建立 `LightroomReferenceThresholds` 或等價版本化型別，作為 spec、CLI 與測試的唯一來源。
- 初始 tone／color 門檻固定為：Mean `<= 0.04`、P95 `<= 0.12`、SSIM `>= 0.95`。
- 移除 `LumaHarborReferenceCompare` 目前硬編碼的 `0.02`／`0.05`／`0.98`，或明確定義成另一個命名 gate；不得讓同一個 `PASS` 有兩套意義。
- CLI JSON 必須輸出 threshold version、各門檻、逐項 pass/fail 與總狀態，不輸出私人路徑。

#### A2. 正式 reference 資料契約

每個 case 必須具備：

- Lightroom neutral、Lightroom preset、LumaHarbor neutral、LumaHarbor preset。
- 原始方向與尺寸一致。
- 原尺寸 16-bit TIFF、sRGB、無 resize、無輸出銳化、無浮水印。
- Lightroom 版本、Process Version、Profile／Look 名稱以去識別化 metadata 記錄。
- 私有 RAW、XMP 與影像只由環境變數或 ignored directory 注入。

Validator 必須拒絕缺圖、尺寸不一致、bit depth 不一致、色彩空間不一致、未知 fixture ID、絕對路徑洩漏，或同一 image ID 同時存在多種候選副檔名。不同 RAW／preset case 若出現相同影像 hash 也必須拒絕；唯一允許的重複是同一 RAW 的 neutral pair 被其五個 XMP case 明確共用。每次比較使用隔離的暫存目錄，不得沿用上一個 mode 的候選檔案。

#### A3. Tone／color 與 detail 分離

- Tone／color gate 比較 neutral-normalized effect field 的低頻明暗與色彩，不得讓隨機 Grain 主導 SSIM。
- Detail gate 對固定 crop 分別量測 Grain、Sharpening 與 Noise Reduction。
- Composite gate 保留完整 preset 輸出，用於 clip ratio、artifact 與人工目視，不以單一 SSIM 判斷 Grain。

#### A4. 三層比較模式

比較工具必須提供三個有名稱、不可混用的 mode：

1. `neutralDirect`：Lightroom neutral 對 LumaHarbor neutral，量測直接像素誤差、luminance SSIM、clipping 與色偏。
2. `presetEffect`：比較 `(preset - neutral)` 的效果場，用於定位 XMP converter 與 render order。
3. `finalDirect`：Lightroom preset 對 LumaHarbor preset，代表使用者實際看到與匯出的結果。

CLI JSON 與 report 必須輸出 mode；direct mode 不得把 direct SSIM 標成 effect SSIM。三種 mode 必須各自有通過狀態，`presetEffect` 通過不能抵銷 `neutralDirect` 或 `finalDirect` 失敗。

### Phase B：Grain 與解析度一致性

#### B1. Grain 座標與 seed

- Grain 必須以來源影像座標或明確的 reference pixel density 定義，不能以 decode 後「每一 preview pixel 一個 random sample」作為基準。
- 同一照片、同一 Grain 設定、同一 renderer version 必須得到穩定 seed；重繪、切換 Inspector 或重開 app 不得讓 Grain 圖樣跳動。
- Preview 可使用較低解析度，但 downsample 後的 Grain RMS contrast、主要 spatial frequency 與 roughness 分布必須接近 full export。
- Grain model／sidecar 增加版本欄位時，舊資料缺值必須維持目前既有外觀，不可在未遷移情況下靜默改變歷史照片。

#### B2. Detail 尺度契約

- Sharpen radius、Grain size、Presence radius 與任何 pixel-radius filter 均以 source-to-decode scale 明確換算。
- Noise Reduction 若底層 filter 無法分離 luminance／color，capability 維持 `approximate`；不得把合併結果標為完整支援。
- Preview、high-quality preview、full export 必須共用相同 converter 與 scale contract。

#### B3. Grain 驗收

對至少三種輸出尺度（短邊約 150、1024、原尺寸）與每份含 Grain 的 corpus case：

- 重複 render 的 tone/color 低頻結果必須 deterministic。
- 同一區域的 Grain RMS contrast 相對 full export 偏差 `<= 10%`。
- 徑向 power spectrum 主要頻率偏差 `<= 10%`。
- 不得出現 Lightroom 參照中不存在的白點爆裂、棋盤、條帶或 posterization。
- 100% 人工檢視必須確認 Grain 尺寸與強度方向一致。

### Phase C：RAW neutral baseline、Basic tone、Presence、Monochrome 與順序校正

#### C0. Neutral RAW 與 Profile 前置 Gate

- 在校正任何 XMP slider 前，先對四張 RAW 執行 `neutralDirect`；任一 case 未通過時，停止 preset 強度校正。
- 先固定 RAW decode 設定、方向、As Shot white balance、output transform 與可散布的 Camera Profile fallback；相同設定必須供 neutral、preset、preview 與 export 共用。
- 第 D3 節的 Profile registry 是本階段前置依賴，必須先為 corpus 中的 Adobe Standard／Adobe Color 定義明確 fallback 或 `profilePreservedNotApplied` 行為，再進入 C1。
- Neutral gate 的修正不得偷偷修改既有 LumaHarbor 原生照片；Adobe compatibility path 必須版本化並可回退。

目前已完成的第一個 C0 開發切片：

- `RawRenderingCompatibility` 以 `.native`／`.adobeProcess2012` 版本化保存於 `PhotoAdjustments`，舊 sidecar 缺少欄位時回到 `.native`。
- Adobe XMP 套用會把相容性標記傳入 preview 與 full-resolution export 的 `RawDecodeRequest`；原生 LumaHarbor 編輯不會被改寫。
- Adobe XMP 沒有明確 `LensProfileEnable` 時，套用結果使用 Core Image 的 automatic lens correction；明確的 `LensProfileEnable="0"` 仍維持關閉，避免覆蓋使用者／檔案意圖。
- `Adobe Standard`／`Adobe Color` 已由 `AdobeProfileRegistry` 辨識為 preserved，匯入時輸出固定 `profilePreservedNotApplied` diagnostic，並在 capability manifest 標示為 `preserved` + `importOnly`；目前使用 neutral fallback，沒有內嵌 Adobe DCP、digest 或 proprietary table。
- 四張 RAW 的 neutral gate 仍為 0/4 PASS，因此這個切片只建立隔離與診斷契約，尚未宣稱 Lightroom baseline 已修正。

#### C1. Process-aware converter

- `Exposure2012` 保持 EV 語意。
- `Contrast2012`、`Highlights2012`、`Shadows2012`、`Whites2012`、`Blacks2012` 使用 Process 2012 專用 converter，不再只以固定五點 `CIToneCurve` 推定 Adobe 效果。
- converter 必須版本化；已有 LumaHarbor 原生照片不得因 XMP 校正而改變。XMP import 使用新的 Adobe compatibility path，原生 slider 保持既有行為，除非另有 migration spec。
- 每個控制至少測試 `-100`、代表性負值、`0`、代表性正值、`+100`，以及相反方向組合。

#### C2. Presence

- Texture、Clarity、Dehaze 維持 `approximate`，但校正 amount curve、radius 與亮度依賴。
- 負 Clarity 不得等同單純 Gaussian blur；正 Dehaze 不得只靠固定 contrast + saturation 比例。
- Presence 對 preview scale 的反應必須符合 Phase B 的尺度契約。

#### C3. Monochrome

- `ConvertToGrayscale` 與八色 mixer 必須在 Adobe compatibility path 中以 Process 2012 語意轉換。
- mixer 全為 0 時必須產生正常中性灰階，不得造成全黑、全白或過強局部反差。
- HSL、Color Grading、Monochrome 與 Split Toning 的先後順序必須由 reference case 鎖定。

#### C4. Render order

相容路徑的目標順序固定為：

1. RAW decode、decoder 可處理的 lens correction 與 white balance。
2. 手動幾何／lens correction。
3. Camera Profile fallback 與 Calibration。
4. Exposure 與 Basic tone recovery。
5. Parametric Curve。
6. Composite point curve，再套 Red／Green／Blue channel curves。
7. Presence。
8. HSL／Point Color。
9. Monochrome mixer。
10. Color Grading 或 legacy Split Toning，依 XMP feature priority 擇一為主。
11. Sharpening、Noise Reduction、Defringe。
12. Vignette、Grain、Local Adjustments、resize 與 output transform。

任何順序改動都屬 compatibility change，必須更新 golden/reference test，不得只改註解或 UI。

### Phase D：缺少的標準模型

#### D1. Parametric Curve

新增獨立模型，至少包含：

- Shadows、Darks、Lights、Highlights 四區 adjustment。
- Shadow／Midtone／Highlight 三個 split。
- Neutral identity、clamp、Codable、Hashable、Sendable。
- XMP import、preservation、export／round-trip 或明確 import-only 限制。

不得把四區值粗略合併到既有 point curve。實作前以合成 ramp 鎖定每一區影響範圍與 split 邊界。

目前狀態：`ParametricToneCurve` 已獨立保存四區值與三個 split；XMP import／export 可 round-trip，renderer 使用連續、clamp、單調 LUT 近似套用，capability 標示為 `approximate` + `roundTrip`。目前沿用既有 `AdvancedToneCurve` stage，尚未證明與 Adobe Process 2012 的精確符號、split 邊界、render order 與 4 × 5 reference gate 等價，因此不得升級為 `native`。

#### D2. Calibration

新增版本化 calibration model：

- Red／Green／Blue Primary Hue。
- Red／Green／Blue Primary Saturation。
- Shadow Tint。

第一版列為 `approximate` + `importOnly`，使用線性／矩陣或公開可驗證方法實作；在 24 色標準色票完成 Delta E gate 前不得升級為 `native`。

#### D3. Adobe Profile／Look fallback

- 建立 profile reference 與 mapping registry，至少辨識 corpus 中的 Adobe Standard 與 Adobe Color。
- 可以使用自有、可散布且有 reference evidence 的近似 mapping；不得內嵌 Adobe 專有 table 或 digest 內容。
- 已辨識但無 mapping：保留原 property，使用 neutral fallback，輸出 `profilePreservedNotApplied` diagnostic。
- 有 mapping：列為 `approximate`，UI 顯示實際 fallback 名稱，不顯示為原生 Adobe Profile。

目前狀態：`Adobe Standard` 與 `Adobe Color` 已進入 registry 的辨識／preserved diagnostic 路徑，但尚無可驗證的公開 fallback mapping；因此仍停留在 neutral fallback，不得列為 `native` 或 `approximate`。

#### D4. Detail 子控制

Sharpen Detail／Masking、Luminance NR Detail／Contrast、Color NR Detail／Smoothness 只有在 renderer 個別使用其值後，才可從 `preserved` 升級。若 Core Image 內建 filter 不足，需新增自有 kernel 或維持 preserved，不得把多個欄位平均後宣稱完整支援。

### Phase E：Point Color、Defringe 與後續能力

- Point Color 使用結構化 control-point model，不得轉成八色 HSL。
- Defringe 需支援 purple／green amount 與 hue window。
- 兩者各自完成 synthetic test、XMP round-trip 與至少一組外部 corpus 後再進主 reference matrix。
- AI `FilterList`、Lens Blur、專有 Profile table 繼續 preserved，另立規格評估。

## 6. Model 與相容性要求

### 6.1 `PhotoAdjustments`

- 新欄位預設必須為 neutral，舊 sidecar／`.lhpreset` 缺少 key 時解碼成功。
- 若新增 optional neutral 欄位即可保持語意，優先不提高 schema version；若改變既有欄位含義或 Grain renderer version，必須提出 migration 與新 schema version。
- `merge` 與 `replace` 必須區分「XMP 未出現」和「XMP 明確設為 neutral」。

### 6.2 `PresetCore`

- Parametric Curve、Calibration、Profile 必須使用 composite converter，不拆成互相矛盾的 scalar side effects。
- 未支援 RDF 結構在多次 Lightroom -> LumaHarbor -> Lightroom round-trip 後保持語意等價。
- Malformed composite feature 必須整組 preserved 並輸出固定、安全 diagnostic；不得套用半組資料。

### 6.3 Capability manifest

每個 capability 必須記錄：

- Process Version family。
- compatibility level。
- mapping direction。
- renderer evidence ID。
- reference threshold version。
- 支援的 renderer version 或最低 sidecar schema。

## 7. Mac／iPad 產品行為

- 兩平台匯入同一 XMP 後，serialized patch、capability counts、diagnostics 與 render parameters 必須相同。
- Import preview 必須逐項顯示：已套用、近似套用、已保存未套用。
- Unknown／unsupported Profile 不得只顯示「部分相容」；必須顯示「Profile 已保存，未套用」或實際 fallback 名稱。
- Phase D 的 import-only 模型可先不提供完整手動編輯 UI，但 Inspector 必須提供唯讀摘要與 reset 行為；未提供 UI 時不得標為 fully editable native。
- Preview 不寫 history／sidecar；commit 只形成一筆 Undo。重開 app、copy/paste、batch 與 export 必須保留完整新模型。

## 8. Failure handling 與 rollback

- 每個新增 compatibility stage 必須可由 renderer version 或 feature flag 隔離，方便逐階段回退；正式 preset 資料不得依賴暫時 flag 才能解碼。
- Reference gate 未通過時，manifest level 不升級，UI 繼續顯示 preserved／approximate。
- Unknown Profile、缺少 lens data 或 malformed composite feature 不得 crash；使用 neutral fallback、保留原 RDF、輸出固定 diagnostic。
- 新 renderer 造成既有 LumaHarbor 原生照片外觀改變時，視為 regression；必須改成只套用於 Adobe compatibility path，或提供版本化 migration。
- 若 full-resolution renderer 超出記憶體／時間預算，該 case 為 FAIL，不得自動改用低解析度後宣稱通過。

## 9. 測試策略

### 9.1 Unit tests

- Threshold single source 與 CLI contract。
- Parametric Curve 每區與 split 的 ramp tests。
- Calibration primary hue／saturation 與 Shadow Tint 色票 tests。
- Process-aware Basic tone converter 的端點、方向與組合 tests。
- Grain deterministic seed、scale mapping、repeatability tests。
- Composite importer 的缺值、malformed、unknown Process Version 與 round-trip tests。
- 舊 sidecar／preset decode 與 neutral default tests。

### 9.2 Renderer tests

- Preview 和 full export 的低頻 tone/color effect comparison。
- Grain 的 RMS contrast、power spectrum 與 artifact detector。
- Sharpening edge overshoot／halo metric。
- Noise Reduction 的 flat-patch variance 與 edge retention。
- Monochrome mixer 的八色色票與中性灰 ramp。
- Pipeline order golden tests；每一 stage 必須有能偵測順序互換的 fixture。

### 9.3 Private Lightroom matrix

- 4 RAW × 5 XMP = 20 cases；每個 case 邏輯上引用 Lightroom neutral、Lightroom preset、LumaHarbor neutral、LumaHarbor preset 四張影像。
- Neutral 可在同一 RAW 的五個 case 間共用，因此最少為 48 份唯一 reference images：8 份 neutral 加 40 份 preset。若採 80 份實體檔案，validator 必須驗證只有同一 RAW 的 neutral 允許重複。
- 每 case 從同一組四張 reference images 派生 `neutralDirect`、`presetEffect`、`finalDirect`、detail 與 composite 分析結果；派生結果不另外列入 reference image 數，也不得取代原圖。
- 報告只使用 `raw-reference-*`、`fixture-*`、case ID 與數字，不含私人檔名、路徑或 metadata。
- 缺少 Lightroom／RAW／XMP／任一參照時標記 `NOT RUN` 或 `SKIPPED`，不可算 PASS。

### 9.4 Cross-platform tests

- Mac 與 iPad patch／diagnostics／render parameters equality。
- 相同 16-bit TIFF 設定下，跨平台 effect field Mean `<= 0.001`、P95 `<= 0.003`，尺寸與方向必須完全一致。
- 實體 iPad 直向、橫向與 Split View 完成 import、apply、Undo、重開與 export。

### 9.5 Performance

- 使用既有標準 RAW corpus 記錄修改前 baseline。
- High-quality preview P95 不得惡化超過 20%。
- 未啟用的新 capability 不得增加可量測的 renderer pass 或記憶體峰值。
- 四張 7008 × 4672 等級 RAW 必須完成 16-bit TIFF export，不得 OOM 或降級尺寸。

## 10. 人工目視驗收

每個 fixture 至少由一名未參與該效果實作的人員，在同一顯示器檢查：

- Fit-to-window 與 100%。
- Lightroom／LumaHarbor neutral 與 preset。
- Mac 與 iPad。
- 明暗方向、色偏、黑白模式、膚色／天空／霓虹色、highlight／shadow clipping、Grain 尺寸、halo、posterization。

只要合理使用者會判斷「這不是同一個 preset」，即使自動門檻通過仍為 FAIL。差異若來自無法重現的 Adobe Profile，必須列出核准例外與 UI 告知方式，不能只寫「接近」。

## 11. 驗收 Gate

### Gate 1：資料與工作流程

- 五份私有 XMP parser／patch tests：5/5 PASS。
- 20/20 case 可完成 import、preview、commit、Undo、重開與 export。
- Unknown／preserved properties 三次語意 round-trip 無遺失。

### Gate 2：Neutral RAW baseline

四張 RAW 的每一個 `neutralDirect` case 都必須：

- Mean absolute pixel error `<= 0.04`。
- P95 absolute pixel error `<= 0.12`。
- Luminance direct SSIM `>= 0.95`。
- Highlight／shadow clipping fraction 與 Lightroom 差異各 `<= 2` 個百分點。
- 無 XMP 時仍須記錄實際 Profile／fallback、As Shot white balance 與 output transform。

### Gate 3：Tone／color effect

每一個 case 都必須：

- Mean absolute effect error `<= 0.04`。
- P95 absolute effect error `<= 0.12`。
- Luminance effect SSIM `>= 0.95`。
- Highlight／shadow clipping fraction 與 Lightroom 差異各 `<= 2` 個百分點。
- 色票平均 Delta E 2000 `<= 4.0`，P95 `<= 10.0`。

### Gate 4：Final appearance

每一個 `finalDirect` case 都必須：

- Mean absolute pixel error `<= 0.04`。
- P95 absolute pixel error `<= 0.12`。
- Luminance direct SSIM `>= 0.95`。
- 通過第 10 節的 Fit-to-window 與 100% 人工目視；任何「不像同一個 preset」的結果均為 FAIL。

### Gate 5：Detail

- Grain RMS contrast 與主要 spatial frequency 偏差各 `<= 10%`。
- Sharpening／NR 固定 crop 的 edge 與 flat-patch metric 偏差各 `<= 15%`。
- 無新增白點爆裂、checkerboard、banding、halo 或 posterization。

### Gate 6：跨尺寸與跨平台

- 150、1024、原尺寸輸出的效果方向一致。
- Mac／iPad effect field 符合第 9.4 節容差。
- Preview、full export、single／batch export 使用相同 renderer version 與完整調整資料。

### Gate 7：回歸與效能

- 完整 `swift test -Xswiftc -strict-concurrency=complete` 無新增 failure。
- macOS build、iPad generic build PASS。
- 實體 iPad gate PASS。
- Preview P95 regression `<= 20%`。
- `git diff --check` 與隱私掃描 PASS。

## 12. 分階段交付與停止條件

1. **A：工具與門檻**。統一 threshold、正式 matrix validator、tone/detail 分離。Gate 1 的工具部分通過後才進 B。
2. **B：Grain 一致性**。先消除目前最明顯的顆粒爆裂；Gate 5 的 Grain 部分通過才進 C。
3. **C0：Neutral RAW／Profile baseline**。四張 RAW 的 Gate 2 未全數通過前，不得用 preset converter 補償 baseline，也不得進 C1。
4. **C1-C4：Basic／Presence／Monochrome 校正**。在 neutral baseline 固定後，才讓現有欄位接近 Lightroom；不得用 slider 補償 Profile 或 white balance 誤差。
5. **D：Parametric Curve／Calibration／Profile registry 完成**。每一 feature 獨立提交、獨立 reference evidence、可回退；其中 Profile fallback 的最小可用版本由 C0 前置。
6. **E：Point Color／Defringe 與後續能力**。只有前述階段未留下 blocker 才進入；Detail 子控制已歸入 Phase D，不在此重複排程。
7. **Final：正式 4 × 5 reference matrix、Mac／iPad 人工驗收與效能 gate**。

任一階段若造成既有原生照片外觀改變、sidecar 無法向後解碼、私有資料進入 Git、或 20-case matrix 出現方向相反的主要調整，立即停止並回退該階段，不得以放寬門檻完成驗收。

## 13. Implementation plan 前的必要決定

本規格確認後，implementation plan 必須先回答並鎖定：

1. Grain 採 source-coordinate procedural noise、預生成 tile 或其他 deterministic 方法；選擇必須能跨 Mac／iPad 重現。
2. Adobe compatibility path 如何與既有 LumaHarbor 原生 slider 行為隔離。
3. Parametric Curve 與 Calibration 的資料欄位加入 `PhotoAdjustments` 是否需要 sidecar schema bump。
4. Adobe Standard／Adobe Color 採哪個可散布 fallback，以及無 mapping 時 UI 文案。
5. Detail metric 的固定 crop、頻譜實作與 performance baseline 命令。
6. `neutralDirect`、`presetEffect`、`finalDirect` 的 CLI schema、reference ID 唯一性與隔離暫存目錄策略。

上述六項未鎖定前，不開始大範圍 renderer 重寫。
