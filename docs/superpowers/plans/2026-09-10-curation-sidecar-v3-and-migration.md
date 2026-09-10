# Curation Sidecar v3 and Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:test-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the P0/P1 quality-gate gaps in `docs/superpowers/specs/2026-09-10-professional-editing-completion-design.md` §6.1: make the portable sidecar (not SQLite) the durable authority for rating/flag/keywords, define an exact migration state machine from legacy SQLite-only curation to `PhotoSidecar` schema v3, and prove full recovery after an index rebuild — while adding baseline protection tests that pin today's behavior before anything changes.

**Architecture:** Extend the existing `PhotoLibraryCore` sidecar/index split. `FileSidecarRepository` stays the only atomic-write boundary; `PhotoIndexStore` stays a rebuildable SQLite projection. A new pure decision function resolves the sidecar-vs-SQLite conflict without any I/O, so the whole migration state machine is unit-testable; the existing scan loop and a new `PhotoLibraryService` mutation API are the only two call sites that perform the actual write. No new actor, no new persistence engine, no UI redesign.

**Tech Stack:** Swift 5.9 / Swift 6 strict concurrency, SQLite3 (existing `SQLiteDatabase` wrapper), Foundation `Codable`/`JSONEncoder`, XCTest, existing `TemporaryDirectoryTestCase` fixture harness.

## Global constraints (carried from `AGENTS.md` and the approved spec)

- RAW files are never touched. Every test that touches a "photo" uses a synthetic fixture file, never a private RAW.
- `PhotoSidecar` is a cross-platform (future iPad) wire format; field names already committed (`schemaVersion`, `photoID`, `sourceRelativePath`, `sourceFingerprint`, `decoder`, `adjustments`, `createdAt`, `modifiedAt`, `variantOf`) are load-bearing and must not be renamed.
- v1 and v2 sidecars, and existing schema v4 SQLite databases, must decode/migrate unchanged.
- SQLite remains a rebuildable projection. No code path may treat it as authoritative for curation after this plan lands.
- Sidecar writes are atomic (`AtomicFileWriter`, already in place); a failed sidecar write must never be reported as saved, and must never partially update SQLite.
- `PASS`, `FAIL`, `SKIPPED`, `NOT RUN` stay distinct in all reporting; a real-device gate this plan cannot exercise is recorded `NOT RUN`, never inferred.
- Out of scope for this plan: `EditSnapshot` (spec §6.6, phase P6), per-channel tone curves (P3), shared Inspector catalog (P2), lens/color/mask features (P4/P5). Do not touch `RawProcessingCore/Model/AdvancedToneCurve.swift`, `Sources/AdjustmentUI/CurveAdjustmentPanel.swift`, or `Sources/AdjustmentUI/HistogramPanel.swift` — those are the just-merged P0 baseline and must be byte-for-byte preserved by `git diff` at the end of this plan.
- Do not modify Xcode signing settings, credentials, or any private absolute path. Do not push, merge, rebase, or package a release.

## Resolved quality-gate gaps (must read before coding)

These are the exact answers this plan supplies where the approved spec was intentionally high-level (per its own quality-gate note: "各 implementation plan 必須在寫程式前補齊該階段的演算法、fixture、狀態機與 evidence 格式").

### G1. Exact migration state machine

