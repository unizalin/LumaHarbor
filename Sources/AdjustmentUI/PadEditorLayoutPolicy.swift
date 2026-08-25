import CoreGraphics

/// Where the ten basic adjustments live relative to the canvas for a
/// given available size — see `PadEditorLayoutPolicy`.
public enum PadInspectorPresentation: Equatable, Sendable {
    /// A persistent 320pt panel trailing the canvas, side by side.
    case trailingDock
    /// A bottom sheet the user can drag between a collapsed peek, medium,
    /// and large detent, over the canvas.
    case bottomDrawer
}

/// Which of the two adaptive workspace layouts `PadEditorView` currently
/// shows.
///
/// Deliberately has no relationship to `EditorSession`, `AdjustmentDefinition`,
/// or any other editing state: switching between these two cases is pure
/// presentation state (which container the same controls render inside),
/// never a reason to call an adjustment, undo/redo, open, or close API. A
/// view holding this as `@State` can toggle it freely without touching the
/// photo, its edits, its zoom, or its undo stack at all.
public enum PadWorkspaceMode: Equatable, Sendable {
    /// The default: adjustments live in a docked panel or drawer
    /// alongside/below the canvas.
    case work
    /// The canvas fills the available space; adjustments become a
    /// draggable floating panel over it.
    case focus
}

/// Chooses where the adjustment controls should live for a given
/// available size.
///
/// A pure function of width and height, with no SwiftUI (or even
/// Foundation) dependency beyond `CGFloat` — so every case, including the
/// exact width boundary and irregular Split View panes, can be checked
/// with a plain value comparison, without a live view hierarchy, a real
/// device, or simulating rotation. `PadEditorView` is the only thing that
/// turns this into an actual container.
public enum PadEditorLayoutPolicy {
    /// The width, in points, at or above which a landscape-or-wider
    /// canvas gets a persistent trailing dock instead of a bottom drawer.
    public static let trailingDockMinimumWidth: CGFloat = 900

    /// - Parameters:
    ///   - width: The available width, in points, of the space the
    ///     canvas and its controls together have to fill.
    ///   - height: The available height, in points, of that same space.
    public static func presentation(forWidth width: CGFloat, height: CGFloat) -> PadInspectorPresentation {
        width >= height && width >= trailingDockMinimumWidth ? .trailingDock : .bottomDrawer
    }
}
