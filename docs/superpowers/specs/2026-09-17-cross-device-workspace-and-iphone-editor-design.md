# Cross-Device Workspace and iPhone Mobile Editor Design

Date: 2026-09-17

Status: Approved design, `SPEC ONLY`; implementation plans have not been written

## 1. Purpose

LumaHarbor currently ships two presentation shells over shared editing and
library cores:

- a macOS workstation shell with a persistent library sidebar, canvas,
  resizable Inspector, and optional filmstrip;
- an iPad shell that selects a movable Inspector overlay or trailing dock from
  the scene's available width.

The shared domain layers are suitable for another Apple device family, but the
presentation layer is not ready to grow safely. The iPad source currently has
both standalone and inlined implementations of `PadInspectorHost` and
`PadToolRail`, `PadEditorView.swift` owns too many unrelated responsibilities,
and several workspace-policy fields are declared without a corresponding
visible behavior. Adding a third copied Inspector would make those sources
drift further.

This design establishes one cross-device architecture for Mac, iPad, and a new
iPhone mobile editor. It intentionally does not make the three devices render
the same frame. They share editing capability, terminology, state, and control
content while each platform shell applies an interaction model appropriate to
its screen and input method.

## 2. Product Decision

The iPhone edition will be part of one universal iOS application rather than a
second independent app or a reduced remote-control companion.

The first iPhone release is a **mobile editor**:

- it can browse, organize, adjust, compare, and export one photo;
- it exposes the common Adjustments, Presets, Geometry, Local Adjustments, and
  Info domains with the same names and ordering as Mac and iPad;
- it provides full editing for Light, Color, Detail, Presets, and the initial
  Geometry tools;
- it renders and preserves existing local adjustments, but does not create or
  modify local masks in the first release;
- it does not attempt to reproduce the Mac three-column workspace or the iPad
  freely movable Inspector on a phone screen.

The first release must never remove, flatten, or rewrite unsupported edit data.
Opening and saving a document on iPhone must preserve every supported sidecar
field, including local adjustments that the phone presents read-only.

## 3. Goals

1. Keep `RawProcessingCore`, `PresetCore`, `PhotoLibraryCore`, and
   `EditorCore` as the only owners of rendering, preset, library, document,
   undo, autosave, and export behavior.
2. Create one shared Inspector content composition and catalog used by all
   three shells.
3. Make the existing iOS product universal for iPhone and iPad without
   introducing a second data store, bundle-level workflow, or adjustment
   implementation.
4. Preserve editing state while rotating, resizing, presenting or dismissing
   tools, changing Inspector placement, and moving between supported layouts.
5. Keep the photo canvas as the primary surface. Secondary chrome yields space
   before the canvas becomes unusable.
6. Provide explicit loading, read-only, offline, authorization, and failure
   states that preserve the RAW-safety language already required by the iPad
   UI/UX state contract.
7. Make every phase independently testable and shippable without requiring the
   entire cross-device redesign to land at once.

## 4. Non-Goals

- iPhone local-mask creation or editing in the first release.
- iPhone batch adjustment sync or batch export in the first release.
- Direct Camera capture or a new Photos-library ingestion model.
- Cloud synchronization, account infrastructure, or cross-device state sync.
- Changing adjustment algorithms, numeric ranges, render order, XMP mapping,
  sidecar schema, undo semantics, or autosave behavior.
- Pixel-identical layouts across Mac, iPad, and iPhone.
- visionOS, Mac Catalyst, Android, or web clients.
- Replacing native platform navigation with a custom cross-platform framework.

## 5. Supported Device Matrix

| Platform | Minimum | Workspace model | Inspector presentation |
| --- | --- | --- | --- |
| macOS | macOS 14 | Desktop workstation | Persistent, resizable trailing Inspector |
| iPad | iPadOS 17 | Adaptive tablet workspace | Movable overlay below 1100pt; trailing dock at 1100pt or wider |
| iPhone | iOS 17 | Mobile single-task workspace | Bottom tool workspace when tall; trailing or full-screen tool workspace in compact-height landscape |

The iPad continues to choose layout from the scene's actual width rather than
physical model or orientation. Split View, Stage Manager, and external-display
windows therefore use the same deterministic width policy.

The universal iOS root may use device idiom to select the phone or tablet shell
because their interaction models are intentionally different. Width and height
then select variants *inside* the chosen shell. A narrow iPad window must not
silently become the phone app, and a landscape iPhone must not inherit the iPad
floating-panel behavior.

## 6. Target Architecture

```text
RawProcessingCore
PresetCore
PhotoLibraryCore
EditorCore
        |
        v
AdjustmentUI
├── InspectorCatalog
├── InspectorNavigationModel
├── shared adjustment panels and control rows
└── SharedInspectorContent
        |
        +----------------------+----------------------+
        v                      v                      v
MacWorkspaceShell      PadWorkspaceShell      PhoneWorkspaceShell
```

