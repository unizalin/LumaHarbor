# Implementation Plan: Snapshots, Soft Proof, and Professional Preview (P6)

Date: 2026-09-11
Phase: P6

## Overview

Implement Edit Snapshots (CRUD + restore compound undo), Sidecar Schema v4 migration, A/B comparison session state, Clipping/Gamut overlays, and Soft Proof preview pipeline, followed by Mac/iPad UI and 8-language localization.

## Task Breakdown

### Task 1: Core Models & Sidecar v4 (TDD)
- Define `EditSnapshot` in `Sources/PhotoLibraryCore/Model/EditSnapshot.swift`.
- Bump `PhotoSidecar.currentSchemaVersion = 4` in `Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift` and add `snapshots: [EditSnapshot]`.
- Update `SidecarSchemaCompatibilityTests` to verify v1, v2, v3, and v4 decode compatibility.
- Write unit tests in `Tests/PhotoLibraryCoreTests/SnapshotModelTests.swift`.

### Task 2: Snapshot Management & Compound Undo (TDD)
- Add Snapshot management API to `PhotoLibraryService` or `EditorSession`:
  - `createSnapshot(name:)`
  - `renameSnapshot(id:newName:)`
  - `duplicateSnapshot(id:)`
  - `deleteSnapshot(id:)`
  - `restoreSnapshot(id:)`
- Ensure restore invokes `updateAdjustments` in a single compound transaction so a single `undo()` cleanly reverts to the pre-restore state.
- Write unit tests in `Tests/EditorCoreTests/SnapshotWorkflowTests.swift`.

### Task 3: Professional Preview Renderer & Overlays (TDD)
- Define `ProfessionalPreviewOptions` and `SoftProofProfile` in `Sources/RawProcessingCore/Preview/ProfessionalPreviewOptions.swift`.
- Implement `ProfessionalPreviewRenderer` in `Sources/RawProcessingCore/Preview/ProfessionalPreviewRenderer.swift`:
  - Highlight clipping mask (Red indicator for pixel values >= 0.99).
  - Shadow clipping mask (Blue indicator for pixel values <= 0.01).
  - Gamut warning overlay.
  - Soft proof color space conversion.
- Write unit tests in `Tests/RawProcessingCoreTests/ProfessionalPreviewFilterTests.swift`.

### Task 4: EditorSession A/B Comparison & Preview Options Wiring
- In `EditorSession`:
  - Add `@Published public var previewOptions: ProfessionalPreviewOptions`.
  - Add `@Published public var comparisonSnapshot: EditSnapshot?`.
  - Wire `toggleABCompare()` session method (does not mutate `adjustments` or write sidecar).
  - Connect preview rendering with preview options.

### Task 5: UI Integration (Mac & iPad) & Localization
- Create `SnapshotsPanel.swift` in `Sources/AdjustmentUI/SnapshotsPanel.swift`.
- Add Professional Preview toolbar items (Clipping toggles, Gamut toggle, Soft Proof picker, A/B toggle) to `EditorView` and `PadEditorView`.
- Add 8-language localization strings.
- Update `EightLanguageLocalizationGateTests`.

### Task 6: Full Verification
- Run `swift test` (ensure all tests pass, 0 failures).
- Run `swift build -Xswiftc -strict-concurrency=complete`.
- Run iPad Simulator `xcodebuild`.
- Run `git diff --check` and privacy scan.
- Update `CURRENT.md` and write handoff.
- Create P6 commit.
