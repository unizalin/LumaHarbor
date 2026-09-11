# iPad／Mac 視覺修整與曲線 UX：Claude 交接

## Status

`IN_PROGRESS`

## Git state

- Source branch: `claude/professional-editing-completion`
- Source HEAD at transfer start: `73ec409201b7623c19b15c5f8635360a482c8110`
- Base for this bounded phase: current branch HEAD plus the preserved dirty changes listed below
- Upstream/push/merge/rebase: 未執行

## Changes prepared by Codex

- 新增規格：`docs/superpowers/specs/2026-09-11-ipad-mac-visual-polish-and-curve-ux.md`
- 規格涵蓋：共用 Inspector 視覺階層、數值輸入欄位、slider row、四通道曲線的任意控制點／刪除／undo、直方圖抗尖峰顯示、iPad 自適應版面、無障礙與真機驗收。
- 不要求或授權修改：簽章、provisioning、Bundle ID、RAW／sidecar schema、匯出色彩與其他 agent 的 dirty files。

## Existing verification evidence

- `swift test --filter 'ToneCurveEditorModelTests|HistogramPanelTests|AdjustmentValueInputTests'`: PASS（16/16）
- `swift test --filter 'ToneCurveEditorModelTests|HistogramPanelTests|AdjustmentValueInputTests|EightLanguageLocalizationGateTests|LocalizationSmokeTest'`: PASS（43/43）
- `swift build -Xswiftc -strict-concurrency=complete`: PASS
- iPad Simulator `xcodebuild ... CODE_SIGNING_ALLOWED=NO build`: PASS
- `git diff --check`: PASS
- Full `swift test`: 2195 executed、9 skipped、1 failure；唯一失敗是保留的本機 signing Team contract mismatch，非本階段產品改動
- 真機 iPad／Apple silicon Mac 視覺驗收：`NOT RUN`，需用 Xcode clean build 後重新安裝／Run

## Dirty files and ownership

- 使用者既有本機變更：`Apps/LumaHarborPad.xcodeproj/project.pbxproj`（signing；Claude 不得修改、stage 或提交）
- Codex 既有產品變更：`Sources/AdjustmentUI/AdjustmentValueInput.swift`、`Sources/AdjustmentUI/CurveAdjustmentPanel.swift`、`Sources/AdjustmentUI/HistogramPanel.swift`、對應測試、8 語本地化、`docs/coordination/CURRENT.md`（不得回復；可在本 spec 範圍內延伸）
- 本次交接文件與 spec：由 Codex 提供，Claude 可讀取並在完成後更新 `CURRENT.md`

## Concerns and blockers

- 真機視覺 gate 仍未完成；模擬器 build 成功不能取代 iPad 11／13 吋、旋轉、Split View、Stage Manager 與 Apple Pencil 驗收。
- 命令列沒有可用 signing identity；Xcode GUI 的 Personal Team 設定屬本機狀態，不得寫入公開協作內容。
- 直方圖 screenshot 曾出現極端裁切尖峰造成其餘細節扁平；驗收需確認新顯示仍保留 clipping count 的真實數值。

## Next action for Claude

1. 先讀 `AGENTS.md`、`docs/coordination/CURRENT.md`、`docs/coordination/DECISIONS.md` 與 `docs/superpowers/specs/2026-09-11-ipad-mac-visual-polish-and-curve-ux.md`。
2. 依 spec 完成 UI／UX 修整與必要測試；先檢查既有實作，避免覆寫 Codex 或使用者 dirty files。
3. 如目前 agent 不適合視覺或真機工作，可關閉該 agent；需要時自行尋找／啟用合適的 iOS design review 或 iOS QA agent。不得讓兩個 agent 同時編輯同一工作樹。
4. 在 Xcode 以 `Product > Clean Build Folder` 後重新 Run 真機，記錄每個人工 gate 的 `PASS`／`FAIL`／`SKIPPED`／`NOT RUN`。
5. 完成後更新 `CURRENT.md`，列出實際修改檔案、測試命令與結果；不得執行 `git push`、`git merge`、`git rebase`，也不得修改 signing project file。

## Suggested skills

- `gstack-ios-design-review`／`ios-design-review`
- `gstack-ios-qa`／`ios-qa`
- `test-driven-development`
- `verification-before-completion`
