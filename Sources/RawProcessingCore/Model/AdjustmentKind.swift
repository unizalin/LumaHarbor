import Foundation

/// Every adjustment the Mac-first MVP exposes.
///
/// The raw values are the sidecar JSON keys, so renaming a case is a schema
/// change and must bump `PhotoSidecar.currentSchemaVersion`.
public enum AdjustmentKind: String, CaseIterable, Codable, Sendable {
    case exposure
    case temperature
    case tint
    case contrast
    case highlights
    case shadows
    case whites
    case blacks
    case vibrance
    case saturation
}

extension AdjustmentKind {
    /// Localised label. `String(localized:)`'s default bundle resolves against
    /// the running app regardless of which module the call sits in, so this
    /// stays here rather than in the UI layer -- ordering and naming stay in
    /// one place.
    public var displayName: String {
        switch self {
        case .exposure: return String(localized: "Exposure")
        case .temperature: return String(localized: "Temperature")
        case .tint: return String(localized: "Tint")
        case .contrast: return String(localized: "Contrast")
        case .highlights: return String(localized: "Highlights")
        case .shadows: return String(localized: "Shadows")
        case .whites: return String(localized: "Whites")
        case .blacks: return String(localized: "Blacks")
        case .vibrance: return String(localized: "Vibrance")
        case .saturation: return String(localized: "Saturation")
        }
    }

    /// Adjustments that belong to the same inspector section.
    public var group: AdjustmentGroup {
        switch self {
        case .temperature, .tint: return .whiteBalance
        case .exposure, .contrast, .highlights, .shadows, .whites, .blacks: return .tone
        case .vibrance, .saturation: return .color
        }
    }
}

public enum AdjustmentGroup: String, CaseIterable, Sendable {
    case whiteBalance
    case tone
    case color

    public var displayName: String {
        switch self {
        case .whiteBalance: return String(localized: "White Balance")
        case .tone: return String(localized: "Tone")
        case .color: return String(localized: "Color")
        }
    }
}
