import CoreGraphics
import Foundation

/// Where the ten basic adjustments live relative to the canvas for a
/// given available size — see `PadEditorLayoutPolicy`.
public enum PadInspectorPresentation: String, Equatable, Sendable {
    /// A persistent responsive panel trailing the canvas, side by side.
    case trailingDock
    /// A bottom sheet the user can drag between a collapsed peek, medium,
    /// and large detent, over the canvas.
    case bottomDrawer
}

/// Which navigation surface the library can afford at a given window width.
/// The primary grid remains visible in every profile; only secondary columns
/// change presentation as the window narrows.
public enum PadLibrarySidebarPresentation: Equatable, Sendable {
    case overlay
    case persistent
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
    public let showsFilmstrip: Bool

    public init(
        profile: PadWorkspaceWidthProfile,
        librarySidebar: PadLibrarySidebarPresentation,
        editorInspector: PadInspectorPresentation,
        showsFilmstrip: Bool
    ) {
        self.profile = profile
        self.librarySidebar = librarySidebar
        self.editorInspector = editorInspector
        self.showsFilmstrip = showsFilmstrip
    }
}

/// Scene-scoped iPad workspace preferences. None of these values belong in a
/// RAW sidecar or an `EditorSession` undo stack.
public struct PadWorkspaceState: Equatable, Sendable {
    public var isSidebarVisible: Bool
    public var isFilmstripVisible: Bool

    public init(
        isSidebarVisible: Bool,
        isFilmstripVisible: Bool
    ) {
        self.isSidebarVisible = isSidebarVisible
        self.isFilmstripVisible = isFilmstripVisible
    }

