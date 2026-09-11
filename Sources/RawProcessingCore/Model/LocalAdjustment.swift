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
    public var name: String
    public var opacity: Double
    public var isInverted: Bool
    public var geometry: LocalAdjustmentGeometry
    public var adjustments: LocalAdjustmentPatch

    public init(
        id: UUID = UUID(),
        kind: LocalAdjustmentKind,
        isEnabled: Bool = true,
        name: String = "",
        opacity: Double = 100,
        isInverted: Bool = false,
        geometry: LocalAdjustmentGeometry = .neutral,
        adjustments: LocalAdjustmentPatch = LocalAdjustmentPatch()
    ) {
        self.id = id
        self.kind = kind
        self.isEnabled = isEnabled
        self.name = name
        self.opacity = Swift.min(Swift.max(opacity, 0), 100)
        self.isInverted = isInverted
        self.geometry = geometry
        self.adjustments = adjustments
    }

    /// Backwards-compatible initializer matching the 5-argument signature
    public init(
        id: UUID = UUID(),
        kind: LocalAdjustmentKind,
        isEnabled: Bool = true,
        geometry: LocalAdjustmentGeometry = .neutral,
        adjustments: LocalAdjustmentPatch = LocalAdjustmentPatch()
    ) {
        self.init(
            id: id,
            kind: kind,
            isEnabled: isEnabled,
            name: "",
            opacity: 100,
            isInverted: false,
            geometry: geometry,
            adjustments: adjustments
        )
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, kind, isEnabled, name, opacity, isInverted, geometry, adjustments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.kind = try container.decode(LocalAdjustmentKind.self, forKey: .kind)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 100
        self.isInverted = try container.decodeIfPresent(Bool.self, forKey: .isInverted) ?? false
        self.geometry = try container.decodeIfPresent(LocalAdjustmentGeometry.self, forKey: .geometry) ?? .neutral
        self.adjustments = try container.decodeIfPresent(LocalAdjustmentPatch.self, forKey: .adjustments) ?? LocalAdjustmentPatch()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(isEnabled, forKey: .isEnabled)
        if !name.isEmpty {
            try container.encode(name, forKey: .name)
        }
        if opacity != 100 {
            try container.encode(opacity, forKey: .opacity)
        }
        if isInverted {
            try container.encode(isInverted, forKey: .isInverted)
        }
        try container.encode(geometry, forKey: .geometry)
        try container.encode(adjustments, forKey: .adjustments)
    }
}

public enum LocalAdjustmentKind: String, Codable, Equatable, Hashable, Sendable {
    case linearGradient
    case radialGradient
    case brush
    case luminanceRange
    case colorRange
    case subject
    case background
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

/// Spot heal's sampling modes (design spec §6.7).
public enum SpotHealMode: String, Codable, Equatable, Hashable, Sendable {
    /// Auto-sampled surrounding texture — no source point needed.
    case heal
    /// Sampled from an explicit source point the user placed.
    case clone
    /// Red-eye removal mode.
    case redEye
}

public struct BrushPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double { didSet { x = Swift.min(Swift.max(x.isFinite ? x : 0, 0), 1) } }
    public var y: Double { didSet { y = Swift.min(Swift.max(y.isFinite ? y : 0, 0), 1) } }
    public var pressure: Double? { didSet { pressure = pressure.map { Swift.min(Swift.max($0.isFinite ? $0 : 1, 0), 1) } } }

    public init(x: Double, y: Double, pressure: Double? = nil) {
        self.x = Swift.min(Swift.max(x.isFinite ? x : 0, 0), 1)
        self.y = Swift.min(Swift.max(y.isFinite ? y : 0, 0), 1)
        self.pressure = pressure.map { Swift.min(Swift.max($0.isFinite ? $0 : 1, 0), 1) }
    }
}

public struct BrushStroke: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var points: [BrushPoint]
    public var radius: Double { didSet { radius = Swift.min(Swift.max(radius.isFinite ? radius : 0.05, 0.001), 1) } }
    public var feather: Double { didSet { feather = Swift.min(Swift.max(feather.isFinite ? feather : 50, 0), 100) } }

    public init(
        id: UUID = UUID(),
        points: [BrushPoint] = [],
        radius: Double = 0.05,
        feather: Double = 50
    ) {
        self.id = id
        self.points = points
        self.radius = Swift.min(Swift.max(radius.isFinite ? radius : 0.05, 0.001), 1)
        self.feather = Swift.min(Swift.max(feather.isFinite ? feather : 50, 0), 100)
    }
}

/// Parametric geometry for one local adjustment.
public struct LocalAdjustmentGeometry: Codable, Equatable, Hashable, Sendable {
    public var x: Double { didSet { x = Self.clampToUnit(x) } }
    public var y: Double { didSet { y = Self.clampToUnit(y) } }
    public var angleDegrees: Double { didSet { angleDegrees = angleDegrees.isFinite ? angleDegrees : 0 } }
    public var range: Double { didSet { range = Self.clampToUnit(range) } }
    public var sourceX: Double? { didSet { sourceX = sourceX.map(Self.clampToUnit) } }
    public var sourceY: Double? { didSet { sourceY = sourceY.map(Self.clampToUnit) } }
    public var radius: Double { didSet { radius = Self.clampToUnit(radius) } }
    public var feather: Double { didSet { feather = Self.clamp(feather, to: Self.featherRange) } }
    public var healMode: SpotHealMode

