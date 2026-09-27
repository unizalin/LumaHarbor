# Lightroom Gate 2 校正與受控啟用規格

- 狀態：草案，已完成現況驗測，待確認後建立 implementation plan
- 日期：2026-09-21
- 分支：`codex/lr-neutral-baseline-v1`
- 上位規格：`docs/superpowers/specs/2026-09-19-lightroom-neutral-raw-baseline-v1.md`
- 驗測契約：`docs/testing/lightroom-xmp-reference-matrix.md`
- 現況報告：`docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md`

## 1. 目的

把現有的 fail-closed Adobe renderer 從「預設安全關閉」推進到「有完整證據才對特定相機與 Profile 受控啟用」。本規格只處理 Neutral RAW Gate 2 的量測、校正產物與啟用閘門；在所有 Gate 2 條件通過前，持久化的 Adobe policy 必須保留，但實際 decoder、工作／輸出色域、camera profile、preview 與 export 繼續使用 Native。

完成後，LumaHarbor 必須能用同一批合法持有的 Lightroom Classic 參考輸出，逐張證明 Neutral RAW baseline 達標，並把通過證據綁定到版本化 artifact。未通過、證據缺漏、相機或 Profile 不在核准範圍時，一律 fail closed。

## 2. 驗測後的現況

### 2.1 已通過

- fail-closed focused tests：`32` executed、`0` failures。
- 私人 RAW decoder／preview／export parity：`2/2` PASS；Adobe policy 保留、`effectivePolicy` 為 Native，Native 與 fail-closed 像素 digest 相同。
- 公開 reference contracts：`15/15` PASS。
- 完整 SwiftPM 證據：`2453` executed、`3` skipped、`0` failures。
- strict-concurrency build、macOS app bundle、iPad generic Simulator build、`git diff --check` 與私人素材／路徑掃描均 PASS。

### 2.2 仍未完成

- `LumaHarborReferenceCompare` 目前只支援 single-case，尚未實作規格中的 `--all-neutral`。
- Comparator 目前把輸入轉成 8-bit sRGB buffer；Gate 2 要求原尺寸 16-bit TIFF 量測。
- `LightroomReferenceThresholds.current` 只判定 Mean、P95 與 SSIM，尚未納入 highlight／shadow clipping fraction。
- Matrix validator 能檢查結構、檔案存在與重複 hash，但尚未從影像本體強制驗證 16-bit、ICC、尺寸與無 resize。
- Matrix 模板仍有 `record-after-reference-export` 與 `0 x 0` placeholder，不能作為正式 Gate 2 證據。
- `AdobeCompatibleProfileFallbacksV1.all` 仍為空；目前沒有已通過合法 paired corpus 與 hold-out 的 production artifact。
- Lightroom 4 張 neutral reference、Mac／iPad pixel parity、效能與實體 iPad smoke 仍為 `NOT RUN`。本次再查詢實體裝置時，CoreDevice service 仍因 XPC invalidation timeout 無法列出裝置。

## 3. 問題定義

公開工具鏈測試通過，只能證明 schema 與單案例比較器存在，不能證明 Lightroom parity 已通過。如果現在直接打開 Adobe renderer，會有四個風險：

1. 以 8-bit 量測結果替代 16-bit Gate 2，掩蓋高光、陰影與色階差異。
2. 用 aggregate 平均值蓋過其中一張 RAW 的失敗。
3. 在沒有 hold-out 證據時發布 camera profile fallback，形成單張照片特例或過擬合。
4. 全域開啟 renderer，讓未核准相機／Profile 也進入不完整的 Adobe 路徑。

因此下一階段的完成條件不是「把 feature flag 改成 true」，而是建立可重現的 16-bit Gate 2、版本化校正產物，以及相機／Profile 範圍明確的受控啟用契約。

## 4. 範圍

### 4.1 本規格包含

- 4 張 unique RAW 的 Neutral reference intake 與 metadata 驗證。
- `--all-neutral` 批次比較與去識別化 JSON report。
- 16-bit normalized pixel extraction、Mean、P95、luminance SSIM、highlight／shadow clipping fraction。
- Decoder option vector、工作／輸出色域與 camera profile fallback 的版本化校正。
- Training／hold-out 隔離與 production artifact 生成。
- 只對已核准 camera + profile + artifact 組合啟用 Adobe renderer。
- Native rollback、preview/export parity、Mac/iPad parity、效能與 build gates。

### 4.2 本規格不包含

