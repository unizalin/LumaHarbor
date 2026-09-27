# Lightroom 相容 Neutral RAW Baseline v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓新匯入 RAW 使用版本化、可稽核的 Lightroom 相容 neutral baseline，同時維持既有照片的 native 外觀；Mac、iPad、preview 與 export 必須共用同一份 resolved render recipe，並以四張原尺寸 16-bit sRGB Lightroom reference 全數通過 Gate 2。

**Architecture:** 將「照片持久化的顯色政策」與「使用者調整值」分離，由 `RawProcessingCore` 的純值 resolver 產生版本化 `ResolvedRawRenderRecipe`。`CoreImageRawDecoder` 只依 recipe 設定固定 decoder version、As Shot 白平衡、lens 與 CIRAW option vector；`ImageRenderService` 依 recipe 選擇 native 或 wide-linear 工作色域與 output transform。`PresetCore` 只把 XMP Camera Profile 轉成 request，profile registry、fallback renderer 與 provenance 由 `RawProcessingCore` 擁有。Mac library 與 iPad document store 分別保存照片的預設政策，舊資料缺欄位一律維持 native。

**Tech Stack:** Swift 5.9、SwiftPM、XCTest、Core Image、Core Graphics／ColorSync、ImageIO、SwiftUI、macOS 14+、iOS／iPadOS 17+。

## Global Constraints

- 本計劃只實作 `C0` Neutral RAW／Profile baseline；不得用 Exposure、Basic tone、Presence、Curve、Calibration、Detail 或 mask 補償 neutral 差異。
- `native` 路徑的像素、既有 sidecar 解碼、render hash 與 UI 行為必須保持不變。
- 舊 record／document／sidecar 缺少新欄位時一律解碼為 `.native`；新 RAW 才預設 `.adobeProcess2012V1`，非 RAW 保持 `.native`。
- Adobe 相容路徑的任何像素行為變更都必須建立新的 policy／option vector／profile fallback／color-space 版本，不得靜默改寫 v1。
- 私人 RAW、Lightroom 輸出、XMP、Adobe 專有 table、digest 與本機絕對路徑不得加入 Git、測試輸出或報告。
- Preview、single export、batch export、Mac 與 iPad 不得各自重新解析政策；它們只能使用同一 resolver 產生的 recipe。
- 參考影像缺失、ICC／位元深度／尺寸不符、decoder fallback 未核准時必須回報 `NOT RUN` 或 `FAIL`，不得視為通過。
- 所有 production 變更採 TDD：先加入可觀察到正確失敗原因的測試，再寫最小實作。
- 每個 task 完成後只提交該 task 的檔案；不得覆蓋目前工作樹中其他代理或使用者尚未提交的變更。
- Task 1 至 Task 8 任一停止條件成立時，立即停止後續像素校正並保留診斷證據。
- 完成前必須執行 focused tests、完整 `swift test`、strict concurrency、macOS build、iPad generic build、實體 iPad smoke、reference matrix、`git diff --check` 與隱私掃描。

---

### Task 1: 分離 baseline policy 與使用者編輯狀態

**Files:**
- Modify: `Sources/RawProcessingCore/Decoding/RawDecoding.swift`
- Modify: `Sources/RawProcessingCore/Model/PhotoAdjustments.swift`
- Modify: `Sources/PhotoLibraryCore/Model/EditHistory.swift`
- Modify: `Sources/PresetCore/Application/PresetApplicator.swift`
- Test: `Tests/RawProcessingCoreTests/RawDecodingTests.swift`
- Test: `Tests/RawProcessingCoreTests/PhotoAdjustmentsTests.swift`
- Test: `Tests/PhotoLibraryCoreTests/EditHistoryTests.swift`
- Test: `Tests/PresetCoreTests/PresetApplicatorTests.swift`

**Interfaces:**

```swift
public enum RawRenderingCompatibility: String, Codable, Hashable, Sendable {
    case native
    case adobeProcess2012V1 = "adobeProcess2012"
}

extension PhotoAdjustments {
    public static func neutral(using policy: RawRenderingCompatibility) -> Self
    public var hasUserAdjustments: Bool { get }
}
```

- `PhotoAdjustments.isNeutral` 保留 source compatibility，但改為 `!hasUserAdjustments`；baseline policy 不形成 edit badge 或 dirty state。
- `Equatable`、Codable、Undo payload 與 render cache key 仍包含 `rawRenderingCompatibility`。
- `EditHistory.resetToNeutral()` 保留目前照片的 policy。
- Preset replace 以目前照片的 policy 建立 neutral base；Adobe XMP preview／commit 才切到 `.adobeProcess2012V1`，Undo 還原套用前 policy。
- 顯式 rollback 只把 policy 切回 `.native`，不得清除 adjustment 值、raw profile request、unknown XMP preservation data 或 originals。
- 舊 wire value `"adobeProcess2012"` 必須繼續 round-trip；不得另外寫出不相容的新字串。

- [ ] **Step 1: Write the failing tests**

加入下列案例：

```swift
func testAdobeBaselineIsStillVisuallyUnedited() {
    let value = PhotoAdjustments.neutral(using: .adobeProcess2012V1)
    XCTAssertTrue(value.isNeutral)
    XCTAssertFalse(value.hasUserAdjustments)
    XCTAssertNotEqual(value, .neutral)
}

func testResetPreservesPhotoBaselinePolicy() {
    var history = EditHistory(initial: .neutral(using: .adobeProcess2012V1))
    var adjusted = history.current
    adjusted.exposure = 1.0
    history.record(adjusted)
    history.resetToNeutral()
    XCTAssertEqual(history.current.rawRenderingCompatibility, .adobeProcess2012V1)
    XCTAssertFalse(history.current.hasUserAdjustments)
}
```

另加入 legacy Codable、preset replace、Adobe XMP preview／commit／undo、non-Adobe preset 不切換 policy，以及 Adobe v1 → native rollback 保留全部調整與 profile request 的測試。

- [ ] **Step 2: Run tests to verify the intended failure**

Run:

```bash
swift test --filter RawDecodingTests
swift test --filter PhotoAdjustmentsTests
swift test --filter EditHistoryTests
swift test --filter PresetApplicatorTests
```

Expected: 新測試因缺少 `.adobeProcess2012V1`、`neutral(using:)`、`hasUserAdjustments` 或 reset／replace 未保留 policy 而失敗；既有測試仍可編譯到相同失敗點。

- [ ] **Step 3: Implement the minimum policy semantics**

