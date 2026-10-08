+# Mainline White Balance and Brush Integration Handoff

## Status

`DONE_WITH_CONCERNS`

The intended white-balance and independent adjustment-brush integration is implemented, committed, and automatically verified. Effective brush-load performance and unavailable manual/device gates remain explicit concerns.

## Git state

- Writing agent and worktree owner: Codex; task-scoped integration worktree.
- Source branch: `codex/mainline-wb-brush-integration`.
- Verified implementation/report HEAD before this handoff-only commit: `4f9bf09` (resolve locally for the full SHA).
- Base branch and SHA: `origin/main` at `82542e73aae8f16b0ba7e4d9d36a8a42451a7319`.
- Ahead/behind at the report checkpoint: 24 ahead, 0 behind.
- Upstream: `origin/main`; the task branch was not pushed.
- Worktree role: task-scoped integration candidate; it is not the integrated `main` baseline.
- Push, merge, and rebase: none.
- The final handoff commit is expected to be one documentation-only commit after the verified implementation/report HEAD.

## Changes

Commits created during the task, oldest first:

- `d25b911 docs: freeze mainline brush integration baseline`
- `09da9ab docs: add mainline brush integration plan`
- `44826a3 fix: harden mainline white-balance semantics`
- `3f8113e fix: preserve legacy white balance on skipped replace`
- `26fbaeb feat: add native adjustment input and safe eyedropper sessions`
- `1db5d68 fix: reject stale eyedropper contexts and localize input errors`
- `b94880e fix: close adjustment gestures and invalidate eyedropper races`
- `238d2d9 feat: add sidecar v5 brush contracts`
- `014ac31 fix: preserve brush contracts across workflows`
- `b5fc203 fix: distinguish absent brush key during migration`
- `1b4180c fix: bound sidecar schema admission`
- `ac802e4 fix: preserve invalid sidecar schema handling`
- `a0a517d feat: integrate brush rendering with geometry mapping`
- `f5bcb6f fix: harden brush raster coverage and geometry mapping`
- `abe1d1f test: verify brush geometry and pipeline parity`
- `18f09ba test: compare exported brush dimensions`
- `9474904 test: sample preview export brush parity`
- `15250ef test: close brush renderer review evidence`
- `ed55d34 feat: integrate brush mask session workflows`
- `e5ee1b5 Fix editor brush and save race invalidation`
- `abdb156 Harden batch sync contract assertions`
- `4ddbf82 feat: add cross-platform adjustment brush UI`
- `0cd6eba test: repair integrated schema and UI contracts`
- `4f9bf09 docs: record mainline integration verification`

Files changed from the base:

