import Foundation

/// Which on-canvas interaction the preview is currently in (design spec
/// §6.5: crop/rotate/straighten need a dedicated interaction mode, not just
/// an inspector slider, since dragging directly on the photo is part of the
/// tool). `.adjust` is the default, ordinary browsing/slider-editing state;
/// every other case adds a gesture-driven overlay on top of the preview.
///
/// `.crop` (Task 2.3), `.whiteBalance` (the eyedropper, Task 2.4),
/// `.linearGradient` (Task 4.3) and `.spotHeal` (Task 4.5) are the cases
/// implemented so far.
public enum EditorToolMode: Equatable, Sendable {
    case adjust
    case crop
    case whiteBalance
    case linearGradient
    case spotHeal
}
