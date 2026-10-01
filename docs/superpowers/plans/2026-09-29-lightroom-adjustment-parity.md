# Lightroom Adjustment Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 逐項對照 Lightroom Classic Develop 的現有編輯功能，修正 LumaHarbor 的數值語意、渲染接線與 UI 行為，讓每個已提供的控制都產生可預期且可驗證的結果。

**Architecture:** 保留 `.lumaharbor` sidecar 的相對調整格式與 `RawDecoding` 抽象；新增白平衡的 baseline-aware presentation mapping，讓 UI 對 RAW 顯示絕對 Kelvin、內部仍保存相對 offset。每個已存在的調整欄位都必須由 model → mapping → pipeline → UI／preset／batch 形成可追蹤鏈路，缺少 Adobe 等價功能則明確標記為 unsupported，而不是顯示看似可用但沒有作用的控制。

**Tech Stack:** Swift 6.1、Swift Package Manager、XCTest、Core Image、SwiftUI、Metal kernels；不新增第三方依賴。

## Global Constraints

- RAW 原檔永不修改；sidecar 仍是 LumaHarbor 編輯狀態的唯一正式來源。
- 不承諾與 Adobe Lightroom／Camera Raw 逐像素一致；驗收以數值語意、方向、單調性、身份映射與固定 fixture 的容差為準。
- 不修改使用者既有未提交變更；`Apps/LumaHarborPad.xcodeproj/project.pbxproj` 的本機 signing 變更保持 dirty、不得納入本次修改。
- 所有 production behavior 先寫 failing test，再實作（TDD：RED → GREEN → REFACTOR）。
- 既有 sidecar 欄位保持向後相容；新增欄位必須 `decodeIfPresent`，不可讓舊照片無法開啟。
- Lightroom Classic 的對照以 Adobe 官方 Develop 文件為行為參考；缺少的功能不以假控制冒充已支援。

## Lightroom 對照矩陣（目前已存在功能）

| LumaHarbor 功能 | Lightroom Classic 對應 | 目前發現 | 調整方向 |
|---|---|---|---|
| Exposure | Basic > Exposure | EV passthrough，方向正確 | 以 fixture 驗證線性 EV 與高光裁切，不改 UI 語意 |
| Temperature / Tint | Basic > Temp / Tint | RAW 目前是相對 offset、45K/unit；UI 不顯示 Kelvin | baseline-aware 絕對 Kelvin 顯示／輸入；內部保留 offset；滴管重新校準 |
| Contrast | Basic > Contrast | 直接映射 `0.5...1.5`，未驗證中間調行為 | 用灰階 ramp 驗證中間調單調性與端點，必要時換曲線映射 |
| Highlights / Shadows / Whites / Blacks | Basic tone controls | 四者共用固定 5 點 tone curve | 對照端點、交互作用與 clipping，補回歸 fixture |
| Vibrance / Saturation | Basic color | Core Image `CIVibrance`／`CIColorControls` | 驗證膚色與已飽和色保護；不把 Vibrance 當 Saturation |
| Tone Curve | Tone Curve | 基本曲線 + 進階 LUT | 驗證端點、單調性、gamma stage 與 LUT ROI |
| HSL | Color Mixer > HSL | 八色 HSL 已有，但需確認色域、band falloff 與正負方向 | 用彩色 ramp／單色 patch fixture 驗證 |
| Split Toning | Color Grading | 只有 shadow/highlight split toning，沒有 midtones／三向輪盤 | 修正現有方向與 luminance mask；缺少功能明確列為後續 |
| Sharpening | Detail > Sharpening | `detail`／`masking` 欄位存在但 pipeline 未使用 | 改用可驗證的 luminance/detail/masking kernel 或移除假控制 |
| Noise Reduction | Detail > Noise Reduction | luminance／color 目前被平均成單一 Core Image filter | 先分離 chroma/luma 路徑；保留 detail 語意與 identity |
| Vignette | Effects > Post-Crop Vignetting | 已有 Amount/Midpoint/Roundness/Feather | 驗證 crop 後座標、正負方向與 aspect ratio |
| Grain | Effects > Grain | 有 Amount/Size/Roughness；噪聲頻率仍依 decode resolution | 固定 preview/export 視覺尺度，加入容差測試 |
| Geometry | Crop / Transform | 裁切、旋轉、拉直、perspective 有模型／部分 pipeline | 驗證 transform order、crop-after-rotate 與輸出尺寸 |
| Local adjustments | Masking / Brush / Linear / Radial | 目前只有 linear gradient、spot heal | 修正 local mini-adjustment 語意；缺少 AI/brush/radial 明確標 unsupported |
| Preset / XMP | Presets / Profiles | sparse patch 與 XMP 相容層已有 | 驗證 Kelvin absolute ↔ relative 轉換與未知欄位保留 |
| Reset / Undo / Batch | History / Sync | 基本 reset、compound undo、batch 已有 | 每個新 mapping 必須保留單一手勢 undo 與欄位範圍 |