### 6.1 Shared domain layers

The existing core targets remain platform-neutral. They must not import
SwiftUI, AppKit, device idiom, size classes, or platform presentation state.

`EditorSession` remains the only owner of the open photo's adjustments,
undo/redo, preview scheduling, and autosave. No shell or Inspector container may
hold a second `PhotoAdjustments` value as editable state.

### 6.2 Shared Inspector content

`AdjustmentUI` will provide one composable Inspector surface containing:

1. the five domain definitions and ordering;
2. search, favorites, pin, reset, and Smart Follow behavior where appropriate;
3. section expansion and summaries;
4. adjustment panels and adaptive control rows;
5. platform-neutral accessibility labels and value semantics.

The shared content accepts presentation capabilities instead of checking a
device directly. Examples include whether a domain rail is supplied by the
host, whether local editing is allowed, whether a page may show a multi-column
control grid, and which minimum row height applies.

Platform shells own navigation chrome, panel placement, drag gestures, sheet
detents, keyboard shortcuts, pointer behavior, and window management.

### 6.3 One universal iOS product

The existing iOS application becomes a universal phone-and-tablet product. It
uses one bundle, service graph, library registry, preset repository, document
store, and localization bundle.

The implementation retains the current package, target, scheme, bundle, and
source-directory names through Phases 0-3. Renaming them is outside this design
and requires a separate distribution and migration decision after both device
families build from the same target.

### 6.4 Source ownership and file boundaries

Before the phone shell is added:

- remove the duplicate standalone/inlined implementations of
  `PadInspectorHost` and `PadToolRail`;
- make the Xcode project and Swift package compile the same source files;
- split `PadEditorView.swift` into focused canvas, Inspector-container,
  toolbar, comparison, export, and filmstrip components;
- retain exactly one app-level `PadInspectorCoordinator` and one shared catalog;
- remove `showsDetailsColumn`, `usesLeftHandedLayout`, and the scene-level
  `inspectorTab` until a separately approved design gives them visible behavior;
- remove `PadBottomDrawerPolicy`, `PadDrawerPresentation`, the unused Focus
  transition, and the unreachable `.floating` policy case while preserving the
  active movable-overlay behavior.

No phase may keep a second implementation solely because one build path uses a
fixed Xcode source list. The project membership must be corrected instead.

## 7. Platform UX Contracts

### 7.1 macOS

- Keep the native three-region workstation: library, canvas/filmstrip, and
  trailing Inspector.
- Keep pointer resize, hover help, menus, and keyboard shortcuts.
- Keep the Inspector width clamped to its current readable range.
- Preserve distraction-free mode without overwriting the user's individual
  panel visibility preferences.
- Keep the current 1100pt minimum Mac window width. A smaller Mac workspace is
  outside this design and must not be introduced implicitly by the iPhone work.
- Use the approved dense hierarchy: page 16pt, Level 1 15pt, Level 2 and
  controls 13pt, auxiliary text 11pt, tabs 12pt.

### 7.2 iPad

- Below 1100pt, use the current single movable and minimizable Inspector
  overlay. Moving it changes presentation only.
- At 1100pt or wider, use the same Inspector content in the trailing dock and
  show the filmstrip when enabled.
- Keep 44pt minimum touch targets and the established 18/16/13 hierarchy.
- Rotation, Split View, Stage Manager resizing, and external-display movement
  must preserve the active domain, expanded sections, edit values, undo state,
  and minimized state. Panel position is re-clamped, not reset arbitrarily.
- The `wide` profile must not advertise a details column until that column is
  visibly implemented and tested.

### 7.3 iPhone library

- Use a `NavigationStack` with the photo grid as the first screen.
- Sources, smart scopes, search, sort, filter, and grid density remain
  reachable from native toolbar controls or sheets; no persistent sidebar is
  shown.
- The grid adapts column count to available width and Dynamic Type without
  changing selection or scroll position during rotation.
- Long-running library operations use visible text and the existing distinct
  `readOnly`, `offline`, and `needsAuthorization` states.
- The first release adds folders through the Files document picker and reuses
  the existing security-scoped source model. Direct Photos-library ingestion is
  out of scope.

### 7.4 iPhone editor

The canvas fills the editor behind minimal top and bottom chrome.

The top bar contains navigation, filename or document identity, compare, undo,
redo, and export actions. Commands that do not fit move into a native menu;
they do not shrink into illegible icon clusters.

The bottom domain bar exposes the same five domains and order as iPad:

1. Adjustments
2. Presets
3. Geometry
4. Local Adjustments
5. Info

When vertical room is regular, selecting a domain opens one system bottom sheet
with medium and large detents, initially at medium. It may be dismissed with the
system downward gesture, and the domain bar remains the single restore entry.

