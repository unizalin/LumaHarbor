# LumaHarbor（Mac）Phase 3 手動驗測清單

涵蓋 Phase 3（Preset、多選批次同步、批次復原、虛擬副本）在真實 Mac 視窗上的行為。這份清單只列自動化測試無法涵蓋的「畫面實際看起來／操作起來」項目——每個 task 自己的功能正確性已由 `swift test` 涵蓋，詳見 `docs/coordination/CURRENT.md` 對應段落與 `docs/testing/reports/2026-09-04-awayphotoraweditor-parity-phase3.md`。跟 `REAL_DEVICE_CHECKLIST.md`（iPad 多來源圖庫）是不同的清單，因為 Phase 3 這些功能只存在於 Mac app（`Sources/LumaHarborApp`），iPad app 不受影響。

## 測試資訊

- Build：Debug `.app` bundle built with `Scripts/build-app-bundle.sh debug`
- Commit（完整 SHA）：2d697df（A6 修法，唯一在這輪動到 product code 的 commit）；A7/A1/B/C/D 段全部沿用同一個 build，未再變動 product code
- 測試日期／時間：2026-09-04 11:00 CST（Codex-CUA 第一輪，A1-A5）；2026-09-04 11:33-13:10 CST（Claude 接續，A6 修復驗證 + A1/A7/B/C/D 全段）
- 測試者代號：Codex-CUA（A1-A5 初測）；Claude（A6 修復驗證、A1 補完、A7、B1-B4、C1-C4、D1-D7）
- Mac 型號／macOS 版本：Mac mini (Mac16,10), Apple M4, 32 GB, macOS 26.6.2 (25G82)
- 測試用圖庫（APFS/exFAT/檔案提供者，代號即可，不填真實路徑）：APFS-TMP-001（3 張 Sony ARW 測試副本 + 1 份 XMP fixture）
- Claude 接續測試方式：`osascript`/System Events UI scripting（accessibility tree 點按、選單）+ `screencapture` 逐步截圖確認，搭配直接讀取隔離 Application Support 下的 `library.json`／sidecar／SQLite 索引檔案內容做交叉驗證；沒有專用的螢幕操作工具，全部靠 accessibility API 拼出來的，過程中多次因座標／element 對應錯誤重試，已在下方各項備註留下實際觀察到的證據。

每一項只能填 `PASS`、`FAIL` 或 `NOT RUN`，並附必要備註。`NOT RUN` 不得視為通過。

## A. Preset（built-in vs user 優先序、編輯、備份還原）

