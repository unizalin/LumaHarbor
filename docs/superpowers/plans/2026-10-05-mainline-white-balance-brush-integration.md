# Mainline White Balance and Brush Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate the validated white-balance/input fixes and Brush Mask v1 onto current `origin/main` without regressing mainline Sidecar v4 snapshots, curation, RAW recipe fail-closed behavior, existing local masks, or the split Mac/iPad editor architecture.

**Architecture:** Work only in `codex/mainline-wb-brush-integration`, based on `82542e73aae8f16b0ba7e4d9d36a8a42451a7319`. Port behavior rather than merging the unrelated source history. Extend mainline data to Sidecar v5, keep existing `LocalAdjustmentKind.brush` intact, add an independent `PhotoAdjustments.brushMasks` pipeline stage before geometry, and adapt white-balance/input behavior inside mainline's resolved RAW recipe and split iPad composition.

**Tech Stack:** Swift 6, SwiftUI, AppKit/UIKit bridges, Core Image, XCTest, Swift Package Manager, Xcode iOS builds.

## Global Constraints

- `origin/main` is the sole integration baseline; do not merge or rebase the unrelated source branch.
- Preserve all mainline `PhotoAdjustments`, curation, snapshot, RAW recipe, profile, preview, export, library, batch, release, and privacy behavior.
- Preserve the source worktree and its 34 dirty/untracked paths byte-for-byte; never import its local signing project change.
- Use test-first RED → GREEN → REFACTOR for every product behavior.
- Sidecar format becomes v5; v1-v5 are readable, v6+ is rejected without quarantine or overwrite.
- Existing `LocalAdjustmentKind.brush` and new `brushMasks` coexist and render once each.
- Adobe-compatible rendering remains fail-closed: feature flag off, production registry empty, effective output Native.
- No push, merge, rebase, release, app replacement, worktree deletion, or branch deletion in this plan.
- Keep `PASS`, `FAIL`, `SKIPPED`, and `NOT RUN` distinct; physical-device and calibrated Lightroom gates cannot be inferred from automated tests.

---

### Task 1: Freeze Baselines and Record the Integration Contract

**Files:**
- Create: `docs/superpowers/specs/2026-10-05-mainline-white-balance-brush-integration.md`
- Modify: `docs/coordination/CURRENT.md`
- Modify: `docs/coordination/DECISIONS.md`
- Create outside Git: a sanitized source manifest and hash inventory under the task's private evidence directory

**Interfaces:**
- Consumes: mainline HEAD `82542e7`, source HEAD `5a80e96`, source dirty inventory.
- Produces: stable P0 evidence, v5 decision, task ownership, and exact next action for all later tasks.

- [ ] **Step 1: Recheck the two repositories and source manifest**

Run branch/HEAD/status/worktree checks and generate a path/status/hash manifest for all source dirty and untracked files. Verify it still contains 24 modified and 10 untracked paths and excludes `Apps/LumaHarborPad.xcodeproj/project.pbxproj` from import.

- [ ] **Step 2: Add the approved integration spec to the target repository**

Copy the approved behavior contract into the repository without any private absolute paths. Record Sidecar v5 and dual-brush coexistence as new decisions rather than rewriting D-006.

- [ ] **Step 3: Record ownership and baseline in CURRENT.md**

Add branch, base SHA, writer, clean start, source read-only rule, phase P1, and the next test to write. Do not claim implementation or verification.

- [ ] **Step 4: Verify documentation integrity**

Run: `git diff --check`

Expected: exit 0; no private source path, signing value, fixture path, or placeholder in the new documents.

### Task 2: Port White-Balance Core Semantics into the Mainline RAW Recipe

**Files:**
- Create: `Sources/RawProcessingCore/Model/WhiteBalancePresentation.swift`
- Modify: `Sources/RawProcessingCore/Model/WhiteBalanceEyedropper.swift`
- Modify: `Sources/RawProcessingCore/Model/AdjustmentMapping.swift`
- Modify: `Sources/RawProcessingCore/Decoding/CoreImageRawDecoder.swift`
- Modify: `Sources/RawProcessingCore/Model/PhotoAdjustments.swift`
- Modify: `Sources/PresetCore/Application/PresetApplicator.swift`
- Test: `Tests/RawProcessingCoreTests/WhiteBalancePresentationTests.swift`
- Test: `Tests/RawProcessingCoreTests/WhiteBalanceEyedropperTests.swift`
- Test: `Tests/RawProcessingCoreTests/RawDecodingTests.swift`
- Test: `Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift`
- Test: `Tests/PresetCoreTests/PresetApplicatorTests.swift`

