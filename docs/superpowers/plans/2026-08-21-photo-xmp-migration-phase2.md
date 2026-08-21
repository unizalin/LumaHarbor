# Photo XMP Migration Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 偵測 RAW 旁 Adobe XMP sidecar，先產生可審查搬家摘要，再把使用者確認的設定安全搬入 LumaHarbor 正式 sidecar，且不改寫原 XMP。

**Architecture:** 沿用 Phase 1 `PresetCore` codec／mapping／applicator；`PhotoLibraryCore` 新增 discovery、migration planner 與逐檔 atomic executor。UI 只驅動 preview-confirm-execute 狀態機，`.lumaharbor/edits/*.json` 維持唯一主來源。

**Tech Stack:** Swift 6 strict concurrency、SwiftPM、Foundation、SwiftUI、XCTest、Phase 1 PresetCore。

## Global Constraints

- 必須先完成並通過 `docs/superpowers/plans/2026-08-21-preset-xmp-phase1.md`。
- 需求來源：`docs/superpowers/specs/2026-08-21-preset-xmp-compatibility-design.md` §10–§13。
- 不解析 `.lrcat`、不處理 DNG 內嵌 XMP、不持續雙向同步。
- 不修改、移動、刪除或重新格式化原 Adobe XMP。
- 取消必須零寫入；既有 LumaHarbor edit 衝突的批次預設是略過。
- `docs/reference/` 必須原樣保留，不得 add、commit、stash、修改或刪除。
- 每個 task 使用 TDD、獨立 commit；不得 force push。

---

## File Map

- `Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift`：保存 XMP envelope／migration provenance 的向前相容 schema。
- `Sources/PhotoLibraryCore/XMP/AdjacentXMPDiscovery.swift`：同 basename discovery 與 fingerprint。
- `Sources/PhotoLibraryCore/XMP/XMPMigrationPlanner.swift`：parse、相容性與 conflict preview。
- `Sources/PhotoLibraryCore/XMP/XMPMigrationExecutor.swift`：使用者決策後逐檔 atomic write 與 partial result。
- `Sources/LumaHarborApp/ViewModels/XMPMigrationViewModel.swift`：狀態機與取消。
- `Sources/LumaHarborApp/Views/XMPMigrationSheet.swift`：摘要、衝突決策、結果。
- `Tests/PhotoLibraryCoreTests/XMP*Tests.swift`：discovery／planner／executor。
- `Tests/LumaHarborAppTests/XMPMigrationViewModelTests.swift`：confirmation 與 UI state。

### Task 1: 擴充 PhotoSidecar 保存 XMP provenance

**Files:**
- Modify: `Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift`
- Modify: `Tests/PhotoLibraryCoreTests/SidecarRepositoryTests.swift`

**Interfaces:**
- Consumes: `PresetCore.XMPEnvelope`。
- Produces: `ImportedXMPProvenance?`，舊 schema 可讀、新 schema 可安全 round-trip。

- [ ] **Step 1: 寫舊 schema decode 與新欄位 round-trip 失敗測試**

```swift
func testVersionTwoSidecarDecodesWithoutXMPProvenance() throws {
    let sidecar = try decoder.decode(PhotoSidecar.self, from: versionTwoFixture)
    XCTAssertNil(sidecar.importedXMP)
}

func testImportedXMPEnvelopeRoundTrips() throws {
    let sidecar = makeSidecar(importedXMP: provenance)
    XCTAssertEqual(try roundTrip(sidecar).importedXMP, provenance)
}
```

- [ ] **Step 2: 確認 tests 先失敗**

Run: `swift test --filter SidecarRepositoryTests`

Expected: FAIL with missing `importedXMP`。

- [ ] **Step 3: bump schema 並實作向前／向後規則**

```swift
public struct ImportedXMPProvenance: Codable, Equatable, Sendable {
    public var envelope: XMPEnvelope
    public var sourceFingerprint: FileFingerprint
    public var importedAt: Date
}
```

缺欄位預設 `nil`；比目前 schema 更高仍拒絕。更新 `Package.swift` 讓 `PhotoLibraryCore` 依賴 `PresetCore`，不得造成循環。

- [ ] **Step 4: 跑 tests 與 commit**

Run: `swift test --filter SidecarRepositoryTests`

Expected: PASS。

```bash
git add Package.swift Sources/PhotoLibraryCore/Sidecar Tests/PhotoLibraryCoreTests
git commit -m "feat: preserve imported XMP provenance in photo sidecars"
```

### Task 2: 實作相鄰 XMP discovery 與冪等 fingerprint

**Files:**
- Create: `Sources/PhotoLibraryCore/XMP/AdjacentXMPDiscovery.swift`
- Create: `Tests/PhotoLibraryCoreTests/AdjacentXMPDiscoveryTests.swift`

**Interfaces:**
- Consumes: scanned `PhotoAsset` relative paths、library root、既有 provenance fingerprint。
- Produces: `[AdjacentXMPCandidate]`。

- [ ] **Step 1: 寫 basename／case／DNG／unchanged 失敗測試**

