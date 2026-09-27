# Lightroom XMP 套用修正報告

日期：2026-09-17
分支：`codex/lr-profile-application`

## 根因

XMP importer 原本只把既有 scalar mapping 寫入 `AdjustmentPatch`。五份 Lightroom 檔案中的黑白混色、色彩分級、鏡頭校正開關與降噪欄位雖能被 parser 讀到，卻被列為 preserved，沒有進入共用 renderer，因此會出現「Preset 顯示已匯入，但照片效果不完整」。

## 修正

- 新增 Adobe B&W 複合欄位解析與 XMP round-trip。
- 新增 Adobe Color Grading 14 個欄位解析與 XMP round-trip。
- 新增 `LensProfileEnable` 到 Core Image automatic/off 模式。
- 新增四個降噪 amount/detail 的 approximate mapping，沿用現有 `CINoiseReduction` 合併式 renderer。
- 新增 Adobe 四區 Parametric Curve 與三個 split 的獨立模型；XMP 可匯入、匯出 round-trip，renderer 以單調且可回退的 approximate LUT 套用。
- 補上 capability manifest、synthetic regression tests 與五份私有 XMP corpus assertions。

## 驗證

- `swift test --filter 'XMPFeatureCapabilityTests|XMPCompositeImportTests'`：8 passed。
- `swift test --filter 'XMPImportExportTests|XMPMappingTests'`：50 passed。
- `LUMAHARBOR_LR_XMP_FIXTURE_DIR=<PRIVATE_FIXTURE_DIR> swift test --filter LightroomXMPFixtureTests`：5 passed。

### Lightroom 實機參照比對（2026-09-18）

使用同一張 `raw-reference-01`，在 Lightroom Classic 先套用 `fixture-05`、再重設調整，各匯出一份未縮放的 sRGB TIFF；LumaHarbor 也使用相同 RAW 產生 neutral／preset 輸出。四份輸出再以相同比例縮至 100 × 150 進行既有 reference comparison：

```text
meanAbsoluteEffectError: 0.0316109784
p95AbsoluteEffectError:  0.1098039150
luminanceEffectSSIM:     0.8119143206
sampleCount:              15000
status:                   FAIL
```

這次實測確認 XMP 數值有讀入，且 Lightroom 端可看到 `曝光 +0.75`、`對比 -80`、`白色 +10`、`黑色 -10`、`清晰度 -12`、`去朦朧 +5`；但整體效果尚未達到當時 comparison command 的 `mean <= 0.02`、`p95 <= 0.05`、`SSIM >= 0.98` 門檻，也未達設計規格 §9 的 `0.04`／`0.12`／`0.95` 門檻。比較用的 Lightroom TIFF 保留在本機暫存目錄，未加入 Git。

### 四張 RAW × 五份 XMP 診斷矩陣（2026-09-18）

使用四張私有 ARW 與五份私有 XMP，在 Lightroom Classic 建立 4 組 neutral 與 20 組 preset 輸出；LumaHarbor 以相同 RAW、XMP 和輸出尺寸產生對照。Lightroom 已確認 20 份 sidecar 全部載入調整狀態，XMP parser 的五份 fixture 測試也全部通過。

本輪輸出為 150 × 100、8-bit sRGB、無輸出銳化，目的是快速定位主要差異，不是規格 §8.1 要求的原尺寸 16-bit TIFF 正式驗收。Grain、Sharpening 與 Noise Reduction 會受輸出尺寸與處理時機影響，因此以下數字只能視為診斷證據；正式 reference gate 仍為 `NOT RUN`。

| Fixture | 案例數 | Mean 平均 | P95 平均 | Effect SSIM 平均 |
| --- | ---: | ---: | ---: | ---: |
| fixture-01 | 4 | 0.113120 | 0.400980 | 0.212903 |
| fixture-02 | 4 | 0.130039 | 0.410784 | 0.025223 |
| fixture-03 | 4 | 0.132693 | 0.458824 | 0.001226 |
| fixture-04 | 4 | 0.094463 | 0.238235 | 0.252939 |
| fixture-05 | 4 | 0.119778 | 0.400980 | 0.053597 |
| **全部** | **20** | **0.118019** | **0.381961** | **0.109177** |

