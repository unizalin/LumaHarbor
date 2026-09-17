# iPad Inspector Source Consolidation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete Phase 0 of the approved cross-device design by giving the iPad Inspector one canonical implementation, removing inactive workspace-policy state, and splitting the oversized editor source into focused SwiftUI components without changing adjustment values, rendering, undo/redo, autosave, export, or document behavior.

**Architecture:** AdjustmentUI remains the owner of platform-neutral Inspector vocabulary and layout policy. The iPad app owns one PadInspectorHost and one PadToolRail source, both compiled by SwiftPM and the Xcode target. PadEditorView becomes a thin composition root that delegates toolbar, canvas/comparison, Inspector container, filmstrip, export, preset, metadata, and crop views to focused files. Presentation-only state stays in the shell; EditorSession remains the only editable document state owner.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Package Manager, Xcode project, XCTest, iOS 17, macOS 14 shared packages.

## Global Constraints

- [ ] Work only from this Phase 0 worktree branch created from origin/main; do not merge, rebase, push, reset, or delete another branch/worktree.
- [ ] Keep RawProcessingCore, PresetCore, PhotoLibraryCore, and EditorCore behavior unchanged. Do not change rendering, XMP, sidecar, numeric range, autosave, or undo semantics.
- [ ] Preserve the existing Adjustments, Presets, Geometry, Local Adjustments, Info, comparison, export, and filmstrip workflows.
- [ ] Do not add a second PhotoAdjustments store, PadInspectorCoordinator, InspectorNavigationModel, domain catalog, or export path.
- [ ] Keep user-facing strings routed through Localization.
- [ ] Every task is test-first: write the narrow test, run it and record the expected failure, implement the smallest change, rerun, then commit.
- [ ] Keep tests and reports repository-relative; never add private machine paths, signing values, fixtures, or generated output.

---

## Task 1: Lock source ownership contract

**Files:**

- Create Tests/AdjustmentUITests/PadInspectorSourceConsolidationContractTests.swift.

**Interfaces consumed:** Existing repository-relative source loaders and the current iPad app source paths.

**Interfaces produced:** A failing contract suite describing the post-consolidation source graph and the smaller policy API.

### 1.1 Add red tests

- [ ] Assert PadEditorView.swift contains no inline PadToolRail or PadInspectorHost declaration or inline marker.
- [ ] Assert PadToolRail.swift and PadInspectorHost.swift each contain exactly one matching struct declaration.
- [ ] Assert project.pbxproj lists both canonical files in PBXFileReference, PBXGroup, PBXBuildFile, and PBXSourcesBuildPhase.
- [ ] Do not change the policy API tests in this task; they remain green against the current baseline and are deliberately migrated in Task 3 after the production API change is red.
- [ ] Do not change the catalog and rail implementation assertions in this task; they are migrated to the canonical files in Task 2 after the stale standalone bodies are replaced.

### 1.2 Run the red baseline

~~~sh
swift test --filter PadInspectorSourceConsolidationContractTests
~~~

Expected result: FAIL because the inline definitions, missing Xcode membership, and inactive policy symbols still exist.

### 1.3 Commit the tests

~~~sh
git diff --check
git add Tests/AdjustmentUITests/PadInspectorSourceConsolidationContractTests.swift
git commit -m "test: lock ipad inspector source ownership"
~~~

---

## Task 2: Make standalone Inspector and rail canonical

**Files:**

- Modify Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadToolRail.swift.
- Modify Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadInspectorHost.swift.
- Modify Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift.
- Modify Apps/LumaHarborPad.xcodeproj/project.pbxproj.
- Modify the Task 1 source contracts only when their expected canonical file changes.

**Interfaces produced:**

~~~swift
struct PadToolRail: View {
    @Binding var selection: PadInspectorDomain
    var axis: Axis = .vertical
}

struct PadInspectorHost: View {
    @ObservedObject var inspector: PadInspectorCoordinator
    @ObservedObject var navigation: InspectorNavigationModel
    @ObservedObject var editor: EditorSession
    @ObservedObject var presetLibrary: PadPresetLibrary
    @ObservedObject var library: PadLibraryModel
    @ObservedObject var batchCoordinator: PadBatchAdjustmentCoordinator
    let showsDomainBar: Bool
}
~~~

