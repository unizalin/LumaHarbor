# Preset 與開發預設 XMP Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付 LumaHarbor 原生 Preset、兩種儲存 scope、非破壞預覽，以及 Lightroom／Camera Raw 開發預設 XMP 的安全匯入與匯出。

**Architecture:** 新增只依賴 `RawProcessingCore` 的 `PresetCore` target，將 schema、partial patch、XMP codec 與 mapping 從 UI／檔案系統隔離。`PhotoLibraryCore` 實作 repositories，`LumaHarborApp` 只透過 typed service 套用、管理與預覽 Preset。

**Tech Stack:** Swift 6 strict concurrency、SwiftPM、Foundation XML／JSON、SwiftUI、XCTest、Core Image 現有 render pipeline。

## Global Constraints

- 基準設計：`docs/superpowers/specs/2026-08-21-preset-xmp-compatibility-design.md`。
- macOS 14 以上、Apple Silicon、完整 Xcode；不得降低 deployment target 或 strict-concurrency 設定。
- 保持 SwiftPM dependency-free；若 Foundation 無法安全滿足 XMP property graph，停下提出證據，不得自行加入第三方套件。
- 原始 RAW、相鄰 Adobe XMP 與私人 fixture 都不得修改或加入 Git。
- `docs/reference/` 必須原樣保留，不得 add、commit、stash、修改或刪除。
- 每個 task 使用 TDD、獨立 commit；不得 force push。
- XMP 無損指語意無損，不要求逐 byte 相同。

---

## File Map

### New target and core files

- `Package.swift`：宣告 `PresetCore` product／target 與 test target，更新既有 target dependency。
- `Sources/PresetCore/Model/PresetDocument.swift`：原生 schema、metadata、source、scope-neutral identity。
- `Sources/PresetCore/Model/AdjustmentPatch.swift`：所有 optional leaf patch 與 canonicalization。
- `Sources/PresetCore/Application/PresetApplicator.swift`：merge／replace、contextual white balance 與 compatibility filtering。
- `Sources/PresetCore/XMP/XMPPropertyGraph.swift`：namespace-aware RDF property graph。
- `Sources/PresetCore/XMP/XMPCodec.swift`：安全 parse／serialize、限制與 semantic comparison。
- `Sources/PresetCore/XMP/XMPMappingRegistry.swift`：process-version-aware 正反向 mapping。
- `Sources/PresetCore/XMP/XMPImportExport.swift`：開發預設分類、摘要、原生／XMP 轉換。
- `Sources/PresetCore/Errors/PresetError.swift`：typed error 與安全 diagnostics。

### Storage and app files

- `Sources/PhotoLibraryCore/Preset/PresetRepository.swift`：repository protocol、兩種 scope、actor isolation。
- `Sources/PhotoLibraryCore/Preset/FilePresetRepository.swift`：atomic file implementation 與 conflicts。
- `Sources/LumaHarborApp/ViewModels/PresetLibraryViewModel.swift`：載入、搜尋、import/export、create、scope copy。
- `Sources/LumaHarborApp/ViewModels/EditorViewModel.swift`：單筆 history 套用與 transient preview。
- `Sources/LumaHarborApp/Views/PresetBrowserView.swift`：browser／搜尋／群組／收藏。
- `Sources/LumaHarborApp/Views/CreatePresetSheet.swift`：leaf selection 與 scope。
- `Sources/LumaHarborApp/Views/ImportPresetSheet.swift`：相容性摘要與 approximate selection。
- `Sources/LumaHarborApp/Views/EditorView.swift` 與 inspector 容器：掛入 Preset browser。
- `Sources/Localization/Resources/*.lproj/Localizable.strings`：所有新增 user-facing copy。

### Tests and fixtures