```swift
func testFindsCaseInsensitiveSidecarWithSameBasename() async throws {
    try fixture.write("IMG_0001.ARW")
    try fixture.write("img_0001.XMP", contents: validXMP)
    let result = try await discovery.findCandidates(for: [photo], at: fixture.root)
    XCTAssertEqual(result.map(\.relativeXMPPath), ["img_0001.XMP"])
}
```

另測不同 basename 不匹配、DNG 不宣稱掃描內嵌資料、已匯入且 fingerprint 相同不提示、內容變更重新提示、私人絕對路徑不進 diagnostic。

- [ ] **Step 2: 確認 tests 失敗**

Run: `swift test --filter AdjacentXMPDiscoveryTests`

Expected: FAIL with missing discovery。

- [ ] **Step 3: 實作 bounded discovery**

```swift
public struct AdjacentXMPCandidate: Equatable, Sendable {
    public var photoID: PhotoID
    public var relativeXMPPath: String
    public var fingerprint: FileFingerprint
}
```

只接受 library-root 內正規化 relative path；symlink 逃出 root 必須拒絕。不得在 main actor hash／讀檔。

- [ ] **Step 4: 跑 tests 與 commit**

Run: `swift test --filter AdjacentXMPDiscoveryTests`

Expected: PASS。

```bash
git add Sources/PhotoLibraryCore/XMP Tests/PhotoLibraryCoreTests
git commit -m "feat: discover adjacent photo XMP sidecars safely"
```

### Task 3: 建立零寫入 migration planner

**Files:**
- Create: `Sources/PhotoLibraryCore/XMP/XMPMigrationPlanner.swift`
- Create: `Tests/PhotoLibraryCoreTests/XMPMigrationPlannerTests.swift`

**Interfaces:**
- Consumes: candidates、Phase 1 importer、現有 `PhotoSidecar?`。
- Produces: `XMPMigrationPlan` 與 per-photo `XMPMigrationProposal`；planner 不得寫檔。

- [ ] **Step 1: 寫分類與 conflict 預設失敗測試**

```swift
func testExistingLumaHarborEditDefaultsToSkip() async throws {
    let plan = try await planner.plan([candidateWithExistingEdit])
    XCTAssertEqual(plan.proposals[0].conflict, .existingLumaHarborEdits)
    XCTAssertEqual(plan.proposals[0].decision, .skip)
    XCTAssertEqual(sidecarRepository.writeCount, 0)
}
```

另測 native-only、approximate、preserved-only、malformed/rejected、missing file 與 summary totals。

- [ ] **Step 2: 確認 tests 失敗**

Run: `swift test --filter XMPMigrationPlannerTests`

Expected: FAIL with missing planner。

- [ ] **Step 3: 實作 planner 與 immutable decisions**

```swift
public enum XMPMigrationDecision: String, Codable, Sendable {
    case skip
    case merge
    case replace
}

public struct XMPMigrationPlan: Equatable, Sendable {
    public var proposals: [XMPMigrationProposal]
    public var summary: XMPMigrationSummary
}
```

proposal 保存 plan-time XMP fingerprint；execute 前必須重新驗證，避免確認後檔案被外部改掉。

- [ ] **Step 4: 跑 tests 與 commit**

Run: `swift test --filter XMPMigrationPlannerTests`

Expected: PASS，repository write count 始終 0。

```bash
git add Sources/PhotoLibraryCore/XMP Tests/PhotoLibraryCoreTests
git commit -m "feat: preview photo XMP migration without writes"
```

### Task 4: 實作逐照片 atomic migration executor

**Files:**
- Create: `Sources/PhotoLibraryCore/XMP/XMPMigrationExecutor.swift`
- Create: `Tests/PhotoLibraryCoreTests/XMPMigrationExecutorTests.swift`

**Interfaces:**
- Consumes: user-confirmed `XMPMigrationPlan`。
- Produces: `XMPMigrationBatchResult` with succeeded／skipped／failed per photo。

- [ ] **Step 1: 寫取消、merge、replace、partial failure 失敗測試**

```swift
func testCancelledPlanWritesNothing() async throws {
    let result = await executor.execute(plan, confirmation: .cancelled)
    XCTAssertEqual(result.succeeded.count, 0)
    XCTAssertEqual(repository.writeCount, 0)
    XCTAssertEqual(try Data(contentsOf: originalXMPURL), originalXMPData)
}
```

另測一張 write failure 不阻止其餘、fingerprint changed 拒絕該張、重跑 unchanged 冪等、existing sidecar createdAt 保留、modifiedAt 更新。

- [ ] **Step 2: 確認 tests 失敗**

Run: `swift test --filter XMPMigrationExecutorTests`

Expected: FAIL with missing executor。

- [ ] **Step 3: 實作 executor**

每張重新 load current sidecar 與 XMP fingerprint；用 `PresetApplicator` 產生結果，透過既有 `SidecarStoring.write` atomic 寫入。錯誤收進 per-photo result，禁止在 batch 中吞掉。

- [ ] **Step 4: 驗證原 XMP bytes／mtime 不變**

測試在 execute 前後比較 SHA-256、size 與 modification date；三者都必須相同。

- [ ] **Step 5: 跑 tests 與 commit**

