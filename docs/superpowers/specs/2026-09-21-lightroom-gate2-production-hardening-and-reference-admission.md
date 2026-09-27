# Lightroom Gate 2 Production Hardening 與 Reference Admission 規格

- 狀態：Draft；承接 2026-09-21 Gate 2 calibration／controlled-enablement 實作
- 日期：2026-09-21
- 分支：`codex/lr-neutral-baseline-v1`
- 基準 HEAD：`fb421507bfeed1b2ff146109e3540d91de0eba62`
- 上位規格：`docs/superpowers/specs/2026-09-21-lightroom-gate2-calibration-and-controlled-enablement.md`
- 上位計畫：`docs/superpowers/plans/2026-09-21-lightroom-gate2-calibration-and-controlled-enablement.md`
- 驗收報告：`docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md`

## 1. 目的

把目前已完成的 fail-closed、16-bit reference tooling 與 synthetic controlled-enablement slice，收斂成可在真實 LumaHarbor app、原尺寸 Lightroom Classic reference 與 Mac／iPad 上安全驗收的 production admission 流程。

這一階段不是直接打開 Adobe renderer。必須先證明：

1. 真實 app 能在取得 RAW camera metadata 後，以同一個 resolver 完成 camera/profile-scoped admission，而不是只在手工注入相機資訊的 unit test 中啟用。
2. persisted recipe、artifact manifest 或 serialized derived IDs 都不能繞過 fail-closed gate。
3. 四組原尺寸 16-bit TIFF 能在受控記憶體與時間內跑完 Gate 2，而不是只在 2×1 synthetic fixture 通過。
4. 只有 production artifact、4/4 Gate 2、hold-out、跨平台、效能、隱私與裝置驗收全部完成後，才可對核准 camera/profile 範圍啟用 Adobe renderer。

## 2. Sol 本輪已完成的工作

截至本規格建立前，worktree 包含 `25` 個 tracked 修改與 `11` 個 untracked 新檔；tracked diff 為 `1252` insertions、`285` deletions。這些內容尚未 commit、push、merge 或 rebase，不得覆蓋或回復。

### 2.1 已實作

- `ReferenceImageBuffer`：讀取 16-bit embedded-sRGB TIFF，保留 16-bit sample precision 後轉成 normalized `Float`。
- `ReferenceImageMetadataValidator`：驗證 TIFF、bit depth、ICC、尺寸與 alpha contract。
- `LightroomReferenceThresholds` v2：加入 highlight／shadow clipping delta，並維持 Mean、P95、luminance SSIM 的逐項判定。
- `LumaHarborReferenceCompare --all-neutral`：逐一執行 `raw-a` 至 `raw-d`，輸出 sanitized JSON，任一 case FAIL／NOT RUN 時 process non-zero。
- process-level CLI tests：實際啟動 executable，而非只做 source-string contract test。
- `ProfileCalibrationArtifactManifest` 與 generated manifest registry；production registry 目前刻意為空。
- camera/profile-scoped resolver gate：feature flag、decoder capability、fallback 與 manifest 全部存在時才允許 effective Adobe。
- fail-closed runtime：persisted Adobe policy 保留；未核准時 decoder option、working space、camera-profile stage、preview/export 走 Native。
- persistence／rollback regression：legacy decode、reopen、Undo、Reset、copy/paste 與 batch export 不得意外啟用 Adobe。

### 2.2 本輪重新驗證

- focused suites：`28` executed、`0` failures。
- `git diff --check`：PASS。
- 既有 dirty report 記錄 fail-closed full suite `2453` executed、`3` skipped、`0` failures，以及 strict-concurrency、macOS app bundle、iPad generic Simulator build PASS。
- 後續完整 suite 的較新數字若要作為 landing 證據，必須先寫入去識別 report；聊天摘要不能取代 repository evidence。

### 2.3 尚未通過

- 真正 Lightroom/LumaHarbor 4 組原尺寸 16-bit neutral TIFF Gate 2：`NOT RUN`。
- production camera-profile artifact admission：`NOT RUN`，registry 仍為空。
- full-resolution comparator memory／performance gate：`NOT RUN`。
- Mac／iPad pixel parity：`NOT RUN`。
- 實體 iPad install／launch／RAW/XMP preview/export smoke：`NOT RUN`。

