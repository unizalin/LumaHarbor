import Foundation

/// Spec §7: how reliably one Camera Raw property maps onto LumaHarbor.
public enum XMPCompatibilityLevel: String, Codable, Equatable, Sendable {
    /// Reliably convertible to LumaHarbor semantics, editable, round-trips.
    case native
    /// Applies, but the algorithm differs from Adobe's -- shown as a flag in
    /// import summaries, and always accompanied by a fixture-based tolerance
    /// test (spec §7, §12.2).
    case approximate
    /// Recognised but not applied and never shown as supported (spec §7).
    case preserved
}

/// One namespace-qualified Camera Raw property this codebase knows how to
/// convert to and from a single `AdjustmentPatch` scalar leaf.
///
/// Everything else encountered in a real document -- crop, masks, camera
/// profile, per-channel tone curves, sharpening detail/masking, independent
/// noise-reduction channels, and any unrecognised namespace -- is *not* in
/// this table by design: `XMPImporter` treats "not in the table" as the
/// uniform, correct definition of `.preserved` (spec §7's own examples),
/// rather than needing a second parallel list of "known but unsupported"
/// properties.
public struct XMPMapping: Sendable {
    public var propertyID: XMPPropertyID
    public var field: AdjustmentFieldID
    public var level: XMPCompatibilityLevel
    /// Converts the raw XMP value into the `Double` this field's slot in
    /// `AdjustmentPatch` stores, already unit-converted where the ranges
    /// differ (e.g. Adobe's 0...100 sharpness vs. LumaHarbor's 0...150). Not
    /// clamped here -- spec §7: "超範圍原值保留" -- clamping happens only when
    /// `PresetApplicator` applies the patch to a photo.
    public var importScalar: @Sendable (XMPValue) throws -> Double
    /// `nil` when this leaf has no reliable reverse mapping (spec §7: a
    /// single-direction converter must be flagged, never silently dropped,
    /// at export time).
    public var exportScalar: (@Sendable (Double) throws -> XMPValue)?

    public init(
        propertyID: XMPPropertyID,
        field: AdjustmentFieldID,
        level: XMPCompatibilityLevel,
        importScalar: @escaping @Sendable (XMPValue) throws -> Double,
        exportScalar: (@Sendable (Double) throws -> XMPValue)? = nil
    ) {
        self.propertyID = propertyID
        self.field = field
        self.level = level
        self.importScalar = importScalar
        self.exportScalar = exportScalar
    }
}

/// Declarative, namespace-aware table from Adobe Camera Raw ("Process 2012"
/// family, `crs:ProcessVersion` >= 6.7 -- Adobe's own documented version
/// number for the introduction of Process 2012, ns.adobe.com/camera-raw
/// -settings/1.0/) properties to `AdjustmentPatch` leaves.
///
/// Property names and types below are grounded in Adobe/exiv2's published
/// `crs:` namespace reference, not guessed from convention (spec's
/// instruction: don't infer semantics from a field name alone). Legacy
/// (pre-2012, "PV2003/2010") property names are deliberately *not* mapped:
/// Adobe changed both the property names and the underlying algorithm at
/// Process 2012, and guessing an equivalence for the older names without a
/// real fixture to verify against would be exactly the kind of unverified
/// claim the spec forbids. They fall through to `.preserved` like any other
/// unrecognised property.
public struct XMPMappingRegistry: Sendable {
    /// Adobe's own version number for the introduction of "Process 2012"
    /// (Lightroom 4 / Camera Raw 7). `crs:ProcessVersion` below this is a
    /// process family this registry does not have verified mappings for.
    public static let minimumRecognizedProcessVersion = 6.7

    public let mappings: [XMPMapping]
    private let byPropertyID: [XMPPropertyID: XMPMapping]
    private let byField: [AdjustmentFieldID: XMPMapping]