Run: `swift test --filter XMPMigrationExecutorTests`

Expected: PASS。

```bash
git add Sources/PhotoLibraryCore/XMP Tests/PhotoLibraryCoreTests
git commit -m "feat: migrate confirmed XMP edits into LumaHarbor sidecars"
```

### Task 5: 加入搬家摘要與確認 UI

**Files:**
- Create: `Sources/LumaHarborApp/ViewModels/XMPMigrationViewModel.swift`
- Create: `Sources/LumaHarborApp/Views/XMPMigrationSheet.swift`
- Modify: `Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift`
- Modify: `Sources/Localization/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/Localization/Resources/zh-Hant.lproj/Localizable.strings`
- Create: `Tests/LumaHarborAppTests/XMPMigrationViewModelTests.swift`

**Interfaces:**
- Consumes: discovery、planner、executor。
- Produces: auto-detect prompt、manual file/folder import、per-photo decision UI、batch result。

- [ ] **Step 1: 寫狀態機與確認 tests**

```swift
@MainActor
func testDetectionShowsSummaryBeforeAnyWrite() async throws {
    await sut.detectAfterScan()
    guard case .awaitingConfirmation(let plan) = sut.state else {
        return XCTFail("expected confirmation")
    }
    XCTAssertEqual(plan.summary.total, 3)
    XCTAssertEqual(executor.callCount, 0)
}
```

另測 dismiss 不在同 session 重複吵使用者、XMP fingerprint 改變後可再次提示、manual import 可重開、partial result 清楚呈現。

- [ ] **Step 2: 確認 tests 失敗**

Run: `swift test --filter XMPMigrationViewModelTests`

Expected: FAIL with missing view model。

- [ ] **Step 3: 實作 view model 與 scan hook**

scan 完成只觸發 discovery／plan；不觸發 execute。用 operation ID 處理 library 切換與 task cancellation，過期 plan 不得套到新 library。

- [ ] **Step 4: 實作 summary／conflict／result UI**

摘要顯示 native／approximate／preserved／rejected／existing edit counts。existing edits 預設 skip；批次變更 decision 要有明確 label。執行前最後一個 action 文案必須表明「寫入 LumaHarbor，原 XMP 不變」。

- [ ] **Step 5: 跑 tests、strict build、commit**

Run: `swift test --filter XMPMigrationViewModelTests`

Expected: PASS。

Run: `swift build -Xswiftc -strict-concurrency=complete`

Expected: PASS，no warnings。

```bash
git add Sources/LumaHarborApp Sources/Localization Tests/LumaHarborAppTests
git commit -m "feat: add confirmed photo XMP migration workflow"
```

### Task 6: Phase 2 完整驗收與報告

**Files:**
- Create: `docs/testing/reports/2026-08-21-photo-xmp-migration-phase2.md`
- Modify: `docs/superpowers/specs/2026-08-21-preset-xmp-compatibility-design.md`（只補狀態／證據）

**Interfaces:**
- Consumes: 完整 Phase 2。
- Produces: Gate C/D 證據。

- [ ] **Step 1: 在去識別 fixture library 做 migration matrix**

至少包含：無既有 edit、既有 edit、preserved-only、malformed、XMP 在確認後變更、唯讀 library、單檔寫入失敗。每案記錄預期 decision／result，並驗證原 XMP SHA-256／mtime 未變。

- [ ] **Step 2: 執行完整 build/test**

Run: `git diff --check`

Expected: no output。

Run: `swift build -Xswiftc -strict-concurrency=complete`

Expected: PASS，no warnings。

Run: `swift test -Xswiftc -strict-concurrency=complete`

Expected: PASS，0 failures。

Run: `LUMAHARBOR_RAW_FIXTURE_DIR="<PRIVATE_RAW_FIXTURE_DIR>" swift test --filter RawFixtureTests`

Expected: 9 tests，0 failures。

- [ ] **Step 3: 執行 MVP acceptance runner**

```bash
export LUMAHARBOR_RAW_FIXTURE_DIR="<PRIVATE_RAW_FIXTURE_DIR>"
export LUMAHARBOR_APFS_TEST_DIR="<PRIVATE_APFS_TEST_DIR>"
export LUMAHARBOR_EXFAT_TEST_DIR="<PRIVATE_EXFAT_TEST_DIR>"
Scripts/run-mvp-acceptance.zsh --preflight-only
Scripts/run-mvp-acceptance.zsh
```

Expected: Overall result PASS。若 exFAT 未掛載，停止並回報，不能略過。

- [ ] **Step 4: 寫報告並掃描隱私**

Run: `rg -n '/Users/|/Volumes/' docs/testing/reports/2026-08-21-photo-xmp-migration-phase2.md`

Expected: no matches。

- [ ] **Step 5: Final commit**

```bash
git add docs/testing/reports/2026-08-21-photo-xmp-migration-phase2.md docs/superpowers/specs/2026-08-21-preset-xmp-compatibility-design.md
git commit -m "docs: record photo XMP migration acceptance"
```

完成後交給 Codex review；在 review 與完整驗收通過前不得 push／宣稱完成。
