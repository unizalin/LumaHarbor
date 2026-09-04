# AwayPhotoRawEditor Parity Phase 3 Report

日期：2026-09-04
分支：`claude/awayphotoraweditor-parity-phase2-geometry`
Worktree：`/Users/private-builder/github/LumaHarbor/.worktrees/claude-awayphotoraweditor-parity-phase2-geometry`
Base：本機 `main@fb7109a4fd76035bb9ca3f492b1fa45f511a60ec`（Phase 1、Phase 2 皆已在這個分支上完成並經獨立審查；`main` 本身尚未 push）
本報告撰寫時的 HEAD：`025a14abca4786b49180723a71dec56a649c1409`
Roadmap：`docs/superpowers/plans/2026-09-02-awayphotoraweditor-parity-roadmap.md`（"Phase 3" 段落）
Design spec：`docs/superpowers/specs/2026-09-02-awayphotoraweditor-parity-design.md`

## 摘要

狀態：**自動化驗證完成**，涵蓋 Phase 3 全部五個 task（3.1 Preset library、3.2 Preset backup/restore、3.3 多選批次同步、3.4 批次復原、3.5 虛擬副本）。這五個 task 每一個做完後都經過獨立審查，其中 3.1+3.2（合併審查）、3.3、3.4（含一次 follow-up 回合的再審查）、3.5 各自都至少抓到並修好一個真的 bug——這是這個 repo 這幾輪一貫的模式，不是這次才發生。Task 3.6（本報告）本身沒有再改 product code，只做整個 Phase 3 範圍的收尾驗證與這份報告。真機／Mac 桌機的人眼手動驗證仍是 `NOT RUN`，見下方「未執行項目」與新增的 `docs/testing/beta/PHASE3_MANUAL_CHECKLIST.md`。

## Commits（`382d799..HEAD`，26 個 commit，與 `main` 沒有分岔）

| Commit | Task | 說明 |
|---|---|---|
| `7178bec` | 3.1 | feat: built-in preset scope and editable presets |
| `41c7095` | 3.1 | docs: record Phase 3 Task 3.1 evidence in CURRENT.md |
| `6b117b9` | 3.2 | feat: preset backup/restore and .lhpreset import |
| `4f8e9a5` | 3.2 | docs: record Phase 3 Task 3.2 evidence in CURRENT.md |
| `917f0ef` | 3.1+3.2 審查修復 | fix: built-in preset copy UUID collision and .lhpreset import fidelity loss |
| `fc21143` | 3.1+3.2 審查 | docs: record independent review of Phase 3 Tasks 3.1+3.2 in CURRENT.md |
| `0b78903` | 3.3 | feat: thumbnail multi-select and batch adjustment sync |
| `c6b6b0b` | 3.3 | docs: record Phase 3 Task 3.3 evidence in CURRENT.md |
| `b347a4b` | 3.3 | docs: add handoff record at the end of Phase 3 Task 3.3 |
| `166688e` | 3.3 審查修復 | fix: sync Reset/Reset All to batch, same as a drag |
| `a785205` | 3.3 審查 | docs: record independent review of Phase 3 Task 3.3 in CURRENT.md |
| `d55821d` | 3.4 | feat: compound batch undo |
| `024a913` | 3.4 | docs: record Phase 3 Task 3.4 evidence in CURRENT.md |
| `d1e9236` | 3.4 審查修復 | fix: batch undo must not overwrite a field edited since the sync |
| `f1de4ff` | 3.4 審查 | docs: record independent review of Phase 3 Task 3.4 in CURRENT.md |
| `b044a62` | 3.4 follow-up | fix: batch undo/sync no longer race a shared target, retry after partial undo failure |
| `7d8600b` | 3.4 follow-up | docs: record Task 3.4 follow-up round (Findings 2 and 4) in CURRENT.md |
| `6752d21` | 3.4 follow-up 審查修復 | fix: undo must not clobber a newer batch transaction that lands while it's in flight |
| `3c62c69` | 3.4 follow-up 審查 | docs: record independent review of the Task 3.4 follow-up round in CURRENT.md |
| `3185313` | 3.5 | feat: virtual copy identity model and schema (step 1/4) |
| `0be541c` | 3.5 | feat: PhotoLibraryService.createVirtualCopy/deleteVirtualCopy (step 2/4) |
| `8ad0190` | 3.5 | feat: virtual copies grouped adjacent to their originals, duplicate/delete actions (step 3/4) |
| `66edf43` | 3.5 | feat: virtual copy grid badge, name, duplicate/delete actions (step 4/4) |
| `e2945cd` | 3.5 | docs: record Phase 3 Task 3.5 evidence in CURRENT.md |
| `57cb884` | 3.5 審查修復 | fix: virtual copies survive an index rebuild and nested copy chains stay visible |
| `025a14a` | 3.5 審查 | docs: record independent review of Phase 3 Task 3.5 in CURRENT.md |

