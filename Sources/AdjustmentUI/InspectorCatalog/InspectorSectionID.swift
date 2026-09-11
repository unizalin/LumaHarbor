import Foundation

/// Stable identifier for one shared Inspector section (design spec §7.1,
/// plan `2026-09-10-shared-professional-inspector-catalog.md`). This is the
/// single enumeration both Mac (`InspectorView`) and iPad (`PadInspectorHost`)
/// iterate over -- adding a ninth section means adding one case here and one
/// descriptor in `InspectorCatalog.allSections`, nothing else.
public enum InspectorSectionID: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case basic
    case whiteBalance
    case hsl
    case curve
    case presence
    case colorGrading
    case detail
    case effects
    case geometry
    case local

    public var id: String { rawValue }
}
