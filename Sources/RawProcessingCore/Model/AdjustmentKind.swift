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
    /// Stable, non-localised label. The UI layer may localise it later; keeping
    /// it here means the ordering and naming stay in one place.
    public var displayName: String {
        switch self {
        case .exposure: return "Exposure"
        case .temperature: return "Temperature"
        case .tint: return "Tint"
        case .contrast: return "Contrast"
        case .highlights: return "Highlights"
        case .shadows: return "Shadows"
        case .whites: return "Whites"
        case .blacks: return "Blacks"
        case .vibrance: return "Vibrance"
        case .saturation: return "Saturation"
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
        case .whiteBalance: return "White Balance"
        case .tone: return "Tone"
        case .color: return "Color"
        }
    }
}
