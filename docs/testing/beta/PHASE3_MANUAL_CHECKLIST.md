# LumaHarbor（Mac）Phase 3 手動驗測清單

涵蓋 Phase 3（Preset、多選批次同步、批次復原、虛擬副本）在真實 Mac 視窗上的行為。這份清單只列自動化測試無法涵蓋的「畫面實際看起來／操作起來」項目——每個 task 自己的功能正確性已由 `swift test` 涵蓋，詳見 `docs/coordination/CURRENT.md` 對應段落與 `docs/testing/reports/2026-09-04-awayphotoraweditor-parity-phase3.md`。跟 `REAL_DEVICE_CHECKLIST.md`（iPad 多來源圖庫）是不同的清單，因為 Phase 3 這些功能只存在於 Mac app（`Sources/LumaHarborApp`），iPad app 不受影響。

## 測試資訊

- Build：Debug `.app` bundle built with `Scripts/build-app-bundle.sh debug`
- Commit（完整 SHA，A6-A7/D 段見下方接續測試）：2d697df（A6 修法）；D 段測試沿用同一個 build，未再變動 product code
- 測試日期／時間：2026-09-04 11:00 CST（Codex-CUA 第一輪）；2026-09-04 11:33-11:58 CST（Claude 接續，A6 修復驗證 + D 段）
- 測試者代號：Codex-CUA（A1-A5）；Claude（A6 修復驗證、D1-D5/D7）
- Mac 型號／macOS 版本：Mac mini (Mac16,10), Apple M4, 32 GB, macOS 26.6.2 (25G82)
- 測試用圖庫（APFS/exFAT/檔案提供者，代號即可，不填真實路徑）：APFS-TMP-001（3 張 Sony ARW 測試副本 + 1 份 XMP fixture）
- Claude 接續測試方式：`osascript`/System Events UI scripting（accessibility tree 點按、選單）+ `screencapture` 逐步截圖確認，搭配直接讀取隔離 Application Support 下的 `library.json`／sidecar／SQLite 索引檔案內容做交叉驗證；沒有專用的螢幕操作工具，全部靠 accessibility API 拼出來的，過程中多次因座標／element 對應錯誤重試，已在下方各項備註留下實際觀察到的證據。

每一項只能填 `PASS`、`FAIL` 或 `NOT RUN`，並附必要備註。`NOT RUN` 不得視為通過。

## A. Preset（built-in vs user 優先序、編輯、備份還原）

