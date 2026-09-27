# Lightroom DCP／XMP Profile Renderer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不鬆動既有 fail-closed Gate 2 邊界的前提下，建立可驗證的 clean-room DCP parser、DCP profile stage、XMP RGBTable codec，以及 camera/profile scoped 的受控啟用路徑。

**Architecture:** 先以 Foundation-only、bounds-checked 的純值 parser 讀取 synthetic DCP TIFF，接著分離 matrix、HueSatMap、LookTable、ProfileToneCurve 與 XMP RGBTable 的純函式 stage。每一個 stage 都先以 synthetic vectors 做 TDD，再由 recipe resolver 以完整 artifact admission 原子地決定 Native 或受控 profile；任何未支援、錯誤或證據不足的狀態都回到完整 Native recipe。

**Tech Stack:** Swift 5.9、Foundation、Core Image（只在既有 render pipeline 連線 task 使用）、Swift Package Manager、XCTest、現有 `LumaHarborReferenceCompare` 與 Xcode macOS／iPad build scripts。

## Global Constraints

- 既有 branch 為 `codex/lr-neutral-baseline-v1`，基準 HEAD 為 `fb421507bfeed1b2ff146109e3540d91de0eba62`。
- worktree 既有 52 個 dirty paths 必須原樣保留；本任務不覆蓋、回復、刪除或清理既有變更。
- Luna 接手後是此 worktree 唯一 writer；其他 agent 只能 review。
- 正式 neutral 4/4、獨立 hold-out、preview/export、Mac/iPad、效能與隱私驗收完成前，Adobe renderer 維持 fail closed、production registry 維持空白、feature flag 預設關閉。
- 不得使用 Exposure、Basic tone、Presence、Curve、Detail、Grain、mask 或單張照片特例補償 profile 差異。
- 不複製 Adobe、GPL 專案或 proprietary DCP／LUT；LightTable、RawTherapee、mini-film 只能作行為 oracle。
- 私人 RAW、XMP、DCP、TIFF、JPEG、hash、檔名、相機序號、絕對路徑與 Lightroom catalog 不得進 Git、報告或 fixture。
- 每個 production function 都必須先有會正確失敗的 RED 測試；每個 RED 都要實際執行並確認失敗原因，再寫最小實作。
- 本輪不得 commit、push、merge、rebase 或修改 `main`；計畫與程式改動均保留在目前 dirty worktree 供 review。

---

## Execution Order and Stop Policy

依序執行 P0、P1，再依驗證結果逐步進入 P2-P8。P1 只產生 parser 與 synthetic test support，不修改 renderer、recipe resolver、registry、feature flag 或 preview/export path。任一 phase 的停止條件成立時，保留前一個已驗證狀態，回報 `DONE_WITH_CONCERNS`，不得跳到 production enablement。

---

### Task P0: Evidence Freeze and Exclusive Ownership

**Files:**
- Modify: `docs/coordination/CURRENT.md`
- Create or update: `docs/coordination/HANDOFF_TEMPLATE.md`-based handoff entry only if ownership is formally transferred
- Read-only: `AGENTS.md`, `docs/coordination/SHARED_AGENT_READ_PROTOCOL.md`, `docs/coordination/SHARED_GIT_WORKFLOW.md`, `docs/coordination/DECISIONS.md`, existing Gate 2 spec／plan／report and this plan

**Interfaces:**
- Consumes: Git snapshot, existing coordination evidence and dirty path list.
- Produces: A sanitized ownership record with branch, full HEAD, dirty path count, one next action, and explicit `READY ONLY WITH RENDERER DISABLED` status.

- [x] **Step 1: Capture the baseline before edits**

```bash
git rev-parse --show-toplevel
git branch --show-current
git rev-parse HEAD
git status --short --branch
git worktree list --porcelain
git log --oneline -8
git status --short | wc -l
```

Expected: repository root is the requested worktree, branch is `codex/lr-neutral-baseline-v1`, HEAD is `fb421507bfeed1b2ff146109e3540d91de0eba62`, and the existing dirty path count is 52 before any P0/P1 change.

- [x] **Step 2: Verify the fail-closed baseline**

```bash
rg -n "adobeProcess2012V1Enabled|ProfileCalibrationArtifactManifestsV1\.all|READY ONLY WITH RENDERER DISABLED" +  Sources Tests docs/coordination/CURRENT.md docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md
```

