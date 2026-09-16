# Lightroom XMP P0 Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立 Lightroom XMP 視覺還原的 P0 驗收基礎：版本化能力清單、私有 fixture 注入、參考輸出矩陣與可重跑的效果差異量測；P0 不改變任何照片渲染結果。

**Architecture:** 在 `PresetCore` 以 namespace-qualified property 為索引建立單一 `XMPCapabilityManifest`，由 importer/exporter/UI 後續共用。私有 XMP 以環境變數提供給測試，測試輸出只包含 fixture ID 與計數。RawProcessingCore 提供純值的 reference effect metrics，macOS 診斷 CLI 負責載入四張參考 TIFF、計算指標與輸出不含檔案路徑的 JSON。

**Tech Stack:** Swift 5.9、SwiftPM、XCTest、Foundation、CoreGraphics/ImageIO（reference CLI 僅在 macOS 執行）。

## Global Constraints

- 不修改現有照片渲染順序、調整值、XMP mapping 行為或 UI 套用語意。
- 私有 XMP、RAW、Lightroom 輸出與絕對路徑不加入 Git，也不寫入測試錯誤訊息或 JSON 報告。
- 私有 fixture 缺少時測試只能 `XCTSkip`，不得回報 `PASS`。
- 所有新增 XMP capability 必須使用完整 namespace URI，不得用 bare `crs:` 字串判斷身份。
- 變更採 TDD：每個 production symbol 先有會正確失敗的測試，再寫最小實作。
- 完成前必須執行 `git diff --check`、focused tests、strict-concurrency build 與完整 `swift test`；本 P0 不要求實體 Lightroom，因此 Adobe smoke test 保持 `NOT RUN`。

---

### Task 1: 建立版本化 XMP capability manifest

**Files:**
- Create: `Sources/PresetCore/XMP/XMPFeatureCapability.swift`
- Modify: `Sources/PresetCore/Model/AdjustmentFieldID.swift`
- Test: `Tests/PresetCoreTests/XMPFeatureCapabilityTests.swift`

**Interfaces:**
- `XMPFeatureID`: 可編輯功能群組，至少包含 `basic`, `whiteBalance`, `presence`, `hsl`, `toneCurve`, `splitToning`, `sharpening`, `noiseReduction`, `vignette`, `grain`, `monochrome`, `colorGrading`, `calibration`, `parametricCurve`, `defringe`, `pointColor`, `renderingProfile`, `lensCorrection`, `unknown`。
- `XMPMappingDirection`: `.roundTrip` 與 `.importOnly`。
- `XMPFeatureCapability`: `propertyIDs`, `feature`, `processVersionFamily`, `level`, `direction`, `rendererEvidenceID`，並符合 `Codable`, `Equatable`, `Hashable`, `Sendable`。
- `XMPCapabilityManifest`: `capabilities`, `capability(for:)`, `capabilities(for:)`, `default`；初始化時拒絕同一 property 被兩個 capability 宣告。
- `AdjustmentFieldID.xmpFeatureID`：把既有 field 映射至功能群組，不改既有 raw value 或 Codable 格式。

- [ ] **Step 1: Write the failing test**

在 `XMPFeatureCapabilityTests.swift` 加入：

```swift
func testDefaultManifestUsesNamespaceQualifiedIDsAndCoversEveryExistingMapping() throws {
    let manifest = XMPCapabilityManifest.default
    let mappedIDs = Set(XMPMappingRegistry.default.mappings.map(\.propertyID))
    let manifestIDs = Set(manifest.capabilities.flatMap(\.propertyIDs))

    XCTAssertTrue(mappedIDs.isSubset(of: manifestIDs))
    XCTAssertTrue(manifest.capabilities.allSatisfy { $0.propertyIDs.allSatisfy { $0.namespaceURI == XMPNamespace.cameraRaw } })
    XCTAssertTrue(manifest.capabilities.contains { $0.feature == .toneCurve && $0.level == .native })
}

func testManifestRejectsDuplicatePropertyOwnership() {
    XCTAssertNil(XMPCapabilityManifest(capabilities: [
        XMPFeatureCapability(propertyIDs: [.cameraRaw("Exposure2012")], feature: .basic, processVersionFamily: .process2012, level: .native, direction: .roundTrip, rendererEvidenceID: "test"),
        XMPFeatureCapability(propertyIDs: [.cameraRaw("Exposure2012")], feature: .basic, processVersionFamily: .process2012, level: .native, direction: .roundTrip, rendererEvidenceID: "test")
    ]))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter XMPFeatureCapabilityTests`

