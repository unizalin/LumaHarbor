import Foundation
import RawProcessingCore

/// Spec §5.2: a `Double?` leaf distinguishes "field absent, keep current value
/// on merge" from "field explicitly present, even if numerically equal to the
/// default". `AdjustmentPatch` therefore cannot be a plain `PhotoAdjustments`.
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

    public init(
        exposure: Double? = nil, temperature: Double? = nil, tint: Double? = nil,
        contrast: Double? = nil, highlights: Double? = nil, shadows: Double? = nil,
        whites: Double? = nil, blacks: Double? = nil, vibrance: Double? = nil,
        saturation: Double? = nil
    ) {
        self.exposure = exposure
        self.temperature = temperature
        self.tint = tint
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.vibrance = vibrance
        self.saturation = saturation
    }

    public var isEmpty: Bool {
        exposure == nil && temperature == nil && tint == nil && contrast == nil
            && highlights == nil && shadows == nil && whites == nil && blacks == nil
            && vibrance == nil && saturation == nil
    }

    func canonicalized() -> BasicAdjustmentPatch? { isEmpty ? nil : self }
}

/// One HSL band's optional hue/saturation/luminance leaves.
public struct HSLBandPatch: Codable, Equatable, Sendable {
    public var hue: Double?
    public var saturation: Double?
    public var luminance: Double?

    public init(hue: Double? = nil, saturation: Double? = nil, luminance: Double? = nil) {
        self.hue = hue
        self.saturation = saturation
        self.luminance = luminance
    }

    public var isEmpty: Bool { hue == nil && saturation == nil && luminance == nil }

    func canonicalized() -> HSLBandPatch? { isEmpty ? nil : self }
}

public struct HSLAdjustmentPatch: Codable, Equatable, Sendable {
    // `didSet` re-canonicalizes on any mutation *after* construction (e.g.
    // `patch.hsl?.red = HSLBandPatch()`) -- Swift does not run `didSet` during
    // a type's own initializer, including its synthesized `Decodable` one, so
    // `init` and `init(from:)` below canonicalize explicitly instead.
    public var red: HSLBandPatch? { didSet { red = red?.canonicalized() } }
    public var orange: HSLBandPatch? { didSet { orange = orange?.canonicalized() } }
    public var yellow: HSLBandPatch? { didSet { yellow = yellow?.canonicalized() } }
    public var green: HSLBandPatch? { didSet { green = green?.canonicalized() } }
    public var aqua: HSLBandPatch? { didSet { aqua = aqua?.canonicalized() } }
    public var blue: HSLBandPatch? { didSet { blue = blue?.canonicalized() } }
    public var purple: HSLBandPatch? { didSet { purple = purple?.canonicalized() } }
    public var magenta: HSLBandPatch? { didSet { magenta = magenta?.canonicalized() } }

    public init(
        red: HSLBandPatch? = nil, orange: HSLBandPatch? = nil, yellow: HSLBandPatch? = nil,
        green: HSLBandPatch? = nil, aqua: HSLBandPatch? = nil, blue: HSLBandPatch? = nil,
        purple: HSLBandPatch? = nil, magenta: HSLBandPatch? = nil
    ) {
        self.red = red?.canonicalized()
        self.orange = orange?.canonicalized()
        self.yellow = yellow?.canonicalized()
        self.green = green?.canonicalized()
        self.aqua = aqua?.canonicalized()
        self.blue = blue?.canonicalized()
        self.purple = purple?.canonicalized()
        self.magenta = magenta?.canonicalized()
    }

    public var isEmpty: Bool {
        red == nil && orange == nil && yellow == nil && green == nil
            && aqua == nil && blue == nil && purple == nil && magenta == nil
    }

    func canonicalized() -> HSLAdjustmentPatch? { isEmpty ? nil : self }