Expected: default feature flag is false, production artifact collection is empty, and current evidence records neutral 4/4／hold-out as FAIL or NOT RUN rather than PASS.

- [x] **Step 3: Update only the coordination record**

Record the current owner as Luna, the exact branch／HEAD, the preserved dirty path count, and this plan as the sole next action. Do not rewrite historical evidence or change the last validated product baseline.

- [x] **Step 4: Verify the evidence freeze**

```bash
git diff --check
git status --short | wc -l
rg -n "DCP／XMP Profile Renderer|SPEC_ONLY|sole writer|renderer.*disabled" docs/coordination/CURRENT.md
```

Expected: no whitespace error; the only P0 file change is coordination text; no product source, test, registry, or feature flag changed.

**Stop condition:** branch／HEAD differs from the requested baseline, the dirty path count changes unexpectedly, a production registry is non-empty, the feature flag defaults true, or any private path appears in a tracked diff. Stop before P1.

**Do not touch:** `main`, other worktrees, existing dirty product files, production registry contents, feature flag defaults, private fixture locations, historical report results.

---

### Task P1: Bounds-Checked DCP TIFF Container Parser

**Files:**
- Create: `Sources/RawProcessingCore/Profile/DCPProfileDocument.swift`
- Create: `Sources/RawProcessingCore/Profile/DCPProfileParser.swift`
- Create: `Tests/RawProcessingCoreTests/DCPProfileParserTests.swift`
- Modify only if target discovery requires it: `Package.swift`

**Interfaces:**
- Consumes: `Data) supplied by a caller; no file path and no filesystem access.
- Produces: `DCPProfileDocument), `DCPByteOrder), `DCPTagID), `DCPTagValue), and typed `DCPProfileParser.Error`.
- Does not consume or produce: `RawRenderRecipe), `CameraProfileFallback), Core Image, production registries, feature flags, or private fixtures.

The public shape must be equivalent to:

```swift
public enum DCPByteOrder: String, Codable, Equatable, Sendable {
    case littleEndian
    case bigEndian
}

public struct DCPTagID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16)
}

public enum DCPTagValue: Equatable, Sendable {
    case ascii(String)
    case unsignedShort([UInt16])
    case unsignedLong([UInt32])
    case rational([DCPRational])
    case signedRational([DCPSignedRational])
    case float([Float32])
    case double([Float64])
}

public struct DCPProfileDocument: Equatable, Sendable {
    public let byteOrder: DCPByteOrder
    public let tags: [DCPTagID: DCPTagValue]
    public func value(for id: DCPTagID) -> DCPTagValue?
}

public struct DCPProfileParser {
    public enum Error: Swift.Error, Equatable, Sendable {
        case dataTooShort
        case invalidByteOrder
        case invalidMagic
        case invalidIFDOffset
        case truncatedIFD
        case invalidType
        case invalidValueOffset
        case countOverflow
        case unsupportedValueEncoding
        case unterminatedASCII
        case nonFiniteNumber
    }

    public init(maxBytes: Int = 64 * 1024 * 1024, maxEntries: Int = 4_096)
    public func parse(_ data: Data) throws -> DCPProfileDocument
}
```

Use DNG tag IDs as constants in a separate nested namespace, including `uniqueCameraModel`, `profileName`, `calibrationIlluminant1/2`, `colorMatrix1/2`, `forwardMatrix1/2`, `profileHueSatMapDims`, `profileHueSatMapData1/2`, `profileLookTableDims`, `profileLookTableData`, and `profileToneCurve`. P1 only guarantees generic decoding; table semantics belong to P2-P4.

- [x] **Step 1: Add RED tests for the wished-for API**

Add these tests to `DCPProfileParserTests.swift`:

```swift
func testParsesLittleEndianInlineASCIIAndShortTags() throws {
    let data = SyntheticDCPTIFF.make(
        byteOrder: .littleEndian,
        tags: [
            .ascii(50708, "Synthetic Camera"),
            .ascii(50936, "Synthetic Profile"),
            .unsignedShort(50938, [3, 2, 2])
        ]
    )

    let document = try DCPProfileParser().parse(data)

    XCTAssertEqual(document.byteOrder, .littleEndian)
    XCTAssertEqual(document.value(for: .init(rawValue: 50708)), .ascii("Synthetic Camera"))
    XCTAssertEqual(document.value(for: .init(rawValue: 50938)), .unsignedShort([3, 2, 2]))
}