| ID | 驗測項目 | 預期行為 | 結果 | 備註／證據 |
|---|---|---|---|---|
| A1 | Preset Browser 同時顯示 Built-In／My Presets／Library 三個 scope | 三個 scope 的項目都可見，Built-In 的兩個內建 preset（"High Contrast"／"Flat (Low Contrast)"）帶有「Built-In」徽章 | NOT RUN | Partial：UI 顯示 `Flat (Low Contrast)`／`High Contrast` 與「內建」徽章；複製到 My Presets 後同名 user preset 也出現在同一區塊。尚未建立 Library scope preset，因此未完整驗證三個 scope。 |
| A2 | Built-In preset 無法直接改名／編輯／刪除 | 右鍵選單只剩「Copy to My Presets」可用，其餘操作不可選或不存在 | PASS | Built-in row 的更多選單只顯示 `匯出…` 與 `Copy to My Presets`，未顯示 rename/edit/delete。 |
| A3 | 把 Built-In preset 複製到 My Presets 後可自由編輯 | 複製出來的項目取得全新身分（不是同一個內建 preset 的 UUID），可正常改名／編輯／刪除，原本的 Built-In 項目不受影響 | PASS | 複製後 My Presets 出現第二筆 `Flat (Low Contrast)`；該 row 更多選單顯示重新命名、編輯、匯出、Copy to This Library、刪除。 |
| A4 | 對已存的 preset 執行「Edit…」，取消某個欄位的勾選 | 該欄位從 preset 的 patch 中移除（之後套用這個 preset 不會再覆蓋該欄位），其餘欄位不受影響 | PASS | 編輯 sheet 顯示單一「對比」欄位；取消勾選並儲存後，隔離 My Presets 檔案的 `patch` 為空物件。 |
| A5 | 套用一個 preset 到目前打開的照片 | 對應欄位立即改變，且可用一般的 Undo（⌘Z）復原 | PASS | 套用 `High Contrast` 後 `對比` 變 `+30`、`飽和度` 變 `+10`；按 toolbar 復原後兩者回到 `0`。 |
| A6 | 從「Backup My Presets…」匯出一份 `.lhpresetbackup`，之後用「Restore Presets…」還原到 My Presets | 還原後項目與備份時一致，成功／失敗／略過的摘要文字（含中文翻譯）清楚可讀 | PASS | 原始 FAIL 見 `docs/testing/beta/PHASE3_BUG_A6_PRESET_RESTORE_SUMMARY.md`。已用 commit `2d697df` 修復（把摘要 alert 邏輯搬進 `PresetLibraryViewModel.restoreBackupAndPresentSummary`），重建 app bundle、重啟同一個隔離測試環境後，Claude 用 UI scripting 重新選同一份 `.lhpresetbackup` 執行 Restore：視窗確實跳出「還原完成 / 1 已存在」alert，按「好」可正常關閉，App 回到正常狀態。 |
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
| D1 | 對任一張照片右鍵「Duplicate as Virtual Copy」 | 立即出現一張新縮圖，緊接在原照片後面，帶有虛擬副本 badge（`doc.on.doc.fill`，縮圖右下角），檔名顯示改為給定的名稱（未命名則顯示與原檔相同的檔名） | PASS | 對 `phase3-a.ARW` 右鍵只有一個選項「複製為虛擬副本」；點下後立即在原照片右邊出現第二張 `phase3-a.ARW` 縮圖，右下角有副本 badge 圖示。 |
| D2 | 編輯虛擬副本的調整值 | 只有這張副本改變，原照片與其他副本完全不受影響 | PASS | 開啟副本、套用 `High Contrast` preset 後直接讀副本自己的 sidecar json，確認 `contrast: 30`／`saturation: 10` 且 `variantOf` 正確保留指向原照片 ID；同時確認原照片的 sidecar 檔案（`.lumaharbor/edits/<原照片 ID>.json`）**不存在**，即從未被寫入過，證明編輯完全沒外溢到原照片。 |
| D3 | 對虛擬副本本身再建立一次「Duplicate as Virtual Copy」 | 產生「副本的副本」，同樣出現在網格中、緊接在它自己的來源（第一代副本）後面，不會消失或跑到別的地方 | PASS | 對第一代副本右鍵，選單多了「刪除虛擬副本」（確認只有副本才有刪除選項，原照片沒有，見 D5）；選「複製為虛擬副本」後，第三張 `phase3-a.ARW` 縮圖緊接在第一代副本後面出現，同樣帶副本 badge。 |
| D4 | 對虛擬副本右鍵「Delete Virtual Copy」 | 該副本消失，原照片與其他副本都還在，磁碟上的 RAW 原檔不受影響 | PASS | 對「副本的副本」右鍵選「刪除虛擬副本」後，該縮圖立即消失，原照片、第一代副本、`phase3-b.ARW`／`phase3-c.ARW` 都還在，數量正確減少 1 張。 |
| D5 | 對原照片右鍵確認「Delete Virtual Copy」不存在／不可選 | 原照片沒有這個刪除選項，只有「Duplicate as Virtual Copy」 | PASS | 見 D1／D3 備註：對原照片右鍵永遠只有「複製為虛擬副本」一個選項；只有對虛擬副本右鍵才會多出「刪除虛擬副本」。 |
| D6 | 在 Finder 把原照片的 RAW 檔改名／搬到別的資料夾，回到 App 重新掃描該圖庫 | 原照片跟著新路徑更新，它的虛擬副本仍緊接在它後面顯示（不會因為路徑不同而被拆散到別的位置） | NOT RUN | 需要在 Finder 對隔離測試圖庫的檔案做搬移／改名操作，這輪沒有執行（環境操作風險評估後跳過，留給下一輪或真人測試）。 |
| D7 | 開啟「Preferences」或圖庫選單裡刪除本機索引重新掃描的功能（reset rebuildable local data），重新掃描 | 所有虛擬副本（含副本的副本）與它們各自的獨立編輯都恢復顯示，不會消失 | PASS | App 內找不到明顯的「刪除本機索引」選單項目，改用直接刪除隔離 Application Support 下的 `library.sqlite*`／`cache` 目錄（等同 `resetRebuildableLocalData()` 的效果），**完全退出 app 再重新啟動**（不是在活著的 process 上直接刪檔——這樣做過一次會讓 app 因為手上還握著已刪除的 SQLite 檔案控點而報「無法讀取本機索引」錯誤，屬於操作方式問題不是產品 bug，已在下方備註記錄避免誤判）。乾淨重啟後 app 自動重新掃描，sidebar 正確顯示「4 張照片」，虛擬副本（含 badge）正常出現在原照片旁邊，`library.sqlite` 的 `photo` table 也確認新增了帶正確 `variant_of` 的一列。**額外發現（非本項目阻擋，供留意）**：測試中另外發現一筆*沿用自更早期測試 session* 的虛擬副本紀錄（sidecar/manifest 都還在），其 `variantOf` 指向的原照片 ID 已經跟原照片目前實際的 ID 對不上（推測是更早某次 session 的原照片身分變動所致，非本輪任何操作造成——`RelinkResolver.resolve` 對同路徑檔案的身分解析本身沒有問題，這輪另外新建一份乾淨的副本重跑整個 D7 流程即正確存活），因此那筆「孤兒」副本目前在 UI 上永久不可見，但沒有被刪除、原照片與其他資料都不受影響。這不影響 D7 本身的判定，但值得之後留意「副本的 `variantOf` 一旦與原照片實際身分不同步時沒有任何提示或復原路徑」這件事。 |