**Interfaces:**
- Consumes: `RawRenderRecipeResolver`, mainline recipe/profile/lens inputs, `AdjustmentCatalog` ranges.
- Produces: `WhiteBalanceResolution`, exact Kelvin/stored-offset conversion, valid commit candidates, decoder last-line defense.

- [ ] **Step 1: Write failing boundary and direction tests**

Add tests equivalent to:

```swift
func testResolverClampsStoredOffsetAndDecoderKelvinTogether() throws {
    let result = try WhiteBalancePresentation.resolve(
        storedOffset: -175.79691980772682,
        baselineKelvin: 4536.72802734375
    )
    XCTAssertEqual(result.effectiveKelvin, 2000, accuracy: 0.01)
    XCTAssertEqual(4536.72802734375 + result.effectiveStoredOffset * 45, 2000, accuracy: 0.01)
}

func testGreenSampleProducesPositiveTintCorrection() throws {
    let correction = try WhiteBalanceEyedropper.correction(for: .init(red: 0.4, green: 0.6, blue: 0.4))
    XCTAssertGreaterThan(correction.tint, 0)
}
```

Cover baselines 2000, 4536.72802734375, 5500, 10000, and 50000; NaN/Infinity/nonpositive baseline; legacy finite out-of-range preservation; decoder Float error ≤0.01 K; old Tint mapping unchanged.

- [ ] **Step 2: Run RED tests**

Run: `swift test --filter 'WhiteBalancePresentationTests|WhiteBalanceEyedropperTests|RawDecodingTests|PresetApplicatorTests'`

Expected: new resolver API and green-to-magenta direction assertions fail for the intended missing behavior.

- [ ] **Step 3: Implement the minimal shared resolver**

Use the exact contract:

```swift
let storedRange = -1200.0...1200.0
let kelvinRange = 2000.0...50000.0
let kelvinPerUnit = 45.0
let permitted = max(storedRange.lowerBound, (kelvinRange.lowerBound - baseline) / kelvinPerUnit)
    ...min(storedRange.upperBound, (kelvinRange.upperBound - baseline) / kelvinPerUnit)
```

New writes use the effective offset. Legacy loads retain the original finite stored value until explicit white-balance edit/reset while preview/export resolve the safe value and diagnostic. Invalid/missing baseline never invents 5500 K.

- [ ] **Step 4: Wire the resolver through mainline recipe/decode/preset paths**

Retain `rawRenderingCompatibility`, lens correction, camera-profile request, resolved recipe, configured render service, and Native fallback. Do not replace mainline decode request with the older source request.

- [ ] **Step 5: Run GREEN and regression tests**

Run the Task 2 filter plus `PreviewExportRecipeParityTests`, `RawRenderRecipeResolverTests`, and `DCPProfileFailClosedTests`.

Expected: all selected tests pass; Adobe-enabled execution remains unreachable by default.

### Task 3: Port Native Numeric Input and Revision-Safe Eyedropper Sessions

**Files:**
- Create/modify: `Sources/AdjustmentUI/AdjustmentEditingContext.swift`
- Create/modify: `Sources/AdjustmentUI/AdjustmentInputState.swift`
- Create/modify: `Sources/AdjustmentUI/AdjustmentInputController.swift`
- Create/modify: `Sources/AdjustmentUI/AdjustmentNativeTextField.swift`
- Modify: `Sources/AdjustmentUI/AdjustmentValueInput.swift`
- Modify: `Sources/AdjustmentUI/BasicAdjustmentPanel.swift`
- Modify: `Sources/EditorCore/EditorSession.swift`
- Modify: `Sources/LumaHarborApp/Views/EyedropperOverlayView.swift`
- Modify: mainline iPad canvas/inspector/coordinator files as resolved by search
- Test: `Tests/AdjustmentUITests/AdjustmentInputStateTests.swift`
- Test: `Tests/AdjustmentUITests/AdjustmentValueInputNativeTests.swift`
- Test: `Tests/EditorCoreTests/EditorSessionEyedropperRenderingTests.swift`
- Test: `Tests/EditorCoreTests/EyedropperDeferredResultTests.swift`
- Test: `Tests/EditorCoreTests/WhiteBalanceWriteBoundaryTests.swift`

**Interfaces:**
- Consumes: Task 2 resolver, mainline editor revision/history/render intent APIs.
- Produces: exact text draft lifecycle, photo/revision/frame-bound eyedropper candidate, stale-result rejection.

- [ ] **Step 1: Write failing UI-state tests**

