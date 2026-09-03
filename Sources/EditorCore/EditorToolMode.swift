import Foundation

/// Which on-canvas interaction the preview is currently in (design spec
/// §6.5: crop/rotate/straighten need a dedicated interaction mode, not just
/// an inspector slider, since dragging directly on the photo is part of the
/// tool). `.adjust` is the default, ordinary browsing/slider-editing state;
/// every other case adds a gesture-driven overlay on top of the preview.
///
/// `.crop` is the only case Phase 2 Task 2.3 implements; `.whiteBalance`
/// (the eyedropper, Task 2.4) and future local-adjustment modes extend this
/// same switch rather than inventing a second, parallel "what am I doing
/// right now" flag.
public enum EditorToolMode: Equatable, Sendable {
    case adjust
    case crop
}