Move the current inline bodies verbatim into these canonical files. The host must retain catalog navigation, search, favorite, pin, reset, section expansion, Info metadata, save state, snapshots, and all five domains. The rail must retain its 88pt vertical budget, 44pt cells, full-cell contentShape, localization, and selection binding.

### 2.1 Replace stale files and remove the duplicate

- [ ] Replace the old standalone rail with the current inline rail implementation.
- [ ] Replace the old standalone host with the current inline host implementation, including its navigation/library/batch dependencies.
- [ ] Remove both inline structs and marker comments from PadEditorView.swift; keep FloatingPanelSizeKey until Task 4 moves the container.
- [ ] Update comments so the canonical files no longer claim they are SwiftPM fallbacks or inline copies.

### 2.2 Correct Xcode membership

- [ ] Add a stable PBXFileReference, PBXBuildFile, group child, and Sources build-phase entry for PadToolRail.swift.
- [ ] Add the equivalent four entries for PadInspectorHost.swift.
- [ ] Do not change target products, bundle IDs, signing settings, resources, or unrelated membership.

### 2.3 Verify and commit

~~~sh
swift test --filter 'PadCatalogWiringContractTests|PadToolRailContractTests|PadInspectorSourceConsolidationContractTests'
swift build --package-path Apps/LumaHarborPad.swiftpm
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
git diff --check
git add Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadToolRail.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadInspectorHost.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift Apps/LumaHarborPad.xcodeproj/project.pbxproj Tests/AdjustmentUITests/PadCatalogWiringContractTests.swift Tests/AdjustmentUITests/PadToolRailContractTests.swift Tests/AdjustmentUITests/PadInspectorSourceConsolidationContractTests.swift
git commit -m "refactor: consolidate ipad inspector sources"
~~~

Expected result: selected contracts pass, nested SwiftPM builds, and the unsigned generic iPad Xcode target builds. Fix access/import errors in the canonical files; never restore an inline copy.

---

## Task 3: Remove inactive workspace-policy state

**Files:**

- Modify Sources/AdjustmentUI/PadEditorLayoutPolicy.swift.
- Modify Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift.
- Modify Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryView.swift.
- Modify Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadRootView.swift.
- Modify Tests/AdjustmentUITests/PadEditorLayoutPolicyTests.swift.
- Modify Tests/AdjustmentUITests/PadInspectorCoordinatorTests.swift.
- Modify Tests/AdjustmentUITests/PadLibraryAccessibilityContractTests.swift.

**Interfaces produced:**

~~~swift
public enum PadInspectorPresentation: String, Equatable, Sendable {
    case trailingDock
    case bottomDrawer
}

public enum PadLibrarySidebarPresentation: Equatable, Sendable {
    case overlay
    case persistent
}

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

public struct PadWorkspaceState: Equatable, Sendable {
    public var isSidebarVisible: Bool
    public var isFilmstripVisible: Bool

    public init(isSidebarVisible: Bool, isFilmstripVisible: Bool) {
        self.isSidebarVisible = isSidebarVisible
        self.isFilmstripVisible = isFilmstripVisible
    }
}

public struct PadDocumentScopedWorkspaceState: Equatable, Sendable {
    public var canvasScale: CGFloat
    public var floatingPanelOffset: CGSize

    public init(canvasScale: CGFloat, floatingPanelOffset: CGSize) {
        self.canvasScale = canvasScale
        self.floatingPanelOffset = floatingPanelOffset
    }
}
~~~

### 3.1 Red tests

- [ ] Update width/state/presentation tests to the interfaces above, including wide width 1,400pt returning persistent and the exact 1,100pt dock boundary.
- [ ] Remove Focus-mode and drawer-reducer tests that reference deleted APIs.
- [ ] Preserve clamping, movable overlay, minimize/restore, downward dismissal, document-ID reset, and real EditorSession undo tests.

Run:

