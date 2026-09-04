# LumaHarbor（Mac）Phase 3 手動驗測清單

涵蓋 Phase 3（Preset、多選批次同步、批次復原、虛擬副本）在真實 Mac 視窗上的行為。這份清單只列自動化測試無法涵蓋的「畫面實際看起來／操作起來」項目——每個 task 自己的功能正確性已由 `swift test` 涵蓋，詳見 `docs/coordination/CURRENT.md` 對應段落與 `docs/testing/reports/2026-09-04-awayphotoraweditor-parity-phase3.md`。跟 `REAL_DEVICE_CHECKLIST.md`（iPad 多來源圖庫）是不同的清單，因為 Phase 3 這些功能只存在於 Mac app（`Sources/LumaHarborApp`），iPad app 不受影響。

## 測試資訊

- Build：
- Commit（完整 SHA）：
- 測試日期／時間：
- 測試者代號：
- Mac 型號／macOS 版本：
- 測試用圖庫（APFS/exFAT/檔案提供者，代號即可，不填真實路徑）：

每一項只能填 `PASS`、`FAIL` 或 `NOT RUN`，並附必要備註。`NOT RUN` 不得視為通過。

## A. Preset（built-in vs user 優先序、編輯、備份還原）

| ID | 驗測項目 | 預期行為 | 結果 | 備註／證據 |
|---|---|---|---|---|
| A1 | Preset Browser 同時顯示 Built-In／My Presets／Library 三個 scope | 三個 scope 的項目都可見，Built-In 的兩個內建 preset（"High Contrast"／"Flat (Low Contrast)"）帶有「Built-In」徽章 | NOT RUN | |
| A2 | Built-In preset 無法直接改名／編輯／刪除 | 右鍵選單只剩「Copy to My Presets」可用，其餘操作不可選或不存在 | NOT RUN | |
| A3 | 把 Built-In preset 複製到 My Presets 後可自由編輯 | 複製出來的項目取得全新身分（不是同一個內建 preset 的 UUID），可正常改名／編輯／刪除，原本的 Built-In 項目不受影響 | NOT RUN | |
| A4 | 對已存的 preset 執行「Edit…」，取消某個欄位的勾選 | 該欄位從 preset 的 patch 中移除（之後套用這個 preset 不會再覆蓋該欄位），其餘欄位不受影響 | NOT RUN | |
| A5 | 套用一個 preset 到目前打開的照片 | 對應欄位立即改變，且可用一般的 Undo（⌘Z）復原 | NOT RUN | |
| A6 | 從「Backup My Presets…」匯出一份 `.lhpresetbackup`，之後用「Restore Presets…」還原到 My Presets | 還原後項目與備份時一致，成功／失敗／略過的摘要文字（含中文翻譯）清楚可讀 | NOT RUN | |
| A7 | 匯入一個帶未知欄位的 `.xmp`，再匯出成 `.lhpreset`，再重新匯入 | 未知欄位不遺失（Imported 徽章與原始 XMP 內容都還在） | NOT RUN | |

## B. 多選批次同步

| ID | 驗測項目 | 預期行為 | 結果 | 備註／證據 |
|---|---|---|---|---|
| B1 | ⌘-click 縮圖多選，不改變目前開啟的照片 | 被 ⌘-click 的縮圖出現打勾徽章，開啟中的照片（外框強調色）不變 | NOT RUN | |
| B2 | 在已選取一批縮圖的情況下，於開啟中的照片拖曳一個滑桿（例如 Exposure） | 拖曳放開後，其餘被選取的縮圖也同步套用「這次拖曳實際改變的欄位」，沒被拖動過的欄位不受影響 | NOT RUN | |
| B3 | 拖曳過程中改變縮圖選取（例如中途再 ⌘-click 別的縮圖） | 這次拖曳仍只同步到「手勢開始時」就已選取的目標，中途加入的縮圖不受這次拖曳影響 | NOT RUN | |
| B4 | 對 Basic 面板以外的欄位（HSL／Detail／Effects／Geometry）操作 | 這些欄位目前刻意不參與批次同步（已知 scope 邊界），確認沒有非預期同步 | NOT RUN | |