每個 task／每次獨立審查的完整細節（改了什麼、TDD 的 RED/GREEN 過程、確切的測試名稱）已經在 `docs/coordination/CURRENT.md` 對應段落裡，這裡不逐字重複，只做本報告自己這一輪（Task 3.6）的整段驗證與摘要。

## 各 Task 摘要

- **Task 3.1 — Preset library storage and UI foundation**：新增 `BuiltInPresetRepository`（唯讀 scope，兩個佔位用內建 preset，`save`/`delete` 一律 throw）；`PresetLibraryViewModel.updatePreset(...)` 讓已存的 preset 可以就地編輯、包含把某個欄位從 patch 裡移除（sparse removal，沿用既有的 `AdjustmentPatch.excluding(_:)`）；`EditPresetSheet`、preset 列表的來源／scope 徽章。**獨立審查（與 3.2 合併審查）發現並修好一個 blocking bug**：`PresetLibraryViewModel.copy(_:to:)` 把 built-in preset 自己固定的 UUID 原封不動複製到 My Presets，導致兩個不同 scope 的項目共用同一個 identity；修法是複製 built-in 時一律換發新的 UUID/`createdAt`/`modifiedAt`。
- **Task 3.2 — Preset backup/restore and XMP continuation**：新增 `PresetBackupArchive`（`.lhpresetbackup`，整個 scope 一次備份）、`restorePresets(_:into:conflict:)`（逐筆還原並容錯，回報 created/replaced/keptBoth/duplicateSkipped/cancelled/failed 摘要）；Mac UI 新增 Backup/Restore 選單；`.lhpreset` 匯入納入既有的 `.xmp` 匯入流程。**同一輪獨立審查另外發現並修好一個真實資料遺失 bug**：`.lhpreset` 匯入預覽（`previewLHPreset`）沒有把 `source`／`xmpEnvelope` 帶進去，會讓「XMP 匯入 → 匯出成 `.lhpreset` 分享 → 對方再匯入」這條路徑靜默遺失原本保留下來的未知 XMP 欄位；已修好並補上回歸測試。
- **Task 3.3 — Thumbnail multi-select and batch snapshot semantics**：新增 `BatchAdjustmentSyncService`（`actor`，手勢開始時凍結目標清單與 baseline，只同步這次手勢實際改變的欄位）；`EditorSession.beginAdjustmentGesture()`/`.endAdjustmentGesture()`；`LibraryViewModel.selectedPhotoIDs`／⌘-click 多選 UI。**獨立審查發現並修好一個真的功能缺口**：`EditorSession.resetAdjustment(_:)`/`.resetAll()`（右鍵 Reset、雙擊列、"Reset All Adjustments"）原本完全沒有觸發批次同步的手勢 hook，導致「批次選取後把某個欄位重設」不會同步給其他被選取的照片；已修好，兩者現在都會正確觸發同步。
- **Task 3.4 — Compound batch undo**：新增 `BatchAdjustmentSyncService.undo(_:)`（把 `before` patch 合併寫回，容錯，回報 affected/failed/skipped）、`LibraryViewModel.lastBatchTransaction`／`undoLastBatchTransaction()`、選單「Undo Batch Sync」。**這個 task 前後總共經歷兩輪獨立審查，各自都抓到真的 bug**：第一輪抓到 `undo(_:)` 在目標欄位已被使用者事後手動改過時仍會靜默覆蓋掉那次手動編輯（silent data loss，已修）；緊接的 follow-up 回合修好另外兩個追蹤中的問題（`commitGesture`／`undo` 對同一目標的競態、部分失敗後遺失重試路徑），而**第二輪獨立審查又抓到 follow-up 回合自己引入的一個新迴歸**：`undoLastBatchTransaction()` 沒有檢查 `lastBatchTransaction` 在 undo 執行期間是否已經被另一次不相關的批次同步取代，會誤刪或誤標那次不相關同步的狀態；已修好。
- **Task 3.5 — Virtual copy**：`PhotoAsset`/`PhotoRecord`/`PhotoSidecar` 新增 `variantOf`/`variantName`；`PhotoIndexStore` schema v2→v3（版本閘門正確處理 v1→v2 與 v2→v3 各自獨立判斷）；`RelinkResolver` 排除虛擬副本的 record；`PhotoLibraryService.createVirtualCopy`/`deleteVirtualCopy`；`LibraryViewModel.orderedForDisplay` 依 `variantOf` 分組；grid badge／名稱／右鍵「Duplicate as Virtual Copy」／「Delete Virtual Copy」。**獨立審查發現並修好兩個真的 bug**（詳見上一輪的獨立審查報告，即本文件所屬分支上一個提交回合）：(1) 虛擬副本原本撐不過 `resetRebuildableLocalData()`（刪除本機索引重建）——這個 app 自己文件保證「身分資訊來自 `library.json`，重建後編輯都還在」，對虛擬副本其實是假的，重建後副本會永久消失；(2) 「副本的副本」（`createVirtualCopy(of:)` 本身明確支援、右鍵選單對任何照片都提供）原本會從 `orderedForDisplay` 的分組邏輯裡整個消失，不是排序錯而是真的看不到。兩者都已修好並補上測試（新增測試同時鎖住修法本身可能引入的新風險：不會把「sidecar 已被刪除、manifest 清理剛好失敗」的殘留紀錄復活回畫面）。