20/20 都未達設計規格 §9 的初始工程門檻（mean `<= 0.04`、p95 `<= 0.12`、SSIM `>= 0.95`），也未達目前 command tool 內更嚴格的門檻。目視結果與指標一致：fixture-01、02、03、05 的顆粒在小尺寸輸出過度明顯；fixture-03 的黑白夜景還出現過強的局部反差與亮點。fixture-04 沒有 Grain，畫面較乾淨，但色溫、明暗恢復與色彩仍明顯不同。

### Lightroom Classic 實際五組 XMP 參照（2026-09-19）

使用同一批四張 ARW 與使用者提供的五份 XMP，在 Lightroom Classic 15.5 產生 4 張 neutral 與 20 張 preset 的原尺寸 16-bit ProPhoto RGB TIFF。LumaHarbor 以同一批 ARW／XMP 產生 512 × 342 的 sRGB 預覽；兩邊再以相同固定畫布與 sRGB 色彩轉換計算三層指標。這是較接近實際使用的 smoke comparison，但 LumaHarbor 仍是 512px 預覽，不是規格要求的原尺寸 16-bit final export gate。

| 比較層 | 案例 | Mean 平均 | P95 平均 | SSIM 平均 | 通過 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Neutral direct | 4 | 0.069503 | 0.279412 | 0.536303 | 0/4 |
| XMP effect | 20 | 0.145974 | 0.462353 | 0.011747 | 0/20 |
| Final direct | 20 | 0.108675 | 0.304706 | 0.575788 | 0/20 |

按預設平均的 final direct mean：`preset-a` 0.090854、`preset-b` 0.091956、`preset-c` 0.093980、`preset-d` 0.118836、`preset-e` 0.147748。這次比對把問題分得更清楚：neutral 已先有顯著 baseline／色彩科學差異；XMP effect 層的 SSIM 幾乎為零，代表曲線、Adobe Color profile／Look、Process 2012 tone 與部分未套用欄位會共同改變效果，不是單一曝光或對比 mapping 的誤差。

這批 Lightroom TIFF 與 LumaHarbor 512px PNG 都保留在本機 未追蹤的私人證據目錄，未加入 Git；檔案內容與私人 XMP／RAW 路徑不寫入報告。

#### Grain 消融測試

對四份含 Grain 的 XMP 暫時只在診斷 renderer 關閉 Grain，其餘設定保持不變：

| 範圍 | Mean 平均 | P95 平均 | Effect SSIM 平均 |
| --- | ---: | ---: | ---: |
| 原始 16 組 | 0.123907 | 0.417892 | 0.073237 |
| LumaHarbor 關閉 Grain | 0.097845 | 0.335294 | 0.229551 |

關閉 Grain 後三項指標都有改善，但仍是 0/16 通過，證明 Grain 是主要可見差異之一，不是唯一根因。

### Phase A／B 實作切片（2026-09-18）

- Phase A 新增版本化 `LightroomReferenceThresholds` v1，統一為 mean `<= 0.04`、p95 `<= 0.12`、SSIM `>= 0.95`；`LumaHarborReferenceCompare` 現在輸出 threshold version、逐項 pass/fail 與總結果。
- Phase A4 新增 `neutralDirect`、`presetEffect`、`finalDirect` 三種 mode；CLI JSON 會輸出 mode，metric／evaluation 欄位改用不誤導 direct mode 的通用名稱。
- Reference locator 與 matrix validator 會拒絕同一 ID 的多副檔名候選；validator 以 SHA-256 拒絕跨 case 重複內容，只允許同一 RAW、同一 neutral ID 的明確共用。
- Phase B 將 Grain 改為在 source 座標先生成／模糊，再依 `scaleFactor` 映射到 preview；相同輸入重繪保持 deterministic。
- 新增跨解析度回歸測試：完整輸出縮小後與低解析度 preview 的 Grain 平均 RGBA 差異需小於 12/255。Phase A4 聚焦測試 18/18 PASS；三種 mode 的實際 CLI 煙霧測試皆 PASS，歧義候選則如預期 FAIL。完整 strict-concurrency 測試 2,380 executed、12 skipped、0 failures，strict-concurrency build PASS；未注入的私有 RAW／XMP 與外部磁碟測試維持 SKIPPED，不列為 PASS。
- 這些是 renderer 的工程修正，不代表 4 × 5 Lightroom 正式 reference matrix 已重新通過；原尺寸 16-bit TIFF 與實體 Mac／iPad gate 仍是 `NOT RUN`。