    // P5 Advanced Masks additions:
    public var radialRadiusY: Double? { didSet { radialRadiusY = radialRadiusY.map(Self.clampToUnit) } }
    public var brushStrokes: [BrushStroke]
    public var luminanceMin: Double? { didSet { luminanceMin = luminanceMin.map(Self.clampToUnit) } }
    public var luminanceMax: Double? { didSet { luminanceMax = luminanceMax.map(Self.clampToUnit) } }
    public var colorTargetHue: Double? {
        didSet {
            colorTargetHue = colorTargetHue.map { hue in
                guard hue.isFinite else { return 0 }
                let rem = hue.truncatingRemainder(dividingBy: 360)
                return rem < 0 ? rem + 360 : rem
            }
        }
    }
    public var colorHueTolerance: Double? {
        didSet {
            colorHueTolerance = colorHueTolerance.map { tol in
                guard tol.isFinite else { return 30 }
                return Swift.min(Swift.max(tol, 0), 180)
            }
        }
    }
    public var maskRelativePath: String?
    public var sourceFingerprint: String?
    public var maskDigest: String?
    public var visionRevision: Int?
    public var reconstructionNeeded: Bool
    public var redEyePupilRadius: Double? { didSet { redEyePupilRadius = redEyePupilRadius.map(Self.clampToUnit) } }

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
        healMode: SpotHealMode = .heal,
        radialRadiusY: Double? = nil,
        brushStrokes: [BrushStroke] = [],
        luminanceMin: Double? = nil,
        luminanceMax: Double? = nil,
        colorTargetHue: Double? = nil,
        colorHueTolerance: Double? = nil,
        maskRelativePath: String? = nil,
        sourceFingerprint: String? = nil,
        maskDigest: String? = nil,
        visionRevision: Int? = nil,
        reconstructionNeeded: Bool = false,
        redEyePupilRadius: Double? = nil
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
        self.radialRadiusY = radialRadiusY.map(Self.clampToUnit)
        self.brushStrokes = brushStrokes
        self.luminanceMin = luminanceMin.map(Self.clampToUnit)
        self.luminanceMax = luminanceMax.map(Self.clampToUnit)
        self.colorTargetHue = colorTargetHue.map { hue in
            guard hue.isFinite else { return 0 }
            let rem = hue.truncatingRemainder(dividingBy: 360)
            return rem < 0 ? rem + 360 : rem
        }
        self.colorHueTolerance = colorHueTolerance.map { tol in
            guard tol.isFinite else { return 30 }
            return Swift.min(Swift.max(tol, 0), 180)
        }
        self.maskRelativePath = maskRelativePath
        self.sourceFingerprint = sourceFingerprint
        self.maskDigest = maskDigest
        self.visionRevision = visionRevision
        self.reconstructionNeeded = reconstructionNeeded
        self.redEyePupilRadius = redEyePupilRadius.map(Self.clampToUnit)
    }

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
        case radialRadiusY, brushStrokes, luminanceMin, luminanceMax
        case colorTargetHue, colorHueTolerance
        case maskRelativePath, sourceFingerprint, maskDigest, visionRevision, reconstructionNeeded
        case redEyePupilRadius
    }

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
            healMode: try container.decodeIfPresent(SpotHealMode.self, forKey: .healMode) ?? .heal,
            radialRadiusY: try container.decodeIfPresent(Double.self, forKey: .radialRadiusY),
            brushStrokes: try container.decodeIfPresent([BrushStroke].self, forKey: .brushStrokes) ?? [],
            luminanceMin: try container.decodeIfPresent(Double.self, forKey: .luminanceMin),
            luminanceMax: try container.decodeIfPresent(Double.self, forKey: .luminanceMax),
            colorTargetHue: try container.decodeIfPresent(Double.self, forKey: .colorTargetHue),
            colorHueTolerance: try container.decodeIfPresent(Double.self, forKey: .colorHueTolerance),
            maskRelativePath: try container.decodeIfPresent(String.self, forKey: .maskRelativePath),
            sourceFingerprint: try container.decodeIfPresent(String.self, forKey: .sourceFingerprint),
            maskDigest: try container.decodeIfPresent(String.self, forKey: .maskDigest),
            visionRevision: try container.decodeIfPresent(Int.self, forKey: .visionRevision),
            reconstructionNeeded: try container.decodeIfPresent(Bool.self, forKey: .reconstructionNeeded) ?? false,
            redEyePupilRadius: try container.decodeIfPresent(Double.self, forKey: .redEyePupilRadius)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(angleDegrees, forKey: .angleDegrees)
        try container.encode(range, forKey: .range)
        try container.encodeIfPresent(sourceX, forKey: .sourceX)
        try container.encodeIfPresent(sourceY, forKey: .sourceY)
        try container.encode(radius, forKey: .radius)
        try container.encode(feather, forKey: .feather)
        try container.encode(healMode, forKey: .healMode)
        try container.encodeIfPresent(radialRadiusY, forKey: .radialRadiusY)
        if !brushStrokes.isEmpty {
            try container.encode(brushStrokes, forKey: .brushStrokes)
        }
        try container.encodeIfPresent(luminanceMin, forKey: .luminanceMin)
        try container.encodeIfPresent(luminanceMax, forKey: .luminanceMax)
        try container.encodeIfPresent(colorTargetHue, forKey: .colorTargetHue)
        try container.encodeIfPresent(colorHueTolerance, forKey: .colorHueTolerance)
        try container.encodeIfPresent(maskRelativePath, forKey: .maskRelativePath)
        try container.encodeIfPresent(sourceFingerprint, forKey: .sourceFingerprint)
        try container.encodeIfPresent(maskDigest, forKey: .maskDigest)
        try container.encodeIfPresent(visionRevision, forKey: .visionRevision)
        if reconstructionNeeded {
            try container.encode(reconstructionNeeded, forKey: .reconstructionNeeded)
        }
        try container.encodeIfPresent(redEyePupilRadius, forKey: .redEyePupilRadius)
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
