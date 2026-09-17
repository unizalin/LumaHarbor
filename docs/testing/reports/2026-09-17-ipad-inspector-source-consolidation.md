# iPad Inspector 來源整併回歸報告

日期：2026-09-17  
狀態：`DONE_WITH_LIMITS`

## 範圍

本輪完成已核准 Phase 0：

- 將 `PadToolRail` 與 `PadInspectorHost` 收斂為唯一 canonical source，並同步 SwiftPM／Xcode target membership。
- 移除未使用的 details、handedness、scene-tab、focus-mode、drawer reducer 與 floating policy state。
- 將 `PadEditorView` 從大型混合責任檔案縮減為 composition root，拆出工具列、畫布／比較、底片列、Inspector 容器、輸出、Preset、Info 與裁切元件。
- 保留同一個 `EditorSession`、`PadInspectorCoordinator`、`InspectorNavigationModel` 與既有調整值、預覽／提交、undo／redo、autosave、輸出及文件流程。

## 變更檔案

新增 iPad 元件：

- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorToolbar.swift`
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorCanvasView.swift`
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorFilmstrip.swift`
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorInspectorContainer.swift`
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorExportViews.swift`
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorPresetViews.swift`
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorInfoViews.swift`
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadCropOverlayView.swift`

調整與測試：

- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift`
- `Apps/LumaHarborPad.xcodeproj/project.pbxproj`
- `Tests/AdjustmentUITests/PadEditorCompositionContractTests.swift`
- 搬檔後改讀 canonical／focused owner 的 Inspector、Preset、Info、裁切、比較與圖庫契約測試。

## 驗證

| 檢查 | 結果 |
| --- | --- |
| `swift test` | PASS；2,349 executed、10 skipped、0 failures |
| Inspector／跨平台 focused suite | PASS；162 tests |
| `swift test --filter PadEditorCompositionContractTests` | PASS；3 tests |
| `swift build -Xswiftc -strict-concurrency=complete` | PASS |
| unsigned generic iOS Simulator `xcodebuild` | PASS；exit 0 |
| canonical source／inactive policy scan | PASS；每個 host／rail 僅一個 declaration，active source 無舊 policy symbol |
| `git diff --check` | PASS |

`swift build --package-path Apps/LumaHarborPad.swiftpm -Xswiftc -strict-concurrency=complete` 已嘗試，但目前命令列環境無法解析 App Playground manifest 的 `AppleProductTypes`；這不是 target 編譯錯誤，Xcode iOS target 已成功建置。

## 提交紀錄

本 worktree 從 `origin/main` `f694308723d8cae98db10dd4416d66f72ffb58a2` 建立，Phase 0 提交順序如下：

- `c5b6b8f` `docs: define universal mobile workspace architecture`
- `857d5ce` `docs: add ipad inspector consolidation plan`
- `81e03ab` `test: lock ipad inspector source ownership`
- `4cd5267` `refactor: consolidate ipad inspector sources`
- `3148ea1` `refactor: remove inactive ipad workspace state`
- `2078907` `refactor: split ipad editor into focused views`
- `f7a1d30` `docs: record ipad inspector consolidation verification`

尚未執行 push、merge、rebase 或改寫 `origin/main`。

## 未執行與限制

- 實體 iPad 的直向／橫向／Split View 視覺與觸控驗收：`NOT RUN`。
- 拖曳、縮小／還原、Wipe、裁切控制點與旋轉／翻轉的真機手勢驗收：`NOT RUN`。
- VoiceOver 與 Dynamic Type 人工驗收：`NOT RUN`。
- iPhone shell／行動編輯器實作：`NOT RUN`，留在後續 Phase 1 之後的獨立計畫。

## 交接

本報告對應計畫 `docs/superpowers/plans/2026-09-17-ipad-inspector-source-consolidation.md`。決策 D-010（Mac 與 iPad 共用 Inspector 語意、容器依尺寸適配）維持不變。下一步應另立 Phase 1 `SharedInspectorContent` implementation plan，再處理 universal iOS／iPhone 外層，不在本輪擴大範圍。