將現有 `.adobeProcess2012` Swift case 改名為 `.adobeProcess2012V1`，保留 raw value。新增 policy-aware neutral factory 與明確的 user-adjustment 判斷；`hasUserAdjustments` 比較所有可編輯欄位，但排除 baseline policy。修改 reset 與 replace base，不改任何 slider mapping 或 pipeline 順序。

- [ ] **Step 4: Run the focused tests**

Run the four commands from Step 2.

Expected: 全部通過；沒有 snapshot／golden 更新。

- [ ] **Step 5: Commit**

```bash
git add Sources/RawProcessingCore/Decoding/RawDecoding.swift Sources/RawProcessingCore/Model/PhotoAdjustments.swift Sources/PhotoLibraryCore/Model/EditHistory.swift Sources/PresetCore/Application/PresetApplicator.swift Tests/RawProcessingCoreTests/RawDecodingTests.swift Tests/RawProcessingCoreTests/PhotoAdjustmentsTests.swift Tests/PhotoLibraryCoreTests/EditHistoryTests.swift Tests/PresetCoreTests/PresetApplicatorTests.swift
git commit -m "feat: separate raw baseline policy from edits"
```

**Stop condition:** 任一既有 native adjustment 被判成不同 edit state、legacy wire value 無法解碼，或 Reset All 改變 native 照片像素時停止。

---

### Task 2: 持久化新舊照片的預設顯色政策

**Files:**
- Modify: `Sources/PhotoLibraryCore/Sidecar/LibraryManifest.swift`
- Modify: `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`
- Modify: `Sources/PhotoLibraryCore/Documents/PhotoDocumentStore.swift`
- Test: `Tests/PhotoLibraryCoreTests/PhotoLibraryServiceCurationTests.swift`
- Test: `Tests/PhotoLibraryCoreTests/PhotoDocumentStoreTests.swift`
- Test: `Tests/PhotoLibraryCoreTests/PhotoDocumentStoreListingTests.swift`
- Test: `Tests/PhotoLibraryCoreTests/CurationMigrationDecisionTests.swift`
- Create: `Tests/PhotoLibraryCoreTests/RawRenderingCompatibilityPersistenceTests.swift`

**Interfaces:**

```swift
public struct PhotoRecord: Codable, Hashable, Sendable {
    public var rawRenderingCompatibility: RawRenderingCompatibility?
}
```

- `LibraryManifest.currentSchemaVersion` 由 `1` 升為 `2`。
- Schema 1 或缺欄位的 record runtime policy 為 `.native`；migration 回填 native，且可重跑。
- 真正新發現的 RAW record 寫入 `.adobeProcess2012V1`；JPEG／PNG／TIFF 寫入 `.native`。
- 重新掃描同一檔案、rename／move、content unchanged 或已知 content change 必須保留 record policy，不得把既有照片當成新照片升級。
- `PhotoDocumentRecord` 使用相同 optional persistence 規則；新 iPad RAW document 寫入 Adobe v1，舊 document 缺值維持 native。
- 有 sidecar 時 sidecar policy 優先；沒有 sidecar時，以 record policy 建立 `PhotoAdjustments.neutral(using:)`。
- Virtual copy、duplicate、copy/paste 與 batch target 明確繼承來源 policy。

- [ ] **Step 1: Write the failing persistence matrix**

在 `RawRenderingCompatibilityPersistenceTests.swift` 建立 table-driven tests，至少涵蓋：

| Case | Expected policy |
| --- | --- |
| schema 1 record without field | native |
| schema 2 legacy-migrated record | native |
| new RAW record | adobeProcess2012V1 |
| new JPEG record | native |
| existing RAW discovered again | original policy |
| sidecar override | sidecar policy |
| iPad legacy document | native |
| iPad new RAW document | adobeProcess2012V1 |

另加入 migration 中斷後重跑、唯讀 library 不部分升級、virtual copy／duplicate 繼承 policy 的測試。

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter RawRenderingCompatibilityPersistenceTests
swift test --filter PhotoDocumentStoreTests
swift test --filter CurationMigrationDecisionTests
```

Expected: 新 record 尚無 policy、manifest schema 尚未升級，或 no-sidecar path 仍回傳 `.neutral` 而失敗。

- [ ] **Step 3: Implement migration and defaulting**

將 manifest decoder 對缺欄位保留 `nil`，由 migration 明確解讀成 native；建立新 record 時依媒體種類寫入具體值。掃描器合併新結果與既有 record 時保留既有 policy。iPad document store 採相同策略。所有 no-sidecar adjustments 都改用 record policy 建立 neutral value。

- [ ] **Step 4: Verify migration idempotency and persistence**

Run:

```bash
swift test --filter RawRenderingCompatibilityPersistenceTests
swift test --filter PhotoLibraryServiceCurationTests
swift test --filter PhotoDocumentStore
swift test --filter CurationMigrationDecisionTests
```

Expected: 全部通過；同一 manifest 連續 migration 兩次內容一致；舊資料不會被自動升級。

- [ ] **Step 5: Commit**

```bash
git add Sources/PhotoLibraryCore/Sidecar/LibraryManifest.swift Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift Sources/PhotoLibraryCore/Documents/PhotoDocumentStore.swift Tests/PhotoLibraryCoreTests/PhotoLibraryServiceCurationTests.swift Tests/PhotoLibraryCoreTests/PhotoDocumentStoreTests.swift Tests/PhotoLibraryCoreTests/PhotoDocumentStoreListingTests.swift Tests/PhotoLibraryCoreTests/CurationMigrationDecisionTests.swift Tests/PhotoLibraryCoreTests/RawRenderingCompatibilityPersistenceTests.swift
git commit -m "feat: persist versioned raw rendering policy"
```

**Stop condition:** migration 會改變既有照片 policy、只完成部分 library、或唯讀／離線 library 無法安全維持 native 時停止。

---

### Task 3: 建立單一 resolved render recipe 與 provenance

**Files:**
- Create: `Sources/RawProcessingCore/Decoding/RawRenderRecipe.swift`
- Create: `Sources/RawProcessingCore/Decoding/RawRenderRecipeResolver.swift`
- Modify: `Sources/RawProcessingCore/Decoding/RawDecoding.swift`
- Modify: `Sources/RawProcessingCore/Preview/PreviewRequest.swift`
- Modify: `Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift`
- Modify: `Sources/RawProcessingCore/Export/PhotoExporter.swift`
- Modify: `Sources/EditorCore/EditorSession.swift`
- Create: `Tests/RawProcessingCoreTests/RawRenderRecipeResolverTests.swift`
- Modify: `Tests/RawProcessingCoreTests/CoreImagePreviewRendererTests.swift`
- Modify: `Tests/RawProcessingCoreTests/PhotoExportTests.swift`
- Create: `Tests/RawProcessingCoreTests/PreviewExportRecipeParityTests.swift`
- Modify: `Tests/EditorCoreTests/EditorSessionEditingTests.swift`

**Interfaces:**

```swift
public struct RawCameraProfileRequest: Codable, Equatable, Hashable, Sendable {
    public var sourceName: String?
}

