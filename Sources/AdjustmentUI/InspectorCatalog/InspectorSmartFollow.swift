import EditorCore

/// Smart Follow (design spec §7.1): when the user activates a canvas gesture
/// tool, the Inspector should jump to the matching section, driven off the
/// already-existing `EditorSession.toolMode` -- not a second, parallel
/// selection concept invented for this feature. Pure mapping, no state.
public enum InspectorSmartFollow {
    /// `nil` means "no section change" -- `.adjust` is the generic tool mode
    /// active whenever the user isn't using a dedicated canvas gesture, and
    /// forcing a section switch every time it's entered would fight whatever
    /// section the user is already looking at.
    public static func section(for toolMode: EditorToolMode) -> InspectorSectionID? {
        switch toolMode {
        case .adjust:
            return nil
        case .crop:
            return .geometry
        case .whiteBalance:
            return .whiteBalance
        case .linearGradient:
            return .local
        case .spotHeal:
            return .local
        }
    }
}