~~~sh
swift test --filter 'PadEditorLayoutPolicyTests|PadInspectorCoordinatorTests|PadLibraryAccessibilityContractTests'
~~~

Expected result: compile failure because production still exposes the old fields and cases.

### 3.2 Implement the cleanup

- [ ] Remove PadWorkspaceMode, PadWorkspaceInspectorTab, showsDetailsColumn, persistentWithDetails, usesLeftHandedLayout, inspectorTab, PadDrawerPresentation, and PadBottomDrawerPolicy.
- [ ] Keep PadBottomDrawerMetrics because the movable Inspector still uses its corner radius and height budget.
- [ ] Make the wide workspace return persistent without a details flag.
- [ ] Remove the .floating switch branch from PadEditorView; the compact path remains the existing movable bottomDrawer overlay.
- [ ] Update PadLibraryView to switch only over overlay and persistent.
- [ ] Update PadRootView and PadEditorView comments to describe only sidebar/filmstrip scene state and document-scoped canvas scale/panel offset.
- [ ] Keep presentation width-driven; do not introduce orientation/device-name branches.

### 3.3 Verify and commit

~~~sh
swift test --filter 'PadEditorLayoutPolicyTests|PadInspectorCoordinatorTests|PadLibraryAccessibilityContractTests|PadInspectorSourceConsolidationContractTests'
rg -n 'showsDetailsColumn|persistentWithDetails|usesLeftHandedLayout|inspectorTab|PadBottomDrawerPolicy|PadDrawerPresentation|PadWorkspaceMode|case \.floating' Sources/AdjustmentUI Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp
git diff --check
git add Sources/AdjustmentUI/PadEditorLayoutPolicy.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryView.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadRootView.swift Tests/AdjustmentUITests/PadEditorLayoutPolicyTests.swift Tests/AdjustmentUITests/PadInspectorCoordinatorTests.swift Tests/AdjustmentUITests/PadLibraryAccessibilityContractTests.swift
git commit -m "refactor: remove inactive ipad workspace state"
~~~

Expected result: selected tests pass and the source scan returns no matches. Existing movable Inspector contracts still pass.

---

## Task 4: Split PadEditorView into focused components

**Files to create:**

- Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorToolbar.swift
- Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorCanvasView.swift
- Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorFilmstrip.swift
- Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorInspectorContainer.swift
- Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorExportViews.swift
- Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorPresetViews.swift
- Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorInfoViews.swift
- Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadCropOverlayView.swift
- Tests/AdjustmentUITests/PadEditorCompositionContractTests.swift

**Files to modify:** PadEditorView.swift and project.pbxproj.

**Interfaces consumed:** EditorSession, PadEditorModel, PadLibraryModel, PadAppServices, PadInspectorCoordinator, InspectorNavigationModel, PadPresetLibrary, and PadBatchAdjustmentCoordinator.

**Required ownership interfaces:**

~~~swift
struct PadEditorCanvasView: View {
    @ObservedObject var editor: EditorSession
    @ObservedObject var library: PadLibraryModel
    let services: PadAppServices
    @Binding var canvasScale: CGFloat
    let size: CGSize
    let filmstripPhotos: [PhotoAsset]
    let showsFilmstrip: Bool
    let onSelectFilmstripPhoto: (PhotoAsset) -> Void
}

struct PadEditorInspectorContainer: View {
    @ObservedObject var inspector: PadInspectorCoordinator
    @ObservedObject var navigation: InspectorNavigationModel
    @ObservedObject var editor: EditorSession
    @ObservedObject var presetLibrary: PadPresetLibrary
    @ObservedObject var library: PadLibraryModel
    @ObservedObject var batchCoordinator: PadBatchAdjustmentCoordinator
    @Binding var isMinimized: Bool
    @Binding var floatingPanelOffset: CGSize
    let availableSize: CGSize
    let floatingPanelMeasuredSize: CGSize
    let onMeasurePanel: (CGSize) -> Void
    let onCommitDrag: (CGSize, CGSize) -> Void
    let onMinimize: () -> Void
    let onRestore: () -> Void
}
~~~

### 4.1 Red composition tests