public struct ResolvedRawRenderRecipe: Codable, Equatable, Hashable, Sendable {
    public let policy: RawRenderingCompatibility
    public let decoder: RawDecoderRecipe
    public let whiteBalance: RawWhiteBalanceRecipe
    public let lensCorrection: RawLensRecipe
    public let cameraProfile: ResolvedRawCameraProfile
    public let decoderOptionVectorID: String
    public let workingColorSpaceID: String
    public let outputTransformID: String
    public let diagnostics: [RawRenderDiagnostic]
}

public protocol RawRenderRecipeResolving: Sendable {
    func resolve(
        _ input: RawRenderRecipeInput,
        capabilities: RawDecoderCapabilities
    ) -> ResolvedRawRenderRecipe
}

public struct RawRendererFeatureFlags: Codable, Equatable, Hashable, Sendable {
    public var adobeProcess2012V1Enabled: Bool
}
```

- 所有 recipe 子型別都符合 `Codable`, `Equatable`, `Hashable`, `Sendable`，只包含穩定 plain values。
- `RawDecodeRequest` 新增 `cameraProfileRequest`；preview／export 使用共用 request factory，不得自行組出不同 policy。
- `CoreImageRawDecoder` 建立 `CIRAWFilter` 後先產生 `RawDecoderCapabilities`，再交給 resolver 選出 recipe；decoder 只能套用該 recipe，不得另行猜 policy。
- Resolver 對 unsupported capability／feature disabled 不丟出未處理錯誤；它保留 persisted policy，產生可執行的 native fallback recipe，並加入固定 `rendererFeatureDisabled` 或 `recipeResolutionFallback` diagnostic。
- Feature flag 只控制新 renderer stage，不改寫 record／sidecar；關閉後仍可讀寫 Adobe v1 policy，重新開啟可恢復相同 recipe。
- `DecodedRawImage` 回傳實際 decoder version、orientation、WB、lens 與 diagnostics；requested 與 resolved 值可同時稽核。
- `PreviewImage` 可攜帶 recipe／provenance；保留既有 initializer 的 source compatibility。
- `ExportOutcome` 可攜帶 recipe／provenance；保留既有 initializer 的 source compatibility。
- `EditorSession` 發布最近一次成功 preview 的 recipe，失敗時不得沿用前一張照片的 recipe。
- Recipe 的 `Hashable` 值直接參與 preview cache key；quality 只允許改變 scale／draft／output bit depth。

- [ ] **Step 1: Write resolver and parity tests first**

測試至少斷言：

```swift
func testSameInputResolvesIdenticalRecipe() throws {
    let first = resolver.resolve(input, capabilities: capabilities)
    let second = resolver.resolve(input, capabilities: capabilities)
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.hashValue, second.hashValue)
}

func testPreviewAndExportReceiveTheSameFullQualityRecipe() async throws {
    let preview = try await previewRenderer.render(fullQualityRequest)
    let export = try await exporter.export(exportRequest)
    XCTAssertEqual(preview.rawRenderRecipe, export.rawRenderRecipe)
}
```

另測 native／Adobe v1、non-RAW、missing metadata diagnostic、不同 quality 只改合法欄位、serialized recipe round-trip、feature flag 關閉仍保留 persisted policy、resolution fallback，以及 EditorSession 清除 stale provenance。

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter RawRenderRecipeResolverTests
swift test --filter PreviewExportRecipeParityTests
swift test --filter CoreImagePreviewRendererTests
swift test --filter EditorSessionEditingTests
```

Expected: 缺少 recipe 型別／resolver 或 preview、export 尚未暴露相同 recipe 而失敗。

- [ ] **Step 3: Implement plain-value recipe without changing pixels**

先讓 resolver 精確描述現況：native 使用 `coreImage/system-default`、`extended-linear-srgb-v1` 與既有 output transform；Adobe v1 暫時解析成相同像素路徑，但使用獨立 IDs 並加入 `rendererNotCalibrated` diagnostic。把同一 recipe 傳入 decoder、preview、export 與 cache key；此 step 不改 `CIRAWFilter` option 或 color space。

- [ ] **Step 4: Verify observability-only behavior**

Run:

```bash
swift test --filter RawRenderRecipeResolverTests
swift test --filter PreviewExportRecipeParityTests
swift test --filter CoreImagePreviewRendererTests
swift test --filter EditorSession
swift test --filter PhotoExportTests
```

Expected: tests pass；native golden pixels／hash 完全不變；recipe JSON 不含檔案路徑。

- [ ] **Step 5: Commit**

```bash
git add Sources/RawProcessingCore/Decoding/RawRenderRecipe.swift Sources/RawProcessingCore/Decoding/RawRenderRecipeResolver.swift Sources/RawProcessingCore/Decoding/RawDecoding.swift Sources/RawProcessingCore/Preview/PreviewRequest.swift Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift Sources/RawProcessingCore/Export/PhotoExporter.swift Sources/EditorCore/EditorSession.swift Tests/RawProcessingCoreTests/RawRenderRecipeResolverTests.swift Tests/RawProcessingCoreTests/CoreImagePreviewRendererTests.swift Tests/RawProcessingCoreTests/PhotoExportTests.swift Tests/RawProcessingCoreTests/PreviewExportRecipeParityTests.swift Tests/EditorCoreTests/EditorSessionEditingTests.swift
git commit -m "feat: resolve shared raw render recipes"
```

**Stop condition:** 加入 provenance 後任何 native pixel hash 改變、preview 與 export recipe 不一致，或 recipe 序列化含私人路徑時停止。

---

### Task 4: 實作 deterministic Core Image RAW decode policy

**Files:**
- Create: `Sources/RawProcessingCore/Decoding/CoreImageRawPolicy.swift`
- Modify: `Sources/RawProcessingCore/Decoding/CoreImageRawDecoder.swift`
- Modify: `Sources/RawProcessingCore/Decoding/RawRenderRecipeResolver.swift`
- Create: `Tests/RawProcessingCoreTests/CoreImageRawPolicyTests.swift`
- Modify: `Tests/RawProcessingCoreTests/RawDecodingTests.swift`
- Create: `Tests/RawProcessingCoreTests/CoreImageRawDecoderPrivateFixtureTests.swift`