- `Tests/PresetCoreTests/*Tests.swift`：schema、patch、codec、mapping、limits、round-trip。
- `Tests/PhotoLibraryCoreTests/PresetRepositoryTests.swift`：兩 scope、atomicity、conflicts、read-only。
- `Tests/LumaHarborAppTests/PresetWorkflowTests.swift`：preview/history/UI view-model 行為。
- `Tests/PresetCoreTests/Fixtures/XMP/`：去識別、可提交的 XMP corpus 與 manifest。

---

### Task 1: 建立 PresetCore 與 typed partial patch

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PresetCore/Model/PresetDocument.swift`
- Create: `Sources/PresetCore/Model/AdjustmentPatch.swift`
- Create: `Sources/PresetCore/Errors/PresetError.swift`
- Create: `Tests/PresetCoreTests/AdjustmentPatchTests.swift`
- Create: `Tests/PresetCoreTests/PresetDocumentTests.swift`

**Interfaces:**
- Consumes: `RawProcessingCore.PhotoAdjustments` 及所有 nested adjustment value types。
- Produces: `PresetDocument`, `PresetSource`, `AdjustmentPatch`, nested patch types, `AdjustmentFieldID`, `PresetError`。

- [ ] **Step 1: 先寫 absent 與 explicit-default 的失敗測試**

```swift
func testBasicPatchDistinguishesAbsentFromExplicitNeutral() throws {
    let absent = AdjustmentPatch()
    let explicit = AdjustmentPatch(basic: .init(exposure: 0))
    XCTAssertFalse(absent.contains(.exposure))
    XCTAssertTrue(explicit.contains(.exposure))
    XCTAssertNotEqual(absent, explicit)
}

func testEmptyNestedPatchCanonicalizesToNil() {
    XCTAssertNil(AdjustmentPatch(basic: BasicAdjustmentPatch()).basic)
}
```

- [ ] **Step 2: 執行測試並確認因 target／types 尚不存在而失敗**

Run: `swift test --filter AdjustmentPatchTests`

Expected: FAIL，錯誤包含 `no such module 'PresetCore'` 或缺少上述 type。

- [ ] **Step 3: 宣告 target 與完整 leaf model**

`AdjustmentFieldID` 使用穩定 raw value，例如 `basic.exposure`、`hsl.red.hue`、`sharpening.amount`。每個 nested patch leaf 為 `Double?`；tone curve 使用 `AdvancedToneCurve?`。initializer 與 decoder 都呼叫 `canonicalized()`，空 nested patch 變 `nil`。

```swift
public struct BasicAdjustmentPatch: Codable, Equatable, Sendable {
    public var exposure: Double?
    public var temperature: Double?
    public var tint: Double?
    public var contrast: Double?
    public var highlights: Double?
    public var shadows: Double?
    public var whites: Double?
    public var blacks: Double?
    public var vibrance: Double?
    public var saturation: Double?
    public var isEmpty: Bool { /* all leaves == nil */ }
}
```

不要只實作 basic；本 task 必須定義設計 spec §5.2 列出的所有 nested patch，並以 table-driven tests 覆蓋每個 `AdjustmentFieldID`。

- [ ] **Step 4: 實作 PresetDocument schema validation／Codable**

```swift
public enum PresetSource: Codable, Equatable, Sendable {
    case native
    case adobeXMP(tool: String?, version: String?)
}

public struct PresetDocument: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1
    // exact fields from design spec §5.1
    public func validated() throws -> PresetDocument
}
```

future schema 必須拋 `PresetError.unsupportedSchemaVersion(found:supported:)`；名稱及 group limits 按 spec 固定測試。

- [ ] **Step 5: 跑 core tests 與 strict build**

Run: `swift test --filter PresetCoreTests`

Expected: PASS。

Run: `swift build -Xswiftc -strict-concurrency=complete`

Expected: exit 0，沒有新增 warning。

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/PresetCore Tests/PresetCoreTests
git commit -m "feat: add versioned preset document and adjustment patch"
```

