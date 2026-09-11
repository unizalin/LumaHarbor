# Gemini IDE Handoff: P5-P7

## 開始位置

- Worktree：`<USER_HOME>/Documents/ChatGPT/LumaHarbor/.worktrees/claude-professional-editing-completion`
- Branch：`claude/professional-editing-completion`
- HEAD：`6e98ecc`（P4 已完成且通過驗證）
- 目前工作樹應保持乾淨；不要重設、覆蓋或刪除既有提交。

## 先讀取

依序讀取：

1. `AGENTS.md`
2. `CLAUDE.md`
3. `GEMINI.md`
4. `docs/coordination/CURRENT.md`
5. `docs/coordination/DECISIONS.md`
6. `docs/coordination/2026-09-10-p4-lens-presence-color-grading-handoff.md`
7. `docs/superpowers/specs/2026-09-10-professional-editing-completion-design.md`
8. `docs/superpowers/specs/2026-09-10-gemini-project-spec-reading-protocol.md`

## 工作指示

使用 Gemini IDE 直接實作，不建立 Epic/Issue，不推送遠端，不 merge/rebase，不修改 code-signing 設定。保留既有 P0-P4 行為與提交。採用 TDD：先寫會失敗的測試，再實作，再跑完整驗證。每個 phase 完成後更新 `CURRENT.md` 與 handoff，並建立一個清楚的 phase commit。

### P4 目前狀態

P4 已完成：鏡頭校正、Presence、Color Grading、Black & White、Rendering Profile、Preset/XMP、Mac Inspector UI。已驗證 `swift test` 2150 tests（9 skipped、0 failures）、strict build、iPad Simulator build、diff check 與隱私掃描。P4 handoff 的主要待確認事項是 iPad 實際面板 mounting 與真機 UI 驗收；開始 P5 前先檢查 `PadInspectorHost`/`PadToolRail` 是否真的呈現新面板，必要時一起補齊。

### P5：Advanced Masks、AI Repair、Perspective

先撰寫並核對 P5 spec/plan，再實作 Brush/Radial/Range/Subject/Background masks、裝置端 Vision fallback、非破壞式 AI Repair/Heal 與四角透視。所有操作需可 undo、離線可用，不下載模型；AI 不支援或失敗時必須有明確且可測試的 fallback。Mac 與 iPad 共用資料模型、渲染與驗證契約，UI 依平台自適應。

### P6：Snapshot 與專業預覽

完成命名/複製/刪除/回復 Snapshot、A/B compare、clipping/gamut overlay、Soft Proof 與 sidecar migration。先讀 `DECISIONS.md` 中關於 Snapshot schema 的決策；Snapshot 回復是單一 compound undo，A/B 切換不可寫入 sidecar。

### P7：跨裝置驗收與發布準備

完成 Mac/iPad parity、效能與 10k 照片測試、RAW/APFS/exFAT fixture 驗收、真機檢查、隱私與 binary path scan、README/使用說明更新，以及 release ZIP 前的完整驗證。P7 未完成前不要建立對外發布 ZIP。

## 每個 phase 的完成條件

- 相關 model、render、XMP/Preset、Mac/iPad UI 與測試完成。
- `swift test`、strict build、iPad Simulator build 與 `git diff --check` 通過。
- 掃描 `/Users/…`、`/Volumes/…`、簽章識別字、私鑰標頭與 UDID，不得把私人資訊帶入 source 或 build artifact。
- 更新 `docs/coordination/CURRENT.md`、phase handoff 與必要決策紀錄。
- commit 後回報 commit id、測試結果、未能執行的真機/fixture 項目與下一步。

若 token 不足，保留所有變更並更新本檔或新增明確 checkpoint，列出已完成檔案、最後通過的測試與下一個命令；不要回復工作樹。