func testParsesBigEndianOffsetASCIIAndRationalTags() throws {
    let data = SyntheticDCPTIFF.make(
        byteOrder: .bigEndian,
        tags: [
            .ascii(50936, "Big Endian Profile"),
            .rational(50778, [(23, 1)])
        ]
    )

    let document = try DCPProfileParser().parse(data)

    XCTAssertEqual(document.byteOrder, .bigEndian)
    XCTAssertEqual(document.value(for: .init(rawValue: 50936)), .ascii("Big Endian Profile"))
    XCTAssertEqual(document.value(for: .init(rawValue: 50778)), .rational([(23, 1)]))
}

func testRejectsTruncatedHeaderAndIFD() {
    XCTAssertThrowsError(try DCPProfileParser().parse(Data([0x49, 0x49, 0x2A])))
    XCTAssertThrowsError(try DCPProfileParser().parse(SyntheticDCPTIFF.truncatedIFD()))
}

func testRejectsInvalidOffsetAndCountOverflowBeforeReadingPayload() {
    XCTAssertThrowsError(try DCPProfileParser().parse(SyntheticDCPTIFF.invalidPayloadOffset()))
    XCTAssertThrowsError(try DCPProfileParser().parse(SyntheticDCPTIFF.overflowingCount()))
}

func testRejectsUnsupportedTypeAndUnterminatedASCII() {
    XCTAssertThrowsError(try DCPProfileParser().parse(SyntheticDCPTIFF.unsupportedType()))
    XCTAssertThrowsError(try DCPProfileParser().parse(SyntheticDCPTIFF.unterminatedASCII()))
}

func testRejectsNonFiniteFloatingPointValue() {
    XCTAssertThrowsError(try DCPProfileParser().parse(SyntheticDCPTIFF.nonFiniteFloat()))
}
```

Add a test-only `SyntheticDCPTIFF` writer in the same test file or `Tests/RawProcessingCoreTests/TestSupport.swift`. It must construct bytes in memory, never write a TIFF to disk, and expose each malformed case by explicit byte offsets.

- [x] **Step 2: Run RED and record the correct failure**

```bash
swift test --filter DCPProfileParserTests
```

Expected: compilation or missing-symbol failures because the parser types do not yet exist. If a test passes before implementation, correct the test or fixture until it fails for the intended missing behavior.

- [x] **Step 3: Implement the minimal parser**

Implement a cursor with:

```swift
private struct DCPByteCursor {
    let data: Data
    let order: DCPByteOrder
    var offset: Int
    mutating func readUInt16() throws -> UInt16
    mutating func readUInt32() throws -> UInt32
    mutating func readBytes(count: Int) throws -> Data
}
```

The parser must validate the header, read the IFD count, validate every entry before reading any payload, use checked multiplication/addition for byte counts, decode inline values when they fit in four bytes, decode offset values otherwise, and reject non-finite Float32／Float64 values. Do not add table interpolation or render calls in this step.

- [x] **Step 4: Run GREEN focused tests**

```bash
swift test --filter DCPProfileParserTests
git diff --check
```

Expected: all parser tests PASS, no skip, no failure, and no production renderer file changed.

- [x] **Step 5: Run the existing profile regression slice**

```bash
swift test --filter 'CameraProfileRendererTests|ProfileCalibrationArtifactManifestTests|RawRenderRecipeResolverTests'
```

Expected: existing v1 fallback and fail-closed tests remain green; the production registry remains empty.

**Stop condition:** any malformed input crashes or allocates unbounded memory; parser accepts a bad offset, overflow, non-finite number, or unterminated string; existing profile tests fail; or the implementation requires a third-party runtime dependency.

**Do not touch:** `CameraProfileFallback.swift), `CameraProfileRenderer.swift), `RawRenderRecipe.swift), `RawRenderRecipeResolver.swift), `AdjustmentPipeline.swift), `ImageRenderService.swift), `AdobeCompatibleProfileFallbacksV1.swift), `ProfileCalibrationArtifactManifestsV1.swift), any production feature flag, any registry entry, UI files, or private fixtures.

---

### Task P2: Matrix and Illuminant Resolution

**Files:**
- Create: `Sources/RawProcessingCore/Profile/DCPProfileMatrixResolver.swift`
- Create: `Tests/RawProcessingCoreTests/DCPProfileMatrixResolverTests.swift`
- Modify: `Sources/RawProcessingCore/Profile/DCPProfileDocument.swift) only for typed accessors proven by RED tests

