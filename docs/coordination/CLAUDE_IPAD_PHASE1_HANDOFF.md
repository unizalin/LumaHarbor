# Claude 交接：iPad Phase 1 圖庫 Workspace

## 目前狀態

- 分支：`codex/open-source-release-prep`
- 前一棒：Codex
- Spec：`docs/superpowers/specs/2026-09-08-ipad-m-series-ui-ux-optimization-design.md`
- Codex 已完成：
  - `PadWorkspaceWidthProfile`：Compact `<700`、Standard `700-1099`、Expanded `1100-1359`、Wide `>=1360`。
  - `PadWorkspaceLayoutPolicy`：同一份 width policy 同時決定圖庫 sidebar 與 editor inspector。
  - `PadWorkspaceState`：sidebar、inspector tab、filmstrip、左右手偏好，沒有照片調整或 undo 資料。
  - `PadEditorLayoutPolicy` 改為 1100 pt 才使用 trailing dock。
  - `PadLibraryView` 已由 `GeometryReader` 接上 policy；overlay、persistent、persistentWithDetails 分支保留來源 lifecycle 行為。
  - 共用 `LibraryBrowserSession` 已接上 rating／flag／keyword／進階條件；`PadLibraryGrid` 已接 touch Select mode、選取數量／全選／清除、filter sheet 與 VoiceOver selection state，請勿重做這些項目。

## Claude 本棒任務

完成 Phase 1 的剩餘 workspace shell 與真機驗收，不要重做已通過的 policy、shared filters 或 Select UI：

1. 檢查 `PadLibraryView.swift` 的 compact／standard overlay 與 expanded／wide persistent sidebar，確保旋轉、Stage Manager resize、來源 sheet 開關不遺失 selection 或 operation overlay。
2. 將 `PadWorkspaceState` 接入 iPad scene-level state；sidebar、filmstrip、inspector tab 只屬 UI state，不得寫入 RAW sidecar 或 `EditorSession` undo。
3. 驗證 `PadWorkspaceState` 在 scene-level 的生命週期；sidebar、filmstrip、inspector tab 只屬 UI state，不得寫入 RAW sidecar 或 `EditorSession` undo。
4. 在旋轉、Stage Manager resize、來源 sheet 開關與返回圖庫時，保留既有 selection、PhotoID scroll anchor 與 operation overlay；若發現遺失才補最小修正。
5. 以已連線的 iPad Pro 做手動 UI QA：compact／standard／expanded／wide、Select／filter sheet、離線來源與 VoiceOver；記錄真機結果，不要修改 signing／Team ID。

## 交接驗收

先寫／更新契約測試並觀察 RED，再實作 GREEN。至少執行：

```text
swift test --filter 'PadEditorLayoutPolicyTests|PadLibraryAccessibilityContractTests|PadLibraryCompositionContractTests|LibraryQueryWiringTests'
xcodebuild -quiet -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
git diff --check
```

Codex 已另外完成 signed device build、安裝與啟動；Claude 應優先補畫面與 state preservation 的手動證據，不要把下列已完成工作重做：`LibraryBrowserSession` shared filters、`PadLibraryFilterSheet`、touch Select／selection bar、VoiceOver selection state。

完整 `swift test` 目前可執行，但本機已知唯一 failure 是 `AppIconAssetContractTests.testIPadProjectDoesNotContainPersonalBundleIdentifier` 的 bundle identifier occurrence contract；不要為了本棒 UI 任務修改 signing 或 project identifier。

## 禁止事項

- 不要同時開另一個代理修改此 worktree。
- 不要 reset、checkout、revert 或刪除既有 dirty changes。
- 不要修改 Team ID、provisioning、bundle identifier 或 RAW／sidecar schema。
- 不要把 details 欄、Pencil Pro squeeze、外接顯示器 Wide polish 偷塞進本棒；它們留給後續 Phase。
- 完成後更新 `docs/coordination/CURRENT.md`，列出實際修改檔案、測試結果、未完成項目與下一棒。
