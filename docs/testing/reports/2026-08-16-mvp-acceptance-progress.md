# LumaHarbor Mac-first MVP 人工驗收進度筆記（2026-08-16，未完成，交接用）

> 這不是正式驗收報告（`docs/testing/mvp-acceptance-report-template.md` 是正式格式），是當天做到一半、明天接續用的進度快照。寫這份筆記的原因：跨工具/跨 session 交接不能只靠 Claude 私有 memory，要寫進專案內文件（見使用者過去的交接慣例）。
>
> 對應 spec：[`2026-08-15-mac-first-mvp-acceptance-plan.md`](../../superpowers/specs/2026-08-15-mac-first-mvp-acceptance-plan.md) Gate D/E/F。

## 目前 git 狀態（2026-08-16 當天結束時）

- 分支：`main`
- 本機 HEAD：`d2e0e11`，比 `origin/main`（`18faff9`）領先 **2 個尚未 push 的 commit**：
  - `bb92349` — 加入繁體中文本地化（跟隨 macOS 系統語言，`.lproj/Localizable.strings`，不是 UI 內建切換器）
  - `d2e0e11` — 更新 README（反映 MVP 已可用、新增「Running it」章節，Acknowledgements 沒動）
- `?? docs/reference/` 仍是未追蹤狀態，**不要動它**（使用者/Codex 先前明確要求原樣保留；裡面現在有兩份筆記：`awayphotoraweditor-design-notes.md` 跟 `next-phase-scope-notes.md`）
- 自動化驗收（`Scripts/run-mvp-acceptance.zsh`）在這個 HEAD 上完整跑過，Overall PASS（strict build / 332 tests 0 failures / RawFixtureTests 8/8）

## 測試用資料

- `Fixtures/Private/APFS-Test`：6 張 fixture 副本（來自 `Fixtures/Private/Sony-ARW`）
- `/Volumes/Untitled/LumaHarbor-exFAT-Test`：11 張（6 張同上 + 5 張從使用者相機記憶卡 `/Volumes/Untitled/DCIM/100MSDCF` 額外複製，**都是複製，原始檔／記憶卡沒動過**）

## Gate D／E／F 進度

### 已完成
- App 能正常開啟（`swift run LumaHarbor` 或 Xcode ⌘R；一開始卡在「只有 Build Succeeded、沒有 Running」是使用者只按到 Build 沒按到 Run，已排除）。
- 初次啟動畫面正確（規格 §6.1「加入照片資料夾」畫面）。
- **APFS 資料夾**：
  - 用 ⌘⇧G 導覽到測試資料夾、加入成功。
  - 縮圖有增量出現（不是全部同時跳出來）。
  - 點照片、拉滑桿，畫面會跟著變（但延遲明顯，見下方效能問題）。
  - **完全關閉 App（⌘Q）後重開，重新選同一資料夾，剛剛調整的滑桿數值有正確保留**（使用者原話「有都有在」）——這代表 sidecar 自動保存＋重啟後恢復這條路徑是通的。

### 尚未做（明天從這裡接續）
- **exFAT 資料夾**：完全還沒測，要重複跟 APFS 一樣的流程（加入→縮圖增量→調整→關閉重開確認保留）。
- **拔插 SSD**（Gate E 第 7、8 項）：exFAT 隨身碟開著時直接拔掉、確認不 crash、縮圖還在；重新插上、重新授權、確認資料沒丟。
- **唯讀資料夾情境**（Gate E 第 9 項）：目前還沒有唯讀測試目錄/disk image，需要先準備。
- **改名 relink**（Gate E 第 6 項）、**刪除本機 SQLite/cache 重建**（Gate E 第 5 項）、**壞掉的 RAW/sidecar**（Gate E 第 10 項）：都還沒做。
- **Gate F UI 功能矩陣**：原圖比較、Undo/Redo、切照片前存檔、匯出流水號與取消暫存檔清理、各種錯誤情境提示——都還沒系統性走過。
- **Gate F 效能**：Instruments 沒接（這台機器目前用肉眼判斷），且已經發現一個真實效能問題（見下）。

## 發現的問題（P1，效能，已找到根因，尚未修）

**現象**：拉調整滑桿（例如曝光）時畫面更新明顯不即時，使用者實測約 3 秒延遲。規格 §11 目標是 ≤150ms。

**已確認的根因**（讀過 `EditorViewModel.swift` / `PreviewScheduler.swift` / `CoreImagePreviewRenderer.swift`）：
- 每次滑桿數值變化（`setAdjustment`）都會立刻送出新的 `.interactive` 品質預覽請求，沒有節流（throttle）。
- `PreviewScheduler.submit()` 有正確做「新請求取消舊請求、畫面只顯示最新結果」（`isCurrent` token 機制沒問題）。
- 但實際的 RAW 解碼（`decoder.decode(decodeRequest)`，在 `CoreImagePreviewRenderer.render()` 裡）**是不可中途打斷的單一呼叫**——`Task.cancel()` 只能讓「已經開始解碼」的舊工作在解碼完成後被丟棄（不顯示），不能真的提早停止那次解碼本身消耗的時間。
- 結論：如果使用者拖曳滑桿的頻率比一次互動品質解碼還快，請求就會像排隊一樣越積越多，累積出使用者看到的秒級延遲——不是「取消機制沒做對」，是「解碼工作本身不可搶佔，純靠取消結果無法真正省下已花的時間」。

**還沒做**：修正方案（例如在送出請求那端加節流／debounce，而不是只靠接收端取消；或是降低 interactive 品質的目標像素讓單次解碼更快）需要先跟使用者確認要哪種修法，還沒動手。

## 明天可以問使用者的問題（決定從哪接續）

1. 先把效能問題修掉，還是先把 Gate D/E/F 剩下的人工步驟（exFAT、拔插 SSD、唯讀、壞檔、relink、Gate F 矩陣）走完？
2. 效能問題修法要選哪種：送出端加節流（簡單、但可能讓最新一次調整感覺稍有延遲）、還是先降低 interactive 品質的目標尺寸讓單次解碼更快（複雜一點，但更貼近「即時」的體感）？
3. 兩個尚未 push 的 commit（`bb92349` 本地化、`d2e0e11` README）要不要先 push？
4. `docs/reference/next-phase-scope-notes.md` 裡記的下一階段範圍（風格檔雙軌、批次/單次全格式匯出）——MVP 簽收後要不要就照那份筆記直接開新 spec？
