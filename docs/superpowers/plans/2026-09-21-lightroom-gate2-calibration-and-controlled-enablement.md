# Lightroom Gate 2 P5-P7 Production Admission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `test-driven-development` for every code change and `executing-plans` to run this plan in order. Do not dispatch another writer into this dirty worktree.

**Goal:** 在不改變 Native 像素路徑的前提下，完成原尺寸 Lightroom 4/4 reference 驗收、條件式 camera-profile 校正、hold-out、Mac/iPad 對等與實體 iPad 驗收；全部通過前 Adobe renderer 維持 fail closed。

**Architecture:** 現有 persisted `policy` 只保存使用者意圖，唯一可執行來源是 resolver 產生的 `effectivePolicy`。Reference 工具先以 streaming/tiled 方式驗證原尺寸 16-bit embedded-sRGB TIFF，再由同一 typed metrics 與 threshold service 產生去識別報告。Production enablement 僅允許精確 camera/profile、runtime recipe 與版本化 artifact manifest 同時匹配。

**Tech Stack:** Swift 6、Swift Package Manager、Core Image、ImageIO/Core Graphics、XCTest、zsh、Xcode/macOS、iPadOS。

- 狀態：`READY ONLY WITH RENDERER DISABLED`
- 日期：2026-09-21
- 分支：`codex/lr-neutral-baseline-v1`
- 基準 HEAD：`fb421507bfeed1b2ff146109e3540d91de0eba62`
- 權威規格：`docs/superpowers/specs/2026-09-21-lightroom-gate2-production-hardening-and-reference-admission.md`
- 驗收報告：`docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md`
- Handoff：`docs/coordination/2026-09-21-lr-gate2-production-hardening-handoff.md`

## Global Constraints

1. 在既有 dirty worktree 原地接手；不得覆蓋、回復、刪除或重新格式化無關變更。
2. 本計畫執行期間不得 commit、push、merge、rebase、reset、stash 或修改 `main`。
3. `RawRendererFeatureFlags.adobeProcess2012V1Enabled` 預設維持 `false`；production registries 維持空白，直到 Task 6 全部 PASS。
4. 私人 RAW、XMP、TIFF、輸出影像、basename、hash、裝置 ID、Team ID、絕對路徑與 XMP 內容不得加入 Git、stdout、report 或測試失敗訊息。
5. 禁止使用 Exposure、Contrast、Highlights、Shadows、Whites、Blacks、Presence、Curve、Detail、mask、grain、sharpening 或單張照片特例補償 neutral 差異。
6. 任一必要素材缺少時標示 `NOT RUN`；任一已執行案例超過 threshold 時標示 `FAIL`。不得把兩者寫成 PASS。
7. Lightroom 與 LumaHarbor 比較的是解碼後像素，不是 TIFF 檔案位元組是否相同。
8. 4/4 neutral Gate 2 是 renderer admission gate。XMP target validation 另行回報；unsupported adjustment 不得被 camera-profile 校正掩蓋。

## Current Evidence Boundary

- P0、P1、P2 已有 fail-closed、canonical recipe 與 strict manifest binding 證據。
- P3 的 functional CLI、16-bit metadata、sanitized report 與 synthetic metrics 已有證據，但原尺寸 streaming 行為仍需 Task 2 驗證及必要修正。
- P4 自動測試、strict-concurrency、macOS bundle、iPad generic Simulator、diff/privacy 曾 PASS；6000x4000 peak RSS 與 wall time 仍為 `NOT RUN`，因此 P4 不可整體宣告完成。
- P5、P6、P7 仍為 `NOT RUN`。
- `ProfileCalibrationArtifactManifestsV1.all` 必須保持空白，直到 Task 5 的 production admission 完成。

## Private Input Contract

所有值只透過 shell environment 提供，不得寫入追蹤文件：