- Exposure、Contrast、Highlights、Shadows、Whites、Blacks。
- Texture、Clarity、Dehaze、Curve、Calibration、Grain、Sharpening 或 Noise Reduction 的 Lightroom 效果對等。
- 任何單張照片、檔名、RAW hash 或個人路徑特例。
- Adobe DCP、Look Table、專有 LUT 或不可散布資料。
- 所有相機與所有 Profile 的一次性全域支援。
- UI 重新設計、資料庫 migration 或既有 adjustment 值變更。

## 5. Reference Intake 契約

正式 Gate 2 corpus 必須符合以下條件：

1. 使用 `4` 張不同內容的 RAW，對應 stable ID `raw-a` 至 `raw-d`；Git 中不得出現原始檔名、絕對路徑、RAW、XMP 或輸出影像。
2. 每張 RAW 各有 Lightroom neutral 與 LumaHarbor neutral 輸出；正式 neutral gate 只比較這 `4` 組，不因 5 個 preset fixture 重複計數。
3. Lightroom 與 LumaHarbor 輸出必須是原尺寸、16-bit TIFF、embedded sRGB ICC、無 resize、無 output sharpening、無 watermark。
4. Matrix 中 `profile`、`processVersion`、`colorSpace`、`bitDepth`、`width`、`height` 必須是實值，不得保留 placeholder。
5. Validator 必須讀取影像本體確認 dimensions、bits per component、ICC identifier 與檔案格式；只相信 JSON 欄位不算通過。
6. 同一 RAW 的 Lightroom／LumaHarbor neutral hash 不可重複；不同 RAW 或不同角色的 hash 不可重複。重複、缺檔、格式模糊或 metadata 不符一律 non-zero exit。
7. Report 只保存 stable ID、版本 ID、數值 metrics 與通過狀態；不保存來源 URL、原始檔名、私人 hash 或 XMP 內容。

## 6. 16-bit 比較器契約

### 6.1 CLI

保留既有 single-case CLI，新增：

```text
LumaHarborReferenceCompare \
  --mode neutralDirect \
  --all-neutral \
  --matrix <matrix.json> \
  --images <reference-directory> \
  --report <sanitized-report.json>
```

- `--all-neutral` 只執行 4 個 unique raw ID 的 neutral pair。
- 任一案例 FAIL 時 process exit code 必須非 0；aggregate 不得把單案 failure 變成 PASS。
- 缺少 reference 時輸出 `NOT RUN` 並非 0 exit，不得輸出假 PASS。
- Single-case 與 batch 必須呼叫同一個 typed comparison service，不得維護兩套 thresholds。

### 6.2 Pixel pipeline

- ImageIO 讀取後必須保留至少 16-bit channel precision，依 embedded sRGB ICC 正規化為 `[0, 1]` 的 encoded sRGB `Float`／`Double` samples 後再計算 metrics。Gate 2 v2 不先轉成 linear light，避免在未重新標定門檻時改變既有 Mean／P95／SSIM 的語意。
- 不得先量化為 8-bit buffer，也不得以縮圖、display screenshot 或 JPEG 代替原尺寸 TIFF。
- 同一 RAW 的 Lightroom／LumaHarbor neutral 配對必須有相同 dimensions、ICC 與 alpha contract；不同 RAW 之間不要求尺寸相同。配對內不一致直接失敗。
- SSIM 可分 tile／window 串流計算以控制記憶體，但結果必須與 deterministic reference implementation 在 `1e-9` 內一致。

### 6.3 Gate 2 thresholds v2

每張 RAW 必須個別同時通過：

| Metric | Threshold |
| --- | --- |
| Mean absolute direct error | `<= 0.04` |
| P95 absolute direct error | `<= 0.12` |
| Luminance direct SSIM | `>= 0.95` |
| Highlight clipping fraction delta | `<= 0.02` |
| Shadow clipping fraction delta | `<= 0.02` |

- Shadow clipping 定義為 `max(R, G, B) <= 0.01` 的像素比例；highlight clipping 定義為 `max(R, G, B) >= 0.99` 的像素比例。兩者都在 normalized encoded sRGB samples 上計算。
- `LightroomReferenceThresholds.current` 升為 version `2`，evaluation 必須包含五個 boolean 與總 `isPassing`。
- Report 同時輸出實際值、threshold version、逐 metric boolean 與 per-case overall status。

## 7. 校正產物契約

### 7.1 允許調整的項目