    private enum CodingKeys: String, CodingKey {
        case red, orange, yellow, green, aqua, blue, purple, magenta
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            red: try container.decodeIfPresent(HSLBandPatch.self, forKey: .red),
            orange: try container.decodeIfPresent(HSLBandPatch.self, forKey: .orange),
            yellow: try container.decodeIfPresent(HSLBandPatch.self, forKey: .yellow),
            green: try container.decodeIfPresent(HSLBandPatch.self, forKey: .green),
            aqua: try container.decodeIfPresent(HSLBandPatch.self, forKey: .aqua),
            blue: try container.decodeIfPresent(HSLBandPatch.self, forKey: .blue),
            purple: try container.decodeIfPresent(HSLBandPatch.self, forKey: .purple),
            magenta: try container.decodeIfPresent(HSLBandPatch.self, forKey: .magenta)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(red, forKey: .red)
        try container.encodeIfPresent(orange, forKey: .orange)
        try container.encodeIfPresent(yellow, forKey: .yellow)
        try container.encodeIfPresent(green, forKey: .green)
        try container.encodeIfPresent(aqua, forKey: .aqua)
        try container.encodeIfPresent(blue, forKey: .blue)
        try container.encodeIfPresent(purple, forKey: .purple)
        try container.encodeIfPresent(magenta, forKey: .magenta)
    }
}

public struct SplitToningPatch: Codable, Equatable, Sendable {
    public var shadowHue: Double?
    public var shadowSaturation: Double?
    public var highlightHue: Double?
    public var highlightSaturation: Double?
    public var balance: Double?

    public init(
        shadowHue: Double? = nil, shadowSaturation: Double? = nil,
        highlightHue: Double? = nil, highlightSaturation: Double? = nil,
        balance: Double? = nil
    ) {
        self.shadowHue = shadowHue
        self.shadowSaturation = shadowSaturation
        self.highlightHue = highlightHue
        self.highlightSaturation = highlightSaturation
        self.balance = balance
    }

    public var isEmpty: Bool {
        shadowHue == nil && shadowSaturation == nil && highlightHue == nil
            && highlightSaturation == nil && balance == nil
    }

    func canonicalized() -> SplitToningPatch? { isEmpty ? nil : self }
}

public struct SharpeningPatch: Codable, Equatable, Sendable {
    public var amount: Double?
    public var radius: Double?
    public var detail: Double?
    public var masking: Double?

    public init(amount: Double? = nil, radius: Double? = nil, detail: Double? = nil, masking: Double? = nil) {
        self.amount = amount
        self.radius = radius
        self.detail = detail
        self.masking = masking
    }

    public var isEmpty: Bool { amount == nil && radius == nil && detail == nil && masking == nil }

    func canonicalized() -> SharpeningPatch? { isEmpty ? nil : self }
}

public struct NoiseReductionPatch: Codable, Equatable, Sendable {
    public var luminanceAmount: Double?
    public var luminanceDetail: Double?
    public var colorAmount: Double?
    public var colorDetail: Double?

    public init(
        luminanceAmount: Double? = nil, luminanceDetail: Double? = nil,
        colorAmount: Double? = nil, colorDetail: Double? = nil
    ) {
        self.luminanceAmount = luminanceAmount
        self.luminanceDetail = luminanceDetail
        self.colorAmount = colorAmount
        self.colorDetail = colorDetail
    }

    public var isEmpty: Bool {
        luminanceAmount == nil && luminanceDetail == nil && colorAmount == nil && colorDetail == nil
    }

    func canonicalized() -> NoiseReductionPatch? { isEmpty ? nil : self }
}

public struct VignettePatch: Codable, Equatable, Sendable {
    public var amount: Double?
    public var midpoint: Double?
    public var roundness: Double?
    public var feather: Double?

    public init(amount: Double? = nil, midpoint: Double? = nil, roundness: Double? = nil, feather: Double? = nil) {
        self.amount = amount
        self.midpoint = midpoint
        self.roundness = roundness
        self.feather = feather
    }

    public var isEmpty: Bool { amount == nil && midpoint == nil && roundness == nil && feather == nil }

    func canonicalized() -> VignettePatch? { isEmpty ? nil : self }
}

public struct GrainPatch: Codable, Equatable, Sendable {
    public var amount: Double?
    public var size: Double?
    public var roughness: Double?

    public init(amount: Double? = nil, size: Double? = nil, roughness: Double? = nil) {
        self.amount = amount
        self.size = size
        self.roughness = roughness
    }

