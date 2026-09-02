# AwayPhotoRawEditor Parity：完整分階段 Implementation Roadmap

狀態：給 Claude / Codex 接續開發用  
日期：2026-09-02  
Worktree：`/Users/private-builder/Documents/ChatGPT/LumaHarbor/codex-awayphotoraweditor-parity-phase1`  
Branch：`codex/awayphotoraweditor-parity-phase1`  
Base：local `main@8a400edb0f07082d157abb28b9c688d18db98f34`  
總 spec：`docs/superpowers/specs/2026-09-02-awayphotoraweditor-parity-design.md`  
Phase 1 plan：`docs/superpowers/plans/2026-09-02-awayphotoraweditor-parity-phase1.md`

## 核心規則

- AwayPhotoRawEditor 只作功能參考，不複製 Windows 原始碼、圖示、字串、圖片素材或 WinForms/D3D 實作。
- RAW 原檔永不修改；sidecar / preset / export 都要是非破壞式。
- 每個 phase 都要拆 task，每個 task 都要 TDD：RED → GREEN → focused tests → commit。
- 不要一次實作整個 parity。先完成 Phase 1，再往 Phase 2。
- 不提交 signing、Apple Team ID、裝置 UDID、私人絕對路徑或本機 Xcode 自動設定。
- Claude 不可 push / merge / rebase / delete worktree，除非使用者明確授權。
- `PASS`、`FAIL`、`SKIPPED`、`NOT RUN` 要分清楚，不准把沒跑過的寫成 PASS。

## 已完成前置

- iPad UI polish 已 fast-forward merge 到本機 `main@8a400ed`。
- Post-merge `swift test`：1125 executed, 9 skipped, 0 failures。
- Post-merge iOS generic build：`** BUILD SUCCEEDED **`。
- 本機 `main` 尚未 push 到 origin。
- 舊 Claude worktree 仍保留本機 signing dirty file：
  - `/Users/private-builder/github/LumaHarbor/.worktrees/claude-ipad-ui-polish-finish/Apps/LumaHarborPad.xcodeproj/project.pbxproj`
  - 不要提交它。

---

# Phase 1：Mac Parity Foundation

詳細計畫已在：

`docs/superpowers/plans/2026-09-02-awayphotoraweditor-parity-phase1.md`

目標：

- Mac EXIF / metadata panel。
- Rendered histogram。
- Mac adjustment inspector productization。
- 單張多格式 export foundation。

這是現在 Claude 應該先做的 phase。請 Claude 先做 Task 1，不要一次吃完全部。

Claude prompt：

```text
Work in /Users/private-builder/Documents/ChatGPT/LumaHarbor/codex-awayphotoraweditor-parity-phase1 on branch codex/awayphotoraweditor-parity-phase1.

Read:
- docs/superpowers/specs/2026-09-02-awayphotoraweditor-parity-design.md
- docs/superpowers/plans/2026-09-02-awayphotoraweditor-parity-roadmap.md
- docs/superpowers/plans/2026-09-02-awayphotoraweditor-parity-phase1.md
- docs/coordination/CURRENT.md

Implement Phase 1 Task 1 only using TDD. First write failing tests for metadata / EXIF snapshot behavior and Mac inspector source contracts, then implement minimal model/UI changes to GREEN.

Do not touch iPad app files unless a shared compile fix requires it. Do not push, merge, rebase, delete worktrees, or commit signing settings. Preserve user dirty files. After Task 1, run focused tests, relevant swift test filters, git diff --check, privacy scan for private paths/signing/device IDs, then commit and report exact SHA plus PASS / FAIL / SKIPPED / NOT RUN.
```

---

# Phase 2：Geometry and White Balance Tools

## Goal

補齊 AwayPhotoRawEditor 對標裡最核心的「看得見且可保存」編輯工具：白平衡滴管、裁切、旋轉、拉直、翻轉、初版 perspective correction。這一階段先做 global geometry，不做局部遮罩。

## User outcomes