Expected: compile failure naming the missing `XMPCapabilityManifest`, `XMPFeatureCapability`, or `xmpFeatureID` symbols.

- [ ] **Step 3: Write minimal implementation**

Implement the enums and structs in `XMPFeatureCapability.swift`. Build `.default` from `XMPMappingRegistry.default.mappings`, grouping fields by `AdjustmentFieldID.xmpFeatureID`; use `.process2012`, the mapping's existing compatibility level, `.roundTrip`, and a stable evidence ID such as `mapping.<feature.rawValue>`. Add `xmpFeatureID` to `AdjustmentFieldID` without changing existing switch behavior. Return `nil` from the failable initializer when a property occurs in more than one capability or a capability has an empty property set.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter XMPFeatureCapabilityTests`

Expected: all capability tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/PresetCore/XMP/XMPFeatureCapability.swift Sources/PresetCore/Model/AdjustmentFieldID.swift Tests/PresetCoreTests/XMPFeatureCapabilityTests.swift
git commit -m "feat: add XMP capability manifest"
```

### Task 2: Add private Lightroom fixture injection and sanitized baseline report

**Files:**
- Create: `Tests/PresetCoreTests/LightroomXMPFixtureSupport.swift`
- Create: `Tests/PresetCoreTests/LightroomXMPFixtureTests.swift`
- Create: `Scripts/run-lr-xmp-fixture-baseline.zsh`
- Modify: `docs/testing/reports/2026-08-21-preset-xmp-phase1.md` only if the runner needs a cross-reference (no private paths)

**Interfaces:**
- `LightroomXMPFixtureSupport.load()` reads `LUMAHARBOR_LR_XMP_FIXTURE_DIR`, enumerates only regular files whose extension is `.xmp`, sorts by filename, and returns `(id: String, data: Data)` without returning a path.
- Missing or empty environment input throws a support error; the XCTest caller converts that exact error to `XCTSkip`. Malformed files fail the test without echoing source content or path.
- `Scripts/run-lr-xmp-fixture-baseline.zsh` runs `swift test --filter LightroomXMPFixtureTests` and writes only fixture count, preview status, and pass/skip/fail status; capability and diagnostics counts are recorded by the P0 handoff report.

- [ ] **Step 1: Write the failing test**

Add tests that set up a temporary directory containing five sanitized XMP snippets and assert that the loader returns five sorted IDs, while a missing environment value throws a skip. Add an importer test that previews all five and asserts no crash, no private path in the report, and every result has a non-empty name or sanitized fallback.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LightroomXMPFixtureTests`

Expected: compile failure for the missing support type and baseline runner contract.

- [ ] **Step 3: Write minimal implementation**