### Neutral／Effect／Final 三層診斷（2026-09-18）

使用既有四張去識別化 RAW reference 與五份 XMP 輸出，補做原規格缺少的 direct comparison。所有輸出均為 150 × 100、8-bit sRGB、無輸出銳化，只用於修訂規格與排定根因，不是原尺寸 16-bit 正式驗收。

| 比較層 | 案例 | Mean 平均 | P95 平均 | SSIM 平均 | 通過 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Neutral RAW direct | 4 | 0.056280 | 0.210784 | 0.779461 | 0/4 |
| XMP effect field | 20 | 0.118019 | 0.381961 | 0.109177 | 0/20 |
| Final output direct | 20 | 0.095714 | 0.289608 | 0.589074 | 0/20 |

四張 neutral case 的 Mean 分別落在 `0.038576...0.073907`，SSIM 落在 `0.672301...0.893806`。這證明未套用 XMP 時 baseline 已不一致，不能只校正 preset slider 或用 `(preset - neutral)` 抵銷差異。後續順序必須先固定 RAW decode、As Shot white balance、Camera Profile／fallback 與 output transform，再進 Basic tone／Presence 校正。

Final output direct 使用 Phase B Grain 修正前產生的 LumaHarbor preset 影像，因此只證明 final gate 必須存在；Phase B 修正後的正式 final 成績仍為 `NOT RUN`。本輪也發現舊五案例 command fixture 是同一組影像的占位副本；檔案 hash 完全重複，不能當成五個獨立案例。修訂後的 validator 必須拒絕跨 RAW／preset 的非預期 duplicate hash、同一 image ID 的多副檔名候選，以及前一 mode 殘留的暫存檔。

聚焦自動測試：Grain 尺度／determinism、XMP fixture／composite import、reference metrics／CLI／matrix contract 共 27/27 PASS。這表示 parser 與測試工具的既有單元契約正常，但像素相容結果仍為 FAIL，兩者不得混為同一狀態。

#### 已確認的缺口

1. **Grain 的解析度一致性與演算法**：初始診斷確認 noise texture 以 decode 後每像素產生，造成小尺寸 preview 過粗；Phase B 已改為 source-coordinate procedural noise，但仍需用原尺寸 4 × 5 matrix 驗證 Grain／Sharpening／Noise Reduction 與 tone／color 分離指標。
2. **Basic tone 與 Presence 仍是近似演算法**：Contrast、Highlights、Shadows、Whites、Blacks、Texture、Clarity 與 Dehaze 使用 Core Image 的近似組合，並非 Adobe Process 2012。fixture-04 沒有 Grain 仍無法通過，表示 tone recovery、white balance、HSL／point curve 的效果強度或順序還需要依 reference corpus 校正。
3. **Parametric Curve 仍是近似套用**：fixture-02、05 具有非零 `ParametricShadows`／`Darks`／`Lights`／`Highlights` 與自訂 split。現在已以獨立模型保存，並由 monotonic LUT 近似套用；尚未證明與 Adobe Process 2012 的精確曲線、split 邊界與 render order 等價。
4. **Calibration 尚未套用**：fixture-02、05 的 RGB Primary Hue／Saturation 有非零值，目前只保存不渲染。
5. **Adobe Profile／Look／Table 尚未映射**：corpus 使用 Adobe Standard 或 Adobe Color，以及私有 table／digest。LumaHarbor 缺少可驗證的等價 Profile 或明確 fallback，會改變 baseline colour science。
6. **Detail 子控制尚未獨立實作**：Sharpen Detail／Masking、Noise Reduction Contrast／Smoothness 等仍只保存，現有 NR 也會把 luminance／color amount 與 detail 合併到單一 Core Image filter。
7. **Point Color／Defringe 模型仍缺少**：本 corpus 的 Point Color 資料為 sentinel／空控制狀態，Defringe amount 也是 0，因此不是這次主要誤差來源；但一般 Lightroom XMP 相容性仍需補齊。
8. **門檻來源不一致**：初始診斷時設計規格與 `LumaHarborReferenceCompare` 使用不同門檻；Phase A 已改為單一版本化來源，正式 gate 仍須確認報告與所有 downstream validator 都使用同一版本。