- `M	Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadBatchAdjustmentCoordinator.swift`
- `M	Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorCanvasView.swift`
- `M	Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorToolbar.swift`
- `M	Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadInspectorHost.swift`
- `M	Sources/AdjustmentUI/AdjustmentControlMetrics.swift`
- `A	Sources/AdjustmentUI/AdjustmentEditingContext.swift`
- `A	Sources/AdjustmentUI/AdjustmentInputController.swift`
- `A	Sources/AdjustmentUI/AdjustmentInputState.swift`
- `A	Sources/AdjustmentUI/AdjustmentNativeTextField.swift`
- `M	Sources/AdjustmentUI/AdjustmentValueInput.swift`
- `M	Sources/AdjustmentUI/BasicAdjustmentPanel.swift`
- `M	Sources/AdjustmentUI/BasicAdjustmentPanelModel.swift`
- `A	Sources/AdjustmentUI/BrushMaskOverlayView.swift`
- `M	Sources/AdjustmentUI/InspectorCatalog/InspectorSmartFollow.swift`
- `M	Sources/AdjustmentUI/LocalAdjustmentsPanel.swift`
- `M	Sources/AdjustmentUI/MaskOverlayViews.swift`
- `M	Sources/AdjustmentUI/PadAdjustmentClipboard.swift`
- `M	Sources/AdjustmentUI/PadAdjustmentPolicy.swift`
- `A	Sources/AdjustmentUI/WhiteBalanceEyedropperOverlay.swift`
- `M	Sources/EditorCore/EditorSession.swift`
- `M	Sources/EditorCore/EditorToolMode.swift`
- `M	Sources/Localization/Resources/de.lproj/Localizable.strings`
- `M	Sources/Localization/Resources/en.lproj/Localizable.strings`
- `M	Sources/Localization/Resources/es.lproj/Localizable.strings`
- `M	Sources/Localization/Resources/fr.lproj/Localizable.strings`
- `M	Sources/Localization/Resources/ja.lproj/Localizable.strings`
- `M	Sources/Localization/Resources/ko.lproj/Localizable.strings`
- `M	Sources/Localization/Resources/zh-Hans.lproj/Localizable.strings`
- `M	Sources/Localization/Resources/zh-Hant.lproj/Localizable.strings`
- `M	Sources/LumaHarborApp/Models/AdjustmentClipboard.swift`
- `M	Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift`
- `M	Sources/LumaHarborApp/Views/EditorView.swift`
- `M	Sources/LumaHarborApp/Views/EyedropperOverlayView.swift`
- `M	Sources/PhotoLibraryCore/Batch/BatchAdjustmentSyncService.swift`
- `M	Sources/PhotoLibraryCore/Service/CurationMigration.swift`
- `M	Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift`
- `M	Sources/PhotoLibraryCore/Sidecar/SidecarRepository.swift`
- `M	Sources/PresetCore/Application/PresetApplicator.swift`
- `M	Sources/RawProcessingCore/Decoding/CoreImageRawDecoder.swift`
- `M	Sources/RawProcessingCore/Export/PhotoExporter.swift`
- `M	Sources/RawProcessingCore/Model/AdjustmentCatalog.swift`
- `M	Sources/RawProcessingCore/Model/AdjustmentMapping.swift`
- `A	Sources/RawProcessingCore/Model/BrushCoordinateMapping.swift`
- `A	Sources/RawProcessingCore/Model/BrushMask.swift`
- `M	Sources/RawProcessingCore/Model/PhotoAdjustments.swift`
- `M	Sources/RawProcessingCore/Model/WhiteBalanceEyedropper.swift`
- `A	Sources/RawProcessingCore/Model/WhiteBalancePresentation.swift`
- `A	Sources/RawProcessingCore/Pipeline/BrushMaskRenderer.swift`
- `M	Sources/RawProcessingCore/Pipeline/GeometryRenderer.swift`
- `M	Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift`
- `M	Sources/RawProcessingCore/Preview/PreviewRequest.swift`
- `M	Sources/RawProcessingCore/Preview/PreviewScheduler.swift`
- `M	Tests/AdjustmentUITests/AdjustmentGroupPanelsContractTests.swift`
- `A	Tests/AdjustmentUITests/AdjustmentInputStateTests.swift`
- `A	Tests/AdjustmentUITests/AdjustmentValueInputNativeTests.swift`
- `M	Tests/AdjustmentUITests/BasicAdjustmentPanelModelTests.swift`
- `A	Tests/AdjustmentUITests/BrushMaskContractTests.swift`
- `M	Tests/AdjustmentUITests/PadAdjustmentClipboardTests.swift`
- `M	Tests/AdjustmentUITests/PadEditorExportContractTests.swift`
- `A	Tests/EditorCoreTests/EditorSessionBrushMaskGestureTests.swift`
- `M	Tests/EditorCoreTests/EditorSessionDocumentPersistenceTests.swift`
- `M	Tests/EditorCoreTests/EditorSessionEditingTests.swift`
- `A	Tests/EditorCoreTests/EditorSessionEyedropperRenderingTests.swift`
- `A	Tests/EditorCoreTests/EditorSessionSaveRaceTests.swift`
- `A	Tests/EditorCoreTests/EyedropperDeferredResultTests.swift`
- `A	Tests/EditorCoreTests/EyedropperRaceMatrixTests.swift`
- `M	Tests/EditorCoreTests/PhotoDocumentEditorTests.swift`
- `M	Tests/EditorCoreTests/SnapshotWorkflowTests.swift`
- `A	Tests/EditorCoreTests/WhiteBalanceWriteBoundaryTests.swift`
- `M	Tests/LumaHarborAppTests/AdjustmentClipboardWorkflowTests.swift`
- `M	Tests/LumaHarborAppTests/AdvancedMaskPanelContractTests.swift`
- `M	Tests/LumaHarborAppTests/CrossDeviceParityVerificationTests.swift`
- `M	Tests/LumaHarborAppTests/EditorWorkflowUXContractTests.swift`
- `M	Tests/LumaHarborAppTests/EyedropperOverlayContractTests.swift`
- `M	Tests/LumaHarborAppTests/LocalizationSmokeTest.swift`
- `M	Tests/PhotoLibraryCoreTests/BatchAdjustmentSyncServiceTests.swift`
- `M	Tests/PhotoLibraryCoreTests/CurationMigrationDecisionTests.swift`
- `M	Tests/PhotoLibraryCoreTests/PhotoDocumentStoreTests.swift`
- `M	Tests/PhotoLibraryCoreTests/PhotoLibraryServiceCurationTests.swift`
- `A	Tests/PhotoLibraryCoreTests/SidecarV5BrushContractTests.swift`
- `M	Tests/PhotoLibraryCoreTests/SnapshotModelTests.swift`
- `M	Tests/PresetCoreTests/PresetApplicatorTests.swift`
- `M	Tests/RawProcessingCoreTests/AdjustmentCatalogTests.swift`
- `A	Tests/RawProcessingCoreTests/BrushCoordinateMappingTests.swift`
- `A	Tests/RawProcessingCoreTests/BrushMaskRendererTests.swift`
- `A	Tests/RawProcessingCoreTests/BrushMaskTests.swift`
- `M	Tests/RawProcessingCoreTests/CoreImagePreviewRendererTests.swift`
- `M	Tests/RawProcessingCoreTests/PhotoAdjustmentsTests.swift`
- `M	Tests/RawProcessingCoreTests/PreviewExportRecipeParityTests.swift`
- `M	Tests/RawProcessingCoreTests/PreviewSchedulerTests.swift`
- `M	Tests/RawProcessingCoreTests/RawDecodingTests.swift`
- `M	Tests/RawProcessingCoreTests/TestSupport.swift`
- `M	Tests/RawProcessingCoreTests/WhiteBalanceEyedropperTests.swift`
- `A	Tests/RawProcessingCoreTests/WhiteBalancePresentationTests.swift`
- `M	docs/coordination/CURRENT.md`
- `M	docs/coordination/DECISIONS.md`
- `A	docs/superpowers/plans/2026-10-05-mainline-white-balance-brush-integration.md`
- `A	docs/superpowers/specs/2026-10-05-mainline-white-balance-brush-integration.md`
- `A	docs/testing/reports/2026-10-05-mainline-white-balance-brush-integration.md`

