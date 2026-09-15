import Foundation

/// The five mutually-exclusive editor domains that the Studio Rails tool rail
/// exposes. Switching domain is pure presentation state — it never creates an
/// undo entry, triggers autosave, or re-decodes RAW.
public enum PadInspectorDomain: String, CaseIterable, Equatable, Sendable {
    case adjust
    case preset
    case geometry
    case local
    case info
}

/// Which sub-panel the Adjust inspector currently shows. Only meaningful when
/// the active domain is `.adjust`; the coordinator retains the last-selected
/// submode so switching away and back restores it.
public enum PadAdjustSubmode: String, CaseIterable, Equatable, Sendable {
    case light
    case color
    case detail
}

/// Stable string field identifiers for each Adjust submode panel.
///
/// P2 (`2026-09-10-shared-professional-inspector-catalog.md`): every array
/// below is derived from `InspectorCatalog`, the single declaration point
/// shared with Mac's `InspectorView` — this type is no longer where the
/// vocabulary is *declared*, only where iPad's three-submode grouping of
/// catalog sections is read from. Adding a field means editing
/// `InspectorCatalog.allSections`, not this file.
///
/// Keys mirror `AdjustmentFieldID.rawValue` (PresetCore) and `AdjustmentKind.rawValue`
/// (RawProcessingCore) where applicable, so callers can bridge to either type
/// without creating a hard compile-time dependency on those modules here.
///
/// A key must not appear in more than one submode — this is a UI vocabulary
/// contract enforced by `PadInspectorCoordinatorTests`.
public enum PadAdjustSubmodeKinds {
    /// Tone sliders (including vibrance/saturation, matching Mac's Basic
    /// group) plus the parametric curve panel.
    public static var light: [String] {
        InspectorCatalog.sections(in: .light).flatMap(\.fieldIDs)
    }

    /// White-balance sliders and per-channel HSL.
    public static var color: [String] {
        InspectorCatalog.sections(in: .color).flatMap(\.fieldIDs)
    }

    /// Sharpening, noise reduction, vignette, and grain controls.
    public static var detail: [String] {
        InspectorCatalog.sections(in: .detail).flatMap(\.fieldIDs)
    }
}