    public init(mappings: [XMPMapping]) {
        var byID: [XMPPropertyID: XMPMapping] = [:]
        var byField: [AdjustmentFieldID: XMPMapping] = [:]
        for mapping in mappings {
            precondition(byID[mapping.propertyID] == nil, "Duplicate mapping for \(mapping.propertyID)")
            byID[mapping.propertyID] = mapping
            precondition(byField[mapping.field] == nil, "Duplicate mapping for \(mapping.field)")
            byField[mapping.field] = mapping
        }
        self.mappings = mappings
        self.byPropertyID = byID
        self.byField = byField
    }

    public func mapping(for propertyID: XMPPropertyID) -> XMPMapping? {
        byPropertyID[propertyID]
    }

    public func mapping(for field: AdjustmentFieldID) -> XMPMapping? {
        byField[field]
    }

    /// Whether a `crs:ProcessVersion` string is one this registry has
    /// verified mappings for. `nil` (property absent) and unparsable strings
    /// are both "not recognised" -- spec §7: never guess.
    public static func isRecognizedProcessVersion(_ processVersion: String?) -> Bool {
        guard let processVersion, let value = Double(processVersion) else { return false }
        return value >= minimumRecognizedProcessVersion
    }

    public static let `default` = XMPMappingRegistry(mappings: Self.buildDefaultMappings())