### Task 2: 實作 merge／replace 與照片上下文套用

**Files:**
- Create: `Sources/PresetCore/Application/PresetApplicator.swift`
- Create: `Tests/PresetCoreTests/PresetApplicatorTests.swift`
- Modify: `Sources/RawProcessingCore/Decoding/RawDecoding.swift`
- Modify: `Sources/RawProcessingCore/Preview/PreviewRequest.swift`
- Modify: `Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift`
- Create: `Tests/RawProcessingCoreTests/CoreImagePreviewRendererTests.swift`

**Interfaces:**
- Consumes: `AdjustmentPatch`, `PhotoAdjustments`, RAW decode baseline。
- Produces: `PresetApplicator.apply(_:to:mode:context:) -> PresetApplicationResult`。

- [ ] **Step 1: 寫 table-driven merge／replace 失敗測試**

```swift
func testMergeChangesOnlyPresentLeaves() throws {
    let current = PhotoAdjustments(exposure: 2, contrast: 30, saturation: 40)
    let patch = AdjustmentPatch(basic: .init(exposure: 0, saturation: -20))
    let result = try PresetApplicator().apply(patch, to: current, mode: .merge, context: .none)
    XCTAssertEqual(result.adjustments.exposure, 0)
    XCTAssertEqual(result.adjustments.contrast, 30)
    XCTAssertEqual(result.adjustments.saturation, -20)
}

func testReplaceStartsFromNeutral() throws {
    let current = PhotoAdjustments(exposure: 2, contrast: 30)
    let patch = AdjustmentPatch(basic: .init(exposure: 1))
    let result = try PresetApplicator().apply(patch, to: current, mode: .replace, context: .none)
    XCTAssertEqual(result.adjustments.exposure, 1)
    XCTAssertEqual(result.adjustments.contrast, 0)
}
```

- [ ] **Step 2: 確認測試因 applicator 不存在而失敗**

Run: `swift test --filter PresetApplicatorTests`

Expected: FAIL with missing `PresetApplicator`。

- [ ] **Step 3: 實作一次性、純函式套用**

```swift
public struct PresetApplicationContext: Equatable, Sendable {
    public var baselineTemperatureKelvin: Double?
    public var baselineTint: Double?
    public static let none = Self()
}

public struct PresetApplicationResult: Equatable, Sendable {
    public var adjustments: PhotoAdjustments
    public var diagnostics: [PresetDiagnostic]
}

public struct PresetApplicator: Sendable {
    public func apply(
        _ patch: AdjustmentPatch,
        to current: PhotoAdjustments,
        mode: PresetApplicationMode,
        context: PresetApplicationContext
    ) throws -> PresetApplicationResult
}
```

套用所有 nested leaves；不得逐 leaf 呼叫 editor history。context 缺少時，contextual field 保持原值並回 diagnostic，不得用 0 假裝 baseline。

在 `RawProcessingCore` 定義不依賴 Preset 的 decoder context，並由 preview renderer 隨結果帶回：

```swift
public struct RawWhiteBalanceBaseline: Equatable, Sendable {
    public var temperatureKelvin: Double
    public var tint: Double
}

public struct PreviewImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let pixelSize: CGSize
    public let whiteBalanceBaseline: RawWhiteBalanceBaseline?
}
```

`CoreImagePreviewRenderer` 從既有 `DecodedRawImage.baselineTemperature`／`baselineTint` 填入；測試 fake 及既有 initializer 以預設 `nil` 保持 source compatibility。`EditorViewModel` 在 Task 6 收到目前照片的 preview 後保存 baseline，再建立 `PresetApplicationContext`。禁止讓 `RawProcessingCore` 依賴 `PresetCore`。

- [ ] **Step 4: 加入白平衡 baseline 與 clamp 診斷測試**