    public var isEmpty: Bool { amount == nil && size == nil && roughness == nil }

    func canonicalized() -> GrainPatch? { isEmpty ? nil : self }
}

/// A partial, mergeable set of `PhotoAdjustments` leaves (spec §5.2).
///
/// Every nested patch canonicalizes an all-nil value to `nil` on init and on
/// decode, so there is exactly one representation of "nothing set here" —
/// never two ways (empty struct vs. absent key) to say the same thing.
public struct AdjustmentPatch: Codable, Equatable, Sendable {
    // See the equivalent comment on `HSLAdjustmentPatch`: `didSet` catches
    // post-construction mutation (e.g. `patch.basic = BasicAdjustmentPatch()`);
    // `init`/`init(from:)` canonicalize explicitly since `didSet` does not run
    // during a type's own initializer.
    public var basic: BasicAdjustmentPatch? { didSet { basic = basic?.canonicalized() } }
    /// Whole-value leaf: absent means "don't touch the curve", present
    /// (including `.neutral`) means "set the curve to exactly this".
    public var advancedToneCurve: AdvancedToneCurve?
    public var hsl: HSLAdjustmentPatch? { didSet { hsl = hsl?.canonicalized() } }
    public var splitToning: SplitToningPatch? { didSet { splitToning = splitToning?.canonicalized() } }
    public var sharpening: SharpeningPatch? { didSet { sharpening = sharpening?.canonicalized() } }
    public var noiseReduction: NoiseReductionPatch? { didSet { noiseReduction = noiseReduction?.canonicalized() } }
    public var vignette: VignettePatch? { didSet { vignette = vignette?.canonicalized() } }
    public var grain: GrainPatch? { didSet { grain = grain?.canonicalized() } }

    public init(
        basic: BasicAdjustmentPatch? = nil,
        advancedToneCurve: AdvancedToneCurve? = nil,
        hsl: HSLAdjustmentPatch? = nil,
        splitToning: SplitToningPatch? = nil,
        sharpening: SharpeningPatch? = nil,
        noiseReduction: NoiseReductionPatch? = nil,
        vignette: VignettePatch? = nil,
        grain: GrainPatch? = nil
    ) {
        self.basic = basic?.canonicalized()
        self.advancedToneCurve = advancedToneCurve
        self.hsl = hsl?.canonicalized()
        self.splitToning = splitToning?.canonicalized()
        self.sharpening = sharpening?.canonicalized()
        self.noiseReduction = noiseReduction?.canonicalized()
        self.vignette = vignette?.canonicalized()
        self.grain = grain?.canonicalized()
    }

    public var isEmpty: Bool {
        basic == nil && advancedToneCurve == nil && hsl == nil && splitToning == nil
            && sharpening == nil && noiseReduction == nil && vignette == nil && grain == nil
    }

    /// Whether `field` has an explicit value in this patch.
    public func contains(_ field: AdjustmentFieldID) -> Bool {
        scalarValue(for: field) != nil || (field == .advancedToneCurve && advancedToneCurve != nil)
    }

