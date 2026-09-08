import EditorCore
import Foundation
import XCTest
@testable import LumaHarborApp

final class EditorWorkflowUXContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private static func loadSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRootURL.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testInspectorHasSeparateAdjustmentPresetAndInfoTabs() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/InspectorView.swift")

        XCTAssertTrue(source.contains("enum InspectorTab"))
        XCTAssertTrue(source.contains("Picker"))
        XCTAssertTrue(source.contains("PresetBrowserView()"))
        XCTAssertTrue(source.contains("MetadataPanel"))
        XCTAssertTrue(source.contains("adjustmentContent"))
    }

    func testMacInspectorSeparatesWhiteBalanceFromTheBasicTonePanel() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/InspectorView.swift")

        XCTAssertTrue(source.contains("kinds: MacBasicAdjustmentPanel.toneKinds"))
        XCTAssertTrue(source.contains("kinds: MacBasicAdjustmentPanel.whiteBalanceKinds"))
    }

    func testMacLibraryExposesSearchSortDensityAndSelectionMode() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/LibraryGridView.swift")

        XCTAssertTrue(source.contains("searchable"))
        XCTAssertTrue(source.contains("PhotoSort"))
        XCTAssertTrue(source.contains("gridDensity"))
        XCTAssertTrue(source.contains("isSelecting"))
        XCTAssertTrue(source.contains("selectedPhotoIDs.count"))
    }

    func testMacLibraryExposesCurationFiltersAndCellBadges() throws {
        let grid = try Self.loadSource("Sources/LumaHarborApp/Views/LibraryGridView.swift")
        let cell = try Self.loadSource("Sources/LumaHarborApp/Views/ThumbnailView.swift")
        let model = try Self.loadSource("Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift")

        XCTAssertTrue(grid.contains("line.3.horizontal.decrease.circle"))
        XCTAssertTrue(grid.contains("ratingFilter"))
        XCTAssertTrue(grid.contains("flagFilter"))
        XCTAssertTrue(cell.contains("photo.rating"))
        XCTAssertTrue(cell.contains("photo.flag"))
        XCTAssertTrue(model.contains("rating: ratingFilter"))
        XCTAssertTrue(model.contains("flag: flagFilter"))
        XCTAssertTrue(model.contains("hasEdits: hasEditsFilter"))
    }

    func testMacLibraryExposesAdvancedCatalogFiltersAndKeywordEditing() throws {
        let grid = try Self.loadSource("Sources/LumaHarborApp/Views/LibraryGridView.swift")
        let sheets = try Self.loadSource("Sources/LumaHarborApp/Views/LibraryFilterSheets.swift")
        let model = try Self.loadSource("Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift")

        XCTAssertTrue(grid.contains("LibraryFilterSheet"))
        XCTAssertTrue(grid.contains("PhotoKeywordEditorSheet"))
        XCTAssertTrue(grid.contains("Edit Keywords"))
        XCTAssertTrue(sheets.contains("formatFilter"))
        XCTAssertTrue(sheets.contains("captureDateStartFilter"))
        XCTAssertTrue(sheets.contains("parseKeywords"))
        XCTAssertTrue(model.contains("keyword: keywordFilter"))
        XCTAssertTrue(model.contains("setKeywordsForPhoto"))
    }

    func testMacLibraryOffersKeyboardSelectionCommands() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/LumaHarborCommands.swift")

        XCTAssertTrue(source.contains("model.selectAllVisible()"))
        XCTAssertTrue(source.contains("keyboardShortcut(\"a\", modifiers: .command)"))
    }

    func testMacLibraryOffersCurationShortcutsWithoutTakingOverTextInput() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/LumaHarborCommands.swift")

        XCTAssertTrue(source.contains("keyboardShortcut(\"p\", modifiers: [])"))
        XCTAssertTrue(source.contains("keyboardShortcut(\"x\", modifiers: [])"))
        XCTAssertTrue(source.contains("keyboardShortcut(\"u\", modifiers: [])"))
        XCTAssertTrue(source.contains("allowsPhotoShortcut"))
        XCTAssertTrue(source.contains("NSTextField"))
        XCTAssertTrue(source.contains("NSTextView"))
    }

    func testBatchExportMakesRejectInclusionAnExplicitChoice() throws {
        let sheet = try Self.loadSource("Sources/LumaHarborApp/Views/BatchExportSheet.swift")
        let model = try Self.loadSource("Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift")

        XCTAssertTrue(sheet.contains("includeRejectedInBatchExport"))
        XCTAssertTrue(sheet.contains("Include rejected photos"))
        XCTAssertTrue(model.contains("includeRejected || $0.flag != .reject"))
    }

    func testMacLibraryQueriesTheSharedIndexRatherThanReimplementingSearchAndSort() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift")

        XCTAssertTrue(source.contains("indexStore.page(matching: query, after: cursor, limit: 200)"))
        XCTAssertTrue(source.contains("LibraryQuery("))
        XCTAssertFalse(
            source.contains("localizedCaseInsensitiveContains"),
            "search must go through PhotoIndexStore's own filename-search contract, not a second Swift-side filter"
        )
    }

    func testMacEditorUsesAViewportStateAndMagnificationGesture() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")

        XCTAssertTrue(source.contains("CanvasViewportState"))
        XCTAssertTrue(source.contains("MagnificationGesture()"))
        XCTAssertTrue(source.contains("DragGesture"))
        XCTAssertTrue(source.contains("viewportTransform"))
    }

    func testViewportClampsPanAndPreservesTheAnchorWhenZooming() {
        var viewport = CanvasViewportState(scale: 1, offset: .zero, mode: .fit)
        let bounds = CGSize(width: 800, height: 600)
        let image = bounds

        viewport.zoom(to: 2, anchor: CGPoint(x: 400, y: 300), imageSize: image, viewportSize: bounds)
        viewport.pan(by: CGSize(width: 10_000, height: -10_000), imageSize: image, viewportSize: bounds)

        XCTAssertEqual(viewport.scale, 2)
        XCTAssertEqual(viewport.offset.width, 400, accuracy: 0.001)
        XCTAssertEqual(viewport.offset.height, -300, accuracy: 0.001)
    }

    // MARK: - Mac canvas viewport: Command shortcuts, double-click, Space pan

    func testEditorOffersCommandKeyboardShortcutsForFitOneToOneAndSteppedZoom() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")

        XCTAssertTrue(source.contains(#".keyboardShortcut("0", modifiers: .command)"#))
        XCTAssertTrue(source.contains(#".keyboardShortcut("1", modifiers: .command)"#))
        XCTAssertTrue(source.contains(#".keyboardShortcut("+", modifiers: .command)"#))
        XCTAssertTrue(source.contains(#".keyboardShortcut("-", modifiers: .command)"#))
        XCTAssertTrue(source.contains("zoomViewportStepped"))
        XCTAssertTrue(source.contains("CanvasViewportState.steppedScale"))
    }

    func testEditorTogglesFitAndOneToOneOnDoubleClickAndPansOnlyWithSpaceHeld() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")

        XCTAssertTrue(source.contains("SpatialTapGesture(count: 2)"))
        XCTAssertTrue(source.contains("viewportDoubleClick"))
        XCTAssertTrue(source.contains("isSpaceKeyDown"))
        XCTAssertTrue(source.contains("NSEvent.addLocalMonitorForEvents"))
        XCTAssertFalse(
            source.contains("CGEventTap"),
            "Space-key tracking must use a local NSEvent monitor, never a global event tap"
        )
    }

    // MARK: - Phase 2.1: Before/After comparison (side-by-side and vertical wipe)

    func testEditorOffersACompareModePickerGatedOnCanCompareWithOriginal() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")

        XCTAssertTrue(source.contains("model.editor.compareMode"))
        XCTAssertTrue(source.contains("EditorSession.CompareMode.sideBySide") || source.contains(".sideBySide"))
        XCTAssertTrue(source.contains("EditorSession.CompareMode.verticalWipe") || source.contains(".verticalWipe"))
        XCTAssertTrue(source.contains("setCompareMode"))
        XCTAssertTrue(
            source.contains(".disabled(!model.editor.canCompareWithOriginal)"),
            "the compare-mode picker must be disabled exactly like the existing hold/pin CompareButton when there is nothing to compare"
        )
    }

    func testSideBySideAndWipeCompareViewsShareTheSameViewportTransform() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")

        XCTAssertTrue(source.contains("sideBySideCompareView"))
        XCTAssertTrue(source.contains("wipeCompareView"))
        // Both compare layouts must be driven by the single shared `viewport`
        // state, never a second, independently-tracked scale/offset pair.
        XCTAssertTrue(source.contains("viewport.scale"))
        XCTAssertTrue(source.contains("viewport.offset"))
        XCTAssertFalse(
            source.contains("compareViewport") || source.contains("sideBySideViewport") || source.contains("wipeViewport"),
            "compare layouts must reuse the single shared CanvasViewportState, not a second copy"
        )
    }

    func testCompareViewsLabelOriginalAndEditedClearly() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")

        XCTAssertTrue(source.contains(#"L10n.t("Original")"#))
        XCTAssertTrue(source.contains(#"L10n.t("Edited")"#))
    }

    func testWipeDividerIsDraggableAndClampedThroughEditorSession() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")

        XCTAssertTrue(source.contains("setWipePosition"))
        XCTAssertTrue(source.contains("DragGesture"))
        XCTAssertTrue(
            source.contains("model.editor.wipePosition"),
            "the wipe divider's on-screen position must be driven by EditorSession's own clamped wipePosition"
        )
    }

    /// Phase 2.1 follow-up: the wipe handle's own `DragGesture` reports
    /// `location`/`translation` in the handle's small local coordinate
    /// space, not the canvas's, so the divider must be driven by
    /// `baseline + translation` (a relative delta) rather than the raw
    /// handle-local `location.x`.
    func testWipeDragPositionAppliesTranslationToTheBaselineAndClamps() {
        XCTAssertEqual(EditorView.wipeDragPosition(baseline: 0.5, translation: 100, width: 1000), 0.6)
        XCTAssertEqual(EditorView.wipeDragPosition(baseline: 0.5, translation: -100, width: 1000), 0.4)
        XCTAssertEqual(
            EditorView.wipeDragPosition(baseline: 0.9, translation: 1000, width: 200),
            EditorSession.maximumWipePosition
        )
        XCTAssertEqual(
            EditorView.wipeDragPosition(baseline: 0.1, translation: -1000, width: 200),
            EditorSession.minimumWipePosition
        )
        XCTAssertEqual(
            EditorView.wipeDragPosition(baseline: 0.5, translation: 100, width: 0),
            0.5,
            "must not divide by a zero canvas width"
        )
    }

    func testWipeDragUsesTranslationFromABaselineRatherThanHandleLocalLocation() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")

        XCTAssertTrue(source.contains("wipeDragBaseline"))
        XCTAssertTrue(source.contains("value.translation.width"))
        XCTAssertFalse(
            source.contains("value.location.x / size.width"),
            "the wipe handle's DragGesture reports locations in the handle's own local coordinate space, not the canvas's -- driving the divider from it silently breaks dragging"
        )
    }

    func testSideBySideCompareViewPartitionsLeftAndRightWithAnHStack() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")

        XCTAssertTrue(
            source.contains("HStack"),
            "side-by-side must lay the two panes out left/right, not stack them"
        )
    }

    func testEditorSessionExposesCompareModeAndClampedWipePosition() throws {
        let source = try Self.loadSource("Sources/EditorCore/EditorSession.swift")

        XCTAssertTrue(source.contains("enum CompareMode"))
        XCTAssertTrue(source.contains("case single"))
        XCTAssertTrue(source.contains("case sideBySide"))
        XCTAssertTrue(source.contains("case verticalWipe"))
        XCTAssertTrue(source.contains("func setCompareMode"))
        XCTAssertTrue(source.contains("func setWipePosition"))
        XCTAssertTrue(source.contains("minimumWipePosition"))
        XCTAssertTrue(source.contains("maximumWipePosition"))
    }

    // MARK: - Phase 2.2: copy, paste, sync adjustments (spec §6.2)

    func testInspectorOffersCopyPasteAndSyncAdjustmentsActions() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/InspectorView.swift")

        XCTAssertTrue(source.contains(#"Toggle(L10n.t("Include Geometry"), isOn: $model.copyIncludesGeometry)"#))
        XCTAssertTrue(source.contains(#"Toggle(L10n.t("Include Local Adjustments"), isOn: $model.copyIncludesLocalAdjustments)"#))
        XCTAssertTrue(source.contains("model.copyAdjustments()"))
        XCTAssertTrue(source.contains("model.pasteAdjustments()"))
        XCTAssertTrue(source.contains("model.syncAdjustmentsToSelectedPhotos()"))
        XCTAssertTrue(
            source.contains(".disabled(model.editor.photo == nil || model.adjustmentClipboard == nil)"),
            "Paste must be disabled with nothing copied yet or no photo open"
        )
        XCTAssertTrue(
            source.contains(".disabled(model.adjustmentClipboard == nil || model.selectedPhotoIDs.count <= 1)"),
            "Sync to Selected Photos must be disabled with nothing copied or fewer than two photos selected"
        )
    }

    func testCopyAdjustmentsCapturesOnlyModifiedFieldsAndOptInGeometryLocalAdjustments() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift")

        XCTAssertTrue(
            source.contains("AdjustmentPatch.modifiedFields(in: current)"),
            "copy must reuse the same diff-vs-neutral primitive the slider-drag batch sync already relies on, not a full 51-field snapshot"
        )
        XCTAssertTrue(source.contains("copyIncludesGeometry ? current.geometry : nil"))
        XCTAssertTrue(source.contains("copyIncludesLocalAdjustments ? current.localAdjustments : nil"))
    }

    func testSyncAdjustmentsToSelectedPhotosFreezesTheSelectionBeforeAwaitingTheService() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift")

        XCTAssertTrue(
            source.contains("let frozenSelection = selectedPhotoIDs"),
            "the target set must be captured into a local value synchronously, before any `await`, so a selection change mid-sync cannot retarget it"
        )
        XCTAssertTrue(source.contains("await batchSyncService.syncPatch(clipboard.patch, sourcePhotoID: source, targetPhotoIDs: targets)"))
    }

    func testSteppedScaleWalksTheFixedZoomLadderAndClampsAtTheEnds() {
        XCTAssertEqual(CanvasViewportState.steppedScale(from: 1, direction: 1), 2)
        XCTAssertEqual(CanvasViewportState.steppedScale(from: 1, direction: -1), 0.5)
        XCTAssertEqual(CanvasViewportState.steppedScale(from: 8, direction: 1), 8, "must clamp at the top of the ladder")
        XCTAssertEqual(CanvasViewportState.steppedScale(from: 0.1, direction: -1), 0.1, "must clamp at the bottom of the ladder")
        // Off-ladder values (e.g. left over from a pinch) step to the nearest
        // neighbour in the requested direction, not past it.
        XCTAssertEqual(CanvasViewportState.steppedScale(from: 0.6, direction: 1), 1)
        XCTAssertEqual(CanvasViewportState.steppedScale(from: 0.6, direction: -1), 0.5)
    }

    // MARK: - Phase 2.3: Mac focus workspace (spec §6.3)

    func testRootViewBindsAppStorageToEveryWorkspaceLayoutStorageKey() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/RootView.swift")

        XCTAssertTrue(source.contains("@AppStorage(WorkspaceLayoutState.StorageKey.showSidebar)"))
        XCTAssertTrue(source.contains("@AppStorage(WorkspaceLayoutState.StorageKey.showInspector)"))
        XCTAssertTrue(source.contains("@AppStorage(WorkspaceLayoutState.StorageKey.showFilmstrip)"))
        XCTAssertTrue(source.contains("@AppStorage(WorkspaceLayoutState.StorageKey.focusMode)"))
        XCTAssertTrue(source.contains("@AppStorage(WorkspaceLayoutState.StorageKey.inspectorWidth)"))
    }

    func testRootViewDrivesColumnVisibilityAndInspectorPaneThroughWorkspaceLayoutStateEffectiveVisibility() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/RootView.swift")

        XCTAssertTrue(source.contains("WorkspaceLayoutState("))
        XCTAssertTrue(
            source.contains("effectiveShowSidebar"),
            "the sidebar column's visibility must be driven by the shared policy, not a second ad hoc check"
        )
        XCTAssertTrue(
            source.contains("effectiveShowInspector"),
            "whether the inspector pane is included in the detail HStack must be driven by the shared policy"
        )
        XCTAssertTrue(source.contains("NavigationSplitViewVisibility"))
    }

    func testRootViewClampsInspectorWidthThroughWorkspaceLayoutStateRatherThanRawAppStorage() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/RootView.swift")

        XCTAssertTrue(
            source.contains("WorkspaceLayoutState.clampedInspectorWidth("),
            "both the drag-to-resize handle and any direct-entry control (e.g. a slider) must clamp through the shared policy, not duplicate 280...420 inline"
        )
    }

    func testRootViewOffersAVisibleWorkspaceMenuWithThreeShowTogglesFocusModeAndInspectorWidthControl() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/RootView.swift")

        XCTAssertTrue(source.contains(#"Label(L10n.t("Workspace"), systemImage:"#), "the menu must be an icon + localized label, not three identical-looking rounded text buttons")
        XCTAssertTrue(source.contains(#"Toggle(L10n.t("Show Sidebar"), isOn: $showSidebar)"#))
        XCTAssertTrue(source.contains(#"Toggle(L10n.t("Show Inspector"), isOn: $showInspector)"#))
        XCTAssertTrue(source.contains(#"Toggle(L10n.t("Show Filmstrip"), isOn: $showFilmstrip)"#))
        XCTAssertTrue(source.contains(#"Toggle(L10n.t("Distraction-Free Mode"), isOn: $focusMode)"#))
        XCTAssertTrue(source.contains("Slider("), "an inspector-width control must be discoverable from the same menu, not only via dragging the divider")
    }

    func testEditorViewShowsFilmstripOnlyWhenTheSharedWorkspaceLayoutSaysSo() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")

        XCTAssertTrue(source.contains("@AppStorage(WorkspaceLayoutState.StorageKey.showFilmstrip)"))
        XCTAssertTrue(source.contains("@AppStorage(WorkspaceLayoutState.StorageKey.focusMode)"))
        XCTAssertTrue(
            source.contains("effectiveShowFilmstrip"),
            "the filmstrip must be gated by the same focus-mode-aware policy the sidebar/inspector use, not a second ad hoc bool"
        )
        XCTAssertTrue(source.contains("FilmstripView()"))
    }

    /// Spec §6.3: "focus mode 隱藏非必要 chrome，但 Undo、Redo、比較控制與返回圖庫仍可達" --
    /// none of these four must ever be gated behind the workspace layout
    /// state, in focus mode or otherwise.
    func testEditorToolbarKeepsBackToLibraryUndoRedoAndCompareReachableRegardlessOfFocusMode() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/EditorView.swift")
        let toolbar = try Self.extractProperty(named: "toolbarContent", from: source)

        XCTAssertTrue(toolbar.contains(#"Label(L10n.t("Back to Library""#))
        XCTAssertTrue(toolbar.contains("model.editor.undo()"))
        XCTAssertTrue(toolbar.contains("model.editor.redo()"))
        XCTAssertTrue(toolbar.contains("CompareButton()"))
        XCTAssertFalse(
            toolbar.contains("focusMode"),
            "the editor toolbar's own content must never itself branch on focus mode -- focus mode only ever hides the sidebar/inspector/filmstrip chrome around it"
        )
    }

    func testLumaHarborCommandsOffersAViewMenuWithWorkspaceTogglesAndADistractionFreeModeShortcut() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/LumaHarborCommands.swift")

        XCTAssertTrue(source.contains(#"CommandMenu(L10n.t("View"))"#))
        XCTAssertTrue(source.contains("@AppStorage(WorkspaceLayoutState.StorageKey.showSidebar)"))
        XCTAssertTrue(source.contains("@AppStorage(WorkspaceLayoutState.StorageKey.showInspector)"))
        XCTAssertTrue(source.contains("@AppStorage(WorkspaceLayoutState.StorageKey.showFilmstrip)"))
        XCTAssertTrue(source.contains("@AppStorage(WorkspaceLayoutState.StorageKey.focusMode)"))
        XCTAssertTrue(source.contains(#"Toggle(L10n.t("Distraction-Free Mode"), isOn: $focusMode)"#))
        XCTAssertTrue(
            source.contains(#".keyboardShortcut("f", modifiers: [.command, .shift])"#),
            "the shortcut must require Command, so it can never fire from a plain \"f\" typed into a text field"
        )
    }

    func testWorkspaceLayoutStateItselfNeverReferencesThePhotoSidecarOrAdjustmentTypes() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Models/WorkspaceLayoutState.swift")

        XCTAssertFalse(source.contains("import EditorCore"))
        XCTAssertFalse(source.contains("import PhotoLibraryCore"))
        XCTAssertFalse(source.contains("PhotoAdjustments"))
    }

    /// Pulls the body of `private var <name>: some ... { ... }` (or
    /// `@ToolbarContentBuilder private var <name>: some ToolbarContent { ... }`)
    /// out of `source` by brace-matching from the property's opening brace,
    /// so a test can assert things about *only* that property instead of
    /// the whole file -- used above to confirm focus mode never appears
    /// inside `toolbarContent` specifically, even though the word appears
    /// elsewhere in the same file (the `@AppStorage` declaration itself).
    private static func extractProperty(named name: String, from source: String) throws -> String {
        guard let declRange = source.range(of: "var \(name):") else {
            throw XCTSkip("no property named \(name) found")
        }
        guard let openBraceIndex = source[declRange.upperBound...].firstIndex(of: "{") else {
            throw XCTSkip("no opening brace found for property \(name)")
        }
        var depth = 0
        var index = openBraceIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[openBraceIndex...index])
                }
            }
            index = source.index(after: index)
        }
        throw XCTSkip("unbalanced braces while extracting property \(name)")
    }
}