```text
LUMAHARBOR_GATE2_MATRIX
LUMAHARBOR_GATE2_IMAGES
LUMAHARBOR_GATE2_WORK_DIR
LUMAHARBOR_GATE2_SOURCE_DIR
LUMAHARBOR_GATE2_REFERENCE_MANIFEST
LUMAHARBOR_PROFILE_TRAINING_JSON
LUMAHARBOR_PROFILE_HOLDOUT_JSON
LUMAHARBOR_PROFILE_ID
LUMAHARBOR_PROFILE_CAMERA_MAKE
LUMAHARBOR_PROFILE_CAMERA_MODEL
LUMAHARBOR_PROFILE_NAME
LUMAHARBOR_PROFILE_PROVENANCE
LUMAHARBOR_IPAD_DEVICE_ID
LUMAHARBOR_IPAD_DERIVED_DATA
```

Stable IDs 固定使用 `raw-a` 到 `raw-e`、`fixture-a` 到 `fixture-e`。前四張供 formal 4/4；`raw-e` 只可作 hold-out，不得參與求解。

## Target Validation Matrix

| Mode | 用途 | Admission 結果 |
| --- | --- | --- |
| `neutralDirect` | Lightroom neutral 對 LumaHarbor neutral，4 unique RAW | 4/4 都 PASS 才能進 P6 |
| `presetEffect` | 比較兩端套用 XMP 前後的效果差 | 只對 parser 宣告支援的欄位形成 hard gate |
| `finalDirect` | 比較兩端套用 XMP 後的最終像素 | 支援範圍內必須回報；unsupported 欄位不得以 profile artifact 補償 |
| hold-out | 未參與求解的第五張 RAW | 必須優於 identity 且通過相同 neutral thresholds |

每個 XMP 先由既有 `XMPFeatureCapability` 分為 `fully-supported`、`partially-supported` 或 `unsupported`。部分支援或不支援仍執行並保存去識別結果，但不能被寫成 renderer Gate 2 PASS。

---

### Task 0: Freeze Execution Evidence Before Product Edits

**Files:**
- Modify: `docs/coordination/CURRENT.md`
- Modify: `docs/coordination/2026-09-21-lr-gate2-production-hardening-handoff.md`
- Modify: `docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md`

**RED check:**

- 比對三份文件與實際 `git status`。若仍把 P4 performance 或 P5-P7 寫成 PASS，先視為文件失敗。
- 確認 `ProfileCalibrationArtifactManifestsV1.all` 為空，feature flag 預設為 `false`。

**Steps:**

1. Run:

   ```bash
   git status --short --branch
   git rev-parse HEAD
   git diff --check
   rg -n "adobeProcess2012V1Enabled|static let all" Sources/RawProcessingCore
   ```

2. 在 handoff/report 記錄新的執行時間、HEAD、dirty file 清單總數，以及下列狀態：

   ```text
   P0-P2: PASS evidence preserved
   P3 functional: PASS evidence preserved
   P4 automated/build/privacy: PASS evidence preserved
   P4 full-resolution performance: NOT RUN
   P5-P7: NOT RUN
   Renderer: disabled
   Production registry: empty
   ```

3. 不複製私人路徑或檔名到文件。

**GREEN verification:**

```bash
git diff --check
rg -n "P4 full-resolution performance: NOT RUN|P5-P7: NOT RUN" docs/coordination docs/testing/reports
```

**Stop condition:** registry 非空、flag 預設為 true、或 dirty state 與文件不一致時停止，不進 Task 1。

**Do not touch:** renderer、decoder、adjustment pipeline、generated coefficient。

---

### Task 1: Make Process Tests and Report Destinations Fail Closed

**Files:**
- Create: `Sources/RawProcessingCore/Diagnostics/ReferenceCompareOutputPathValidator.swift`
- Create: `Tests/RawProcessingCoreTests/ReferenceCompareOutputPathValidatorTests.swift`
- Modify: `Sources/LumaHarborReferenceCompare/main.swift`
- Modify: `Tests/LumaHarborAppTests/ReferenceCompareProcessTests.swift`

**Required interface:**

```swift
public enum ReferenceCompareOutputPathValidator {
    public static func validate(
        reportURL: URL,
        matrixURL: URL,
        referenceRootURL: URL
    ) throws
}
```

Validation must compare standardized and symlink-resolved URLs. Reject a report that is the matrix, an existing directory, a symlink, or resolves inside the reference directory.

**RED tests:**

