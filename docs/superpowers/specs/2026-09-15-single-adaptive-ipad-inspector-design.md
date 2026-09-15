# Single Adaptive iPad Inspector Design

Date: 2026-09-15
Status: Approved design, pending implementation

## Problem

The iPad editor currently presents the Inspector through multiple containers:
a trailing dock, a system bottom sheet, and a separate floating Focus mode.
Moving the panel therefore changes its width, height, placement rules, and
workspace mode. To the user this looks like one Inspector being replaced by a
different panel.

The Inspector should instead be one continuous editing surface. Its placement
may adapt to available width, but moving or hiding it must not replace its UI,
change the canvas, or affect any photo-editing state.

## Goals

- Render one Inspector content hierarchy backed by the existing
  `PadInspectorCoordinator` and `EditorSession`.
- At 1100pt or wider, place that Inspector in the existing trailing dock.
- Below 1100pt, place the same Inspector as a movable overlay over the canvas.
- Let the overlay move directly from its own header without entering another
  workspace mode.
- Let the Inspector minimize into a persistent 44pt edge control and restore
  with all tabs, expanded sections, values, and undo state intact.
- Keep the canvas frame unchanged when the overlay moves, minimizes, or
  restores.
- Clamp the overlay after dragging, rotation, Split View, and Stage Manager
  resizing so its header remains reachable.

## Non-goals

- Changing adjustment algorithms, numeric ranges, slider behavior, undo,
  autosave, export, or sidecar data.
- Redesigning the macOS Inspector.
- Adding free-form panel resizing. Inspector content remains scrollable within
  an adaptive bounded height.
- Persisting an overlay position between different documents.

## Adaptive Placement

`PadEditorLayoutPolicy` remains the source of the 1100pt breakpoint.

- **Expanded width (>= 1100pt):** the Inspector is a trailing dock beside the
  canvas. It uses the existing readable dock width policy.
- **Compact or standard width (< 1100pt):** the Inspector is a movable overlay.
  Its default position is centered near the bottom with a 24pt safe margin.
  Its width is the available width minus two 24pt insets, capped at 960pt and
  never narrower than the existing minimum readable Inspector width.
- The overlay height is bounded by the available height and its content
  scrolls. Moving it never changes its content hierarchy or width policy.
- A resize re-clamps the last offset. Crossing the 1100pt breakpoint changes
  placement only; it does not recreate coordinator or editor state.

## Interaction

### Show

The toolbar Adjustments button selects the Adjustments domain and shows the
single Inspector if minimized. If the Inspector is already visible, the button
does not change its position or placement.

### Move

At compact or standard widths, dragging the full Inspector header moves the
overlay in both axes. The panel follows the finger continuously and commits one
clamped offset when the gesture ends. Sliders, pickers, scrolling, crop, and
mask gestures retain their own hit regions and are not intercepted.

The drag does not set `workspaceMode`, present a sheet, dismiss a sheet, or
create a second Inspector view.

### Minimize and Restore

The Inspector header contains one minimize control. Minimizing removes only the
panel chrome and leaves a 44pt Adjustments tile at the safe trailing edge.
Tapping the tile restores the same Inspector at its previous valid overlay
position, or in the trailing dock when the current width is expanded.

Minimize and restore are presentation-only actions. They do not touch
`PhotoAdjustments`, the current tool, compare state, undo/redo, autosave, or the
open photo.

## Component Structure

`PadEditorView` owns one shared `inspectorPanelContent` containing:

1. Move/minimize header.
2. Save status and undo/redo controls.
3. Domain navigation.
4. Search, favorites, pin, and reset actions.
5. The active adjustment, preset, geometry, local adjustment, or info content.

The trailing dock and movable overlay host this same content. The compact path
does not use SwiftUI `.sheet`, `PadBottomDrawerPolicy`, or a Focus-mode
Inspector. No duplicated coordinator or adjustment state is introduced.

## State and Data Flow

- `PadInspectorCoordinator` continues to own the active domain and adjustment
  submode.
- `InspectorNavigationModel` continues to own catalog navigation state.
- `EditorSession` remains the only owner of photo adjustments and undo/redo.
- `isInspectorMinimized` controls visibility only.
- `floatingPanelOffset` stores the document-scoped overlay displacement.
- Available size and measured panel size feed the existing pure clamping
  policy.

The former `work -> focus` transition is removed from panel movement. Any
remaining workspace-mode API is outside the Inspector interaction and must not
be mutated by Adjustments button, drag, minimize, or restore actions.

## Accessibility

- The full header is the drag target and exposes the localized hint that the
  panel can be moved.
- Minimize and restore controls keep at least 44x44pt hit targets.
- The restore tile has a localized `Show Inspector` label.
- VoiceOver order inside the Inspector stays identical across docked and
  overlay placement because both host the same content hierarchy.

## Verification

Automated tests must prove:

- 1100pt and wider uses the trailing dock; narrower sizes use the overlay.
- The compact path contains no `.sheet` presentation.
- Moving the Inspector does not assign `.focus` or change workspace mode.
- The toolbar Adjustments action does not mutate panel position.
- Dock and overlay host the same `inspectorPanelContent`.
- Overlay width, default bottom origin, and all-edge clamping are deterministic.
- Minimize and restore leave adjustments and undo state unchanged.
- Rotation and Split View re-clamp the overlay into a reachable position.

Build verification:

- Focused Inspector and layout test suites.
- Strict-concurrency Swift build.
- Unsigned generic iPad Xcode build.
- `git diff --check`.

Manual iPad verification:

1. In portrait, tapping Adjustments shows one bottom-centered overlay.
2. Dragging its header moves that same surface without a visual or width swap.
3. Tapping Adjustments again leaves a visible panel where it was placed.
4. Minimize reveals the photo and leaves one edge tile; restore returns the
   same Inspector and state.
5. Rotating to a wide landscape docks the Inspector on the right.
6. Returning to portrait restores and safely clamps the overlay.
7. Adjustment values, scrolling, undo/redo, crop, and masks still work.

## Acceptance Criteria

- There is never more than one visible Inspector.
- No user action is required to enter a separate movable-panel mode.
- Moving, minimizing, restoring, or adapting placement does not resize the
  compact canvas or mutate editing state.
- The compact Inspector retains every adjustment domain and control available
  in the docked Inspector.
- The overlay cannot become completely unreachable after drag or resize.