XMP absolute Kelvin 先由 mapping 轉為 contextual instruction；套用到 baseline 5,000 K、target 6,000 K 時，結果必須是 LumaHarbor `temperature = (6000 - 5000) / 45`。超出 LumaHarbor range 時結果可 clamp，但 diagnostic 必須含原始及轉換值。

- [ ] **Step 5: 跑測試與 commit**

Run: `swift test --filter PresetApplicatorTests`

Expected: PASS。

```bash
git add Sources/PresetCore Sources/RawProcessingCore Tests/PresetCoreTests
git commit -m "feat: apply preset patches with merge and replace semantics"
```

### Task 3: 建立安全、namespace-aware XMP codec

**Files:**
- Create: `Sources/PresetCore/XMP/XMPPropertyGraph.swift`
- Create: `Sources/PresetCore/XMP/XMPCodec.swift`
- Create: `Tests/PresetCoreTests/XMPCodecTests.swift`
- Create: `Tests/PresetCoreTests/XMPSecurityTests.swift`
- Create: `Tests/PresetCoreTests/Fixtures/XMP/manifest.json`
- Create: `Tests/PresetCoreTests/Fixtures/XMP/subset-basic.xmp`
- Create: `Tests/PresetCoreTests/Fixtures/XMP/unknown-nested-rdf.xmp`
- Create: `Tests/PresetCoreTests/Fixtures/XMP/corrupt.xmp`

**Interfaces:**
- Consumes: bounded UTF-8 `Data`。
- Produces: `XMPDocument`, `XMPEnvelope`, `XMPCodec.parse(_:)`, `serialize(_:)`, `semanticallyEquivalent(_:_:)`。

- [ ] **Step 1: 寫 namespace／unknown structure round-trip 失敗測試**

```swift
func testUnknownNamespaceStructureSurvivesSemanticRoundTrip() throws {
    let input = try fixture("unknown-nested-rdf.xmp")
    let document = try XMPCodec().parse(input)
    let output = try XMPCodec().serialize(document)
    let reparsed = try XMPCodec().parse(output)
    XCTAssertTrue(XMPCodec().semanticallyEquivalent(document, reparsed))
    XCTAssertNotNil(reparsed.property(namespaceURI: "urn:test:future", localName: "MaskTree"))
}
```

- [ ] **Step 2: 寫 hostile XML 失敗測試**

```swift
func testRejectsDoctypeBeforeEntityResolution() {
    let xml = Data("<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><x>&e;</x>".utf8)
    XCTAssertThrowsError(try XMPCodec().parse(xml)) {
        XCTAssertEqual($0 as? PresetError, .unsafeXMLConstruct("DOCTYPE"))
    }
}
```

另以 synthetic builders 精確測 10 MiB、depth 64、20,000 properties、1 MiB value 的邊界及超界。

- [ ] **Step 3: 確認測試先失敗**

Run: `swift test --filter XMPCodecTests`

Expected: FAIL with missing codec types。

- [ ] **Step 4: 實作 property graph 與受限 parser**

```swift
public struct XMPPropertyID: Hashable, Codable, Sendable {
    public var namespaceURI: String
    public var localName: String
}

public indirect enum XMPValue: Equatable, Sendable {
    case text(String)
    case array(kind: XMPArrayKind, values: [XMPValue])
    case structure([XMPPropertyID: XMPValue])
    case qualified(value: XMPValue, qualifiers: [XMPPropertyID: XMPValue])
}
```

在 parse 前拒絕 `DOCTYPE`／`ENTITY` token；parser 不設定任何 external resolver。所有 counter 在 append 前檢查上限。錯誤訊息不得包含完整輸入或絕對路徑。

- [ ] **Step 5: 實作 canonical serializer 與 semantic comparator**

Serializer 可重新排序 namespace declaration／attributes，但 ordered array 不得改序；comparator 以 URI＋local name 比較，不以 prefix 或 whitespace 比較。

- [ ] **Step 6: 跑 codec/security tests、fuzz smoke 與 commit**

