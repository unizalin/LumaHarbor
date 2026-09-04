import Foundation

/// One local (spatially-limited) edit — a linear gradient or a spot heal /
/// clone point — layered on top of a photo's global `PhotoAdjustments`
/// (design spec §6.6/§6.7, roadmap Phase 4 "Data model").
///
/// Phase 4 Task 4.1 is schema only: nothing here builds a Core Image mask,
/// composites a render, or feeds any render pipeline — that is Task 4.2
/// (linear gradient) and Task 4.4 (spot heal)'s job. The array lives on
/// `PhotoAdjustments.localAdjustments` so it rides the same sidecar
/// persistence, undo, and batch-sync exclusion every other adjustment
/// already has (spec §6.9 explicitly keeps local retouching out of batch
/// sync unless the user opts in — Task 3.3's own scope boundary, unchanged
/// here).
public struct LocalAdjustment: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: LocalAdjustmentKind
    public var isEnabled: Bool
    public var geometry: LocalAdjustmentGeometry
    public var adjustments: LocalAdjustmentPatch

    public init(
        id: UUID = UUID(),
        kind: LocalAdjustmentKind,
        isEnabled: Bool = true,
        geometry: LocalAdjustmentGeometry = .neutral,
        adjustments: LocalAdjustmentPatch = LocalAdjustmentPatch()
    ) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.geometry = geometry
        self.adjustments = adjustments
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, kind, isEnabled, geometry, adjustments
    }

    /// `id` and `kind` are the two keys this type does *not* degrade on:
    /// every other field in this codebase's sidecar types falls back to a
    /// default when absent because that default is a faithful stand-in for
    /// "not set yet". There is no faithful stand-in for "which edit is
    /// this" or "which point does undo/hit-testing think this is" — a
    /// missing `id` would silently detach this entry from anything that
    /// already referenced it, and a missing `kind` would have to guess
    /// between two edits with very different render behavior. Both throw,
    /// same as any other structurally corrupt sidecar field this codebase
    /// doesn't have a safe default for.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.kind = try container.decode(LocalAdjustmentKind.self, forKey: .kind)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.geometry = try container.decodeIfPresent(LocalAdjustmentGeometry.self, forKey: .geometry) ?? .neutral
        self.adjustments = try container.decodeIfPresent(LocalAdjustmentPatch.self, forKey: .adjustments) ?? LocalAdjustmentPatch()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(geometry, forKey: .geometry)
        try container.encode(adjustments, forKey: .adjustments)
    }
}

public enum LocalAdjustmentKind: String, Codable, Equatable, Hashable, Sendable {
    case linearGradient
    case spotHeal
}

/// Copy/delete/select as list surgery on the plain array `PhotoAdjustments
/// .localAdjustments` already is (Phase 4 Task 4.2's own "model tests for
/// copy/delete/select" requirement) -- there is no service or view model
/// yet (Task 4.3 is the first Mac UI), so this is exactly what a future
/// "Duplicate"/"Delete"/tap-to-select action needs the schema layer to
/// support, matching how `LibraryViewModel.duplicateAsVirtualCopy`/
/// `deleteVirtualCopy` sit directly on top of equally plain model
/// operations for Phase 3's virtual copies.
extension Array where Element == LocalAdjustment {
    /// Inserts a fresh-identity copy of the entry matching `id` immediately
    /// after it, leaving everything else (including elements after the
    /// original) in the same relative order. A no-op, not a crash, if `id`
    /// isn't found -- matches `removing(_:)`'s own tolerance for a stale
    /// reference (e.g. the entry was already deleted by a concurrent edit).
    public func duplicating(_ id: UUID) -> [LocalAdjustment] {
        guard let index = firstIndex(where: { $0.id == id }) else { return self }
        var copy = self[index]
        copy.id = UUID()
        var result = self
        result.insert(copy, at: index + 1)
        return result
    }

    /// Removes the entry matching `id`. A no-op if `id` isn't found.
    public func removing(_ id: UUID) -> [LocalAdjustment] {
        var result = self
        result.removeAll { $0.id == id }
        return result
    }

    /// Looks up the entry matching `id` -- the model-layer half of "the
    /// user tapped/selected this one"; which `id` counts as selected is a
    /// future UI's own state, not this array's.
    public func selecting(_ id: UUID) -> LocalAdjustment? {
        first { $0.id == id }
    }
}

/// Spot heal's two sampling modes (design spec §6.7).
public enum SpotHealMode: String, Codable, Equatable, Hashable, Sendable {
    /// Auto-sampled surrounding texture — no source point needed.
    case heal
    /// Sampled from an explicit source point the user placed.
    case clone
}