## 自動化驗證

### 各 Task 重點測試

| Task | 涵蓋的測試套件 | 結果 | 證據 |
|---|---|---|---|
| 3.1 | `BuiltInPresetRepositoryTests`, `PresetBrowserFoundationContractTests`, `PresetWorkflowTests`, `PresetLibraryViewModelTests` | PASS | 77 個測試執行，0 失敗 |
| 3.2 | `PresetBackupArchiveTests`, `PresetRestoreTests`（`.lhpreset`/backup 相關案例同時涵蓋在上面 3.1 那組 `PresetWorkflowTests` 裡） | PASS | 13 個測試執行，0 失敗 |
| 3.3 | `AdjustmentPatchExtractionTests`, `BatchAdjustmentSyncServiceTests`, `EditorSessionEditingTests`, `AdjustmentGroupPanelsContractTests`, `BasicAdjustmentPanelModelTests`, `LibraryGridMultiSelectContractTests`, `BatchAdjustmentGestureIntegrationTests` | PASS | 90 個測試執行，0 失敗 |
| 3.4 | `BatchUndoSummaryMessageTests`, `BatchAdjustmentSyncServiceTests`, `BatchAdjustmentGestureIntegrationTests`（跟 3.3 的過濾條件有重疊，因為 undo 相關案例加在同一批既有測試檔裡） | PASS | 29 個測試執行，0 失敗 |
| 3.5 | `RelinkResolverTests`, `PhotoIndexMigrationTests`, `PhotoIndexStoreTests`, `VirtualCopyServiceTests`, `VirtualCopyLibraryViewModelTests`, `LibraryLifecycleTests` | PASS | 73 個測試執行，0 失敗 |
| 全 Phase 3 共用 | `LocalizationSmokeTest` | PASS | 12 個測試執行，0 失敗 |