    /// The explicit value for a scalar leaf, or `nil` if `field` is a
    /// whole-value leaf (`advancedToneCurve`) or simply absent.
    public func scalarValue(for field: AdjustmentFieldID) -> Double? {
        switch field {
        case .basicExposure: return basic?.exposure
        case .basicTemperature: return basic?.temperature
        case .basicTint: return basic?.tint
        case .basicContrast: return basic?.contrast
        case .basicHighlights: return basic?.highlights
        case .basicShadows: return basic?.shadows
        case .basicWhites: return basic?.whites
        case .basicBlacks: return basic?.blacks
        case .basicVibrance: return basic?.vibrance
        case .basicSaturation: return basic?.saturation
        case .advancedToneCurve: return nil
        case .hslRedHue: return hsl?.red?.hue
        case .hslRedSaturation: return hsl?.red?.saturation
        case .hslRedLuminance: return hsl?.red?.luminance
        case .hslOrangeHue: return hsl?.orange?.hue
        case .hslOrangeSaturation: return hsl?.orange?.saturation
        case .hslOrangeLuminance: return hsl?.orange?.luminance
        case .hslYellowHue: return hsl?.yellow?.hue
        case .hslYellowSaturation: return hsl?.yellow?.saturation
        case .hslYellowLuminance: return hsl?.yellow?.luminance
        case .hslGreenHue: return hsl?.green?.hue
        case .hslGreenSaturation: return hsl?.green?.saturation
        case .hslGreenLuminance: return hsl?.green?.luminance
        case .hslAquaHue: return hsl?.aqua?.hue
        case .hslAquaSaturation: return hsl?.aqua?.saturation
        case .hslAquaLuminance: return hsl?.aqua?.luminance
        case .hslBlueHue: return hsl?.blue?.hue
        case .hslBlueSaturation: return hsl?.blue?.saturation
        case .hslBlueLuminance: return hsl?.blue?.luminance
        case .hslPurpleHue: return hsl?.purple?.hue
        case .hslPurpleSaturation: return hsl?.purple?.saturation
        case .hslPurpleLuminance: return hsl?.purple?.luminance
        case .hslMagentaHue: return hsl?.magenta?.hue
        case .hslMagentaSaturation: return hsl?.magenta?.saturation
        case .hslMagentaLuminance: return hsl?.magenta?.luminance
        case .splitToningShadowHue: return splitToning?.shadowHue
        case .splitToningShadowSaturation: return splitToning?.shadowSaturation
        case .splitToningHighlightHue: return splitToning?.highlightHue
        case .splitToningHighlightSaturation: return splitToning?.highlightSaturation
        case .splitToningBalance: return splitToning?.balance
        case .sharpeningAmount: return sharpening?.amount
        case .sharpeningRadius: return sharpening?.radius
        case .sharpeningDetail: return sharpening?.detail
        case .sharpeningMasking: return sharpening?.masking
        case .noiseReductionLuminanceAmount: return noiseReduction?.luminanceAmount
        case .noiseReductionLuminanceDetail: return noiseReduction?.luminanceDetail
        case .noiseReductionColorAmount: return noiseReduction?.colorAmount
        case .noiseReductionColorDetail: return noiseReduction?.colorDetail
        case .vignetteAmount: return vignette?.amount
        case .vignetteMidpoint: return vignette?.midpoint
        case .vignetteRoundness: return vignette?.roundness
        case .vignetteFeather: return vignette?.feather
        case .grainAmount: return grain?.amount
        case .grainSize: return grain?.size
        case .grainRoughness: return grain?.roughness
        }
    }

    private enum CodingKeys: String, CodingKey {
        case basic, advancedToneCurve, hsl, splitToning, sharpening, noiseReduction, vignette, grain
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            basic: try container.decodeIfPresent(BasicAdjustmentPatch.self, forKey: .basic),
            advancedToneCurve: try container.decodeIfPresent(AdvancedToneCurve.self, forKey: .advancedToneCurve),
            hsl: try container.decodeIfPresent(HSLAdjustmentPatch.self, forKey: .hsl),
            splitToning: try container.decodeIfPresent(SplitToningPatch.self, forKey: .splitToning),
            sharpening: try container.decodeIfPresent(SharpeningPatch.self, forKey: .sharpening),
            noiseReduction: try container.decodeIfPresent(NoiseReductionPatch.self, forKey: .noiseReduction),
            vignette: try container.decodeIfPresent(VignettePatch.self, forKey: .vignette),
            grain: try container.decodeIfPresent(GrainPatch.self, forKey: .grain)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(basic, forKey: .basic)
        try container.encodeIfPresent(advancedToneCurve, forKey: .advancedToneCurve)
        try container.encodeIfPresent(hsl, forKey: .hsl)
        try container.encodeIfPresent(splitToning, forKey: .splitToning)
        try container.encodeIfPresent(sharpening, forKey: .sharpening)
        try container.encodeIfPresent(noiseReduction, forKey: .noiseReduction)
        try container.encodeIfPresent(vignette, forKey: .vignette)
        try container.encodeIfPresent(grain, forKey: .grain)
    }
}
