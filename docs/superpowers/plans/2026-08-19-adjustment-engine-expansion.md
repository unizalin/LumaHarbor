# Adjustment Engine Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add seven new adjustment sub-models (advanced tone curve, HSL, split toning, sharpening, noise reduction, vignette, grain) to `PhotoAdjustments`, wire them into the render pipeline, and bump the sidecar schema — with **no new UI**, per spec.

**Architecture:** Each new adjustment type is a small `Codable, Equatable, Hashable, Sendable` value type living in `Sources/RawProcessingCore/Model/`, following the exact `decodeIfPresent` + clamp + `.neutral` pattern already used by `PhotoAdjustments`. `RenderParameters`/`AdjustmentMapping` (`Sources/RawProcessingCore/Model/AdjustmentMapping.swift`) grow new fields and `isXIdentity` flags, one per new type. `AdjustmentPipeline.apply` grows new stages, each skipped when its parameter is at identity, inserted at the exact points spec §4.2 specifies. Two stages (advanced curve, HSL) need custom `CIColorKernel`s; the rest use built-in `CIFilter`s.

**Tech Stack:** Swift 6.1, Swift Package Manager, XCTest, Core Image (`CIColorKernel`, `CIFilterBuiltins`). No new dependencies (package is deliberately dependency-free).

**Spec:** `docs/superpowers/specs/2026-08-19-adjustment-engine-expansion-design.md` — read this plan alongside it; task descriptions below reference its section numbers (§3, §4, §5, §6) rather than repeating the full rationale.

## Global Constraints

- **No new UI.** Inspector stays at its existing 10 sliders. New fields are never written by any `AdjustmentKind`-driven code path in this plan (spec §1).
- **`PhotoAdjustments.isNeutral`/`modifiedKinds` are not touched.** `isNeutral` picks up the new fields automatically via synthesized `Equatable`; `modifiedKinds` stays scoped to the 10 existing `AdjustmentKind` cases (spec §3.8).
- **Every new struct is `Codable, Equatable, Hashable, Sendable`** with a `.neutral` static value, decodes missing/out-of-range JSON to neutral/clamped rather than throwing, and always encodes every field (spec §3, following `PhotoAdjustments`'s existing convention — `decodeIfPresent` + default fallback, clamp on both `init` and decode).
- **Sidecar schema version bumps from 1 to 2** (`PhotoSidecar.currentSchemaVersion`, `Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift:32`). No new test needed for the reject-newer-schema path — `SidecarRepositoryTests` already covers it generically (spec §5).
- **Every new pipeline stage is skipped entirely when at identity** — no filter constructed, nothing added to the chain (spec §4.4), matching every existing stage in `AdjustmentPipeline.apply`.
- **Pipeline order is fixed** (spec §4.2): after existing step 5 (Vibrance), before "back to linear": 5.5 advanced curve → 6 HSL → 7 split toning → *(back to linear)* → 8 sharpening → 9 noise reduction → 10 vignette → 11 grain.
- **This machine (confirmed 2026-08-20) cannot compile or run any file that `import XCTest`.** No Xcode.app is installed (Command Line Tools only), and CLT has never shipped `XCTest.framework`. `swift test`, `swift build --build-tests`, and the `swiftc -typecheck -enable-testing` workaround HANDOFF.md documents from 2026-08-15 all fail identically at the `import XCTest` line. **`swift build` (Sources/ only, no `--build-tests`) still works and is the only local verification available** — every "Run: `swift test` ... Expected: PASS" step below is replaced in practice by (1) `swift build` to confirm production code compiles, and (2) writing the test file carefully and tracing its logic by hand, since it cannot be compiled or executed here at all. Real test execution (and the Task 8 manual visual verification) happens on a separate Apple Silicon + Xcode machine, per this project's existing Gate D/E/F convention. State this substitution explicitly in every implementer/reviewer report so nobody mistakes "compiles" for "tests pass."
- **One commit per task below**, message states what and why. Do not batch multiple tasks into one commit (spec "給接手者的話").
- **If you run out of budget mid-plan:** append to the spec's `## 進度日誌` section (bottom of `docs/superpowers/specs/2026-08-19-adjustment-engine-expansion-design.md`) — which task/step you reached, what's committed vs. half-done, what's next — then commit + push before stopping. Do not leave uncommitted work on disk.

---

### Task 1: Seven new adjustment sub-structs (pure data, no rendering)

Spec §3.1–§3.7, §7 item 1. Pure value types + unit tests only. Nothing in this task touches `PhotoAdjustments`, the pipeline, or the sidecar.

**Files:**
- Modify: `Sources/RawProcessingCore/Model/ToneCurveMapping.swift:4` — `ToneCurvePoint` needs `Codable, Hashable` added (currently only `Equatable, Sendable`) because `AdvancedToneCurve` wraps `[ToneCurvePoint]` and must itself be `Codable, Hashable`.
- Create: `Sources/RawProcessingCore/Model/AdvancedToneCurve.swift`
- Create: `Sources/RawProcessingCore/Model/HSLAdjustments.swift`
- Create: `Sources/RawProcessingCore/Model/SplitToning.swift`
- Create: `Sources/RawProcessingCore/Model/Sharpening.swift`
- Create: `Sources/RawProcessingCore/Model/NoiseReduction.swift`
- Create: `Sources/RawProcessingCore/Model/Vignette.swift`
- Create: `Sources/RawProcessingCore/Model/Grain.swift`
- Test: `Tests/RawProcessingCoreTests/AdvancedToneCurveTests.swift`
- Test: `Tests/RawProcessingCoreTests/HSLAdjustmentsTests.swift`
- Test: `Tests/RawProcessingCoreTests/SplitToningTests.swift`
- Test: `Tests/RawProcessingCoreTests/SharpeningTests.swift`
- Test: `Tests/RawProcessingCoreTests/NoiseReductionTests.swift`
- Test: `Tests/RawProcessingCoreTests/VignetteTests.swift`
- Test: `Tests/RawProcessingCoreTests/GrainTests.swift`

**Interfaces (what Task 2+ will consume):**
- `AdvancedToneCurve.neutral`, `.points: [ToneCurvePoint]`, `.isIdentity: Bool` (`points.isEmpty`)
- `HSLAdjustments.neutral`, `.red/.orange/.yellow/.green/.aqua/.blue/.purple/.magenta: HSLBand`, `.isIdentity: Bool`
- `HSLBand.hue/.saturation/.luminance: Double`, `.init(hue:saturation:luminance:)` with defaults `0,0,0`
- `SplitToning.neutral`, `.shadowHue/.shadowSaturation/.highlightHue/.highlightSaturation/.balance: Double`, `.isIdentity: Bool`
- `Sharpening.neutral`, `.amount/.radius/.detail/.masking: Double`, `.isIdentity: Bool`
- `NoiseReduction.neutral`, `.luminanceAmount/.luminanceDetail/.colorAmount/.colorDetail: Double`, `.isIdentity: Bool`
- `Vignette.neutral`, `.amount/.midpoint/.roundness/.feather: Double`, `.isIdentity: Bool`
- `Grain.neutral`, `.amount/.size/.roughness: Double`, `.isIdentity: Bool`

- [ ] **Step 1: Add `Codable, Hashable` to `ToneCurvePoint`**

In `Sources/RawProcessingCore/Model/ToneCurveMapping.swift`, change line 4:

```swift
public struct ToneCurvePoint: Codable, Equatable, Hashable, Sendable {
```

`x`/`y` are both `Double`, so the compiler synthesizes `Codable`/`Hashable` for free — no other change needed in this file.

- [ ] **Step 2: Write the failing tests for `AdvancedToneCurve`**

```swift
// Tests/RawProcessingCoreTests/AdvancedToneCurveTests.swift
import XCTest
@testable import RawProcessingCore

final class AdvancedToneCurveTests: XCTestCase {
    func testNeutralIsEmptyAndIdentity() {
        XCTAssertTrue(AdvancedToneCurve.neutral.points.isEmpty)
        XCTAssertTrue(AdvancedToneCurve.neutral.isIdentity)
    }

    func testNonEmptyPointsIsNotIdentity() {
        let curve = AdvancedToneCurve(points: [ToneCurvePoint(x: 0.5, y: 0.6)])
        XCTAssertFalse(curve.isIdentity)
    }

    func testRoundTripsThroughJSON() throws {
        let original = AdvancedToneCurve(points: [
            ToneCurvePoint(x: 0, y: 0),
            ToneCurvePoint(x: 0.5, y: 0.7),
            ToneCurvePoint(x: 1, y: 1)
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AdvancedToneCurve.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMissingKeyFallsBackToNeutral() throws {
        let decoded = try JSONDecoder().decode(AdvancedToneCurve.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, .neutral)
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `swift test --filter AdvancedToneCurveTests`
Expected: FAIL — `AdvancedToneCurve` doesn't exist yet.

- [ ] **Step 4: Implement `AdvancedToneCurve`**

```swift
// Sources/RawProcessingCore/Model/AdvancedToneCurve.swift
import Foundation

/// A curve layered on top of the four-slider tone curve (`ToneCurveMapping`),
/// applied later in the pipeline (spec §3.1, §4.2 step 5.5). Unlike the
/// four-slider curve, this one has no fixed point count — its only source is
/// a style file applying an arbitrary Lightroom-style curve, so the shape is
/// whatever `points` says.
public struct AdvancedToneCurve: Codable, Equatable, Hashable, Sendable {
    /// Normalised 0...1 control points. Empty = identity (no-op).
    public var points: [ToneCurvePoint]

    public init(points: [ToneCurvePoint] = []) {
        self.points = points
    }

    public static let neutral = AdvancedToneCurve(points: [])

    public var isIdentity: Bool { points.isEmpty }

    private enum CodingKeys: String, CodingKey { case points }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.points = try container.decodeIfPresent([ToneCurvePoint].self, forKey: .points) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter AdvancedToneCurveTests`
Expected: PASS

- [ ] **Step 6: Write the failing tests for `HSLAdjustments`**

```swift
// Tests/RawProcessingCoreTests/HSLAdjustmentsTests.swift
import XCTest
@testable import RawProcessingCore

final class HSLAdjustmentsTests: XCTestCase {
    func testNeutralIsAllZeroesAndIdentity() {
        let neutral = HSLAdjustments.neutral
        for band in [neutral.red, neutral.orange, neutral.yellow, neutral.green,
                     neutral.aqua, neutral.blue, neutral.purple, neutral.magenta] {
            XCTAssertEqual(band.hue, 0)
            XCTAssertEqual(band.saturation, 0)
            XCTAssertEqual(band.luminance, 0)
        }
        XCTAssertTrue(neutral.isIdentity)
    }

    func testOneBandOffZeroBreaksIdentity() {
        var adjustments = HSLAdjustments.neutral
        adjustments.red.hue = 10
        XCTAssertFalse(adjustments.isIdentity)
    }

    func testBandClampsToPlusMinus100() {
        let band = HSLBand(hue: 500, saturation: -500, luminance: 999)
        XCTAssertEqual(band.hue, 100)
        XCTAssertEqual(band.saturation, -100)
        XCTAssertEqual(band.luminance, 100)
    }

    func testRoundTripsThroughJSON() throws {
        var original = HSLAdjustments.neutral
        original.aqua = HSLBand(hue: -30, saturation: 40, luminance: -10)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HSLAdjustments.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMissingColorKeyFallsBackToNeutralBand() throws {
        let json = Data(#"{"red": {"hue": 20, "saturation": 0, "luminance": 0}}"#.utf8)
        let decoded = try JSONDecoder().decode(HSLAdjustments.self, from: json)
        XCTAssertEqual(decoded.red.hue, 20)
        XCTAssertEqual(decoded.orange, HSLBand())
    }

    func testEncodesAllEightColorKeys() throws {
        let data = try JSONEncoder().encode(HSLAdjustments.neutral)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
        )
    }
}
```

- [ ] **Step 7: Run to verify it fails**

Run: `swift test --filter HSLAdjustmentsTests`
Expected: FAIL — `HSLAdjustments`/`HSLBand` don't exist yet.

- [ ] **Step 8: Implement `HSLAdjustments`**

```swift
// Sources/RawProcessingCore/Model/HSLAdjustments.swift
import Foundation

/// One of the eight Lightroom-style hue bands (spec §3.2).
public struct HSLBand: Codable, Equatable, Hashable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var luminance: Double

    public init(hue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
        self.hue = Self.clamp(hue)
        self.saturation = Self.clamp(saturation)
        self.luminance = Self.clamp(luminance)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, -100), 100)
    }

    private enum CodingKeys: String, CodingKey { case hue, saturation, luminance }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hue = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .hue) ?? 0)
        self.saturation = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0)
        self.luminance = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .luminance) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hue, forKey: .hue)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(luminance, forKey: .luminance)
    }
}

/// Eight-band hue/saturation/luminance, matching Lightroom's HSL panel
/// one-for-one so a future XMP importer needs no colour-space guesswork
/// (spec §3.2).
public struct HSLAdjustments: Codable, Equatable, Hashable, Sendable {
    public var red: HSLBand
    public var orange: HSLBand
    public var yellow: HSLBand
    public var green: HSLBand
    public var aqua: HSLBand
    public var blue: HSLBand
    public var purple: HSLBand
    public var magenta: HSLBand

