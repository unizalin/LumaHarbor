import CoreGraphics
import Foundation

/// Where the ten basic adjustments live relative to the canvas for a
/// given available size — see `PadEditorLayoutPolicy`.
public enum PadInspectorPresentation: String, Equatable, Sendable {
    /// A persistent 320pt panel trailing the canvas, side by side.
    case trailingDock
    /// A bottom sheet the user can drag between a collapsed peek, medium,
    /// and large detent, over the canvas.
    case bottomDrawer
    /// A detached, draggable floating panel — activated in focus mode so the
    /// canvas can fill the available space while the inspector stays reachable.
    case floating
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

/// Which navigation surface the library can afford at a given window width.
/// The primary grid remains visible in every profile; only secondary columns
/// change presentation as the window narrows.
public enum PadLibrarySidebarPresentation: Equatable, Sendable {
    case overlay
    case persistent
    case persistentWithDetails
}

/// Width-driven layout profiles shared by the iPad library and editor.
/// These are based on the view's available width, not the physical device or
/// orientation, so Stage Manager and Split View use the same deterministic
/// policy as full-screen layouts.
public enum PadWorkspaceWidthProfile: Equatable, Sendable {
    case compact
    case standard
    case expanded
    case wide
}

/// The complete adaptive workspace decision for one available width.
public struct PadWorkspaceLayout: Equatable, Sendable {
    public let profile: PadWorkspaceWidthProfile
    public let librarySidebar: PadLibrarySidebarPresentation
    public let editorInspector: PadInspectorPresentation
    public let showsDetailsColumn: Bool
    public let showsFilmstrip: Bool

    public init(
        profile: PadWorkspaceWidthProfile,
        librarySidebar: PadLibrarySidebarPresentation,
        editorInspector: PadInspectorPresentation,
        showsDetailsColumn: Bool,
        showsFilmstrip: Bool
    ) {
        self.profile = profile
        self.librarySidebar = librarySidebar
        self.editorInspector = editorInspector
        self.showsDetailsColumn = showsDetailsColumn
        self.showsFilmstrip = showsFilmstrip
    }
}

/// Inspector sections are presentation state, not photo-editing state.
public enum PadWorkspaceInspectorTab: Equatable, Sendable {
    case adjustments
    case presets
    case info
}

/// Scene-scoped iPad workspace preferences. None of these values belong in a
/// RAW sidecar or an `EditorSession` undo stack.
public struct PadWorkspaceState: Equatable, Sendable {
    public var isSidebarVisible: Bool
    public var inspectorTab: PadWorkspaceInspectorTab
    public var isFilmstripVisible: Bool
    public var usesLeftHandedLayout: Bool

    public init(
        isSidebarVisible: Bool,
        inspectorTab: PadWorkspaceInspectorTab,
        isFilmstripVisible: Bool,
        usesLeftHandedLayout: Bool
    ) {
        self.isSidebarVisible = isSidebarVisible
        self.inspectorTab = inspectorTab
        self.isFilmstripVisible = isFilmstripVisible
        self.usesLeftHandedLayout = usesLeftHandedLayout
    }

    public static let initial = PadWorkspaceState(
        isSidebarVisible: true,
        inspectorTab: .adjustments,
        isFilmstripVisible: true,
        usesLeftHandedLayout: false
    )
}

/// Converts available width into a stable layout profile and its secondary
/// surfaces. Keeping this pure lets the iPad UI and tests share one contract.
public enum PadWorkspaceLayoutPolicy {
    public static let compactMaximumWidth: CGFloat = 700
    public static let expandedMinimumWidth: CGFloat = 1_100
    public static let wideMinimumWidth: CGFloat = 1_360

    public static func profile(forWidth width: CGFloat) -> PadWorkspaceWidthProfile {
        switch width {
        case ..<compactMaximumWidth:
            return .compact
        case ..<expandedMinimumWidth:
            return .standard
        case ..<wideMinimumWidth:
            return .expanded
        default:
            return .wide
        }
    }