Cover `6500 → 60000 → Enter → blur` restoring 6500 with zero setter calls, exact 4536.72802734375 focus/blur with no quantization, `7000 → Escape → blur` with no commit, Enter followed by blur committing once, same numeric value on a different photo invalidating the old draft.

- [ ] **Step 2: Write failing session race tests**

Cover valid sample then exposure edit, A→B→A, reset, preset, Undo/Redo, geometry change, snapshot restore, valid→invalid→release, delayed image/histogram/error, neutral resample restoring pixels and every histogram bin.

- [ ] **Step 3: Verify RED**

Run: `swift test --filter 'AdjustmentInputStateTests|AdjustmentValueInputNativeTests|EditorSessionEyedropperRenderingTests|EyedropperDeferredResultTests|WhiteBalanceWriteBoundaryTests'`

Expected: failures identify absent native bridge/revision guards, never only test fixture errors.

- [ ] **Step 4: Implement minimal input and session state**

Use a value state keyed by field/photo/revision, with authoritative exact Double, initial text, draft, dirty flag, ended flag, and error. Commit only once on valid changed Enter/blur; invalid or Escape ends the session and synchronizes visible native text.

Eyedropper candidate and async render intents carry photo ID, session identity, edit revision, source frame/mapping, and gesture token. Any authoritative edit or photo/frame change invalidates the token before actor hops return.

- [ ] **Step 5: Wire Mac and the split iPad composition**

Add the shared eyedropper control to current `PadEditorCanvasView`/`PadInspectorHost`/coordinator. Preserve current inspector composition and all mainline adjustment rows. Keep 44 pt hit regions and eight-language strings.

- [ ] **Step 6: Run GREEN and affected UI tests**

Run the Task 3 filter plus mainline Inspector, Pad layout, Filmstrip, and Snapshot workflow suites.

Expected: selected tests pass with no duplicate submit or stale result.

### Task 4: Introduce Sidecar v5 and Dual Brush Data Contracts

**Files:**
- Create: `Sources/RawProcessingCore/Model/BrushMask.swift`
- Modify: `Sources/RawProcessingCore/Model/PhotoAdjustments.swift`
- Modify: `Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift`
- Modify: `Sources/PhotoLibraryCore/Sidecar/SidecarRepository.swift`
- Modify: `Sources/PhotoLibraryCore/Service/CurationMigration.swift`
- Modify: relevant document-store save paths
- Test: `Tests/RawProcessingCoreTests/BrushMaskTests.swift`
- Test: `Tests/RawProcessingCoreTests/PhotoAdjustmentsTests.swift`
- Test: `Tests/PhotoLibraryCoreTests/SidecarRepositoryTests.swift`
- Test: `Tests/PhotoLibraryCoreTests/CurationMigrationDecisionTests.swift`
- Test: `Tests/PhotoLibraryCoreTests/SnapshotModelTests.swift`

**Interfaces:**
- Consumes: mainline curation/snapshot contracts and `AdjustmentCatalog`.
- Produces: `PhotoAdjustments.brushMasks: [BrushMask]`, Sidecar v5, strict brush validation, safe old/new schema handling.

- [ ] **Step 1: Write failing v5 and persistence tests**

Test v1-v4 missing brush arrays as empty, source experimental v3 brush JSON, v5 full round trip, v6 rejection with byte/mtime preservation, no-op load without version write, valid edit upgrading to v5, unknown top-level preservation, and old v4 reader rejecting v5.

Add the two mainline bug tests: v3/v4 curation beats conflicting SQLite regardless of current schema version, including explicitly neutral curation; deleting the last snapshot removes it after write/reopen rather than resurrecting an unknown top-level key.

- [ ] **Step 2: Write failing dual-brush/model-copy tests**

Assert existing `LocalAdjustmentKind.brush` remains unchanged while `brushMasks` survives initializer, Codable, `clamped()`, neutral/reset, snapshots, copy/paste, history, and non-local preset application.

- [ ] **Step 3: Verify RED**

Run: `swift test --filter 'BrushMaskTests|PhotoAdjustmentsTests|SidecarRepositoryTests|CurationMigrationDecisionTests|SnapshotModelTests'`

Expected: failures for missing brush model/v5 and the snapshot known-key case.

- [ ] **Step 4: Implement BrushMask and Sidecar v5**

Preserve source-coordinate renderer version 1. Validate exposure/contrast/highlights/shadows/whites/blacks/saturation/temperature/tint through `AdjustmentCatalog`: nil and closed-range endpoints pass; out-of-range and non-finite values throw; no silent clamp/drop/default.

Make curation authority depend on curation schema/key semantics, not equality with latest schema. Add `snapshots` to repository-owned top-level keys while preserving truly unknown keys. All writers reject newer schemas before replacing them.