In compact-height landscape at 700pt or wider, selecting a domain opens the same
content in a dismissible trailing workspace clamped to 300-360pt and no more
than 44% of available width. Below 700pt, the tool opens as a full-screen page
with an explicit Done action. The phone never exposes free-form panel dragging;
moving a large panel around a phone would cover the same limited canvas without
creating useful space.

Only one domain is rendered at a time. Detailed Geometry interactions such as
crop and rotate enter a dedicated canvas-tool mode with explicit Done and
Cancel actions. Preset preview remains reversible until committed.

### 7.5 iPhone typography and touch

- Use semantic Dynamic Type styles rather than scaling fonts from viewport
  width.
- Default hierarchy: page and Level 1 use headline emphasis, Level 2 uses a
  semibold subheadline, controls use body, and auxiliary status uses footnote.
- Numeric values use a stable-width field and monospaced digits where helpful.
- Every primary icon or row has a minimum 44x44pt touch target.
- At accessibility text sizes, horizontal control rows use `ViewThatFits` or an
  equivalent measured policy and fall back to stacked rows; labels and numeric
  values must not truncate each other.
- State may not be communicated by color alone.

## 8. iPhone First-Release Capability Matrix

| Area | First release | Required behavior |
| --- | --- | --- |
| Library sources and grid | Editable | Add/reconnect/remove sources, browse, search, sort, filter, rate, flag |
| Light adjustments | Editable | Full existing Light controls |
| Color adjustments | Editable | White balance and existing Color controls |
| Detail adjustments | Editable | Existing Detail controls |
| Presets | Editable | Browse, preview, commit, cancel, favorite, and import/export through Files |
| Geometry | Editable | Crop, rotate, and flip; perspective is deferred from the first release |
| Local Adjustments | Read-only summary | Render and preserve existing edits; explain that editing requires iPad or Mac |
| Info | Visible and editable | View metadata; edit rating, flag, and keywords without exposing private paths |
| Compare | Editable presentation state | Original/edited toggle and wipe; side-by-side becomes top/bottom in portrait and remains side-by-side in landscape |
| Export | Editable | Existing export pipeline, Save to Files, Share, and Save to Photos where authorized |
| Batch operations | Deferred | No batch sync or batch export in the first release |

If an unsupported field is encountered, the iPhone app must preserve it through
load/save/export workflows and must never imply that the field was reset.

## 9. State Ownership and Lifetime

| State | Owner | Lifetime |
| --- | --- | --- |
| Adjustments, undo, preview, autosave | `EditorSession` | Open document |
| Library sources, query, selection, pagination | Existing library model/session | Scene and persisted library registry |
| Inspector catalog, search, favorites | Shared Inspector models | Favorites persisted; search session-local |
| Active domain and section expansion | Platform workspace state | Scene; preserved across orientation and transient presentation |
| Phone tool visibility and detent | `PhoneWorkspaceState` | Scene/document presentation only |
| iPad floating offset and minimized state | iPad workspace state | Existing document-scoped policy |
| Mac panel visibility and width | Mac workspace preferences | Existing app preferences |

Presentation state is never written to RAW sidecars or inserted into the photo
undo stack. Switching shells cannot apply, reset, or commit an adjustment.

## 10. Data and Error Flow

All three shells call the same application and domain services. A typical phone
adjustment flows as follows:

1. The phone control sends a typed adjustment update to `EditorSession`.
2. `EditorSession` owns the value, undo registration, autosave scheduling, and
   preview request.
3. The shared renderer produces the same preview semantics used by Mac and
   iPad.
4. The phone shell observes progress or failure and presents localized text.

Operations that may outlive one render pass display a visible status message,
not an unlabeled spinner. File failures say what happened, confirm that the RAW
original was not modified, and provide the next action. Internal provider
errors and private filesystem paths are never shown directly.

## 11. Performance Contract

- Do not decode or retain a second full-resolution image only because another
  shell is active.
- Reuse the existing preview scheduler and cancellation semantics.
- Slider drags use the existing preview scheduler to coalesce intermediate work,
  while the visible control value updates immediately and the final value
  renders after the gesture ends.
- Leaving a phone tool page cancels obsolete page-local work without canceling
  the document session.
- Thumbnail and preview caches respond to memory pressure; a phone build must
  not assume iPad or Mac memory budgets.
- Layout changes must not recreate `EditorSession`, reload the RAW, or clear
  the undo stack.

## 12. Accessibility and Localization

- All user-facing strings route through the existing `Localization` product.
- English and Traditional Chinese receive human-reviewed values before the
  phone release; all supported locales must pass key-parity and non-empty
  checks.