    public init(
        red: HSLBand = HSLBand(), orange: HSLBand = HSLBand(), yellow: HSLBand = HSLBand(),
        green: HSLBand = HSLBand(), aqua: HSLBand = HSLBand(), blue: HSLBand = HSLBand(),
        purple: HSLBand = HSLBand(), magenta: HSLBand = HSLBand()
    ) {
        self.red = red; self.orange = orange; self.yellow = yellow; self.green = green
        self.aqua = aqua; self.blue = blue; self.purple = purple; self.magenta = magenta
    }

    public static let neutral = HSLAdjustments()

    public var isIdentity: Bool { self == .neutral }

    private enum CodingKeys: String, CodingKey {
        case red, orange, yellow, green, aqua, blue, purple, magenta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func band(_ key: CodingKeys) throws -> HSLBand {
            try container.decodeIfPresent(HSLBand.self, forKey: key) ?? HSLBand()
        }
        self.red = try band(.red); self.orange = try band(.orange)
        self.yellow = try band(.yellow); self.green = try band(.green)
        self.aqua = try band(.aqua); self.blue = try band(.blue)
        self.purple = try band(.purple); self.magenta = try band(.magenta)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(red, forKey: .red); try container.encode(orange, forKey: .orange)
        try container.encode(yellow, forKey: .yellow); try container.encode(green, forKey: .green)
        try container.encode(aqua, forKey: .aqua); try container.encode(blue, forKey: .blue)
        try container.encode(purple, forKey: .purple); try container.encode(magenta, forKey: .magenta)
    }
}
```

- [ ] **Step 9: Run to verify it passes**

Run: `swift test --filter HSLAdjustmentsTests`
Expected: PASS

- [ ] **Step 10: Write, implement and pass `SplitToningTests` / `SplitToning`**

```swift
// Tests/RawProcessingCoreTests/SplitToningTests.swift
import XCTest
@testable import RawProcessingCore

final class SplitToningTests: XCTestCase {
    func testNeutralIsIdentity() {
        XCTAssertTrue(SplitToning.neutral.isIdentity)
    }

    func testBothSaturationsZeroIsIdentityRegardlessOfHueOrBalance() {
        // Spec §3.3: hue/balance are meaningless at zero saturation.
        let splitToning = SplitToning(
            shadowHue: 180, shadowSaturation: 0,
            highlightHue: 90, highlightSaturation: 0, balance: 50
        )
        XCTAssertTrue(splitToning.isIdentity)
    }

    func testEitherSaturationNonZeroBreaksIdentity() {
        XCTAssertFalse(SplitToning(shadowSaturation: 10).isIdentity)
        XCTAssertFalse(SplitToning(highlightSaturation: 10).isIdentity)
    }

    func testHueClampsTo0To360AndSaturationTo0To100() {
        let splitToning = SplitToning(
            shadowHue: -10, shadowSaturation: 200,
            highlightHue: 999, highlightSaturation: -5, balance: 0
        )
        XCTAssertEqual(splitToning.shadowHue, 0)
        XCTAssertEqual(splitToning.shadowSaturation, 100)
        XCTAssertEqual(splitToning.highlightHue, 360)
        XCTAssertEqual(splitToning.highlightSaturation, 0)
    }

    func testBalanceClampsToPlusMinus100() {
        XCTAssertEqual(SplitToning(balance: 500).balance, 100)
        XCTAssertEqual(SplitToning(balance: -500).balance, -100)
    }

    func testRoundTripsThroughJSON() throws {
        let original = SplitToning(
            shadowHue: 210, shadowSaturation: 30,
            highlightHue: 45, highlightSaturation: 20, balance: -15
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SplitToning.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMissingKeysFallBackToNeutral() throws {
        let decoded = try JSONDecoder().decode(SplitToning.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, .neutral)
    }
}
```

```swift
// Sources/RawProcessingCore/Model/SplitToning.swift
import Foundation

/// Independent shadow/highlight colour tinting (spec §3.3).
public struct SplitToning: Codable, Equatable, Hashable, Sendable {
    public var shadowHue: Double
    public var shadowSaturation: Double
    public var highlightHue: Double
    public var highlightSaturation: Double
    /// Negative biases toward shadows, positive toward highlights.
    public var balance: Double

    public init(
        shadowHue: Double = 0, shadowSaturation: Double = 0,
        highlightHue: Double = 0, highlightSaturation: Double = 0,
        balance: Double = 0
    ) {
        self.shadowHue = Self.clamp(shadowHue, 0, 360)
        self.shadowSaturation = Self.clamp(shadowSaturation, 0, 100)
        self.highlightHue = Self.clamp(highlightHue, 0, 360)
        self.highlightSaturation = Self.clamp(highlightSaturation, 0, 100)
        self.balance = Self.clamp(balance, -100, 100)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, low), high)
    }

    public static let neutral = SplitToning()

    /// Hue/balance are meaningless once both saturations are zero, so identity
    /// only checks saturation (spec §3.3).
    public var isIdentity: Bool { shadowSaturation == 0 && highlightSaturation == 0 }

    private enum CodingKeys: String, CodingKey {
        case shadowHue, shadowSaturation, highlightHue, highlightSaturation, balance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ low: Double, _ high: Double) throws -> Double {
            Self.clamp(try container.decodeIfPresent(Double.self, forKey: key) ?? 0, low, high)
        }
        self.shadowHue = try value(.shadowHue, 0, 360)
        self.shadowSaturation = try value(.shadowSaturation, 0, 100)
        self.highlightHue = try value(.highlightHue, 0, 360)
        self.highlightSaturation = try value(.highlightSaturation, 0, 100)
        self.balance = try value(.balance, -100, 100)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shadowHue, forKey: .shadowHue)
        try container.encode(shadowSaturation, forKey: .shadowSaturation)
        try container.encode(highlightHue, forKey: .highlightHue)
        try container.encode(highlightSaturation, forKey: .highlightSaturation)
        try container.encode(balance, forKey: .balance)
    }
}
```

Run: `swift test --filter SplitToningTests` — verify FAIL then PASS around the implementation, same as steps 3–5.

- [ ] **Step 11: Write, implement and pass `SharpeningTests` / `Sharpening`**

```swift
// Tests/RawProcessingCoreTests/SharpeningTests.swift
import XCTest
@testable import RawProcessingCore

final class SharpeningTests: XCTestCase {
    func testDefaultsMatchLightroomConventionAndAreIdentity() {
        let neutral = Sharpening.neutral
        XCTAssertEqual(neutral.amount, 0)
        XCTAssertEqual(neutral.radius, 1.0)
        XCTAssertEqual(neutral.detail, 25)
        XCTAssertEqual(neutral.masking, 0)
        XCTAssertTrue(neutral.isIdentity)
    }

    func testOnlyAmountDeterminesIdentity() {
        // detail/masking away from default must NOT break identity on their own.
        XCTAssertTrue(Sharpening(amount: 0, detail: 80, masking: 50).isIdentity)
        XCTAssertFalse(Sharpening(amount: 1).isIdentity)
    }

    func testClampsToDocumentedRanges() {
        let s = Sharpening(amount: 999, radius: 10, detail: -5, masking: 500)
        XCTAssertEqual(s.amount, 150)
        XCTAssertEqual(s.radius, 3.0)
        XCTAssertEqual(s.detail, 0)
        XCTAssertEqual(s.masking, 100)
        XCTAssertEqual(Sharpening(radius: 0).radius, 0.5)
    }

    func testRoundTripsThroughJSON() throws {
        let original = Sharpening(amount: 60, radius: 1.5, detail: 40, masking: 20)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Sharpening.self, from: data), original)
    }

    func testMissingKeysFallBackToNeutral() throws {
        XCTAssertEqual(try JSONDecoder().decode(Sharpening.self, from: Data("{}".utf8)), .neutral)
    }
}
```

```swift
// Sources/RawProcessingCore/Model/Sharpening.swift
import Foundation

/// Lightroom-style sharpening (spec §3.4). Only `amount` gates identity;
/// `radius`/`detail`/`masking` matter only once sharpening is switched on.
public struct Sharpening: Codable, Equatable, Hashable, Sendable {
    public var amount: Double
    public var radius: Double
    public var detail: Double
    public var masking: Double

    public init(amount: Double = 0, radius: Double = 1.0, detail: Double = 25, masking: Double = 0) {
        self.amount = Self.clamp(amount, 0, 150)
        self.radius = Self.clamp(radius, 0.5, 3.0)
        self.detail = Self.clamp(detail, 0, 100)
        self.masking = Self.clamp(masking, 0, 100)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        guard value.isFinite else { return low > 0 ? low : 0 }
        return Swift.min(Swift.max(value, low), high)
    }

    public static let neutral = Sharpening()

    public var isIdentity: Bool { amount == 0 }

    private enum CodingKeys: String, CodingKey { case amount, radius, detail, masking }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.amount = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .amount) ?? 0, 0, 150)
        self.radius = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .radius) ?? 1.0, 0.5, 3.0)
        self.detail = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .detail) ?? 25, 0, 100)
        self.masking = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .masking) ?? 0, 0, 100)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(amount, forKey: .amount)
        try container.encode(radius, forKey: .radius)
        try container.encode(detail, forKey: .detail)
        try container.encode(masking, forKey: .masking)
    }
}
```

Run: `swift test --filter SharpeningTests` — FAIL then PASS.

- [ ] **Step 12: Write, implement and pass `NoiseReductionTests` / `NoiseReduction`**

```swift
// Tests/RawProcessingCoreTests/NoiseReductionTests.swift
import XCTest
@testable import RawProcessingCore

final class NoiseReductionTests: XCTestCase {
    func testNeutralIsLumaAndColorZeroNotLightroomDefaults() {
        // Spec §3.5: "neutral" means LumaHarbor does nothing, not "mimic
        // Lightroom's own new-photo default" (which has colorAmount = 25).
        let neutral = NoiseReduction.neutral
        XCTAssertEqual(neutral.luminanceAmount, 0)
        XCTAssertEqual(neutral.colorAmount, 0)
        XCTAssertEqual(neutral.luminanceDetail, 50)
        XCTAssertEqual(neutral.colorDetail, 50)
        XCTAssertTrue(neutral.isIdentity)
    }

    func testEitherAmountNonZeroBreaksIdentity() {
        XCTAssertFalse(NoiseReduction(luminanceAmount: 1).isIdentity)
        XCTAssertFalse(NoiseReduction(colorAmount: 1).isIdentity)
    }

    func testClampsToZeroTo100() {
        let n = NoiseReduction(luminanceAmount: 500, luminanceDetail: -5, colorAmount: 500, colorDetail: -5)
        XCTAssertEqual(n.luminanceAmount, 100)
        XCTAssertEqual(n.luminanceDetail, 0)
        XCTAssertEqual(n.colorAmount, 100)
        XCTAssertEqual(n.colorDetail, 0)
    }

    func testRoundTripsThroughJSON() throws {
        let original = NoiseReduction(luminanceAmount: 40, luminanceDetail: 60, colorAmount: 20, colorDetail: 70)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(NoiseReduction.self, from: data), original)
    }

    func testMissingKeysFallBackToNeutral() throws {
        XCTAssertEqual(try JSONDecoder().decode(NoiseReduction.self, from: Data("{}".utf8)), .neutral)
    }
}
```

```swift
// Sources/RawProcessingCore/Model/NoiseReduction.swift
import Foundation

/// Luminance and colour noise reduction (spec §3.5).
public struct NoiseReduction: Codable, Equatable, Hashable, Sendable {
    public var luminanceAmount: Double
    public var luminanceDetail: Double
    public var colorAmount: Double
    public var colorDetail: Double

    public init(
        luminanceAmount: Double = 0, luminanceDetail: Double = 50,
        colorAmount: Double = 0, colorDetail: Double = 50
    ) {
        self.luminanceAmount = Self.clamp(luminanceAmount)
        self.luminanceDetail = Self.clamp(luminanceDetail)
        self.colorAmount = Self.clamp(colorAmount)
        self.colorDetail = Self.clamp(colorDetail)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, 0), 100)
    }

    public static let neutral = NoiseReduction()

    public var isIdentity: Bool { luminanceAmount == 0 && colorAmount == 0 }

    private enum CodingKeys: String, CodingKey {
        case luminanceAmount, luminanceDetail, colorAmount, colorDetail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.luminanceAmount = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .luminanceAmount) ?? 0)
        self.luminanceDetail = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .luminanceDetail) ?? 50)
        self.colorAmount = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .colorAmount) ?? 0)
        self.colorDetail = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .colorDetail) ?? 50)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(luminanceAmount, forKey: .luminanceAmount)
        try container.encode(luminanceDetail, forKey: .luminanceDetail)
        try container.encode(colorAmount, forKey: .colorAmount)
        try container.encode(colorDetail, forKey: .colorDetail)
    }
}
```

Run: `swift test --filter NoiseReductionTests` — FAIL then PASS.

- [ ] **Step 13: Write, implement and pass `VignetteTests` / `Vignette`**

```swift
// Tests/RawProcessingCoreTests/VignetteTests.swift
import XCTest
@testable import RawProcessingCore