- [ ] Assert PadEditorView calls PadEditorToolbar, PadEditorCanvasView, and PadEditorInspectorContainer.
- [ ] Assert PadEditorView no longer declares PadPresetPanel, PadExportOptionsSheet, PadCropOverlayView, or PadEditorFilmstrip.
- [ ] Assert the root passes the same editor object to canvas and Inspector container and no new file constructs EditorSession or stores PhotoAdjustments.
- [ ] Assert all eight new files are present in PBXFileReference, PBXGroup, PBXBuildFile, and PBXSourcesBuildPhase.

Run:

~~~sh
swift test --filter PadEditorCompositionContractTests
~~~

Expected result: FAIL because the new files and call sites do not yet exist.

### 4.2 Extract the Inspector container

- [ ] Move trailingDockPanel, movableInspectorPanel, inspectorPanelContent, floatingPanelSizeReader, inspectorPanelHeader, inspectorPanelDragHandle, minimize/restore controls, and compact drag/dismiss gesture into PadEditorInspectorContainer.swift.
- [ ] Keep floatingPanelDragTranslation as @GestureState in the extracted container. Send measured size to onMeasurePanel and movement to onCommitDrag; the parent remains the owner of isMinimized and floatingPanelOffset.
- [ ] Preserve thickMaterial, corner radius, shadow, 44pt controls, localization, downward-dismiss threshold, and PadFloatingPanelLayout clamping.
- [ ] Replace the parent layout branches with the new container call while retaining one Inspector content composition.
- [ ] Run swift test --filter 'PadEditorLayoutPolicyTests|PadEditorCompositionContractTests' and expect PASS.

### 4.3 Extract canvas, comparison, and filmstrip

- [ ] Move canvas, comparisonCanvas, verticalWipeCanvas, canvasImageWithOverlays, fittedImageFrame, and canvasImage into PadEditorCanvasView.swift.
- [ ] Keep magnification and wipe-drag @GestureState in the canvas component; bind only document-scoped canvasScale to the parent.
- [ ] Move the nested PadEditorFilmstrip into PadEditorFilmstrip.swift unchanged: 116pt height, thumbnails, source status, selected border, accessibility label, and tap callback.
- [ ] Keep filmstripPhotos calculation and sceneWorkspaceState.isFilmstripVisible gate in explicit root helpers; pass results to the canvas.
- [ ] Run swift test --filter 'PadEditorLayoutPolicyTests|CropOverlayContractTests|PadEditorCompositionContractTests' and expect PASS.

### 4.4 Extract toolbar and menus

- [ ] Move the root .toolbar content, inspectorPresentationButton, compareMenu, and adjustmentClipboardMenu to PadEditorToolbar.swift.
- [ ] Pass close, export, save-to-Photos, batch-summary, and clipboard actions as closures/bindings; do not duplicate EditorSession or PhotoAdjustments state.
- [ ] Preserve every localized title, accessibility label, disabled condition, compare mode, export destination, and clipboard field toggle.
- [ ] Run swift test --filter 'PadEditorLayoutPolicyTests|PadEditorCompositionContractTests' and expect PASS.

### 4.5 Extract support views

- [ ] Move export sheets and ExportedPhotoFileDocument to PadEditorExportViews.swift.
- [ ] Move PadPresetPanel and its data/create/edit/field-selection sheets to PadEditorPresetViews.swift.
- [ ] Move histogram, save-state, metadata, and standalone Info blocks to PadEditorInfoViews.swift.
- [ ] Move PadCropOverlayView, PadCropHandle, and PadCropDragMath to PadCropOverlayView.swift.
- [ ] Keep internal visibility only where cross-file composition requires it; do not make helpers public.
- [ ] Run swift test --filter 'PadPresetContractTests|CurveHistogramContractTests|CropOverlayContractTests|PadEditorCompositionContractTests' and expect PASS.

### 4.6 Finish root and target parity

- [ ] Reduce PadEditorView.swift to root state, body, route-level alerts/sheets, layout selection, document reset, filmstrip selection callback, Inspector navigation bridge, clamp callbacks, and pure helpers.
- [ ] Keep its single PadInspectorCoordinator and InspectorNavigationModel StateObjects; children receive those objects.
- [ ] Add all eight files to Xcode group, file references, build files, and Sources phase so Xcode and SwiftPM compile the same app sources.
- [ ] Run:

~~~sh
swift test --filter 'PadEditorLayoutPolicyTests|PadInspectorCoordinatorTests|PadCatalogWiringContractTests|PadToolRailContractTests|PadInspectorSourceConsolidationContractTests|PadEditorCompositionContractTests|PadPresetContractTests|CurveHistogramContractTests|CropOverlayContractTests'
swift build -Xswiftc -strict-concurrency=complete
swift build --package-path Apps/LumaHarborPad.swiftpm -Xswiftc -strict-concurrency=complete
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
~~~

Expected result: selected tests and both strict-concurrency builds pass. Real-device iPad interaction is recorded as NOT RUN unless explicitly performed.

- [ ] Run git diff --check, stage the created sources, project membership, root, and composition tests, then commit with message refactor: split ipad editor into focused views.

---

## Task 5: Regression report and coordination handoff

**Files:**

- Create docs/testing/reports/2026-09-17-ipad-inspector-source-consolidation.md.
- Modify docs/coordination/CURRENT.md.
- Update the approved design status only after implementation is complete; do not rewrite approved decisions.

### 5.1 Run final checks

- [ ] Run swift test from the root package and record executed, skipped, and failed counts.
- [ ] Run swift build -Xswiftc -strict-concurrency=complete.
- [ ] Run swift build --package-path Apps/LumaHarborPad.swiftpm -Xswiftc -strict-concurrency=complete.
- [ ] Run the unsigned generic iPad Xcode build.
- [ ] Run the following scans:

~~~sh
rg -n 'PadInspectorHost|PadToolRail' Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp Apps/LumaHarborPad.xcodeproj/project.pbxproj
rg -n 'showsDetailsColumn|persistentWithDetails|usesLeftHandedLayout|inspectorTab|PadBottomDrawerPolicy|PadDrawerPresentation|PadWorkspaceMode|case \.floating' Sources/AdjustmentUI Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp Tests/AdjustmentUITests
git diff --check
~~~

Expected result: one declaration for each Inspector type, no removed policy symbols, no diff-check errors, and all available automated checks pass. Any pre-existing local signing-only contract failure is reported separately rather than “fixed” by changing signing settings.

### 5.2 Publish the record

- [ ] Include scope, files changed, exact commands/outcomes, test counts, Xcode result, final commit IDs, and explicit NOT RUN entries for real-device visual/gesture, VoiceOver, Dynamic Type, and iPhone work.
- [ ] Update CURRENT.md with branch, base commit, plan path, report path, final Phase 0 status, and next action: write the separate Phase 1 SharedInspectorContent plan.
- [ ] Keep decision D-010 unchanged and reference it from the handoff.

### 5.3 Final docs commit

~~~sh
git diff --check
git add docs/coordination/CURRENT.md docs/superpowers/specs/2026-09-17-cross-device-workspace-and-iphone-editor-design.md docs/testing/reports/2026-09-17-ipad-inspector-source-consolidation.md
git commit -m "docs: record ipad inspector consolidation verification"
git status --short --branch
git log --oneline --decorate -n 6
~~~

Expected result: clean worktree, branch ahead only by Phase 0 commits, and no push/merge/rebase.

## Completion Checklist

- [ ] One canonical PadToolRail and PadInspectorHost compile in SwiftPM and Xcode.
- [ ] PadEditorView is a composition root rather than a 2,800-line mixed-responsibility source.
- [ ] Inactive details, handedness, scene-tab, focus-mode, drawer-reducer, and floating-policy symbols are removed from active sources.
- [ ] The single Inspector still moves, minimizes, restores, scrolls, expands/collapses, searches, resets, compares, exports, and preserves adjustment values exactly as before.
- [ ] Mac sources and shared core behavior are unchanged and regression tests pass.
- [ ] Strict-concurrency builds, Swift tests, and the unsigned generic iPad Xcode build are recorded.
- [ ] Real-device and later universal-iOS work remain explicitly separated into later plans.