Run: `swift test --filter 'XMPCodecTests|XMPSecurityTests'`

Expected: PASS，hostile fixture 不觸碰本機檔案。

```bash
git add Sources/PresetCore/XMP Tests/PresetCoreTests
git commit -m "feat: add bounded semantic XMP codec"
```

### Task 4: 實作 version-aware mapping 與 import/export

**Files:**
- Create: `Sources/PresetCore/XMP/XMPMappingRegistry.swift`
- Create: `Sources/PresetCore/XMP/XMPImportExport.swift`
- Create: `Tests/PresetCoreTests/XMPMappingTests.swift`
- Create: `Tests/PresetCoreTests/XMPImportExportTests.swift`
- Add: `Tests/PresetCoreTests/Fixtures/XMP/basic-hsl-curve.xmp`
- Add: `Tests/PresetCoreTests/Fixtures/XMP/unsupported-process-version.xmp`

**Interfaces:**
- Consumes: `XMPDocument`, `PresetDocument`, `PresetApplicationContext`。
- Produces: `XMPMappingRegistry.default`, `XMPImporter.preview(data:)`, `XMPExporter.export(_:baseEnvelope:)`。

- [ ] **Step 1: 寫每個初始 mapping 的 table-driven 失敗測試**

```swift
func testExposureMapsBothDirections() throws {
    let property = XMPProperty(id: .cameraRaw("Exposure2012"), value: .text("1.25"))
    let mapped = try XMPMappingRegistry.default.importProperty(property, processVersion: "11.0")
    XCTAssertEqual(mapped.field, .exposure)
    XCTAssertEqual(mapped.level, .native)
    XCTAssertEqual(mapped.value, 1.25)
    XCTAssertEqual(try XMPMappingRegistry.default.export(mapped), property)
}
```

測試清單必須直接列出 registry 第一版每個 property；不要用「其餘類似」省略。Sharpening detail／masking、獨立 noise reduction、unknown namespace 必須 assert `.preserved` 且不進 patch。

- [ ] **Step 2: 確認 mapping tests 失敗**

Run: `swift test --filter XMPMappingTests`

Expected: FAIL with missing registry。

- [ ] **Step 3: 實作 declarative registry**

```swift
public struct XMPMapping: Sendable {
    public var propertyID: XMPPropertyID
    public var processVersions: Set<String>
    public var field: AdjustmentFieldID?
    public var level: XMPCompatibilityLevel
    public var importValue: @Sendable (XMPValue) throws -> ImportedAdjustmentValue
    public var exportValue: (@Sendable (ImportedAdjustmentValue) throws -> XMPValue)?
}
```

Registry initialization 檢查相同 key 不得重複。所有 Adobe property 以 namespace URI 辨識，不能依賴 `crs` prefix。

- [ ] **Step 4: 實作 preview import summary**

```swift
public struct XMPImportPreview: Equatable, Sendable {
    public var proposedPreset: PresetDocument
    public var nativeFields: [AdjustmentFieldID]
    public var approximateFields: [AdjustmentFieldID]
    public var preservedProperties: [XMPPropertyID]
    public var diagnostics: [XMPDiagnostic]
}
```

Importer 不寫檔；unknown process version 仍回 preview，但 mapped patch 為空且含 warning。沒有可套用欄位但有 preserved data 時允許保存為 dormant preset，UI 必須標示「尚無可套用調整」。

- [ ] **Step 5: 實作 reverse export 與 semantic round-trip tests**

匯出以 envelope property graph 為基底；只更新使用者在 LumaHarbor 修改的 mapped field。測試 assert unknown nested RDF 仍 semantic-equivalent，及單向 mapping 產生 warning。

- [ ] **Step 6: 跑 tests、更新 fixture manifest、commit**

Run: `swift test --filter 'XMPMappingTests|XMPImportExportTests'`

Expected: PASS。