**Interfaces:**
- Consumes: validated `DCPProfileDocument`, camera CCT／illuminant metadata, and a declared working color space at the admission boundary.
- Produces: a pure `DCPResolvedMatrix` in D50 XYZ matrix space with matrix provenance and no Core Image object; working-space conversion is intentionally deferred to the later renderer admission task.

- [x] **Step 1: RED vectors**

Matrix selection has no pixel or hue input, so it is hue-independent by construction; hue wrap and shortest circular interpolation are tested in P3 HueSatMap rather than duplicated here.

Test identity matrices, one illuminant, two illuminants in reciprocal-temperature space, shortest hue-independent matrix selection, ForwardMatrix preference, ColorMatrix fallback with explicit D50 adaptation, singular matrix rejection, and camera mismatch rejection.

```bash
swift test --filter DCPProfileMatrixResolverTests
```

Expected: RED because the resolver does not exist.

- [x] **Step 2: Minimal GREEN implementation**

Implement only matrix selection, reciprocal-temperature interpolation, finite-value validation, and D50 adaptation. Keep all profile table application out of this task.

- [x] **Step 3: Verify**

```bash
swift test --filter DCPProfileMatrixResolverTests
swift test --filter 'DCPProfileParserTests|DCPProfileMatrixResolverTests'
```

Expected: all tests PASS; no recipe or renderer changes.

**Stop condition:** matrix output is non-deterministic, ForwardMatrix/ColorMatrix precedence is ambiguous, or a missing matrix is silently replaced with identity.

**Do not touch:** decoder option defaults, output transform, user sliders, calibration artifacts, production registry, preview/export services.

---

### Task P3: HueSatMap and LookTable Pure Stages

**Files:**
- Create: `Sources/RawProcessingCore/Profile/DCPHueSatMap.swift`
- Create: `Sources/RawProcessingCore/Profile/DCPLookTable.swift`
- Create: `Tests/RawProcessingCoreTests/DCPHueSatMapTests.swift`
- Create: `Tests/RawProcessingCoreTests/DCPLookTableTests.swift`