1. Replace `XCTSkip` in `referenceCompareExecutable()` with a hard test failure when the executable is missing.
2. Add process tests for:
   - report equals matrix;
   - report is an existing directory;
   - report is a symlink;
   - report uses `..` and resolves into the reference root;
   - report write failure returns non-zero;
   - PASS, FAIL and NOT RUN all emit the same typed schema to stdout/report;
   - report contains no test temp path or image extension.
3. Run RED after deliberately not building the executable; the process suite must fail, not skip.

**Minimal implementation:**

1. Build the product before process tests.
2. Validate `--report` before loading any private image.
3. Keep report writing as temporary file plus atomic replacement; do not print destination details on failure.
4. Keep `BatchOutput` as the single source for stdout and report serialization.

**GREEN verification:**

```bash
swift build --product LumaHarborReferenceCompare
swift test --filter ReferenceCompareOutputPathValidatorTests
swift test --filter ReferenceCompareProcessTests
```

Expected: zero skips, zero failures, unsafe destinations return non-zero.

**Stop condition:** any process case skips, any report can overwrite an input, or any output exposes a path/basename.

**Do not touch:** thresholds、camera profile、feature flag、XMP adjustment logic。

---

### Task 2: Prove and Fix Full-Resolution Streaming Performance

**Files:**
- Create: `Sources/RawProcessingCore/Diagnostics/ReferenceImageTileReader.swift`
- Create: `Sources/RawProcessingCore/Diagnostics/SlidingWindowSSIMAccumulator.swift`
- Create: `Tests/RawProcessingCoreTests/ReferenceComparisonPerformanceTests.swift`
- Modify: `Sources/RawProcessingCore/Diagnostics/ReferenceImageBuffer.swift`
- Modify: `Sources/RawProcessingCore/Diagnostics/ReferenceComparisonMetrics.swift`
- Modify: `Sources/LumaHarborReferenceCompare/main.swift`
- Modify: `Tests/RawProcessingCoreTests/ReferenceComparisonMetricsTests.swift`

**Required interfaces:**

```swift
public struct ReferenceImageTile: Sendable {
    public let originY: Int
    public let width: Int
    public let height: Int
    public let rgba16: [UInt16]
}

public struct ReferenceImageTileReader {
    public init(url: URL) throws
    public func tile(startRow: Int, rowCount: Int) throws -> ReferenceImageTile
}
```

Production CLI must iterate the same row range through the Lightroom and LumaHarbor readers, retain only the current pair of tiles plus rolling state, and release each pair before loading the next one. It must not materialize two full `[SIMD4<Float>]` images. SSIM must use an 11-row rolling/separable window and reusable buffers; P95 remains a fixed 65536-bin histogram.

**RED tests:**

1. Generate temporary 6000x4000 16-bit embedded-sRGB TIFF pairs at runtime. Do not commit the generated files.
2. Assert identical pair produces Mean/RMSE/P95 of 0 and SSIM of 1.
3. Assert metrics are deterministic for tile heights 16, 64 and 257, with absolute metric difference `<= 1e-9`.
4. Compare streaming SSIM against the existing small-image reference implementation with difference `<= 1e-9`.
5. Build `LumaHarborReferenceCompare`, generate the temporary TIFFs before measurement, then have the test launch that executable under `/usr/bin/time -l`. Parse only the child process aggregate metrics; do not use the XCTest process peak, because fixture generation would contaminate it.
6. Set `LUMAHARBOR_RUN_FULL_RES_REFERENCE_PERF=1` and assert:
   - dimensions remain 6000x4000;
   - bit depth remains 16;
   - peak RSS `<= 1.5 GB`;
   - wall time is measured and printed only as aggregate seconds;
   - no OOM, resize or 8-bit fallback.

**Minimal implementation:**

1. Keep `ReferenceImageBuffer` for small unit fixtures only.
2. Route CLI comparison through synchronized tile readers.
3. Accumulate Mean, RMSE, clipping and luminance statistics in one pass.
4. Feed rows into `SlidingWindowSSIMAccumulator`; do not allocate a per-pixel window array.
5. Keep alpha validation and encoded-sRGB conversion identical to the current typed validator.

**GREEN verification:**

```bash
swift build --product LumaHarborReferenceCompare
LUMAHARBOR_REFERENCE_COMPARE_EXECUTABLE="$(swift build --show-bin-path)/LumaHarborReferenceCompare" \
  LUMAHARBOR_RUN_FULL_RES_REFERENCE_PERF=1 \
  swift test --filter ReferenceComparisonPerformanceTests
swift test --filter ReferenceComparisonMetricsTests
```