**Interfaces:**

```swift
public struct CoreImageRawOptionVector: Codable, Equatable, Hashable, Sendable {
    public static let adobeProcess2012V1: Self
    public let id: String
    public let exposure: Float
    public let baselineExposure: Float
    public let shadowBias: Float
    public let boostAmount: Float
    public let boostShadowAmount: Float
    public let gamutMappingEnabled: Bool
    public let luminanceNoiseReductionAmount: Float
    public let colorNoiseReductionAmount: Float
    public let sharpnessAmount: Float
    public let contrastAmount: Float
    public let detailAmount: Float
    public let moireReductionAmount: Float
    public let localToneMapAmount: Float
    public let extendedDynamicRangeAmount: Float
    public let highlightRecoveryEnabled: Bool?
}
```

- Native path 不設定新的 option，保留 system-default。
- Adobe v1 selector 由 `CIRAWFilter.supportedDecoderVersions` 選擇固定、Mac／iPad 皆可用的 decoder version；選不到才 fallback，並加入 `rawDecoderVersionFallback`。
- Adobe v1 對規格列出的每個 CIRAW property 明確賦值；availability 不支援時記錄固定 diagnostic。
- TIFF orientation 由 metadata 明確設定。
- Neutral 使用 decoder As Shot `neutralTemperature`／`neutralTint`，不得額外插入 `CITemperatureAndTint`。
- Lens auto requested／supported／enabled 狀態全部進 provenance。
- 私有 RAW test 只讀 `LUMAHARBOR_RAW_FIXTURE_DIR`，缺少時 `XCTSkip`；錯誤與 JSON 不輸出路徑。

- [ ] **Step 1: Write failing option-vector tests**

加入每一個 property 的固定值測試、decoder version selection table、unsupported availability diagnostic、orientation mapping、missing WB fallback 與 lens status。私有 fixture test 驗證同一 RAW 連續解碼兩次的 serialized provenance 與像素 hash 一致。

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter CoreImageRawPolicyTests
swift test --filter RawDecodingTests
LUMAHARBOR_RAW_FIXTURE_DIR="$LUMAHARBOR_RAW_FIXTURE_DIR" swift test --filter CoreImageRawDecoderPrivateFixtureTests
```

Expected: 純值 tests 因 option vector／selector 尚不存在而失敗；未設定私有 fixture 時第三項明確 skip。

- [ ] **Step 3: Implement the policy adapter**

把 decoder version selection 與 option vector 保持為可單測純函式；`CoreImageRawDecoder` 只負責把 resolved values 寫入 `CIRAWFilter`。先使用「關閉創意 tone／detail 增強」的零值向量，baseline exposure、EDR、highlight recovery 與 gamut mapping 由 reference 消融結果調整，但每次改動都必須改 option vector ID。將實際 read-back 值寫入 provenance。

- [ ] **Step 4: Verify determinism and native isolation**

Run:

```bash
swift test --filter CoreImageRawPolicyTests
swift test --filter CoreImageRawDecoderPrivateFixtureTests
swift test --filter CoreImagePreviewRendererTests
```

Expected: 相同 fixture 連續 decode 結果一致；native fake／fixture tests 與既有 hash 不變；fallback cases 不會被標示為正式相容。

- [ ] **Step 5: Commit**

```bash
git add Sources/RawProcessingCore/Decoding/CoreImageRawPolicy.swift Sources/RawProcessingCore/Decoding/CoreImageRawDecoder.swift Sources/RawProcessingCore/Decoding/RawRenderRecipeResolver.swift Tests/RawProcessingCoreTests/CoreImageRawPolicyTests.swift Tests/RawProcessingCoreTests/RawDecodingTests.swift Tests/RawProcessingCoreTests/CoreImageRawDecoderPrivateFixtureTests.swift
git commit -m "feat: add deterministic Core Image raw policy"
```

**Stop condition:** 必須依單張照片設 option、As Shot WB 需要事後 slider 補償、固定 decoder 在 reference RAW 不支援，或 native hash 改變時停止並更新證據，不進 Task 5。

---

### Task 5: 導入版本化 wide-linear 工作色域與共同 output transform

**Files:**
- Create: `Sources/RawProcessingCore/Pipeline/RawColorSpace.swift`
- Modify: `Sources/RawProcessingCore/Pipeline/ImageRenderService.swift`
- Modify: `Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift`
- Modify: `Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift`
- Modify: `Sources/RawProcessingCore/Export/PhotoExporter.swift`
- Create: `Tests/RawProcessingCoreTests/RawColorSpaceTests.swift`
- Create: `Tests/RawProcessingCoreTests/ImageRenderServiceColorSpaceTests.swift`
- Modify: `Tests/RawProcessingCoreTests/PhotoExportTests.swift`
- Modify: `Tests/RawProcessingCoreTests/PreviewExportRecipeParityTests.swift`

**Interfaces:**

```swift
public enum RawWorkingColorSpaceID: String, Codable, Hashable, Sendable {
    case nativeExtendedLinearSRGBV1
    case adobeCompatibleLinearWideGamutV1
}

public enum RawOutputTransformID: String, Codable, Hashable, Sendable {
    case displaySRGBV1
    case referenceTIFFSRGB16V1
}
```

- Native context 繼續使用現有 `extendedLinearSRGB`。
- Adobe v1 建立公開定義、跨平台可重現的 linear wide-gamut color space；primaries、white point、transfer function 與 chromatic adaptation 由測試鎖定。
- `ImageRenderService` 依 recipe 建立／選擇 CIContext 與 output color space，不從呼叫端猜 policy。
- Profile、Calibration 與 tone stage 前不得限制到 sRGB primaries。
- 正式 reference output 為原尺寸、16-bit TIFF、embedded sRGB ICC、無 resize、無 output sharpening、無 watermark。
- Preview 與 export 使用相同 working/output transform family；只允許位元深度與尺寸不同。

- [ ] **Step 1: Write failing color-space tests**

測試 wide-linear RGB primaries／white point／linear transfer、recipe IDs、16-bit TIFF bits-per-component、embedded ICC、preview/export 共用 transform family，以及 native service 仍建立原本 context。

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter RawColorSpaceTests
swift test --filter ImageRenderServiceColorSpaceTests
swift test --filter PreviewExportRecipeParityTests
```

Expected: 缺少版本化 color-space 型別或 export 尚未嵌入可驗證 profile 而失敗。

- [ ] **Step 3: Implement recipe-driven color management**