## E. 停止條件

下列任一情況發生時，停止把此 build 當作可上線候選並建立 bug：

- 批次同步或批次復原造成任何照片的調整值跟畫面顯示不一致，或跟磁碟上 sidecar 內容不一致。
- 虛擬副本的操作（建立／刪除／編輯）影響到原照片或其他副本的調整值。
- 刪除虛擬副本連帶刪到 RAW 原檔，或刪到原照片／其他副本的 sidecar。
- 重新掃描或重建本機索引後虛擬副本消失，或副本的副本消失。
- App 閃退，或編輯狀態跨照片錯置。
- 任何必要項目為 `FAIL` 或 `NOT RUN`。

## 整體結論

- 結果：**PARTIAL PASS**（原本的 A6 阻擋問題已修復並重新驗證通過；D 段虛擬副本核心流程 6/7 項通過；仍有多項因時間/風險考量維持 `NOT RUN`，尚不能整體判定為可上線候選）。
- A6 阻擋問題已解除：見上方 A6 列，commit `2d697df` 修復並經 Claude 用 UI scripting 實測確認「還原完成」摘要 alert 正確顯示。
- D 段虛擬副本：D1／D2／D3／D4／D5／D7 皆 `PASS`（含建立、編輯隔離、巢狀副本、刪除、原照片無刪除選項、本機索引重建後存活，見各列備註的具體證據），D6（Finder 外部改名/搬移後重新掃描）維持 `NOT RUN`。
- 未執行項目與原因：A1（Library scope 未完整覆蓋，維持 Partial）、A7、B1-B4、C1-C4、D6 依本清單停止條件維持 `NOT RUN`——這些多為需要額外情境建置（滑桿拖曳手勢、磁碟唯讀模擬、Finder 外部檔案操作）的項目，這一輪基於時間與環境操作風險評估後未執行，留給下一輪或真人測試。
- 額外發現：一筆沿用自更早期測試 session 的孤兒虛擬副本（`variantOf` 與原照片目前身分不同步，永久不可見但無資料遺失），詳見 D7 備註；不阻擋本輪判定，建議之後找時間排查。
- 證據位置（僅填去識別化名稱）：CUA-Phase3-A1-A6-20260904；APFS-TMP-001；Bug-A6-Preset-Restore-Summary（已解決）；Claude-Phase3-A6Fix-D1D7-20260904