Record aggregate peak RSS and wall time in the report. Do not record temporary paths.

**Stop condition:** RSS exceeds 1.5 GB, full-resolution test times out/OOMs, metric drift exceeds tolerance, or CLI falls back to 8-bit/downscaled data.

**Do not touch:** Lightroom thresholds、profile coefficients、tone/presence/curve/detail。

---

### Task 2A: Generate Paired Lightroom and LumaHarborPad References

**Files:**
- Private, untracked source: `$LUMAHARBOR_GATE2_SOURCE_DIR`
- Private, untracked export staging: `$LUMAHARBOR_GATE2_WORK_DIR/lightroom-exports`
- Private, untracked export staging: `$LUMAHARBOR_GATE2_WORK_DIR/lumaharborpad-exports`
- Private, untracked mapping: `$LUMAHARBOR_GATE2_REFERENCE_MANIFEST`
- Verify existing export contracts only: `Tests/RawProcessingCoreTests/PhotoExportTests.swift`, `Tests/AdjustmentUITests/PadExportOptionsTests.swift`

**Preflight:**

1. Confirm the source directory contains five RAW inputs and five XMP inputs without printing their names into shared output.
2. Assign only stable IDs `raw-a` through `raw-e` and `fixture-a` through `fixture-e` in the private manifest.
3. Confirm LumaHarborPad's TIFF exporter supports original dimensions, 16-bit, embedded sRGB, no resize and no output sharpening. Existing export tests must pass before any manual export.

**Reference export protocol:**

1. For raw-a through raw-d, open the same RAW in Lightroom Classic and LumaHarborPad with the same requested Profile, As Shot white balance and Process Version semantics. Reset all creative adjustments.
2. Export each neutral render as original-size, 16-bit, embedded-sRGB TIFF with no resize, output sharpening or watermark. Paired alpha policy must match.
3. Repeat the neutral export for raw-e, but reserve it as hold-out and never include it in the calibration training input.
4. After the neutral 4/4 baseline is captured, apply each of the five XMP files independently in both applications and export the 20 preset cases per application. Do not produce these 40 files before neutral intake has a recorded result.
5. Record only stable IDs, export settings, dimensions, bit depth, ICC status, alpha status and capability class in the private manifest. Keep actual filenames and paths outside Git.

**RED checks:**

- Missing LumaHarborPad 16-bit TIFF capability, mismatched dimensions/alpha, non-embedded sRGB, 8-bit output, resized output or output sharpening must fail the preflight.
- A missing Lightroom or LumaHarborPad pair is `NOT RUN`, not a synthetic substitute.
- A failed XMP capability classification must not be silently treated as fully supported.

**GREEN verification:**

```bash
swift test --filter 'PhotoExportTests|PadExportOptionsTests'
Scripts/validate-lr-reference-matrix.zsh "$LUMAHARBOR_GATE2_MATRIX"
```

Then inspect the staged files with the typed metadata validator. For the initial neutral gate, only the eight raw-a through raw-d neutral TIFFs plus the two raw-e hold-out TIFFs are required. The full 20-case matrix is admitted only after all preset/final pairs exist.

**Stop condition:** the source folder has no valid pair, Lightroom export settings differ from LumaHarborPad, the iPad cannot export or retrieve an original-size 16-bit TIFF, or any reference is missing/invalid. Do not enter calibration or populate a registry.

**Do not touch:** renderer policy, decoder options, profile coefficients, production registry or tracked private-data files.

---

### Task 3: Admit the Private Reference Corpus Without Leaking It

**Files:**
- Modify only if a real defect is found: `Sources/RawProcessingCore/Diagnostics/ReferenceImageMetadataValidator.swift`
- Modify only if a real defect is found: `Tests/RawProcessingCoreTests/ReferenceImageMetadataValidatorTests.swift`
- Modify only if a real defect is found: `Scripts/validate-lr-reference-matrix.zsh`
- Private, untracked: `$LUMAHARBOR_GATE2_MATRIX`
- Private, untracked: `$LUMAHARBOR_GATE2_IMAGES`

