import Foundation

/// Phase 2.3 (spec §6.3): which of the three optional Mac workspace chrome
/// panes -- left sidebar, right inspector, bottom filmstrip -- are visible,
/// plus the inspector's adjustable width and whether focus mode is hiding
/// all three right now. Like `CanvasViewportState` and
/// `EditorSession.compareMode`, this is pure UI/session state: it is never
/// written to the photo adjustment sidecar. `RootView`/`EditorView` each own
/// the actual `@AppStorage` value backing every field below (keyed by
/// `StorageKey`); this struct only holds the policy math -- focus mode's
/// effect on visibility, and the inspector width clamp -- so it can be unit
/// tested without a live SwiftUI hierarchy.
struct WorkspaceLayoutState: Equatable {
    /// The `@AppStorage` keys `RootView`, `EditorView`, and
    /// `LumaHarborCommands` all bind against, so every reader of the same
    /// preference is guaranteed to observe the same `UserDefaults` entry.
    enum StorageKey {
        static let showSidebar = "workspaceShowSidebar"
        static let showInspector = "workspaceShowInspector"
        static let showFilmstrip = "workspaceShowFilmstrip"
        static let focusMode = "workspaceFocusMode"
        static let inspectorWidth = "workspaceInspectorWidth"
    }

    static let minimumInspectorWidth: Double = 280
    static let maximumInspectorWidth: Double = 420
    static let defaultInspectorWidth: Double = 300

    var showSidebar: Bool
    var showInspector: Bool
    var showFilmstrip: Bool
    var focusMode: Bool
    var inspectorWidth: Double

    init(
        showSidebar: Bool = true,
        showInspector: Bool = true,
        showFilmstrip: Bool = true,
        focusMode: Bool = false,
        inspectorWidth: Double = WorkspaceLayoutState.defaultInspectorWidth
    ) {
        self.showSidebar = showSidebar
        self.showInspector = showInspector
        self.showFilmstrip = showFilmstrip
        self.focusMode = focusMode
        self.inspectorWidth = Self.clampedInspectorWidth(inspectorWidth)
    }

    /// Focus mode hides all three panes regardless of each one's own stored
    /// preference -- but it never *changes* those preferences (see the
    /// plain stored properties above), so turning focus mode back off
    /// restores exactly what was showing before it was turned on.
    var effectiveShowSidebar: Bool { !focusMode && showSidebar }
    var effectiveShowInspector: Bool { !focusMode && showInspector }
    var effectiveShowFilmstrip: Bool { !focusMode && showFilmstrip }

    static func clampedInspectorWidth(_ width: Double) -> Double {
        min(max(width, minimumInspectorWidth), maximumInspectorWidth)
    }
}