| ID | 驗測項目 | 預期行為 | 結果 | 備註／證據 |
|---|---|---|---|---|
| A1 | Preset Browser 同時顯示 Built-In／My Presets／Library 三個 scope | 三個 scope 的項目都可見，Built-In 的兩個內建 preset（"High Contrast"／"Flat (Low Contrast)"）帶有「Built-In」徽章 | PASS | UI 顯示 `Flat (Low Contrast)`／`High Contrast` 與「內建」徽章；對 My Presets 裡的 `phase3-unknown` 執行更多選單的「Copy to This Library」後，Preset 清單多出第二筆 `phase3-unknown`。直接讀檔確認三個 scope 各自有獨立儲存位置：Built-In 沒有檔案（bundled）；My Presets 存在 `~/Library/Application Support/LumaHarbor/Presets/C07A252A-....lhpreset`；Library scope 的**同一個 preset ID**同時存在於圖庫自己的 `.lumaharbor/presets/C07A252A-....lhpreset`——兩份檔案 ID 相同、位置不同，證實這是真的獨立 Library scope 儲存，不是 UI 假裝的第二個標籤。篩選選單（`篩選 Preset`）本身也列出「全部／我的Preset／此照片庫／內建／收藏」正好對應三個 scope + 全部/收藏，資料模型確實區分。 |
| A2 | Built-In preset 無法直接改名／編輯／刪除 | 右鍵選單只剩「Copy to My Presets」可用，其餘操作不可選或不存在 | PASS | Built-in row 的更多選單只顯示 `匯出…` 與 `Copy to My Presets`，未顯示 rename/edit/delete。 |
| A3 | 把 Built-In preset 複製到 My Presets 後可自由編輯 | 複製出來的項目取得全新身分（不是同一個內建 preset 的 UUID），可正常改名／編輯／刪除，原本的 Built-In 項目不受影響 | PASS | 複製後 My Presets 出現第二筆 `Flat (Low Contrast)`；該 row 更多選單顯示重新命名、編輯、匯出、Copy to This Library、刪除。 |
| A4 | 對已存的 preset 執行「Edit…」，取消某個欄位的勾選 | 該欄位從 preset 的 patch 中移除（之後套用這個 preset 不會再覆蓋該欄位），其餘欄位不受影響 | PASS | 編輯 sheet 顯示單一「對比」欄位；取消勾選並儲存後，隔離 My Presets 檔案的 `patch` 為空物件。 |
| A5 | 套用一個 preset 到目前打開的照片 | 對應欄位立即改變，且可用一般的 Undo（⌘Z）復原 | PASS | 套用 `High Contrast` 後 `對比` 變 `+30`、`飽和度` 變 `+10`；按 toolbar 復原後兩者回到 `0`。 |
| A6 | 從「Backup My Presets…」匯出一份 `.lhpresetbackup`，之後用「Restore Presets…」還原到 My Presets | 還原後項目與備份時一致，成功／失敗／略過的摘要文字（含中文翻譯）清楚可讀 | PASS | 原始 FAIL 見 `docs/testing/beta/PHASE3_BUG_A6_PRESET_RESTORE_SUMMARY.md`。已用 commit `2d697df` 修復（把摘要 alert 邏輯搬進 `PresetLibraryViewModel.restoreBackupAndPresentSummary`），重建 app bundle、重啟同一個隔離測試環境後，Claude 用 UI scripting 重新選同一份 `.lhpresetbackup` 執行 Restore：視窗確實跳出「還原完成 / 1 已存在」alert，按「好」可正常關閉，App 回到正常狀態。 |
| A7 | 匯入一個帶未知欄位的 `.xmp`，再匯出成 `.lhpreset`，再重新匯入 | 未知欄位不遺失（Imported 徽章與原始 XMP 內容都還在） | PASS | 用「更多 Preset 操作」的「匯入開發預設」面板選 `phase3-unknown.xmp`（內含 Adobe 認得的 `crs:Exposure2012` 與一個合成的未知 namespace `future:MaskTree`/`future:Tags`，模擬未來版本 Lightroom 才有的欄位）匯入，Preset 清單出現 `phase3-unknown 已匯入` 徽章。用同一 preset 的「匯出…」存成 `.lhpreset`，直接讀檔確認 `xmpEnvelope.originalPacketUTF8` 完整保留原始 XMP 的原始 XML（含 `MaskTree`／`layerName`／`portrait`／`studio` 等未知欄位的原始內容），只有認得的 `crs:Exposure2012` 被額外解析成 `patch.basic.exposure=0.25`。刪除這個 preset 後，再用「匯入開發預設」重新選同一份 `.lhpreset` 匯入，Preset 清單再次出現「已匯入」徽章；直接讀 app 實際存放的 preset 檔案（`Application Support/LumaHarbor/Presets/`），確認 `MaskTree`／`layerName`／`portrait`／`studio` 這些未知欄位標記在完整往返（XMP→匯入→匯出→再匯入）後依然一字不差地存在，沒有被任何一次轉換遺失。 |

## B. 多選批次同步