**Required reference properties:**

- Same four unique RAW inputs on both sides.
- Lightroom Classic and LumaHarbor each export original dimensions, 16-bit TIFF, embedded sRGB.
- No resize, output sharpening, watermark or creative adjustment for neutral references.
- Paired LR/LH dimensions and alpha policy match.
- Stable IDs only in matrix; no real filename in tracked artifacts.

**RED admission:**

1. Run the structural validator without `--images` first.
2. Run `--all-neutral` against the candidate directory.
3. Intentionally verify an 8-bit, resized or missing-ICC candidate returns non-zero and a sanitized reason.
4. Do not run the full 80-reference image validator until all preset/final images exist; neutral intake requires only the eight neutral TIFFs.

**Commands:**

```bash
test -n "$LUMAHARBOR_GATE2_MATRIX"
test -n "$LUMAHARBOR_GATE2_IMAGES"
test -n "$LUMAHARBOR_GATE2_WORK_DIR"
Scripts/validate-lr-reference-matrix.zsh "$LUMAHARBOR_GATE2_MATRIX"
swift build --product LumaHarborReferenceCompare
"$(swift build --show-bin-path)/LumaHarborReferenceCompare" \
  --all-neutral \
  --matrix "$LUMAHARBOR_GATE2_MATRIX" \
  --images "$LUMAHARBOR_GATE2_IMAGES" \
  --report "$LUMAHARBOR_GATE2_WORK_DIR/neutral-baseline.json"
```

**GREEN result:** report contains four stable cases and no private path/name. Each case is explicitly PASS, FAIL or NOT RUN.

**Stop condition:** metadata rejection、duplicate content、ambiguous extension、placeholder dimension、missing pair or any privacy leak. Do not calibrate rejected input.

**Do not touch:** generated registry、feature flag、product source unless a validator bug has a failing regression test first.

---

### Task 4: Run Formal 4/4 Neutral and XMP Target Validation

**Files:**
- Create: `Scripts/run-lr-gate2-target-validation.zsh`
- Create: `Tests/LumaHarborAppTests/LightroomGate2TargetValidationProcessTests.swift`
- Modify: `docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md`
- Private, untracked outputs: `$LUMAHARBOR_GATE2_WORK_DIR`

**RED process tests:**

1. A synthetic 20-case/80-reference corpus runs all three modes.
2. Any neutral FAIL makes the suite non-zero.
3. Any missing required preset/final reference makes that target `NOT RUN` and the full target suite non-zero.
4. Unsupported XMP capability is reported separately and never counted as renderer neutral PASS.
5. Aggregate report contains only stable IDs, metrics, thresholds, capability class and status.

**Minimal runner behavior:**

```text
1. validate matrix structure
2. run --all-neutral
3. if and only if all 80 references exist, run image metadata validator
4. run presetEffect and finalDirect for all 20 stable cases
5. write one sanitized aggregate report using temp + atomic rename
6. exit 0 only when all required gates for the selected scope pass
```

The runner must call `LumaHarborReferenceCompare`; it must not duplicate metrics or thresholds in shell.

**GREEN verification:**

```bash
swift build --product LumaHarborReferenceCompare
swift test --filter LightroomGate2TargetValidationProcessTests
Scripts/run-lr-gate2-target-validation.zsh \
  --binary "$(swift build --show-bin-path)/LumaHarborReferenceCompare" \
  --matrix "$LUMAHARBOR_GATE2_MATRIX" \
  --images "$LUMAHARBOR_GATE2_IMAGES" \
  --work-dir "$LUMAHARBOR_GATE2_WORK_DIR"
```

**Decision:**

- Neutral 4/4 PASS: preserve uncalibrated baseline and continue to Task 5.
- Any neutral FAIL: record the exact metric class using stable IDs, then continue to Task 5 only for layer-isolation analysis.
- Any neutral NOT RUN: stop. Missing evidence cannot enter calibration.
- XMP failure limited to unsupported fields: record preset compatibility gap; do not alter neutral renderer.

**Stop condition:** baseline was not captured before coefficients changed, reports contain private material, or neutral FAIL is relabeled as acceptable.

**Do not touch:** production artifact registry、release gate、adjustment controls。

---