```bash
git add Sources/PresetCore/XMP Tests/PresetCoreTests
git commit -m "feat: map Camera Raw develop presets to LumaHarbor"
```

### Task 5: 實作兩種 Preset repository 與衝突處理

**Files:**
- Create: `Sources/PhotoLibraryCore/Preset/PresetRepository.swift`
- Create: `Sources/PhotoLibraryCore/Preset/FilePresetRepository.swift`
- Create: `Tests/PhotoLibraryCoreTests/PresetRepositoryTests.swift`
- Modify: `Sources/LumaHarborApp/AppServices.swift`

**Interfaces:**
- Consumes: validated `PresetDocument`。
- Produces: `PresetRepository` actor API、`PresetScope`, `PresetConflictResolution`, `PresetStoreResult`。

- [ ] **Step 1: 寫 global／library／read-only／conflict 失敗測試**

```swift
func testSameUUIDAndSameCanonicalContentIsSkipped() async throws {
    let repository = FilePresetRepository(rootURL: temporaryDirectory)
    let first = try await repository.save(preset, conflict: .cancel)
    let second = try await repository.save(preset, conflict: .cancel)
    XCTAssertEqual(first, .created)
    XCTAssertEqual(second, .duplicateSkipped)
}
```

另測同 UUID 不同內容的 `.replace`／`.keepBoth`／`.cancel`，同名不同 UUID 共存、UUID filename、atomic failure 不破壞舊檔、唯讀仍可 list/load。

- [ ] **Step 2: 確認 repository tests 失敗**

Run: `swift test --filter PresetRepositoryTests`

Expected: FAIL with missing repository。

- [ ] **Step 3: 實作 actor repository**

```swift
public protocol PresetRepository: Sendable {
    func list() async throws -> [PresetDocument]
    func load(id: UUID) async throws -> PresetDocument?
    func save(_ document: PresetDocument, conflict: PresetConflictResolution) async throws -> PresetStoreResult
    func delete(id: UUID) async throws
}
```

實作必須沿用 `AtomicFileWriter` 的 durable/replace 規則；若需泛化 writer，先加 regression test，不能複製一份行為不一致的 atomic writer。

- [ ] **Step 4: 實作 scope copy/move transaction**

先 copy、讀回 canonical compare、再 delete source。delete 失敗回 `.copiedSourceRetained` warning；絕不因刪除失敗回滾已驗證的安全副本。

- [ ] **Step 5: 跑 tests 與 commit**

Run: `swift test --filter PresetRepositoryTests`

Expected: PASS。

```bash
git add Sources/PhotoLibraryCore Sources/LumaHarborApp Tests/PhotoLibraryCoreTests Package.swift
git commit -m "feat: store global and library presets atomically"
```

### Task 6: 將 Preset 接入 Editor history 與 transient preview

**Files:**
- Modify: `Sources/LumaHarborApp/ViewModels/EditorViewModel.swift`
- Modify: `Sources/PhotoLibraryCore/Model/EditHistory.swift`（只使用既有 `record(_:)`，預期不需改碼；若測試證明 API 不足才修改）
- Create: `Tests/LumaHarborAppTests/PresetWorkflowTests.swift`

**Interfaces:**
- Consumes: `PresetApplicator`, `PresetDocument`, selected compatibility fields。
- Produces: `previewPreset`, `cancelPresetPreview`, `commitPreset`；一次 commit 對應一筆 history mutation。

- [ ] **Step 1: 寫 preview 不污染狀態與單筆 Undo 失敗測試**