## 3. 審查發現與根因

### 3.1 真實 app 的 controlled enablement 尚不可到達

`EditorSession` 建立 `RawCameraProfileRequest` 時只帶入 Profile 名稱；camera make/model 要由 RAW decoder 讀取 metadata 後才取得。現有 resolver 的第一階段因缺少 camera metadata 會 fail closed 為 Native，第二階段 `resolvingCameraProfile` 只允許既有 Adobe recipe 降回 Native，不會把 Native recipe 升成已核准 Adobe。

結果是 synthetic test 可用手工注入的 make/model 走 Adobe，但 production app 的正常資料流即使未來加入合法 artifact，也可能永遠維持 Native。

### 3.2 Serialized recipe 的 derived IDs 尚未完全 canonicalize

`ResolvedRawRenderRecipe` decode 會把 Adobe `effectivePolicy` 強制改成 Native，但仍可保留 serialized `decoderOptionVectorID`、`workingColorSpaceID`、`outputTransformID` 與 camera-profile payload。`ImageRenderService` 直接使用 color-space IDs，因此「effectivePolicy 是 Native」本身不足以證明所有 downstream stage 都是 Native。

Derived execution fields 必須由當前 resolver 重新產生，不能把 serialized 值當授權資料。

### 3.3 Artifact manifest 尚未完整綁定 runtime recipe

目前 manifest validation 會檢查 policy、camera、profile、artifact ID/version 與非空欄位，但沒有證明 manifest 的 decoder option vector、working color space、output transform 與 resolver 最終 recipe 完全一致。錯誤但非空的 pipeline ID 仍可能被視為 admitted。

### 3.4 全尺寸 comparator 尚未達 production 規模

目前 loader 會同時持有 `UInt16` sample buffer 與 `[SIMD4<Float>]`；metrics 另建立四組 sample 的 flattened copy、三通道 error array、排序副本與兩組 luminance array。SSIM 對每個像素建立視窗陣列。以 6000×4000 影像估算，單一 case 的峰值記憶體可能超過數 GB，SSIM 工作量也不適合正式 4/4 Gate 2。

Synthetic process test 通過只證明行為契約，不能當作原尺寸效能證據。

### 3.5 CLI 與 validator 契約仍有漂移

- 上位規格要求 `--report <path>`，目前 executable 只輸出 stdout，尚未原子寫入 report file。
- shell validator 重新實作一份 TIFF metadata 規則，並硬性要求 alpha；CLI 則只要求配對雙方 alpha contract 相同。兩條路徑可能對同一份合法 reference 得出不同結果。
- 圖像 metadata 與 comparison 應共用 typed production service，shell script 不應維護第二套規則。

### 3.6 Coordination evidence 落後實作

`docs/coordination/CURRENT.md` 仍描述 comparator 是 single-case、8-bit、沒有 clipping metrics；這和目前 dirty code 不一致。進入下一個產品修改前，必須先以 handoff/report 對齊 owner、dirty files、測試數與未執行 gates。

## 4. 範圍

### 4.1 本規格包含

- 封存 Sol dirty worktree 的實際檔案、證據與 ownership。
- 真實 app 兩階段 camera metadata resolution 與 camera/profile-scoped enablement。
- Serialized recipe derived fields 的 canonical fail-closed re-resolution。
- Artifact manifest 與 runtime recipe 的完整版本綁定。
- Full-resolution tiled/streaming 16-bit comparator、bounded-memory P95 與 SSIM。
- `--report` 原子輸出、sanitized schema 與 process-level tests。
- 統一 TIFF metadata／ICC／dimensions／alpha validator。
- Lightroom Classic 4 組 reference intake、baseline、training／hold-out、artifact admission。
- Preview/export、Mac/iPad、效能、實體 iPad、隱私與 rollback 驗收。

### 4.2 本規格不包含

- Exposure、Contrast、Highlights、Shadows、Whites、Blacks。
- Texture、Clarity、Dehaze、Curve、Calibration、Detail、Grain、Sharpening 或 Noise Reduction 的效果對等。
- 任何依 RAW ID、檔名、hash、照片內容或私人路徑建立的特例。
- Adobe DCP、Look Table、專有 LUT 或不可散布資料。
- 全相機／全 Profile 的一次性啟用。
- UI redesign、既有 adjustment 值或 sidecar wire semantics 變更。