### Task 5: Calibrate One Allowed Layer and Prove Hold-Out

**Files:**
- Modify: `Sources/RawProcessingCore/Profile/CameraProfileFallback.swift`
- Modify: `Sources/RawProcessingCore/Profile/ProfileCalibrationArtifactManifest.swift`
- Modify: `Sources/LumaHarborProfileCalibrate/main.swift`
- Modify: `Tests/RawProcessingCoreTests/CameraProfileCalibrationTests.swift`
- Modify: `Tests/RawProcessingCoreTests/ProfileCalibrationArtifactManifestTests.swift`
- Modify: `Tests/LumaHarborAppTests/ProfileCalibrationCommandContractTests.swift`
- Generate only after every gate passes: `Sources/RawProcessingCore/Profile/Generated/ProfileCalibrationArtifactManifestsV1.swift`

**Precondition:** Task 4 produced a real uncalibrated 4/4 result. If 4/4 already passes and no profile correction is needed, do not invent an artifact; record calibration as `NOT REQUIRED` and keep renderer disabled unless the approved runtime path has a separately valid manifest.

**RED tests:**

1. Training and hold-out stable IDs overlap: reject.
2. Empty hold-out: reject.
3. Hold-out RMSE does not beat identity: reject.
4. Manifest digest/runtime vector/working space/output transform/provenance mismatch: fail closed.
5. A coefficient set that improves training but fails any formal Gate 2 threshold: reject.
6. Sanitized calibrator stdout contains no sample ID, path, basename or input hash.
7. Legacy paired-sample JSON without `colorDomain` is rejected rather than inferred.
8. Encoded-sRGB samples are rejected before matrix fitting; v1 accepts only `linear-display-p3-v1` samples matching the runtime camera-profile stage.

**Layer-isolation order:**

1. Decoder option vector ablation.
2. Working/output color transform ablation.
3. Camera-profile artifact fit.

Change exactly one layer per experiment. Preserve each aggregate result outside Git. Stop at the first layer that causally explains the neutral delta; never combine layers merely to chase metrics.

Camera-profile samples must be converted from the validated 16-bit encoded-sRGB references into linear Display P3 before extraction. The JSON sample contract must declare `colorDomain=linear-display-p3-v1`; missing or encoded-sRGB domains fail closed. A fit performed directly on encoded-sRGB values is not runtime-equivalent evidence and cannot produce an admissible artifact.

**Calibration command:**

```bash
swift build --product LumaHarborProfileCalibrate
LUMAHARBOR_PROFILE_TRAINING_JSON="$LUMAHARBOR_PROFILE_TRAINING_JSON" \
LUMAHARBOR_PROFILE_HOLDOUT_JSON="$LUMAHARBOR_PROFILE_HOLDOUT_JSON" \
LUMAHARBOR_PROFILE_ID="$LUMAHARBOR_PROFILE_ID" \
LUMAHARBOR_PROFILE_CAMERA_MAKE="$LUMAHARBOR_PROFILE_CAMERA_MAKE" \
LUMAHARBOR_PROFILE_CAMERA_MODEL="$LUMAHARBOR_PROFILE_CAMERA_MODEL" \
LUMAHARBOR_PROFILE_NAME="$LUMAHARBOR_PROFILE_NAME" \
LUMAHARBOR_PROFILE_PROVENANCE="$LUMAHARBOR_PROFILE_PROVENANCE" \
"$(swift build --show-bin-path)/LumaHarborProfileCalibrate" \
  > "$LUMAHARBOR_GATE2_WORK_DIR/calibration-sanitized.json"
```

**GREEN verification:**

```bash
swift test --filter CameraProfileCalibrationTests
swift test --filter ProfileCalibrationArtifactManifestTests
swift test --filter ProfileCalibrationCommandContractTests
```

Then rerun Task 4 neutral 4/4 and hold-out. Required result: 4/4 passes all five thresholds, hold-out improves over identity and passes the same thresholds.

**Stop condition:** missing/incorrect color domain、overfitting、training/hold-out overlap、unsupported profile、runtime binding mismatch、single-photo coefficient、or any tone/presence/curve/detail compensation.

**Do not touch:** XMP sliders、Basic adjustments、mask、grain、sharpening、per-photo branches。