一次只允許變更一組版本化 artifact：

1. decoder option vector；
2. working/output color-space transform；
3. camera + source profile fallback matrix/LUT。

每次變更都必須更新 artifact ID／version，重跑 4/4 neutral cases 與 hold-out。不得使用 Exposure、tone、Presence、Curve、Detail 或單張照片補償。

### 7.2 Training／hold-out

- Training 與 hold-out 的 stable raw IDs 必須互斥。
- Hold-out 只可接受或拒絕結果，不得參與求解。
- Production fallback 必須讓 hold-out RMSE 優於 identity baseline，並且完整 4/4 Gate 2 仍通過。
- 任何只改善 training、卻惡化任一 hold-out 或 Gate 2 case 的 artifact 不得進 registry。
- 校正輸出只包含可散布係數、aggregate metrics、artifact ID／version、camera match、source profile name 與 provenance。

### 7.3 Generated registry

`AdobeCompatibleProfileFallbacksV1` 只能收錄已通過上述 gate 的 artifact。每筆 production entry 必須可由以下 key 唯一解析：

```text
renderer policy + camera make + camera model + canonical profile name + artifact version
```

未命中、版本不符、artifact validation 失敗或 provenance 缺漏時，resolver 必須回到 Native，並保留 `profilePreservedNotApplied` 診斷。

## 8. 受控啟用契約

### 8.1 不得全域開啟

`RawRendererFeatureFlags.adobeProcess2012V1Enabled` 的無參數預設值維持 `false`。不得因第一個相機／Profile 通過就把所有 Adobe policy 全域切成 effective Adobe。

### 8.2 Effective policy 判定

只有以下條件全部成立時，`effectivePolicy` 才能是 `.adobeProcess2012V1`：

1. persisted/requested policy 是 `.adobeProcess2012V1`；
2. 內部 release enablement 明確開啟；
3. camera make/model 與 canonical profile 命中核准 registry；
4. decoder option vector、working space、output transform 與 profile artifact 版本完整；
5. artifact validation 與 provenance 檢查通過。

任何條件不成立時：

- persisted policy 仍保持 Adobe；
- `effectivePolicy` 為 Native；
- decoder options、工作／輸出色域、camera profile、preview 與 export 全部使用 Native；
- diagnostics 說明未套用原因；
- 不修改 adjustment 值、sidecar 或 history。

### 8.3 Preview／Export／操作安全

- Preview、single export 與 batch export 必須解析到相同 recipe artifact IDs。
- Undo、Reset、copy/paste、duplicate、reopen 與舊 recipe decoding 不得繞過 registry 或 release enablement。
- 對 unsupported camera/profile 的 Adobe policy，decode pixel SHA256 必須與 Native 完全一致。
- 啟用後的同一張照片，preview 與 export 只允許在尺寸／品質欄位不同；renderer、decoder vector、profile 與色域 IDs 必須相同。

## 9. 驗收標準

### 9.1 TDD 與公開測試

- 先新增會失敗的 batch CLI、16-bit intake、metadata rejection、clipping metrics、per-case gate、registry miss 與 controlled enablement tests。
- `ReferenceCompareCommandContractTests` 不得只用 source-string 搜尋證明行為；新增 process-level fixture tests 驗證 exit code 與 JSON schema。
- `ReferenceComparisonMetricsTests` 覆蓋 16-bit 值、clipping boundary、dimension mismatch、非有限值、per-case failure 與 deterministic tiled result。
- Matrix validator tests 覆蓋錯誤 bit depth、ICC、dimensions、duplicate content、placeholder 與缺檔。

### 9.2 Gate 2

- 4/4 unique neutral RAW 各自通過 thresholds v2。
- Report 顯示每張 RAW 的 requested/resolved decoder、option vector、As Shot WB status、profile fallback、working/output IDs 與五項 metrics。
- 任一 fallback、unsupported metadata 或 placeholder 存在時，Gate 2 不得 PASS。
- Sanitized report 通過私人路徑、檔名、RAW/XMP 名稱與素材掃描。

### 9.3 回歸與跨平台