State is derived fresh on every scan/open — there is no separate "pending" boolean that could itself go stale. Given `existingSidecar: PhotoSidecar?` and `existingSQLiteCuration: PhotoCuration?` (the current SQLite row's rating/flag/keywords, `nil` when the photo has no prior row):

| # | `existingSidecar` | `existingSidecar.schemaVersion` | `existingSQLiteCuration` | Decision |
|---|---|---|---|---|
| 1 | present | `>= 3` | any | `.sidecarAuthoritative(sidecar.curation)` — SQLite is ignored outright (spec rule 1). |
| 2 | present | `< 3` | `nil` or `.neutral` | `.unchanged(.neutral)` — nothing to migrate; sidecar is left at its old version until the user's next real edit upgrades it. |
| 3 | present | `< 3` | non-neutral | `.migrate(sidecar: <same sidecar, schemaVersion bumped to 3, curation set>, curation: existingSQLiteCuration)` (spec rule 2). |
| 4 | `nil` | n/a | `nil` or `.neutral` | `.unchanged(.neutral)` — no sidecar needed yet, matches today's "no edits yet" behavior. |
| 5 | `nil` | n/a | non-neutral | `.migrate(sidecar: <brand-new v3 sidecar, adjustments = .neutral, curation = existingSQLiteCuration>, curation: existingSQLiteCuration)` (spec rule 3: never requires the photo to have been edited first). |

The caller (scan hydration and, separately, an explicit repair path) then does exactly one of:

- `.sidecarAuthoritative` / `.unchanged` → apply `curation` to the in-memory `PhotoAsset`; no write; `curationMigrationPending = false`.
- `.migrate(sidecar, curation)` → attempt `repository.write(sidecar:)`.
  - Success → apply `curation` to the asset; `curationMigrationPending = false`. SQLite projection for this row is naturally consistent because the upsert that follows carries the same `curation`.
  - Failure (offline, read-only, disk full, mid-write cancellation) → **do not raise**, keep the asset's curation at `existingSQLiteCuration ?? .neutral` (old values are never lost) and set `curationMigrationPending = true`. The next scan of the same source re-runs this exact table from scratch — that is the entire "resume" mechanism (spec acceptance #5). No retry queue, no timer, no separate resumption code path to keep in sync.

Rebuild (`resetRebuildableLocalData()` followed by a rescan) is not a special case: it is the same scan loop with an empty SQLite, so `existingSQLiteCuration` is `nil` for every photo and rows 1/4 above dominate — a v3 sidecar's `curation` is what repopulates SQLite, satisfying spec rule 6 without a dedicated "rebuild" function.

### G2. Data conflict rule when both sides are non-neutral and disagree

Row 1 above is unconditional: once a sidecar is schema v3, its `curation` always wins, even if SQLite disagrees (e.g. a stale row from before a crash). This matches spec rule 1 ("v3 sidecar 永遠優先於 SQLite") and is what makes the system self-healing: any SQLite drift is corrected on the very next scan, never merged or reconciled field-by-field.

### G3. Fixtures

New fixture-producing helpers (no fixture files committed as binary blobs; JSON is generated in-test so it stays reviewable as Swift):

- `makeLegacySidecarJSON(schemaVersion: Int, includeVariantOf: Bool) -> Data` in a new `Tests/PhotoLibraryCoreTests/TestSupport.swift` extension — hand-built JSON string (not round-tripped through the current encoder) for schema v1 (no `variantOf`, no `curation`) and schema v2 (`variantOf` present, no `curation`), so the test proves the *file format*, not just "whatever this build happens to produce."
- `PhotoCuration.stub(rating:flag:keywords:)` test helper.
- A reusable in-memory `PhotoIndexStore` fixture builder that seeds one library and N photos with specific SQLite-only rating/flag/keyword values and zero sidecars, for migration integration tests.

### G4. APIs introduced

```swift
// Sources/PhotoLibraryCore/Model/PhotoCuration.swift
public struct PhotoCuration: Codable, Equatable, Sendable {
    public var rating: Int
    public var flag: PhotoFlag
    public var keywords: [PhotoKeyword]   // deduplicated by normalized, sorted by normalized
    public static let neutral: PhotoCuration
    public var isNeutral: Bool
    public init(rating: Int = 0, flag: PhotoFlag = .none, keywords: [PhotoKeyword] = [])
}

// Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift
public static let currentSchemaVersion = 3
public var curation: PhotoCuration   // custom Decodable: missing key -> .neutral
public func updating(curation: PhotoCuration, modifiedAt: Date = Date()) -> PhotoSidecar

// Sources/PhotoLibraryCore/Service/CurationMigration.swift (new file, pure/no I/O)
enum CurationMigrationDecision: Equatable {
    case sidecarAuthoritative(PhotoCuration)
    case unchanged(PhotoCuration)
    case migrate(sidecar: PhotoSidecar, curation: PhotoCuration)
}
enum CurationMigration {
    static func decide(
        existingSidecar: PhotoSidecar?,
        existingSQLiteCuration: PhotoCuration?,
        photoID: PhotoID,
        sourceRelativePath: String,
        sourceFingerprint: FileFingerprint,
        decoder: DecoderDescriptor,
        now: Date
    ) -> CurationMigrationDecision
}

// Sources/PhotoLibraryCore/Index/PhotoIndexStore.swift
public static let schemaVersion = 5   // was 4
public func curationSnapshot(inLibrary: LibraryID) throws -> [PhotoID: PhotoCuration]  // one bulk SELECT
public func setCurationMigrationPending(_ pending: Bool, for: PhotoID) throws

// Sources/PhotoLibraryCore/Model/PhotoAsset.swift
public var curationMigrationPending: Bool   // default false

// Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift
public func curation(for photo: PhotoAsset) throws -> PhotoCuration
public func setRating(_ rating: Int, for photo: PhotoAsset) throws
public func setFlag(_ flag: PhotoFlag, for photo: PhotoAsset) throws
public func setKeywords(_ inputs: [String], for photo: PhotoAsset) throws
```

### G5. Tests (minimum; exact files listed per task below)

Model unit ≥ 12, migration-decision unit ≥ 10, repository/projection integration ≥ 10, compatibility ≥ 6, UI-wiring contract ≥ 3. Total new tests ≥ 41, comfortably inside the spec's Model-unit-plus-Repository-integration budget for this slice of P1.

### G6. Evidence format

Every verification step in this plan's own Task 8 records: exact command, exit code, `executed`/`skipped`/`failures` counts when it is an XCTest run, and `PASS`/`FAIL`/`SKIPPED`/`NOT RUN`. Real-device gates are out of scope for a sidecar/SQLite change and are recorded `NOT RUN` with the reason "no product surface requiring device hardware changed."

### G7. Rollback

1. Every task below is one commit. Reverting any single commit from the tip backward is safe because `PhotoSidecar.currentSchemaVersion` only ever increases and no task rewrites an already-committed migration rule.
2. `PhotoSidecar` schema v3 decode is additive (new field defaults via custom `Decodable`), so reverting the Swift code while sidecars on disk have already been upgraded to v3 still lets an *older* build read them as far back as v2 semantics allowed (`curation` is simply unknown JSON to an older decoder, which Foundation's `Decodable` already ignores) — no destructive downgrade path is needed.
3. `PhotoIndexStore.schemaVersion` bump to 5 only adds a column; there is no data loss in reverting to a build that only expects v4, because `resetRebuildableLocalData()` (or a fresh install) always re-creates the database from the code that's actually running.
4. No task deletes or renames an existing public API; `LibraryViewModel`'s call-site change (Task 6) is the only call-site edit, and it is its own commit so it can be reverted independently of the model/store changes.

### G8. Per-file sequence

`PhotoCuration.swift` → `PhotoSidecar.swift` → `CurationMigration.swift` → `PhotoIndexStore.swift` (schema v5 + `curationSnapshot` + pending column) → `PhotoAsset.swift` (`curationMigrationPending`) → `PhotoLibraryService.swift` (scan hydration + mutation API) → `LibraryViewModel.swift` (call-site swap) → compatibility test sweep → full verification. This order means every task after the first two compiles against a stable curation model, and the scan-loop change (the highest-risk edit) lands only after the pure decision function already has full unit coverage.

---

## File Structure

| File | Change |
|---|---|
| `Sources/PhotoLibraryCore/Model/PhotoCuration.swift` | New. |
| `Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift` | Schema v3, `curation` field, custom `Codable`. |
| `Sources/PhotoLibraryCore/Service/CurationMigration.swift` | New pure decision function. |
| `Sources/PhotoLibraryCore/Index/PhotoIndexStore.swift` | Schema v5 migration, `curationSnapshot`, pending column, pending setter. |
| `Sources/PhotoLibraryCore/Model/PhotoAsset.swift` | `curationMigrationPending` field. |
| `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift` | Scan-loop + virtual-copy curation hydration; `curation(for:)`, `setRating/setFlag/setKeywords(for photo:)`. |
| `Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift` | Call `libraryService.setRating/setFlag/setKeywords` instead of `indexStore.set*` directly. |
| `Tests/PhotoLibraryCoreTests/TestSupport.swift` | Legacy sidecar JSON builders, `PhotoCuration.stub`. |
| `Tests/PhotoLibraryCoreTests/PhotoCurationTests.swift` | New. |
| `Tests/PhotoLibraryCoreTests/SidecarSchemaCompatibilityTests.swift` | New (P0 + P1). |
| `Tests/PhotoLibraryCoreTests/CurationMigrationDecisionTests.swift` | New. |
| `Tests/PhotoLibraryCoreTests/PhotoIndexMigrationTests.swift` | Extend for schema v5. |
| `Tests/PhotoLibraryCoreTests/CurationDurabilityTests.swift` | New (P0 baseline, then flipped GREEN in P1). |
| `Tests/PhotoLibraryCoreTests/VirtualCopyServiceTests.swift` | Extend: copy still starts neutral curation. |
| `Tests/LumaHarborAppTests/EditorWorkflowUXContractTests.swift` | Extend: source-contract proving `LibraryViewModel` no longer calls `indexStore.set*` directly. |
| `docs/coordination/DECISIONS.md` | Append D-006 (schema v3 ships without `snapshots`; that field is deferred to P6). |
| `docs/coordination/CURRENT.md` | Updated at handoff. |

---

## Task 0 (P0): Baseline protection tests

**Files:**
- Create: `Tests/PhotoLibraryCoreTests/SidecarSchemaCompatibilityTests.swift`
- Create: `Tests/PhotoLibraryCoreTests/CurationDurabilityTests.swift`
- Modify: `Tests/PhotoLibraryCoreTests/TestSupport.swift`

**Interfaces:** Consumes only what already exists (`PhotoSidecar` v2, `PhotoIndexStore` v4, `PhotoLibraryService`). Produces no new production API.

- [ ] **Step 1: Add legacy sidecar JSON builders**

In `TestSupport.swift`, add:

```swift
enum LegacySidecarFixture {
    /// Hand-built schema v1 JSON: no `variantOf`, no `curation`. This is the
    /// literal shape a pre-Phase-3 build wrote to disk.
    static func schemaV1JSON(photoID: PhotoID) -> Data {
        """
        {
          "schemaVersion": 1,
          "photoID": "\(photoID.rawValue.uuidString)",
          "sourceRelativePath": "Trip/DSC0001.ARW",
          "sourceFingerprint": {"fileSize": 25000000, "edgeDigest": "abc"},
          "decoder": {"kind": "coreImage", "version": "system-default"},
          "adjustments": {"exposure": 1.5},
          "createdAt": "2024-01-01T00:00:00Z",
          "modifiedAt": "2024-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
    }

    /// Hand-built schema v2 JSON: adds `variantOf`, still no `curation`.
    static func schemaV2JSON(photoID: PhotoID, variantOf: PhotoID) -> Data {
        """
        {
          "schemaVersion": 2,
          "photoID": "\(photoID.rawValue.uuidString)",
          "sourceRelativePath": "Trip/DSC0002.ARW",
          "sourceFingerprint": {"fileSize": 25000000, "edgeDigest": "def"},
          "decoder": {"kind": "coreImage", "version": "system-default"},
          "adjustments": {"exposure": -0.5},
          "createdAt": "2024-01-01T00:00:00Z",
          "modifiedAt": "2024-01-01T00:00:00Z",
          "variantOf": "\(variantOf.rawValue.uuidString)"
        }
        """.data(using: .utf8)!
    }
}
```

- [ ] **Step 2: Write the compatibility tests (RED is not expected here — these pin *current* behavior)**

```swift
final class SidecarSchemaCompatibilityTests: XCTestCase {
    func testSchemaV1JSONDecodesWithoutVariantOf() throws {
        let id = PhotoID()
        let sidecar = try SidecarCoding.decode(PhotoSidecar.self, from: LegacySidecarFixture.schemaV1JSON(photoID: id))
        XCTAssertEqual(sidecar.schemaVersion, 1)
        XCTAssertNil(sidecar.variantOf)
        XCTAssertEqual(sidecar.adjustments.exposure, 1.5)
    }

    func testSchemaV2JSONDecodesWithVariantOf() throws {
        let id = PhotoID()
        let original = PhotoID()
        let sidecar = try SidecarCoding.decode(PhotoSidecar.self, from: LegacySidecarFixture.schemaV2JSON(photoID: id, variantOf: original))
        XCTAssertEqual(sidecar.schemaVersion, 2)
        XCTAssertEqual(sidecar.variantOf, original)
    }
}
```

Run `swift test --filter SidecarSchemaCompatibilityTests` — expect PASS today (this documents the pre-existing contract, it is not a new capability).

- [ ] **Step 3: Write the curation-durability baseline test (documents today's known gap)**

```swift
final class CurationDurabilityTests: TemporaryDirectoryTestCase {
    func testTodayIndexRebuildLosesRatingFlagAndKeywords() async throws {
        // Arrange: a library with one photo rated 5 stars via the SQLite-only
        // API that LibraryViewModel currently calls directly.
        let (service, libraryID, photoID) = try await makeLibraryWithOnePhoto()
        let indexStore = await service.indexStore
        try indexStore.setRating(5, for: photoID)
        try indexStore.setFlag(.pick, for: photoID)
        try indexStore.setKeywords(["Sunset"], for: photoID)

        // Act: simulate deleting the local index and rebuilding.
        try await service.resetRebuildableLocalData()
        try await drainScan(service, libraryID: libraryID)

        // Assert: today, curation does NOT survive -- this is the exact gap
        // Task 4/5/6 of this plan close. This assertion is intentionally
        // updated (not silently left in place) when this plan's migration
        // and sidecar-first mutation land; see Task 4 Step 5.
        let photo = try await service.indexStore.photo(id: photoID)
        XCTAssertEqual(photo?.rating, 0)
        XCTAssertEqual(photo?.flag, .none)
        XCTAssertEqual(photo?.keywords, [])
    }
}
```

Run `swift test --filter CurationDurabilityTests` — expect PASS (confirming the gap exists exactly as the spec's "已驗證現況" table states). This is the safety net: Task 4 will edit this exact test to assert the *fixed* behavior, and the diff will be reviewable as an intentional behavior change, not a silent rewrite.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter 'SidecarSchemaCompatibilityTests|CurationDurabilityTests'
git add Tests/PhotoLibraryCoreTests/SidecarSchemaCompatibilityTests.swift Tests/PhotoLibraryCoreTests/CurationDurabilityTests.swift Tests/PhotoLibraryCoreTests/TestSupport.swift
git commit -m "test: pin sidecar compatibility and curation-durability baseline"
```

---

## Task 1 (P1): `PhotoCuration` model

**Files:**
- Create: `Sources/PhotoLibraryCore/Model/PhotoCuration.swift`
- Create: `Tests/PhotoLibraryCoreTests/PhotoCurationTests.swift`

- [ ] **Step 1: Write failing model tests**

Cover: `.neutral` is rating 0/flag none/no keywords; `isNeutral`; rating clamps to `0...5` in `init`; keyword list dedupes by `normalized` keeping the first `displayValue` and first-seen order is *not* preserved — output is sorted by `normalized` for a stable, diffable sidecar; `Equatable`/`Codable` round trip; `Codable` JSON uses plain field names (`rating`, `flag`, `keywords`) matching `PhotoAsset`'s existing naming so a future reader recognizes the shape.

```swift
func testInitClampsRatingToZeroThroughFive() {
    XCTAssertEqual(PhotoCuration(rating: 9).rating, 5)
    XCTAssertEqual(PhotoCuration(rating: -3).rating, 0)
}

func testKeywordsDeduplicateByNormalizedAndSortStably() {
    let curation = PhotoCuration(keywords: [
        PhotoKeyword(normalized: "sunset", displayValue: "Sunset"),
        PhotoKeyword(normalized: "sunset", displayValue: "SUNSET"),
        PhotoKeyword(normalized: "beach", displayValue: "Beach")
    ])
    XCTAssertEqual(curation.keywords, [
        PhotoKeyword(normalized: "beach", displayValue: "Beach"),
        PhotoKeyword(normalized: "sunset", displayValue: "Sunset")
    ])
}

func testNeutralIsRatingZeroFlagNoneNoKeywords() {
    XCTAssertEqual(PhotoCuration.neutral, PhotoCuration(rating: 0, flag: .none, keywords: []))
    XCTAssertTrue(PhotoCuration.neutral.isNeutral)
}
```

- [ ] **Step 2: Run and confirm RED**

```bash
swift test --filter PhotoCurationTests
```

Expected: compile failure, `PhotoCuration` does not exist.

- [ ] **Step 3: Implement**

```swift
public struct PhotoCuration: Codable, Equatable, Sendable {
    public var rating: Int
    public var flag: PhotoFlag
    public var keywords: [PhotoKeyword]

    public init(rating: Int = 0, flag: PhotoFlag = .none, keywords: [PhotoKeyword] = []) {
        self.rating = min(max(rating, 0), 5)
        self.flag = flag
        var seen = Set<String>()
        self.keywords = keywords
            .filter { seen.insert($0.normalized).inserted }
            .sorted { $0.normalized < $1.normalized }
    }

    public static let neutral = PhotoCuration()
    public var isNeutral: Bool { self == .neutral }
}
```

- [ ] **Step 4: Run and commit**

```bash
swift test --filter PhotoCurationTests
swift build -Xswiftc -strict-concurrency=complete
git add Sources/PhotoLibraryCore/Model/PhotoCuration.swift Tests/PhotoLibraryCoreTests/PhotoCurationTests.swift
git commit -m "feat: add portable PhotoCuration model"
```

---

## Task 2 (P1): `PhotoSidecar` schema v3

**Files:**
- Modify: `Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift`
- Modify: `Tests/PhotoLibraryCoreTests/SidecarRepositoryTests.swift`
- Modify: `Tests/PhotoLibraryCoreTests/SidecarSchemaCompatibilityTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// SidecarRepositoryTests.swift
func testSidecarRoundTripsCuration() throws {
    let sidecar = makeSidecar().updating(curation: PhotoCuration(rating: 4, flag: .pick, keywords: [PhotoKeyword(normalized: "dog", displayValue: "Dog")]))
    try repository.write(sidecar: sidecar)
    let loaded = try XCTUnwrap(try repository.loadSidecar(for: sidecar.photoID))
    XCTAssertEqual(loaded.curation.rating, 4)
    XCTAssertEqual(loaded.curation.flag, .pick)
}

func testSidecarJSONMatchesTheDocumentedShape() throws {
    // extend existing key list with "curation"
}

// SidecarSchemaCompatibilityTests.swift
func testSchemaV1JSONDecodesCurationAsNeutral() throws {
    let sidecar = try SidecarCoding.decode(PhotoSidecar.self, from: LegacySidecarFixture.schemaV1JSON(photoID: PhotoID()))
    XCTAssertEqual(sidecar.curation, .neutral)
}

func testSchemaV2JSONDecodesCurationAsNeutral() throws {
    let sidecar = try SidecarCoding.decode(PhotoSidecar.self, from: LegacySidecarFixture.schemaV2JSON(photoID: PhotoID(), variantOf: PhotoID()))
    XCTAssertEqual(sidecar.curation, .neutral)
}

func testSidecarFromNewerSchemaIsStillRejected() throws {
    // schemaVersion 99 must still throw SidecarError.unsupportedSchemaVersion via the repository -- unchanged contract.
}
```

- [ ] **Step 2: Run and confirm RED**

```bash
swift test --filter 'SidecarRepositoryTests|SidecarSchemaCompatibilityTests'
```

- [ ] **Step 3: Implement schema v3**

```swift
public static let currentSchemaVersion = 3

public var curation: PhotoCuration

public init(
    schemaVersion: Int = PhotoSidecar.currentSchemaVersion,
    photoID: PhotoID,
    sourceRelativePath: String,
    sourceFingerprint: FileFingerprint,
    decoder: DecoderDescriptor = .coreImageDefault,
    adjustments: PhotoAdjustments = .neutral,
    curation: PhotoCuration = .neutral,
    createdAt: Date = Date(),
    modifiedAt: Date = Date(),
    variantOf: PhotoID? = nil
) {
    self.schemaVersion = schemaVersion
    self.photoID = photoID
    self.sourceRelativePath = sourceRelativePath
    self.sourceFingerprint = sourceFingerprint
    self.decoder = decoder
    self.adjustments = adjustments
    self.curation = curation
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
    self.variantOf = variantOf
}

private enum CodingKeys: String, CodingKey {
    case schemaVersion, photoID, sourceRelativePath, sourceFingerprint
    case decoder, adjustments, curation, createdAt, modifiedAt, variantOf
}

public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    photoID = try container.decode(PhotoID.self, forKey: .photoID)
    sourceRelativePath = try container.decode(String.self, forKey: .sourceRelativePath)
    sourceFingerprint = try container.decode(FileFingerprint.self, forKey: .sourceFingerprint)
    self.decoder = try container.decodeIfPresent(DecoderDescriptor.self, forKey: .decoder) ?? .coreImageDefault
    adjustments = try container.decodeIfPresent(PhotoAdjustments.self, forKey: .adjustments) ?? .neutral
    curation = try container.decodeIfPresent(PhotoCuration.self, forKey: .curation) ?? .neutral
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
    variantOf = try container.decodeIfPresent(PhotoID.self, forKey: .variantOf)
}

public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(photoID, forKey: .photoID)
    try container.encode(sourceRelativePath, forKey: .sourceRelativePath)
    try container.encode(sourceFingerprint, forKey: .sourceFingerprint)
    try container.encode(decoder, forKey: .decoder)
    try container.encode(adjustments, forKey: .adjustments)
    try container.encode(curation, forKey: .curation)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(modifiedAt, forKey: .modifiedAt)
    try container.encodeIfPresent(variantOf, forKey: .variantOf)
}

public func updating(curation: PhotoCuration, modifiedAt: Date = Date()) -> PhotoSidecar {
    var copy = self
    copy.curation = curation
    copy.modifiedAt = modifiedAt
    return copy
}
```

Keep the existing `updating(adjustments:modifiedAt:)` unchanged.

- [ ] **Step 4: Run full sidecar suite and commit**

```bash
swift test --filter 'SidecarRepositoryTests|SidecarSchemaCompatibilityTests|PhotoDocumentStoreTests'
swift build -Xswiftc -strict-concurrency=complete
git add Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift Tests/PhotoLibraryCoreTests/SidecarRepositoryTests.swift Tests/PhotoLibraryCoreTests/SidecarSchemaCompatibilityTests.swift
git commit -m "feat: add curation to PhotoSidecar schema v3"
```

---

## Task 3 (P1): Pure migration decision function

**Files:**
- Create: `Sources/PhotoLibraryCore/Service/CurationMigration.swift`
- Create: `Tests/PhotoLibraryCoreTests/CurationMigrationDecisionTests.swift`

- [ ] **Step 1: Write failing tests covering the full G1 table**

One test per row of the state-machine table above, plus: a sidecar at schema 3 with `.neutral` curation still wins over a non-neutral SQLite row (proves rule 1 is unconditional, not just "when SQLite is empty"); the migrated sidecar produced for row 3 preserves the original `adjustments`, `createdAt`, `decoder`, and `variantOf` untouched; the migrated sidecar produced for row 5 uses `adjustments: .neutral` and the given `photoID`/`sourceRelativePath`/`sourceFingerprint`.

```swift
func testSchemaV3SidecarWinsEvenWhenSQLiteDisagrees() {
    let sidecar = makeSidecar(curation: PhotoCuration(rating: 2))
    let decision = CurationMigration.decide(
        existingSidecar: sidecar,
        existingSQLiteCuration: PhotoCuration(rating: 5, flag: .pick),
        photoID: sidecar.photoID, sourceRelativePath: sidecar.sourceRelativePath,
        sourceFingerprint: sidecar.sourceFingerprint, decoder: sidecar.decoder, now: fixedNow
    )
    XCTAssertEqual(decision, .sidecarAuthoritative(PhotoCuration(rating: 2)))
}

func testLegacySidecarWithNonNeutralSQLiteMigratesPreservingAdjustments() {
    let legacy = makeSidecar(schemaVersion: 2, adjustments: PhotoAdjustments(exposure: 1.0))
    let decision = CurationMigration.decide(
        existingSidecar: legacy,
        existingSQLiteCuration: PhotoCuration(rating: 3, flag: .reject),
        photoID: legacy.photoID, sourceRelativePath: legacy.sourceRelativePath,
        sourceFingerprint: legacy.sourceFingerprint, decoder: legacy.decoder, now: fixedNow
    )
    guard case .migrate(let migrated, let curation) = decision else { return XCTFail() }
    XCTAssertEqual(migrated.schemaVersion, PhotoSidecar.currentSchemaVersion)
    XCTAssertEqual(migrated.adjustments, legacy.adjustments)
    XCTAssertEqual(migrated.createdAt, legacy.createdAt)
    XCTAssertEqual(curation, PhotoCuration(rating: 3, flag: .reject))
}

func testLegacySidecarWithNeutralSQLiteIsUnchanged() { /* row 2 */ }
func testNoSidecarNoSQLiteIsUnchangedNeutral() { /* row 4 */ }
func testNoSidecarNonNeutralSQLiteCreatesNewSidecarWithNeutralAdjustments() {
    let decision = CurationMigration.decide(
        existingSidecar: nil,
        existingSQLiteCuration: PhotoCuration(rating: 5),
        photoID: PhotoID(), sourceRelativePath: "Trip/DSC0009.ARW",
        sourceFingerprint: .stub("xyz"), decoder: .coreImageDefault, now: fixedNow
    )
    guard case .migrate(let created, let curation) = decision else { return XCTFail() }
    XCTAssertEqual(created.adjustments, .neutral)
    XCTAssertEqual(created.schemaVersion, PhotoSidecar.currentSchemaVersion)
    XCTAssertEqual(curation, PhotoCuration(rating: 5))
}
```

- [ ] **Step 2: Run and confirm RED**

```bash
swift test --filter CurationMigrationDecisionTests
```

- [ ] **Step 3: Implement**

```swift
enum CurationMigrationDecision: Equatable {
    case sidecarAuthoritative(PhotoCuration)
    case unchanged(PhotoCuration)
    case migrate(sidecar: PhotoSidecar, curation: PhotoCuration)
}

enum CurationMigration {
    static func decide(
        existingSidecar: PhotoSidecar?,
        existingSQLiteCuration: PhotoCuration?,
        photoID: PhotoID,
        sourceRelativePath: String,
        sourceFingerprint: FileFingerprint,
        decoder: DecoderDescriptor,
        now: Date
    ) -> CurationMigrationDecision {
        if let sidecar = existingSidecar, sidecar.schemaVersion >= PhotoSidecar.currentSchemaVersion {
            return .sidecarAuthoritative(sidecar.curation)
        }
        let sqliteCuration = existingSQLiteCuration ?? .neutral
        guard !sqliteCuration.isNeutral else { return .unchanged(.neutral) }

        if let sidecar = existingSidecar {
            var migrated = sidecar
            migrated.schemaVersion = PhotoSidecar.currentSchemaVersion
            migrated.curation = sqliteCuration
            return .migrate(sidecar: migrated, curation: sqliteCuration)
        }
        let created = PhotoSidecar(
            photoID: photoID,
            sourceRelativePath: sourceRelativePath,
            sourceFingerprint: sourceFingerprint,
            decoder: decoder,
            adjustments: .neutral,
            curation: sqliteCuration,
            createdAt: now,
            modifiedAt: now
        )
        return .migrate(sidecar: created, curation: sqliteCuration)
    }
}
```

`internal` visibility is enough — only `PhotoLibraryService` (same module) calls this.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter CurationMigrationDecisionTests
swift build -Xswiftc -strict-concurrency=complete
git add Sources/PhotoLibraryCore/Service/CurationMigration.swift Tests/PhotoLibraryCoreTests/CurationMigrationDecisionTests.swift
git commit -m "feat: add pure curation migration decision function"
```

---

## Task 4 (P1): SQLite schema v5, bulk curation snapshot, pending column

**Files:**
- Modify: `Sources/PhotoLibraryCore/Index/PhotoIndexStore.swift`
- Modify: `Sources/PhotoLibraryCore/Model/PhotoAsset.swift`
- Modify: `Tests/PhotoLibraryCoreTests/PhotoIndexMigrationTests.swift`
- Modify: `Tests/PhotoLibraryCoreTests/PhotoIndexQueryTests.swift`

- [ ] **Step 1: Write failing migration and query tests**

```swift
// PhotoIndexMigrationTests.swift
func testOpeningV4DatabaseMigratesAtomicallyToV5() throws {
    // seed a v4 fixture DB (existing helper), open through PhotoIndexStore
    let store = try PhotoIndexStore(databaseURL: url)
    XCTAssertEqual(PhotoIndexStore.schemaVersion, 5)
    XCTAssertTrue(try columnExists("photo", "curation_migration_pending", at: url))
}

func testV5MigrationFailureRollsBack() throws {
    try makeSchemaV4Database(at: url, photoCount: 1)
    XCTAssertThrowsError(try PhotoIndexStore(databaseURL: url, migrationHook: { throw TestError.injected }))
    XCTAssertEqual(try readSchemaVersion(at: url), 4)
    XCTAssertFalse(try columnExists("photo", "curation_migration_pending", at: url))
}

// PhotoIndexQueryTests.swift
func testCurationSnapshotReturnsOnlyRowsThatExist() throws {
    try store.upsert(photo: .stub(libraryID: libraryID))
    try store.setRating(4, for: photo.id)
    let snapshot = try store.curationSnapshot(inLibrary: libraryID)
    XCTAssertEqual(snapshot[photo.id]?.rating, 4)
    XCTAssertNil(snapshot[PhotoID()])
}

func testCurationSnapshotIncludesKeywords() throws {
    try store.setKeywords(["Dog", "Beach"], for: photo.id)
    let snapshot = try store.curationSnapshot(inLibrary: libraryID)
    XCTAssertEqual(Set(snapshot[photo.id]?.keywords.map(\.displayValue) ?? []), ["Dog", "Beach"])
}

func testSetCurationMigrationPendingRoundTrips() throws {
    try store.setCurationMigrationPending(true, for: photo.id)
    XCTAssertEqual(try store.photo(id: photo.id)?.curationMigrationPending, true)
    try store.setCurationMigrationPending(false, for: photo.id)
    XCTAssertEqual(try store.photo(id: photo.id)?.curationMigrationPending, false)
}
```

- [ ] **Step 2: Run and confirm RED**

```bash
swift test --filter 'PhotoIndexMigrationTests|PhotoIndexQueryTests'
```

- [ ] **Step 3: Implement schema v5**

In `migrateToLatestSchemaIfNeeded`, add:

```swift
if version < 5 {
    try addColumnIfNeeded(
        "curation_migration_pending", to: "photo",
        definition: "INTEGER NOT NULL DEFAULT 0"
    )
}
```

Bump `public static let schemaVersion = 5`.

Add `curation_migration_pending` to `photoColumnList`/`photoColumns`, the `upsertPhoto` INSERT/VALUES list (from `photo.curationMigrationPending`) — but **not** to its `ON CONFLICT DO UPDATE SET` list, for the same reason `rating`/`flag` are already excluded there: a rescan must never clobber a pending flag that only an explicit migration attempt (Task 5) is allowed to change. Add the column to `Self.photoAsset(from:)`'s row mapping.

Add:

```swift
public func curationSnapshot(inLibrary libraryID: LibraryID) throws -> [PhotoID: PhotoCuration] {
    try withLock {
        let ratingsAndFlags = try database.query(
            "SELECT photo_id, rating, flag FROM photo WHERE library_id = ?;",
            [.text(libraryID.description)]
        ) { (id: $0.string(0), rating: Int($0.int(1)), flag: PhotoFlag(rawValue: $0.string(2)) ?? .none) }

        let keywordRows = try database.query("""
            SELECT k.photo_id, k.normalized, k.display_value
            FROM photo_keyword k
            JOIN photo p ON p.photo_id = k.photo_id
            WHERE p.library_id = ?;
            """, [.text(libraryID.description)]
        ) { (id: $0.string(0), keyword: PhotoKeyword(normalized: $0.string(1), displayValue: $0.string(2))) }
        var keywordsByID: [String: [PhotoKeyword]] = [:]
        for row in keywordRows { keywordsByID[row.id, default: []].append(row.keyword) }

        var result: [PhotoID: PhotoCuration] = [:]
        for row in ratingsAndFlags {
            guard let id = PhotoID(uuidString: row.id) else { continue }
            result[id] = PhotoCuration(rating: row.rating, flag: row.flag, keywords: keywordsByID[row.id] ?? [])
        }
        return result
    }
}

public func setCurationMigrationPending(_ pending: Bool, for photoID: PhotoID) throws {
    try withLock {
        try database.run(
            "UPDATE photo SET curation_migration_pending = ? WHERE photo_id = ?;",
            [.integer(pending ? 1 : 0), .text(photoID.description)]
        )
    }
}
```

- [ ] **Step 4: Add `PhotoAsset.curationMigrationPending`**

```swift
public var curationMigrationPending: Bool = false
```

(Give it a default in the memberwise initializer so every existing call site keeps compiling unchanged.)

- [ ] **Step 5: Run and commit**

```bash
swift test --filter 'PhotoIndexMigrationTests|PhotoIndexQueryTests|PhotoIndexStoreTests|PhotoCatalogMetadataTests'
swift build -Xswiftc -strict-concurrency=complete
git add Sources/PhotoLibraryCore/Index/PhotoIndexStore.swift Sources/PhotoLibraryCore/Model/PhotoAsset.swift Tests/PhotoLibraryCoreTests/PhotoIndexMigrationTests.swift Tests/PhotoLibraryCoreTests/PhotoIndexQueryTests.swift
git commit -m "feat: add SQLite schema v5 curation snapshot and pending flag"
```

---

## Task 5 (P1): Wire migration into scan hydration; fix the durability baseline

**Files:**
- Modify: `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`
- Modify: `Tests/PhotoLibraryCoreTests/CurationDurabilityTests.swift` (flip the Task 0 baseline)
- Modify: `Tests/PhotoLibraryCoreTests/VirtualCopyServiceTests.swift`

- [ ] **Step 1: Extend `editState` into a combined hydration helper**

Replace the call site at the scan loop (currently `Self.editState(photoID:repository:)`) with a helper that also resolves curation, using one `curationSnapshot` computed once per scan (mirroring the existing `variantRecordsByOriginal` precomputation pattern):

```swift
let curationSnapshot = (try? index.curationSnapshot(inLibrary: libraryID)) ?? [:]
```

placed alongside the existing `variantRecordsByOriginal` computation, before the `for await event in scanner.scan(...)` loop.

Add:

```swift
private static func hydrateCurationAndEditState(
    asset: inout PhotoAsset,
    existingSQLiteCuration: PhotoCuration?,
    repository: FileSidecarRepository,
    decoder: DecoderDescriptor
) {
    let existingSidecar = try? repository.loadSidecar(for: asset.id)
    asset.hasEdits = existingSidecar.map { !$0.adjustments.isNeutral } ?? false
    asset.lastEditAt = asset.hasEdits ? existingSidecar?.modifiedAt : nil

    let decision = CurationMigration.decide(
        existingSidecar: existingSidecar,
        existingSQLiteCuration: existingSQLiteCuration,
        photoID: asset.id,
        sourceRelativePath: asset.relativePath,
        sourceFingerprint: asset.fingerprint,
        decoder: decoder,
        now: Date()
    )
    switch decision {
    case .sidecarAuthoritative(let curation), .unchanged(let curation):
        asset.rating = curation.rating
        asset.flag = curation.flag
        asset.keywords = curation.keywords
        asset.curationMigrationPending = false
    case .migrate(let sidecar, let curation):
        if (try? repository.write(sidecar: sidecar)) != nil {
            asset.rating = curation.rating
            asset.flag = curation.flag
            asset.keywords = curation.keywords
            asset.curationMigrationPending = false
        } else {
            let fallback = existingSQLiteCuration ?? .neutral
            asset.rating = fallback.rating
            asset.flag = fallback.flag
            asset.keywords = fallback.keywords
            asset.curationMigrationPending = true
        }
    }
}
```

Call this instead of the bare `editState` call, passing `curationSnapshot[asset.id]`, at both the main per-file call site and inside `virtualCopyAssets(for:...)` (a virtual copy's own sidecar is authoritative from creation — spec rule 7 — so it takes the same path uniformly; its `existingSQLiteCuration` will typically be `nil` on first discovery after a rebuild, and row 4/5 of the table handles that correctly since a copy's sidecar always already carries `curation: .neutral` written by `createVirtualCopy`).

- [ ] **Step 2: Remove the now-redundant standalone `editState(photoID:repository:)`**, since its logic is folded into the new helper. Update its one remaining call site if any test references it directly (none should, per the earlier grep — it was `private`).

- [ ] **Step 3: Flip the Task 0 baseline test to assert the fix**

```swift
// CurationDurabilityTests.swift
func testIndexRebuildRestoresRatingFlagAndKeywordsFromSidecar() async throws {
    let (service, libraryID, photoID) = try await makeLibraryWithOnePhoto()
    // Set curation the sidecar-first way (Task 6 API) once it exists;
    // until Task 6 lands, seed through the sidecar directly here to keep
    // this test's own dependency order correct:
    try await service.setRating(5, for: photoOf(photoID))
    try await service.setFlag(.pick, for: photoOf(photoID))
    try await service.setKeywords(["Sunset"], for: photoOf(photoID))

    try await service.resetRebuildableLocalData()
    try await drainScan(service, libraryID: libraryID)

    let photo = try await service.indexStore.photo(id: photoID)
    XCTAssertEqual(photo?.rating, 5)
    XCTAssertEqual(photo?.flag, .pick)
    XCTAssertEqual(photo?.keywords.map(\.displayValue), ["Sunset"])
    XCTAssertEqual(photo?.curationMigrationPending, false)
}

func testLegacySQLiteOnlyCurationMigratesOnNextScan() async throws {
    // Simulate the pre-P1 world: set curation through the raw SQLite API
    // only (no sidecar), matching what LibraryViewModel did before Task 6.
    let (service, libraryID, photoID) = try await makeLibraryWithOnePhoto()
    let indexStore = await service.indexStore
    try indexStore.setRating(4, for: photoID)

    try await rescan(service, libraryID: libraryID)  // no reset -- prove in-place migration too

    let photo = try await service.indexStore.photo(id: photoID)
    XCTAssertEqual(photo?.rating, 4)
    XCTAssertEqual(photo?.curationMigrationPending, false)
    // and the sidecar on disk is now schema v3 carrying that rating:
    let sidecar = try repository(for: service, libraryID: libraryID).loadSidecar(for: photoID)
    XCTAssertEqual(sidecar?.schemaVersion, PhotoSidecar.currentSchemaVersion)
    XCTAssertEqual(sidecar?.curation.rating, 4)
}

func testReadOnlySourceKeepsSQLiteValuesAndMarksPendingThenRetries() async throws {
    // Make the library root read-only, set SQLite-only curation, rescan:
    // expect values preserved and curationMigrationPending == true.
    // Restore write permission, rescan again: expect pending clears and a
    // v3 sidecar now exists.
}
```

- [ ] **Step 4: Extend `VirtualCopyServiceTests.swift`**

```swift
func testVirtualCopyStartsWithNeutralCuration() throws {
    let copy = try service.createVirtualCopy(of: original)
    XCTAssertEqual(copy.rating, 0)
    XCTAssertEqual(copy.flag, .none)
    XCTAssertEqual(copy.keywords, [])
}
```

- [ ] **Step 5: Run and confirm RED, then implement, then GREEN**

```bash
swift test --filter 'CurationDurabilityTests|VirtualCopyServiceTests'
```

Implement Step 1–2 above, rerun until green.

- [ ] **Step 6: Full regression and commit**

```bash
swift test --filter 'PhotoLibraryCoreTests'
swift build -Xswiftc -strict-concurrency=complete
git add Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift Tests/PhotoLibraryCoreTests/CurationDurabilityTests.swift Tests/PhotoLibraryCoreTests/VirtualCopyServiceTests.swift
git commit -m "fix: hydrate and migrate curation from sidecar during scan"
```

---

## Task 6 (P1): Sidecar-first curation mutation API

**Files:**
- Modify: `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`
- Modify: `Tests/PhotoLibraryCoreTests/PhotoLibraryServiceTests.swift` (create if it doesn't already exist as a distinct file — check first; if curation-mutation tests belong better alongside existing service-level tests, add to whichever file already exercises `saveAdjustments`)

- [ ] **Step 1: Write failing tests**

```swift
func testSetRatingWritesSidecarFirst() async throws {
    let (service, _, photoID) = try await makeLibraryWithOnePhoto()
    try await service.setRating(5, for: photoOf(photoID))
    let sidecar = try repository(for: service).loadSidecar(for: photoID)
    XCTAssertEqual(sidecar?.curation.rating, 5)
    let projected = try await service.indexStore.photo(id: photoID)
    XCTAssertEqual(projected?.rating, 5)
}

func testSetRatingRejectsOutOfRangeValue() async throws {
    await XCTAssertThrowsErrorAsync(try await service.setRating(9, for: photo)) {
        XCTAssertEqual($0 as? LibraryQueryError, .invalidRating(9))
    }
}

func testSetFlagPreservesRatingAndKeywords() async throws {
    try await service.setRating(3, for: photo)
    try await service.setKeywords(["Dog"], for: photo)
    try await service.setFlag(.pick, for: photo)
    let sidecar = try repository(for: service).loadSidecar(for: photoID)
    XCTAssertEqual(sidecar?.curation, PhotoCuration(rating: 3, flag: .pick, keywords: [PhotoKeyword(normalized: "dog", displayValue: "Dog")]))
}

func testSetKeywordsRejectsBlankKeyword() async throws {
    await XCTAssertThrowsErrorAsync(try await service.setKeywords([""], for: photo)) {
        XCTAssertEqual($0 as? LibraryQueryError, .invalidKeyword)
    }
}

func testSetRatingThrowsWhenSourceOffline() async throws {
    // detach the library root; expect LibraryError.offline and confirm
    // no partial SQLite write happened.
}

func testSetRatingSQLiteProjectionFailureStillLeavesSidecarSaved() async throws {
    // Inject an index failure the same way saveAdjustments's own tests do
    // (if such a seam exists); assert the sidecar write already succeeded
    // and is not rolled back.
}

func testCurationForPhotoReadsSidecarNotSQLite() async throws {
    // Write mismatched SQLite value directly through indexStore, then
    // confirm curation(for:) still returns the sidecar's value.
}
```

- [ ] **Step 2: Run and confirm RED**

```bash
swift test --filter <the chosen test file>
```

- [ ] **Step 3: Implement**

```swift
public func curation(for photo: PhotoAsset) throws -> PhotoCuration {
    try recoverPendingRegistryTransaction()
    guard let folder = libraries[photo.libraryID] else { throw LibraryError.notFound(photo.libraryID) }
    guard folder.isOnline else { throw LibraryError.offline(path: folder.lastKnownPath) }
    let repository = FileSidecarRepository(libraryRootURL: folder.rootURL)
    do {
        return try repository.loadSidecar(for: photo.id)?.curation ?? .neutral
    } catch let error as SidecarError {
        throw LibraryError.sidecar(error)
    }
}

private func mutateCuration(
    for photo: PhotoAsset,
    transform: (inout PhotoCuration) -> Void
) throws {
    try recoverPendingRegistryTransaction()
    guard let folder = libraries[photo.libraryID] else { throw LibraryError.notFound(photo.libraryID) }
    guard folder.isOnline else { throw LibraryError.offline(path: folder.lastKnownPath) }
    let repository = FileSidecarRepository(libraryRootURL: folder.rootURL)

    do {
        let existing = try? repository.loadSidecar(for: photo.id)
        var curation = existing?.curation ?? .neutral
        transform(&curation)
        let now = Date()
        let sidecar = PhotoSidecar(
            photoID: photo.id,
            sourceRelativePath: photo.relativePath,
            sourceFingerprint: photo.fingerprint,
            decoder: DecoderDescriptor(decoder.identifier),
            adjustments: existing?.adjustments ?? .neutral,
            curation: curation,
            createdAt: existing?.createdAt ?? now,
            modifiedAt: existing?.modifiedAt ?? now,   // curation is not an "edit" -- do not disturb the adjustments' own modifiedAt semantics used elsewhere; see note below
            variantOf: photo.variantOf ?? existing?.variantOf
        )
        try repository.write(sidecar: sidecar)
        // Best-effort projection, same tolerance as saveAdjustments (spec §8.1).
        try? index.setRating(curation.rating, for: photo.id)
        try? index.setFlag(curation.flag, for: photo.id)
        try? index.setKeywords(curation.keywords.map(\.displayValue), for: photo.id)
        try? index.setCurationMigrationPending(false, for: photo.id)
    } catch let error as SidecarError {
        throw LibraryError.sidecar(error)
    }
}

public func setRating(_ rating: Int, for photo: PhotoAsset) throws {
    guard (0...5).contains(rating) else { throw LibraryQueryError.invalidRating(rating) }
    try mutateCuration(for: photo) { $0.rating = rating }
}

public func setFlag(_ flag: PhotoFlag, for photo: PhotoAsset) throws {
    try mutateCuration(for: photo) { $0.flag = flag }
}

public func setKeywords(_ inputs: [String], for photo: PhotoAsset) throws {
    var keywords: [PhotoKeyword] = []
    for input in inputs {
        guard let keyword = PhotoKeyword.make(from: input) else { throw LibraryQueryError.invalidKeyword }
        keywords.append(keyword)
    }
    try mutateCuration(for: photo) { $0.keywords = keywords }
}
```

Note on `modifiedAt`: keep `existing?.modifiedAt ?? now` for a curation-only mutation, i.e. **do not** bump `modifiedAt` for a rating/flag/keyword change alone — `modifiedAt`/`lastEditAt` are specifically about `adjustments` elsewhere in this codebase (`PhotoAsset.lastEditAt` doc comment: "the sidecar's modifiedAt... nil when the photo has no edits or its adjustments are neutral"). Changing that meaning would alter the existing "Recently Edited" smart scope semantics, which is out of this plan's scope. Add a unit test asserting a rating change alone does not change `lastEditAt`/`hasEdits`.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter PhotoLibraryCoreTests
swift build -Xswiftc -strict-concurrency=complete
git add Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift <chosen test file>
git commit -m "feat: make PhotoLibraryService curation mutations sidecar-first"
```

---

## Task 7 (P1): Rewire the Mac UI call sites

**Files:**
- Modify: `Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift`
- Modify: `Tests/LumaHarborAppTests/EditorWorkflowUXContractTests.swift`

- [ ] **Step 1: Write a failing source-contract test**

Following this codebase's existing style of asserting production source text rather than only behavior (see e.g. the `WorkspaceLayoutState` contract tests already in this file):

```swift
func testLibraryViewModelCurationMutationsGoThroughLibraryServiceNotIndexStoreDirectly() throws {
    let source = try sourceText(of: "Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift")
    let body = try extractFunctionBodies(named: ["setRatingForSelectedPhoto", "setFlagForSelectedPhoto", "setKeywordsForPhoto"], in: source)
    XCTAssertFalse(body.contains("indexStore.setRating"))
    XCTAssertFalse(body.contains("indexStore.setFlag"))
    XCTAssertFalse(body.contains("indexStore.setKeywords"))
    XCTAssertTrue(body.contains("libraryService.setRating"))
    XCTAssertTrue(body.contains("libraryService.setFlag"))
    XCTAssertTrue(body.contains("libraryService.setKeywords"))
}
```

(Reuse whatever existing source-extraction helper this test file already has — it already builds one, per the `extractProperty(named:from:)` helper mentioned in `docs/coordination/CURRENT.md`'s Phase 2.3 notes; adapt it to functions if a function-body variant does not already exist, in the same file, not a new shared utility.)

- [ ] **Step 2: Run and confirm RED**

```bash
swift test --filter EditorWorkflowUXContractTests
```

- [ ] **Step 3: Implement the call-site swap**

```swift
func setRatingForSelectedPhoto(_ rating: Int) {
    guard let photoID = selectedPhotoID, let services, let photo = photo(for: photoID) else { return }
    Task { [weak self] in
        do {
            try await services.libraryService.setRating(rating, for: photo)
            await self?.reloadPhotos()
        } catch {
            self?.alert = UserAlert(title: L10n.t("Couldn't save rating"), error: error)
        }
    }
}

func setFlagForSelectedPhoto(_ flag: PhotoFlag) {
    guard let photoID = selectedPhotoID, let services, let photo = photo(for: photoID) else { return }
    Task { [weak self] in
        do {
            try await services.libraryService.setFlag(flag, for: photo)
            await self?.reloadPhotos()
        } catch {
            self?.alert = UserAlert(title: L10n.t("Couldn't save flag"), error: error)
        }
    }
}

func setKeywordsForPhoto(_ photoID: PhotoID, inputs: [String]) {
    guard let services, let photo = photo(for: photoID) else { return }
    Task { [weak self] in
        do {
            try await services.libraryService.setKeywords(inputs, for: photo)
            await self?.reloadPhotos()
        } catch {
            self?.alert = UserAlert(title: L10n.t("Couldn't save keywords"), error: error)
        }
    }
}
```

`photo(for:)` is the existing `private func photo(for id: PhotoID) -> PhotoAsset?` at `LibraryViewModel.swift:259`; confirm it is visible from these methods (same type, already `private` — fine, same file).

- [ ] **Step 4: Run and commit**

```bash
swift test --filter 'EditorWorkflowUXContractTests|LibraryViewModelTransitionTests'
swift build -Xswiftc -strict-concurrency=complete
(cd Apps/LumaHarborPad.swiftpm && xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build) || true  # iPad app does not call these Mac view-model methods; run only to prove no cross-target regression
git add Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift Tests/LumaHarborAppTests/EditorWorkflowUXContractTests.swift
git commit -m "fix: route Mac rating/flag/keyword edits through the sidecar-first API"
```

---

## Task 8: Record the phase-scoping decision and full verification

**Files:**
- Modify: `docs/coordination/DECISIONS.md`
- Modify: `docs/coordination/CURRENT.md`
- Create: `docs/coordination/handoffs/2026-09-10-p0-p1-curation-sidecar-v3.md` (use `HANDOFF_TEMPLATE.md`)

- [ ] **Step 1: Append D-006 to `DECISIONS.md`**

```markdown
## D-006 — Sidecar schema v3 ships without `snapshots`

- Date: 2026-09-10
- Decision: `PhotoSidecar.currentSchemaVersion = 3` adds `curation` only. The approved spec's §6.1 bundles `curation` and `snapshots` into one version bump; this plan implements P1 only (curation) and defers `EditSnapshot`/`snapshots` to P6, where it will ship as its own schema version.
- Reason: The task authorizing this plan explicitly excludes P2 and later phases, including P6 (Snapshot). Defining `EditSnapshot` now, only to satisfy a version-number bundling in the spec text, would be scope creep with no test coverage or consumer.
- Impact: A future P6 plan bumps `PhotoSidecar.currentSchemaVersion` again (to 4) when it adds `snapshots`; that plan must re-verify v1/v2/v3 sidecars all still decode.
```

- [ ] **Step 2: Run the full verification matrix**

```bash
swift test 2>&1 | tee /tmp/lumaharbor-p0-p1-swift-test.log
swift build -Xswiftc -strict-concurrency=complete
(cd Apps/LumaHarborPad.swiftpm && xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build)
git diff --check
rg -n '/Users/[A-Za-z0-9_.-]+|/Volumes/[A-Za-z0-9_.-]+|DEVELOPMENT_TEAM|BEGIN (RSA|EC|OPENSSH) PRIVATE KEY' \
  $(git diff --name-only main...HEAD) docs/coordination/DECISIONS.md docs/coordination/CURRENT.md \
  || echo "privacy scan: no hits"
```

Record for each: exact command, exit code, and (for `swift test`) executed/skipped/failure counts. If any command is unavailable in this environment (e.g. no Xcode iOS SDK), record that step `NOT RUN` with the reason — never `PASS`.

- [ ] **Step 3: Update `docs/coordination/CURRENT.md`**

Prepend a new dated section (do not delete history) stating: branch `claude/professional-editing-completion`, full HEAD SHA after Task 7's commit, the fact that P0 baseline-protection tests and P1 (`PhotoSidecar` v3, `PhotoCuration`, sidecar-first mutation, SQLite projection, resumable migration, index-rebuild recovery) are implemented and committed, the verification results from Step 2 with PASS/FAIL/SKIPPED/NOT RUN kept distinct, that P2 onward remain untouched, and that `AdvancedToneCurve`/`CurveAdjustmentPanel`/`HistogramPanel` are unmodified (cite `git diff --stat` confirming no changes under `Sources/RawProcessingCore/Model/AdvancedToneCurve.swift`, `Sources/AdjustmentUI/CurveAdjustmentPanel.swift`, `Sources/AdjustmentUI/HistogramPanel.swift`).

- [ ] **Step 4: Write the handoff**

Use `docs/coordination/HANDOFF_TEMPLATE.md` verbatim, filling in real evidence from Step 2, and naming the next bounded objective as "P2: shared professional Inspector catalog" per `docs/superpowers/specs/2026-09-10-professional-editing-completion-design.md` §16 item 2 — explicitly out of scope for whoever picks this up next unless the user says otherwise.

- [ ] **Step 5: Commit coordination updates as their own commit**

```bash
git add docs/coordination/DECISIONS.md docs/coordination/CURRENT.md docs/coordination/handoffs/2026-09-10-p0-p1-curation-sidecar-v3.md
git commit -m "docs: record P0/P1 curation sidecar v3 completion and handoff"
```

## Final Review Gate

Before declaring this plan done:

1. Re-read spec §11.1 acceptance items 1–6 and confirm each has a named test from this plan (#1 → `SidecarSchemaCompatibilityTests`; #4 → `CurationDurabilityTests.testIndexRebuildRestoresRatingFlagAndKeywordsFromSidecar`; #5 → `testReadOnlySourceKeepsSQLiteValuesAndMarksPendingThenRetries`; #6 → the custom `Codable` preserves any JSON key not modeled here because it only ever reads the keys it knows and Foundation's default `Decodable` ignores the rest — add one explicit test decoding a sidecar JSON blob with an extra unknown top-level key and re-encoding it, asserting no crash; note this does *not* prove the unknown key round-trips, since a keyed `Codable` container cannot preserve keys it never modeled — if literal preservation of unknown top-level keys is required, that needs a follow-up plan using a raw-JSON merge strategy, and this gate must record that as an explicit, named gap rather than a silent pass).
2. Run `rg -n 'TBD|TODO|FIXME|fatalError|try!' Sources/PhotoLibraryCore/Model/PhotoCuration.swift Sources/PhotoLibraryCore/Service/CurationMigration.swift` and resolve or justify every hit.
3. Confirm no test added by this plan touches a real RAW fixture path or private directory.
4. Confirm `git log --oneline` shows one commit per task above, in order, each independently revertable per G7.