final class VignetteTests: XCTestCase {
    func testNeutralIsIdentity() {
        let neutral = Vignette.neutral
        XCTAssertEqual(neutral.amount, 0)
        XCTAssertEqual(neutral.midpoint, 50)
        XCTAssertEqual(neutral.roundness, 0)
        XCTAssertEqual(neutral.feather, 50)
        XCTAssertTrue(neutral.isIdentity)
    }

    func testOnlyAmountDeterminesIdentity() {
        XCTAssertTrue(Vignette(amount: 0, midpoint: 90, roundness: 80, feather: 10).isIdentity)
        XCTAssertFalse(Vignette(amount: 1).isIdentity)
        XCTAssertFalse(Vignette(amount: -1).isIdentity)
    }

    func testClampsToDocumentedRanges() {
        let v = Vignette(amount: 999, midpoint: -5, roundness: -999, feather: 999)
        XCTAssertEqual(v.amount, 100)
        XCTAssertEqual(v.midpoint, 0)
        XCTAssertEqual(v.roundness, -100)
        XCTAssertEqual(v.feather, 100)
        XCTAssertEqual(Vignette(amount: -999).amount, -100)
    }

    func testRoundTripsThroughJSON() throws {
        let original = Vignette(amount: -40, midpoint: 60, roundness: 20, feather: 70)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Vignette.self, from: data), original)
    }

    func testMissingKeysFallBackToNeutral() throws {
        XCTAssertEqual(try JSONDecoder().decode(Vignette.self, from: Data("{}".utf8)), .neutral)
    }
}
```

```swift
// Sources/RawProcessingCore/Model/Vignette.swift
import Foundation

/// Post-processing vignette (not lens-correction vignetting). Negative
/// `amount` darkens the corners, positive brightens them (spec §3.6).
public struct Vignette: Codable, Equatable, Hashable, Sendable {
    public var amount: Double
    public var midpoint: Double
    public var roundness: Double
    public var feather: Double

    public init(amount: Double = 0, midpoint: Double = 50, roundness: Double = 0, feather: Double = 50) {
        self.amount = Self.clamp(amount, -100, 100)
        self.midpoint = Self.clamp(midpoint, 0, 100)
        self.roundness = Self.clamp(roundness, -100, 100)
        self.feather = Self.clamp(feather, 0, 100)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, low), high)
    }

    public static let neutral = Vignette()

    public var isIdentity: Bool { amount == 0 }

    private enum CodingKeys: String, CodingKey { case amount, midpoint, roundness, feather }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ fallback: Double, _ low: Double, _ high: Double) throws -> Double {
            Self.clamp(try container.decodeIfPresent(Double.self, forKey: key) ?? fallback, low, high)
        }
        self.amount = try value(.amount, 0, -100, 100)
        self.midpoint = try value(.midpoint, 50, 0, 100)
        self.roundness = try value(.roundness, 0, -100, 100)
        self.feather = try value(.feather, 50, 0, 100)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(amount, forKey: .amount)
        try container.encode(midpoint, forKey: .midpoint)
        try container.encode(roundness, forKey: .roundness)
        try container.encode(feather, forKey: .feather)
    }
}
```

Run: `swift test --filter VignetteTests` — FAIL then PASS.

- [ ] **Step 14: Write, implement and pass `GrainTests` / `Grain`**

```swift
// Tests/RawProcessingCoreTests/GrainTests.swift
import XCTest
@testable import RawProcessingCore

final class GrainTests: XCTestCase {
    func testNeutralIsIdentity() {
        let neutral = Grain.neutral
        XCTAssertEqual(neutral.amount, 0)
        XCTAssertEqual(neutral.size, 25)
        XCTAssertEqual(neutral.roughness, 50)
        XCTAssertTrue(neutral.isIdentity)
    }

    func testOnlyAmountDeterminesIdentity() {
        XCTAssertTrue(Grain(amount: 0, size: 90, roughness: 90).isIdentity)
        XCTAssertFalse(Grain(amount: 1).isIdentity)
    }

    func testClampsToZeroTo100() {
        let g = Grain(amount: 500, size: -5, roughness: 500)
        XCTAssertEqual(g.amount, 100)
        XCTAssertEqual(g.size, 0)
        XCTAssertEqual(g.roughness, 100)
    }

    func testRoundTripsThroughJSON() throws {
        let original = Grain(amount: 30, size: 40, roughness: 60)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Grain.self, from: data), original)
    }

    func testMissingKeysFallBackToNeutral() throws {
        XCTAssertEqual(try JSONDecoder().decode(Grain.self, from: Data("{}".utf8)), .neutral)
    }
}
```

```swift
// Sources/RawProcessingCore/Model/Grain.swift
import Foundation

/// Simulated film grain (spec §3.7).
public struct Grain: Codable, Equatable, Hashable, Sendable {
    public var amount: Double
    public var size: Double
    public var roughness: Double

    public init(amount: Double = 0, size: Double = 25, roughness: Double = 50) {
        self.amount = Self.clamp(amount)
        self.size = Self.clamp(size)
        self.roughness = Self.clamp(roughness)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, 0), 100)
    }

    public static let neutral = Grain()

    public var isIdentity: Bool { amount == 0 }

    private enum CodingKeys: String, CodingKey { case amount, size, roughness }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.amount = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .amount) ?? 0)
        self.size = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .size) ?? 25)
        self.roughness = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .roughness) ?? 50)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(amount, forKey: .amount)
        try container.encode(size, forKey: .size)
        try container.encode(roughness, forKey: .roughness)
    }
}
```

- [ ] **Step 15: Run the whole new set together**

Run: `swift test --filter 'AdvancedToneCurveTests|HSLAdjustmentsTests|SplitToningTests|SharpeningTests|NoiseReductionTests|VignetteTests|GrainTests'`
Expected: all PASS.

- [ ] **Step 16: Build the whole package to catch any stray reference**

Run: `swift build`
Expected: exit 0.

- [ ] **Step 17: Commit**

```bash
git add Sources/RawProcessingCore/Model/ToneCurveMapping.swift \
        Sources/RawProcessingCore/Model/AdvancedToneCurve.swift \
        Sources/RawProcessingCore/Model/HSLAdjustments.swift \
        Sources/RawProcessingCore/Model/SplitToning.swift \
        Sources/RawProcessingCore/Model/Sharpening.swift \
        Sources/RawProcessingCore/Model/NoiseReduction.swift \
        Sources/RawProcessingCore/Model/Vignette.swift \
        Sources/RawProcessingCore/Model/Grain.swift \
        Tests/RawProcessingCoreTests/AdvancedToneCurveTests.swift \
        Tests/RawProcessingCoreTests/HSLAdjustmentsTests.swift \
        Tests/RawProcessingCoreTests/SplitToningTests.swift \
        Tests/RawProcessingCoreTests/SharpeningTests.swift \
        Tests/RawProcessingCoreTests/NoiseReductionTests.swift \
        Tests/RawProcessingCoreTests/VignetteTests.swift \
        Tests/RawProcessingCoreTests/GrainTests.swift
git commit -m "feat: add seven adjustment-expansion data types (spec §3, §7 item 1)"
```

---

### Task 2: Integrate into `PhotoAdjustments`, bump schema, sidecar round-trip

Spec §3 (intro), §3.8, §5, §7 item 2.

**Files:**
- Modify: `Sources/RawProcessingCore/Model/PhotoAdjustments.swift`
- Modify: `Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift:32`
- Modify: `Tests/RawProcessingCoreTests/PhotoAdjustmentsTests.swift` (fix `testEncodesEveryDocumentedKey`, add new-field tests)

**Interfaces:**
- Consumes: Task 1's seven types and their `.neutral`.
- Produces: `PhotoAdjustments.advancedToneCurve/hsl/splitToning/sharpening/noiseReduction/vignette/grain` — Task 3+ read these directly off a `PhotoAdjustments` value.

- [ ] **Step 1: Fix the now-outdated key-set test and add new-field tests**

`testEncodesEveryDocumentedKey` in `Tests/RawProcessingCoreTests/PhotoAdjustmentsTests.swift` currently asserts the JSON key set is exactly the 10 original scalar keys — that assertion will fail the moment new fields are added. Update it and add coverage for the new fields:

```swift
// Replace the existing testEncodesEveryDocumentedKey with:
func testEncodesEveryDocumentedKey() throws {
    let data = try JSONEncoder().encode(PhotoAdjustments.neutral)
    let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    XCTAssertEqual(
        Set(object.keys),
        [
            "exposure", "temperature", "tint", "contrast", "highlights",
            "shadows", "whites", "blacks", "vibrance", "saturation",
            "advancedToneCurve", "hsl", "splitToning", "sharpening",
            "noiseReduction", "vignette", "grain"
        ]
    )
}

// New tests, appended to the same file:
func testNewFieldsDefaultToNeutral() {
    let adjustments = PhotoAdjustments.neutral
    XCTAssertEqual(adjustments.advancedToneCurve, .neutral)
    XCTAssertEqual(adjustments.hsl, .neutral)
    XCTAssertEqual(adjustments.splitToning, .neutral)
    XCTAssertEqual(adjustments.sharpening, .neutral)
    XCTAssertEqual(adjustments.noiseReduction, .neutral)
    XCTAssertEqual(adjustments.vignette, .neutral)
    XCTAssertEqual(adjustments.grain, .neutral)
}