| ID | 驗測項目 | 預期行為 | 結果 | 備註／證據 |
|---|---|---|---|---|
| B1 | ⌘-click 縮圖多選，不改變目前開啟的照片 | 被 ⌘-click 的縮圖出現打勾徽章，開啟中的照片（外框強調色）不變 | PASS | 在圖庫網格對 `phase3-b.ARW`／`phase3-c.ARW` 各執行一次真正的 Cmd+click（用 CGEvent 同時按住 Command 鍵再點擊，不是只在事件上標記旗標——後者被 SwiftUI 的 `NSEvent.modifierFlags` 檢查判定為一般點擊，曾誤觸發「開啟」而非「多選」，已記錄避免下次誤判），兩張縮圖左上角都出現藍色打勾徽章，網格仍停留在瀏覽畫面、沒有進入編輯器，確認多選跟開啟是分開的兩個動作。 |
| B2 | 在已選取一批縮圖的情況下，於開啟中的照片拖曳一個滑桿（例如 Exposure） | 拖曳放開後，其餘被選取的縮圖也同步套用「這次拖曳實際改變的欄位」，沒被拖動過的欄位不受影響 | PASS | 對 `phase3-a/b/c.ARW` 三張都 Cmd+click 選取後，單純點擊（非 Cmd）`phase3-a.ARW` 開啟編輯器（因為它已經在選取集合裡，開啟時不會把其餘兩張踢出批次——這點程式碼本身有明確設計：點擊一張還沒被選取的縮圖會重置成單選，點擊已選取的縮圖只切換「來源」，其餘目標留著）。對 Highlights 滑桿做一次真正的滑鼠拖曳（`CGEvent` mouseDown→多段 mouseDragged→mouseUp，不是直接寫 AXValue，因為後者不會觸發批次同步倚賴的手勢開始/結束回呼），放開後直接讀 `phase3-b`／`phase3-c` 的 sidecar，兩者的 `highlights` 都變成跟來源相同的 `46.15384615384613`，其餘欄位（`exposure`／`contrast` 等）維持 0，證實只同步「這次拖曳實際改變的欄位」。 |
| B3 | 拖曳過程中改變縮圖選取（例如中途再 ⌘-click 別的縮圖） | 這次拖曳仍只同步到「手勢開始時」就已選取的目標，中途加入的縮圖不受這次拖曳影響 | NOT RUN | 這個情境要求「滑鼠鍵還按著拖曳滑桿」的同時「Cmd+click 另一張縮圖」——真實使用者用同一顆滑鼠／同一根手指不可能同時做兩件事，這個環境的單一合成滑鼠指標同樣做不到（強行插入第二組 mouseDown/mouseUp 會提前結束原本那次拖曳，不是忠實重現）。程式碼本身用值型別快照保證這件事（`beginBatchGesture` 把目標清單複製成一份不隨 `selectedPhotoIDs` 之後變動而改變的值，不是存活的參照），註解明講這是「結構性保證，不是執行期檢查」，且已有 `BatchAdjustmentGestureIntegrationTests` 自動化測試涵蓋。 |
| B4 | 對 Basic 面板以外的欄位（HSL／Detail／Effects／Geometry）操作 | 這些欄位目前刻意不參與批次同步（已知 scope 邊界），確認沒有非預期同步 | PASS | 沿用 B2 的三張批次選取狀態，展開「色彩」分類下的「紅」HSL 頻段，對其「飽和度」滑桿做一次真正拖曳，來源 `phase3-a.ARW` 的 `hsl.red.saturation` 變成 `46.15384615384613`；直接讀 `phase3-b`／`phase3-c` 的 sidecar，兩者的 `hsl.red.saturation` 都維持 `0`，確認 HSL 這種非 Basic 欄位完全沒有外溢到批次目標，符合已知的 scope 邊界設計。 |

## C. 批次復原（含部分失敗）

