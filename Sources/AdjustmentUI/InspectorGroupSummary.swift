import Localization
import RawProcessingCore

/// A top-level inspector group's collapsed summary (inspector hierarchy/
/// typography spec §5.1): "Neutral: `未調整`. Modified: localized count such
/// as `3 項已調整`." Pure function over `PhotoAdjustments` -- independent of
/// `EditorSession`, so a collapsed group's summary never depends on any live
/// render or preview state.
public enum InspectorGroupSummary: Equatable, Sendable {
    case notAdjusted
    case adjusted(count: Int)

    public var localizedText: String {
        switch self {
        case .notAdjusted:
            return L10n.t("Not Adjusted")
        case .adjusted(let count):
            return String(format: L10n.t("%d Adjusted"), count)
        }
    }

    public static func summary(for sectionID: InspectorSectionID, in adjustments: PhotoAdjustments) -> InspectorGroupSummary {
        let count = modifiedFieldCount(for: sectionID, in: adjustments)
        return count == 0 ? .notAdjusted : .adjusted(count: count)
    }

    /// Counts individually modified fields where doing so is cheap and
    /// exact (every field default is `0`, so a simple non-zero test is
    /// correct). Sections without a convenient per-field breakdown here
    /// (Curve, Geometry, Local Adjustments) fall back to
    /// `InspectorCatalog.isNeutral(_:in:)`'s coarse 0/1 -- still correct
    /// (a modified section always reports at least 1), just not an exact
    /// per-control tally.
    private static func modifiedFieldCount(for sectionID: InspectorSectionID, in adjustments: PhotoAdjustments) -> Int {
        switch sectionID {
        case .basic, .whiteBalance:
            return InspectorCatalog.section(sectionID).adjustmentKinds.filter { kind in
                adjustments[kind] != AdjustmentCatalog.definition(for: kind).defaultValue
            }.count

        case .hsl:
            let bands: [RawProcessingCore.HSLBand] = [
                adjustments.hsl.red, adjustments.hsl.orange, adjustments.hsl.yellow, adjustments.hsl.green,
                adjustments.hsl.aqua, adjustments.hsl.blue, adjustments.hsl.purple, adjustments.hsl.magenta,
            ]
            let hslCount = bands.reduce(0) { partial, band in
                partial + [band.hue, band.saturation, band.luminance].filter { $0 != 0 }.count
            }
            let monoFields: [Double] = adjustments.monochrome.isEnabled ? [
                adjustments.monochrome.red, adjustments.monochrome.orange, adjustments.monochrome.yellow, adjustments.monochrome.green,
                adjustments.monochrome.aqua, adjustments.monochrome.blue, adjustments.monochrome.purple, adjustments.monochrome.magenta,
            ] : []
            return hslCount + monoFields.filter { $0 != 0 }.count

        case .presence:
            return [adjustments.presence.texture, adjustments.presence.clarity, adjustments.presence.dehaze]
                .filter { $0 != 0 }.count

        default:
            return InspectorCatalog.isNeutral(sectionID, in: adjustments) ? 0 : 1
        }
    }
}