**Interfaces:**
- Consumes: validated dimensions and numeric table payloads from `DCPProfileDocument).
- Produces: deterministic RGB transforms over normalized linear pixels; no image file I/O.

- [x] **Step 1: RED isolation vectors**

Cover storage order, hue wrap using the shortest circular path, saturation/value boundaries, trilinear interpolation, table encoding, dual-illuminant blend, identity table, malformed dimensions, and non-finite samples.

```bash
swift test --filter 'DCPHueSatMapTests|DCPLookTableTests'
```

Expected: RED because table stages do not exist.

- [x] **Step 2: Minimal implementation**

Implement table sampling and validation as pure value types. Do not attach either stage to `AdjustmentPipeline`.

- [x] **Step 3: GREEN**

```bash
swift test --filter 'DCPHueSatMapTests|DCPLookTableTests'
swift test --filter 'DCPProfileParserTests|DCPProfileMatrixResolverTests|DCPHueSatMapTests|DCPLookTableTests'
```

Expected: all PASS, deterministic repeated output, no production enablement.

**Stop condition:** interpolation order differs from the documented layout, a malformed table is partially applied, or any implementation needs a per-photo branch.

**Do not touch:** user adjustment controls, XMP patch application, production registries, camera fallback v1, UI.

---

### Task P4: ProfileToneCurve and Profile Metadata

**Files:**
- Create: `Sources/RawProcessingCore/Profile/DCPProfileToneCurve.swift`
- Create: `Tests/RawProcessingCoreTests/DCPProfileToneCurveTests.swift`
- Modify: none; `DCPProfileDocument.swift` remains unchanged until a typed accessor is required by a later RED test

**Interfaces:**
- Consumes: validated profile curve and metadata.
- Produces: hue-preserving, monotonic tone transform and explicit metadata operations.

- [x] **Step 1: RED**

Test identity curve, monotonic knots, repeated/decreasing x rejection, out-of-domain rejection, NaN rejection, hue preservation, `BaselineExposureOffset`, and `DefaultBlackRender`. Assert that no operation creates an editable Exposure adjustment or dirty state.

```bash
swift test --filter DCPProfileToneCurveTests
```

Expected: RED because the curve type does not exist.

- [x] **Step 2: GREEN**

Implement monotonic validation and interpolation. Keep profile metadata separate from `PhotoAdjustments`; do not reuse the user Exposure field.

- [x] **Step 3: Verify**

```bash
swift test --filter DCPProfileToneCurveTests
swift test --filter 'DCPProfileToneCurveTests|PhotoAdjustmentsTests|XMPFeatureCapabilityTests'
```

Expected: PASS; existing adjustment persistence remains unchanged.

**Stop condition:** profile metadata changes a user slider, writes a fake edit badge, or curve validation accepts a non-monotonic profile.

**Do not touch:** Basic tone, Presence, Curve, Detail, Grain, masks, sidecar schema, undo manager.

---

### Task P5: XMP RGBTable Codec and Parse-Only Capability

**Files:**
- Create: `Sources/PresetCore/XMP/AdobeRGBTable.swift`
- Create: `Sources/PresetCore/XMP/AdobeRGBTableCodec.swift`
- Create: `Tests/PresetCoreTests/AdobeRGBTableCodecTests.swift`
- Modify: `Sources/PresetCore/XMP/XMPFeatureCapability.swift` only after RED tests prove the diagnostic transition
- Modify: `Sources/PresetCore/XMP/XMPImportExport.swift` only for lossless preserved payload metadata

**Interfaces:**
- Consumes: XMP property text or a bounded Data payload.
- Produces: validated RGBTable document, round-trip encoding, and `preserved／importOnly` capability when render order is not proven.

- [x] **Step 1: RED codec tests**

Test Adobe custom base85, zlib, version, dimensions, exact uncompressed length, delta reconstruction, neutral ramp, 1D／3D sampling, malformed alphabet, truncated compressed bytes, decompression limit, and round-trip. Test that importing a valid table does not claim applied rendering.

```bash
swift test --filter AdobeRGBTableCodecTests
```

Expected: RED because the codec does not exist.

- [x] **Step 2: Minimal GREEN codec**

Implement bounded decode and pure table sampling. Preserve the original request metadata without storing private source paths or source hashes. Keep capability as `preserved／importOnly` until stage order evidence exists.

- [x] **Step 3: GREEN and regression**

```bash
swift test --filter AdobeRGBTableCodecTests
swift test --filter 'XMPImportExportTests|XMPFeatureCapabilityTests|LightroomXMPFixtureTests'
```

Expected: PASS; existing XMP round-trip remains intact and no RGBTable reaches production rendering.

**Evidence (2026-09-23):** RED first failed because `AdobeRGBTable`, `AdobeRGBTableCodec`, and `AdobeRGBTableCodecError` did not exist. Minimal GREEN added bounded custom base85／zlib decoding, exact payload size checks, DCP-style header/footer and delta reconstruction, B-fastest trilinear sampling, and synthetic round-trip vectors. Two fail-closed bugs found by malformed/endpoint vectors were fixed: identity endpoint rounding now uses the denominator midpoint, and base85 padding uses non-negative remainder arithmetic. `AdobeRGBTableCodecTests` 8/8 PASS; `XMPImportExportTests|XMPFeatureCapabilityTests|LightroomXMPFixtureTests` 41 executed, 3 skipped, 0 failures; the 3 skips are the intentionally unconfigured private Lightroom corpus. P1-P5 profile suite 45/45 PASS. RGBTable remains `preserved`／`importOnly` and no renderer or registry path was changed.

**Stop condition:** decompression can exceed limits, RGBTable import changes effective policy, or a valid parse is incorrectly reported as applied.

**Do not touch:** Raw decoder options, DCP renderer, production registry, private XMP fixtures, UI.

---

### Task P6: Atomic v2 Artifact and Fail-Closed Recipe Resolution

**Files:**
- Create: `Sources/RawProcessingCore/Profile/DCPProfileArtifactV2.swift`
- Create: `Tests/RawProcessingCoreTests/DCPProfileFailClosedTests.swift`
- Modify only after RED tests: `Sources/RawProcessingCore/Decoding/RawRenderRecipe.swift`, `Sources/RawProcessingCore/Decoding/RawRenderRecipeResolver.swift`
- Modify only after RED tests: `Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift`, `Sources/RawProcessingCore/Pipeline/ImageRenderService.swift`

**Interfaces:**
- Consumes: validated v2 artifact, feature flag, camera/profile scope, persisted policy.
- Produces: complete Native or complete admitted profile recipe; never a hybrid recipe.

- [x] **Step 1: RED fail-closed tests**

Add process-level behavior tests for feature flag off, empty production registry, malformed artifact, scope mismatch, old recipe without effective policy, runtime stage error, app restart, Undo, Reset, copy/paste, batch export, preview/export recipe parity, and exact Native pixel digest.

```bash
swift test --filter DCPProfileFailClosedTests
```

Expected: RED for the new v2 artifact/resolver contract.

- [x] **Step 2: Minimal GREEN**

Add a test-only registry and versioned artifact identity. Resolver must retain `persistedPolicy == .adobeProcess2012V1) but emit `effectivePolicy == .native) unless every admission condition is satisfied. Runtime errors must downgrade before rendering or rerun with the complete Native recipe.

- [x] **Step 3: GREEN regression**

```bash
swift test --filter 'DCPProfileFailClosedTests|ControlledRendererEnablementTests|RawRenderRecipeResolverTests|PreviewExportRecipeParityTests|BatchExportQueueTests'
```

Expected: all PASS; `ProfileCalibrationArtifactManifestsV1.all) remains empty and the default flag remains false.