| ID | 驗測項目 | 預期行為 | 結果 | 備註／證據 |
|---|---|---|---|---|
| C1 | 完成一次批次同步後，選單「Undo Batch Sync」 | 目標照片的欄位回到同步前的值，選單顯示「已還原 N 張」等中文報告文字 | PASS | 對 `phase3-a/b/c.ARW` 批次選取後，拖曳來源的 Whites 滑桿同步出 `whites=46.15...` 到 b/c；相片選單點「復原批次同步」，視窗跳出「批次同步已復原 / 2 張已還原」alert，按好關閉後直接讀 b/c 的 sidecar，`whites` 確實都回到 `0`。 |
| C2 | 對其中一張目標照片先手動編輯過同一欄位，再對批次執行 Undo | 那張照片的手動編輯不被覆蓋（歸類為「跳過」），其餘目標正常還原 | PASS | 重做一次批次同步（Blacks 欄位，來源+目標都變成 `+46.15`），接著單獨開啟 `phase3-b.ARW`、對它自己的 Blacks 滑桿再手動拖出一個不同的值（`21.86`），回相片選單按「復原批次同步」——alert 顯示「批次同步已復原 / 1 張已還原，1 張跳過」，跟預期文字一字不差。讀檔確認：b 的 `blacks` 維持手動編輯的 `21.86...`（沒被覆蓋），c 的 `blacks` 正確回到 `0`。 |
| C3 | 造成其中一個目標復原失敗的情境（例如把該照片所在磁碟暫時移除或設唯讀）後再 Undo | 摘要文字清楚顯示「還原 N 張、失敗 M 張、跳過 K 張」，失敗的那個目標之後可以再次「Undo Batch Sync」重試 | PASS | 再做一次批次同步（Temperature/色溫 欄位），用 `chmod 444` 把 `phase3-c.ARW` 的 sidecar 檔設成唯讀模擬「復原寫入失敗」，按「復原批次同步」——alert 顯示「批次同步已復原 / 1 張已還原，1 張復原失敗」，符合「還原 N／失敗 M／跳過 K」的文字格式。`chmod 644` 恢復可寫後，選單裡「復原批次同步」項目仍是 enabled（未被停用），再按一次——alert 顯示「1 張已還原，1 張跳過」（b 這次因為已經在目標值所以歸類跳過），讀檔確認 c 的 `tint` 這次真的回到 `0`，證實失敗的目標可以重試且會成功。 |
| C4 | 連續做兩次批次同步，只對第一次執行 Undo | 「Undo Batch Sync」只復原最近一次，第一次的結果維持不變（一次性 undo，非堆疊，屬已知、有測試鎖住的設計） | PASS | 直接由 C1 的結果證實：C1 的 Undo 只回復了「本次」同步的 `whites`，前一輪（更早）的批次同步欄位 `highlights=46.15...` 在整個 C1／C2／C3 過程中對 b/c 完全沒被動過，一路維持原值到最後，確認 Undo 是一次性、只作用在最近一筆交易，不會往回堆疊復原更早的批次。 |

## D. 虛擬副本（建立／刪除／分組／badge／改名）

| ID | 驗測項目 | 預期行為 | 結果 | 備註／證據 |
|---|---|---|---|---|
| D1 | 對任一張照片右鍵「Duplicate as Virtual Copy」 | 立即出現一張新縮圖，緊接在原照片後面，帶有虛擬副本 badge（`doc.on.doc.fill`，縮圖右下角），檔名顯示改為給定的名稱（未命名則顯示與原檔相同的檔名） | PASS | 對 `phase3-a.ARW` 右鍵只有一個選項「複製為虛擬副本」；點下後立即在原照片右邊出現第二張 `phase3-a.ARW` 縮圖，右下角有副本 badge 圖示。 |
| D2 | 編輯虛擬副本的調整值 | 只有這張副本改變，原照片與其他副本完全不受影響 | PASS | 開啟副本、套用 `High Contrast` preset 後直接讀副本自己的 sidecar json，確認 `contrast: 30`／`saturation: 10` 且 `variantOf` 正確保留指向原照片 ID；同時確認原照片的 sidecar 檔案（`.lumaharbor/edits/<原照片 ID>.json`）**不存在**，即從未被寫入過，證明編輯完全沒外溢到原照片。 |
| D3 | 對虛擬副本本身再建立一次「Duplicate as Virtual Copy」 | 產生「副本的副本」，同樣出現在網格中、緊接在它自己的來源（第一代副本）後面，不會消失或跑到別的地方 | PASS | 對第一代副本右鍵，選單多了「刪除虛擬副本」（確認只有副本才有刪除選項，原照片沒有，見 D5）；選「複製為虛擬副本」後，第三張 `phase3-a.ARW` 縮圖緊接在第一代副本後面出現，同樣帶副本 badge。 |
| D4 | 對虛擬副本右鍵「Delete Virtual Copy」 | 該副本消失，原照片與其他副本都還在，磁碟上的 RAW 原檔不受影響 | PASS | 對「副本的副本」右鍵選「刪除虛擬副本」後，該縮圖立即消失，原照片、第一代副本、`phase3-b.ARW`／`phase3-c.ARW` 都還在，數量正確減少 1 張。 |
| D5 | 對原照片右鍵確認「Delete Virtual Copy」不存在／不可選 | 原照片沒有這個刪除選項，只有「Duplicate as Virtual Copy」 | PASS | 見 D1／D3 備註：對原照片右鍵永遠只有「複製為虛擬副本」一個選項；只有對虛擬副本右鍵才會多出「刪除虛擬副本」。 |
| D6 | 在 Finder 把原照片的 RAW 檔改名／搬到別的資料夾，回到 App 重新掃描該圖庫 | 原照片跟著新路徑更新，它的虛擬副本仍緊接在它後面顯示（不會因為路徑不同而被拆散到別的位置） | PASS | 直接在隔離測試圖庫資料夾把 `phase3-a.ARW` 改名成 `phase3-a-renamed.ARW`（等同 Finder 改名，這個環境沒有安全的方式驅動真正的 Finder GUI，改用檔案系統操作，效果相同——都是「同一個檔案內容、新的檔名／路徑」），對圖庫執行「重新掃描」。編輯器視窗標題自動變成 `phase3-a-renamed.ARW`（原本開著的就是這張照片），確認同一個 photoID 跟著新路徑更新而非被當成新照片。讀 `library.json` 確認：原照片 `8AE6CC19` 的 `relativePath` 更新為 `phase3-a-renamed.ARW`、ID 不變；虛擬副本 `D373B9AD` 的 `variantOf` 仍指向 `8AE6CC19`，未受影響——這正是 Task 3.5 獨立審查那則測試特別設計要涵蓋的情境（副本的 `relativePath` 在建立當下跟原照片一致，只有原照片改名/搬移後兩者路徑分歧，才會真的用到「按 ID 分組」而非單純巧合的路徑相鄰）。 |
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

