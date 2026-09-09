# Professional Editing Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the existing Mac/iPad editing parity contract on iPad without duplicating adjustment or export business logic.

**Architecture:** Keep `EditorSession`, `PhotoAdjustments`, `AdjustmentPatch`, `PhotoExporter`, and `BatchAdjustmentSyncService` authoritative. Add only presentation adapters and narrowly scoped shared policies; `PadEditorView` composes them, while `AdjustmentUI` owns controls and coordinate contracts.

**Tech Stack:** Swift 5.9+, SwiftUI, XCTest, Swift Package Manager, Xcode iPad target.

## Global Constraints

- RAW 原檔永遠不修改、搬移或刪除。
- 預覽、滑動與遮罩拖曳不直接寫 sidecar；只有 commit／autosave 才寫入。
- Mac 與 iPad 使用相同 stable field ID，不因平台新增同義欄位。
- 取消不是失敗；錯誤文案不可露出原始路徑、bookmark data、帳號、Team ID、UDID 或 provider identifier。
- 不修改本機簽章設定，不把 `.ipa`、`.mobileprovision`、`.p12` 或 signing identity 放進 Git。

## File Map

- `Sources/AdjustmentUI/AdjustmentValueInput.swift`: cross-platform numeric input and neutral reset affordance.
- `Sources/AdjustmentUI/AdjustmentSliderRow.swift`: use numeric input and gesture hooks consistently.
- `Sources/AdjustmentUI/PadAdjustmentPolicy.swift`: pure ranges, formatting, and reset-section policy for iPad.
- `Sources/EditorCore/EditorSession.swift`: expose one compound adjustment transaction for geometry/local and batch-safe reset.
- `Sources/PhotoLibraryCore/Batch/BatchAdjustmentSyncService.swift`: expose a reusable field-selection sync result and undo input.
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift`: compose real Geometry/Local/Adjust controls, batch command surface, and export options.
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadExportOptions.swift`: iPad export option state and request mapping.
- `Tests/AdjustmentUITests/AdjustmentValueInputTests.swift`: numeric input policy tests.
- `Tests/AdjustmentUITests/PadEditingContractTests.swift`: iPad domain and control wiring contracts.
- `Tests/EditorCoreTests/EditorSessionEditingTests.swift`: compound transaction and reset behavior.
- `Tests/PhotoLibraryCoreTests/BatchAdjustmentSyncServiceTests.swift`: field selection, partial result, and undo inputs.

### Task 1: Numeric editing policy and control

**Files:** Create `Sources/AdjustmentUI/AdjustmentValueInput.swift`, `Sources/AdjustmentUI/PadAdjustmentPolicy.swift`, `Tests/AdjustmentUITests/AdjustmentValueInputTests.swift`; modify `Sources/AdjustmentUI/AdjustmentSliderRow.swift`.

**Interfaces:** `PadAdjustmentPolicy.clamp(_:range:)`, `PadAdjustmentPolicy.parse(_:range:fractionDigits:)`, `PadAdjustmentPolicy.formatted(_:fractionDigits:)`; `AdjustmentValueInput` accepts a `Binding<Double>`, range, fraction digits, and reset closure.

- [ ] Write tests for finite clamping, invalid text rejection, rounding, and neutral reset.
- [ ] Run focused tests and verify the new policy tests fail before implementation.
- [ ] Implement the pure policy and a compact `TextField` numeric input with `.decimalPad` on iPad and keyboard-safe submit behavior on Mac.
- [ ] Replace the value-only label in `AdjustmentSliderRow` with the reusable input while preserving slider editing callbacks and accessibility.
- [ ] Run `swift test --filter 'AdjustmentValueInputTests|AdjustmentGroupPanelsContractTests'`.
- [ ] Commit `feat: add precise adjustment input policy`.

### Task 2: iPad Adjust/Geometry/Local composition

**Files:** Modify `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift`; add `Tests/AdjustmentUITests/PadEditingContractTests.swift`.

**Interfaces:** `PadEditorView.adjustContent` must render the existing public `BasicAdjustmentPanel`, `ColorAdjustmentPanel`, `CurveAdjustmentPanel`, `DetailAdjustmentPanel`, `EffectsAdjustmentPanel`, `GeometryAdjustmentPanel`, and `LocalAdjustmentsPanel` through the shared `EditorSession`.

