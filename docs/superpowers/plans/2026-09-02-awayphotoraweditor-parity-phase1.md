# AwayPhotoRawEditor Parity Phase 1：Mac Foundation Implementation Plan

> **For agentic workers:** 用 task-by-task 方式執行。每個 task 都要先寫失敗測試或 source-contract，再實作到 GREEN。不要把 Phase 2 的 batch、virtual copy、local retouching 或八語 localization 混進來。

**Goal:** 先把 macOS 編輯主畫面的對標基礎補齊：使用者能看到照片 metadata / EXIF、看見目前渲染結果的 histogram、在 Mac inspector 裡使用已存在的調整能力，並用更完整的單張匯出設定輸出成品。

**Architecture:** 核心能力放在 `RawProcessingCore` / `EditorCore` / `PhotoLibraryCore`，macOS SwiftUI 只負責呈現與操作。iPadOS 這輪不做完整 UI parity，但資料模型與 service 不得讓 iPad 後續無法共用。

**Base:** local `main` at `8a400edb0f07082d157abb28b9c688d18db98f34`.

## Global Constraints

- RAW 原檔永不修改；所有調整、匯出、metadata 顯示都不得寫回來源照片。
- AwayPhotoRawEditor 只作功能參考，不複製 WinForms 原始碼、圖示、字串或平台專屬設計。
- 使用者可見字串必須走 localization；這輪至少維持 English + zh-Hant key parity。
- `PASS`、`FAIL`、`SKIPPED`、`NOT RUN` 必須分清楚記錄。
- 不提交本機 Xcode signing、Apple Team ID、裝置 UDID、私人路徑、fixture 絕對路徑。
- 不做 LibRaw、ExifTool、批次、virtual copy、local healing、linear gradient、八語翻譯與 release packaging。

## File Structure

Likely files in scope:

- `Sources/RawProcessingCore/Model/RawMetadata.swift`
- `Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift`
- `Sources/RawProcessingCore/Export/JPEGExporter.swift`
- `Sources/RawProcessingCore/Export/`
- `Sources/EditorCore/`
- `Sources/Localization/Resources/en.lproj/Localizable.strings`
- `Sources/Localization/Resources/zh-Hant.lproj/Localizable.strings`
- `Apps/LumaHarborApp/Views/EditorView.swift`
- `Apps/LumaHarborApp/Views/InspectorView.swift`
- `Tests/RawProcessingCoreTests/`
- `Tests/EditorCoreTests/`
- `Tests/LumaHarborAppTests/`
- `docs/coordination/CURRENT.md`
- `docs/testing/reports/2026-09-02-awayphotoraweditor-parity-phase1.md`

Do not edit iPad app files unless a shared model/API rename forces a compile fix.

---

## Task 1: Metadata / EXIF snapshot contract

**User outcome:** 在 Mac editor 右側面板能看見檔名、格式、像素、檔案大小、相機、鏡頭、焦距、光圈、快門、ISO、拍攝時間、orientation 與 sidecar/save 狀態。

**Files:**

- Modify: `Sources/RawProcessingCore/Model/RawMetadata.swift`
- Modify/Add: `Sources/EditorCore/EditorMetadataSnapshot.swift`
- Modify: `Apps/LumaHarborApp/Views/InspectorView.swift`
- Test: `Tests/RawProcessingCoreTests/`
- Test: `Tests/EditorCoreTests/`
- Test: `Tests/LumaHarborAppTests/`

**Steps:**

- [ ] Add tests proving `RawMetadata` can carry the Phase 1 visible fields while decoding old/minimal metadata as safe nil/default values.
- [ ] Add an `EditorMetadataSnapshot` or equivalent view-facing model that formats optional metadata without leaking absolute source paths.
- [ ] Add source-contract tests that `InspectorView` renders a dedicated metadata / EXIF section and does not hard-code user-visible labels outside localization.
- [ ] Implement the smallest model and UI changes needed for GREEN.
- [ ] Verify metadata panel still shows safe placeholders when fields are missing.

**Acceptance:**

- Missing EXIF never crashes the editor.
- File path shown to users is basename or source-safe display name, not private absolute path.
- Existing RAW fixture tests still pass.

---

## Task 2: Rendered histogram service

**User outcome:** Histogram 反映目前預覽渲染結果，不只是原圖統計。調整曝光、對比或飽和度後，histogram 會跟著變。

**Files:**

- Add/Modify: `Sources/RawProcessingCore/Histogram/`
- Modify: `Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift` only if histogram needs a shared rendered-image hook.
- Modify: `Sources/EditorCore/`
- Modify: `Apps/LumaHarborApp/Views/InspectorView.swift`
- Test: `Tests/RawProcessingCoreTests/`
- Test: `Tests/EditorCoreTests/`
- Test: `Tests/LumaHarborAppTests/`

**Steps:**

- [ ] Add deterministic tests for RGB histogram binning from tiny synthetic images.
- [ ] Add a test proving histogram input is post-adjustment rendered pixels by comparing neutral vs exposure-adjusted fixture output.
- [ ] Add an editor-level test proving histogram refresh is versioned with preview/adjustment changes and ignores stale async results.
- [ ] Render RGB composite plus per-channel counts in Mac inspector.
- [ ] Keep computation cancellable or cheap enough not to block slider interaction.