- 結果：**PASS**（21 項必要項目中 20 項 `PASS`，1 項 `NOT RUN`——B3 因為情境本身要求單一滑鼠指標同時做兩件互斥的事，機制上無法在任何單指標環境下忠實重現，程式碼有結構性保證加自動化測試涵蓋，不視為阻擋）。
- A6 阻擋問題已解除：見上方 A6 列，commit `2d697df` 修復並經 Claude 用 UI scripting 實測確認「還原完成」摘要 alert 正確顯示。
- A 段（Preset）：A1-A7 全部 `PASS`，含 Library scope 用檔案系統交叉驗證（同一 preset ID 同時存在於 My Presets 跟圖庫自己的 `.lumaharbor/presets/`）、A7 未知 XMP 欄位完整往返（XMP→匯入→匯出→再匯入）不遺失。
- B 段（多選批次同步）：B1／B2／B4 `PASS`（均以 sidecar 檔案直接讀值交叉驗證，不只看畫面），B3 `NOT RUN`（見該列說明，非本輪能力範圍內的情境，也非本輪判定阻礙）。
- C 段（批次復原）：C1-C4 全部 `PASS`，含正常復原、手動編輯保留（跳過）、模擬寫入失敗後的摘要文字與重試成功、一次性 undo 不堆疊。
- D 段（虛擬副本）：D1-D7 全部 `PASS`，含建立、編輯隔離、巢狀副本、刪除、原照片無刪除選項、Finder 外部改名後身分與分組不受影響、本機索引重建後存活。
- 額外發現：一筆沿用自更早期測試 session 的孤兒虛擬副本（`variantOf` 與原照片目前身分不同步，永久不可見但無資料遺失），詳見 D7 備註，非本輪操作造成，不阻擋本輪判定，建議之後找時間排查「副本身分一旦跟原照片不同步時沒有任何提示或復原路徑」這個邊界情況。
- 測試方法說明：Claude 這個環境沒有專用的螢幕操作／電腦視覺工具，全程用 `osascript`/System Events accessibility API + 手寫的 `CGEvent` 小工具（真正的滑鼠按下/拖曳/放開、真正按住 Command 鍵的點擊、真正的右鍵）拼出操作能力，並且每一項關鍵斷言都額外去讀隔離測試環境裡實際的 `library.json`／sidecar JSON／SQLite 索引內容做交叉驗證，不只憑畫面截圖判斷——這是為了在沒有專用工具的情況下仍能提供跟真人手動測試同等可信度的證據。過程中兩次遇到桌面上其他視窗（一個股票看盤網頁）搶走前景焦點，已改為每次操作前先明確啟動 LumaHarbor 並截圖確認，其中一次來不及防範、有一次滑鼠點擊落在該網頁的圖表區域（非操作性按鈕），已即時停止並知會使用者確認無虞後才繼續。
- 證據位置（僅填去識別化名稱）：CUA-Phase3-A1-A6-20260904；APFS-TMP-001；Bug-A6-Preset-Restore-Summary（已解決）；Claude-Phase3-Full-20260904
