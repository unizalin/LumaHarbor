import Foundation
import RawProcessingCore

/// The single declaration point for every Adjust/Geometry/Local Inspector
/// section on both platforms (design spec §7.1, §11.3 items 18-20; plan
/// `2026-09-10-shared-professional-inspector-catalog.md`). Mac's
/// `InspectorView` and iPad's `PadInspectorHost`/`PadToolRail` both read from
/// `allSections` -- neither declares its own parallel field-ID list anymore.
///
/// Deliberately excludes the Preset and Info domains: Presets already has its
/// own dedicated search/favorites UI (`PadPresetLibrary`), and Info is
/// read-only metadata, not a field catalog to search or reset.
public enum InspectorCatalog {

    // MARK: - Section inventory

    public static let allSections: [InspectorSectionDescriptor] = [
        InspectorSectionDescriptor(
            id: .basic,
            domain: .adjust,
            submode: .light,
            titleKey: "Basic",
            symbol: "slider.horizontal.3",
            fieldIDs: ["exposure", "contrast", "highlights", "shadows", "whites", "blacks", "vibrance", "saturation"],
            searchTokens: ["exposure", "contrast", "highlights", "shadows", "whites", "blacks", "vibrance", "saturation", "tone", "light", "basic"]
        ),
        InspectorSectionDescriptor(
            id: .whiteBalance,
            domain: .adjust,
            submode: .color,
            titleKey: "White Balance",
            symbol: "thermometer.medium",
            fieldIDs: ["basic.temperature", "basic.tint"],
            searchTokens: ["temperature", "tint", "white balance", "kelvin", "wb", "color"]
        ),
        InspectorSectionDescriptor(
            id: .hsl,
            domain: .adjust,
            submode: .color,
            titleKey: "Color",
            symbol: "paintpalette",
            fieldIDs: Self.hslFieldIDs,
            searchTokens: ["hue", "saturation", "luminance", "hsl", "color",
                           "red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
        ),
        InspectorSectionDescriptor(
            id: .curve,
            domain: .adjust,
            submode: .light,
            titleKey: "Curve",
            symbol: "curve",
            fieldIDs: ["advancedToneCurve"],
            searchTokens: ["curve", "tone curve", "points", "rgb curve"]
        ),
        InspectorSectionDescriptor(
            id: .presence,
            domain: .adjust,
            submode: .light,
            titleKey: "Presence",
            symbol: "circle.hexagongrid",
            fieldIDs: ["presence.texture", "presence.clarity", "presence.dehaze"],
            searchTokens: ["texture", "clarity", "dehaze", "presence", "haze"]
        ),
        InspectorSectionDescriptor(
            id: .colorGrading,
            domain: .adjust,
            submode: .color,
            titleKey: "Color Grading",
            symbol: "circle.hexagonpath",
            fieldIDs: ["colorGrading"],
            searchTokens: ["color grading", "shadows", "midtones", "highlights", "grade", "wheel", "split toning"]
        ),
        InspectorSectionDescriptor(
            id: .detail,
            domain: .adjust,
            submode: .detail,
            titleKey: "Detail",
            symbol: "circle.grid.3x3",
            fieldIDs: ["sharpening.amount", "sharpening.radius", "sharpening.detail", "sharpening.masking",
                       "noiseReduction.luminanceAmount", "noiseReduction.luminanceDetail",
                       "noiseReduction.colorAmount", "noiseReduction.colorDetail"],
            searchTokens: ["sharpening", "sharpen", "noise", "noise reduction", "detail"]
        ),
        InspectorSectionDescriptor(
            id: .effects,
            domain: .adjust,
            submode: .detail,
            titleKey: "Effects",
            symbol: "sparkles",
            fieldIDs: ["vignette.amount", "vignette.midpoint", "vignette.roundness", "vignette.feather",
                       "grain.amount", "grain.size", "grain.roughness"],
            searchTokens: ["vignette", "grain", "effects"]
        ),
        InspectorSectionDescriptor(
            id: .geometry,
            domain: .geometry,
            submode: nil,
            titleKey: "Geometry",
            symbol: "crop.rotate",
            fieldIDs: [],
            searchTokens: ["crop", "rotate", "flip", "straighten", "geometry", "perspective", "aspect ratio",
                           "lens correction", "distortion", "vignetting", "chromatic aberration"]
        ),
        InspectorSectionDescriptor(
            id: .local,
            domain: .local,
            submode: nil,
            titleKey: "Local Adjustments",
            symbol: "paintbrush.pointed",
            fieldIDs: [],
            searchTokens: ["heal", "clone", "gradient", "spot", "local", "brush", "retouch"]
        )
    ]

    private static let hslFieldIDs: [String] = {
        let bands = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]
        let components = ["hue", "saturation", "luminance"]
        return bands.flatMap { band in components.map { "hsl.\(band).\($0)" } }
    }()