    public static func layout(forWidth width: CGFloat) -> PadWorkspaceLayout {
        switch profile(forWidth: width) {
        case .compact:
            return PadWorkspaceLayout(
                profile: .compact,
                librarySidebar: .overlay,
                editorInspector: .bottomDrawer,
                showsDetailsColumn: false,
                showsFilmstrip: false
            )
        case .standard:
            return PadWorkspaceLayout(
                profile: .standard,
                librarySidebar: .overlay,
                editorInspector: .bottomDrawer,
                showsDetailsColumn: false,
                showsFilmstrip: false
            )
        case .expanded:
            return PadWorkspaceLayout(
                profile: .expanded,
                librarySidebar: .persistent,
                editorInspector: .trailingDock,
                showsDetailsColumn: false,
                showsFilmstrip: true
            )
        case .wide:
            return PadWorkspaceLayout(
                profile: .wide,
                librarySidebar: .persistentWithDetails,
                editorInspector: .trailingDock,
                showsDetailsColumn: true,
                showsFilmstrip: true
            )
        }
    }
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
    /// The width, in points, at or above which the Expanded profile gets a
    /// persistent trailing dock instead of a bottom drawer.
    public static let trailingDockMinimumWidth = PadWorkspaceLayoutPolicy.expandedMinimumWidth

    /// - Parameters:
    ///   - width: The available width, in points, of the space the
    ///     canvas and its controls together have to fill.
    ///   - height: The available height, in points, of that same space.
    public static func presentation(forWidth width: CGFloat, height: CGFloat) -> PadInspectorPresentation {
        PadWorkspaceLayoutPolicy.layout(forWidth: width).editorInspector
    }
}

// MARK: - Bottom drawer presentation state

/// Whether the work-mode bottom drawer sheet should currently be shown.
///
/// Kept as an explicit, named state rather than a bare `Bool` so a
/// `PadEditorView` call site reads as "what should the drawer be doing"
/// rather than an unlabeled boolean — and so `PadBottomDrawerPolicy`'s
/// signature can't be satisfied by accidentally passing the wrong flag.
public enum PadDrawerPresentation: Equatable, Sendable {
    case presented
    case dismissed
}

/// Decides whether the bottom drawer sheet should be presented, from the
/// same two facts `PadEditorView` already has on hand every time either
/// one changes: the current workspace mode and the current inspector
/// presentation (`PadEditorLayoutPolicy`'s own output).
///
/// This is the reducer the drawer's real, toggleable `@State` binding is
/// driven from — never a `.sheet(isPresented: .constant(true))`, which
/// can't be told to close (work → focus), can't reliably reopen once
/// dismissed (focus → work while still narrow), and stays attached to
/// whichever `switch` branch it was written inside, so a presentation
/// change that swaps branches (bottomDrawer → trailingDock) tears the
/// sheet's view identity down mid-presentation instead of dismissing it
/// through SwiftUI's own transition.
public enum PadBottomDrawerPolicy {
    public static func presentation(
        mode: PadWorkspaceMode,
        inspectorPresentation: PadInspectorPresentation
    ) -> PadDrawerPresentation {
        mode == .work && inspectorPresentation == .bottomDrawer ? .presented : .dismissed
    }
}

// MARK: - Floating panel position clamping

/// Keeps a focus-mode floating panel draggable back into view from
/// wherever it was left, rather than lettable to be dragged fully off
/// the available area with no way back short of a document switch or a
/// resize.
public enum PadFloatingPanelLayout {
    /// Clamps a proposed offset (relative to `panelOrigin`, the panel's
    /// position with zero offset) so that at least `minimumVisibleEdge`
    /// points of the panel remain within `[0, availableSize]` on both
    /// axes — enough of the panel (which always has its draggable header
    /// spanning its full width, at its top edge) stays on-screen and
    /// reachable to grab and drag back, regardless of which direction it
    /// was dragged toward or how the available area has since changed.
    ///
    /// Pure geometry: no view hierarchy, no device/orientation lookup, no
    /// timing of any kind — safe to call both from a drag gesture's own
    /// `onEnded` and again whenever `availableSize` changes (a resize or
    /// rotation), re-clamping whatever offset was already committed.
    ///
    /// - Parameters:
    ///   - proposedOffset: The offset being considered — either a fresh
    ///     drag's final translation added to the previously committed
    ///     offset, or the already-committed offset being re-checked after
    ///     `availableSize` changed.
    ///   - panelOrigin: Where the panel sits before any offset is applied.
    ///   - panelSize: The panel's current measured size.
    ///   - availableSize: The size of the area the panel must stay
    ///     reachable within.
    ///   - minimumVisibleEdge: How much of the panel, along whichever
    ///     edge is nearest the boundary, must remain visible. Must be
    ///     positive for the clamp to guarantee any part of the panel stays
    ///     reachable; a value larger than `panelSize` on an axis is
    ///     harmless (the clamp still resolves to a single valid position
    ///     on that axis rather than an empty range).
    public static func clampedOffset(
        proposedOffset: CGSize,
        panelOrigin: CGPoint,
        panelSize: CGSize,
        availableSize: CGSize,
        minimumVisibleEdge: CGFloat
    ) -> CGSize {
        let proposedX = panelOrigin.x + proposedOffset.width
        let proposedY = panelOrigin.y + proposedOffset.height

        let clampedX = Self.clampedPosition(
            proposed: proposedX,
            extent: panelSize.width,
            availableExtent: availableSize.width,
            minimumVisibleEdge: minimumVisibleEdge
        )
        let clampedY = Self.clampedPosition(
            proposed: proposedY,
            extent: panelSize.height,
            availableExtent: availableSize.height,
            minimumVisibleEdge: minimumVisibleEdge
        )

        return CGSize(width: clampedX - panelOrigin.x, height: clampedY - panelOrigin.y)
    }