#### C0 第一個開發切片（2026-09-18）

- 新增版本化 `RawRenderingCompatibility`，舊 sidecar 缺少欄位時維持 `.native`；Adobe XMP 套用結果標記為 `.adobeProcess2012`。
- 相容性標記已從 `PresetApplicator` 傳到 `PhotoAdjustments`、preview／export 的 `RawDecodeRequest`，因此後續 Adobe Process 2012 converter 可以只掛在相容路徑，不影響既有原生 RAW。
- Adobe XMP 未明確指定 `LensProfileEnable` 時採用 automatic lens correction；明確關閉值仍保持 off。
- `Adobe Standard`／`Adobe Color` 由 `AdobeProfileRegistry` 辨識，匯入時保留 `CameraProfile`、輸出 `profilePreservedNotApplied`，並在 capability manifest 標示為 `preserved` + `importOnly`；目前沒有偷套用同名或未驗證的內建 profile。
- 若 Adobe XMP 只有尚未能解析 baseline 的白平衡欄位，套用會保留警告但維持真正 no-op，不會新增 Undo、dirty 狀態或錯誤的相容性標記。
- 這不是 neutral baseline 修正：四張 RAW neutral gate 仍為 0/4 PASS，D3 公開 fallback mapping、Process 2012 tone converter 與原尺寸 16-bit reference gate 仍待完成。

#### D1 Parametric Curve approximate slice（2026-09-19）

- `ParametricToneCurve` 保存 Shadows、Darks、Lights、Highlights 與三個 split，缺少欄位的舊 sidecar 仍解碼為 neutral。
- XMP importer／exporter 已支援七個欄位的 round-trip；capability manifest 標示為 `approximate` + `roundTrip`，不冒充 Adobe 原生支援。
- renderer 以連續四區、clamp、單調 LUT 近似，並套在既有 composite／channel curve 組合上；目前沿用 `AdvancedToneCurve` 的既有 stage，identity 時完全不增加量化誤差。這個 stage 與 Adobe Process 2012 的完整 render order 仍待 reference corpus 鎖定。
- 使用 Lightroom 私有 smoke corpus 的抽樣比對，`preset-c` 與 `preset-d` 的 raw-a final mean 有小幅改善，但仍未達正式門檻；完整 4 × 5 matrix 尚未重新產生，故 gate 維持 `NOT RUN`／`FAIL`。

#### 建議實作順序

1. `neutralDirect`／`presetEffect`／`finalDirect` 三種 comparison mode 與 reference validator 已完成；正式重跑時仍必須為各 mode 使用隔離目錄。
2. Grain 的 source-coordinate 修正與輸出尺寸回歸測試已完成；用原尺寸 16-bit detail gate 驗證，並重新產生 Phase B 後的 preset 輸出。
3. 在現有 C0 compatibility plumbing 上完成 RAW decode、As Shot white balance、Adobe Standard／Adobe Color fallback 與 output transform，直到 4/4 neutral gate 通過。
4. Neutral baseline 固定後，再以 4 × 5 corpus 校正 Basic tone、Presence、Monochrome 與 point-curve 的強度及 pipeline 順序。
5. 以 reference corpus 校正 Parametric Curve 的符號、split 邊界與 render order；再新增獨立 Calibration 與 Detail 子控制。Point Color／Defringe 後續補齊，AI FilterList／Lens Blur 繼續 preserved。
6. 以原尺寸 16-bit sRGB TIFF 重跑三層完整矩陣，再進行 Mac／iPad 目視與輸出一致性驗收。

## 限制

這不是 Adobe Lightroom 的逐像素相容性承諾。`CameraProfile`／DCP、Calibration、Point Color、遮罩、Defringe、Lens Blur 及其他 Adobe 專有欄位仍會保留但不套用；Parametric Curve 已加入 approximate renderer，降噪也明確標示為 approximate。本輪已完成 4 × 5 低解析度 effect 診斷與 neutral／final 補測，但原尺寸 16-bit reference gate 尚未執行；要進一步降低差異，必須先讓 neutral RAW baseline 通過，再校正 XMP effect，最後以 final output 驗收使用者實際看到的結果。