Implement the support loader with `FileManager` and `ProcessInfo.processInfo.environment`; use generated IDs `fixture-01`, `fixture-02`, etc. rather than basenames in report output. Add the runner with `set -euo pipefail`, a task-specific temporary report directory created by `mktemp -d`, and a final summary that never prints the fixture directory. Do not make the runner create or copy user data.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LightroomXMPFixtureTests`

Expected: sanitized fixture tests pass; the no-environment case is explicitly skipped, not passed.

- [ ] **Step 5: Commit**

```bash
git add Tests/PresetCoreTests/LightroomXMPFixtureSupport.swift Tests/PresetCoreTests/LightroomXMPFixtureTests.swift Scripts/run-lr-xmp-fixture-baseline.zsh
git commit -m "test: add private Lightroom XMP fixture baseline"
```

### Task 3: Define the reference matrix format

**Files:**
- Create: `docs/testing/templates/lightroom-xmp-reference-matrix.json`
- Create: `docs/testing/lightroom-xmp-reference-matrix.md`
- Create: `Scripts/validate-lr-reference-matrix.zsh`
- Test: `Tests/LumaHarborAppTests/LightroomReferenceMatrixContractTests.swift`

**Interfaces:**
- Matrix schema version is `1`.
- Each case has only stable IDs: `fixtureID`, `rawID`, `lrNeutralID`, `lrPresetID`, `lhNeutralID`, `lhPresetID`, `profile`, `processVersion`, `colorSpace`, `bitDepth`, `width`, `height`.
- `validate-lr-reference-matrix.zsh <matrix.json> [--images <directory>]` validates required keys, rejects absolute paths and unknown fixture IDs, and, when `--images` is supplied, exits non-zero for missing image IDs. Without an image directory it validates the sanitized template schema only. It prints IDs and counts only.
- The template contains five fixture IDs and no private names, paths, image bytes, or Lightroom account metadata.

- [ ] **Step 1: Write the failing test**

Add contract tests asserting the template contains schema version `1`, five fixture IDs, no `/Users/`, `/Volumes/`, `file://`, or XMP packet content, and the documented required keys for every case.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LightroomReferenceMatrixContractTests`

Expected: failure because the template and validator do not exist.

- [ ] **Step 3: Write minimal implementation**

Create the sanitized JSON template and a Markdown protocol documenting the four-image case, Lightroom export settings, neutral/preset pairing, profile and Process Version capture, and `NOT RUN` semantics. Implement the shell validator with `/usr/bin/plutil` or `swift` Foundation JSON parsing available on macOS; never print the input path in an error. Make the image-directory argument optional so the committed template can validate before reference exports exist.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LightroomReferenceMatrixContractTests` and `Scripts/validate-lr-reference-matrix.zsh docs/testing/templates/lightroom-xmp-reference-matrix.json`

Expected: contract and template validation pass.

- [ ] **Step 5: Commit**

```bash
git add docs/testing/templates/lightroom-xmp-reference-matrix.json docs/testing/lightroom-xmp-reference-matrix.md Scripts/validate-lr-reference-matrix.zsh Tests/LumaHarborAppTests/LightroomReferenceMatrixContractTests.swift
git commit -m "docs: define Lightroom reference matrix"
```

### Task 4: Implement pure reference effect metrics

**Files:**
- Create: `Sources/RawProcessingCore/Diagnostics/ReferenceComparisonMetrics.swift`
- Create: `Tests/RawProcessingCoreTests/ReferenceComparisonMetricsTests.swift`

**Interfaces:**
- `ReferenceComparisonMetrics.compare(width:height:lrNeutral:lrPreset:lhNeutral:lhPreset:) throws -> ReferenceComparisonResult` accepts RGBA float samples normalized to `0...1` and requires equal dimensions and sample counts.
- `ReferenceComparisonResult` contains `meanAbsoluteEffectError`, `p95AbsoluteEffectError`, `luminanceEffectSSIM`, and `sampleCount`; it is `Codable`, `Equatable`, and `Sendable`.
- The effect vector is `(preset - neutral)` per RGB channel. Luminance uses Rec. 709 coefficients and the SSIM calculation uses a fixed `11 x 11` window, `K1 = 0.01`, `K2 = 0.03`.
- Non-finite samples and dimension mismatch throw a safe, fixed `ReferenceComparisonError` without including image paths.

- [ ] **Step 1: Write the failing test**

Add tests for identical neutral/preset pairs yielding zero error and SSIM `1`, a known one-channel delta yielding the expected mean/p95, dimension mismatch throwing, and non-finite input throwing.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReferenceComparisonMetricsTests`

Expected: compile failure for missing metrics types.

- [ ] **Step 3: Write minimal implementation**