```swift
@MainActor
func testPresetPreviewDoesNotDirtySaveOrHistory() async throws {
    let sut = makeOpenedEditor(adjustments: .neutral)
    let before = snapshot(sut)
    sut.previewPreset(preset, mode: .merge)
    XCTAssertNotEqual(sut.displayedAdjustments, before.adjustments)
    sut.cancelPresetPreview()
    XCTAssertEqual(snapshot(sut), before)
}

@MainActor
func testCommittingMultiFieldPresetCreatesOneUndoEntry() async throws {
    let sut = makeOpenedEditor(adjustments: .neutral)
    sut.commitPreset(preset, mode: .merge)
    sut.undo()
    XCTAssertEqual(sut.adjustments, .neutral)
    XCTAssertFalse(sut.canUndo)
}
```

- [ ] **Step 2: 確認 tests 失敗**

Run: `swift test --filter PresetWorkflowTests`

Expected: FAIL with missing editor methods。

- [ ] **Step 3: 實作 transient state 與 generation cancellation**

Editor 保留 committed history 與 optional preview adjustments 分離；render request 讀 preview-or-current，autosave 永遠只讀 history.current。快速 preview 使用既有 scheduler generation，取消後重送 committed render。收到目前照片的 `PreviewImage.whiteBalanceBaseline` 後保存；照片切換或 close 立即清空，禁止沿用上一張照片的 baseline。

- [ ] **Step 4: 實作單次 history replace**

直接使用既有 `EditHistory.record(_:)` 寫入完整套用結果；禁止依 Preset leaf 數量連續呼叫 `record`。相同結果不新增 history、不 autosave。

- [ ] **Step 5: 跑 editor tests 與 commit**

Run: `swift test --filter PresetWorkflowTests`

Expected: PASS。

Run: `swift test --filter EditorViewModel`

Expected: 既有 editor tests PASS。

```bash
git add Sources/LumaHarborApp Tests/LumaHarborAppTests
git commit -m "feat: preview and apply presets as one editor action"
```

### Task 7: 建立 Preset 管理、建立、匯入與匯出 UI

**Files:**
- Create: `Sources/LumaHarborApp/ViewModels/PresetLibraryViewModel.swift`
- Create: `Sources/LumaHarborApp/Views/PresetBrowserView.swift`
- Create: `Sources/LumaHarborApp/Views/CreatePresetSheet.swift`
- Create: `Sources/LumaHarborApp/Views/ImportPresetSheet.swift`
- Modify: `Sources/LumaHarborApp/Views/InspectorView.swift`
- Modify: `Sources/Localization/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/Localization/Resources/zh-Hant.lproj/Localizable.strings`
- Modify: `Tests/LumaHarborAppTests/PresetWorkflowTests.swift`

**Interfaces:**
- Consumes: repositories、XMP import preview/exporter、editor preset methods。
- Produces: accessible Preset browser and sheets。

- [ ] **Step 1: 寫 view-model search／selection／confirmation tests**

測試必須固定：search 同時匹配 name/group、scope filter、favorite、approximate 預設勾選、preserved 不可勾選、取消 import 零寫入、create 預設選 modified leaves。

```swift
@MainActor
func testCancelledImportWritesNothing() async throws {
    let repository = RecordingPresetRepository()
    let sut = PresetLibraryViewModel(repository: repository, importer: importer)
    await sut.previewImport([fixtureURL])
    sut.cancelImport()
    XCTAssertEqual(repository.savedDocuments, [])
}
```

- [ ] **Step 2: 確認 tests 失敗**

Run: `swift test --filter PresetWorkflowTests`

Expected: FAIL with missing view model。

- [ ] **Step 3: 實作 view model 狀態機**

明確狀態：idle、loading、importPreview、saving、partialResult、failed。每個 async completion 用 operation ID 丟棄過期結果；所有 published state 在 `@MainActor`。

- [ ] **Step 4: 實作 SwiftUI browser 與 sheets**

Preset row 的 hover／focus 呼叫 preview，離開呼叫 cancel；主要 action 才 commit。所有 icon-only button 有可翻譯 label/help。刪除與 replace 有確認；系統 file importer/exporter 限定 `.xmp`／`.lhpreset`。

- [ ] **Step 5: 完成雙語文案與 accessibility assertions**

