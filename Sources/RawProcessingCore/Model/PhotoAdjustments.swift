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
    /// Independent source-coordinate adjustment brushes. This intentionally
    /// remains separate from the legacy `LocalAdjustmentKind.brush` model.
    public var brushMasks: [BrushMask]
    /// Source-shape bookkeeping used by experimental v3 curation migration.
    /// It is deliberately excluded from value equality and encoding.
    public private(set) var hasBrushMasksField: Bool
    public var presence: PresenceAdjustments
    public var colorGrading: ColorGradingAdjustments
    public var monochrome: MonochromeAdjustments
    public var renderingProfile: RenderingProfileSelection
    /// The requested Adobe Camera Raw profile, kept separate from the
    /// app-owned creative rendering profile.
    public var rawCameraProfile: RawCameraProfileSelection
    public var lensCorrection: LensCorrectionAdjustments
    /// Identifies the versioned renderer policy required by an imported edit.
    /// Native edits stay on the existing path; older sidecars decode as native.
    public var rawRenderingCompatibility: RawRenderingCompatibility

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
        brushMasks: [BrushMask] = [],
        presence: PresenceAdjustments = .neutral,
        colorGrading: ColorGradingAdjustments = .neutral,
        monochrome: MonochromeAdjustments = .neutral,
        renderingProfile: RenderingProfileSelection = .neutral,
        rawCameraProfile: RawCameraProfileSelection = RawCameraProfileSelection(),
        lensCorrection: LensCorrectionAdjustments = .neutral,
        rawRenderingCompatibility: RawRenderingCompatibility = .native
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
        self.brushMasks = brushMasks
        self.hasBrushMasksField = true
        self.presence = presence
        self.colorGrading = colorGrading
        self.monochrome = monochrome
        self.renderingProfile = renderingProfile
        self.rawCameraProfile = rawCameraProfile
        self.lensCorrection = lensCorrection
        self.rawRenderingCompatibility = rawRenderingCompatibility
    }

    /// All sliders at their documented default with the native rendering policy.
    public static let neutral = PhotoAdjustments()

    public static func == (lhs: PhotoAdjustments, rhs: PhotoAdjustments) -> Bool {
        lhs.exposure == rhs.exposure
            && lhs.temperature == rhs.temperature
            && lhs.tint == rhs.tint
            && lhs.contrast == rhs.contrast
            && lhs.highlights == rhs.highlights
            && lhs.shadows == rhs.shadows
            && lhs.whites == rhs.whites
            && lhs.blacks == rhs.blacks
            && lhs.vibrance == rhs.vibrance
            && lhs.saturation == rhs.saturation
            && lhs.advancedToneCurve == rhs.advancedToneCurve
            && lhs.hsl == rhs.hsl
            && lhs.splitToning == rhs.splitToning
            && lhs.sharpening == rhs.sharpening
            && lhs.noiseReduction == rhs.noiseReduction
            && lhs.vignette == rhs.vignette
            && lhs.grain == rhs.grain
            && lhs.geometry == rhs.geometry
            && lhs.localAdjustments == rhs.localAdjustments
            && lhs.brushMasks == rhs.brushMasks
            && lhs.presence == rhs.presence
            && lhs.colorGrading == rhs.colorGrading
            && lhs.monochrome == rhs.monochrome
            && lhs.renderingProfile == rhs.renderingProfile
            && lhs.rawCameraProfile == rhs.rawCameraProfile
            && lhs.lensCorrection == rhs.lensCorrection
            && lhs.rawRenderingCompatibility == rhs.rawRenderingCompatibility
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(exposure)
        hasher.combine(temperature)
        hasher.combine(tint)
        hasher.combine(contrast)
        hasher.combine(highlights)
        hasher.combine(shadows)
        hasher.combine(whites)
        hasher.combine(blacks)
        hasher.combine(vibrance)
        hasher.combine(saturation)
        hasher.combine(advancedToneCurve)
        hasher.combine(hsl)
        hasher.combine(splitToning)
        hasher.combine(sharpening)
        hasher.combine(noiseReduction)
        hasher.combine(vignette)
        hasher.combine(grain)
        hasher.combine(geometry)
        hasher.combine(localAdjustments)
        hasher.combine(brushMasks)
        hasher.combine(presence)
        hasher.combine(colorGrading)
        hasher.combine(monochrome)
        hasher.combine(renderingProfile)
        hasher.combine(rawCameraProfile)
        hasher.combine(lensCorrection)
        hasher.combine(rawRenderingCompatibility)
    }

    /// All sliders at their documented default under the requested baseline policy.
    public static func neutral(using policy: RawRenderingCompatibility) -> Self {
        Self(rawRenderingCompatibility: policy)
    }

    /// True when an editable adjustment differs from its documented default.
    /// The source rendering policy remains part of the full value identity, but
    /// is not itself a user edit or a dirty-state signal.
    public var hasUserAdjustments: Bool {
        var valueWithoutPolicy = self
        valueWithoutPolicy.rawRenderingCompatibility = .native
        return valueWithoutPolicy != .neutral
    }

    /// Retained for source compatibility with existing edit-state callers.
    public var isNeutral: Bool { !hasUserAdjustments }

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
        var copy = PhotoAdjustments(
            exposure: exposure, temperature: 0, tint: tint, contrast: contrast,
            highlights: highlights, shadows: shadows, whites: whites, blacks: blacks,
            vibrance: vibrance, saturation: saturation,
            advancedToneCurve: advancedToneCurve, hsl: hsl, splitToning: splitToning,
            sharpening: sharpening, noiseReduction: noiseReduction, vignette: vignette,
            grain: grain, geometry: geometry, localAdjustments: localAdjustments,
            brushMasks: brushMasks,
            presence: presence, colorGrading: colorGrading, monochrome: monochrome,
            renderingProfile: renderingProfile, rawCameraProfile: rawCameraProfile,
            lensCorrection: lensCorrection,
            rawRenderingCompatibility: rawRenderingCompatibility
        )
        // A finite out-of-range temperature may be a legacy sidecar value.
        // Preserve it until the baseline-aware resolver sees the actual RAW;
        // only non-finite corruption collapses to neutral here.
        copy.temperature = temperature.isFinite
            ? temperature
            : AdjustmentCatalog.definition(for: .temperature).defaultValue
        return copy
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
        case localAdjustments, brushMasks
        case presence, colorGrading, monochrome, renderingProfile, lensCorrection
        case rawCameraProfile
        case rawRenderingCompatibility
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
        // Temperature is decoder-relative; its safety depends on the RAW
        // baseline, which is unavailable while decoding the sidecar. Preserve
        // every finite legacy value and defer clamping to the resolver.
        let temperatureDefinition = AdjustmentCatalog.definition(for: .temperature)
        let rawTemperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        self.temperature = rawTemperature?.isFinite == true
            ? rawTemperature!
            : temperatureDefinition.defaultValue
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
        self.hasBrushMasksField = container.contains(.brushMasks)
        // Sidecars before v5 have no independent adjustment-brush collection.
        // When present, BrushMask decoding enforces the strict v1 contract.
        self.brushMasks = try container.decodeIfPresent([BrushMask].self, forKey: .brushMasks) ?? []
        // A sidecar written before P4 has none of these five keys.
        self.presence = try container.decodeIfPresent(PresenceAdjustments.self, forKey: .presence) ?? .neutral
        self.colorGrading = try container.decodeIfPresent(ColorGradingAdjustments.self, forKey: .colorGrading) ?? .neutral
        self.monochrome = try container.decodeIfPresent(MonochromeAdjustments.self, forKey: .monochrome) ?? .neutral
        self.renderingProfile = try container.decodeIfPresent(RenderingProfileSelection.self, forKey: .renderingProfile) ?? .neutral
        self.rawCameraProfile = try container.decodeIfPresent(RawCameraProfileSelection.self, forKey: .rawCameraProfile) ?? RawCameraProfileSelection()
        self.lensCorrection = try container.decodeIfPresent(LensCorrectionAdjustments.self, forKey: .lensCorrection) ?? .neutral
        self.rawRenderingCompatibility = try container.decodeIfPresent(RawRenderingCompatibility.self, forKey: .rawRenderingCompatibility) ?? .native
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
        try container.encode(brushMasks, forKey: .brushMasks)
        try container.encode(presence, forKey: .presence)
        try container.encode(colorGrading, forKey: .colorGrading)
        try container.encode(monochrome, forKey: .monochrome)
        try container.encode(renderingProfile, forKey: .renderingProfile)
        try container.encode(rawCameraProfile, forKey: .rawCameraProfile)
        try container.encode(lensCorrection, forKey: .lensCorrection)
        try container.encode(rawRenderingCompatibility, forKey: .rawRenderingCompatibility)
    }
}