- [ ] **Step 5: Run GREEN and broader persistence tests**

Run Task 4 filter plus curation durability, document store, snapshot workflow, preset, batch, and virtual-copy tests.

Expected: all pass; no source RAW write.

### Task 5: Add Brush Rendering and Mainline Geometry Mapping

**Files:**
- Create: `Sources/RawProcessingCore/Pipeline/BrushMaskRenderer.swift`
- Create: `Sources/RawProcessingCore/Model/BrushCoordinateMapping.swift`
- Modify: `Sources/RawProcessingCore/Pipeline/GeometryRenderer.swift` only as needed to share authoritative transforms
- Modify: `Sources/RawProcessingCore/Preview/PreviewRequest.swift`
- Modify: `Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift`
- Modify: `Sources/RawProcessingCore/Export/PhotoExporter.swift`
- Test: `Tests/RawProcessingCoreTests/BrushMaskTests.swift`
- Test: `Tests/RawProcessingCoreTests/BrushCoordinateMappingTests.swift`
- Test: `Tests/RawProcessingCoreTests/GeometryRendererTests.swift`
- Test: `Tests/RawProcessingCoreTests/CoreImagePreviewRendererTests.swift`
- Test: export parity tests

**Interfaces:**
- Consumes: Task 4 brush models, mainline `GeometryRenderer`, resolved RAW recipe.
- Produces: source/display forward+inverse mapper, `PreviewImage.brushCoordinateMapping`, preview/export pipeline stage.

- [ ] **Step 1: Write RED renderer/sampling tests**

Cover noncentral quadrants, non-square/nonzero extent, paint/erase, sparse vs dense collinear segments, repeated points, corners, low flow/nonzero feather, and strict patch boundary cases. Original BR-F01/F03/F04 counterexamples must fail first.

- [ ] **Step 2: Write RED geometry and independent-oracle tests**

Cover identity, H/V/H+V, 90/180/270, noncentral crop, straighten ±10°, perspective H/V ±25, combined transforms, transparent-corner rejection, and inverse→renderer pixels using a non-symmetric landmark image. Identity-negative control must miss the expected flipped point.

- [ ] **Step 3: Verify RED**

Run: `swift test --filter 'BrushMaskTests|BrushCoordinateMappingTests|GeometryRendererTests|CoreImagePreviewRendererTests'`

- [ ] **Step 4: Implement renderer and mapper**

Render order is global adjustments → new brush masks → geometry → existing local adjustments. Use fixed arc spacing `max(size / 8, 1 / shortSide)`. Keep one meaning for cross-segment remaining distance. Reject invalid/outside/noninvertible mapping rather than identity fallback or clamping.

- [ ] **Step 5: Integrate preview and export without replacing mainline recipe code**

`PreviewImage` retains raw recipe and baseline while adding same-revision mapping metadata. Export uses the same brush renderer and ordering before its existing size/color/encode path. Preview-only professional overlays never enter export.

- [ ] **Step 6: Run GREEN and recipe/pixel regression suites**

Expected: all selected tests pass; empty brush arrays reproduce mainline pixels within the existing test contract.

### Task 6: Add Brush Gesture, History, Clipboard, Snapshot, and Autosave Behavior

**Files:**
- Modify: `Sources/EditorCore/EditorSession.swift`
- Modify: `Sources/EditorCore/EditorToolMode.swift`
- Modify: Mac/iPad clipboard models and batch application paths
- Test: new editor brush gesture/session tests
- Test: `Tests/LumaHarborAppTests/AdjustmentClipboardWorkflowTests.swift`
- Test: `Tests/AdjustmentUITests/PadAdjustmentClipboardTests.swift`
- Test: `Tests/EditorCoreTests/SnapshotWorkflowTests.swift`
- Test: document persistence tests

**Interfaces:**
- Consumes: Task 5 mapping and Task 3 revision tokens.
- Produces: `.brushMask` tool, typed selection identity, one-commit gestures, local opt-in clipboard, snapshot/autosave round trips.

- [ ] **Step 1: Write RED gesture/history tests**

Test activate-without-stroke, valid press/move/release as one history entry, cancel/empty/outside/invalid release as zero entries, gap path separation, delete/Undo/Redo, and stale release after photo/geometry/Undo/snapshot/cancel.

- [ ] **Step 2: Write RED clipboard/snapshot/persistence tests**

Local off preserves both local arrays; Local on replaces both, including empty source. Test source/target geometry, Mac/iPad equivalence, batch conflict guard, snapshot create/restore/compare, and real repository/session reopen.

