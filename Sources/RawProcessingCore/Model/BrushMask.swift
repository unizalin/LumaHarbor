import Foundation

/// Errors raised when the portable adjustment-brush contract cannot be
/// rendered safely.  Brush data is deliberately strict: unlike the original
/// local-adjustment model, an invalid value is never silently clamped.
public enum BrushMaskValidationError: Error, Equatable, Sendable {
    case unsupportedRendererVersion(Int)
    case invalidCoordinate(String)
    case invalidStrokeParameter(String, Double)
    case invalidAdjustment(AdjustmentKind, Double)
}

/// A source-image coordinate.  The values are retained exactly until the
/// explicit `validated()` boundary, which lets an importer report malformed
/// data rather than changing the user's path behind their back.
public struct BrushMaskPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var pressure: Double?

    public init(x: Double, y: Double, pressure: Double? = nil) {
        self.x = x
        self.y = y
        self.pressure = pressure
    }

    public func validated() throws -> Self {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw BrushMaskValidationError.invalidCoordinate("point")
        }
        if let pressure, (!pressure.isFinite || !(0...1).contains(pressure)) {
            throw BrushMaskValidationError.invalidCoordinate("pressure")
        }
        return self
    }
}

/// One normalized source-coordinate path.  A path may contain one or more
/// points; points are kept in insertion order for deterministic rendering.
public struct BrushMaskPath: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var points: [BrushMaskPoint]

    public init(id: UUID = UUID(), points: [BrushMaskPoint] = []) {
        self.id = id
        self.points = points
    }

    public func validated() throws -> Self {
        for point in points { _ = try point.validated() }
        return self
    }
}

/// Paint/erase operation for a new adjustment brush.  This type is aliased
/// below under the names used by early experimental files so the importer can
/// consume both spellings without changing the in-memory contract.
public enum BrushMaskStrokeMode: String, Codable, Equatable, Hashable, Sendable {
    case paint
    case erase
}

public typealias BrushMaskOperation = BrushMaskStrokeMode
public typealias BrushMode = BrushMaskStrokeMode
public typealias BrushStrokeMode = BrushMaskStrokeMode
public typealias BrushAdjustmentPatch = BrushMaskPatch
public typealias BrushMaskAdjustments = BrushMaskPatch

/// A brush stroke with source-coordinate geometry and normalized brush
/// controls.  `path` is canonical; the `points` convenience initializer and
/// property make the experimental v3 flat-point spelling readable as well.
public struct BrushMaskStroke: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var path: BrushMaskPath
    public var mode: BrushMaskStrokeMode
    public var size: Double
    public var feather: Double
    public var flow: Double
    public var density: Double

    public var points: [BrushMaskPoint] {
        get { path.points }
        set { path.points = newValue }
    }

    /// Experimental v3 called the paint/erase discriminator `operation`.
    /// Keep both spellings available in memory while encoding the canonical
    /// `mode` key for new sidecars.
    public var operation: BrushMaskStrokeMode {
        get { mode }
        set { mode = newValue }
    }

    public init(
        id: UUID = UUID(),
        path: BrushMaskPath = BrushMaskPath(),
        mode: BrushMaskStrokeMode = .paint,
        size: Double = 0.05,
        feather: Double = 0,
        flow: Double = 1,
        density: Double = 1
    ) {
        self.id = id
        self.path = path
        self.mode = mode
        self.size = size
        self.feather = feather
        self.flow = flow
        self.density = density
    }

    public init(
        id: UUID = UUID(),
        points: [BrushMaskPoint],
        mode: BrushMaskStrokeMode = .paint,
        size: Double = 0.05,
        feather: Double = 0,
        flow: Double = 1,
        density: Double = 1
    ) {
        self.init(
            id: id,
            path: BrushMaskPath(points: points),
            mode: mode,
            size: size,
            feather: feather,
            flow: flow,
            density: density
        )
    }

    public func validated() throws -> Self {
        _ = try path.validated()
        for (name, value, range) in [
            ("size", size, 0.000_001...1.0),
            ("feather", feather, 0.0...1.0),
            ("flow", flow, 0.0...1.0),
            ("density", density, 0.0...1.0)
        ] {
            guard value.isFinite, range.contains(value) else {
                throw BrushMaskValidationError.invalidStrokeParameter(name, value)
            }
        }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, points, mode, operation, size, feather, flow, density
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let path = try container.decodeIfPresent(BrushMaskPath.self, forKey: .path)
            ?? BrushMaskPath(points: container.decodeIfPresent([BrushMaskPoint].self, forKey: .points) ?? [])
        let mode = try container.decodeIfPresent(BrushMaskStrokeMode.self, forKey: .mode)
            ?? container.decodeIfPresent(BrushMaskStrokeMode.self, forKey: .operation)
            ?? .paint
        self.init(
            id: id,
            path: path,
            mode: mode,
            size: try container.decodeIfPresent(Double.self, forKey: .size) ?? 0.05,
            feather: try container.decodeIfPresent(Double.self, forKey: .feather) ?? 0,
            flow: try container.decodeIfPresent(Double.self, forKey: .flow) ?? 1,
            density: try container.decodeIfPresent(Double.self, forKey: .density) ?? 1
        )
        _ = try validated()
    }

    public func encode(to encoder: Encoder) throws {
        _ = try validated()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(mode, forKey: .mode)
        try container.encode(size, forKey: .size)
        try container.encode(feather, forKey: .feather)
        try container.encode(flow, forKey: .flow)
        try container.encode(density, forKey: .density)
    }
}