**Evidence (2026-09-23):** RED failed because `DCPProfileArtifactV2` and the atomic `admittedArtifacts` resolver initializer did not exist. GREEN added a schema-versioned wrapper that validates fallback／manifest as one unit and a resolver path that admits only an exact camera/profile/runtime binding. Focused `DCPProfileFailClosedTests` 5/5 PASS; regression `DCPProfileFailClosedTests|ControlledRendererEnablementTests|RawRenderRecipeResolverTests|PreviewExportRecipeParityTests|BatchExportQueueTests` 31/31 PASS. Persisted Adobe policy remains visible while effective recipe is Native when reopened or when scope/runtime binding fails. Default registry remains empty and flag default remains false.

**Stop condition:** any persisted Adobe request produces an effective Adobe render without a production manifest, or preview/export/undo/copy/batch diverge.

**Do not touch:** production registry contents, feature flag default, v1 artifact, UI, main branch.

---

### Task P7: Reference Comparator, Sanitized Reporting, and Cross-Oracle Evidence

**Files:**
- Modify only with RED evidence: `Sources/RawProcessingCore/Diagnostics/ReferenceImageBuffer.swift`, `ReferenceImageMetadataValidator.swift`, `ReferenceComparisonMetrics.swift`, `Sources/LumaHarborReferenceCompare/main.swift`
- Create: `Tests/LumaHarborAppTests/DCPProfileProcessTests.swift` if a process boundary is needed
- Modify only if a real defect is reproduced: `Scripts/validate-lr-reference-matrix.zsh`

**Interfaces:**
- Consumes: environment-provided private references and sanitized matrix IDs.
- Produces: 16-bit encoded-sRGB validation, clipping metrics v2, `--all-neutral` reports and process-level exit codes without private identifiers.

- [x] **Step 1: RED process tests**

Launch the real comparator executable and test missing input, invalid TIFF bit depth／ICC／dimensions, placeholder detection, duplicate reference rejection, all-neutral exit status, sanitized JSON, and output path traversal rejection.

```bash
swift build --product LumaHarborReferenceCompare
swift test --filter 'ReferenceCompareProcessTests|DCPProfileProcessTests'
```

Expected: RED only for missing DCP/XMP-specific contracts; existing comparator contracts must remain green.

- [x] **Step 2: Minimal implementation**

Reuse the existing bounded streaming reader and validator. Add no private fixture to the repository and redact basename, absolute path, source hash and camera serial from reports.

- [x] **Step 3: GREEN**

```bash
swift test --filter 'ReferenceCompareProcessTests|ReferenceImageMetadataValidatorTests|ReferenceComparisonStreamingTests'
swift test --filter 'ReferenceComparisonMetricsTests|ReferenceComparisonPerformanceTests'
Scripts/validate-lr-reference-matrix.zsh <sanitized-matrix-json>
```

Expected: process tests exercise the real CLI, malformed references fail before pixel loading, and sanitized reports contain stable IDs only.

**Evidence (2026-09-23):** `swift build --product LumaHarborReferenceCompare` PASS. Real process tests `ReferenceCompareProcessTests` 9/9 PASS, including `--all-neutral`, missing references／non-zero `NOT RUN`, sanitized JSON, atomic report destination protections, 16-bit encoded-sRGB error magnitude, and typed neutral mode. Metadata／streaming suites 7/7 PASS; metrics suite 8/8 PASS. Full-resolution performance test 1 skipped because `LUMAHARBOR_RUN_FULL_RES_PERF` was not opted in; no failure. No private paths, filenames, hashes, RAW/XMP/TIFF fixtures or camera serials were added to the repository.