- [ ] **Step 3: Verify RED and implement minimal session behavior**

Add an independent `.brushMask` tool and selection discriminator so existing `.brush` continues to address mainline local masks. Freeze photo/revision/mapping/settings on press; move is transient; release submits once.

- [ ] **Step 4: Wire save scheduling and failure behavior**

Autosave only after valid committed edits. Preserve offline/read-only/failure messages and never claim saved when disk write fails.

- [ ] **Step 5: Run GREEN and full editor/document filters**

Expected: tests pass and RAW fingerprints stay unchanged.

### Task 7: Add Mac and iPad Brush UI without Regressing Mainline Inspector Structure

**Files:**
- Create: `Sources/AdjustmentUI/BrushMaskOverlayView.swift`
- Modify: `Sources/AdjustmentUI/LocalAdjustmentsPanel.swift`
- Modify: `Sources/LumaHarborApp/Views/EditorView.swift`
- Modify: current iPad canvas/model/inspector/coordinator files
- Modify: eight localization files
- Test: `Tests/AdjustmentUITests/BrushMaskContractTests.swift`
- Test: mainline inspector/layout/accessibility tests

**Interfaces:**
- Consumes: Task 6 session APIs and Task 5 mapper.
- Produces: adjustment-brush section, paint/erase controls, cursor/path overlay, Mac+iPad wiring.

- [ ] **Step 1: Write RED source and behavior contracts**

Assert old mask controls remain, the new section routes to `.brushMask`, all controls have 44 pt/accessibility/localized labels, and Mac/iPad both use the same overlay/session APIs.

- [ ] **Step 2: Verify RED and implement the minimal UI**

Add adjustment brush creation, selection, enable/delete, paint/erase, size/feather/flow/density, and exposure patch. Keep current inspector grouping and split iPad files. Cursor and saved paths use the same forward mapper and source-short-side footprint.

- [ ] **Step 3: Run GREEN and affected UI contract suites**

Run BrushMaskContract, AdvancedMaskPanelContract, Inspector, Pad composition/layout, accessibility, and cross-device parity tests.

- [ ] **Step 4: Perform foreground Mac and iPad Simulator acceptance**

Use an isolated test home/library and copy of a RAW. Record exact flows: numeric input, eyedropper, noncentral paint/erase, flip/crop, cancel, Undo/Redo, Local copy/paste, autosave/reopen, portrait/landscape/zoom. Do not use the daily app or unique photo originals.

### Task 8: Full Verification, Performance, Privacy, and Handoff

**Files:**
- Create: `docs/testing/reports/2026-10-05-mainline-white-balance-brush-integration.md`
- Modify: `docs/coordination/CURRENT.md`
- Create: a handoff document from `docs/coordination/HANDOFF_TEMPLATE.md` if required by the project state

**Interfaces:**
- Consumes: all implementation tasks and observed commands.
- Produces: auditable acceptance matrix and bounded next action.

- [ ] **Step 1: Run focused and complete tests in fresh scratch directories**

Run the focused union, full `swift test`, strict-concurrency build, Release Mac product build, and generic iPad Simulator/device unsigned builds. Record every exit code, executed/skipped/failure count, and zero-test mistake.

- [ ] **Step 2: Run available private RAW tests without publishing private identifiers**

Run `RawFixtureTests` with the verified local fixture environment. Record only sanitized counts and source immutability result. Missing material remains NOT RUN/SKIPPED.

- [ ] **Step 3: Run pixel and performance comparisons**

Interleave baseline/current after warmup for at least eight samples and two rounds. Record 1600px preview and available full-resolution export, p50/p95, peak memory, cancellation, empty brush, one-mask, and ten-mask loads. Empty-brush p50 regression budget is `max(5 ms, baseline × 5%)`.

- [ ] **Step 4: Run privacy and diff checks**

Run `git diff --check`, text/history scans for private paths/signing/fixtures, Mac app privacy scan, and a non-published package/unzip privacy check in a fresh output directory. Verify source worktree hash inventory remains unchanged.

- [ ] **Step 5: Record manual/device gates honestly**

If a physical iPad test deployment is authorized and available, install the TARGET build and run touch/orientation/reopen behavior. Apple Pencil, keyboard, VoiceOver, Lightroom gray-card, and Gate 2 are separately PASS/FAIL/NOT RUN. A generic build does not satisfy them.

- [ ] **Step 6: Complete report and coordination handoff**

List branch, full base/HEAD, changed files, actual tests, known failures, skipped/not-run gates, dirty state, concerns, and one next action. Use `DONE_WITH_CONCERNS` while any required manual/material gate remains NOT RUN. Do not push or merge.
