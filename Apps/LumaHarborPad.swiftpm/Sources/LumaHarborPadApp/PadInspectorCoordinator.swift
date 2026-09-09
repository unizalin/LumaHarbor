import AdjustmentUI
import Foundation

/// Owns all inspector presentation state for the iPad Studio Rails editor.
///
/// This object is pure presentation — it holds which domain is selected,
/// which Adjust submode is active, and how the panel is currently hosted.
/// It must never hold a second copy of `PhotoAdjustments`, drive autosave,
/// or appear on the `EditorSession` undo stack. All mutations here are safe
/// to call at any time without side effects on the open document.
public final class PadInspectorCoordinator: ObservableObject {
    @Published public var activeDomain: PadInspectorDomain
    @Published public var adjustSubmode: PadAdjustSubmode
    @Published public var inspectorPresentation: PadInspectorPresentation
    @Published public var isInspectorVisible: Bool

    public static let initial = PadInspectorCoordinator()

    public init(
        activeDomain: PadInspectorDomain = .adjust,
        adjustSubmode: PadAdjustSubmode = .light,
        inspectorPresentation: PadInspectorPresentation = .trailingDock,
        isInspectorVisible: Bool = true
    ) {
        self.activeDomain = activeDomain
        self.adjustSubmode = adjustSubmode
        self.inspectorPresentation = inspectorPresentation
        self.isInspectorVisible = isInspectorVisible
    }

    /// Selects a domain. Presentation only — no undo, no save, no decode.
    public func selectDomain(_ domain: PadInspectorDomain) {
        activeDomain = domain
    }

    /// Selects the Adjust submode. Ignored if the active domain is not `.adjust`
    /// from the caller's perspective, but the value is always retained so
    /// switching back to `.adjust` later restores the last-used submode.
    public func selectAdjustSubmode(_ submode: PadAdjustSubmode) {
        adjustSubmode = submode
    }

    /// Changes the inspector's hosting container. Presentation only.
    public func selectPresentation(_ presentation: PadInspectorPresentation) {
        inspectorPresentation = presentation
    }

    /// Shows or hides the inspector panel without affecting the open document.
    public func toggleInspector() {
        isInspectorVisible.toggle()
    }
}
