import CoreGraphics
import RawProcessingCore

/// One of the eight HSL color bands the adaptive selector (inspector
/// hierarchy/typography spec §5.2) can show. Replaces the eight
/// per-band `DisclosureGroup`s `ColorAdjustmentPanel` used to build --
/// `keyPath` is the single place that maps a band identity to its field in
/// `HSLAdjustments`.
public enum HSLBandID: String, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    public var id: String { rawValue }

    /// Matches the localization keys `ColorAdjustmentPanel` already uses
    /// ("Red", "Orange", ...) -- capitalizing the raw value rather than
    /// duplicating the list keeps there being exactly one spelling.
    public var labelKey: String { rawValue.capitalized }

    public var keyPath: WritableKeyPath<HSLAdjustments, RawProcessingCore.HSLBand> {
        switch self {
        case .red: return \.red
        case .orange: return \.orange
        case .yellow: return \.yellow
        case .green: return \.green
        case .aqua: return \.aqua
        case .blue: return \.blue
        case .purple: return \.purple
        case .magenta: return \.magenta
        }
    }
}

/// Pure presentation logic for the adaptive HSL band grid: which bands
/// exist, how many grid columns fit a given width, and whether a band has
/// been edited away from neutral (for the modified indicator). Never reads
/// or writes `EditorSession` -- selecting a band is UI-only state, so
/// nothing here can render the photo, write history, or touch the sidecar
/// (spec §5.2).
public enum HSLBandSelectorModel {
    public static var allBands: [HSLBandID] { HSLBandID.allCases }

    /// Spec §5.2: "At 340 points or wider, use four columns. Below 340
    /// points, use two columns."
    public static func columnCount(forAvailableWidth width: CGFloat) -> Int {
        width >= AdaptiveRowLayout.stackedWidthThreshold ? 4 : 2
    }

    public static func isModified(_ band: HSLBandID, in hsl: HSLAdjustments) -> Bool {
        hsl[keyPath: band.keyPath] != RawProcessingCore.HSLBand()
    }
}