將 color-space construction 集中於 `RawColorSpace.swift`，不得在 preview／export 重複建立不同定義。`AdjustmentPipeline` 接收工作色域 context 或 recipe，不在 Adobe v1 路徑提前套用 sRGB tone curve。`PhotoExporter` 依 output transform 明確指定 16-bit TIFF 與 ICC。

- [ ] **Step 4: Verify output contract**

Run:

```bash
swift test --filter RawColorSpaceTests
swift test --filter ImageRenderServiceColorSpaceTests
swift test --filter PreviewExportRecipeParityTests
swift test --filter PhotoExportTests
```

Expected: 全部通過；reference TIFF metadata 顯示 16-bit sRGB；native golden hash 不變。

- [ ] **Step 5: Commit**

```bash
git add Sources/RawProcessingCore/Pipeline/RawColorSpace.swift Sources/RawProcessingCore/Pipeline/ImageRenderService.swift Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift Sources/RawProcessingCore/Export/PhotoExporter.swift Tests/RawProcessingCoreTests/RawColorSpaceTests.swift Tests/RawProcessingCoreTests/ImageRenderServiceColorSpaceTests.swift Tests/RawProcessingCoreTests/PhotoExportTests.swift Tests/RawProcessingCoreTests/PreviewExportRecipeParityTests.swift
git commit -m "feat: add versioned raw color management"
```

**Stop condition:** ICC 缺失、wide-linear 定義在 Mac／iPad 不一致、preview 與 export transform 分歧，或 native hash 改變時停止。

---

### Task 6: 將 XMP Camera Profile 納入共用 request 與 registry

**Files:**
- Create: `Sources/RawProcessingCore/Profile/AdobeCompatibleProfileRegistry.swift`
- Create: `Sources/RawProcessingCore/Profile/RawCameraProfileSelection.swift`
- Modify: `Sources/RawProcessingCore/Model/PhotoAdjustments.swift`
- Modify: `Sources/PresetCore/Model/AdjustmentFieldID.swift`
- Modify: `Sources/PresetCore/Model/AdjustmentPatch.swift`
- Modify: `Sources/PresetCore/Model/PhotoAdjustmentsFieldAccess.swift`
- Modify: `Sources/PresetCore/XMP/XMPImportExport.swift`
- Modify: `Sources/PresetCore/XMP/AdobeProfileRegistry.swift`
- Modify: `Sources/PresetCore/Application/PresetApplicator.swift`
- Create: `Tests/RawProcessingCoreTests/AdobeCompatibleProfileRegistryTests.swift`
- Modify: `Tests/PresetCoreTests/AdjustmentPatchTests.swift`
- Modify: `Tests/PresetCoreTests/XMPCompositeImportTests.swift`
- Modify: `Tests/PresetCoreTests/PresetApplicatorTests.swift`

**Interfaces:**

```swift
public struct RawCameraProfileSelection: Codable, Equatable, Hashable, Sendable {
    public var requestedName: String?
}

public enum RawCameraProfileCompatibility: String, Codable, Equatable, Hashable, Sendable {
    case approximate
    case preservedNotApplied
}

public struct CameraMatch: Codable, Equatable, Hashable, Sendable {
    public let make: String
    public let model: String
}

public struct AdobeCompatibleProfileDescriptor: Codable, Equatable, Hashable, Sendable {
    public let sourceName: String
    public let cameraMatch: CameraMatch
    public let fallbackID: String
    public let fallbackVersion: Int
    public let compatibility: RawCameraProfileCompatibility
    public let provenance: String
}
```

- `PhotoAdjustments.rawCameraProfile` 與 adjustment patch 保存 requested Adobe name；不可借用既有 creative `RenderingProfileSelection`。
- `RawProcessingCore` registry 擁有 alias、camera match、fallback ID／version、compatibility 與合法 provenance。
- `RawCameraProfileCompatibility` 與 `CameraMatch` 定義在 `RawProcessingCore`；不得引用 `PresetCore.XMPCompatibilityLevel`。`PresetCore` adapter 只負責把共用結果映射成 XMP capability 文案。
- `PresetCore` 現有 `AdobeProfileRegistry` 移除 renderer ownership，僅保留薄 adapter 或刪除並改呼叫共用 registry。
- `XMPImportExport` 將 `CameraProfile` 寫入 patch；unknown name 原值完整保存。
- Adobe Color／Adobe Standard 在 reference camera 可解析成 `approximate` descriptor；unknown camera／profile 解析成 system-neutral fallback 並加入 `profilePreservedNotApplied`。
- Preview 不寫 sidecar；commit 形成一筆 Undo；Undo 還原 profile request 與 policy。

- [x] **Step 1: Write failing profile ownership tests**

加入 Adobe Color／Adobe Standard alias、camera-specific match、unknown camera、unknown profile、XMP round-trip、patch extraction、preview no-write、commit／undo 的測試。加入 dependency contract，確保 `RawProcessingCore` 不依賴 `PresetCore`。