- [ ] Add source contracts for all three Adjust submodes, Geometry, Local, and reset/precise input affordances.
- [ ] Run the contract test and confirm it fails for any missing domain wiring.
- [ ] Keep the existing panel composition, add section-level reset and explicit Geometry/Local presentation in the rail host, and ensure the active canvas tool follows the selected domain.
- [ ] Add a single shared `image-to-canvas` transform adapter for crop, gradient, and spot-heal overlays; do not duplicate scale math in the iPad view.
- [ ] Run focused UI contracts and Swift syntax parsing.
- [ ] Commit `feat: complete iPad adjustment domains`.

### Task 3: Batch copy/paste/sync contract

**Files:** Modify `Sources/EditorCore/EditorSession.swift`, `Sources/PhotoLibraryCore/Batch/BatchAdjustmentSyncService.swift`, `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift`; add/update the corresponding core tests.

**Interfaces:** use `AdjustmentPatch.extracting`, `EditorSession.pasteAdjustments(patch:geometry:localAdjustments:)`, and `BatchAdjustmentSyncService.syncPatch` as the only write paths. Add a result summary containing affected, failed, and skipped IDs without raw error details.

- [ ] Add tests for selected-field patch extraction, Geometry/Local opt-in, compound undo input, and partial failure summary.
- [ ] Run those tests to establish failing expectations.
- [ ] Add iPad clipboard state with explicit field selection; copy never includes rating, flag, or keyword.
- [ ] Add batch-bar actions for paste, sync-to-selected, and virtual copy with target counts and cancellation.
- [ ] Keep one compound undo boundary per sync operation; use safe localized failure messages.
- [ ] Run `swift test --filter 'EditorSessionEditingTests|BatchAdjustmentSyncServiceTests|PadBatchContractTests'`.
- [ ] Commit `feat: expose iPad batch adjustment workflow`.

### Task 4: Export request parity

**Files:** Create `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadExportOptions.swift`; modify `PadEditorView.swift`; add `Tests/AdjustmentUITests/PadExportOptionsTests.swift` and extend `PadEditorExportContractTests.swift`.

**Interfaces:** `PadExportOptions` maps to the existing `ExportRequest`; no platform-specific encoder or second render path.

- [ ] Test format availability, quality/bit depth, max dimensions, DPI, EXIF policy, filename tokens, and collision policy mapping.
- [ ] Run tests to verify the missing options fail.
- [ ] Implement the option state and present it from the existing single export entry point; reuse `PhotoExporter` and existing Files/Photos/Share destinations.
- [ ] Add per-file progress and cancellation state without exposing private paths.
- [ ] Run focused export tests and simulator build with signing disabled.
- [ ] Commit `feat: add iPad export options`.

### Task 5: Library metadata and keyword durability

**Files:** Modify the shared PhotoLibraryCore migration/repository/query code and `PadLibraryGrid.swift`; add migration, query, and UI contract tests.

- [ ] Add a migration test proving rating, flag, and keyword survive index rebuild/restore through the authoritative store.
- [ ] Run the migration test to establish the current durability gap.
- [ ] Route iPad batch metadata edits through the same `PhotoIndexStore` APIs as Mac; clear only invalid selections after query scope changes.
- [ ] Add keyword editor with normalized matching and preserved display spelling.
- [ ] Run PhotoLibraryCore tests and focused iPad contracts.
- [ ] Commit `feat: complete iPad metadata batch editing`.

### Task 6: Verification and release evidence

**Files:** update `docs/testing/reports/2026-09-09-professional-editing-phase1.md` and, only if required by tests, the relevant contract tests.

- [ ] Run focused Swift tests with a scratch path that has sufficient free space.
- [ ] Run `git diff --check` and the privacy scan for signing material, personal identifiers, and absolute paths.
- [ ] Run simulator build with `CODE_SIGNING_ALLOWED=NO`; record result and exact command.
- [ ] Run device build only after the user empties the macOS Trash or otherwise frees disk space; record `NOT RUN` when blocked.
- [ ] Record remaining gaps honestly: real-device visual QA, full advanced masking, lens profiles, and Phase 2+ features are not Phase 1 completion criteria.
- [ ] Commit `docs: record professional editing phase1 verification`.