func testOldSidecarWithoutNewFieldsDecodesToNeutralExpansions() throws {
    // Exactly the old MVP sidecar shape — none of the seven new keys present.
    let json = Data(#"""
    {"exposure": 1.0, "temperature": 0, "tint": 0, "contrast": 0, "highlights": 0,
     "shadows": 0, "whites": 0, "blacks": 0, "vibrance": 0, "saturation": 0}
    """#.utf8)
    let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: json)
    XCTAssertEqual(decoded.exposure, 1.0)
    XCTAssertEqual(decoded.advancedToneCurve, .neutral)
    XCTAssertEqual(decoded.hsl, .neutral)
    XCTAssertEqual(decoded.splitToning, .neutral)
    XCTAssertEqual(decoded.sharpening, .neutral)
    XCTAssertEqual(decoded.noiseReduction, .neutral)
    XCTAssertEqual(decoded.vignette, .neutral)
    XCTAssertEqual(decoded.grain, .neutral)
}

func testRoundTripsNewFieldsThroughJSON() throws {
    var original = PhotoAdjustments.neutral
    original.sharpening = Sharpening(amount: 40)
    original.hsl.red = HSLBand(hue: 10, saturation: 20, luminance: -5)
    original.vignette = Vignette(amount: -30)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: data)
    XCTAssertEqual(decoded, original)
}
```

- [ ] **Step 2: Run to verify these fail**

Run: `swift test --filter PhotoAdjustmentsTests`
Expected: FAIL — `PhotoAdjustments` has no `advancedToneCurve`/`hsl`/etc. members yet, and the key-set assertion doesn't match.

- [ ] **Step 3: Add the seven fields to `PhotoAdjustments`**

In `Sources/RawProcessingCore/Model/PhotoAdjustments.swift`:

```swift
// Add after `public var saturation: Double` (line 18):
    public var advancedToneCurve: AdvancedToneCurve
    public var hsl: HSLAdjustments
    public var splitToning: SplitToning
    public var sharpening: Sharpening
    public var noiseReduction: NoiseReduction
    public var vignette: Vignette
    public var grain: Grain
```

```swift
// Extend the memberwise init's parameter list (line 20-31) and body (line 32-41):
    public init(
        exposure: Double = 0,
        temperature: Double = 0,
        tint: Double = 0,
        contrast: Double = 0,
        highlights: Double = 0,
        shadows: Double = 0,
        whites: Double = 0,
        blacks: Double = 0,
        vibrance: Double = 0,
        saturation: Double = 0,
        advancedToneCurve: AdvancedToneCurve = .neutral,
        hsl: HSLAdjustments = .neutral,
        splitToning: SplitToning = .neutral,
        sharpening: Sharpening = .neutral,
        noiseReduction: NoiseReduction = .neutral,
        vignette: Vignette = .neutral,
        grain: Grain = .neutral
    ) {
        self.exposure = AdjustmentCatalog.definition(for: .exposure).clamp(exposure)
        self.temperature = AdjustmentCatalog.definition(for: .temperature).clamp(temperature)
        self.tint = AdjustmentCatalog.definition(for: .tint).clamp(tint)
        self.contrast = AdjustmentCatalog.definition(for: .contrast).clamp(contrast)
        self.highlights = AdjustmentCatalog.definition(for: .highlights).clamp(highlights)
        self.shadows = AdjustmentCatalog.definition(for: .shadows).clamp(shadows)
        self.whites = AdjustmentCatalog.definition(for: .whites).clamp(whites)
        self.blacks = AdjustmentCatalog.definition(for: .blacks).clamp(blacks)
        self.vibrance = AdjustmentCatalog.definition(for: .vibrance).clamp(vibrance)
        self.saturation = AdjustmentCatalog.definition(for: .saturation).clamp(saturation)
        self.advancedToneCurve = advancedToneCurve
        self.hsl = hsl
        self.splitToning = splitToning
        self.sharpening = sharpening
        self.noiseReduction = noiseReduction
        self.vignette = vignette
        self.grain = grain
    }
```

```swift
// Extend clamped() (line 94-100) so it preserves the new fields instead of
// silently dropping them back to neutral:
    public func clamped() -> PhotoAdjustments {
        PhotoAdjustments(
            exposure: exposure, temperature: temperature, tint: tint, contrast: contrast,
            highlights: highlights, shadows: shadows, whites: whites, blacks: blacks,
            vibrance: vibrance, saturation: saturation,
            advancedToneCurve: advancedToneCurve, hsl: hsl, splitToning: splitToning,
            sharpening: sharpening, noiseReduction: noiseReduction, vignette: vignette,
            grain: grain
        )
    }
```

```swift
// Extend CodingKeys (line 111-114):
    private enum CodingKeys: String, CodingKey {
        case exposure, temperature, tint, contrast, highlights
        case shadows, whites, blacks, vibrance, saturation
        case advancedToneCurve, hsl, splitToning, sharpening, noiseReduction, vignette, grain
    }
```

```swift
// Extend init(from:) (line 119-138), after the existing `self.saturation = ...` line:
        self.advancedToneCurve = try container.decodeIfPresent(AdvancedToneCurve.self, forKey: .advancedToneCurve) ?? .neutral
        self.hsl = try container.decodeIfPresent(HSLAdjustments.self, forKey: .hsl) ?? .neutral
        self.splitToning = try container.decodeIfPresent(SplitToning.self, forKey: .splitToning) ?? .neutral
        self.sharpening = try container.decodeIfPresent(Sharpening.self, forKey: .sharpening) ?? .neutral
        self.noiseReduction = try container.decodeIfPresent(NoiseReduction.self, forKey: .noiseReduction) ?? .neutral
        self.vignette = try container.decodeIfPresent(Vignette.self, forKey: .vignette) ?? .neutral
        self.grain = try container.decodeIfPresent(Grain.self, forKey: .grain) ?? .neutral
```

```swift
// Extend encode(to:) (line 140-154), after the existing `saturation` encode line:
        try container.encode(advancedToneCurve, forKey: .advancedToneCurve)
        try container.encode(hsl, forKey: .hsl)
        try container.encode(splitToning, forKey: .splitToning)
        try container.encode(sharpening, forKey: .sharpening)
        try container.encode(noiseReduction, forKey: .noiseReduction)
        try container.encode(vignette, forKey: .vignette)
        try container.encode(grain, forKey: .grain)
```

Leave `isNeutral`, `subscript(kind:)`, `resetting`, `setting`, `modifiedKinds` untouched — per spec §3.8 they intentionally stay scoped to the 10-slider `AdjustmentKind` surface; `isNeutral`'s `self == .neutral` picks up the new fields automatically via synthesized `Equatable`.

- [ ] **Step 4: Bump the sidecar schema version**

In `Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift:32`:

```swift
    public static let currentSchemaVersion = 2
```

- [ ] **Step 5: Run to verify everything passes**

Run: `swift test --filter PhotoAdjustmentsTests`
Expected: PASS.

Run: `swift test --filter SidecarRepositoryTests`
Expected: PASS — this exercises the "reject a sidecar from a newer schema" path generically; no new test needed here per spec §5.

- [ ] **Step 6: Full build + full test suite**

Run: `swift build && swift test`
Expected: exit 0, no failures, no regressions elsewhere (e.g. `AdjustmentPipelineTests`, `LibraryLifecycleTests` should be unaffected since they only touch the 10 original fields).

- [ ] **Step 7: Commit**

```bash
git add Sources/RawProcessingCore/Model/PhotoAdjustments.swift \
        Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift \
        Tests/RawProcessingCoreTests/PhotoAdjustmentsTests.swift
git commit -m "feat: integrate expansion fields into PhotoAdjustments, bump sidecar schema to 2 (spec §3, §5, §7 item 2)"
```

---

### Task 3: Sharpening, noise reduction, vignette (built-in `CIFilter`s)

Spec §4.2 steps 8–10, §7 item 3. Lowest-risk rendering task — all three use system `CIFilter`s, no custom kernels.

**Files:**
- Modify: `Sources/RawProcessingCore/Model/AdjustmentMapping.swift`
- Modify: `Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift`
- Modify: `Tests/RawProcessingCoreTests/AdjustmentMappingTests.swift`
- Modify: `Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift`

**Interfaces:**
- Consumes: `PhotoAdjustments.sharpening/noiseReduction/vignette` (Task 2).
- Produces: `RenderParameters.sharpening/noiseReduction/vignette: Sharpening/NoiseReduction/Vignette` (the clamped struct itself, not re-decomposed values — later tasks and the pipeline read these directly) and `RenderParameters.isSharpeningIdentity/isNoiseReductionIdentity/isVignetteIdentity: Bool`.

- [ ] **Step 1: Write the failing mapping tests**

Append to `Tests/RawProcessingCoreTests/AdjustmentMappingTests.swift`:

```swift
    func testNeutralIncludesTheNewIdentityFlags() {
        let parameters = AdjustmentMapping.renderParameters(for: .neutral)
        XCTAssertTrue(parameters.isSharpeningIdentity)
        XCTAssertTrue(parameters.isNoiseReductionIdentity)
        XCTAssertTrue(parameters.isVignetteIdentity)
    }

    func testSharpeningIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.sharpening = Sharpening(amount: 60, radius: 1.5, detail: 40, masking: 10)
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.sharpening, adjustments.sharpening)
        XCTAssertFalse(parameters.isSharpeningIdentity)
    }

    func testNoiseReductionIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.noiseReduction = NoiseReduction(luminanceAmount: 30, colorAmount: 20)
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.noiseReduction, adjustments.noiseReduction)
        XCTAssertFalse(parameters.isNoiseReductionIdentity)
    }

    func testVignetteIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.vignette = Vignette(amount: -40, midpoint: 60, roundness: 10, feather: 70)
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.vignette, adjustments.vignette)
        XCTAssertFalse(parameters.isVignetteIdentity)
    }
```

- [ ] **Step 2: Run to verify these fail**

Run: `swift test --filter AdjustmentMappingTests`
Expected: FAIL — `RenderParameters` has no `sharpening`/`noiseReduction`/`vignette` members yet.

- [ ] **Step 3: Extend `RenderParameters` and `AdjustmentMapping`**

In `Sources/RawProcessingCore/Model/AdjustmentMapping.swift`, add to `RenderParameters` (after `public let toneCurve: [ToneCurvePoint]`, line 21):

```swift
    public let sharpening: Sharpening
    public let noiseReduction: NoiseReduction
    public let vignette: Vignette
```

Add to the identity flags block (after `public var isExposureIdentity: Bool { exposureEV == 0 }`, line 35):

```swift
    public var isSharpeningIdentity: Bool { sharpening.isIdentity }
    public var isNoiseReductionIdentity: Bool { noiseReduction.isIdentity }
    public var isVignetteIdentity: Bool { vignette.isIdentity }
```

Extend `renderParameters(for:)` (line 57-68), adding to the returned `RenderParameters(...)`:

```swift
    public static func renderParameters(for adjustments: PhotoAdjustments) -> RenderParameters {
        let clamped = adjustments.clamped()
        return RenderParameters(
            exposureEV: clamped.exposure,
            temperatureOffsetKelvin: clamped.temperature * kelvinPerTemperatureUnit,
            tintOffset: clamped.tint * tintPerUnit,
            contrast: 1 + (clamped.contrast / 100) * contrastSpan,
            saturation: 1 + (clamped.saturation / 100) * saturationSpan,
            vibrance: (clamped.vibrance / 100) * vibranceSpan,
            toneCurve: ToneCurveMapping.controlPoints(for: clamped),
            sharpening: clamped.sharpening,
            noiseReduction: clamped.noiseReduction,
            vignette: clamped.vignette
        )
    }
```

Add three mapping constants near the top of the `AdjustmentMapping` enum (after `public static let vibranceSpan = 1.0`, line 55) — these are the "one place slider units become Core Image units" for the new stages, same status as the existing constants:

```swift
    /// `CISharpenLuminance.inputSharpness` span. Amount 0...150 maps to
    /// sharpness 0...3.0; radius passes straight through (spec's radius range
    /// 0.5...3.0 already matches the filter's own expected units).
    public static let sharpenLuminanceSharpnessSpan = 3.0 / 150.0
    /// `CINoiseReduction` exposes exactly two knobs (`inputNoiseLevel`,
    /// `inputSharpness`), not independent luminance/colour controls. Amount is
    /// the average of the two Lightroom-style amounts, mapped to a noise level
    /// span Apple's own filter treats as strong (its own default is 0.02).
    public static let noiseReductionNoiseLevelSpan = 0.1 / 100.0
    public static let noiseReductionSharpnessSpan = 2.0 / 100.0
```

- [ ] **Step 4: Run to verify mapping tests pass**

Run: `swift test --filter AdjustmentMappingTests`
Expected: PASS.

- [ ] **Step 5: Write the failing pipeline tests**

Append to `Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift` (inside the `AdjustmentPipelineTests` class, before the closing brace on line 191):

```swift
    // MARK: - Sharpening / noise reduction / vignette

    func testNeutralSharpeningNoiseVignetteStaysAPassthrough() {
        let source = makeSourceImage()
        let output = pipeline.apply(PhotoAdjustments.neutral, to: source)
        XCTAssertTrue(output === source)
    }

    func testSharpeningAddsAFilterToTheChainWhenNonZero() {
        let source = makeSourceImage()
        var adjustments = PhotoAdjustments.neutral
        adjustments.sharpening = Sharpening(amount: 80)
        let output = pipeline.apply(adjustments, to: source)
        XCTAssertFalse(output === source)
        XCTAssertEqual(output.extent, source.extent)
    }

    func testNoiseReductionAddsAFilterToTheChainWhenNonZero() {
        let source = makeSourceImage()
        var adjustments = PhotoAdjustments.neutral
        adjustments.noiseReduction = NoiseReduction(luminanceAmount: 50)
        let output = pipeline.apply(adjustments, to: source)
        XCTAssertFalse(output === source)
        XCTAssertEqual(output.extent, source.extent)
    }

    func testNegativeVignetteDarkensTheCorner() throws {
        let source = makeSourceImage(red: 0.5, green: 0.5, blue: 0.5)
        var adjustments = PhotoAdjustments.neutral
        adjustments.vignette = Vignette(amount: -100, midpoint: 30, roundness: 0, feather: 50)
        let output = pipeline.apply(adjustments, to: source)
        let renderer = ImageRenderService()
        let cgImage = try renderer.makeCGImage(output)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Sample the top-left corner pixel of the 16x16 fixture.
        context.draw(cgImage, in: CGRect(x: -Int(size.width) + 1, y: 0, width: Int(size.width), height: Int(size.height)))
        let cornerRed = Int(bytes[0])
        let centre = try centrePixel(output)
        XCTAssertLessThan(cornerRed, centre.red, "A negative-amount vignette should darken the corner relative to the centre")
    }

    func testPositiveVignetteBrightensTheCorner() throws {
        let source = makeSourceImage(red: 0.5, green: 0.5, blue: 0.5)
        var adjustments = PhotoAdjustments.neutral
        adjustments.vignette = Vignette(amount: 100, midpoint: 30, roundness: 0, feather: 50)
        let output = pipeline.apply(adjustments, to: source)
        let renderer = ImageRenderService()
        let cgImage = try renderer.makeCGImage(output)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: -Int(size.width) + 1, y: 0, width: Int(size.width), height: Int(size.height)))
        let cornerRed = Int(bytes[0])
        let centre = try centrePixel(output)
        XCTAssertGreaterThan(cornerRed, centre.red, "A positive-amount vignette should brighten the corner relative to the centre")
    }
```

- [ ] **Step 6: Run to verify these fail**

Run: `swift test --filter AdjustmentPipelineTests`
Expected: FAIL — new stages don't exist in `apply` yet, so sharpening/noise-reduction images are still `===` passthrough and vignette does nothing.

- [ ] **Step 7: Implement the three pipeline stages**

In `Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift`, insert after the existing perceptual-stage block closes (after step 6 "Back to linear", i.e. after line 77 `working = toLinear.outputImage ?? working` and its closing `}`), still inside `apply(_:to:)`:

```swift
        // 8. Sharpening (spec §4.2 step 8) — a post-colour detail effect, so it
        // runs after the perceptual stage and its own linear round-trip, not
        // inside it.
        if !parameters.isSharpeningIdentity {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = working
            filter.sharpness = Float(parameters.sharpening.amount * AdjustmentMapping.sharpenLuminanceSharpnessSpan)
            filter.radius = Float(parameters.sharpening.radius)
            working = filter.outputImage ?? working
        }

        // 9. Noise reduction (spec §4.2 step 9). CINoiseReduction exposes one
        // noise-level knob and one sharpness knob, not independent
        // luminance/colour controls, so both amounts are averaged into the
        // former and both detail values into the latter (see the span
        // constants' doc comments in AdjustmentMapping).
        if !parameters.isNoiseReductionIdentity {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = working
            let averageAmount = (parameters.noiseReduction.luminanceAmount + parameters.noiseReduction.colorAmount) / 2
            let averageDetail = (parameters.noiseReduction.luminanceDetail + parameters.noiseReduction.colorDetail) / 2
            filter.noiseLevel = Float(averageAmount * AdjustmentMapping.noiseReductionNoiseLevelSpan)
            filter.sharpness = Float(averageDetail * AdjustmentMapping.noiseReductionSharpnessSpan)
            working = filter.outputImage ?? working
        }

        // 10. Vignette (spec §4.2 step 10). Built with an explicit radial-alpha
        // composite rather than CIVignette/CIVignetteEffect because both only
        // ever darken; this adjustment is bidirectional (spec §3.6: negative
        // darkens, positive brightens).
        if !parameters.isVignetteIdentity {
            working = Self.applyVignette(parameters.vignette, to: working)
        }

        return working
    }

    private static func applyVignette(_ vignette: Vignette, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let centre = CGPoint(x: extent.midX, y: extent.midY)
        let halfDiagonal = (extent.width * extent.width + extent.height * extent.height).squareRoot() / 2

        // midpoint 0...100 -> inner radius 0...halfDiagonal (where the effect
        // starts); feather 0...100 -> how far past the inner radius it takes to
        // reach full strength. roundness biases the gradient toward a circle
        // (positive) or the image's own aspect ratio (negative) by scaling the
        // gradient anisotropically before compositing -- a first-pass
        // approximation flagged for manual visual confirmation (spec §6, this
        // plan's Task 8).
        let innerRadius = (vignette.midpoint / 100) * halfDiagonal
        let featherDistance = max((vignette.feather / 100) * halfDiagonal, 1)
        let outerRadius = innerRadius + featherDistance

        let gradient = CIFilter.radialGradient()
        gradient.center = centre
        gradient.radius0 = Float(innerRadius)
        gradient.radius1 = Float(outerRadius)
        let brightening = vignette.amount > 0
        let tintAlpha = Float(abs(vignette.amount) / 100)
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        gradient.color1 = brightening
            ? CIColor(red: 1, green: 1, blue: 1, alpha: tintAlpha)
            : CIColor(red: 0, green: 0, blue: 0, alpha: tintAlpha)
        guard var mask = gradient.outputImage else { return image }

        if vignette.roundness != 0 {
            // Scale the gradient about the image centre before cropping: a
            // positive roundness compresses it toward a circle on the longer
            // axis, negative stretches it to hug the frame's own aspect ratio.
            let aspect = extent.width / extent.height
            let bias = vignette.roundness / 100
            let scaleX = aspect >= 1 ? 1 - bias * (1 - 1 / aspect) : 1
            let scaleY = aspect < 1 ? 1 - bias * (1 - aspect) : 1
            let toOrigin = CGAffineTransform(translationX: -centre.x, y: -centre.y)
            let scale = CGAffineTransform(scaleX: scaleX, y: scaleY)
            let backToCentre = CGAffineTransform(translationX: centre.x, y: centre.y)
            mask = mask.transformed(by: toOrigin.concatenating(scale).concatenating(backToCentre))
        }

        let composite = CIFilter.sourceOverCompositing()
        composite.inputImage = mask.cropped(to: extent)
        composite.backgroundImage = image
        return composite.outputImage ?? image
    }
```

Note the closing `}` that was previously right after the perceptual-stage `if needsPerceptualStage { ... }` block (old line 77-78) moves — the new stages 8-10 sit between that block's end and the function's final `return working`. Re-read the file after editing to confirm brace balance before running tests.

- [ ] **Step 8: Run to verify pipeline tests pass**

Run: `swift test --filter AdjustmentPipelineTests`
Expected: PASS.

- [ ] **Step 9: Full build + full test suite**

Run: `swift build && swift test`
Expected: exit 0, no regressions.

- [ ] **Step 10: Commit**

```bash
git add Sources/RawProcessingCore/Model/AdjustmentMapping.swift \
        Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift \
        Tests/RawProcessingCoreTests/AdjustmentMappingTests.swift \
        Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift
git commit -m "feat: wire sharpening, noise reduction and vignette into the render pipeline (spec §4.2 steps 8-10, §7 item 3)"
```

---

### Task 4: Grain

Spec §4.2 step 11, §7 item 4.

**Files:**
- Modify: `Sources/RawProcessingCore/Model/AdjustmentMapping.swift`
- Modify: `Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift`
- Modify: `Tests/RawProcessingCoreTests/AdjustmentMappingTests.swift`
- Modify: `Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift`

**Interfaces:**
- Consumes: `PhotoAdjustments.grain` (Task 2), pipeline insertion point after Task 3's vignette stage.
- Produces: `RenderParameters.grain: Grain`, `RenderParameters.isGrainIdentity: Bool`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/RawProcessingCoreTests/AdjustmentMappingTests.swift`:

```swift
    func testGrainIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.grain = Grain(amount: 25, size: 60, roughness: 40)
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.grain, adjustments.grain)
        XCTAssertFalse(parameters.isGrainIdentity)
    }

    func testNeutralGrainIsIdentity() {
        XCTAssertTrue(AdjustmentMapping.renderParameters(for: .neutral).isGrainIdentity)
    }
```

Append to `Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift`:

```swift
    // MARK: - Grain

    func testNeutralGrainStaysAPassthrough() {
        let source = makeSourceImage()
        XCTAssertTrue(pipeline.apply(PhotoAdjustments.neutral, to: source) === source)
    }

    func testGrainAddsVisibleNoiseAndPreservesExtent() throws {
        // A flat mid-grey source with grain applied must stop being perfectly
        // flat -- neighbouring pixels should diverge -- while the canvas size
        // is untouched.
        let source = makeSourceImage(red: 0.5, green: 0.5, blue: 0.5)
        var adjustments = PhotoAdjustments.neutral
        adjustments.grain = Grain(amount: 100, size: 25, roughness: 50)
        let output = pipeline.apply(adjustments, to: source)
        XCTAssertEqual(output.extent, source.extent)

        let renderer = ImageRenderService()
        let cgImage = try renderer.makeCGImage(output)
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let firstPixelRed = bytes[0]
        let anyPixelDiffers = stride(from: 0, to: bytes.count, by: 4).contains { bytes[$0] != firstPixelRed }
        XCTAssertTrue(anyPixelDiffers, "Grain at full amount on a flat source must not render perfectly flat")
    }
```

- [ ] **Step 2: Run to verify these fail**

Run: `swift test --filter 'AdjustmentMappingTests|AdjustmentPipelineTests'`
Expected: FAIL.

- [ ] **Step 3: Extend `RenderParameters`/`AdjustmentMapping`**

In `Sources/RawProcessingCore/Model/AdjustmentMapping.swift`, add to `RenderParameters` (alongside the Task 3 fields):

```swift
    public let grain: Grain
```

```swift
    public var isGrainIdentity: Bool { grain.isIdentity }
```

Add `grain: clamped.grain` to the `RenderParameters(...)` construction in `renderParameters(for:)`.

- [ ] **Step 4: Implement the grain stage**

In `Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift`, after the vignette stage from Task 3, before `return working`:

```swift
        // 11. Grain (spec §4.2 step 11) — synthetic per-pixel luminance noise,
        // generated once at the image's own extent and blended in proportion
        // to amount. size / roughness shape the noise before blending: size
        // widens the grain (blur radius scales up), roughness controls how
        // much of a soft-light vs. straight-overlay blend is used (a rougher
        // grain reads grittier at high blend contribution).
        if !parameters.isGrainIdentity {
            working = Self.applyGrain(parameters.grain, to: working)
        }

        return working
    }

    private static func applyGrain(_ grain: Grain, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let noise = CIFilter.randomGenerator()
        guard var noiseImage = noise.outputImage else { return image }

        // size 0...100 -> blur radius 0...4; identical noise blurred more
        // reads as larger grain clumps.
        let blurRadius = (grain.size / 100) * 4
        if blurRadius > 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = noiseImage
            blur.radius = Float(blurRadius)
            noiseImage = blur.outputImage ?? noiseImage
        }

        // Recentre the (0...1 per channel, high-frequency) random noise around
        // 0.5 grey and scale its deviation by amount and roughness, so it can
        // be composited as a soft-light layer that leaves flat mid-tones
        // mostly alone and roughens texture elsewhere.
        let amountScale = (grain.amount / 100) * (0.15 + (grain.roughness / 100) * 0.25)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = noiseImage
        let vector = CIVector(x: CGFloat(amountScale), y: 0, z: 0, w: 0)
        matrix.rVector = vector
        matrix.gVector = vector
        matrix.bVector = vector
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.biasVector = CIVector(x: 0.5, y: 0.5, z: 0.5, w: 1)
        guard let scaledNoise = matrix.outputImage else { return image }

        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = scaledNoise.cropped(to: extent)
        blend.backgroundImage = image
        return blend.outputImage ?? image
    }
```

- [ ] **Step 5: Run to verify tests pass**

Run: `swift test --filter 'AdjustmentMappingTests|AdjustmentPipelineTests'`
Expected: PASS.

- [ ] **Step 6: Full build + full test suite**

Run: `swift build && swift test`
Expected: exit 0.

- [ ] **Step 7: Commit**

```bash
git add Sources/RawProcessingCore/Model/AdjustmentMapping.swift \
        Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift \
        Tests/RawProcessingCoreTests/AdjustmentMappingTests.swift \
        Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift
git commit -m "feat: wire film grain into the render pipeline (spec §4.2 step 11, §7 item 4)"
```

---

### Task 5: Split toning

Spec §4.2 step 7, §7 item 5. Inserted **before** "back to linear" (i.e. inside the perceptual stage, after HSL in Task 7's slot — see note below on task ordering).

> **Ordering note:** spec §7 lists split toning (item 5) before advanced curve/HSL (items 6-7) by risk, but spec §4.2's pipeline position has split toning *after* HSL (step 7 comes after step 6). Implementing split toning's pipeline wiring now, ahead of Tasks 6-7, means inserting it into the perceptual-stage block at the position "immediately before the back-to-linear conversion" and leaving a clear seam for Tasks 6-7 to insert steps 5.5 and 6 *before* it. This task adds that seam explicitly (a `// MARK` comment) so Tasks 6-7 have an unambiguous insertion point.

**Files:**
- Modify: `Sources/RawProcessingCore/Model/AdjustmentMapping.swift`
- Modify: `Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift`
- Modify: `Tests/RawProcessingCoreTests/AdjustmentMappingTests.swift`
- Modify: `Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift`

**Interfaces:**
- Consumes: `PhotoAdjustments.splitToning` (Task 2).
- Produces: `RenderParameters.splitToning: SplitToning`, `RenderParameters.isSplitToningIdentity: Bool`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/RawProcessingCoreTests/AdjustmentMappingTests.swift`:

```swift
    func testSplitToningIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.splitToning = SplitToning(shadowHue: 210, shadowSaturation: 30, highlightHue: 45, highlightSaturation: 20, balance: 0)
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.splitToning, adjustments.splitToning)
        XCTAssertFalse(parameters.isSplitToningIdentity)
    }

    func testNeutralSplitToningIsIdentity() {
        XCTAssertTrue(AdjustmentMapping.renderParameters(for: .neutral).isSplitToningIdentity)
    }
```

Append to `Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift`:

```swift
    // MARK: - Split toning

    func testNeutralSplitToningStaysAPassthrough() {
        let source = makeSourceImage()
        XCTAssertTrue(pipeline.apply(PhotoAdjustments.neutral, to: source) === source)
    }

    func testShadowTintShiftsADarkPixelTowardTheShadowHue() throws {
        // A blue shadow tint (hue 240) on a dark-grey patch should push blue
        // above red at the pixel level.
        let darkComponent = linearComponent(fromPerceptual: 0.2)
        let dark = makeSourceImage(red: darkComponent, green: darkComponent, blue: darkComponent)
        var adjustments = PhotoAdjustments.neutral
        adjustments.splitToning = SplitToning(shadowHue: 240, shadowSaturation: 80, highlightHue: 0, highlightSaturation: 0, balance: 0)
        let tinted = try centrePixel(pipeline.apply(adjustments, to: dark))
        XCTAssertGreaterThan(tinted.blue, tinted.red, "A blue shadow tint should leave blue above red in a dark patch")
    }

    func testHighlightTintShiftsABrightPixelTowardTheHighlightHue() throws {
        let brightComponent = linearComponent(fromPerceptual: 0.8)
        let bright = makeSourceImage(red: brightComponent, green: brightComponent, blue: brightComponent)
        var adjustments = PhotoAdjustments.neutral
        adjustments.splitToning = SplitToning(shadowHue: 0, shadowSaturation: 0, highlightHue: 30, highlightSaturation: 80, balance: 0)
        let tinted = try centrePixel(pipeline.apply(adjustments, to: bright))
        XCTAssertGreaterThan(tinted.red, tinted.blue, "An orange (hue 30) highlight tint should leave red above blue in a bright patch")
    }
```

- [ ] **Step 2: Run to verify these fail**

Run: `swift test --filter 'AdjustmentMappingTests|AdjustmentPipelineTests'`
Expected: FAIL.

- [ ] **Step 3: Extend `RenderParameters`/`AdjustmentMapping`**

Add `public let splitToning: SplitToning` to `RenderParameters`, `public var isSplitToningIdentity: Bool { splitToning.isIdentity }`, and `splitToning: clamped.splitToning` to the constructor call — same pattern as Tasks 3-4.

- [ ] **Step 4: Implement the split-toning stage**

In `Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift`, inside the `needsPerceptualStage` block (the `if needsPerceptualStage { ... }` from the original file), immediately before the existing step 6 comment `// 6. Back to linear...` (originally line 72), insert:

```swift
            // MARK: - Insertion seam for Task 6 (advanced curve, step 5.5) and
            // Task 7 (HSL, step 6) — both belong here, before split toning.

            // 7. Split toning (spec §4.2 step 7): tint shadows and highlights
            // independently using a luminance mask to blend two flat colour
            // layers, weighted by `balance`.
            if !parameters.isSplitToningIdentity {
                working = Self.applySplitToning(parameters.splitToning, to: working)
            }

```

(This sits before the existing `// 6. Back to linear...` block, which stays last in the perceptual stage as already numbered — do not renumber the existing comments; the spec's step numbers describe pipeline *position*, not comment order in this file.)

Add the implementation as a new private static method on `AdjustmentPipeline`:

```swift
    private static func applySplitToning(_ splitToning: SplitToning, to image: CIImage) -> CIImage {
        let extent = image.extent

        func flatColor(hue: Double, saturation: Double) -> CIImage {
            let color = CIColor(
                color: NSColor(
                    hue: hue / 360, saturation: saturation / 100, brightness: 0.5, alpha: 1
                )
            )
            return CIImage(color: color).cropped(to: extent)
        }

        let shadowColor = flatColor(hue: splitToning.shadowHue, saturation: splitToning.shadowSaturation)
        let highlightColor = flatColor(hue: splitToning.highlightHue, saturation: splitToning.highlightSaturation)

        // Luminance mask: 0 at black, 1 at white, biased by balance (positive
        // balance shrinks the shadow range so highlights dominate more of the
        // midtones, and vice versa) -- CIMaskToAlpha-style use of the source
        // image's own luminance via CIColorMatrix collapsing to grey, offset
        // by balance/200 before use as a blend mask.
        let luminanceMask = CIFilter.colorMatrix()
        luminanceMask.inputImage = image
        let lumaVector = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        luminanceMask.rVector = lumaVector
        luminanceMask.gVector = lumaVector
        luminanceMask.bVector = lumaVector
        luminanceMask.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        luminanceMask.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        let balanceOffset = splitToning.balance / 200
        let biasedMask = CIFilter.colorMatrix()
        biasedMask.inputImage = luminanceMask.outputImage
        biasedMask.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        biasedMask.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        biasedMask.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        biasedMask.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        biasedMask.biasVector = CIVector(x: CGFloat(balanceOffset), y: CGFloat(balanceOffset), z: CGFloat(balanceOffset), w: 0)
        guard let mask = biasedMask.outputImage else { return image }

        let shadowsBlend = CIFilter.blendWithMask()
        shadowsBlend.inputImage = shadowColor
        shadowsBlend.backgroundImage = image
        shadowsBlend.maskImage = mask.applyingFilter("CIColorInvert")
        guard let withShadows = shadowsBlend.outputImage else { return image }

        let highlightsBlend = CIFilter.blendWithMask()
        highlightsBlend.inputImage = highlightColor
        highlightsBlend.backgroundImage = withShadows
        highlightsBlend.maskImage = mask
        guard let withHighlights = highlightsBlend.outputImage else { return withShadows }

        // The flat tint layers are opaque colour, so blending them straight in
        // would flatten contrast entirely; soft-light keeps the underlying
        // luminance structure while still shifting hue, matching how
        // Lightroom's split toning reads.
        let softLight = CIFilter.softLightBlendMode()
        softLight.inputImage = withHighlights
        softLight.backgroundImage = image
        return softLight.outputImage?.cropped(to: extent) ?? image
    }
```

Add `import AppKit` to the top of `Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift` for `NSColor` (macOS-only target, matches the rest of the app — check `CoreImageRawDecoder.swift` for the existing `import AppKit`/`import CoreGraphics` convention in this module and match it).

- [ ] **Step 5: Run to verify tests pass**

Run: `swift test --filter 'AdjustmentMappingTests|AdjustmentPipelineTests'`
Expected: PASS. If the hue-direction assertions (`testShadowTintShiftsADarkPixelTowardTheShadowHue`/highlight equivalent) fail, the soft-light blend or mask direction is inverted — check `maskImage` polarity on the two `blendWithMask` calls before touching the hue math; this is the most likely mechanical mistake, not a wrong formula.

- [ ] **Step 6: Full build + full test suite**

Run: `swift build && swift test`
Expected: exit 0.

- [ ] **Step 7: Commit**

```bash
git add Sources/RawProcessingCore/Model/AdjustmentMapping.swift \
        Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift \
        Tests/RawProcessingCoreTests/AdjustmentMappingTests.swift \
        Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift
git commit -m "feat: wire split toning into the render pipeline (spec §4.2 step 7, §7 item 5)"
```

---

### Task 6: Advanced tone curve (custom `CIColorKernel`, CPU LUT)

Spec §3.1, §4.2 step 5.5, §4.3, §7 item 6. Split into a fully unit-testable CPU half (LUT interpolation) and a GPU half that only manual visual verification (Task 8) can confirm — per spec §4.3, this is expected: "GPU 端查表 kernel 本身無法單元測試,需要人工視覺驗證。"

**Files:**
- Create: `Sources/RawProcessingCore/Pipeline/AdvancedToneCurveLUT.swift`
- Modify: `Sources/RawProcessingCore/Model/AdjustmentMapping.swift`
- Modify: `Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift`
- Test: `Tests/RawProcessingCoreTests/AdvancedToneCurveLUTTests.swift`
- Modify: `Tests/RawProcessingCoreTests/AdjustmentMappingTests.swift`
- Modify: `Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift`

**Interfaces:**
- Consumes: `PhotoAdjustments.advancedToneCurve` (Task 2), `AdvancedToneCurve.points: [ToneCurvePoint]` (Task 1).
- Produces: `AdvancedToneCurveLUT.build(from: [ToneCurvePoint], resolution: Int = 256) -> [Float]` (256 values, 0...1, monotonic non-decreasing) — pure function, the only piece of this task that's meaningfully unit-tested. `RenderParameters.advancedToneCurve: AdvancedToneCurve`, `RenderParameters.isAdvancedToneCurveIdentity: Bool`.

- [ ] **Step 1: Write the failing LUT tests**

```swift
// Tests/RawProcessingCoreTests/AdvancedToneCurveLUTTests.swift
import XCTest
@testable import RawProcessingCore

final class AdvancedToneCurveLUTTests: XCTestCase {
    func testEmptyPointsProducesIdentityLUT() {
        let lut = AdvancedToneCurveLUT.build(from: [], resolution: 256)
        XCTAssertEqual(lut.count, 256)
        XCTAssertEqual(lut.first!, 0, accuracy: 1e-6)
        XCTAssertEqual(lut.last!, 1, accuracy: 1e-6)
        // Identity: value at index i is approximately i / 255.
        for i in stride(from: 0, to: 256, by: 32) {
            XCTAssertEqual(lut[i], Float(i) / 255, accuracy: 1e-6)
        }
    }

    func testKnownControlPointsProduceKnownOutput() {
        // A curve that maps 0->0, 0.5->0.25, 1->1: sampling at the midpoint
        // index should land near 0.25, not the identity's 0.5.
        let points = [
            ToneCurvePoint(x: 0, y: 0),
            ToneCurvePoint(x: 0.5, y: 0.25),
            ToneCurvePoint(x: 1, y: 1)
        ]
        let lut = AdvancedToneCurveLUT.build(from: points, resolution: 256)
        let midIndex = 127 // ~0.5 at 256 resolution
        XCTAssertEqual(lut[midIndex], 0.25, accuracy: 0.02)
    }

    func testSinglePointProducesAFlatLUTAtThatValue() {
        // Degenerate input (a "curve" with one point) can't interpolate --
        // must degrade to a constant rather than crash or extrapolate wildly.
        let lut = AdvancedToneCurveLUT.build(from: [ToneCurvePoint(x: 0.5, y: 0.7)], resolution: 256)
        XCTAssertTrue(lut.allSatisfy { abs($0 - 0.7) < 1e-6 })
    }

    func testOutputIsMonotonicNonDecreasing() {
        // Hostile input: y values that go backwards. The LUT must still come
        // out non-decreasing, or the render solarises (same risk documented
        // on ToneCurveMapping.enforceMonotonicOutput).
        let points = [
            ToneCurvePoint(x: 0, y: 0.5),
            ToneCurvePoint(x: 0.3, y: 0.1),
            ToneCurvePoint(x: 0.7, y: 0.9),
            ToneCurvePoint(x: 1, y: 0.6)
        ]
        let lut = AdvancedToneCurveLUT.build(from: points, resolution: 256)
        for i in 1..<lut.count {
            XCTAssertGreaterThanOrEqual(lut[i], lut[i - 1], "LUT must be non-decreasing at index \(i)")
        }
    }

    func testOutputIsClampedToZeroOne() {
        let points = [ToneCurvePoint(x: 0, y: -5), ToneCurvePoint(x: 1, y: 5)]
        let lut = AdvancedToneCurveLUT.build(from: points, resolution: 256)
        XCTAssertTrue(lut.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    func testResolutionControlsOutputCount() {
        XCTAssertEqual(AdvancedToneCurveLUT.build(from: [], resolution: 64).count, 64)
    }
}
```

- [ ] **Step 2: Run to verify these fail**

Run: `swift test --filter AdvancedToneCurveLUTTests`
Expected: FAIL — `AdvancedToneCurveLUT` doesn't exist yet.

- [ ] **Step 3: Implement `AdvancedToneCurveLUT`**

```swift
// Sources/RawProcessingCore/Pipeline/AdvancedToneCurveLUT.swift
import Foundation

/// Turns an arbitrary-length control-point curve into a fixed-resolution
/// lookup table, so `CIColorKernel` can do a flat per-pixel table lookup
/// instead of evaluating a spline on the GPU (spec §4.3).
///
/// Pure Swift, no Core Image — this is the part of Task 6 that is actually
/// unit-testable; the kernel that samples this table on the GPU is not
/// (verified manually instead, spec §6).
public enum AdvancedToneCurveLUT {
    /// - Parameters:
    ///   - points: Normalised 0...1 control points. Does not need to arrive
    ///     sorted or monotonic in y -- both are enforced here so a hostile or
    ///     malformed style file can't solarise the render (same risk as
    ///     `ToneCurveMapping.enforceMonotonicOutput`).
    ///   - resolution: Number of samples in the returned table.
    public static func build(from points: [ToneCurvePoint], resolution: Int = 256) -> [Float] {
        guard resolution > 0 else { return [] }
        guard !points.isEmpty else {
            return (0..<resolution).map { Float($0) / Float(resolution - 1) }
        }
        guard points.count > 1 else {
            let value = Float(clamp01(points[0].y))
            return Array(repeating: value, count: resolution)
        }

        let sorted = points.sorted { $0.x < $1.x }
        var table = [Float](repeating: 0, count: resolution)
        for i in 0..<resolution {
            let x = Double(i) / Double(resolution - 1)
            table[i] = Float(clamp01(interpolate(x, in: sorted)))
        }
        return enforceMonotonicNonDecreasing(table)
    }

    private static func interpolate(_ x: Double, in points: [ToneCurvePoint]) -> Double {
        if x <= points.first!.x { return points.first!.y }
        if x >= points.last!.x { return points.last!.y }
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            guard x <= current.x else { continue }
            let span = current.x - previous.x
            guard span > 0 else { return current.y }
            let t = (x - previous.x) / span
            return previous.y + t * (current.y - previous.y)
        }
        return points.last!.y
    }

    private static func enforceMonotonicNonDecreasing(_ table: [Float]) -> [Float] {
        var result = table
        for i in 1..<result.count {
            result[i] = max(result[i], result[i - 1])
        }
        return result
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
```

- [ ] **Step 4: Run to verify LUT tests pass**

Run: `swift test --filter AdvancedToneCurveLUTTests`
Expected: PASS.

- [ ] **Step 5: Write the failing mapping + pipeline tests**

Append to `Tests/RawProcessingCoreTests/AdjustmentMappingTests.swift`:

```swift
    func testAdvancedToneCurveIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.advancedToneCurve = AdvancedToneCurve(points: [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)])
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.advancedToneCurve, adjustments.advancedToneCurve)
        XCTAssertFalse(parameters.isAdvancedToneCurveIdentity)
    }

    func testNeutralAdvancedToneCurveIsIdentity() {
        XCTAssertTrue(AdjustmentMapping.renderParameters(for: .neutral).isAdvancedToneCurveIdentity)
    }
```

Append to `Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift`:

```swift
    // MARK: - Advanced tone curve

    func testNeutralAdvancedCurveStaysAPassthrough() {
        let source = makeSourceImage()
        XCTAssertTrue(pipeline.apply(PhotoAdjustments.neutral, to: source) === source)
    }

    func testAdvancedCurveDarkeningPointsDarkenTheImage() throws {
        let source = makeSourceImage(red: 0.5, green: 0.5, blue: 0.5)
        let base = try centrePixel(source)
        var adjustments = PhotoAdjustments.neutral
        adjustments.advancedToneCurve = AdvancedToneCurve(points: [
            ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 0.5)
        ])
        let darkened = try centrePixel(pipeline.apply(adjustments, to: source))
        XCTAssertLessThan(darkened.red, base.red)
    }
```

- [ ] **Step 6: Run to verify these fail**

Run: `swift test --filter 'AdjustmentMappingTests|AdjustmentPipelineTests'`
Expected: FAIL.

- [ ] **Step 7: Extend `RenderParameters`/`AdjustmentMapping`**

Add `public let advancedToneCurve: AdvancedToneCurve` to `RenderParameters`, `public var isAdvancedToneCurveIdentity: Bool { advancedToneCurve.isIdentity }`, and `advancedToneCurve: clamped.advancedToneCurve` to the constructor.

- [ ] **Step 8: Implement the kernel and wire it into the pipeline**

Add a static `CIColorKernel` and application helper to `AdjustmentPipeline.swift` (or a new private extension in the same file — keep it next to `applySplitToning`/`applyVignette`/`applyGrain` since all four are pipeline-internal, not public API):

```swift
    /// Per-pixel 1D LUT lookup, run once per RGB channel with the same table
    /// (spec §4.3: colour is not touched, only tone). Core Image Kernel
    /// Language rather than a `.metal` file, so no Package.swift build-target
    /// changes are needed for one small kernel.
    private static let advancedToneCurveKernel: CIColorKernel? = {
        let source = """
        kernel vec4 advancedToneCurve(sampler image, sampler lut, float lutWidth) {
            vec4 pixel = sample(image, samplerCoord(image));
            float lastIndex = lutWidth - 1.0;
            vec2 lutSize = samplerSize(lut);
            float r = sample(lut, samplerTransform(lut, vec2(pixel.r * lastIndex + 0.5, lutSize.y * 0.5))).r;
            float g = sample(lut, samplerTransform(lut, vec2(pixel.g * lastIndex + 0.5, lutSize.y * 0.5))).r;
            float b = sample(lut, samplerTransform(lut, vec2(pixel.b * lastIndex + 0.5, lutSize.y * 0.5))).r;
            return vec4(r, g, b, pixel.a);
        }
        """
        return CIColorKernel(source: source)
    }()

    private static func applyAdvancedToneCurve(_ curve: AdvancedToneCurve, to image: CIImage) -> CIImage {
        guard let kernel = advancedToneCurveKernel else { return image }
        let table = AdvancedToneCurveLUT.build(from: curve.points, resolution: 256)
        guard let lutImage = Self.makeLUTImage(table) else { return image }
        let extent = image.extent
        let arguments: [Any] = [image, lutImage, Double(table.count)]
        return kernel.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: arguments) ?? image
    }

    /// Packs a 1D `[Float]` table into a 1-row-high `CIImage` the kernel can
    /// sample, one red-channel texel per LUT entry.
    private static func makeLUTImage(_ table: [Float]) -> CIImage? {
        var pixelData = [UInt8]()
        pixelData.reserveCapacity(table.count * 4)
        for value in table {
            let byte = UInt8(max(0, min(255, value * 255)))
            pixelData.append(contentsOf: [byte, byte, byte, 255])
        }
        return pixelData.withUnsafeBytes { buffer -> CIImage? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            let data = Data(bytes: baseAddress, count: pixelData.count)
            return CIImage(
                bitmapData: data,
                bytesPerRow: table.count * 4,
                size: CGSize(width: table.count, height: 1),
                format: .RGBA8,
                colorSpace: nil
            )
        }
    }
```

Wire it into `apply(_:to:)`, inside the `needsPerceptualStage` block, replacing the `// MARK: - Insertion seam for Task 6 ...` comment left by Task 5 with:

```swift
            // 5.5. Advanced tone curve (spec §4.2 step 5.5) — a second,
            // independent curve layered on top of the four-slider one.
            if !parameters.isAdvancedToneCurveIdentity {
                working = Self.applyAdvancedToneCurve(parameters.advancedToneCurve, to: working)
            }

```

`needsPerceptualStage` (the boolean guarding the whole gamma round-trip block) also needs `|| !parameters.isAdvancedToneCurveIdentity` added to its `||`-chain, or a curve-only edit will never enter gamma space and silently no-op:

```swift
        let needsPerceptualStage = !parameters.isToneCurveIdentity
            || !parameters.isContrastIdentity
            || !parameters.isSaturationIdentity
            || !parameters.isVibranceIdentity
            || !parameters.isAdvancedToneCurveIdentity
            || !parameters.isSplitToningIdentity
```

(Add `!parameters.isSplitToningIdentity` here too if Task 5 didn't already — check the current state of this line before editing; Tasks 5-7 all add stages inside this block and all need their identity flag represented here, since this boolean is what decides whether the block runs at all.)

- [ ] **Step 9: Run to verify tests pass**

Run: `swift test --filter 'AdjustmentMappingTests|AdjustmentPipelineTests'`
Expected: PASS. If `testAdvancedCurveDarkeningPointsDarkenTheImage` fails while `AdvancedToneCurveLUTTests` all pass, the bug is in the kernel/sampling code (`applyAdvancedToneCurve`/`makeLUTImage`/`advancedToneCurveKernel`), not the LUT math — narrow it there first per systematic-debugging.

- [ ] **Step 10: Full build + full test suite**

Run: `swift build && swift test`
Expected: exit 0.

- [ ] **Step 11: Commit**

```bash
git add Sources/RawProcessingCore/Pipeline/AdvancedToneCurveLUT.swift \
        Sources/RawProcessingCore/Model/AdjustmentMapping.swift \
        Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift \
        Tests/RawProcessingCoreTests/AdvancedToneCurveLUTTests.swift \
        Tests/RawProcessingCoreTests/AdjustmentMappingTests.swift \
        Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift
git commit -m "feat: wire advanced tone curve into the render pipeline via a CIColorKernel LUT lookup (spec §4.2 step 5.5, §4.3, §7 item 6)"
```

---

### Task 7: HSL (custom `CIColorKernel`, 8-band)

Spec §3.2, §4.2 step 6, §4.3, §7 item 7 — spec's own highest-risk item. Same split as Task 6: a testable CPU half (per-band weight math) and a GPU kernel confirmed only by manual visual verification (Task 8).

**Files:**
- Create: `Sources/RawProcessingCore/Pipeline/HSLKernelWeights.swift`
- Modify: `Sources/RawProcessingCore/Model/AdjustmentMapping.swift`
- Modify: `Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift`
- Test: `Tests/RawProcessingCoreTests/HSLKernelWeightsTests.swift`
- Modify: `Tests/RawProcessingCoreTests/AdjustmentMappingTests.swift`
- Modify: `Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift`

**Interfaces:**
- Consumes: `PhotoAdjustments.hsl` (Task 2), `HSLAdjustments`/`HSLBand` (Task 1).
- Produces: `HSLKernelWeights.weight(forHueDegrees:centerDegrees:) -> Double` (0...1 triangular falloff, pure function) and `HSLKernelWeights.bandCenters: [Double]` (the 8 fixed hue centers, in `HSLAdjustments` field order) — pure functions, the testable half. `RenderParameters.hsl: HSLAdjustments`, `RenderParameters.isHSLIdentity: Bool`.

- [ ] **Step 1: Write the failing weight tests**

```swift
// Tests/RawProcessingCoreTests/HSLKernelWeightsTests.swift
import XCTest
@testable import RawProcessingCore

final class HSLKernelWeightsTests: XCTestCase {
    func testEightBandCentersSpanTheHueWheel() {
        XCTAssertEqual(HSLKernelWeights.bandCenters.count, 8)
        // Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta order,
        // matching HSLAdjustments's field order (spec §3.2).
        XCTAssertEqual(HSLKernelWeights.bandCenters, [0, 30, 60, 120, 180, 240, 275, 315])
    }

    func testWeightIsOneAtExactCenter() {
        XCTAssertEqual(HSLKernelWeights.weight(forHueDegrees: 60, centerDegrees: 60), 1.0, accuracy: 1e-9)
    }

    func testWeightFallsOffAwayFromCenter() {
        let atCenter = HSLKernelWeights.weight(forHueDegrees: 60, centerDegrees: 60)
        let near = HSLKernelWeights.weight(forHueDegrees: 70, centerDegrees: 60)
        let far = HSLKernelWeights.weight(forHueDegrees: 150, centerDegrees: 60)
        XCTAssertGreaterThan(atCenter, near)
        XCTAssertGreaterThan(near, far)
    }

    func testWeightWrapsAroundZeroDegrees() {
        // Red is centred at 0/360 -- a hue of 350 should weight almost as
        // strongly toward red as a hue of 10 does, not fall off as if 0 and
        // 360 were unrelated ends of a line.
        let justBelow = HSLKernelWeights.weight(forHueDegrees: 350, centerDegrees: 0)
        let justAbove = HSLKernelWeights.weight(forHueDegrees: 10, centerDegrees: 0)
        XCTAssertEqual(justBelow, justAbove, accuracy: 1e-9)
        XCTAssertGreaterThan(justBelow, 0.5)
    }

    func testWeightsAcrossAllBandsSumToAtMostOnePlusOverlap() {
        // Neighbouring bands should overlap smoothly (no hard seams) but a
        // hue exactly between two centers shouldn't get more than ~1 total
        // weight, or the blended adjustment amplifies instead of blending.
        let totalAtBoundary = HSLKernelWeights.bandCenters.reduce(0.0) { total, center in
            total + HSLKernelWeights.weight(forHueDegrees: 15, centerDegrees: center)
        }
        XCTAssertLessThanOrEqual(totalAtBoundary, 1.2)
        XCTAssertGreaterThan(totalAtBoundary, 0.9)
    }
}
```

- [ ] **Step 2: Run to verify these fail**

Run: `swift test --filter HSLKernelWeightsTests`
Expected: FAIL — `HSLKernelWeights` doesn't exist yet.

- [ ] **Step 3: Implement `HSLKernelWeights`**

```swift
// Sources/RawProcessingCore/Pipeline/HSLKernelWeights.swift
import Foundation

/// Per-band hue-distance weighting for the 8-colour HSL kernel (spec §4.3).
///
/// A triangular falloff around each band's centre hue, on a wrapped 0...360
/// circle, so hues near a boundary blend smoothly between the two nearest
/// bands instead of snapping — the pure-Swift half of Task 7, kept separate
/// from the GPU kernel so the weighting math itself is unit-tested.
public enum HSLKernelWeights {
    /// Centre hue in degrees for red/orange/yellow/green/aqua/blue/purple/magenta,
    /// in the same order as `HSLAdjustments`'s stored properties.
    public static let bandCenters: [Double] = [0, 30, 60, 120, 180, 240, 275, 315]

    /// Half-width, in degrees, of one band's falloff before it reaches zero.
    /// Chosen so adjacent bands' triangles cross near their midpoint rather
    /// than leaving a dead zone or overlapping too heavily.
    public static let halfWidthDegrees = 45.0

    /// 1.0 at `centerDegrees`, falling linearly to 0.0 at `halfWidthDegrees`
    /// away, wrapping correctly across the 0/360 seam.
    public static func weight(forHueDegrees hue: Double, centerDegrees: Double) -> Double {
        let distance = wrappedDistance(hue, centerDegrees)
        return max(0, 1 - distance / halfWidthDegrees)
    }

    private static func wrappedDistance(_ a: Double, _ b: Double) -> Double {
        let raw = abs(a.truncatingRemainder(dividingBy: 360) - b.truncatingRemainder(dividingBy: 360))
        return min(raw, 360 - raw)
    }
}
```

- [ ] **Step 4: Run to verify weight tests pass**

Run: `swift test --filter HSLKernelWeightsTests`
Expected: PASS.

- [ ] **Step 5: Write the failing mapping + pipeline tests**

Append to `Tests/RawProcessingCoreTests/AdjustmentMappingTests.swift`:

```swift
    func testHSLIsCarriedThroughUnchanged() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.hsl.blue = HSLBand(hue: -20, saturation: 40, luminance: 0)
        let parameters = AdjustmentMapping.renderParameters(for: adjustments)
        XCTAssertEqual(parameters.hsl, adjustments.hsl)
        XCTAssertFalse(parameters.isHSLIdentity)
    }

    func testNeutralHSLIsIdentity() {
        XCTAssertTrue(AdjustmentMapping.renderParameters(for: .neutral).isHSLIdentity)
    }
```

Append to `Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift`:

```swift
    // MARK: - HSL

    func testNeutralHSLStaysAPassthrough() {
        let source = makeSourceImage()
        XCTAssertTrue(pipeline.apply(PhotoAdjustments.neutral, to: source) === source)
    }

    func testReducingRedSaturationDesaturatesARedPatch() throws {
        let red = makeSourceImage(red: 0.7, green: 0.2, blue: 0.2)
        let base = try centrePixel(red)
        var adjustments = PhotoAdjustments.neutral
        adjustments.hsl.red = HSLBand(hue: 0, saturation: -100, luminance: 0)
        let desaturated = try centrePixel(pipeline.apply(adjustments, to: red))
        XCTAssertLessThan(desaturated.red - desaturated.blue, base.red - base.blue)
    }

    func testAdjustingBlueDoesNotVisiblyMoveARedPatch() throws {
        // A band-selective tool must leave hues far from its centre close to
        // untouched -- this is what makes it "selective" rather than a
        // second global saturation slider.
        let red = makeSourceImage(red: 0.7, green: 0.2, blue: 0.2)
        let base = try centrePixel(red)
        var adjustments = PhotoAdjustments.neutral
        adjustments.hsl.blue = HSLBand(hue: 0, saturation: 100, luminance: 0)
        let stillRed = try centrePixel(pipeline.apply(adjustments, to: red))
        XCTAssertEqual(stillRed.red, base.red, accuracy: 3)
    }
```

- [ ] **Step 6: Run to verify these fail**

Run: `swift test --filter 'AdjustmentMappingTests|AdjustmentPipelineTests'`
Expected: FAIL.

- [ ] **Step 7: Extend `RenderParameters`/`AdjustmentMapping`**

Add `public let hsl: HSLAdjustments` to `RenderParameters`, `public var isHSLIdentity: Bool { hsl.isIdentity }`, and `hsl: clamped.hsl` to the constructor.

- [ ] **Step 8: Implement the kernel and wire it into the pipeline**

Add to `AdjustmentPipeline.swift`, alongside the Task 6 kernel:

```swift
    /// One pass over all 8 bands per pixel, blending each band's hue/sat/lum
    /// adjustment by `HSLKernelWeights`-equivalent triangular falloff (spec
    /// §4.3). The falloff math is duplicated here in CIKL rather than calling
    /// into `HSLKernelWeights` -- the GPU kernel can't call Swift -- so any
    /// change to the falloff shape must be made in both places; the unit
    /// tests on `HSLKernelWeights` exist specifically to keep this constant
    /// correct even though the kernel body itself can't be unit tested.
    private static let hslKernel: CIColorKernel? = {
        let source = """
        kernel vec4 hslAdjust(
            sampler image,
            float centers0, float centers1, float centers2, float centers3,
            float centers4, float centers5, float centers6, float centers7,
            float hues0, float hues1, float hues2, float hues3,
            float hues4, float hues5, float hues6, float hues7,
            float sats0, float sats1, float sats2, float sats3,
            float sats4, float sats5, float sats6, float sats7,
            float lums0, float lums1, float lums2, float lums3,
            float lums4, float lums5, float lums6, float lums7,
            float halfWidth
        ) {
            vec4 pixel = sample(image, samplerCoord(image));
            float maxC = max(pixel.r, max(pixel.g, pixel.b));
            float minC = min(pixel.r, min(pixel.g, pixel.b));
            float delta = maxC - minC;
            float luma = (maxC + minC) * 0.5;

            float hueDeg = 0.0;
            if (delta > 0.0001) {
                if (maxC == pixel.r) {
                    hueDeg = 60.0 * mod((pixel.g - pixel.b) / delta, 6.0);
                } else if (maxC == pixel.g) {
                    hueDeg = 60.0 * (((pixel.b - pixel.r) / delta) + 2.0);
                } else {
                    hueDeg = 60.0 * (((pixel.r - pixel.g) / delta) + 4.0);
                }
            }
            if (hueDeg < 0.0) { hueDeg = hueDeg + 360.0; }

            float centers[8];
            centers[0]=centers0; centers[1]=centers1; centers[2]=centers2; centers[3]=centers3;
            centers[4]=centers4; centers[5]=centers5; centers[6]=centers6; centers[7]=centers7;
            float hues[8];
            hues[0]=hues0; hues[1]=hues1; hues[2]=hues2; hues[3]=hues3;
            hues[4]=hues4; hues[5]=hues5; hues[6]=hues6; hues[7]=hues7;
            float sats[8];
            sats[0]=sats0; sats[1]=sats1; sats[2]=sats2; sats[3]=sats3;
            sats[4]=sats4; sats[5]=sats5; sats[6]=sats6; sats[7]=sats7;
            float lums[8];
            lums[0]=lums0; lums[1]=lums1; lums[2]=lums2; lums[3]=lums3;
            lums[4]=lums4; lums[5]=lums5; lums[6]=lums6; lums[7]=lums7;

            float hueShift = 0.0;
            float satShift = 0.0;
            float lumShift = 0.0;
            for (int i = 0; i < 8; i++) {
                float rawDistance = abs(mod(hueDeg, 360.0) - mod(centers[i], 360.0));
                float distance = min(rawDistance, 360.0 - rawDistance);
                float weight = max(0.0, 1.0 - distance / halfWidth);
                hueShift += weight * hues[i];
                satShift += weight * sats[i];
                lumShift += weight * lums[i];
            }

            // hue in degrees/100 keeps the shift in the same -1...1-ish order
            // of magnitude as sat/lum before they're applied as fractional
            // adjustments -- a 100-degree slider maps to roughly a 27-degree
            // hue rotation, consistent with the ±100 UI range meaning "full
            // strength", not "spin the hue wheel".
            float shiftedHue = mod(hueDeg + hueShift * 0.27, 360.0);
            float newSat = clamp(1.0 + satShift / 100.0, 0.0, 2.0);
            float newLum = luma + (lumShift / 100.0) * 0.25;

            float c = delta * newSat;
            float x = c * (1.0 - abs(mod(shiftedHue / 60.0, 2.0) - 1.0));
            float m = newLum - c * 0.5;
            vec3 rgbPrime;
            if (shiftedHue < 60.0) { rgbPrime = vec3(c, x, 0.0); }
            else if (shiftedHue < 120.0) { rgbPrime = vec3(x, c, 0.0); }
            else if (shiftedHue < 180.0) { rgbPrime = vec3(0.0, c, x); }
            else if (shiftedHue < 240.0) { rgbPrime = vec3(0.0, x, c); }
            else if (shiftedHue < 300.0) { rgbPrime = vec3(x, 0.0, c); }
            else { rgbPrime = vec3(c, 0.0, x); }

            return vec4(clamp(rgbPrime + m, 0.0, 1.0), pixel.a);
        }
        """
        return CIColorKernel(source: source)
    }()

    private static func applyHSL(_ hsl: HSLAdjustments, to image: CIImage) -> CIImage {
        guard let kernel = hslKernel else { return image }
        let bands = [hsl.red, hsl.orange, hsl.yellow, hsl.green, hsl.aqua, hsl.blue, hsl.purple, hsl.magenta]
        let centers = HSLKernelWeights.bandCenters
        var arguments: [Any] = [image]
        arguments.append(contentsOf: centers.map { Double($0) })
        arguments.append(contentsOf: bands.map { Double($0.hue) })
        arguments.append(contentsOf: bands.map { Double($0.saturation) })
        arguments.append(contentsOf: bands.map { Double($0.luminance) })
        arguments.append(HSLKernelWeights.halfWidthDegrees)
        let extent = image.extent
        return kernel.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: arguments) ?? image
    }
```

Wire it into `apply(_:to:)`, immediately after the Task 6 advanced-curve stage and before split toning:

```swift
            // 6. HSL (spec §4.2 step 6).
            if !parameters.isHSLIdentity {
                working = Self.applyHSL(parameters.hsl, to: working)
            }

```

Add `|| !parameters.isHSLIdentity` to `needsPerceptualStage`'s `||`-chain (same reasoning as Task 6's `isAdvancedToneCurveIdentity` addition — check the line's current state, it should now also carry Task 5's and Task 6's additions).

- [ ] **Step 9: Run to verify tests pass**

Run: `swift test --filter 'AdjustmentMappingTests|AdjustmentPipelineTests'`
Expected: PASS. `hslAdjust`'s CIKL has 33 scalar arguments plus the image — if the kernel fails to compile (`hslKernel` is `nil`, `applyHSL` silently no-ops and pixel-direction tests fail while nothing crashes), the most likely cause is CIKL's fixed-size local array syntax (`float centers[8]`) not being supported in the CIKL dialect on this OS version — if so, replace the 32 scalar parameters + local-array pattern with 8 unrolled `if`/weight terms (no arrays), which is more verbose CIKL but has no array-support dependency; verify by testing `hslKernel != nil` directly in a quick throwaway test before debugging the pixel-level tests further.

- [ ] **Step 10: Full build + full test suite**

Run: `swift build && swift test`
Expected: exit 0.

- [ ] **Step 11: Commit**

```bash
git add Sources/RawProcessingCore/Pipeline/HSLKernelWeights.swift \
        Sources/RawProcessingCore/Model/AdjustmentMapping.swift \
        Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift \
        Tests/RawProcessingCoreTests/HSLKernelWeightsTests.swift \
        Tests/RawProcessingCoreTests/AdjustmentMappingTests.swift \
        Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift
git commit -m "feat: wire 8-band HSL into the render pipeline via a CIColorKernel (spec §4.2 step 6, §4.3, §7 item 7)"
```

---

### Task 8: Manual visual verification checklist

Spec §6 (manual visual verification bullets), §7 item 8. This is not automatable — real Sony ARW files and a GPU are both required, and this machine (as of this plan's writing) is x86_64 with only Command Line Tools, no Xcode (see this repo's `Tests/LumaHarborIntegrationTests/RawFixtureTests.swift` for the same constraint on the existing RAW test suite). This task's deliverable is the checklist document plus running it; running it may have to happen in a later session on Apple Silicon + Xcode hardware, per the existing `LUMAHARBOR_RAW_FIXTURE_DIR` convention.

**Files:**
- Create: `docs/testing/2026-08-19-adjustment-engine-manual-verification.md`

- [ ] **Step 1: Write the checklist document**

```markdown
# Adjustment Engine Expansion — Manual Visual Verification

Spec: `docs/superpowers/specs/2026-08-19-adjustment-engine-expansion-design.md` §6.

Prerequisite: Apple Silicon Mac, full Xcode, real Sony `.ARW` fixtures. Set
`LUMAHARBOR_RAW_FIXTURE_DIR` and run the automated suite first
(`swift test`) — it must be green before manual verification starts.

None of these seven effects is reachable from the Inspector UI (spec §1) — set
values directly on a `PhotoAdjustments` in a throwaway debug harness, or via
temporarily hardcoding a non-neutral value in `AdjustmentMapping.renderParameters`,
render, inspect, then revert.

- [ ] **HSL**: on a real ARW, push each of the 8 hue bands' hue/saturation/luminance
  to their extremes one at a time. Confirm the correct region of the photo visibly
  changes and neighbouring bands' boundaries don't show hard colour-banding
  seams.
- [ ] **Advanced tone curve**: apply a curve with several control points and a
  non-trivial shape (at least one point that pulls a midtone away from the
  4-slider curve's effect). Confirm the image's brightness distribution
  matches the curve's shape, and there is no solarisation (any tonal
  inversion — see `enforceMonotonicNonDecreasing` in
  `AdvancedToneCurveLUT.swift`).
- [ ] **Split toning**: apply distinct shadow and highlight hues at high
  saturation. Confirm shadows and highlights tint independently and
  `balance` visibly shifts which tonal range is affected more.
- [ ] **Sharpening / noise reduction / vignette / grain**: apply each at an
  extreme value independently. Confirm each produces a visible, correct-
  direction change, no crash, and no obvious artifact (haloing, banding,
  posterisation).
- [ ] **All seven together**: apply every effect at once. Confirm the pipeline
  doesn't crash, output still renders, and render time doesn't feel
  noticeably slower than before this expansion (no precise measurement
  required per spec §6 — a "does this still feel snappy" judgement call).

## Result

(Fill in after running: date, machine, which items passed, any follow-up
issues filed.)
```

- [ ] **Step 2: Commit**

```bash
git add docs/testing/2026-08-19-adjustment-engine-manual-verification.md
git commit -m "docs: add manual visual verification checklist for the adjustment engine expansion (spec §6, §7 item 8)"
```

- [ ] **Step 3: If this machine can run it, run it now; otherwise hand off**

If Xcode + an Apple Silicon target are available, work through the checklist and fill in the Result section, then commit that update separately. If not (as expected on the machine this plan was authored on), leave the checklist unrun and note that explicitly in the spec's `## 進度日誌` section per this plan's Global Constraints, so the next session — possibly on different hardware — knows exactly where things stand.

---

## Self-Review Notes

- **Spec coverage:** §3.1-§3.8 → Tasks 1-2. §4.1 (unchanged) verified by existing `AdjustmentPipelineTests` continuing to pass. §4.2 steps 5.5-11 → Tasks 3-7, in pipeline-position order except split toning (Task 5) is implemented before advanced-curve/HSL (Tasks 6-7) despite sitting after them in the pipeline — the insertion-seam comment in Task 5 Step 4 and the explicit re-statement in Tasks 6-7 Step 8 handle this ordering mismatch. §4.3 → Tasks 6-7. §4.4 → every task's `isXIdentity` flag + skip-when-identity `if` guard. §5 → Task 2 Step 4 (schema bump); no new sidecar test per spec's own note that `SidecarRepositoryTests` already covers rejection generically. §6 → the boundary/identity/round-trip tests threaded through every task, plus Task 8 for the GPU-only portion.
- **Type consistency:** `RenderParameters` gains exactly one new field + one new `isXIdentity` computed property per task (Tasks 3 adds three at once for sharpening/noise/vignette, being the one exception since spec §7 groups them); every later task's pipeline code reads `parameters.<field>` with the same name used in the corresponding `AdjustmentMapping` extension in the same task. `PhotoAdjustments.<field>` names (Task 2) match the struct names from Task 1 exactly (`advancedToneCurve: AdvancedToneCurve`, `hsl: HSLAdjustments`, etc.) and match `RenderParameters`'s field names one-for-one.
- **No placeholders:** every step above either has real Swift/CIKL code or is a manual QA checklist item that spec §6 itself states cannot be automated.