/// Parametric (never bitmap — spec §6.6: "不使用不可 diff 的遮罩點陣圖")
/// geometry for one local adjustment. A single flat struct rather than a
/// per-kind enum, matching `GeometryAdjustments`'s own established
/// convention in this codebase: fields that don't apply to the current
/// `LocalAdjustment.kind` just stay at their default rather than the type
/// system encoding two mutually exclusive shapes.
public struct LocalAdjustmentGeometry: Codable, Equatable, Hashable, Sendable {
    /// Normalized `[0, 1]` source-image coordinates, origin top-left (same
    /// convention as `NormalizedCropRect`). Linear gradient: the gradient's
    /// pivot point. Spot heal: the target point being retouched.
    ///
    /// Every field below carries its own `didSet` clamp -- not just
    /// validation inside `init` -- because Task 4.3's UI mutates an
    /// existing value's fields directly (`adjustments.localAdjustments[i]
    /// .geometry.x = newX`, the same idiom `GeometryAdjustments
    /// .rotationDegrees` already established its own `didSet` for), and
    /// `didSet` does not fire during a type's own initializer, so `init`
    /// clamps explicitly too, matching `Vignette`'s and `GeometryAdjustments`'s
    /// own existing convention exactly.
    public var x: Double { didSet { x = Self.clampToUnit(x) } }
    public var y: Double { didSet { y = Self.clampToUnit(y) } }
    /// Linear gradient only: direction of the transition, degrees (0 =
    /// left-to-right, 90 = top-to-bottom, increasing clockwise). Not an
    /// angle Task 4.1 validates against a range — any finite value is a
    /// legal direction, it just normalizes to something a compass makes
    /// sense of at render time (Task 4.2). Still guarded against non-finite
    /// input the same way every other field here is.
    public var angleDegrees: Double { didSet { angleDegrees = angleDegrees.isFinite ? angleDegrees : 0 } }
    /// Linear gradient only: how far the transition band extends from the
    /// pivot before reaching full effect, normalized to `[0, 1]`.
    /// Meaningless for `.spotHeal`.
    public var range: Double { didSet { range = Self.clampToUnit(range) } }
    /// Spot heal, clone mode only: the point sampled from. `nil` in heal
    /// mode (the algorithm chooses its own source) or before the user has
    /// placed one. Meaningless for `.linearGradient`.
    public var sourceX: Double? { didSet { sourceX = sourceX.map(Self.clampToUnit) } }
    public var sourceY: Double? { didSet { sourceY = sourceY.map(Self.clampToUnit) } }
    /// Spot heal only: brush radius, normalized to `[0, 1]`. Meaningless
    /// for `.linearGradient`.
    public var radius: Double { didSet { radius = Self.clampToUnit(radius) } }
    /// Shared: edge softness. `0` = hard edge, `100` = maximally soft.
    /// Applies to the gradient's own transition and the heal brush's edge.
    public var feather: Double { didSet { feather = Self.clamp(feather, to: Self.featherRange) } }
    /// Spot heal only: which of the two sampling modes this point uses.
    /// Meaningless for `.linearGradient`.
    public var healMode: SpotHealMode

    public static let unitRange: ClosedRange<Double> = 0...1
    public static let featherRange: ClosedRange<Double> = 0...100

    public init(
        x: Double = 0.5,
        y: Double = 0.5,
        angleDegrees: Double = 0,
        range: Double = 0.3,
        sourceX: Double? = nil,
        sourceY: Double? = nil,
        radius: Double = 0.05,
        feather: Double = 50,
        healMode: SpotHealMode = .heal
    ) {
        self.x = Self.clampToUnit(x)
        self.y = Self.clampToUnit(y)
        self.angleDegrees = angleDegrees.isFinite ? angleDegrees : 0
        self.range = Self.clampToUnit(range)
        self.sourceX = sourceX.map(Self.clampToUnit)
        self.sourceY = sourceY.map(Self.clampToUnit)
        self.radius = Self.clampToUnit(radius)
        self.feather = Self.clamp(feather, to: Self.featherRange)
        self.healMode = healMode
    }

    /// The gradient/heal point centered on the photo with no source point
    /// placed yet — the "just added, not dragged anywhere" state. There is
    /// no sidecar written before this struct existed, so unlike
    /// `GeometryAdjustments.neutral` this isn't standing in for a
    /// pre-existing on-disk shape; it just needs to be a valid, harmless
    /// starting point.
    public static let neutral = LocalAdjustmentGeometry()

    private static func clampToUnit(_ value: Double) -> Double {
        clamp(value, to: unitRange)
    }