- VoiceOver order follows visible order in every Inspector host.
- Domain selection, expanded/collapsed state, preset preview state, read-only
  Local Adjustments state, save progress, and compare mode expose explicit
  accessibility values.
- Reduce Motion disables nonessential panel and thumbnail transitions.
- Increased Contrast and Differentiate Without Color keep selection and status
  understandable without relying on the accent color.
- Dynamic Type testing includes the largest accessibility size in portrait and
  landscape.

## 13. Delivery Phases

This is an umbrella design. Each phase requires a separate implementation plan,
test-first change set, verification report, and approval before integration.

### Phase 0 — Source consolidation

- Make Xcode and SwiftPM compile one `PadInspectorHost` and one `PadToolRail`.
- Split `PadEditorView.swift` into focused components without behavior changes.
- Remove the inactive workspace-policy fields and legacy types identified in
  section 6.4.
- Prove iPad and Mac behavior remain unchanged.

### Phase 1 — Shared Inspector composition

- Add `SharedInspectorContent` and platform capability inputs in
  `AdjustmentUI`.
- Migrate Mac and iPad hosts without changing adjustment behavior.
- Lock the five-domain catalog, section mapping, reset behavior, and state
  ownership with contract tests.

### Phase 2 — Universal iOS shell

- Enable phone and tablet device families in the same iOS product.
- Add shared mobile services/root routing plus `PhoneWorkspaceShell`.
- Add phone library navigation and empty/loading/error states.
- Keep iPad routed through `PadWorkspaceShell`.

### Phase 3 — iPhone editor

- Add the phone canvas, top toolbar, bottom domain bar, portrait tool workspace,
  and compact-height landscape workspace.
- Wire the first-release capability matrix.
- Add explicit read-only Local Adjustments summary and preservation tests.

### Phase 4 — Accessibility, performance, and release validation

- Complete Dynamic Type, VoiceOver, contrast, Reduce Motion, localization,
  memory-pressure, and interaction-latency gates.
- Complete real-device phone and regression validation on iPad and Mac.
- Publish only when no required release gate remains `NOT RUN`.

## 14. Verification Matrix

### 14.1 Automated tests

- Pure layout-policy tests for representative phone widths and heights,
  including small phone portrait, standard portrait, large portrait, and
  compact-height landscape.
- Contract test proving one active source for each Inspector host and tool rail.
- Cross-device Inspector catalog parity and localization-key parity.
- State-preservation tests across phone tool presentation, rotation, document
  changes, and domain changes.
- Unsupported local-adjustment round-trip tests proving no data loss.
- Editor undo/autosave tests proving presentation changes create no undo step.
- Library source-state and RAW-safety regression tests.
- Strict-concurrency Swift build and complete Swift test suite.
- Unsigned generic macOS, iPad Simulator, and iPhone Simulator builds.

### 14.2 Visual and interaction matrix

At minimum, verify:

- small iPhone portrait and landscape;
- current standard iPhone portrait and landscape;
- large iPhone portrait and landscape;
- iPad compact, standard, expanded, and wide width profiles;
- Mac at its minimum and a wide workstation window;
- English and Traditional Chinese;
- default and largest accessibility Dynamic Type;
- light and dark appearance;
- VoiceOver reading order and control values;
- Reduce Motion and Increased Contrast.

### 14.3 Real-device release gates

- At least one real iPhone and one real iPad must open, adjust, undo, export,
  relaunch, and restore the same RAW document without changing the RAW hash.
- Existing local adjustments created on Mac or iPad must render on iPhone and
  survive an iPhone save/export round trip unchanged.
- Portrait/landscape changes must not lose the active domain, edits, or undo
  state.
- Source add/reconnect, Files authorization loss, offline storage, and read-only
  behavior must present distinct localized states.
- Required gates remain `NOT RUN`, not `PASS`, until hardware evidence exists.

## 15. Acceptance Criteria

1. One universal iOS app runs the phone and tablet shells over one service and
   persistence graph.
2. Mac, iPad, and iPhone read the same Inspector catalog and adjustment values.
3. There is one compiled implementation of each shared Inspector component per
   target; standalone and inlined copies no longer coexist.
4. The iPhone editor can complete the first-release capability matrix without
   exposing a movable floating panel.
5. Local adjustments unsupported for phone editing remain visible, preserved,
   and clearly labeled read-only.
6. Rotation, resizing, panel presentation, and domain navigation never recreate
   the document session or modify undo state.
7. Every long-running file action has visible text, safe failure copy, and a
   recovery action.
8. Layout, touch, Dynamic Type, localization, VoiceOver, contrast, and motion
   requirements pass the automated and manual matrix.
9. Existing macOS and iPad workflows pass their regression suites and required
   device gates.
10. No implementation phase changes rendering algorithms, XMP mapping,
    sidecar schema, or RAW originals unless a separately approved spec says so.