Behavior changes are summarized in the spec, plan, decisions, current-state entry, and verification report:

- `docs/superpowers/specs/2026-10-05-mainline-white-balance-brush-integration.md`
- `docs/superpowers/plans/2026-10-05-mainline-white-balance-brush-integration.md`
- `docs/coordination/DECISIONS.md`
- `docs/coordination/CURRENT.md`
- `docs/testing/reports/2026-10-05-mainline-white-balance-brush-integration.md`

## Verification

- Focused post-fix suite: exit 0; 19 executed, 0 failures.
- Task 7 UI-focused fresh suite: exit 0; 84 executed, 0 failures.
- Full fresh `swift test`: exit 0; 2,687 executed, 17 skipped, 0 failures.
- Strict-concurrency build: exit 0; PASS.
- Mac Release app bundle: exit 0; PASS, ad-hoc signed.
- Generic iPad Simulator build: exit 0; `BUILD SUCCEEDED`.
- Generic iPad device build: exit 0; `BUILD SUCCEEDED`.
- Private RAW suite: exit 0; 10 executed, 1 skipped, 0 failures; fixture inventory unchanged.
- Release privacy, branch-diff privacy, ZIP extraction privacy, and checksum gates: exit 0; PASS.
- iPad Simulator install/launch/first-screen screenshot/terminate/shutdown: exit 0; PASS.
- Empty-brush performance budget: PASS across two interleaved rounds.
- One-/ten-mask effective-load performance: measured and recorded; concern remains.
- Mac manual UI: `NOT RUN` because the host was locked.
- Physical iPad, Pencil, VoiceOver, keyboard, rotation, Split View, gray-card D65 Lab/ΔE00, and formal Lightroom Gate 2: `NOT RUN`.
- Final commands and metrics: `docs/testing/reports/2026-10-05-mainline-white-balance-brush-integration.md`.

## Dirty files

None expected after this handoff-only commit. The preserved source worktree is owned by its existing author and retains 24 tracked modifications plus 10 untracked paths; the next agent must not modify it.

## Concerns and blockers

1. The CPU coverage rasterizer takes roughly 0.94 seconds for one mandated-density mask and 8.0 seconds for ten masks at 1600 px. Original-size ten-mask export takes about 87.2 seconds and peaks near 691 MiB. This clears only after a pixel-equivalent rasterization optimization passes the full correctness and performance matrix.
2. Mac manual UI could not run while the host was locked. Clear with an unlocked isolated-app smoke.
3. Physical iPad and assistive-input checks are `NOT RUN`. Clear with a separately authorized test deployment and manual matrix.
4. Gray-card and formal Lightroom reference gates are `NOT RUN`; do not infer them from synthetic tests.
5. Independent Task 7 UI review could not be delegated because the agent workspace quota was exhausted. Root Codex performed the code review and fresh focused/full verification; a fresh independent UI review remains desirable before landing.

## Next action

Create a new task-scoped branch/worktree from this candidate and optimize `Sources/RawProcessingCore/Pipeline/BrushMaskRenderer.swift` coverage generation. Preserve exact validation, geometry, mask ordering, pixel tolerances, cancellation, legacy brush behavior, and preview/export parity. Add a failing performance-oriented regression or benchmark contract before changing behavior, then rerun focused pixels, the full suite, strict build, Mac/iPad builds, private RAW tests, and the same one-/ten-mask matrix.

Do not push, merge, rebase, publish, install to a physical device, destructively clean worktrees, or modify the preserved source worktree without explicit authorization.

## Suggested skills

- `using-git-worktrees`
- `test-driven-development`
- `benchmark`
- `verification-before-completion`
- `handoff`