    public static let initial = PadWorkspaceState(
        isSidebarVisible: true,
        isFilmstripVisible: true
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
                showsFilmstrip: false
            )
        case .standard:
            return PadWorkspaceLayout(
                profile: .standard,
                librarySidebar: .overlay,
                editorInspector: .bottomDrawer,
                showsFilmstrip: false
            )
        case .expanded:
            return PadWorkspaceLayout(
                profile: .expanded,
                librarySidebar: .persistent,
                editorInspector: .trailingDock,
                showsFilmstrip: true
            )
        case .wide:
            return PadWorkspaceLayout(
                profile: .wide,
                librarySidebar: .persistent,
                editorInspector: .trailingDock,
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
    /// The fixed width occupied by the leading tool rail in work mode.
    /// This is a control budget, not a device-specific measurement. It must
    /// match the labelled five-item rail used by both iPad source paths;
    /// keeping the budget smaller than the rendered rail causes the canvas
    /// and trailing inspector to overlap at the landscape boundary.
    public static let toolRailWidth: CGFloat = 88

    /// The two separators around the canvas/dock boundary in work mode.
    public static let layoutSeparators: CGFloat = 2

    /// The smallest canvas width that keeps the image useful while a dock is
    /// visible. Narrower containers use the bottom drawer instead.
    public static let minimumCanvasWidth: CGFloat = 640

    /// The smallest inspector width that keeps the search bar, action icons,
    /// and numeric controls usable without truncation.
    public static let minimumInspectorWidth: CGFloat = 360

    /// The largest inspector width used by the persistent dock. Extra space
    /// belongs to the canvas rather than making every control row oversized.
    public static let maximumInspectorWidth: CGFloat = 440

    /// The legacy floating-panel clamp keeps at least this much of the
    /// Inspector reachable after a drag or a resize.
    public static let floatingPanelMinimumVisibleEdge: CGFloat = 44

    /// The movable Inspector keeps the wide bottom-drawer treatment when it
    /// leaves the bottom edge. It must not collapse to the narrow trailing
    /// dock width just because its position changed.
    public static let movableInspectorHorizontalInset: CGFloat = 24
    public static let movableInspectorMaximumWidth: CGFloat = 960
    public static let movableInspectorMinimumHeight: CGFloat = 280
    public static let movableInspectorMaximumHeight: CGFloat = 720
    public static let movableInspectorDismissDragThreshold: CGFloat = 100

    public static func floatingPanelWidth(for size: CGSize) -> CGFloat {
        let availableWidth = max(0, size.width - (2 * floatingPanelMinimumVisibleEdge))
        return min(maximumInspectorWidth, max(minimumInspectorWidth, availableWidth))
    }

    /// Width for the single Inspector surface while it is being moved over
    /// the canvas. This is intentionally wider than `floatingPanelWidth`:
    /// moving the bottom drawer changes only its origin, never its editing
    /// layout or readable control width.
    public static func movableInspectorWidth(for size: CGSize) -> CGFloat {
        let availableWidth = max(0, size.width - (2 * movableInspectorHorizontalInset))
        return min(movableInspectorMaximumWidth, max(minimumInspectorWidth, availableWidth))
    }

    /// Bounds the single compact Inspector surface so portrait and Split View
    /// keep a useful canvas while the Inspector body remains scrollable. The
    /// minimum is intentionally below a typical iPad height; when a container
    /// is smaller still, the clamp policy keeps the header reachable.
    public static func movableInspectorHeight(for size: CGSize) -> CGFloat {
        let availableHeight = max(0, size.height - (2 * movableInspectorHorizontalInset))
        return min(
            movableInspectorMaximumHeight,
            max(movableInspectorMinimumHeight, availableHeight)
        )
    }

    /// A downward gesture on the compact Inspector header is an intentional
    /// dismissal only when it is long enough and predominantly vertical. This
    /// keeps a short adjustment-panel drag or a horizontal repositioning drag
    /// from unexpectedly hiding the Inspector.
    public static func shouldDismissMovableInspector(for translation: CGSize) -> Bool {
        translation.height >= movableInspectorDismissDragThreshold
            && translation.height >= abs(translation.width)
    }

    /// Places a compact Inspector at the bottom center before its stored
    /// document-scoped offset is applied. Keeping this origin pure lets the
    /// same geometry be reused for first display, rotation, and Split View
    /// re-clamping without knowing anything about SwiftUI containers.
    public static func movableInspectorOrigin(
        for size: CGSize,
        panelSize: CGSize
    ) -> CGPoint {
        CGPoint(
            x: max(movableInspectorHorizontalInset, (size.width - panelSize.width) / 2),
            y: max(movableInspectorHorizontalInset, size.height - panelSize.height - movableInspectorHorizontalInset)
        )
    }

    /// The width, in points, at or above which the Expanded profile gets a
    /// persistent trailing dock instead of a bottom drawer.
    public static let trailingDockMinimumWidth = PadWorkspaceLayoutPolicy.expandedMinimumWidth

    /// A measured editor layout for one container size. The optional widths
    /// make the bottom-drawer decision explicit: there is no hidden dock
    /// width to accidentally apply while the inspector is presented as a
    /// sheet.
    public struct LayoutPlan: Equatable, Sendable {
        public let presentation: PadInspectorPresentation
        public let inspectorWidth: CGFloat?
        public let canvasWidth: CGFloat?

        public init(
            presentation: PadInspectorPresentation,
            inspectorWidth: CGFloat?,
            canvasWidth: CGFloat?
        ) {
            self.presentation = presentation
            self.inspectorWidth = inspectorWidth
            self.canvasWidth = canvasWidth
        }
    }

    /// Calculates the complete work-mode geometry from the actual container
    /// size reported by `GeometryReader`. Keeping this pure makes rotation,
    /// Split View, Stage Manager and window resizing deterministic and
    /// directly testable without a live view hierarchy.
    public static func plan(for size: CGSize) -> LayoutPlan {
        let presentation = self.presentation(forWidth: size.width, height: size.height)
        guard presentation == .trailingDock else {
            return LayoutPlan(presentation: presentation, inspectorWidth: nil, canvasWidth: nil)
        }

        let inspectorWidth = min(
            maximumInspectorWidth,
            max(
                minimumInspectorWidth,
                size.width - toolRailWidth - layoutSeparators - minimumCanvasWidth
            )
        )
        let canvasWidth = max(
            minimumCanvasWidth,
            size.width - toolRailWidth - layoutSeparators - inspectorWidth
        )
        return LayoutPlan(
            presentation: presentation,
            inspectorWidth: inspectorWidth,
            canvasWidth: canvasWidth
        )
    }

    /// - Parameters:
    ///   - width: The available width, in points, of the space the
    ///     canvas and its controls together have to fill.
    ///   - height: The available height, in points, of that same space.
    public static func presentation(forWidth width: CGFloat, height: CGFloat) -> PadInspectorPresentation {
        PadWorkspaceLayoutPolicy.layout(forWidth: width).editorInspector
    }
}

/// Visual constants for the iPad bottom drawer. Keeping these values outside
/// the view makes the portrait presentation easy to verify without a live
/// sheet and prevents the surface treatment from drifting between hosts.
public enum PadBottomDrawerMetrics {
    /// The initial peek keeps the unified Inspector header and domain bar
    /// entirely inside the sheet. A smaller detent would clip the save row or
    /// place it beneath the system drag indicator on portrait iPad.
    public static let peekHeight: CGFloat = 280

    /// A slightly softened corner keeps the drawer distinct from the canvas
    /// without turning it into a floating card.
    public static let cornerRadius: CGFloat = 22
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
    public var canvasScale: CGFloat
    public var floatingPanelOffset: CGSize

    public init(canvasScale: CGFloat, floatingPanelOffset: CGSize) {
        self.canvasScale = canvasScale
        self.floatingPanelOffset = floatingPanelOffset
    }

    /// What every one of these three should be for a document that was
    /// just opened, or that this state is being reset for.
    public static let initial = PadDocumentScopedWorkspaceState(canvasScale: 1, floatingPanelOffset: .zero)
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
