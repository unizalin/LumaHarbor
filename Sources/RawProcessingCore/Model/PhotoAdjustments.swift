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
    public var advancedToneCurve: AdvancedToneCurve
    public var hsl: HSLAdjustments
    public var splitToning: SplitToning
    public var sharpening: Sharpening
    public var noiseReduction: NoiseReduction
    public var vignette: Vignette
    public var grain: Grain
    public var geometry: GeometryAdjustments
    /// Ordered — later entries composite on top of earlier ones once Task
    /// 4.2/4.4 wire up rendering. Order is significant and must survive a
    /// round trip, unlike every other field here which is a single value.
    public var localAdjustments: [LocalAdjustment]
    public var presence: PresenceAdjustments
    public var colorGrading: ColorGradingAdjustments
    public var monochrome: MonochromeAdjustments
    public var renderingProfile: RenderingProfileSelection
    public var lensCorrection: LensCorrectionAdjustments

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
        grain: Grain = .neutral,
        geometry: GeometryAdjustments = .neutral,
        localAdjustments: [LocalAdjustment] = [],
        presence: PresenceAdjustments = .neutral,
        colorGrading: ColorGradingAdjustments = .neutral,
        monochrome: MonochromeAdjustments = .neutral,
        renderingProfile: RenderingProfileSelection = .neutral,
        lensCorrection: LensCorrectionAdjustments = .neutral
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
        self.geometry = geometry
        self.localAdjustments = localAdjustments
        self.presence = presence
        self.colorGrading = colorGrading
        self.monochrome = monochrome
        self.renderingProfile = renderingProfile
        self.lensCorrection = lensCorrection
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
            vibrance: vibrance, saturation: saturation,
            advancedToneCurve: advancedToneCurve, hsl: hsl, splitToning: splitToning,
            sharpening: sharpening, noiseReduction: noiseReduction, vignette: vignette,
            grain: grain, geometry: geometry, localAdjustments: localAdjustments,
            presence: presence, colorGrading: colorGrading, monochrome: monochrome,
            renderingProfile: renderingProfile, lensCorrection: lensCorrection
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
        case advancedToneCurve, hsl, splitToning, sharpening, noiseReduction, vignette, grain
        case geometry
        case localAdjustments
        case presence, colorGrading, monochrome, renderingProfile, lensCorrection
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
        self.advancedToneCurve = try container.decodeIfPresent(AdvancedToneCurve.self, forKey: .advancedToneCurve) ?? .neutral
        self.hsl = try container.decodeIfPresent(HSLAdjustments.self, forKey: .hsl) ?? .neutral
        self.splitToning = try container.decodeIfPresent(SplitToning.self, forKey: .splitToning) ?? .neutral
        self.sharpening = try container.decodeIfPresent(Sharpening.self, forKey: .sharpening) ?? .neutral
        self.noiseReduction = try container.decodeIfPresent(NoiseReduction.self, forKey: .noiseReduction) ?? .neutral
        self.vignette = try container.decodeIfPresent(Vignette.self, forKey: .vignette) ?? .neutral
        self.grain = try container.decodeIfPresent(Grain.self, forKey: .grain) ?? .neutral
        self.geometry = try container.decodeIfPresent(GeometryAdjustments.self, forKey: .geometry) ?? .neutral
        // A sidecar written before Phase 4 has no "localAdjustments" key at
        // all — the same absent-key-means-empty convention `geometry`
        // itself used when it was the newly added field in Phase 2.
        self.localAdjustments = try container.decodeIfPresent([LocalAdjustment].self, forKey: .localAdjustments) ?? []
        // A sidecar written before P4 has none of these five keys.
        self.presence = try container.decodeIfPresent(PresenceAdjustments.self, forKey: .presence) ?? .neutral
        self.colorGrading = try container.decodeIfPresent(ColorGradingAdjustments.self, forKey: .colorGrading) ?? .neutral
        self.monochrome = try container.decodeIfPresent(MonochromeAdjustments.self, forKey: .monochrome) ?? .neutral
        self.renderingProfile = try container.decodeIfPresent(RenderingProfileSelection.self, forKey: .renderingProfile) ?? .neutral
        self.lensCorrection = try container.decodeIfPresent(LensCorrectionAdjustments.self, forKey: .lensCorrection) ?? .neutral
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
        try container.encode(advancedToneCurve, forKey: .advancedToneCurve)
        try container.encode(hsl, forKey: .hsl)
        try container.encode(splitToning, forKey: .splitToning)
        try container.encode(sharpening, forKey: .sharpening)
        try container.encode(noiseReduction, forKey: .noiseReduction)
        try container.encode(vignette, forKey: .vignette)
        try container.encode(grain, forKey: .grain)
        try container.encode(geometry, forKey: .geometry)
        try container.encode(localAdjustments, forKey: .localAdjustments)
        try container.encode(presence, forKey: .presence)
        try container.encode(colorGrading, forKey: .colorGrading)
        try container.encode(monochrome, forKey: .monochrome)
        try container.encode(renderingProfile, forKey: .renderingProfile)
        try container.encode(lensCorrection, forKey: .lensCorrection)
    }
}
