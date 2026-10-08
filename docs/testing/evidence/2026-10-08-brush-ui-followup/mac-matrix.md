# Mac brush and persistence follow-up matrix

日期：2026-10-08（Asia/Taipei）

整體結果：`UI-BRUSH-01 PASS`、`UI-BRUSH-02 PARTIAL`、`STORE-01 PASS`、`UI-MAC-02 PARTIAL`

## 固定環境

| 欄位 | 值 |
| --- | --- |
| Candidate product SHA | `5d32550029fd317e377a732fa68b57ec2ff2cf85` |
| Branch | `luna/brush-preview-performance-fix` |
| Target | macOS 26.7.1 arm64、Xcode 26.6 |
| Configuration | Debug app bundle |
| Test data | 兩份隔離 RAW 測試副本；公開證據只保存匿名 sidecar 計數 |

測試固定綁定本 worktree 的 `build/LumaHarbor.app`，並使用隔離的 app home 與測試圖庫。沒有改動來源 RAW，沒有提交私人照片、檔名、路徑、裝置識別碼或畫面截圖。

## 完成的操作矩陣

| 案例 | 起始狀態 | 操作 | 實際與保存結果 | 狀態 |
| --- | --- | --- | --- | --- |
| 兩支筆刷與獨立調整 | 文件 A 無本輪測試筆刷 | 建立兩支 adjustment brush，各畫一筆，曝光分別設為 0.1／0.2 | 匿名 sidecar 為 2 masks、strokes `[1,1]`、brush exposures `[0.1,0.2]`；全域曝光 0.7 | PASS |
| 刪除第二支筆刷 | 上列兩支筆刷 | 選取第二支並刪除 | 文件 A 只剩第一支：1 mask、1 stroke、曝光 0.1；另一支的 stroke 與調整未改動 | PASS |
| 筆刷刪除 Undo／Redo | 第二支已刪除 | Undo，再 Redo | Undo 恢復 2 masks／`[1,1]`／`[0.1,0.2]`；Redo 回到 1 mask／`[1]`／`[0.1]` | PASS |
| 刪除結果重開 | Redo 後 1 mask | 回相片庫再重開文件 A | UI 與 sidecar 都維持 1 mask、1 stroke、曝光 0.1 | PASS |
| Local paste 關閉 | 來源 A 為 2 masks／`[1,1]`／`[0.1,0.2]`、全域曝光 0.7；目標 B 為 2 masks／`[2,0]`／`[0.1,null]`、全域曝光 0.5 | 關閉「包含局部調整」，複製 A 並貼到 B | B 的全域曝光改為 0.7；局部資料仍為 `[2,0]`／`[0.1,null]` | PASS |
| Local paste 開啟 | 同上 | 開啟「包含局部調整」，再次複製 A 並貼到 B | B 的局部資料改為來源的 `[1,1]`／`[0.1,0.2]`，順序一致 | PASS |
| Batch sync | 目標 B 先改成全域曝光 0.3、第二支曝光 0.4；來源 A 維持 0.7／`[0.1,0.2]` | 多選 B 與 A，以 A 為 anchor 執行同步 | UI 顯示「1 張已同步，1 張跳過」；兩份文件最後均為全域 0.7、2 masks、`[1,1]`、`[0.1,0.2]` | PASS |
| Snapshot restore | A 為全域 0.7、2 masks／`[1,1]`／`[0.1,0.2]` | 建立 Snapshot 1；把全域改為 0.9、第二支改為 0.4，再 Restore | 同一工作階段回到全域 0.7、`[0.1,0.2]` | PASS |
| Snapshot reopen（修正前反例） | Snapshot 1 在記憶體中可還原 | 回相片庫再重開 | UI 顯示沒有快照；sidecar `snapshotCount=0` | FAIL（已修正） |
| Snapshot persistence repair | 在 `5d32550` 重建相同 App | 建立 Snapshot 1，確認 sidecar，再回相片庫重開 | sidecar 先變為 `snapshotCount=1`；重開仍顯示 Snapshot 1 | PASS |
| 刪除最後快照 | 重開後有唯一 Snapshot 1 | 由快照選單刪除，再回相片庫重開 | sidecar 變為 `snapshotCount=0`；重開顯示「尚未儲存快照」 | PASS |
| Curation isolation | 完成 paste／batch／snapshot 流程後 | 匿名讀取兩份 sidecar 的 curation | 兩份均維持 rating 0、flag none、0 keywords；操作沒有注入 curation | PASS |

## Snapshot 缺陷與修正

最短反例是「建立快照 → 同一工作階段 Restore 成功 → 回相片庫 → 重開」。修正前快照消失，且 sidecar 從未出現 snapshot。根因不是 sidecar codec；`PhotoLibraryService` 已有 `snapshots(for:)` 與 `saveSnapshots(_:for:)`，`EditorSession` 也已在增刪改快照時呼叫保存。Mac App 的 `AppServices.editorDependencies` 沒有接入快照讀寫 closure，`LibraryViewModel` 開啟照片時也沒有載入快照。

`5d32550` 將快照讀寫加入 App 組裝層，並在照片選取的同一個 generation／cancellation 邊界內依序載入調整與快照。新增的 app-level 回歸測試先得到 sidecar 寫入逾時與重開空陣列的預期 RED，再於修正後 GREEN。聚焦結果：`LibraryViewModelTransitionTests` 13/13、`SnapshotWorkflowTests` 9/9 PASS；Debug app bundle 重建成功。完整 Release 結果記於主驗收報告。

## 尚未手動完成

| 案例 | 狀態 | 原因／解除條件 |
| --- | --- | --- |
| 未 release 時切圖 | NOT RUN | 單一 CUA 指標無法在維持真實 drag hold 的同時觸發第二個跨區動作；既有自動 stale-result／切圖測試另列 PASS，但不取代人工結果 |
| 未 release 時 geometry 變更 | NOT RUN | 同上；需要能同時維持 pointer-down 與觸發 inspector/keyboard action 的雙輸入或人工操作 |
| 未 release 時 snapshot restore | NOT RUN | 同上；完成筆畫後的 snapshot restore 已 PASS |
| 未 release 時 Undo／Redo／取消／close | NOT RUN | 同上；完成筆畫的 Undo／Redo 與 close/reopen 已 PASS |
| 受控四色滴管方向 | NOT RUN | 沒有可散布、可辨識取樣區的四色 RAW fixture；一般照片不能代替受控素材 |
| 滴管切圖與晚到結果 | NOT RUN | 需要受控素材與可同時維持取樣 gesture 的操作通道；既有自動取消／晚到隔離結果保持 PASS |

`UI-BRUSH-01` 的建立、繪製、設定、選取、enable、刪除與 Undo／Redo 已補齊，因此改判 PASS。`STORE-01` 的 local off/on paste、batch sync、snapshot restore、快照保存／刪除及重開已補齊，且本輪發現的快照持久化缺陷已修正，因此改判 PASS。中途手勢案例與受控滴管仍未完成，`UI-BRUSH-02`、`UI-MAC-02` 維持 PARTIAL。