---

### Task 6: Controlled Enablement, Regression, Mac/iPad and Real-Device Acceptance

**Files:**
- Modify: `Sources/RawProcessingCore/Profile/Generated/ProfileCalibrationArtifactManifestsV1.swift`
- Modify: `Sources/RawProcessingCore/Profile/CameraProfileFallback.swift`
- Modify: `Sources/RawProcessingCore/Decoding/RawRenderRecipeResolver.swift`
- Modify: `Tests/RawProcessingCoreTests/ControlledRendererEnablementTests.swift`
- Modify: `Tests/RawProcessingCoreTests/PreviewExportRecipeParityTests.swift`
- Modify: `Tests/RawProcessingCoreTests/BatchExportQueueTests.swift`
- Modify: `Tests/RawProcessingCoreTests/ImageRenderServiceColorSpaceTests.swift`
- Modify: `Tests/RawProcessingCoreTests/CoreImageRawDecoderPrivateFixtureTests.swift`
- Modify: `docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md`

**RED tests:**

1. Exact camera/profile + release gate off: persisted Adobe, effective Native, Native pixel digest.
2. Exact camera/profile + gate on + exact manifest: effective Adobe.
3. Camera、profile、decoder version、option vector、ICC、output transform、coefficient digest or provenance 任一 mismatch: effective Native.
4. Legacy recipe missing derived fields: Native.
5. Undo、Reset、copy/paste、single export、batch export must not bypass resolver.
6. Preview、single export and batch export recipe IDs and pixel digests agree.
7. Unsupported XMP remains preserved-not-applied and cannot enable Adobe renderer.

**Minimal implementation:**

1. Generate fallback and manifest registry from the same admitted artifact input; never hand-edit only one side.
2. Keep global default flag false. Add only the exact admitted camera/profile key.
3. All rendering entry points consume the same resolved recipe.
4. Rollback is removal/disablement of the one registry entry or release gate, with persisted policy unchanged.

**Automated GREEN gates:**

```bash
swift test --filter ControlledRendererEnablementTests
swift test --filter PreviewExportRecipeParityTests
swift test --filter BatchExportQueueTests
swift test --filter ImageRenderServiceColorSpaceTests
swift test --filter CoreImageRawDecoderPrivateFixtureTests
swift test
swift build -Xswiftc -strict-concurrency=complete
Scripts/build-app-bundle.sh debug
xcodebuild \
  -project Apps/LumaHarborPad.xcodeproj \
  -scheme LumaHarborPad \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
git diff --check
```

**Mac/iPad parity:**

- On the same RAW and admitted profile, serialize the resolved recipe on Mac and iPad; IDs must match.
- Export paired original-size 16-bit embedded-sRGB TIFFs; Mean `<= 0.001` and P95 `<= 0.003`.
- Flag off and unsupported scope must remain byte/pixel equivalent to Native where the existing contract requires equality.

**Physical iPad acceptance:**

```bash
xcrun devicectl list devices
xcodebuild \
  -project Apps/LumaHarborPad.xcodeproj \
  -scheme LumaHarborPad \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$LUMAHARBOR_IPAD_DERIVED_DATA" \
  build
xcrun devicectl device install app \
  --device "$LUMAHARBOR_IPAD_DEVICE_ID" \
  "$LUMAHARBOR_IPAD_DERIVED_DATA/Build/Products/Debug-iphoneos/LumaHarborPad.app"
```

On device verify:

1. Import the real RAW through the supported UI.
2. With gate off, requested Profile is shown as saved/not applied and preview/export remain Native.
3. With the internal exact-scope gate on, only admitted camera/profile becomes effective Adobe.
4. Apply the XMPs and verify supported values, preview, single export, batch export and rollback.
5. Reopen the app; persisted policy survives, but effective policy still follows the current gate/artifact state.

If CoreDevice、signing、device availability or manual access blocks any step, mark physical iPad `NOT RUN`; do not infer PASS from Simulator.

**Stop condition:** any test/build failure、Mac/iPad metric failure、Native digest drift、privacy leak、physical iPad failure or NOT RUN. Do not enable production scope.

**Do not touch:** unrelated UI、library schema、main branch、signing identity。

---