**Acceptance:**

- Histogram uses rendered preview pixels.
- Stale histogram results cannot overwrite newer adjustments.
- Empty/failed preview states show clear localized fallback copy.

---

## Task 3: Mac adjustment inspector productization

**User outcome:** Mac 版右側 inspector 不只是基本 slider，而是能清楚操作既有的 Basic、Color、Curve、Detail、Effects 調整群組，接近 AwayPhotoRawEditor 的完整調整工作流第一版。

**Files:**

- Modify: `Apps/LumaHarborApp/Views/InspectorView.swift`
- Modify/Add: `Apps/LumaHarborApp/Views/Adjustment*`
- Modify: `Sources/Localization/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/Localization/Resources/zh-Hant.lproj/Localizable.strings`
- Test: `Tests/LumaHarborAppTests/`
- Test: `Tests/RawProcessingCoreTests/AdjustmentCatalogTests.swift`

**Steps:**

- [ ] Add source-contract tests that all `AdjustmentCatalog.groups` are reachable from the Mac inspector.
- [ ] Add tests for reset-to-neutral UI affordance per adjustment or per group.
- [ ] Add precision input or keyboard-adjustable semantics where practical; if not finished, record as `NOT RUN` / follow-up, not PASS.
- [ ] Implement grouped panels for Basic, Color, Curve, Detail, and Effects using existing model fields.
- [ ] Preserve current autosave / undo behavior.

**Acceptance:**

- Every existing `AdjustmentKind` is reachable in Mac UI.
- Each adjustment has visible neutral/reset semantics.
- No duplicate, stale, or unlocalized labels.

---

## Task 4: Single-photo export options foundation

**User outcome:** 使用者能從 Mac 匯出單張成品，並設定格式、品質/位深、尺寸上限、DPI、EXIF 保留策略與同名檔處理。這輪不做批次。

**Files:**

- Modify/Add: `Sources/RawProcessingCore/Export/`
- Modify/Add: `Sources/EditorCore/Export*`
- Modify: `Apps/LumaHarborApp/Views/EditorView.swift`
- Modify/Add: `Apps/LumaHarborApp/Views/Export*`
- Test: `Tests/RawProcessingCoreTests/`
- Test: `Tests/EditorCoreTests/`
- Test: `Tests/LumaHarborAppTests/`

**Steps:**

- [ ] Generalize `JPEGExporter` behind a format-aware request while preserving existing JPEG behavior.
- [ ] Add tests for JPEG, PNG, TIFF, and HEIC capability detection; if a platform cannot encode one format, show disabled/unsupported UI instead of pretending success.
- [ ] Add tests for max-width/max-height resizing, DPI metadata, quality/bit-depth mapping, and EXIF retention policy.
- [ ] Add UI tests/source-contracts for export option labels, RAW safety copy, and per-export success/failure state.
- [ ] Ensure export renders from full-resolution source, not preview cache.

**Acceptance:**

- Existing single JPEG export still works.
- Export writes new files only.
- Failed export leaves no partial final file unless explicitly reported as partial/temp cleanup failure.

---

## Task 5: Phase 1 verification and handoff

**Files:**

- Add: `docs/testing/reports/2026-09-02-awayphotoraweditor-parity-phase1.md`
- Modify: `docs/coordination/CURRENT.md`

**Steps:**

- [ ] Run focused tests for Tasks 1-4.
- [ ] Run full `swift test`.
- [ ] Run `git diff --check`.
- [ ] Run privacy scan over changed diff for private paths, signing IDs, team IDs, device IDs.
- [ ] Run Mac app build if available.
- [ ] Run iOS generic build with `CODE_SIGNING_ALLOWED=NO` if shared APIs changed.
- [ ] Record all `PASS` / `FAIL` / `SKIPPED` / `NOT RUN`.
- [ ] Ask for independent review before landing.

**Acceptance:**

- Report states exactly what was verified.
- Any manual UI or real-device check not actually performed remains `NOT RUN`.
- No signing/project local settings are committed.

## Suggested Claude handoff

Claude should start with Task 1 only, not the whole phase at once:

> Work in `/Users/private-builder/Documents/ChatGPT/LumaHarbor/codex-awayphotoraweditor-parity-phase1` on branch `codex/awayphotoraweditor-parity-phase1`. Read `docs/superpowers/specs/2026-09-02-awayphotoraweditor-parity-design.md` and `docs/superpowers/plans/2026-09-02-awayphotoraweditor-parity-phase1.md`. Implement Task 1 only using TDD: first write failing tests for metadata / EXIF snapshot behavior and Mac inspector source contracts, then implement the minimal model/UI changes to GREEN. Do not touch iPad app files unless a shared compile fix requires it. Do not push, merge, rebase, delete worktrees, or commit signing settings. Preserve user dirty files. After Task 1, run the focused tests, `swift test --filter` for changed test files, `git diff --check`, and report PASS / FAIL / SKIPPED / NOT RUN with exact commit SHA.