- 使用者可以用滴管點照片取得白平衡。
- 使用者可以裁切、旋轉 90 度、水平/垂直翻轉、拉直。
- 使用者可以看到旋轉後裁切預覽，並且重新開啟照片後狀態恢復。
- 匯出使用完整解析度套用 geometry，不只套用預覽 bitmap。

## Data model

Add or extend model in `RawProcessingCore`:

```swift
public struct GeometryAdjustments: Codable, Equatable, Hashable, Sendable {
    public var crop: NormalizedCropRect?
    public var rotationDegrees: Double
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    public var straightenDegrees: Double
    public var perspectiveHorizontal: Double
    public var perspectiveVertical: Double
}

public struct NormalizedCropRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
}
```

`PhotoAdjustments` should carry `geometry` with backward-compatible decoding. Missing geometry means neutral.

## Tasks

### Task 2.1：Geometry model and sidecar compatibility

- Add failing tests that old sidecar JSON decodes with neutral geometry.
- Add tests for crop rect validation/clamping.
- Add tests that neutral geometry does not change render extent unexpectedly.
- Implement model with Codable backward compatibility.

### Task 2.2：Geometry render pipeline

- Add synthetic image tests for rotate 90, flip horizontal/vertical, crop, straighten.
- Use tolerance-based image assertions, not pixel-perfect for interpolated transforms.
- Ensure full-resolution export path applies the same geometry as preview.
- Document transform order. Recommended order:
  1. orientation normalize
  2. crop in source-normalized coordinates
  3. rotate / straighten
  4. perspective
  5. resize/export

### Task 2.3：Mac crop/rotate/straighten UI

- Add Mac UI source-contract tests for crop overlay, rotate buttons, flip buttons, straighten slider, reset.
- Implement Mac editor tool mode and overlay.
- Preserve undo/autosave behavior.
- Add localized safety copy: geometry is non-destructive and RAW original is unchanged.

### Task 2.4：White balance eyedropper

- Add model/service test that sampled neutral target adjusts temperature/tint in expected direction.
- Add cancellation test: hover/preview sampling must not write sidecar.
- Add Mac UI source-contract for eyedropper mode, cancel, apply.
- Implement first version using decoded RGB sampling if RAW metadata baseline is insufficient.

### Task 2.5：Verification

- Focused tests for geometry model/render/UI.
- `swift test`.
- `git diff --check`.
- Privacy scan.
- Mac app build.
- iOS generic build if shared model changed.
- Manual screenshot checklist for crop direction, rotate direction, and eyedropper cancel/apply. If not run, record `NOT RUN`.

## Claude prompt

```text
Continue in /Users/private-builder/Documents/ChatGPT/LumaHarbor/codex-awayphotoraweditor-parity-phase1 unless a newer phase branch exists.

Read the parity roadmap and total spec. Implement Phase 2 Task 2.1 only first: Geometry model and sidecar compatibility. Use TDD, commit only Task 2.1 when GREEN, and report exact SHA. Do not start render/UI until Task 2.1 is reviewed or explicitly approved.
```

---

# Phase 3：Preset, Batch, Virtual Copy

## Goal

把對標工作流從「單張修圖」推到「大量照片整理與套用」。這階段做 preset library、preset 覆寫/備份/還原、多選批次同步、compound undo、virtual copy。

## User outcomes

- 使用者可以建立、套用、搜尋、收藏、備份、還原 preset。
- 使用者可以多選縮圖，同步這次操作改動過的欄位。
- 批次操作可復原，不會讓 sidecar 半套用。
- 使用者可以建立 virtual copy，用同一 RAW 做多個版本。

## Data model

Preset remains sparse patch:

```swift
public struct PresetDocument: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var group: String?
    public var isFavorite: Bool
    public var patch: AdjustmentPatch
    public var source: PresetSource
}
```

Virtual copy:

```swift
public struct PhotoVariant: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var sourcePhotoID: PhotoID
    public var name: String?
    public var createdAt: Date
    public var adjustments: PhotoAdjustments
    public var rating: Int?
    public var flag: PhotoFlag
}
```