## 5. 核心安全契約

### 5.1 Recipe authorization

- persisted `policy` 與 requested Profile 是使用者意圖，可以保存。
- `effectivePolicy`、decoder vector、working space、output transform、fallback ID/version 與 applied Profile 全部是 derived execution state。
- Derived state 每次開啟、preview、single export、batch export 與重新取得 camera metadata 時，都必須由同一個 resolver 依當前 release gate、capabilities 與 admitted registry 重建。
- JSON decode 不得直接信任任何 serialized derived state；缺欄位、未知版本、偽造 Adobe ID 或不一致組合全部 canonicalize 成完整 Native recipe，並保留 requested intent 與診斷。

### 5.2 Two-phase camera resolution

解析流程固定為：

```text
persisted intent
  -> preflight Native-safe recipe
  -> decoder reads canonical camera make/model
  -> resolver re-evaluates all gates from original intent
  -> admitted Adobe recipe OR complete Native recipe
```

- 第二階段可從 preflight Native 升成 Adobe，但只限 release gate、decoder capability、camera/profile registry、manifest validation 與 pipeline IDs 全部命中。
- camera metadata 缺失、模糊或改變時必須回 Native。
- 不允許先用 Adobe decoder 解碼後才發現相機不符；若 admission 需要 metadata，metadata preflight 必須不啟用 Adobe option vector。

### 5.3 Artifact admission key

Production admission 必須唯一綁定：

```text
policy
+ canonical camera make/model
+ canonical profile name
+ artifact ID/version
+ decoder identifier/version
+ decoder option vector ID
+ working color-space ID
+ output transform ID
+ coefficient digest
+ provenance schema/version
```

任一欄位不符或缺少時，整組 admission 失敗並回 Native。Coefficient digest 只可識別可散布的 generated artifact，不得包含私人 image hash。

## 6. Reference tool production 契約

### 6.1 Bounded memory

- 原尺寸比較器不得同時持有四份完整 RGBA float buffer。
- Neutral direct 只載入 Lightroom/LumaHarbor 兩張影像；preset/final 依 mode 只載入必要影像。
- Pixel decode、Mean、clipping 與 luminance statistics 採 scanline／tile streaming。
- P95 使用固定大小 histogram 或可證明 bounded-memory 的 deterministic quantile；誤差需小於 `1 / 65535`。
- SSIM 使用 rolling/tiled window，不得對每個像素配置新陣列；結果和 reference implementation 差異 `<= 1e-9`。
- 6000×4000 兩張 16-bit RGBA TIFF 的 peak RSS 必須 `<= 1.5 GB`，單 case wall time 必須先量測並記錄；不得因 timeout 自動降尺寸或轉 8-bit。

### 6.2 CLI/report

```text
LumaHarborReferenceCompare \
  --mode neutralDirect \
  --all-neutral \
  --matrix <matrix.json> \
  --images <reference-directory> \
  --report <sanitized-report.json>
```

- stdout 與 report 使用同一 typed `BatchOutput`；report 以 temporary file + atomic rename 寫入。
- PASS／FAIL／NOT RUN 都必須輸出完整逐案 report；I/O failure 為 non-zero。
- Report 不得包含絕對路徑、basename、RAW/XMP/TIFF 名稱、私人 hash、裝置 ID 或 XMP 內容。
- `--report` 不得覆蓋輸入 matrix/reference；目標路徑不可是 symlink 或 directory traversal 到 reference directory。

### 6.3 Metadata validator

- Shell validator、CLI 與 tests 共用 `ReferenceImageMetadataValidator` 或同一 typed library API。
- TIFF、16-bit、embedded sRGB、原尺寸與配對 dimensions 都是必要條件。
- Alpha 規則只有一份：配對雙方必須一致；若產品決定正式 corpus 必須有 alpha，matrix schema 要明確記錄，不可在 shell script 隱含硬編碼。
- Matrix placeholder、duplicate content、ambiguous extension 與 metadata mismatch 全部 non-zero。

## 7. 執行階段與依賴