上面每一組都是這一輪（Task 3.6）重新單獨跑過確認，不是沿用各 task 自己回合當時的數字（雖然數字剛好一致，因為這一輪沒有再改動對應 product code，Task 3.5 審查那輪的修復除外，已含在 3.5 那一列的數字裡）。

### 全範圍 Gate

| Gate | 結果 | 證據 |
|---|---|---|
| `swift test`（完整套件） | PASS | 1483 個測試執行，9 個 skip，0 失敗——跟上一輪（Task 3.5 獨立審查修復完成時）記錄的基準完全一致，這一輪沒有新增 product 改動 |
| — skip 的測試身分 | 符合預期 | 全部 9 個都是 `LumaHarborIntegrationTests.RawFixtureTests`（`testEveryFixtureDecodes`、`testExportingNeverModifiesTheOriginal`、`testFullDecodeReturnsNativeResolution`、`testFullResolutionExportMatchesTheSourceDimensions`、`testInteractivePreviewLatencyForARealPhoto`、`testPreviewDecodeHonoursTheRequestedSize`、`testPreviewSchedulerDeliversARenderedFrameForARealRaw`、`testSonyArwReportsPlausibleMetadata`、`testWhiteBalanceOffsetChangesTheRender`）——這個環境沒有設定 `LUMAHARBOR_RAW_FIXTURE_DIR`，是從 Phase 1 就有的既有基準，Phase 3 沒有改變它 |
| `git diff --check`（工作目錄） | PASS | 無輸出 |
| `git diff --check`（`fb7109a..HEAD`，整個分支範圍，含 Phase 2） | PASS | 無輸出 |
| `git diff --check`（`382d799..HEAD`，Phase 3 自己的範圍） | PASS | 無輸出 |
| 隱私掃描（`rg -n "/Users/\|/Volumes/\|/private/\|7KM4ZM25P3\|teamIdentifier:\|DEVELOPMENT_TEAM"` 對 `git diff fb7109a..HEAD`） | PASS | 20 處命中，全部逐一確認都落在 `docs/coordination/CURRENT.md` 自己的文字裡，內容是這個 worktree 本身已公開的路徑（跟前面每一輪的既有慣例一致），或是這份 `rg` 樣式字串本身被貼在文件裡（不是真的洩漏）；另外用 `git diff --name-only -- Sources/ Tests/ Apps/` 篩出這個範圍內每一個被改到的 product/test 檔案單獨重跑同一組 pattern，零命中；沒有任何簽章／裝置專屬樣式（`7KM4ZM25P3`／`teamIdentifier:`／`DEVELOPMENT_TEAM`）的真實命中 |
| Mac app build（`swift build`） | PASS | `Build complete!` |
| iOS generic build（`xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/LumaHarbor-Phase3Task6-DerivedData CODE_SIGNING_ALLOWED=NO build`） | PASS | `** BUILD SUCCEEDED **`；Phase 3 全部改動都在 `LumaHarborApp`/`PhotoLibraryCore`/`PresetCore`/`EditorCore`/`AdjustmentUI`/`Localization`，其中 `PhotoLibraryCore`/`PresetCore`/`Localization` 是 iPad app 也依賴的共用 target，故納入這個 gate |
| 本機簽章／專案檔 | 未變動 | `Apps/LumaHarborPad.xcodeproj/project.pbxproj` 在 iOS build 前後 `git status --porcelain` 皆為空 |

## 未執行項目

