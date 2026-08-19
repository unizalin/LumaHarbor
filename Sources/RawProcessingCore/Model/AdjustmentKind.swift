import Foundation
import Localization

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
    /// Localised label, via `L10n.t` (see `Localization/L10n.swift` for why
    /// not plain `String(localized:)`). Kept here rather than in the UI layer
    /// so ordering and naming stay in one place.
    public var displayName: String {
        switch self {
        case .exposure: return L10n.t("Exposure")
        case .temperature: return L10n.t("Temperature")
        case .tint: return L10n.t("Tint")
        case .contrast: return L10n.t("Contrast")
        case .highlights: return L10n.t("Highlights")
        case .shadows: return L10n.t("Shadows")
        case .whites: return L10n.t("Whites")
        case .blacks: return L10n.t("Blacks")
        case .vibrance: return L10n.t("Vibrance")
        case .saturation: return L10n.t("Saturation")
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
        case .whiteBalance: return L10n.t("White Balance")
        case .tone: return L10n.t("Tone")
        case .color: return L10n.t("Color")
        }
    }
}
