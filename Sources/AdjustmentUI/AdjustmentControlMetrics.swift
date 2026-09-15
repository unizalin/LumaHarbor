import CoreGraphics

/// Platform-specific control sizing (inspector hierarchy/typography spec
/// §5.4's metrics table): macOS pointer targets stay compact so a narrow
/// inspector has room for the full localized label, while iPad keeps the
/// required 44pt minimum touch target.
public enum AdjustmentControlMetrics {
    /// Nudge/reset tappable region. Spec: "28 to 32 pt" on macOS, "At least
    /// 44 pt" on iPad.
    public static var nudgeHitTarget: CGFloat {
        #if os(iOS)
        44
        #else
        30
        #endif
    }

    /// The visible circle inside the nudge/reset hit target -- kept smaller
    /// than the hit target itself on iPad so the control doesn't look
    /// oversized while still being fully tappable.
    public static var nudgeVisualDiameter: CGFloat {
        #if os(iOS)
        30
        #else
        22
        #endif
    }

    /// Numeric field width. Spec: "64 to 72 pt" on macOS, "72 to 88 pt" on
    /// iPad.
    public static var numericFieldWidth: CGFloat {
        #if os(iOS)
        80
        #else
        68
        #endif
    }

    /// Row vertical gap. Spec: "6 to 8 pt" on macOS, "8 to 12 pt" on iPad.
    public static var rowVerticalGap: CGFloat {
        #if os(iOS)
        10
        #else
        6
        #endif
    }

    /// Minimum height for labelled action buttons such as section resets.
    /// Keep Mac actions compact, while ensuring every iPad action remains a
    /// comfortable 44pt touch target even when its visual control size is
    /// `.small`.
    public static var actionMinimumHeight: CGFloat {
        #if os(iOS)
        44
        #else
        36
        #endif
    }
}