- [x] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter AdobeCompatibleProfileRegistryTests
swift test --filter AdjustmentPatchTests
swift test --filter XMPCompositeImportTests
swift test --filter PresetApplicatorTests
```

Expected: CameraProfile 目前只能 preserved、無法進 adjustment／recipe，或 registry 位於錯誤模組而失敗。

- [x] **Step 3: Implement profile request and registry adapter**

先完成名稱與 camera metadata 到 descriptor 的純值解析，不在本 task 改像素。XMP importer 寫入 request，applicator 在 Adobe packet 實際含 profile／Adobe rendering property 時切換 Adobe v1 policy。Unknown 值必須保存且 diagnostics 誠實顯示未套用。

- [x] **Step 4: Verify round-trip and ownership**

Run the four commands from Step 2, then:

```bash
swift test --filter XMPFeatureCapabilityTests
swift test --filter PhotoAdjustmentsTests
```

Expected: tests pass；creative rendering profile 行為不變；unknown profile 不會被標示為 approximate。

- [x] **Step 5: Commit**

```bash
git add Sources/RawProcessingCore/Profile/AdobeCompatibleProfileRegistry.swift Sources/RawProcessingCore/Profile/RawCameraProfileSelection.swift Sources/RawProcessingCore/Model/PhotoAdjustments.swift Sources/PresetCore/Model/AdjustmentFieldID.swift Sources/PresetCore/Model/AdjustmentPatch.swift Sources/PresetCore/Model/PhotoAdjustmentsFieldAccess.swift Sources/PresetCore/XMP/XMPImportExport.swift Sources/PresetCore/XMP/AdobeProfileRegistry.swift Sources/PresetCore/Application/PresetApplicator.swift Tests/RawProcessingCoreTests/AdobeCompatibleProfileRegistryTests.swift Tests/PresetCoreTests/AdjustmentPatchTests.swift Tests/PresetCoreTests/XMPCompositeImportTests.swift Tests/PresetCoreTests/PresetApplicatorTests.swift
git commit -m "feat: preserve and resolve raw camera profiles"
```

**Stop condition:** 需要依賴 Adobe 專有 table、把 creative profile 當 Camera Profile、unknown profile 被宣稱已套用，或造成模組反向依賴時停止。

---

### Task 7: 建立可校正、可散布的 Camera Profile fallback renderer

**Files:**
- Create: `Sources/RawProcessingCore/Profile/CameraProfileFallback.swift`
- Create: `Sources/RawProcessingCore/Profile/CameraProfileRenderer.swift`
- Create: `Sources/RawProcessingCore/Profile/Generated/AdobeCompatibleProfileFallbacksV1.swift`
- Modify: `Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift`
- Modify: `Sources/RawProcessingCore/Decoding/RawRenderRecipeResolver.swift`
- Modify: `Package.swift`
- Create: `Sources/LumaHarborProfileCalibrate/main.swift`
- Create: `Tests/RawProcessingCoreTests/CameraProfileRendererTests.swift`
- Create: `Tests/RawProcessingCoreTests/CameraProfileCalibrationTests.swift`
- Create: `Tests/LumaHarborAppTests/ProfileCalibrationCommandContractTests.swift`

**Interfaces:**

```swift
public struct CameraProfileFallback: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let version: Int
    public let cameraMatch: CameraMatch
    public let sourceProfileName: String
    public let matrix3x3: [Float]
    public let redToneLUT: [Float]
    public let greenToneLUT: [Float]
    public let blueToneLUT: [Float]
    public let provenance: String
}

public protocol CameraProfileRendering: Sendable {
    func apply(_ fallback: CameraProfileFallback, to image: CIImage, recipe: ResolvedRawRenderRecipe) throws -> CIImage
}
```

- Profile stage 固定在 decode／As Shot WB 之後、Exposure／Basic tone 之前。
- v1 fallback 只允許 camera model + source profile 層級的 3×3 matrix 與單調 per-channel LUT；不得加入 per-photo branch。
- Calibration CLI 讀取由環境變數指定的私人 paired references，輸出只有係數、穩定 IDs、aggregate metrics 與去識別 provenance；不得輸出路徑、影像或 Adobe table。
- 係數擬合必須分 training 與 hold-out；hold-out raw ID 不得參與 fit。
- Generated Swift 檔只包含可散布數值與 provenance 摘要。
- Unknown camera／profile 不進 renderer，使用 system-neutral 並保留 diagnostic。

- [x] **Step 1: Write failing synthetic renderer and calibration tests**

測試 identity fallback 不改像素、matrix channel mapping、LUT 單調性／端點、invalid coefficient rejection、profile stage ordering，以及 synthetic paired samples 可重建已知 matrix。CLI contract test 斷言輸出不含 `/Users/`、`/Volumes/`、`file://` 或輸入 basename。