不得在 SwiftUI 新增裸 user-facing literal；全部走 `L10n.t`。測試載入兩語言資源，確認新增 key 不缺漏。

- [ ] **Step 6: 跑 app tests、build、commit**

Run: `swift test --filter LumaHarborAppTests`

Expected: PASS。

Run: `swift build -Xswiftc -strict-concurrency=complete`

Expected: PASS，no new warnings。

```bash
git add Sources/LumaHarborApp Sources/Localization Tests/LumaHarborAppTests
git commit -m "feat: add preset browser and XMP import export workflow"
```

### Task 8: Phase 1 fixture 驗證、完整回歸與報告

**Files:**
- Modify: `Tests/PresetCoreTests/Fixtures/XMP/manifest.json`
- Create: `docs/testing/reports/2026-08-21-preset-xmp-phase1.md`
- Modify: `docs/superpowers/specs/2026-08-21-preset-xmp-compatibility-design.md`（只更新狀態／證據，不改已確認需求）

**Interfaces:**
- Consumes: Phase 1 完整功能。
- Produces: 可追蹤驗收證據與 Gate A/B/D 結論。

- [ ] **Step 1: 建立去識別 XMP fixture manifest**

每個 fixture 記錄安全檔名、SHA-256、document kind、Adobe 產生工具／版本、預期 native／approximate／preserved 數量及是否可提交。不得記錄私人來源路徑。

- [ ] **Step 2: 在可用的 Lightroom Classic／Camera Raw 做 smoke test**

驗證 Adobe 可匯入 LumaHarbor 輸出的開發預設，並把 Adobe 再輸出的 XMP 交回 semantic comparator。若該 app 不可用，Gate B 標示未完成並回報，不得用單元測試代替真實 smoke test。

- [ ] **Step 3: 執行完整自動測試**

Run: `git diff --check`

Expected: no output。

Run: `swift build -Xswiftc -strict-concurrency=complete`

Expected: PASS，no warnings。

Run: `swift test -Xswiftc -strict-concurrency=complete`

Expected: PASS，0 failures；記錄 total／passed／skipped 的正確口徑。

Run: `LUMAHARBOR_RAW_FIXTURE_DIR="<PRIVATE_RAW_FIXTURE_DIR>" swift test --filter RawFixtureTests`

Expected: 9 tests，0 failures；路徑不得寫進 committed report。

- [ ] **Step 4: 跑 MVP runner**

```bash
export LUMAHARBOR_RAW_FIXTURE_DIR="<PRIVATE_RAW_FIXTURE_DIR>"
export LUMAHARBOR_APFS_TEST_DIR="<PRIVATE_APFS_TEST_DIR>"
export LUMAHARBOR_EXFAT_TEST_DIR="<PRIVATE_EXFAT_TEST_DIR>"
Scripts/run-mvp-acceptance.zsh --preflight-only
Scripts/run-mvp-acceptance.zsh
```

Expected: preflight PASS；strict build PASS；完整 tests 0 failures；RawFixtureTests 0 failures；Overall result PASS。若 exFAT 未掛載，停止並回報，不能略過。

- [ ] **Step 5: 寫驗收報告並掃描私人路徑**

Run: `rg -n '/Users/|/Volumes/' docs/testing/reports/2026-08-21-preset-xmp-phase1.md Tests/PresetCoreTests/Fixtures/XMP`

Expected: no private absolute path matches。

- [ ] **Step 6: Final commit**

```bash
git add docs/testing/reports/2026-08-21-preset-xmp-phase1.md docs/superpowers/specs/2026-08-21-preset-xmp-compatibility-design.md Tests/PresetCoreTests/Fixtures/XMP
git commit -m "docs: record preset and XMP phase 1 acceptance"
```

完成 Phase 1 後先交給 Codex review；Critical／Important 問題清空後才開始 Phase 2。