## Task 1: 建立對照與固定 fixture 測試基礎

**Files:**
- Create: `docs/testing/reports/2026-09-29-lightroom-adjustment-parity-audit.md`
- Modify: `Tests/RawProcessingCoreTests/AdjustmentMappingTests.swift`
- Modify: `Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift`
- Create: `Tests/RawProcessingCoreTests/AdjustmentParityFixtureTests.swift`

- [x] **Step 1: Write failing tests** for current advertised controls: neutral identity, monotonic direction, white-balance baseline conversion seam, sharpen/noise fields not being silently ignored, and tone/HSL fixture hooks.
- [x] **Step 2: Run focused tests** and confirm each new assertion fails for the intended reason.
- [x] **Step 3: Add the audit report** recording PASS/FAIL/NOT RUN separately and the exact Adobe comparison behavior used.
- [x] **Step 4: Run focused tests again**; leave production behavior unchanged until each test has a documented expected contract.

## Task 2: RAW white-balance semantics and calibration

**Files:**
- Create: `Sources/RawProcessingCore/Model/WhiteBalancePresentation.swift`
- Modify: `Sources/RawProcessingCore/Model/AdjustmentMapping.swift`
- Modify: `Sources/RawProcessingCore/Model/AdjustmentCatalog.swift`
- Modify: `Sources/EditorCore/EditorSession.swift`
- Modify: `Sources/AdjustmentUI/BasicAdjustmentPanel.swift`
- Modify: `Sources/AdjustmentUI/AdjustmentValueInput.swift`
- Modify: `Sources/AdjustmentUI/PadAdjustmentPolicy.swift`
- Modify: `Sources/PresetCore/Application/PresetApplicator.swift`
- Modify: `Sources/RawProcessingCore/Model/WhiteBalanceEyedropper.swift`
- Test: `Tests/RawProcessingCoreTests/AdjustmentMappingTests.swift`
- Test: `Tests/RawProcessingCoreTests/WhiteBalanceEyedropperTests.swift`
- Test: `Tests/EditorCoreTests/EditorSessionEditingTests.swift`
- Test: `Tests/AdjustmentUITests/BasicAdjustmentPanelModelTests.swift`

- [x] **Step 1: RED** — test absolute Kelvin ↔ stored relative offset round trips around each photo baseline, clamp behavior, and `Tint` direction.
- [x] **Step 2: RED** — test the UI exposes Kelvin for RAW once a baseline arrives and never writes presentation Kelvin directly into the sidecar.
- [x] **Step 3: RED** — test eyedropper neutral samples, warm/cool direction, and sensitivity against synthetic gray patches; mark real-camera calibration NOT RUN until a fixture is used.
- [x] **Step 4: GREEN** — add baseline-aware mapping and a dedicated temperature value binding; preserve old sidecars by decoding the existing relative field.
- [x] **Step 5: GREEN** — calibrate the eyedropper using the same mapping and clamp through one shared helper. RGB calibration is centralized and invalid samples are rejected; real-RAW/Lightroom calibration remains in the manual gate.
- [x] **Step 6: Run** focused white-balance tests, preset/XMP tests, and `git diff --check`.

## Task 3: Make every advertised detail/effect control functional

**Files:**
- Modify: `Sources/RawProcessingCore/Model/AdjustmentMapping.swift`
- Modify: `Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift`
- Modify: `Sources/RawProcessingCore/Pipeline/LocalAdjustmentRenderer.swift`
- Modify: `Sources/RawProcessingCore/Kernels/AdjustmentKernels.metal`
- Modify: `Sources/AdjustmentUI/DetailAdjustmentPanel.swift`
- Modify: `Sources/AdjustmentUI/EffectsAdjustmentPanel.swift`
- Test: `Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift`
- Test: `Tests/RawProcessingCoreTests/NoiseReductionTests.swift`
- Test: `Tests/RawProcessingCoreTests/SharpeningTests.swift`
- Test: `Tests/RawProcessingCoreTests/VignetteTests.swift`
- Test: `Tests/RawProcessingCoreTests/GrainTests.swift`