    /// One axis of the clamp: `position` is the panel's top/left
    /// coordinate along this axis. The panel's trailing/bottom edge must
    /// not retreat past `minimumVisibleEdge` from the container's
    /// leading/top edge, and the panel's leading/top edge must not
    /// advance past `availableExtent - minimumVisibleEdge` — the two
    /// bounds `max`-clamped against each other so an oversized panel (or
    /// an undersized container) still yields a single well-defined
    /// position instead of an inverted, empty range.
    private static func clampedPosition(
        proposed: CGFloat,
        extent: CGFloat,
        availableExtent: CGFloat,
        minimumVisibleEdge: CGFloat
    ) -> CGFloat {
        let lowerBound = minimumVisibleEdge - extent
        let upperBound = max(lowerBound, availableExtent - minimumVisibleEdge)
        return min(max(proposed, lowerBound), upperBound)
    }
}

// MARK: - Document-scoped workspace state

/// The subset of `PadEditorView`'s view-local state that belongs to one
/// specific open document — everything else about the document
/// (adjustments, undo/redo, autosave) lives in `EditorSession` and is
/// untouched by anything here.
public struct PadDocumentScopedWorkspaceState: Equatable, Sendable {
    public var workspaceMode: PadWorkspaceMode
    public var canvasScale: CGFloat
    public var floatingPanelOffset: CGSize

    public init(workspaceMode: PadWorkspaceMode, canvasScale: CGFloat, floatingPanelOffset: CGSize) {
        self.workspaceMode = workspaceMode
        self.canvasScale = canvasScale
        self.floatingPanelOffset = floatingPanelOffset
    }

    /// What every one of these three should be for a document that was
    /// just opened, or that this state is being reset for.
    public static let initial = PadDocumentScopedWorkspaceState(workspaceMode: .work, canvasScale: 1, floatingPanelOffset: .zero)
}

/// Decides whether `PadDocumentScopedWorkspaceState` must reset to
/// `.initial` for a document-identity transition, without ever assuming
/// the view holding that state gets recreated by SwiftUI when the open
/// document changes — it does not: `PadEditorView` is the same view
/// instance across a restore, a relink, or opening a second document
/// while the first was already showing, so its `@State` survives unless
/// something explicitly resets it.
public enum PadDocumentScopedWorkspacePolicy {
    /// - Parameters:
    ///   - state: The state as it currently stands.
    ///   - previousDocumentID: The document id this state was last known
    ///     to belong to (`nil` if none was open yet).
    ///   - currentDocumentID: The document id now open (`nil` if none is).
    ///
    /// Resets only on an actual document-to-document change — both ids
    /// present and different. The very first open (`nil` → an id) has
    /// nothing to reset *from* (a freshly created view already starts at
    /// `.initial`), and a close (an id → `nil`) has no new document to
    /// reset *for* — `PadEditorView` itself is torn down in that case,
    /// which discards this state on its own.
    public static func resettingIfNeeded(
        _ state: PadDocumentScopedWorkspaceState,
        previousDocumentID: UUID?,
        currentDocumentID: UUID?
    ) -> PadDocumentScopedWorkspaceState {
        guard let previousDocumentID, let currentDocumentID, previousDocumentID != currentDocumentID else {
            return state
        }
        return .initial
    }
}
