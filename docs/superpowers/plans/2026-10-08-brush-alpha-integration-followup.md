# LumaHarbor 文件同步、操作驗收與 Alpha 整合 Implementation Plan

> **For agentic workers:** Use `executing-plans` to implement this plan task-by-task in the current session. Steps use checkbox syntax for tracking. 預設由本 task 的 Codex 單一寫入者執行，不自動委派代理。

**Goal:** 同步根目錄 README 與候選實作，補齊目前能執行的操作證據，交付可判斷是否進入 main 的 Alpha 整合包。

**Architecture:** 沿用已通過的筆刷 renderer、decoded-preview cache、Sidecar v5 與驗收工具。先修正文件，再逐項執行 Simulator／Mac 操作；只有重現產品缺陷才修改程式。完整驗收與 Alpha 例外整合分別記錄，不改寫未執行 gate。

**Tech Stack:** Markdown、Git、SwiftUI、XCTest、Xcode Simulator、既有 Swift／Python 驗收工具。

## 狀態、基準與取代範圍

- 日期：2026-10-08；Task 1 已完成並通過獨立審查；Task 2 已完成可執行操作與限制記錄；Task 3～5 尚未完成。
- 起始 HEAD：`f365f88d3ba22df329886651dd5573c35a3b5416`。
- 延續分支：`luna/brush-preview-performance-fix`；本次是同一未整合候選的文件與驗收收尾，不是新的產品任務。
- 已驗證產品／harness：`7af212512f59768801081765808202fe84a85b25`；其後至起始 HEAD 僅有文件／證據變動。
- 最近確認 main：`82542e73aae8f16b0ba7e4d9d36a8a42451a7319`；實際整合前必須重新核對。
- 既有 Draft PR：[#2](https://github.com/unizalin/LumaHarbor/pull/2)。
- 依據：[repair spec](../specs/2026-10-06-brush-performance-and-acceptance-repair-spec.md) §6、§9，以及[目前驗收報告](../../testing/reports/2026-10-07-brush-preview-performance-fix.md)。
- 本計畫只調整剩餘工作順序；不取代既有像素、效能、資料保存或 READY 標準。
- 使用者本輪要求先寫實作方向；此計畫不構成合併 main、發布或豁免驗收的授權。

## Global Constraints

- 已有 7 個效能 FAIL 的修正與自動驗收證據保留，不重做已證實通過的工作。
- 不降低解析度、不刪除筆刷點、不跳過調整、不放寬 benchmark 門檻。
- Sidecar v5、舊筆刷共存、mask 順序、paint／erase、recipe 隔離、取消與晚到結果隔離保持。
- PASS／FAIL／SKIPPED／NOT RUN／PARTIAL 分開；GitHub 沒有 checks 不等於測試通過。
- 測試使用隔離的測試文件或副本；Delete 只作用於測試筆刷／測試快照，不刪來源 RAW。
- 無障礙樹可讀不等於 VoiceOver 實測；Simulator 不代替 Pencil、實機觸控、實機效能或灰卡量測。
- 公開證據不含私人路徑、照片名稱、RAW、裝置識別碼、簽章、憑證或私人照片截圖。
- 只有文件改動時執行文件檢查；產品改動才新增缺陷回歸測試並重跑受影響驗收。

## Task 1：同步根目錄 README 與文件入口

**Files:** 修改 `README.md`、`docs/coordination/CURRENT.md`；核對 `Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift`、`docs/coordination/DECISIONS.md` D-012／D-013。必要時更新 `docs/testing/beta/QUICK_START_ZH-HANT.md` 中與本次功能直接相關的敘述。

**輸入／交付：** 現有程式與報告 → 正確描述目前分支能力、限制及驗收入口的 README。

- [x] 將 Sidecar v4 功能條目改為 v5；說明保留中繼資料、curation、snapshots，並新增有順序的 adjustment brush masks。舊版讀取能力以現有測試為準，不宣稱舊 App 可完整保存 v5。
- [x] 補上白平衡數值輸入／滴管、paint／erase、筆刷 Undo／Redo；說明舊筆刷與新調整筆刷共存，不宣稱自動轉換。
- [x] 保留「發布前 Alpha」；新增驗收摘要連結，明列自動效能通過、Mac／Simulator 部分完成、實機／輸入／灰卡尚待驗收。benchmark 數據連到報告，避免複製多套數字。
- [x] README 建議文案：「目前為發布前 Alpha。筆刷效能與自動回歸已通過；Mac 與 iPad 模擬器已完成部分操作驗收，實體 iPad、輸入裝置與灰卡色彩仍待驗證。完整結果見驗收報告。」
- [x] 檢查相對連結存在、版本與程式一致、沒有把候選寫成已進 main。

驗證命令：

```sh
rg -n 'currentSchemaVersion' Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift
rg -n 'Sidecar|v4|v5|Alpha|驗收' README.md docs/testing/beta/QUICK_START_ZH-HANT.md
git diff --check
```

完成條件：README 與 v5 程式／報告一致；文件檢查 exit 0。獨立提交文件變更，不因文件更新重跑完整產品 suite。

## Task 2：補 Simulator 可執行矩陣

**Files:** 新增 `docs/testing/evidence/2026-10-08-brush-ui-followup/simulator-matrix.md` 與該目錄 `README.md`；更新目前驗收報告及 CURRENT。保留既有 Simulator 摘要作歷史證據。

**輸入／交付：** 已保存的直橫向、paint／Undo／Redo／重啟證據 → 補足尚缺的逐案例操作與保存矩陣。

- [x] 核對 source SHA、app bundle 與 Simulator runtime。沿用已驗證 bundle前確認 Sources／Apps／依賴沒有變動；diff check exit 0，因此不重建未變更產品。
- [x] 執行 Files 選取流程；檔案進入 Quick Look，未證明 Files 直接交件給 app，因此該步與 app-copy／in-place 分列 NOT RUN。另在 app 中完成新增筆畫、saved、terminate／relaunch 與 mask／stroke／曝光核對。
- [x] 使用 iPad 內實際 Split View／多工視窗調整成窄視窗；確認 inspector 控制、canvas、保存／重開。工具未曝露精確 logical point 內容尺寸，該欄維持 NOT RUN。
- [x] 核對產品畫布 zoom 0.75×／1×／2× 可執行性；iPad scale clamp 為 1×～5×且 UI 無精確倍率讀值，原矩陣無法完成並維持 NOT RUN。
- [x] 對無法證明的精確倍率／內容尺寸記錄具體限制；沒有注入 sidecar，也沒有新增僅供通過驗收的產品控制。
- [x] 每列保存 SHA、匿名環境、起始狀態、操作、預期／實際、保存結果及狀態；原 spec 子項未全數通過，UI-SIM-01 維持 PARTIAL。

完成條件：每項都有可核對的結果或明確限制；不能只以 app 啟動或畫面存在判定 source mapping 正確。

## Task 3：補 Mac 局部操作與資料保存

**Files:** 新增 `docs/testing/evidence/2026-10-08-brush-ui-followup/mac-matrix.md`；更新目前驗收報告、證據索引及 CURRENT。

**輸入／交付：** 既有 UI-MAC-01 PASS 與 brush／store PARTIAL → 尚缺子項的動作、history 與保存證據。

- [ ] 在隔離測試文件新增兩支筆刷，刪除其中一支，再 Undo／Redo；核對另一支 mask／stroke 未改動，重開結果一致。
- [ ] 在筆畫尚未 release 時，分別執行切圖、geometry 變更、snapshot restore、Undo／Redo、取消及 close；以各自獨立案例核對舊 release 沒有新增 stroke／history／保存，也沒有污染新文件。
- [ ] UI 工具無法可靠保持拖曳途中並觸發另一動作時，記為 NOT RUN 並保留自動 race 測試的獨立結果，不以自動測試取代人工結論。
- [ ] 測試 Local off／on paste、batch sync 與 snapshot restore／刪最後快照；逐列比較新舊筆刷、curation、snapshot 與重開資料。
- [ ] 用可散布的四色偏測試素材補滴管方向、取消及晚到結果；記錄取樣區與前後數值。若只有 synthetic 素材，只判定操作／方向，不用它宣稱 RAW 灰卡 D65 Lab／ΔE00 通過。
- [ ] 若重現缺陷，先保存最短操作反例與失敗證據，再決定受影響檔案、建立回歸測試、修正並複驗。沒有已重現缺陷時不預先重構 renderer 或 EditorSession。

完成條件：每個 PARTIAL 的缺口被補證或具體列出；新發現的資料保存、像素或取消回歸必須修正後才進入整合決策。

## Task 4：列清硬體、素材與 PERF-UI 依賴

**Files:** 更新 `docs/testing/evidence/2026-10-08-brush-ui-followup/README.md`、目前驗收報告與 handoff。

- [ ] 重新確認配對 iPad 是否可用；可用時依既有部署授權和規則執行真機基本觸控、旋轉、Split View、來源離線／重接、保存／重開。
- [ ] Pencil、外接鍵盤、VoiceOver 分列可用性與實際操作；沒有設備就記 NOT RUN 和解除條件。
- [ ] 清點合格 RAW 灰卡及受控 ROI reference，記匿名素材數與是否符合 spec。無合格素材不得用普通照片或平均 RGB 代替。
- [ ] PERF-UI 需要相同 B/O 的 16 ms heartbeat 與 30 次手勢記錄。先確認 recorder 是否存在；不存在時另交付 recorder 設計，定義執行緒、單調時鐘、手勢邊界、原始樣本 schema、取消／缺樣處理與測試後才開發。此計畫不把 renderer latency 當成 UI heartbeat。
- [ ] 將硬體／素材依賴與可自行開發的 recorder 分開追蹤；設備缺席不阻止 Task 1～3。

完成條件：每個未完成 gate 有原因、所需資源與具體解除動作；不新增沒有量測的 PASS。

## Task 5：整理交付並決定 main 整合方式

**Files:** 更新目前驗收報告、`docs/coordination/CURRENT.md`、`docs/coordination/2026-10-07-brush-preview-performance-fix-handoff.md`。若採用明確授權的 Alpha 例外，才在 `docs/coordination/DECISIONS.md` 追加本次例外。

- [ ] 合併前重新查詢遠端 main／PR HEAD、差異範圍與 GitHub checks；若 base 改變，重新評估整合差異和所需驗證。
- [ ] 核對本 PR 包含白平衡、筆刷 UI、Sidecar v5 及效能修正，不能以「只合併效能」描述整份 PR。
- [ ] 文件更新只跑格式、連結、checksum 與隱私檢查。若 Task 2～3 修了產品，跑受影響 focused tests；renderer／decode／scheduler 改動還要重跑相關 parity、取消、RSS 與 B/O gate。產品改動後完成 Release suite並記實際數量，不沿用舊 SHA 結果。
- [ ] 提交可審查摘要：exact HEAD、scope、PASS／FAIL／PARTIAL／NOT RUN、資料相容性與 remaining actions。

| 整合方式 | 條件 | 文件狀態 |
| --- | --- | --- |
| 一般整合 | 原必要 gate 全部完成，review／回歸通過且已授權 merge | 依 spec 判定 READY |
| Alpha 例外整合 | 使用者明確接受列出的未驗收項目並授權此 PR 進 main；無未處理的已知資料／像素／取消回歸；遵守遠端保護規則 | 保留 DONE_WITH_CONCERNS，追加例外範圍及後續工作，不改成 PASS |
| 暫不整合 | 上述條件未成立 | 保留 Draft，成果留在遠端分支 |

- [ ] 若採 Alpha 例外，只針對本次 exact candidate 記錄，不能永久解除其他版本的驗收要求；未知風險必須明列。
- [ ] 真正授權後透過 PR 整合，核對 merged SHA 與遠端 main；不得 force-push 或覆寫其他 worktree。
- [ ] 依 AGENTS 的產品版本推送規則，以實際 main SHA 建置／同步 Mac Release 並核對版本、簽章及啟動；可用且獲授權的 iPad 同步驗證，不可用則記 NOT RUN。若對外散布新版，依 D-011 更新產品版本，避免重複發行相同版本。
- [ ] 應用程式安裝成功不取代未完成的功能驗收；不刪除保留的 branch／worktree 或歷史證據。

## 執行順序與交接

順序：Task 1 → Task 2 → Task 3 → Task 4 → Task 5。先完成可直接執行的工作，再提出有具體結果的整合決策；不用等實機才能更新 README 或跑 Simulator。

本次交付僅為計畫與 coordination 索引。下一個有界動作是 **Task 1：更新根目錄 README 的 Sidecar v5、白平衡／筆刷能力與 Alpha 驗收限制**。沒有新增測試結果、沒有改變 READY 判定，也沒有授權 main 合併。