    private static let byID: [InspectorSectionID: InspectorSectionDescriptor] =
        Dictionary(uniqueKeysWithValues: allSections.map { ($0.id, $0) })

    public static func section(_ id: InspectorSectionID) -> InspectorSectionDescriptor {
        guard let descriptor = byID[id] else {
            preconditionFailure("InspectorCatalog.allSections is missing a descriptor for \(id) -- every InspectorSectionID case must have exactly one entry")
        }
        return descriptor
    }

    public static func sections(in domain: PadInspectorDomain) -> [InspectorSectionDescriptor] {
        allSections.filter { $0.domain == domain }
    }

    public static func sections(in submode: PadAdjustSubmode) -> [InspectorSectionDescriptor] {
        allSections.filter { $0.submode == submode }
    }

    // MARK: - Search

    /// Matches a query against each section's title key, raw field IDs, and
    /// declared search-token synonyms. Case-insensitive substring match --
    /// deliberately simple (no fuzzy scoring) so results stay predictable.
    /// Blank/whitespace-only queries return no results (nothing to search
    /// for, not "everything").
    public static func search(_ query: String) -> [InspectorSectionDescriptor] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }
        return allSections.filter { section in
            if section.titleKey.lowercased().contains(trimmed) { return true }
            if section.fieldIDs.contains(where: { $0.lowercased().contains(trimmed) }) { return true }
            if section.searchTokens.contains(where: { $0.lowercased().contains(trimmed) }) { return true }
            return false
        }
    }

    // MARK: - Reset

    /// Resets exactly the fields owned by `id`, leaving every other field
    /// (including other sections in the same domain) untouched. Pure
    /// function -- callers integrate it with undo/autosave via
    /// `EditorSession.updateAdjustments(_:)`.
    public static func resetting(_ id: InspectorSectionID, in adjustments: PhotoAdjustments) -> PhotoAdjustments {
        var copy = adjustments
        switch id {
        case .basic:
            for kind in section(.basic).adjustmentKinds {
                copy[kind] = AdjustmentCatalog.definition(for: kind).defaultValue
            }
        case .whiteBalance:
            for kind in section(.whiteBalance).adjustmentKinds {
                copy[kind] = AdjustmentCatalog.definition(for: kind).defaultValue
            }
        case .hsl:
            copy.hsl = .neutral
        case .curve:
            copy.advancedToneCurve = .neutral
        case .presence:
            copy.presence = .neutral
        case .colorGrading:
            copy.colorGrading = .neutral
        case .detail:
            copy.sharpening = .neutral
            copy.noiseReduction = .neutral
        case .effects:
            copy.vignette = .neutral
            copy.grain = .neutral
        case .geometry:
            copy.geometry = .neutral
            copy.lensCorrection = .neutral
        case .local:
            copy.localAdjustments = []
        }
        return copy
    }

    /// Resets every section in `domain` that opts into domain-wide reset
    /// (`resetsWithDomain`), leaving other domains untouched.
    public static func resetting(domain: PadInspectorDomain, in adjustments: PhotoAdjustments) -> PhotoAdjustments {
        sections(in: domain)
            .filter(\.resetsWithDomain)
            .reduce(adjustments) { partial, section in resetting(section.id, in: partial) }
    }

    // MARK: - Neutral check

    public static func isNeutral(_ id: InspectorSectionID, in adjustments: PhotoAdjustments) -> Bool {
        resetting(id, in: adjustments) == adjustments
    }

    public static func isNeutral(domain: PadInspectorDomain, in adjustments: PhotoAdjustments) -> Bool {
        resetting(domain: domain, in: adjustments) == adjustments
    }
}