    private static func clamp(_ value: Double, to bounds: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return bounds.lowerBound }
        return Swift.min(Swift.max(value, bounds.lowerBound), bounds.upperBound)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case x, y, angleDegrees, range, sourceX, sourceY, radius, feather, healMode
    }

    /// Every key optional on decode, matching `GeometryAdjustments`'s own
    /// convention — a future field this struct doesn't know about yet, or
    /// one a hand edit dropped, degrades to the neutral default rather than
    /// failing the whole sidecar.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try container.decodeIfPresent(Double.self, forKey: .x) ?? 0.5,
            y: try container.decodeIfPresent(Double.self, forKey: .y) ?? 0.5,
            angleDegrees: try container.decodeIfPresent(Double.self, forKey: .angleDegrees) ?? 0,
            range: try container.decodeIfPresent(Double.self, forKey: .range) ?? 0.3,
            sourceX: try container.decodeIfPresent(Double.self, forKey: .sourceX),
            sourceY: try container.decodeIfPresent(Double.self, forKey: .sourceY),
            radius: try container.decodeIfPresent(Double.self, forKey: .radius) ?? 0.05,
            feather: try container.decodeIfPresent(Double.self, forKey: .feather) ?? 50,
            healMode: try container.decodeIfPresent(SpotHealMode.self, forKey: .healMode) ?? .heal
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(angleDegrees, forKey: .angleDegrees)
        try container.encode(range, forKey: .range)
        // `nil` means "no source point yet" — omitted, not encoded as
        // `null`, matching `GeometryAdjustments.crop`'s own convention for
        // an absent optional leaf.
        try container.encodeIfPresent(sourceX, forKey: .sourceX)
        try container.encodeIfPresent(sourceY, forKey: .sourceY)
        try container.encode(radius, forKey: .radius)
        try container.encode(feather, forKey: .feather)
        try container.encode(healMode, forKey: .healMode)
    }
}

/// The mini adjustments a local edit can apply on top of the photo's global
/// adjustments (design spec §6.6: "曝光、對比、高光、陰影、白色、黑色、飽和度、
/// 色溫、色調" — deliberately nine fields, no `vibrance`, unlike
/// `AdjustmentCatalog`'s ten basic sliders). Sparse like `PresetCore`'s
/// `AdjustmentPatch` — a `nil` leaf means "this local adjustment doesn't
/// touch this field" — but redeclared here rather than reused because
/// `RawProcessingCore` cannot depend on `PresetCore`; the dependency already
/// runs the other way (`PresetCore` imports `RawProcessingCore`).
public struct LocalAdjustmentPatch: Codable, Equatable, Hashable, Sendable {
    public var exposure: Double?
    public var contrast: Double?
    public var highlights: Double?
    public var shadows: Double?
    public var whites: Double?
    public var blacks: Double?
    public var saturation: Double?
    public var temperature: Double?
    public var tint: Double?

    public init(
        exposure: Double? = nil,
        contrast: Double? = nil,
        highlights: Double? = nil,
        shadows: Double? = nil,
        whites: Double? = nil,
        blacks: Double? = nil,
        saturation: Double? = nil,
        temperature: Double? = nil,
        tint: Double? = nil
    ) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.saturation = saturation
        self.temperature = temperature
        self.tint = tint
    }

    public var isEmpty: Bool {
        exposure == nil && contrast == nil && highlights == nil && shadows == nil
            && whites == nil && blacks == nil && saturation == nil
            && temperature == nil && tint == nil
    }

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks, saturation, temperature, tint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            exposure: try container.decodeIfPresent(Double.self, forKey: .exposure),
            contrast: try container.decodeIfPresent(Double.self, forKey: .contrast),
            highlights: try container.decodeIfPresent(Double.self, forKey: .highlights),
            shadows: try container.decodeIfPresent(Double.self, forKey: .shadows),
            whites: try container.decodeIfPresent(Double.self, forKey: .whites),
            blacks: try container.decodeIfPresent(Double.self, forKey: .blacks),
            saturation: try container.decodeIfPresent(Double.self, forKey: .saturation),
            temperature: try container.decodeIfPresent(Double.self, forKey: .temperature),
            tint: try container.decodeIfPresent(Double.self, forKey: .tint)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(exposure, forKey: .exposure)
        try container.encodeIfPresent(contrast, forKey: .contrast)
        try container.encodeIfPresent(highlights, forKey: .highlights)
        try container.encodeIfPresent(shadows, forKey: .shadows)
        try container.encodeIfPresent(whites, forKey: .whites)
        try container.encodeIfPresent(blacks, forKey: .blacks)
        try container.encodeIfPresent(saturation, forKey: .saturation)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encodeIfPresent(tint, forKey: .tint)
    }
}
