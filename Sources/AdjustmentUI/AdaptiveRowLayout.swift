import CoreGraphics

/// How one adjustment row lays out its label, numeric/nudge controls, and
/// slider (inspector hierarchy/typography spec §5.4). `inline` keeps the
/// label and trailing numeric controls on one line with the slider beneath;
/// `stacked` gives the label its own full-width line, so a full localized
/// title never needs to shrink or truncate in a narrow column.
public enum AdjustmentRowComposition: Equatable, Sendable {
    case inline
    case stacked
}

/// Pure width-threshold policy shared by every adjustment row (`AdjustmentSliderRow`,
/// `BasicAdjustmentPanel`) so macOS and iPad pick the same composition at the
/// same width rather than each hard-coding their own breakpoint.
public enum AdaptiveRowLayout {
    /// Below this available row width, a row switches to the stacked
    /// composition (spec §5.4: "For available row width below 340 points").
    public static let stackedWidthThreshold: CGFloat = 340

    public static func composition(forAvailableWidth width: CGFloat) -> AdjustmentRowComposition {
        width >= stackedWidthThreshold ? .inline : .stacked
    }
}