**Stop condition:** a private path, hash, filename, placeholder, wrong bit depth, wrong ICC, or duplicate payload reaches Git or a report.

**Do not touch:** renderer coefficients, profile admission, private reference files, unrelated UI diagnostics.

---

### Task P8: Formal Gate 2, Controlled Admission, and Cross-Platform Acceptance

**Files:**
- Modify: `docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md` with sanitized evidence only
- Modify: `docs/coordination/CURRENT.md` with observed status only
- Modify production registry only in a separately reviewed admission change after every gate passes

**Interfaces:**
- Consumes: four unique 16-bit encoded-sRGB Lightroom/LumaHarbor paired references, independent hold-out, test registry evidence, and Mac/iPad build outputs.
- Produces: either `READY ONLY WITH RENDERER DISABLED` or an explicitly reviewed camera/profile-scoped admission proposal.

- [x] **Step 1: Run the formal matrix**

```bash
swift test
swift build -Xswiftc -strict-concurrency=complete
Scripts/build-app-bundle.sh debug
(cd Apps/LumaHarborPad.swiftpm && xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build)
swift test --filter 'DCPProfileFailClosedTests|PreviewExportRecipeParityTests|ControlledRendererEnablementTests'
git diff --check
```

Expected: record exact executed／skipped／failed counts; do not convert missing physical-device or private-reference evidence into PASS.

**Evidence (2026-09-23):** `swift test` completed with 2,546 executed, 17 skipped, and 0 failures; the earlier one-off signal 11 did not reproduce on rerun. `swift build -Xswiftc -strict-concurrency=complete` PASS; `Scripts/build-app-bundle.sh debug` PASS; generic iPad Simulator `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` PASS; focused parser／fail-closed／process suite 22/22 PASS; `git diff --check` PASS. Full-resolution performance remains 1 skipped without opt-in. A local untracked Lightroom corpus audit found 28 diagnostic TIFFs, all 150×100 8-bit RGB with embedded ICC; no matching LumaHarbor pairs were present, so these files do not satisfy the formal 16-bit reference contract. Separately, the real-ARW export smoke test generated five private, repository-external LumaHarbor neutral TIFFs and passed 1/1, confirming the LumaHarbor side can emit 7008×4672 16-bit RGB embedded-sRGB output. This is build and regression evidence only: formal private 4/4 reference comparison, hold-out, and physical-device acceptance remain `NOT RUN`.

- [ ] **Step 2: Run training／hold-out**

Use environment-provided private paths only. Freeze training and hold-out IDs before calibration, run `--all-neutral`, compare MAE／P95／SSIM／clipping per case, and reject any artifact that improves training but fails hold-out.

- [ ] **Step 3: Perform Mac and iPad parity**

For the same RAW, persisted policy, artifact identity, decoder options, working/output spaces, recipe, dimensions and pixel digest must match. Install on a physical iPad when available; otherwise mark the device gate `NOT RUN`.

- [ ] **Step 4: Decide admission**

If any gate fails or is `NOT RUN`, keep registry empty and flag false. Only after all gates PASS may a separate reviewed change populate one camera/profile entry. This task itself must not silently enable the renderer.

**Stop condition:** neutral 4/4, hold-out, cross-platform parity, performance, privacy, or physical-device evidence is missing or failing.

**Do not touch:** main, unrelated branches/worktrees, private source files, UI redesign, user adjustment compensation, historical report conclusions.

---

## Required Luna Handoff and Reporting

At the end of each task, report:

- exact modified and unmodified files;
- RED command, observed failure, minimal GREEN change, and GREEN command;
- test count, skip count, failure count, exit code;
- whether any gate is PASS, FAIL, SKIPPED, or NOT RUN;
- dirty path count and whether private-material scan passed;
- one bounded next action.

Before this plan is considered complete, run:

```bash
git diff --check
git status --short --branch
git status --short | wc -l
swift test --filter DCPProfileParserTests
```

The expected final state for any incomplete Gate 2 run is:

```text
READY ONLY WITH RENDERER DISABLED
production registry: empty
Adobe feature flag: false
physical iPad: NOT RUN unless actually installed and tested
```