- [x] **Step 1: RED** — assert changing `Sharpening.detail` and `masking` changes the rendered synthetic edge differently; assert luminance and color noise controls do not collapse to the same output.
- [x] **Step 2: RED** — assert preview and full-resolution paths preserve the intended effect scale within the defined tolerance.
- [x] **Step 3: GREEN** — implement the smallest Core Image/Metal stages that honor each field; if a field cannot be represented faithfully, replace its UI with a clearly disabled/unsupported state rather than a no-op slider.
- [x] **Step 4: Run** focused render tests and compare fixture histograms/edge metrics.

## Task 4: Tone, color and geometry behavior parity

**Files:**
- Modify: `Sources/RawProcessingCore/Model/ToneCurveMapping.swift`
- Modify: `Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift`
- Modify: `Sources/RawProcessingCore/Pipeline/GeometryRenderer.swift`
- Modify: `Sources/RawProcessingCore/Pipeline/HSLKernelWeights.swift`
- Modify: `Sources/AdjustmentUI/CurveAdjustmentPanel.swift`
- Modify: `Sources/AdjustmentUI/ColorAdjustmentPanel.swift`
- Modify: `Sources/AdjustmentUI/GeometryAdjustmentPanel.swift`
- Test: `Tests/RawProcessingCoreTests/ToneCurveMappingTests.swift`
- Test: `Tests/RawProcessingCoreTests/HSLKernelWeightsTests.swift`
- Test: `Tests/RawProcessingCoreTests/GeometryRendererTests.swift`
- Test: `Tests/AdjustmentUITests/AdjustmentGroupPanelsContractTests.swift`

- [x] **Step 1: RED** — add ramp tests for each tone control, curve endpoint preservation, HSL band direction/falloff, split-toning luminance masking, and geometry transform order.
- [x] **Step 2: GREEN** — adjust only the mappings/stages that fail those behavior contracts; preserve stable field IDs and sidecar decoding.
- [x] **Step 3: Run** focused tests plus a clean render build.

## Task 5: Local, preset, batch and UI behavior parity

**Files:**
- Modify: `Sources/RawProcessingCore/Pipeline/LocalAdjustmentRenderer.swift`
- Modify: `Sources/AdjustmentUI/LocalAdjustmentsPanel.swift`
- Modify: `Sources/PresetCore/Application/PresetApplicator.swift`
- Modify: `Sources/PresetCore/XMP/XMPMappingRegistry.swift`
- Modify: `Sources/EditorCore/EditorSession.swift`
- Modify: `Sources/PhotoLibraryCore/Batch/BatchAdjustmentSyncService.swift`
- Modify: `Sources/LumaHarborApp/Views/InspectorView.swift`
- Modify: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadInspectorHost.swift`
- Test: `Tests/LumaHarborAppTests/PresetWorkflowTests.swift`
- Test: `Tests/LumaHarborAppTests/BatchAdjustmentGestureIntegrationTests.swift`
- Test: `Tests/AdjustmentUITests/AdjustmentGroupPanelsContractTests.swift`
- Test: `Tests/AdjustmentUITests/PadInspectorCoordinatorTests.swift`

- [x] **Step 1: RED** — assert local controls match global direction, preset Kelvin import/export is baseline-aware, and batch sync only carries modified stable fields.
- [x] **Step 2: GREEN** — wire the corrected mappings through local/preset/batch/UI paths.
- [x] **Step 3: Verify** Mac and iPad inspector source contracts and localization keys.

## Task 6: Verification and manual calibration gate

**Files:**
- Modify: `docs/testing/reports/2026-09-29-lightroom-adjustment-parity-audit.md`
- Create: `docs/testing/beta/LIGHTROOM_ADJUSTMENT_PARITY_CHECKLIST.md`

- [x] **Step 1:** Run focused tests for each task and the full `swift test` suite; record exact counts and known signing-only failures separately.
- [x] **Step 2:** Run macOS build and generic iOS build without touching the signing-only project file.
- [ ] **Step 3:** Use a disposable RAW fixture set to compare Kelvin, Tint, tone endpoints, HSL directions, sharpening, noise reduction, geometry, local edits, preset round-trip, batch undo, and export integrity against Lightroom Classic.
- [ ] **Step 4:** Record manual visual results as PASS/FAIL/NOT RUN; do not claim Lightroom parity until the real-RAW calibration gate is run.