### Task 7: Final Evidence and Handoff, Still Without Git Publication

**Files:**
- Modify: `docs/coordination/CURRENT.md`
- Modify: `docs/coordination/2026-09-21-lr-gate2-production-hardening-handoff.md`
- Modify: `docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md`

**Steps:**

1. Report actual test counts, skips, failures, build results, 4/4 per-case status, hold-out status, performance RSS/wall time, Mac/iPad parity and physical iPad result.
2. Report every `NOT RUN` and blocker explicitly.
3. Run privacy and material scans:

   ```bash
   git diff --check
   git status --porcelain=v1 | rg -i '\.(arw|xmp|tiff?|jpe?g|heic)$' && exit 1 || true
   rg -n '/Users/[^/]+|/Volumes/|Desktop/|Downloads/|Mobile Documents' \
     docs/testing/reports docs/coordination \
     Sources/RawProcessingCore/Profile/Generated
   ```

4. Confirm the final status with this decision table:

   ```text
   Any P4-P7 FAIL                  -> NOT READY
   Any required P4-P7 NOT RUN      -> READY ONLY WITH RENDERER DISABLED
   All P0-P7 PASS                  -> ELIGIBLE FOR CONTROLLED ENABLEMENT REVIEW
   ```

5. Leave the worktree dirty for review. Do not commit, push, merge, rebase or modify `main`.

**Final stop condition:** do not claim production-ready while physical iPad、hold-out、4/4、performance or cross-platform parity is missing.

## Completion Definition

## Execution Status (2026-09-22)

- Task 0 baseline／ownership：PASS；既有 dirty worktree 保留，未改 `main`。
- Task 1 process hardening：PASS；8 process cases、0 skipped、0 failures。
- Task 2 streaming comparator：PASS；tile heights 1／4／7 match array metrics within `1e-9`；6000x4000 synthetic run peak RSS `904167424` bytes under 1.5 GB，aggregate wall time 約 331 秒。
- Task 2A export preflight：PASS；50 `PhotoExportTests` + 4 `PadExportOptionsTests`，且私人 reference 已在 Git 外完成產生與 metadata 驗證。
- Task 3 reference admission：PASS；正式 4 組 neutral pairs 與第 5 組 hold-out 均為原尺寸 16-bit embedded-sRGB，未使用 placeholder。
- Task 4 neutral gate：FAIL；修正 16-bit byte order 後 4/4 均執行但未達 MAE、P95、SSIM thresholds。
- Task 5 layer isolation：decoder 舊強制向量已證明有害並改為保留 per-RAW defaults；工作色域 ablation 沒有實質改善；linear Display P3 camera matrix 僅小幅改善 training，formal 4/4 與獨立 hold-out 仍失敗，因此 artifact 已拒絕。Calibration sample JSON 現在缺少 domain 或使用 encoded sRGB 時 fail closed。
- Task 6 controlled enablement：`NOT RUN`；production registries 維持空白，Adobe renderer 維持 fail closed。
- Task 7 automated evidence：PASS；完整 `swift test` 2496 executed／17 skipped／0 failures，另以私人環境重跑 RAW 3/3 與 XMP 5/5 均無 skip；strict-concurrency、macOS bundle、iPad generic Simulator、公開矩陣、`git diff --check` 與 changed-diff privacy scan 均 PASS。實體 iPad 依 Task 5 失敗停止條件維持 `NOT RUN`。
- Decision：**READY ONLY WITH RENDERER DISABLED**。不得以 synthetic export preflight 宣告 Gate 2 4/4、hold-out、Mac/iPad pixel parity 或 physical iPad acceptance。

This plan is complete only when:

- process tests hard-fail rather than skip;
- unsafe report destinations are rejected;
- 6000x4000 comparison meets the 1.5 GB limit without precision/size fallback;
- four unique neutral RAW pairs pass formal Gate 2;
- any artifact passes independent hold-out and exact runtime binding;
- unsupported scopes remain fully Native;
- full tests, strict build, macOS bundle and iPad generic build pass;
- Mac/iPad recipe and pixel parity pass;
- physical iPad acceptance passes;
- Git contains no private material or identifying metadata.

Before all of the above, the only valid state is `READY ONLY WITH RENDERER DISABLED` or `NOT READY`.
