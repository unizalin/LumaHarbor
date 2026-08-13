import Foundation

/// The non-destructive edit state for one photo.
///
/// Spec §5.1: this is a plain `Codable` value type. It must not reference Core
/// Image or any UI type — `PhotoLibraryCore` serialises it straight into the
/// portable sidecar, and a future LibRaw decoder has to consume the same struct.
public struct PhotoAdjustments: Codable, Equatable, Hashable, Sendable {
    public var exposure: Double
    public var temperature: Double
    public var tint: Double
    public var contrast: Double
    public var highlights: Double
    public var shadows: Double
    public var whites: Double
    public var blacks: Double
    public var vibrance: Double
    public var saturation: Double

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
        saturation: Double = 0
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
    }

    /// All sliders at their documented default — the "no edit applied" state.
    public static let neutral = PhotoAdjustments()

    public var isNeutral: Bool { self == .neutral }

    public subscript(kind: AdjustmentKind) -> Double {
        get {
            switch kind {
            case .exposure: return exposure
            case .temperature: return temperature
            case .tint: return tint
            case .contrast: return contrast
            case .highlights: return highlights
            case .shadows: return shadows
            case .whites: return whites
            case .blacks: return blacks
            case .vibrance: return vibrance
            case .saturation: return saturation
            }
        }
        set {
            let clamped = AdjustmentCatalog.definition(for: kind).clamp(newValue)
            switch kind {
            case .exposure: exposure = clamped
            case .temperature: temperature = clamped
            case .tint: tint = clamped
            case .contrast: contrast = clamped
            case .highlights: highlights = clamped
            case .shadows: shadows = clamped
            case .whites: whites = clamped
            case .blacks: blacks = clamped
            case .vibrance: vibrance = clamped
            case .saturation: saturation = clamped
            }
        }
    }

    /// Resets a single slider to its default, leaving the rest untouched.
    public func resetting(_ kind: AdjustmentKind) -> PhotoAdjustments {
        var copy = self
        copy[kind] = AdjustmentCatalog.definition(for: kind).defaultValue
        return copy
    }

    public func setting(_ kind: AdjustmentKind, to value: Double) -> PhotoAdjustments {
        var copy = self
        copy[kind] = value
        return copy
    }

    public func clamped() -> PhotoAdjustments {
        PhotoAdjustments(
            exposure: exposure, temperature: temperature, tint: tint, contrast: contrast,
            highlights: highlights, shadows: shadows, whites: whites, blacks: blacks,
            vibrance: vibrance, saturation: saturation
        )
    }

    /// Kinds that currently differ from their default.
    public var modifiedKinds: [AdjustmentKind] {
        AdjustmentKind.allCases.filter { kind in
            self[kind] != AdjustmentCatalog.definition(for: kind).defaultValue
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case exposure, temperature, tint, contrast, highlights
        case shadows, whites, blacks, vibrance, saturation
    }

    /// Missing keys fall back to the catalogue default and out-of-range values
    /// are clamped. A sidecar written by a future minor version — or one a user
    /// hand-edited — degrades instead of producing a broken render.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func value(_ key: CodingKeys, _ kind: AdjustmentKind) throws -> Double {
            let definition = AdjustmentCatalog.definition(for: kind)
            let raw = try container.decodeIfPresent(Double.self, forKey: key)
            return definition.clamp(raw ?? definition.defaultValue)
        }

        self.exposure = try value(.exposure, .exposure)
        self.temperature = try value(.temperature, .temperature)
        self.tint = try value(.tint, .tint)
        self.contrast = try value(.contrast, .contrast)
        self.highlights = try value(.highlights, .highlights)
        self.shadows = try value(.shadows, .shadows)
        self.whites = try value(.whites, .whites)
        self.blacks = try value(.blacks, .blacks)
        self.vibrance = try value(.vibrance, .vibrance)
        self.saturation = try value(.saturation, .saturation)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Every key is always written, so a sidecar is self-describing even if a
        // later version changes a default.
        try container.encode(exposure, forKey: .exposure)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(tint, forKey: .tint)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(shadows, forKey: .shadows)
        try container.encode(whites, forKey: .whites)
        try container.encode(blacks, forKey: .blacks)
        try container.encode(vibrance, forKey: .vibrance)
        try container.encode(saturation, forKey: .saturation)
    }
}