- **整個 Phase 3 的真機／Mac 桌機人眼手動驗證：`NOT RUN`。** 這個環境沒有辦法啟動並操作 Mac app 的實際視窗，所以以下這些都只能靠單元／整合／source-contract 測試驗證，沒有人在跑起來的視窗前確認過：Preset browser 的 built-in／My Presets／Library 三個 scope 分區與徽章實際外觀、Preset 編輯表單的欄位勾選互動、Backup/Restore 的 `NSSavePanel`/`NSOpenPanel` 流程、多選 ⌘-click 的打勾徽章與拖曳同步的即時手感、"Undo Batch Sync" 選單與 alert 的實際樣式、虛擬副本徽章與右鍵選單的真實觸感、以及「刪除本機索引重建」在真實視窗上是否如預期把虛擬副本找回來。已建立 `docs/testing/beta/PHASE3_MANUAL_CHECKLIST.md`，列出這些項目各自要驗證什麼、預期行為是什麼，供之後有人拿到真實 Mac 時照著走；目前清單裡每一項都還是 `NOT RUN`。
- **`LumaHarborIntegrationTests.RawFixtureTests`**（9 個測試，上表已列）——`SKIPPED`，不是 `NOT RUN`：需要 `LUMAHARBOR_RAW_FIXTURE_DIR` 指向真實相機 RAW 檔案，這個環境沒有，從 Phase 1 起就是既有、不變的基準。
- **刻意排除、不是這輪漏掉的範圍**（Task 3.5 一開始就經使用者明確決定排除，記錄在 `CURRENT.md` Task 3.5 段落）：批次同步（3.3/3.4）、preset 套用／匯出、搜尋／篩選目前都還不認識虛擬副本——虛擬副本在這些流程裡就是一張普通、獨立的 `PhotoAsset`，除了圖庫網格自己的分組與兩個新的右鍵選單動作之外，沒有特別處理。這是下一輪如果要擴大虛擬副本相容性時的待辦，不是這次 Task 3.6 收尾漏掉的東西。
- **Preset 相關既有的本地化缺口**（Task 3.1 自己記錄，非本輪引入）：`PresetError` 整個 `LocalizedError` family 與部分 alert 內文從一開始就沒有 `.strings` entry，兩種語言都沒有；這是獨立於 Task 3.1 新增內容之外的既有系統性缺口，留待日後整批處理。

## 獨立審查

Phase 3 五個 task（3.1 起到 3.5 止，含 3.4 的 follow-up 回合）**每一個都已經個別經過獨立審查**，不是只有整個 phase 結束後才審查一次；審查方式、發現與修法細節分別記錄在 `docs/coordination/CURRENT.md` 對應的「Independent review of Phase 3 Task 3.x」段落，這裡不重複列出，只總結：3.1+3.2 合併審查抓到 1 個 blocking + 1 個真實資料遺失問題（皆已修）；3.3 審查抓到 1 個真的功能缺口（已修）；3.4 前後兩輪審查各抓到 1 個真的 bug（第二輪抓到的正是第一輪 follow-up 修法自己引入的迴歸，已修）；3.5 審查抓到 2 個真的 bug（虛擬副本撐不過索引重建、副本的副本從畫面消失，皆已修）。這輪 Task 3.6 本身是收尾驗證，沒有再發現新問題，也沒有再改 product code。

## 上線準備度

尚未 land、merge、rebase 或 push。`claude/awayphotoraweditor-parity-phase2-geometry` 仍是獨立分支／worktree，位於 `/Users/private-builder/github/LumaHarbor/.worktrees/claude-awayphotoraweditor-parity-phase2-geometry`，未 push，沒有任何簽章／本機專案設定被提交。本機 `main` 仍在 `fb7109a`，領先 `origin/main` 27 個 commit，未 push，不受這個分支影響。

建議下一步：Phase 3（preset／批次／虛擬副本）的自動化驗證與逐 task 獨立審查已經全部完成，接下來是使用者自己決定——(a) 依 `docs/testing/beta/PHASE3_MANUAL_CHECKLIST.md` 在真實 Mac 上跑一輪人眼手動驗證，(b) 決定要不要把這個分支合併進 `main`（合併／push 都需要使用者明確授權），或 (c) 依 roadmap 開始下一個 Phase。三者互不衝突，也可以先做手動驗證再決定要不要合併。