```text
P0 Evidence freeze / handoff
  -> P1 Canonical fail-closed recipe
  -> P2 Reachable two-phase enablement + strict artifact binding
  -> P3 Bounded-memory comparator + unified validator + --report
  -> P4 Synthetic/process/performance regression
  -> P5 Real 4/4 Lightroom baseline intake
  -> P6 Calibration + hold-out + production artifact admission
  -> P7 Controlled rollout + Mac/iPad/device acceptance
```

### P0：Evidence freeze 與 ownership

修改文件：

- `docs/coordination/CURRENT.md`
- `docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md`
- 新增符合 `docs/coordination/HANDOFF_TEMPLATE.md` 的 Lightroom handoff。

驗收：

1. 記錄 branch、完整 HEAD、25 tracked + 11 untracked dirty files、writer 與下一個唯一 action。
2. 將實際最新 full/focused test 數、skip/failure、build、privacy、Gate 2 NOT RUN 寫入 report。
3. 不把聊天摘要當證據，不加入私人路徑。

停止條件：ownership 未交接、dirty file 清單改變且來源不明，或 `CURRENT.md` 與實際 Git 狀態仍不一致。

### P1：Canonical fail-closed recipe

主要檔案：

- `Sources/RawProcessingCore/Decoding/RawRenderRecipe.swift`
- `Sources/RawProcessingCore/Decoding/RawRenderRecipeResolver.swift`
- `Sources/RawProcessingCore/Pipeline/ImageRenderService.swift`
- `Tests/RawProcessingCoreTests/ControlledRendererEnablementTests.swift`
- `Tests/RawProcessingCoreTests/ImageRenderServiceColorSpaceTests.swift`

RED：偽造 Adobe `effectivePolicy`、working space、option vector、output transform 或 applied Profile 的 serialized recipe，decode 後所有 derived state 必須成為 canonical Native；requested Adobe intent 保留。

GREEN：resolver、preview、single export、batch export、legacy recipe 與 reopen 都使用相同 canonical recipe；Native pixel digest 不變。

### P2：Reachable two-phase enablement 與 strict artifact binding

主要檔案：

- `Sources/EditorCore/EditorSession.swift`
- `Sources/RawProcessingCore/Decoding/CoreImageRawDecoder.swift`
- `Sources/RawProcessingCore/Decoding/RawRenderRecipeResolver.swift`
- `Sources/RawProcessingCore/Profile/ProfileCalibrationArtifactManifest.swift`
- `Sources/RawProcessingCore/Profile/CameraProfileFallback.swift`
- `Tests/RawProcessingCoreTests/ControlledRendererEnablementTests.swift`
- `Tests/RawProcessingCoreTests/ProfileCalibrationArtifactManifestTests.swift`
- `Tests/RawProcessingCoreTests/CoreImageRawDecoderPrivateFixtureTests.swift`

RED：production-shaped request 只含 Profile name，camera metadata 由 decoder preflight 取得；完整 match 時可升成 Adobe，任一 mismatch 時完整回 Native。Manifest 中任何 pipeline ID、decoder version、digest 或 provenance mismatch 都必須拒絕。

GREEN：同一條 production API 同時覆蓋 unit test、preview 與 export，不允許 tests 使用 app 不會提供的額外欄位繞過流程。

### P3：Reference tool production hardening

主要檔案：

- `Sources/RawProcessingCore/Diagnostics/ReferenceImageBuffer.swift`
- `Sources/RawProcessingCore/Diagnostics/ReferenceImageMetadataValidator.swift`
- `Sources/RawProcessingCore/Diagnostics/ReferenceComparisonMetrics.swift`
- `Sources/LumaHarborReferenceCompare/main.swift`
- `Scripts/validate-lr-reference-matrix.zsh`
- 對應 RawProcessingCore／process-level tests。

RED：24MP synthetic metadata fixture 或可控 generated TIFF 必須證明 bounded memory、deterministic metrics、`--report` atomic output、alpha rule 一致與 sanitized error。

GREEN：single-case、batch、shell validator 與 report 全部走同一 typed service；不能以 source-string assertion 取代 process behavior。

### P4：公開回歸與效能 gate

必須 PASS：

- focused fail-closed、artifact、16-bit、metadata、metrics、CLI process suites。
- 完整 `swift test`。
- strict-concurrency build。
- macOS app bundle build。
- iPad generic Simulator build。
- full-resolution comparator peak RSS／wall-time benchmark。
- `git diff --check`、tracked private-material scan、report/path scan。

