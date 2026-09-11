# Handoff: P6 Snapshots, Soft Proof, and Professional Preview

依循 `docs/coordination/HANDOFF_TEMPLATE.md`。

## Status

`DONE_WITH_CONCERNS`

## Git state

- Source branch: `claude/professional-editing-completion`
- Base for this phase: `3905ec7` ("feat: add advanced masks, AI repair, and perspective (P5)")
- Implementation commit: `feat: add snapshots, soft proof, and professional preview (P6)`
- Ahead / behind: Feature branch 保持領先；嚴格未執行 push、merge 或 rebase。

## Changes

### New files (spec / plan)

- `docs/superpowers/specs/2026-09-10-snapshots-soft-proof-and-professional-preview.md`
- `docs/superpowers/plans/2026-09-10-snapshots-soft-proof-and-professional-preview.md`

### New files (models, rendering, and UI)

- `Sources/PhotoLibraryCore/Model/EditSnapshot.swift`:
  - 定義 `EditSnapshot(id:name:adjustments:createdAt:)`，符合 `Identifiable, Codable, Equatable, Sendable`。
  - 完整凍結快照生成當下的 `PhotoAdjustments`（包含基礎調光、顏色、曲線、局部遮罩與幾何）。
- `Sources/RawProcessingCore/Preview/ProfessionalPreviewOptions.swift`:
  - 定義 `SoftProofProfile` (`.sRGB`, `.displayP3`, `.adobeRGB`) 與色彩空間轉換。
  - 定義 `ProfessionalPreviewOptions`，包含高光溢出遮罩 (`highlightClipping`)、陰影死黑遮罩 (`shadowClipping`)、超出目標色域警示 (`gamutWarning`) 及軟體打樣 (`softProofProfile`, `simulatePaperAndInk`)。
- `Sources/RawProcessingCore/Preview/ProfessionalPreviewRenderer.swift`:
  - 專門處理專業預覽疊加層，支援 Metal Kernel (`professionalPreviewOverlay`) 與 CoreImage 備援演算法。
  - 依循色彩空間目標進行色域溢出色覆蓋（黃色標記）、高光裁切（純紅標記）、暗部裁切（純藍標記）。
- `Sources/AdjustmentUI/SnapshotsPanel.swift`:
  - 提供快照列表、建立、重新命名、複製、刪除（具確認警示）、還原與 A/B 對比按鈕。
  - 整合專業預覽開關面板（高光、陰影、色域警示、軟體打樣色彩空間與紙墨模擬）。

### New files (tests)

- `Tests/PhotoLibraryCoreTests/SnapshotModelTests.swift`:
  - 4 項測試：驗證快照初始化、預設命名、Codable 序列化與 Sidecar v4 讀寫。
- `Tests/RawProcessingCoreTests/ProfessionalPreviewFilterTests.swift`:
  - 5 項測試：驗證高光裁切標記、暗部死黑標記、中間調不誤判、色彩空間設定與未啟用時的穿透 pass-through。
- `Tests/EditorCoreTests/SnapshotWorkflowTests.swift`:
  - 8 項測試：驗證建立快照、空名稱回退、重新命名、複製、刪除、Compound Undo 還原（單次 undo 回到還原前狀態）、A/B 比較隔離性（不寫入 active adjustments 與 sidecar）、預覽選項更新。

### Modified files (core & rendering)

- `Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift`:
  - 落實 `DECISIONS.md` D-006：`currentSchemaVersion` 升級為 4。
  - 新增 `snapshots: [EditSnapshot] = []` 欄位，向前相容解碼 v1/v2/v3 舊格式，保證無損載入。
- `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`:
  - 於 `saveAdjustments` 與 `mutateCuration` 補齊保留快照陣列，避免舊版覆蓋。
  - 新增 `snapshots(for photo:)` 與 `saveSnapshots(_:for:)` API。
- `Sources/RawProcessingCore/Kernels/AdjustmentKernels.metal`:
  - 新增 `professionalPreviewOverlay` Metal kernel。
- `Sources/RawProcessingCore/Preview/PreviewRequest.swift` & `CoreImagePreviewRenderer.swift`:
  - 注入 `previewOptions`，在 CoreImage 渲染後掛上專業預覽疊加濾鏡。
  - 保持隔離：`previewOptions` 僅影響編輯器畫布預覽，絕不流入 `PhotoExportRequest`，匯出產物絕不被預覽標記污染。
- `Sources/EditorCore/EditorDependencies.swift` & `EditorSession.swift`:
  - 注入 `loadSnapshots` 與 `saveSnapshots` 閉包。
  - 新增 `snapshots`、`previewOptions`、`comparisonSnapshot` 狀態。
  - 實作快照 CRUD 與複合交易還原。
  - A/B 比較切換時僅調整 `displayedAdjustments`，不修改 `history` 與 sidecar。

### Modified files (UI & iPad Parity)

- `Sources/LumaHarborApp/Views/InspectorView.swift`:
  - `InspectorTab` 新增 `.snapshots`，在右側面板提供完整的 Snapshots & 專業預覽工作區。
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift` & `PadInspectorHost.swift`:
  - 於 Info 面板（Histogram 與 Metadata 後）掛載 `SnapshotsPanel`。
  - 於頂部 Toolbar 的 `compareMenu` 中整合快照 A/B 比較切換清單。
  - 保持跨平台 SwiftUI 相容性。

### Modified files (Localization)

- 於 8 國語言 (`en`, `zh-Hant`, `zh-Hans`, `ja`, `ko`, `de`, `fr`, `es`) 的 `Localizable.strings` 完整加入 22 個 Phase 6 本地化鍵值。
- 更新 `Tests/LumaHarborAppTests/EightLanguageLocalizationGateTests.swift`：
  - 新增 `testPhase6StringsAreTranslatedInEveryRequiredLanguage` 測試。
  - 將色彩空間專有名詞加入白名單，全套 10/10 PASS。

## Test evidence

- `swift test`：**PASS**（2184 tests executed, 9 skipped, 0 failures, 28.636s）。
- `swift build -Xswiftc -strict-concurrency=complete`：**PASS**（0 warnings, 0 errors）。
- iPad Simulator build：`xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`：**BUILD SUCCEEDED**。
- `git diff --check`：**PASS**（0 whitespace/merge issues）。
- Privacy scan：**PASS**（無個人路徑、Team ID 或私密簽章洩漏）。

## Concerns / Next actions

- Sidecar schema 已正式升為 4，舊版（v1/v2/v3）相容測試均通過。
- 下一步：推進 Phase 7（跨裝置驗收與發布準備）。