- Fail-closed focused suite 維持全綠；Native decode/preview/export digest 不變。
- 完整 `swift test`、strict-concurrency build、macOS app bundle、iPad generic Simulator build PASS。
- 同一 RAW 的 Mac／iPad serialized recipe 完全一致；16-bit TIFF Mean `<= 0.001`、P95 `<= 0.003`。
- High-quality preview P95 regression `<= 20%`；連續 4 次 full-resolution export 不得 OOM 或 fallback。
- 實體 iPad 完成 build、install、launch、真實 RAW/XMP preview 與 export smoke；裝置不可用時只能記錄 `NOT RUN`，不可取代 Gate 2。
- `git diff --check` 與私人素材／路徑掃描 PASS；Git 不得追蹤 RAW、XMP、reference TIFF、絕對路徑或私人 hash。

## 10. Rollback

Rollback 只需關閉 internal release enablement 或移除有問題的核准 registry entry，不需遷移或刪除使用者資料：

- persisted Adobe policy 與 requested profile 繼續保存；
- `effectivePolicy` 立即回到 Native；
- preview/export 回到 Native recipe 與既有像素；
- sidecar、Undo、history 與 adjustment 值不變。

若 OS 更新、decoder 版本、ICC 實作或 artifact 變更導致 Gate 2 回歸，必須先停用對應 registry entry，再重新校正；不得在原 artifact version 下靜默改係數。

## 11. 建議實作順序

1. TDD 補齊 thresholds v2、clipping metrics 與 16-bit typed image loader。
2. TDD 實作 matrix image metadata validator 與 process-level CLI tests。
3. 實作 `--all-neutral`、sanitized batch report 與 per-case non-zero exit。
4. 產生 4 組合法 Lightroom／LumaHarbor neutral reference，先跑未校正 baseline。
5. 依 decoder vector、color space、camera profile 的順序做單一變因校正與 hold-out。
6. 4/4 Gate 2 通過後生成 production artifact 與核准 registry entry。
7. 實作 camera/profile-scoped controlled enablement，重跑 fail-closed、跨平台、效能與完整 build gates。
8. 完成實體 iPad smoke、更新去識別化報告，再進 landing review。

## 12. 預計修改檔案

- `Sources/RawProcessingCore/Diagnostics/ReferenceComparisonMetrics.swift`
- `Sources/RawProcessingCore/Diagnostics/LightroomReferenceThresholds.swift`
- `Sources/LumaHarborReferenceCompare/main.swift`
- `Scripts/validate-lr-reference-matrix.zsh`
- `Sources/RawProcessingCore/Profile/CameraProfileFallback.swift`
- `Sources/RawProcessingCore/Profile/Generated/AdobeCompatibleProfileFallbacksV1.swift`
- `Sources/RawProcessingCore/Decoding/RawRenderRecipe.swift`
- `Sources/RawProcessingCore/Decoding/RawRenderRecipeResolver.swift`
- `Tests/RawProcessingCoreTests/ReferenceComparisonMetricsTests.swift`
- `Tests/RawProcessingCoreTests/RawRenderRecipeResolverTests.swift`
- `Tests/RawProcessingCoreTests/CameraProfileCalibrationTests.swift`
- `Tests/LumaHarborAppTests/LightroomReferenceMatrixContractTests.swift`
- `Tests/LumaHarborAppTests/ReferenceCompareCommandContractTests.swift`
- `docs/testing/lightroom-xmp-reference-matrix.md`
- `docs/testing/templates/lightroom-xmp-reference-matrix.json`
- `docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md`

## 13. 工作量與依賴

- 工程實作預估：`3-5` 個工程日，包含 TDD、batch comparator、16-bit intake、artifact gate 與完整回歸。
- Lightroom Classic 參考輸出與 metadata 登錄：`2-4` 小時人工操作；這是 Gate 2 的必要外部依賴。
- 實體 iPad 安裝與 smoke：裝置服務正常後約 `1-2` 小時。
- 若 4/4 baseline 未通過而需要多輪 decoder/color/profile 消融，每一輪另估 `0.5-1` 個工程日；不得為趕時間放寬 thresholds。

## 14. 完成定義

只有同時滿足以下條件，本規格才可標示完成：

- 公開工具鏈與完整回歸全綠；
- 正式 4/4 16-bit Neutral Gate 2 逐案 PASS；
- production artifact 通過 hold-out 並進入核准 registry；
- 支援範圍內 effective Adobe、範圍外 effective Native 的測試均 PASS；
- preview/export、Mac/iPad、效能、build、實體 iPad 與隱私 gates 完成；
- 去識別化報告可追溯 threshold、recipe 與 artifact version；
- 沒有 tone／Presence／Curve／Detail 或單張照片補償。

Gate 2 未達 4/4 時，renderer 必須維持 fail closed，下一階段 C1 不得開始。