Implement input validation, effect-field absolute error collection, percentile using sorted finite values with nearest-rank selection, and the fixed-window luminance SSIM. Keep the implementation independent of Core Image and SwiftUI so Mac, iPad tests, and future command-line tools share it.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ReferenceComparisonMetricsTests`

Expected: all deterministic metric tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/RawProcessingCore/Diagnostics/ReferenceComparisonMetrics.swift Tests/RawProcessingCoreTests/ReferenceComparisonMetricsTests.swift
git commit -m "feat: add reference effect comparison metrics"
```

### Task 5: Add the macOS reference comparison command

**Files:**
- Create: `Sources/LumaHarborReferenceCompare/main.swift`
- Modify: `Package.swift`
- Create: `Tests/LumaHarborAppTests/ReferenceCompareCommandContractTests.swift`

**Interfaces:**
- Command: `swift run LumaHarborReferenceCompare --case <case-id> --lr-neutral <id> --lr-preset <id> --lh-neutral <id> --lh-preset <id> --matrix <matrix.json> --images <directory>`.
- It loads TIFF/PNG/JPEG through ImageIO, converts each image to normalized RGBA samples, calls `ReferenceComparisonMetrics`, and prints one JSON object containing only case ID, dimensions, metric values, and threshold status.
- It refuses mismatched dimensions, missing matrix IDs, unsupported formats, and non-finite output; it never prints an absolute input path.
- It exits `0` only when dimensions and metrics meet the matrix thresholds; no images available is an explicit non-zero `NOT RUN` result.

- [ ] **Step 1: Write the failing test**

Add a source contract test asserting `Package.swift` declares `LumaHarborReferenceCompare`, the command source contains `CGImageSourceCreateWithURL`, calls `ReferenceComparisonMetrics.compare`, and redacts paths from output.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReferenceCompareCommandContractTests`

Expected: failure because the executable target and source do not exist.

- [ ] **Step 3: Write minimal implementation**

Add a macOS executable target depending on `RawProcessingCore`; implement argument parsing, matrix lookup, ImageIO loading, RGBA normalization through a bitmap context, metrics call, JSON output, and threshold evaluation. On non-macOS builds return a fixed unsupported-platform status without importing AppKit.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ReferenceCompareCommandContractTests` and `swift run LumaHarborReferenceCompare --help`

Expected: contract tests pass and help text exits successfully without loading an image.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/LumaHarborReferenceCompare/main.swift Tests/LumaHarborAppTests/ReferenceCompareCommandContractTests.swift
git commit -m "feat: add Lightroom reference comparison command"
```

### Task 6: P0 integration verification and handoff

**Files:**
- Modify: `docs/coordination/CURRENT.md`
- Create: `docs/testing/reports/2026-09-16-lightroom-xmp-p0-baseline.md`

- [ ] **Step 1: Run focused verification**

Run:

```bash
swift test --filter 'XMPFeatureCapabilityTests|LightroomXMPFixtureTests|LightroomReferenceMatrixContractTests|ReferenceComparisonMetricsTests|ReferenceCompareCommandContractTests'
swift build -Xswiftc -strict-concurrency=complete
swift run LumaHarborReferenceCompare --help
git diff --check
```

Expected: focused tests PASS (with private corpus explicitly SKIPPED when no environment is supplied), strict build PASS, help PASS, and no diff-check output.

- [ ] **Step 2: Run full verification**

Run: `swift test -Xswiftc -strict-concurrency=complete`

Expected: no new failures; existing fixture-dependent skips remain distinct from passes.

- [ ] **Step 3: Write sanitized report**

Record branch, commit, exact commands, executed/skipped/failed counts, capability manifest counts, matrix validator result, command help result, and the fact that Adobe reference images and real Lightroom smoke tests are `NOT RUN` until the user supplies the exported references. Do not record any private fixture path.

- [ ] **Step 4: Update coordination state**

Update `CURRENT.md` with P0 status, changed files, verification evidence, unrun Adobe gate, and one next action: collect the Lightroom neutral/preset reference exports before P1 renderer work.

- [ ] **Step 5: Commit**

```bash
git add docs/testing/reports/2026-09-16-lightroom-xmp-p0-baseline.md docs/coordination/CURRENT.md
git commit -m "docs: record Lightroom XMP P0 baseline"
```