任何 OOM、尺寸降級、8-bit fallback、private path leakage 或 Native digest 改變都停止，不進 P5。

### P5：真實 4/4 Lightroom baseline intake

- 同一批四張 unique RAW，各自從 Lightroom Classic 與 LumaHarbor 輸出原尺寸 16-bit embedded-sRGB TIFF。
- 無 resize、output sharpening、watermark 或 creative adjustment。
- 私人素材只透過環境變數／未追蹤目錄提供。
- 先記錄未校正 4/4 逐案結果；不得先改 artifact 再補 baseline。

Gate 2 任一案失敗時狀態是 `FAIL`，不是「接近通過」。

### P6：Calibration、hold-out 與 production admission

- Training／hold-out stable IDs 互斥；hold-out 不參與求解。
- 一次只改 decoder vector、color transform 或 camera-profile artifact 其中一層。
- Hold-out RMSE 必須優於 identity，且 4/4 Gate 2 五項 metrics 全過。
- Production fallback + manifest 以同一 generated step 產生，registry entry 不得手工只加一邊。
- Artifact entry 加入後重跑 P1-P5 全部 gates。

禁止使用任何 tone／Presence／Curve／Detail 或單張照片補償。

### P7：Controlled rollout 與裝置驗收

- 核准 camera/profile：requested Adobe + release gate on + exact artifact match 才 effective Adobe。
- 未核准 camera/profile、flag off、legacy recipe、artifact mismatch：完整 Native，且 requested intent 保留。
- Preview、single export、batch export recipe IDs 一致。
- Mac/iPad serialized recipe 一致；paired 16-bit output Mean `<= 0.001`、P95 `<= 0.003`。
- 實體 iPad 安裝目前 branch build，驗證真實 RAW/XMP、Profile 狀態、preview/export 與 rollback。裝置不可用只能標 `NOT RUN`。

## 8. 驗收標準

1. `CURRENT.md`、handoff、report 與 Git dirty state 一致。
2. Serialized derived execution fields 無法啟用或部分啟用 Adobe path。
3. Production-shaped profile-only request 在 metadata preflight 後能正確升級／降級，且不先執行 Adobe decoder。
4. Manifest 逐欄綁定實際 runtime recipe；任一 mismatch fail closed。
5. `--all-neutral --report` 對四案輸出 sanitized report，任一 FAIL／NOT RUN process non-zero。
6. 原尺寸 comparator peak RSS `<= 1.5 GB`，不降尺寸、不轉 8-bit、不 OOM。
7. 四張 unique RAW 各自通過 Gate 2 v2 五項 threshold。
8. Hold-out 改善且 production artifact 可散布、可驗證、可 rollback。
9. Unsupported path 的 decode／preview／export digest 與 Native 完全一致。
10. 完整 tests/builds、Mac/iPad parity、效能、實體 iPad 與 privacy gates 有可追溯證據。
11. Git 不含私人 RAW、XMP、TIFF、hash、檔名、絕對路徑、Team ID 或裝置 ID。
12. 沒有 Exposure、tone、Presence、Curve、Detail 或單張照片特例。

## 9. Rollback

- 關閉 internal release gate 或移除單一 camera/profile artifact registry entry，`effectivePolicy` 立即回 Native。
- persisted Adobe policy、requested Profile、sidecar、Undo/history 與 adjustments 不變。
- Artifact、decoder、ICC、OS 或 Core Image 版本改變時，一律提高版本並重跑 P1-P7；不得在同一 artifact version 靜默替換係數。
- 若任何 production incident 顯示 partial Adobe path，優先停用 registry entry，再分析；不得以 UI slider 補償。

## 10. 完成定義

只有 P0-P7 全部具備 PASS 證據，且正式 4/4 Gate 2、artifact hold-out、Mac/iPad parity、效能與實體 iPad 都完成，才能把該 camera/profile 組合標為可受控啟用。

在此之前：

- production registries 維持空，或只包含已完整驗收的既有組合；
- default feature flag 維持 `false`；
- 對外狀態只能是 `READY ONLY WITH RENDERER DISABLED` 或 `NOT READY`；
- 不得開始以 Basic tone、Presence、Curve 或 Detail 校正 XMP 效果差異。