- [x] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter CameraProfileRendererTests
swift test --filter CameraProfileCalibrationTests
swift test --filter ProfileCalibrationCommandContractTests
```

Expected: renderer／calibration target 尚不存在而失敗。

- [x] **Step 3: Implement renderer and calibrator**

先完成純值 validation 與 identity renderer，再實作 matrix + LUT Core Image stage。CLI 使用固定 seed／deterministic solver，明確接收 training IDs 與 hold-out IDs，產生可重現係數。僅在 legal provenance 與 hold-out metrics 完整時，才把 reference camera 的 Adobe Color／Adobe Standard 係數寫入 generated registry。

- [x] **Step 4: Verify hold-out behavior**

Run:

```bash
swift test --filter CameraProfileRendererTests
swift test --filter CameraProfileCalibrationTests
swift test --filter ProfileCalibrationCommandContractTests
swift run LumaHarborProfileCalibrate --help
```

Expected: synthetic tests pass；help 不讀私人資料；同一 sanitized input 產生 byte-identical coefficients；hold-out regression 會使 command exit non-zero。

- [x] **Step 5: Commit**

```bash
git add Package.swift Sources/RawProcessingCore/Profile/CameraProfileFallback.swift Sources/RawProcessingCore/Profile/CameraProfileRenderer.swift Sources/RawProcessingCore/Profile/Generated/AdobeCompatibleProfileFallbacksV1.swift Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift Sources/RawProcessingCore/Decoding/RawRenderRecipeResolver.swift Sources/LumaHarborProfileCalibrate/main.swift Tests/RawProcessingCoreTests/CameraProfileRendererTests.swift Tests/RawProcessingCoreTests/CameraProfileCalibrationTests.swift Tests/LumaHarborAppTests/ProfileCalibrationCommandContractTests.swift
git commit -m "feat: add calibrated camera profile fallbacks"
```

**Stop condition:** hold-out 沒有改善、只有 training 照片改善、需要單張照片特例、係數來源不可散布，或 stage ordering 需要改動 C1 tone controls 時停止。

---

### Task 8: 在 Mac 與 iPad 資訊面板呈現同一份診斷

**Files:**
- Read: `Sources/EditorCore/EditorSession.swift` (the existing `latestRawRenderRecipe` source of truth)
- Create: `Sources/EditorCore/RawRenderDiagnosticsPresentation.swift`
- Create: `Sources/AdjustmentUI/RawRenderDiagnosticsPanel.swift`
- Modify: `Sources/LumaHarborApp/Views/InspectorView.swift`
- Modify: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadInspectorHost.swift`
- Modify: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorInfoViews.swift`
- Modify: `Sources/RawProcessingCore/Decoding/RawRenderRecipe.swift`
- Modify: `Sources/RawProcessingCore/Decoding/CoreImageRawDecoder.swift`
- Modify: `Sources/Localization/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/Localization/Resources/zh-Hant.lproj/Localizable.strings`
- Modify: the remaining six `Sources/Localization/Resources/*.lproj/Localizable.strings` files required by the parity gate
- Create: `Tests/LumaHarborAppTests/RawRenderDiagnosticsContractTests.swift`
- Modify: `Tests/LumaHarborAppTests/InspectorMetadataContractTests.swift`
- Modify: `Tests/LumaHarborAppTests/LocalizationKeyParityContractTests.swift`

**UI contract:**

- 不新增第二套 adjustment panel 或新的操作模式。
- Mac 與 iPad 現有「資訊」頁顯示相同欄位：顯色模式、As Shot WB 狀態、requested profile、resolved fallback、decoder fallback、metadata fallback。
- 使用者文案顯示 `LumaHarbor Native` 或 `Lightroom-compatible v1`；不得只顯示 Adobe 名稱而暗示 native support。
- Diagnostics 使用固定 identifier；UI 文案從 localization key 取得。
- Unknown profile 文案明確顯示「Profile 已保存，未套用」。
- VoiceOver／accessibility value 必須包含模式與 fallback 狀態，不依賴顏色傳意。

- [x] **Step 1: Write failing cross-platform UI contracts**

加入 source／view-model contract tests，驗證兩平台都從 `EditorSession` 的同一 recipe 取得值、所有 identifiers 有 localization key、unknown profile 顯示未套用、切換照片時 diagnostics 不殘留。

- [x] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter RawRenderDiagnosticsContractTests
swift test --filter InspectorMetadataContractTests
swift test --filter LocalizationKeyParityContractTests
swift test --filter EightLanguageLocalizationGateTests
```

Expected: diagnostics row／localization keys 尚不存在，或 Mac／iPad 來源不一致而失敗。

- [x] **Step 3: Implement shared presentation mapping**

在 `EditorSession` 或共用純值 presenter 把 recipe diagnostics 轉成固定 rows；Mac 與 iPad view 只渲染 rows。保持既有字型階層、觸控尺寸與 panel 行為，不在本 task 重設 Inspector 版面。

- [x] **Step 4: Verify localization and stale state**

Run the four commands from Step 2, then build both app targets as described in Task 10.

Expected: contract tests pass；兩平台用相同 identifiers；recipe nil 時不顯示前一張照片資訊。

- [x] **Step 5: Commit**

```bash
git add Sources/EditorCore/RawRenderDiagnosticsPresentation.swift Sources/AdjustmentUI/RawRenderDiagnosticsPanel.swift Sources/LumaHarborApp/Views/InspectorView.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadInspectorHost.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorInfoViews.swift Sources/RawProcessingCore/Decoding/RawRenderRecipe.swift Sources/RawProcessingCore/Decoding/CoreImageRawDecoder.swift Tests/LumaHarborAppTests/RawRenderDiagnosticsContractTests.swift Tests/LumaHarborAppTests/InspectorMetadataContractTests.swift Tests/LumaHarborAppTests/LocalizationKeyParityContractTests.swift
git add Sources/Localization/Resources
git commit -m "feat: show raw render diagnostics across platforms"
```

**Stop condition:** 需要建立不同的 Mac／iPad resolver、UI 顯示與實際 recipe 不一致，或新增 adjustment controls 才能呈現時停止。

---

### Task 9: 執行正式 Gate 2 reference 校正與鎖定 v1 artifacts

**Files:**
- Modify: `Scripts/validate-lr-reference-matrix.zsh`
- Modify: `Sources/LumaHarborReferenceCompare/main.swift`
- Modify: `docs/testing/lightroom-xmp-reference-matrix.md`
- Modify: `docs/testing/templates/lightroom-xmp-reference-matrix.json`
- Create: `docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md`
- Test: `Tests/LumaHarborAppTests/LightroomReferenceMatrixContractTests.swift`
- Test: `Tests/LumaHarborAppTests/ReferenceCompareCommandContractTests.swift`
- Test: `Tests/RawProcessingCoreTests/ReferenceComparisonMetricsTests.swift`

**Gate contract:**

- 四張 neutral RAW 各自使用原尺寸、16-bit TIFF、sRGB ICC、無 resize、無 output sharpening、無 watermark。
- 每張都同時符合 Mean `<= 0.04`、P95 `<= 0.12`、luminance direct SSIM `>= 0.95`、highlight／shadow clipping fraction 差異各 `<= 0.02`。
- Report 記錄 stable raw ID、Lightroom version、Process Version、Profile、Luma policy、requested／resolved decoder、option vector、As Shot WB status、profile fallback、working/output IDs 與 metrics。
- 報告不得記錄私人路徑、檔名、影像或 XMP 內容。
- Decoder fallback、unsupported metadata、reference hash 重複、尺寸／ICC／bit depth 不符均為 `FAIL` 或 `NOT RUN`。
- 調參只能修改 decoder option vector、profile fallback artifact 或 color-space artifact，且每次變更版本 ID；不得修改 C1 sliders。
- `LumaHarborReferenceCompare` 保留既有 single-case CLI，並新增 `--all-neutral` batch mode；batch mode 只比較四個 unique raw ID 的 neutral pair，輸出 sanitized JSON report。

- [ ] **Step 1: Extend contract tests before running private references**

先讓 matrix validator 與 comparator 驗證 direct neutral metrics、clipping fractions、ICC、bit depth、dimensions、four-RAW coverage、unique hashes 與 recipe metadata。加入缺失或錯誤 metadata 必須 non-zero exit 的 tests。

- [ ] **Step 2: Run public contract tests**

Run:

```bash
swift test --filter LightroomReferenceMatrixContractTests
swift test --filter ReferenceCompareCommandContractTests
swift test --filter ReferenceComparisonMetricsTests
Scripts/validate-lr-reference-matrix.zsh docs/testing/templates/lightroom-xmp-reference-matrix.json
```

Expected: public contracts pass；沒有私人 reference 時保持 `NOT RUN`，不偽造 Gate 2 結果。

- [ ] **Step 3: Generate LumaHarbor neutral outputs with the locked recipe**

使用既有私有 matrix image directory 與 RAW fixture environment，先驗證 matrix，再由 LumaHarbor full export 產生四張 neutral 16-bit TIFF。輸出 report 僅使用 stable IDs。若任一 output recipe 含 fallback diagnostic，停止並回到 Task 4 至 Task 7 對應 artifact。

- [ ] **Step 4: Run the 4/4 direct comparison**

Run:

```bash
Scripts/validate-lr-reference-matrix.zsh "$LUMAHARBOR_LR_REFERENCE_MATRIX" --images "$LUMAHARBOR_LR_REFERENCE_IMAGES"
swift run LumaHarborReferenceCompare --mode neutralDirect --all-neutral --matrix "$LUMAHARBOR_LR_REFERENCE_MATRIX" --images "$LUMAHARBOR_LR_REFERENCE_IMAGES" --report "$LUMAHARBOR_LR_REFERENCE_REPORT"
```

Expected: 每張 case 個別 PASS；aggregate 只作摘要，不得覆蓋單張 failure。

- [ ] **Step 5: Tune only versioned artifacts when a case fails**

一次只改一組 artifact，依序執行：decoder option vector 消融、working/output transform 驗證、camera/profile fallback calibration。每次重跑四張 case 與 hold-out，不接受只改善一張的變更。通過後固定 v1 IDs、係數與 report hash。

- [ ] **Step 6: Commit the sanitized gate evidence**

```bash
git add Scripts/validate-lr-reference-matrix.zsh Sources/LumaHarborReferenceCompare/main.swift docs/testing/lightroom-xmp-reference-matrix.md docs/testing/templates/lightroom-xmp-reference-matrix.json docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md Tests/LumaHarborAppTests/LightroomReferenceMatrixContractTests.swift Tests/LumaHarborAppTests/ReferenceCompareCommandContractTests.swift Tests/RawProcessingCoreTests/ReferenceComparisonMetricsTests.swift
git commit -m "test: lock Lightroom neutral raw gate"
```

**Stop condition:** 任一 RAW 未達全部 thresholds、reference metadata 不可信、fallback 未核准、或需要 tone／Presence／curve 補償時，Gate 2 維持 FAIL，不進 C1。

---

### Task 10: 完整回歸、跨平台驗收與交接

**Files:**
- Modify: `docs/coordination/CURRENT.md`
- Modify: `docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md`
- Modify only if findings require it: `docs/superpowers/specs/2026-09-19-lightroom-neutral-raw-baseline-v1.md`

**Acceptance matrix:**

| Area | Required evidence |
| --- | --- |
| Policy | new RAW Adobe v1, legacy native, non-RAW native |
| Persistence | reopen, migration replay, virtual copy, duplicate, copy/paste |
| XMP | preview no-write, commit one Undo, undo restores policy/profile |
| Rendering | preview/single/batch share recipe; native hash unchanged |
| Gate 2 | 4/4 full-size 16-bit neutral direct PASS |
| Cross-platform | Mac/iPad serialized recipe equal; TIFF Mean `<= 0.001`, P95 `<= 0.003` |
| Performance | high-quality preview P95 regression `<= 20%`; four full-size exports without OOM |
| Build | strict Swift tests, macOS build, iPad generic build, physical iPad smoke |
| Hygiene | diff check, privacy scan, no private fixture tracked |

- [ ] **Step 1: Run focused module suites**

```bash
swift test --filter RawProcessingCoreTests
swift test --filter PresetCoreTests
swift test --filter PhotoLibraryCoreTests
swift test --filter EditorCoreTests
swift test --filter LumaHarborAppTests
```

Expected: all focused suites pass; intentional private-fixture absences are `XCTSkip`, not PASS.

- [ ] **Step 2: Run strict and complete SwiftPM gates**

```bash
swift test -Xswiftc -strict-concurrency=complete
swift test
```

Expected: no new failure. If the known `CurationDurabilityTests` signal 11 remains, reproduce it separately, record command and crash evidence, and do not claim the full suite is green until it is fixed or proven unrelated with a tracked report.

- [ ] **Step 3: Build macOS and iPad targets**

```bash
Scripts/build-app-bundle.sh debug
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: both builds exit 0 with no new warnings from touched files.

- [ ] **Step 4: Run physical iPad smoke**

Install the current branch build on the connected iPad and verify portrait／landscape preview, Info diagnostics, Adobe XMP preview／commit／undo, panel dismiss, full export and reopen. Record device class and OS major version only; do not record device identifier or private filenames.

Expected: no stale diagnostics, no crash／OOM, and serialized recipe matches macOS for the same stable raw ID.

- [ ] **Step 5: Run cross-platform pixels and performance gates**

Render the same neutral case on Mac and iPad to 16-bit sRGB TIFF, then run the reference comparator in platform mode. Measure high-quality preview and four full-resolution exports using the existing benchmark harness.

Expected: Mac/iPad Mean `<= 0.001`, P95 `<= 0.003`, orientation／dimensions identical; preview P95 regression `<= 20%`; no OOM or silent downscale.

- [ ] **Step 6: Run repository hygiene and privacy checks**

```bash
git diff --check
git status --short
rg -n '/Users/|/Volumes/|file://|BEGIN XMP|Table_|LookTable|Digest' Sources Tests Scripts docs --glob '!docs/superpowers/plans/2026-09-19-lightroom-neutral-raw-baseline-v1.md'
git ls-files | rg '\.(ARW|CR2|CR3|NEF|RAF|ORF|RW2|DNG|tif|tiff)$'
```

Expected: diff check passes；privacy scan 只有已審核的規格文字或零結果；Git 未追蹤私人 RAW／TIFF。

- [ ] **Step 7: Complete the handoff report**

更新 report 與 `docs/coordination/CURRENT.md`，逐項標示 `PASS`、`FAIL` 或 `NOT RUN`，列出 commit、測試數量、Gate 2 每張 metrics、fallback diagnostics、已知 `CurationDurabilityTests` 狀態與下一個允許開始的 C1 spec。未執行項目不得推測為 PASS。

- [ ] **Step 8: Commit documentation only after evidence is final**

```bash
git add docs/coordination/CURRENT.md docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md docs/superpowers/specs/2026-09-19-lightroom-neutral-raw-baseline-v1.md
git commit -m "docs: record Lightroom neutral raw acceptance"
```

**Stop condition:** Gate 2、native regression、跨平台、真機、build 或隱私 gate 任一未通過時，保持本功能未完成且不得開始 C1 Process 2012 tone／Presence 校正。

---

## Spec Coverage Matrix

| 規格需求 | 實作 task |
| --- | --- |
| Policy version、legacy wire value、neutral edit state、Reset／Undo、rollback | Task 1 |
| Mac／iPad new-vs-legacy persistence、migration、sidecar precedence | Task 2 |
| Shared resolved recipe、cache key、provenance、feature flag／safe fallback | Task 3 |
| Fixed decoder version、CIRAW option vector、WB／orientation／lens | Task 4 |
| Wide-linear working space、16-bit sRGB output、ICC | Task 5 |
| XMP Camera Profile request、registry ownership、unknown fallback | Task 6 |
| Legal camera/profile fallback、hold-out calibration、stage ordering | Task 7 |
| Mac／iPad diagnostics and localization | Task 8 |
| Four-case full-size Gate 2 and artifact locking | Task 9 |
| Regression、cross-platform、performance、physical iPad、privacy | Task 10 |

## Completion Rule

本計劃只有在 Task 1 至 Task 10 全部完成，且 Gate 2 四張 reference 每張都通過時才算完成。任何 `NOT RUN`、未核准 fallback、native hash 變動或跨平台 recipe 分歧都會阻止 C1 開發；不得用平均 metrics、人工目視或文件敘述取代測試證據。
