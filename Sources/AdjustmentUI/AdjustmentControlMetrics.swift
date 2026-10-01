import CoreGraphics

/// Platform-specific sizing for the shared numeric control.
///
/// macOS can use a smaller visual control because pointer and keyboard input
/// provide precision. iPad keeps the larger touch target. Keeping these values
/// in one place prevents individual panels from drifting apart.
public enum AdjustmentControlMetrics {
    #if os(macOS)
    public static let nudgeHitTarget: CGFloat = 30
    public static let nudgeVisualDiameter: CGFloat = 22
    public static let resetHitTarget: CGFloat = 30
    public static let resetVisualDiameter: CGFloat = 22
    public static let numericFieldWidth: CGFloat = 68
    public static let actionSpacing: CGFloat = 4
    #else
    public static let nudgeHitTarget: CGFloat = 44
    public static let nudgeVisualDiameter: CGFloat = 30
    public static let resetHitTarget: CGFloat = 44
    public static let resetVisualDiameter: CGFloat = 30
    public static let numericFieldWidth: CGFloat = 80
    public static let actionSpacing: CGFloat = 6
    #endif
}