/// Sparse local adjustment values applied by one new brush mask.
public struct BrushMaskPatch: Codable, Equatable, Hashable, Sendable {
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

    public static let neutral = BrushMaskPatch()

    public func validated() throws -> Self {
        let values: [(AdjustmentKind, Double?)] = [
            (.exposure, exposure), (.contrast, contrast), (.highlights, highlights),
            (.shadows, shadows), (.whites, whites), (.blacks, blacks),
            (.saturation, saturation), (.temperature, temperature), (.tint, tint)
        ]
        for (kind, value) in values {
            guard let value else { continue }
            guard AdjustmentCatalog.definition(for: kind).contains(value) else {
                throw BrushMaskValidationError.invalidAdjustment(kind, value)
            }
        }
        return self
    }

    public func validate() throws { _ = try validated() }

    public var isNeutral: Bool {
        exposure == nil && contrast == nil && highlights == nil && shadows == nil
            && whites == nil && blacks == nil && saturation == nil
            && temperature == nil && tint == nil
    }

    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks
        case saturation, temperature, tint
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
        _ = try validated()
    }

    public func encode(to encoder: Encoder) throws {
        _ = try validated()
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

/// Independent, ordered adjustment-brush model.  It intentionally coexists
/// with `LocalAdjustmentKind.brush`; the two arrays have different coordinate
/// and rendering contracts and must never be inferred from one another.
public struct BrushMask: Codable, Equatable, Hashable, Sendable, Identifiable {
    public static let currentRendererVersion = 1

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var rendererVersion: Int
    public var strokes: [BrushMaskStroke]
    public var adjustments: BrushMaskPatch

    /// Alternate label used by the earliest experimental v3 importer.
    public var brushStrokes: [BrushMaskStroke] {
        get { strokes }
        set { strokes = newValue }
    }

    public var enabled: Bool {
        get { isEnabled }
        set { isEnabled = newValue }
    }

    /// Alternate labels used by early importer drafts for the sparse patch.
    public var patch: BrushMaskPatch {
        get { adjustments }
        set { adjustments = newValue }
    }

    public var adjustmentPatch: BrushMaskPatch {
        get { adjustments }
        set { adjustments = newValue }
    }

    /// Compatibility projection for experimental files that called the
    /// ordered stroke collection `paths`.
    public var paths: [BrushMaskPath] {
        get { strokes.map { $0.path } }
        set { strokes = newValue.map { BrushMaskStroke(path: $0) } }
    }

    public init(
        id: UUID = UUID(),
        name: String = "",
        isEnabled: Bool = true,
        rendererVersion: Int = BrushMask.currentRendererVersion,
        strokes: [BrushMaskStroke] = [],
        adjustments: BrushMaskPatch = .neutral
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.rendererVersion = rendererVersion
        self.strokes = strokes
        self.adjustments = adjustments
    }

    public init(
        id: UUID = UUID(),
        name: String = "",
        isEnabled: Bool = true,
        rendererVersion: Int = BrushMask.currentRendererVersion,
        paths: [BrushMaskPath],
        adjustments: BrushMaskPatch = .neutral
    ) {
        self.init(
            id: id,
            name: name,
            isEnabled: isEnabled,
            rendererVersion: rendererVersion,
            strokes: paths.map { BrushMaskStroke(path: $0) },
            adjustments: adjustments
        )
    }

    public func validated() throws -> Self {
        guard rendererVersion == Self.currentRendererVersion else {
            throw BrushMaskValidationError.unsupportedRendererVersion(rendererVersion)
        }
        _ = try adjustments.validated()
        for stroke in strokes { _ = try stroke.validated() }
        return self
    }

    public func validate() throws { _ = try validated() }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, rendererVersion, strokes, paths, adjustments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let strokes = try container.decodeIfPresent([BrushMaskStroke].self, forKey: .strokes)
            ?? (container.decodeIfPresent([BrushMaskPath].self, forKey: .paths) ?? []).map { BrushMaskStroke(path: $0) }
        self.init(
            id: id,
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            rendererVersion: try container.decodeIfPresent(Int.self, forKey: .rendererVersion) ?? Self.currentRendererVersion,
            strokes: strokes,
            adjustments: try container.decodeIfPresent(BrushMaskPatch.self, forKey: .adjustments) ?? .neutral
        )
        _ = try validated()
    }

    public func encode(to encoder: Encoder) throws {
        _ = try validated()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if !name.isEmpty { try container.encode(name, forKey: .name) }
        if !isEnabled { try container.encode(isEnabled, forKey: .isEnabled) }
        try container.encode(rendererVersion, forKey: .rendererVersion)
        try container.encode(strokes, forKey: .strokes)
        try container.encode(adjustments, forKey: .adjustments)
    }
}