Batch transaction:

```swift
public struct BatchAdjustmentTransaction: Codable, Equatable, Sendable {
    public var id: UUID
    public var targetVariantIDs: [UUID]
    public var modifiedFieldIDs: [AdjustmentFieldID]
    public var before: [UUID: AdjustmentPatch]
    public var after: [UUID: AdjustmentPatch]
    public var results: [UUID: BatchWriteResult]
}
```

## Tasks

### Task 3.1：Preset library storage and UI foundation

- Add tests for built-in vs user preset precedence.
- Add tests for sparse patch edit/removal when value returns to inherited/default.
- Add Mac preset browser UI source-contracts: group, favorite, search, create from current photo.
- Implement storage and UI foundation.

### Task 3.2：Preset backup/restore and XMP continuation

- Add backup archive tests.
- Add restore conflict tests.
- Preserve unknown XMP fields.
- Add UI for import/export `.lhpreset` and `.xmp`.

### Task 3.3：Thumbnail multi-select and batch snapshot semantics

- Add tests that gesture start snapshots selected targets.
- Add tests that only modified field IDs are synchronized.
- Add tests that selection changes mid-drag do not change the current batch target list.
- Implement multi-select UI and batch sync service.

### Task 3.4：Compound batch undo

- Add tests for full success, partial failure, and undo after partial failure.
- Ensure no target sidecar stays half-written.
- Add localized report copy: affected N, failed M, skipped K.

### Task 3.5：Virtual copy

- Add sidecar/schema tests for original photo vs copy identity.
- Add library query tests that variants appear adjacent to original.
- Add delete tests: deleting virtual copy never deletes RAW original or other copies.
- Add UI badge / name / duplicate / delete copy actions.

### Task 3.6：Verification

- Focused tests per task.
- `swift test`.
- `git diff --check`.
- Privacy scan.
- Manual Mac checklist for preset apply, multi-select sync, batch undo, virtual copy persistence.

## Claude prompt

```text
Implement Phase 3 Task 3.1 only. Use TDD. Preserve existing XMP behavior. Do not start batch or virtual copy in the same commit. Commit Task 3.1 separately and report SHA plus tests.
```

---

# Phase 4：Local Retouching

## Goal

加入 AwayPhotoRawEditor 對標中的局部工具第一版：多重線性漸層與 spot heal / clone。先做可序列化、可匯出、可回復的 local adjustment，不追求 AI 修圖。

## User outcomes

- 使用者可以在一張照片上加多個線性漸層。
- 每個漸層可以調整位置、角度、範圍、羽化與局部調整。
- 使用者可以加 spot heal / clone，移動 target/source、調整大小與羽化。
- 重新開 App 後 local edits 還在。
- 匯出完整解析度會套用 local edits。

## Data model

```swift
public struct LocalAdjustment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: LocalAdjustmentKind
    public var isEnabled: Bool
    public var geometry: LocalAdjustmentGeometry
    public var adjustments: LocalAdjustmentPatch
}

public enum LocalAdjustmentKind: String, Codable, Sendable {
    case linearGradient
    case spotHeal
}
```

## Tasks

### Task 4.1：Local adjustment schema

- Backward-compatible sidecar tests.
- Multiple local adjustments order tests.
- Enable/disable/delete tests.
- No bitmap mask in first data model.

### Task 4.2：Linear gradient render

- Add synthetic image tests for gradient mask direction, feather, local exposure.
- Add model tests for copy/delete/select.
- Implement render composition.

### Task 4.3：Mac linear gradient UI

- Add overlay source-contracts and accessibility labels.
- Add hit target tests where possible.
- Add manual screenshot checklist for drag handles.
- Implement first Mac UI.

### Task 4.4：Spot heal / clone model and render

- Add tests for target/source movement.
- Add tests for mode switch immediately updating selected point.
- Add full-resolution export test.
- Implement conservative Core Image based heal/clone.