## C. 批次復原（含部分失敗）

| ID | 驗測項目 | 預期行為 | 結果 | 備註／證據 |
|---|---|---|---|---|
| C1 | 完成一次批次同步後，選單「Undo Batch Sync」 | 目標照片的欄位回到同步前的值，選單顯示「已還原 N 張」等中文報告文字 | NOT RUN | |
| C2 | 對其中一張目標照片先手動編輯過同一欄位，再對批次執行 Undo | 那張照片的手動編輯不被覆蓋（歸類為「跳過」），其餘目標正常還原 | NOT RUN | |
| C3 | 造成其中一個目標復原失敗的情境（例如把該照片所在磁碟暫時移除或設唯讀）後再 Undo | 摘要文字清楚顯示「還原 N 張、失敗 M 張、跳過 K 張」，失敗的那個目標之後可以再次「Undo Batch Sync」重試 | NOT RUN | |
| C4 | 連續做兩次批次同步，只對第一次執行 Undo | 「Undo Batch Sync」只復原最近一次，第一次的結果維持不變（一次性 undo，非堆疊，屬已知、有測試鎖住的設計） | NOT RUN | |

## D. 虛擬副本（建立／刪除／分組／badge／改名）

| ID | 驗測項目 | 預期行為 | 結果 | 備註／證據 |
|---|---|---|---|---|
| D1 | 對任一張照片右鍵「Duplicate as Virtual Copy」 | 立即出現一張新縮圖，緊接在原照片後面，帶有虛擬副本 badge（`doc.on.doc.fill`，縮圖右下角），檔名顯示改為給定的名稱（未命名則顯示與原檔相同的檔名） | NOT RUN | |
| D2 | 編輯虛擬副本的調整值 | 只有這張副本改變，原照片與其他副本完全不受影響 | NOT RUN | |
| D3 | 對虛擬副本本身再建立一次「Duplicate as Virtual Copy」 | 產生「副本的副本」，同樣出現在網格中、緊接在它自己的來源（第一代副本）後面，不會消失或跑到別的地方 | NOT RUN | |
| D4 | 對虛擬副本右鍵「Delete Virtual Copy」 | 該副本消失，原照片與其他副本都還在，磁碟上的 RAW 原檔不受影響 | NOT RUN | |
| D5 | 對原照片右鍵確認「Delete Virtual Copy」不存在／不可選 | 原照片沒有這個刪除選項，只有「Duplicate as Virtual Copy」 | NOT RUN | |
| D6 | 在 Finder 把原照片的 RAW 檔改名／搬到別的資料夾，回到 App 重新掃描該圖庫 | 原照片跟著新路徑更新，它的虛擬副本仍緊接在它後面顯示（不會因為路徑不同而被拆散到別的位置） | NOT RUN | |
| D7 | 開啟「Preferences」或圖庫選單裡刪除本機索引重新掃描的功能（reset rebuildable local data），重新掃描 | 所有虛擬副本（含副本的副本）與它們各自的獨立編輯都恢復顯示，不會消失 | NOT RUN | |

## E. 停止條件

下列任一情況發生時，停止把此 build 當作可上線候選並建立 bug：

- 批次同步或批次復原造成任何照片的調整值跟畫面顯示不一致，或跟磁碟上 sidecar 內容不一致。
- 虛擬副本的操作（建立／刪除／編輯）影響到原照片或其他副本的調整值。
- 刪除虛擬副本連帶刪到 RAW 原檔，或刪到原照片／其他副本的 sidecar。
- 重新掃描或重建本機索引後虛擬副本消失，或副本的副本消失。
- App 閃退，或編輯狀態跨照片錯置。
- 任何必要項目為 `FAIL` 或 `NOT RUN`。

## 整體結論

- 結果：NOT RUN
- 阻擋問題：
- 未執行項目與原因：（此清單建立時尚未有真機／Mac 桌機環境可操作，全部項目為 NOT RUN）
- 證據位置（僅填去識別化名稱）：