    private static func buildDefaultMappings() -> [XMPMapping] {
        var mappings: [XMPMapping] = []

        // MARK: Basic -- native (spec §7 table)
        mappings.append(scalar(.cameraRaw("Exposure2012"), .basicExposure, .native))
        mappings.append(scalar(.cameraRaw("Vibrance"), .basicVibrance, .native))
        mappings.append(scalar(.cameraRaw("Saturation"), .basicSaturation, .native))

        // MARK: Basic -- contextual white balance (spec §5.3, §7)
        // No generic `exportScalar`: whether the stored value is an absolute
        // Kelvin/tint (Adobe-sourced) or a LumaHarbor-relative offset
        // (native-sourced) depends on `PresetDocument.source`, which this
        // per-property closure never sees -- `XMPExporter` special-cases
        // both leaves directly instead (spec §7: flag single-direction
        // mappings rather than silently guessing).
        mappings.append(XMPMapping(
            propertyID: .cameraRaw("Temperature"),
            field: .basicTemperature,
            level: .native,
            importScalar: { try numeric($0) }
        ))
        mappings.append(XMPMapping(
            propertyID: .cameraRaw("Tint"),
            field: .basicTint,
            level: .native,
            importScalar: { try numeric($0) }
        ))

        // MARK: Basic -- approximate (different tone-mapping algorithm)
        mappings.append(scalar(.cameraRaw("Contrast2012"), .basicContrast, .approximate))
        mappings.append(scalar(.cameraRaw("Highlights2012"), .basicHighlights, .approximate))
        mappings.append(scalar(.cameraRaw("Shadows2012"), .basicShadows, .approximate))
        mappings.append(scalar(.cameraRaw("Whites2012"), .basicWhites, .approximate))
        mappings.append(scalar(.cameraRaw("Blacks2012"), .basicBlacks, .approximate))

        // MARK: HSL -- native, all eight bands, identical -100...100 range
        let hslColors: [(adobe: String, field: (hue: AdjustmentFieldID, saturation: AdjustmentFieldID, luminance: AdjustmentFieldID))] = [
            ("Red", (.hslRedHue, .hslRedSaturation, .hslRedLuminance)),
            ("Orange", (.hslOrangeHue, .hslOrangeSaturation, .hslOrangeLuminance)),
            ("Yellow", (.hslYellowHue, .hslYellowSaturation, .hslYellowLuminance)),
            ("Green", (.hslGreenHue, .hslGreenSaturation, .hslGreenLuminance)),
            ("Aqua", (.hslAquaHue, .hslAquaSaturation, .hslAquaLuminance)),
            ("Blue", (.hslBlueHue, .hslBlueSaturation, .hslBlueLuminance)),
            ("Purple", (.hslPurpleHue, .hslPurpleSaturation, .hslPurpleLuminance)),
            ("Magenta", (.hslMagentaHue, .hslMagentaSaturation, .hslMagentaLuminance))
        ]
        for color in hslColors {
            mappings.append(scalar(.cameraRaw("HueAdjustment\(color.adobe)"), color.field.hue, .native))
            mappings.append(scalar(.cameraRaw("SaturationAdjustment\(color.adobe)"), color.field.saturation, .native))
            mappings.append(scalar(.cameraRaw("LuminanceAdjustment\(color.adobe)"), color.field.luminance, .native))
        }

        // MARK: Split toning -- native, identical ranges (hue 0...360, sat 0...100, balance -100...100)
        mappings.append(scalar(.cameraRaw("SplitToningShadowHue"), .splitToningShadowHue, .native))
        mappings.append(scalar(.cameraRaw("SplitToningShadowSaturation"), .splitToningShadowSaturation, .native))
        mappings.append(scalar(.cameraRaw("SplitToningHighlightHue"), .splitToningHighlightHue, .native))
        mappings.append(scalar(.cameraRaw("SplitToningHighlightSaturation"), .splitToningHighlightSaturation, .native))
        mappings.append(scalar(.cameraRaw("SplitToningBalance"), .splitToningBalance, .native))

        // MARK: Sharpening -- approximate (amount/radius render; detail/masking
        // fall through to `.preserved` automatically -- spec §7 explicitly
        // forbids claiming those as supported since the pipeline never reads
        // them). Adobe's Sharpness is 0...100; LumaHarbor's amount is
        // 0...150, so this rescales rather than passing through untouched.
        mappings.append(XMPMapping(
            propertyID: .cameraRaw("Sharpness"),
            field: .sharpeningAmount,
            level: .approximate,
            importScalar: { try numeric($0) * 1.5 },
            exportScalar: { .text(format($0 / 1.5)) }
        ))
        mappings.append(scalar(.cameraRaw("SharpenRadius"), .sharpeningRadius, .approximate))

        // MARK: Vignette -- approximate, identical ranges
        mappings.append(scalar(.cameraRaw("PostCropVignetteAmount"), .vignetteAmount, .approximate))
        mappings.append(scalar(.cameraRaw("PostCropVignetteMidpoint"), .vignetteMidpoint, .approximate))
        mappings.append(scalar(.cameraRaw("PostCropVignetteFeather"), .vignetteFeather, .approximate))
        mappings.append(scalar(.cameraRaw("PostCropVignetteRoundness"), .vignetteRoundness, .approximate))

        // MARK: Grain -- approximate. `GrainFrequency` is the XMP property
        // name behind Lightroom's current "Roughness" slider (Adobe kept the
        // legacy property name after renaming the control in the UI); there
        // is no other third grain property documented, and LumaHarbor's own
        // `Grain` model has exactly the same three-slider shape (amount,
        // size, roughness), so this is a grounded pairing, not a guess from
        // the name alone.
        mappings.append(scalar(.cameraRaw("GrainAmount"), .grainAmount, .approximate))
        mappings.append(scalar(.cameraRaw("GrainSize"), .grainSize, .approximate))
        mappings.append(scalar(.cameraRaw("GrainFrequency"), .grainRoughness, .approximate))

        return mappings
    }

    private static func scalar(
        _ propertyID: XMPPropertyID,
        _ field: AdjustmentFieldID,
        _ level: XMPCompatibilityLevel
    ) -> XMPMapping {
        XMPMapping(
            propertyID: propertyID,
            field: field,
            level: level,
            importScalar: { try numeric($0) },
            exportScalar: { .text(format($0)) }
        )
    }

    /// Parses an XMP scalar's text form into a `Double`. Adobe writes signed
    /// values with an explicit `+` (`"+0.50"`, `"+11"`); `Double.init(_:)`
    /// accepts that natively via `strtod`.
    private static func numeric(_ value: XMPValue) throws -> Double {
        guard case .text(let text) = value else {
            throw PresetError.malformedXML("expected a scalar XMP value")
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let number = Double(trimmed), number.isFinite else {
            throw PresetError.malformedXML("not a finite number: \(trimmed.prefix(32))")
        }
        return number
    }

    /// Formats a `Double` back to XMP text without accumulating binary
    /// floating-point noise (`1.5` rather than `1.4999999999999998`).
    static func format(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