### Task 4.5：Spot heal UI

- Add UI source-contracts for add, select, move source, move target, size, feather, delete, mode switch.
- Implement Mac UI.
- Record quality limitations honestly.

### Task 4.6：Verification

- Focused render tests.
- `swift test`.
- `git diff --check`.
- Privacy scan.
- Mac manual checklist with screenshots. If not run, `NOT RUN`.

## Claude prompt

```text
Implement Phase 4 Task 4.1 only. Do not implement rendering/UI yet. The goal is a backward-compatible sidecar schema for local adjustments with tests. Commit separately and report SHA.
```

---

# Phase 5：Export Pro, Theme, Languages, Diagnostics

## Goal

把 app 從「功能能用」推到「可 beta / RC 驗收」。補完整批次匯出、浮水印、EXIF policy、兩套主題、八語 localization coverage、headless diagnostics。

## User outcomes

- 使用者可以批次匯出 JPEG/TIFF/PNG/HEIC。
- 可以設定重新命名、尺寸、DPI、浮水印、EXIF 保留/移除。
- 可以切換 classic dark 與 warm paper theme。
- UI 有八語 key coverage，不會出現漏翻或硬編字串。
- 測試人員可以用 selftest/exporttest/shot/gallery 產生驗收證據。

## Tasks

### Task 5.1：Batch export queue

- Add queue model tests: pending/running/succeeded/failed/cancelled.
- Add per-file report tests.
- Add cancel temp cleanup tests.
- Implement Mac export queue UI.

### Task 5.2：Rename, DPI, EXIF policy, watermark

- Add naming template tests: original filename, sequence, date, preset name, virtual copy name.
- Add collision policy tests: increment, ask, skip.
- Add DPI metadata tests.
- Add EXIF preserve/remove/partial tests.
- Add watermark render tests: text, position, opacity, size.

### Task 5.3：Theme system

- Add theme model tests: system/classicDark/warmPaper.
- Add UI source-contracts for theme picker and no hard-coded one-off colors in major Mac panels.
- Implement design tokens for photo-neutral background vs app chrome.

### Task 5.4：Eight-language localization gate

- Add key coverage tests for:
  - zh-Hant
  - en
  - ja
  - ko
  - zh-Hans
  - de
  - fr
  - es
- Add placeholder consistency tests.
- Initial translations may be rough but must be marked machine-assisted in docs if not human reviewed.

### Task 5.5：Headless diagnostics

- Add commands or scripts:
  - `selftest`
  - `exporttest`
  - `shot`
  - `gallery`
- Add tests that scripts do not report PASS for zero executed tests.
- Add privacy-safe diagnostic export.

### Task 5.6：RC verification

- Full `swift test`.
- Mac app build.
- iOS generic build.
- MVP acceptance if fixtures available.
- Export fixture tolerance report.
- Manual Mac checklist.
- iPad subset checklist for any shared features exposed on iPad.
- Privacy scan.
- Independent review.

## Claude prompt

```text
Implement Phase 5 Task 5.1 only. Do not start themes/languages/diagnostics in the same task. Use TDD for export queue state, cancellation, and per-file result reporting. Commit separately and report SHA plus verification.
```

---

# Recommended execution order

1. Phase 1 Task 1：Metadata / EXIF snapshot contract。
2. Phase 1 Task 2：Rendered histogram service。
3. Phase 1 Task 3：Mac adjustment inspector productization。
4. Phase 1 Task 4：Single-photo export options foundation。
5. Phase 1 Task 5：Verification and independent review。
6. Phase 2 geometry model only。
7. Phase 2 render/UI/eyedropper。
8. Phase 3 preset library。
9. Phase 3 batch + virtual copy。
10. Phase 4 local adjustment schema/render/UI。
11. Phase 5 export pro/theme/language/diagnostics。

不要跳過 Phase 1。後面的 batch/local/export pro 都需要 Phase 1 的 metadata、histogram、inspector、export foundation 先穩。

