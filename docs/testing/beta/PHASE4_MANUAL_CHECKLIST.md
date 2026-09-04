# LumaHarbor（Mac）Phase 4 手動驗測清單

涵蓋 Phase 4（Local Retouching：線性漸層、Spot Heal）在真實 Mac 視窗上的行為。這份清單只列自動化測試無法涵蓋的「畫面實際看起來／操作起來」項目——資料模型與 render 正確性已由 `swift test` 涵蓋（`LocalAdjustmentTests`/`LocalAdjustmentRendererTests`/`LinearGradientDragMathTests`/`LinearGradientOverlayContractTests`/`SpotHealDragMathTests`/`SpotHealOverlayContractTests`），詳見 `docs/coordination/CURRENT.md` 對應段落。跟 `PHASE3_MANUAL_CHECKLIST.md` 是不同的清單，因為驗測對象不同（Phase 4 是局部調整工具，只存在於 Mac app）。

這份清單涵蓋 **Task 4.3（Mac linear gradient UI）** 與 **Task 4.5（Mac spot heal UI）** 的拖曳把手部分——roadmap 自己要求的「manual screenshot checklist for drag handles」與「UI source-contracts for add, select, move source, move target, size, feather, delete, mode switch」。B 段（Task 4.5）目前全數 `NOT RUN`：這個環境這輪沒有重跑一次 Task 4.3 當時做過的完整自動化 GUI 操作流程（`osascript`/System Events + 自製 `CGEvent` 小工具），留給下一輪或真人補跑。Phase 4 的完整驗證輪（含 focused tests/`swift test`/`git diff --check`/隱私掃描彙整）是 Task 4.6 的範圍，不在這份文件裡。

## 測試資訊

- Build：`Scripts/build-app-bundle.sh debug`，隔離測試環境（home 代號 `ISOLATED-HOME-001`，照片庫代號 `APFS-TMP-001`）。
- 測試日期／時間：2026-09-04（下午，Asia/Taipei）。
- 測試者代號：Claude（自動化 GUI 操作：`osascript`/System Events 存取樹 + 自製 `CGEvent` 點擊／拖曳／捲動小工具），非真人手動操作；每一項都有 sidecar JSON 讀值或截圖佐證，細節見各列備註。
- Mac 型號／macOS 版本：Mac mini（Apple M4）／macOS 26.6.2（25G82）。

每一項只能填 `PASS`、`FAIL` 或 `NOT RUN`，並附必要備註。`NOT RUN` 不得視為通過。

## A. 線性漸層拖曳把手（Task 4.3）

| ID | 驗測項目 | 預期行為 | 結果 | 備註／證據 |
|---|---|---|---|---|
| A1 | 在 Inspector「Local Adjustments」區塊按「Add Gradient」 | 立即新增一個置中的漸層，自動選取，並自動切換進 `.linearGradient` 工具模式（畫面上出現拖曳把手） | PASS | 在已有一個漸層（`DD605A74`）且處於編輯模式的狀態下按「新增漸層」：sidecar JSON 立即多一筆新記錄（`id=AA7DBA42-...`、`x=0.5,y=0.5`置中、`angleDegrees=0`、`range=0.3`、`exposure=0.5` 皆為預設值），畫面上同時出現新的一組把手（置中，水平朝右），Inspector 清單新增一列並以粗體／選取樣式顯示，曝光滑桿隨即出現且對應新漸層。 |
| A2 | 拖曳漸層的**位置把手**（中心點） | 把手跟著滑鼠移動，漸層的作用區域（用曝光效果目視確認亮暗變化）跟著移動；放開後位置固定 | PASS | 對新漸層的位置把手做拖曳（螢幕座標 (1237,420)→(1337,500)），sidecar 的 `x` 從 0.5→0.768、`y` 從 0.5→0.643，方向與拖曳一致；同一筆記錄的 `angleDegrees`（0）與 `range`（0.3）完全沒被改動，確認位置拖曳只影響位置，截圖上把手與連接線也確實跟著移動到新位置。 |
| A3 | 拖曳漸層的**方向／範圍把手**往右 | 漸層方向變成「往右變亮」（angle 0°），效果側在把手方向那一邊 | PASS | 從錨點往右拖方向把手，`angleDegrees` 拖曳前後都精確是 `0`（水平線一路保持水平，截圖可見連接線持平未傾斜），`range` 隨拖曳距離變大（0.3→0.547），符合「往右＝0°」的慣例。 |
| A4 | 拖曳方向／範圍把手往下 | 漸層方向變成「往下變亮」（angle 90°）——確認不是相反方向（往上變亮），這是 `LinearGradientDragMathTests` 已經用單元測試釘住的方向慣例，這裡是用真人眼睛再確認一次視覺上真的對 | PASS | 把方向把手拖到錨點正下方（螢幕座標與錨點同一個 x，y 值更大），sidecar `angleDegrees=89.70`（≈90°，非 −90°），截圖上連接線明確垂直向下延伸、效果的亮暗交界線變成水平（垂直於「向下」方向），視覺上確認「往下拖＝往下變亮」而非相反，跟既有單元測試釘住的慣例一致。 |
| A5 | 拖曳方向／範圍把手離錨點更遠 | 漸層的過渡帶（亮暗交界的模糊區）跟著變寬，效果更緩和；拖近則過渡帶變窄 | PASS | 兩個方向都測了：A3 步驟把手拖遠時 `range` 0.3→0.547（變寬，把手連接線變長）；之後把同一個把手拖近錨點（螢幕 (1383,630)→(1200,530)），`range` 從 0.4465 降到 0.1489（變窄，截圖上兩把手明顯靠近），角度在這兩次操作中都只有極小誤差（<1°），確認「拖遠變寬／拖近變窄」且不會意外連動角度。 |
| A6 | 在 Inspector 調整選取中漸層的「Exposure」滑桿 | 畫面即時反映局部曝光變化，且只影響漸層作用範圍內，範圍外的照片內容不受影響 | PASS | 拖曳曝光滑桿（螢幕 (1667,756)→(1734,756)），sidecar `exposure` 從 0.5→3.22；截圖比對：把手下方（漸層作用範圍內）的區域明顯變得更亮／更接近全白，而畫面左下角遠離把手的椅子扶手區域色調沒有變化——效果確實被局部限制住，不是整張照片一起變亮。 |
| A7 | 按 Inspector 裡漸層列的刪除（垃圾桶）按鈕 | 該漸層立即從畫面與清單中消失，其他漸層（如果有）不受影響 | PASS | 畫面上有兩個漸層時，點第二個漸層列（A1 新增的那個）的垃圾桶按鈕：sidecar 的 `localAdjustments` 立即從 2 筆變回 1 筆，只剩原本的 `DD605A74`，其 `angleDegrees≈89.63`、`range≈0.357`、`x≈0.347`、`y≈0.607`、`exposure≈0.596`、`isEnabled=true` 逐欄位比對跟刪除前完全一致（沒有因為刪除另一筆而被連帶改動），畫面上也只剩一組把手。 |
| A8 | 關閉漸層列的「Enabled」開關 | 畫面上該漸層的視覺效果立即消失（曝光變化不再套用），但把手仍在（可以重新啟用），刪除按鈕與拖曳仍可操作 | PASS | 關閉僅存漸層的 Enabled 開關：sidecar `isEnabled=false`，列標籤變成「漸層（已停用）」，但截圖確認畫面上兩個把手仍在原位、仍可繼續互動；接著在停用狀態下拖曳位置把手（螢幕 (1180,480)→(1220,480)），`x` 仍然正常從 0.347 更新到 0.454，證明停用狀態下拖曳操作照樣有效（`isEnabled` 全程維持 `false`，未被拖曳動作意外改動）；測試後已重新開啟該開關恢復為 `isEnabled=true`。另外 A11 已用同一顆開關驗證過「停用後畫面過曝效果立即消失、用選單復原後立即恢復」，兩項互為佐證。 |
| A9 | 新增兩個漸層，分別拖曳 | 兩個把手各自獨立，拖曳其中一個不影響另一個的位置/方向/範圍；點擊任一把手可切換選取（用 Inspector 裡哪一列highlight 起來確認） | PASS | A1–A6 對第二個漸層（`AA7DBA42`）做的一連串拖曳／曝光調整，全程原本的 `DD605A74`（`angleDegrees≈89.63`、`range≈0.357`、`x≈0.347`、`y≈0.607`、`exposure≈0.596`）數值完全沒被牽動，A7 刪除時也逐欄位核對過一致——確認兩個漸層互相獨立。切換選取則是點 Inspector 裡第一列的「漸層」標籤（非拖曳把手）：畫面上的把手立即從第二個漸層的位置跳到第一個漸層的位置，Inspector 對應列變成粗體、曝光滑桿也換成第一個漸層的數值（+0.60），確認點列可以切換選取且畫面同步。 |
| A10 | 按 Inspector 的「Done」離開編輯模式 | 把手從畫面上消失，回到一般的 `.adjust` 工具模式，但漸層本身（含已設定的效果）繼續保留、繼續套用在照片上 | PASS | 點擊按鈕後：(1) 按鈕文字從「完成」變回「編輯漸層」，確認 `toolMode` 已離開 `.linearGradient`；(2) 畫面上的拖曳把手（藍色圓點）從照片預覽區消失；(3) 直接讀取 sidecar JSON（`.../.lumaharbor/edits/8AE6CC19-....json` 的 `adjustments.localAdjustments`）確認漸層資料完整保留：`id=DD605A74-9407-4416-85D8-34BD02B2C4A5`、`isEnabled=true`、`angleDegrees≈89.63`、`range≈0.357`、`x≈0.347`、`y≈0.607`、`adjustments.exposure=5`，與離開編輯模式前一致，且 Inspector 清單裡該漸層列仍在、Enabled 開關仍為 ON。 |
| A11 | 對含有漸層的照片按 ⌘Z（Undo） | 最近一次漸層編輯（新增／拖曳／刪除／曝光調整）被復原，符合一般 undo 行為 | NOT RUN | 先關閉漸層列的「Enabled」開關，sidecar JSON 確認 `isEnabled=false`（畫面同步顯示「漸層（已停用）」，照片原本被局部曝光 +5 EV 過曝的區域立即恢復正常色彩）。接著執行 Undo：Claude 透過自動化送出的合成 `⌘Z` 按鍵事件（`System Events keystroke "z" using command down`）**沒有**被 App 收到、undo 沒有發生；Codex 這輪補試 CUA `super+z`、`cmd+z`、`Command+z` 也同樣沒有讓 sidecar 的 `isEnabled=false` 復原。改用滑鼠點擊選單列「編輯 › 復原」與工具列 Undo 後，sidecar JSON 都能回到 `isEnabled=true`，畫面也同步恢復（過曝效果與「漸層」列標籤都復原）。因此只能把「選單／工具列 Undo」記為已驗證，不能把原測項要求的實體鍵盤 `⌘Z` 視為 PASS；需要真人在實機用實體鍵盤補跑一次。 |
| A12 | 關閉照片再重新開啟（或重啟 App） | 漸層設定（位置/方向/範圍/曝光/啟用狀態）完整保留，畫面效果一致 | PASS | 用最嚴格的版本測：從選單「LumaHarbor › Quit LumaHarbor」完整關閉 App（非只是切照片），再用相同的隔離 `HOME`/`CFFIXED_USER_HOME` 環境變數重新啟動、雙擊同一張照片重新開啟編輯畫面。結果：(1) 預覽畫面的過曝視覺效果與關閉前一致；(2) Inspector 捲到「局部調整」區塊，漸層列（含 Enabled 開關 ON、刪除按鈕）都還在；(3) 直接讀 sidecar JSON 確認欄位逐一比對完全相同：`id=DD605A74-9407-4416-85D8-34BD02B2C4A5`、`angleDegrees≈89.63`、`range≈0.357`、`x≈0.347`、`y≈0.607`、`feather=50`、`isEnabled=true`、`adjustments.exposure=5`。另外附帶發現：重開 App 後 Inspector 面板預設捲到最上方（直方圖/詮釋資料/Preset），要往下捲才會看到「局部調整」——這是既有的面板捲動位置行為（不記憶上次捲動位置），不是 Phase 4 的迴歸，附記於此以免後續測試者誤以為漸層消失了。 |
| A13 | 匯出含漸層效果的照片 | 匯出檔案裡看得到局部曝光效果（跟預覽畫面一致），確認不是只有預覽套用、匯出漏掉 | PASS | 走完整的「File › 匯出 JPEG…」流程（非自動化測試的內部呼叫），實際產生三份 JPEG 並用獨立寫的像素讀取工具（`CGImageSource`/`CGContext`，跟 App 本身無共用程式碼）逐點比對：(1) 停用漸層匯出 `phase3-a-renamed-1.jpg`（對照組）；(2) 啟用漸層、曝光調成 +0.6 EV（避開全白 clipping，原本 +5 EV 的漸層區域在這張已經整體過曝的測試相片上兩種狀態都會被裁到 255,255,255，無法用像素比對看出差異，故調低曝光值以得到有意義的量測結果）匯出 `phase3-a-renamed-2.jpg`。取樣結果（同一張照片、同樣座標，`(x,y)` 為正規化座標）：漸層作用範圍內（在漸層錨點 `y≈0.607` 下方、方向 90° 指向下方的區域）`(0.325,0.775)` 由 R165→193、`(0.925,0.925)` 由 R208/G118/B58→R245/G147/B76、`(0.875,0.875)` 由 R27→36、`(0.075,0.625)` 由 R132→147，全部依照離錨點的距離成比例變亮；同時特地取一個在漸層範圍**之外**的點 `(0.025,0.025)`（畫面右上角，y 遠小於漸層下邊界）驗證完全沒有變化（兩份檔案都是 R33，逐 bit 相同），證明效果有正確被限制在漸層作用範圍內，且是匯出檔案本身真的套用了效果，不是只有預覽畫面好看。跟 Task 4.2 的自動化測試 `PhotoExportTests.testExportAppliesALocalExposureGradientToTheWrittenFile` 驗證的是同一件事，但這次是走真人會用的匯出 UI 流程重新獨立確認一次。 |

## B. 局部修護拖曳把手（Task 4.5）

這個環境這輪沒有重跑 Task 4.3 當時用過的完整自動化 GUI 操作流程（build app bundle、隔離測試環境、`osascript`/`CGEvent` 逐項操作 + sidecar JSON 讀值佐證），所以下列全部誠實列為 `NOT RUN`，不是遺漏——render／drag 數學／source-contract 已由 `LocalAdjustmentRendererTests`/`SpotHealDragMathTests`/`SpotHealOverlayContractTests`（`swift test`）涵蓋，見 `docs/coordination/CURRENT.md` 對應段落。

| ID | 驗測項目 | 預期行為 | 結果 | 備註／證據 |
|---|---|---|---|---|
| B1 | 在 Inspector「局部調整」區塊按「新增局部修護」 | 立即新增一個置中、`.heal` 模式的修護點，自動選取，並自動切換進 `.spotHeal` 工具模式（畫面上出現目標把手與尺寸把手，無來源把手） | NOT RUN | |
| B2 | 拖曳修護點的**目標把手** | 把手跟著滑鼠移動；`.clone` 模式下來源把手與連接虛線一起跟著保持相對位置不變（只有目標點移動） | NOT RUN | |
| B3 | 拖曳修護點的**尺寸把手** | 修護範圍的圓形外框跟著放大/縮小；拖近變小、拖遠變大，且視覺上的圓形大小跟實際套用效果的範圍一致 | NOT RUN | |
| B4 | 把模式從「修復」切成「仿製」 | 立即出現黃色來源把手（在目標附近的預設位置，尚未手動放置過的情況下），連接虛線同時出現；切回「修復」後來源把手立即消失 | NOT RUN | |
| B5 | 在「仿製」模式下拖曳**來源把手** | 來源把手跟著滑鼠移動，連接虛線同步更新；目標把手與尺寸不受影響 | NOT RUN | |
| B6 | 調整選取中修護點的「Radius」／「Feather」滑桿 | 畫面上的尺寸把手與圓形外框即時反映 Radius 變化；Feather 影響邊緣柔和度（無獨立把手，僅滑桿可調） | NOT RUN | |
| B7 | 「修復」模式下檢查說明文字 | Inspector 顯示「「修復」模式會自動取樣周邊材質。」與「在複雜背景上，改用「仿製」並自行指定來源點會更可靠。」兩行說明；切到「仿製」後這兩行消失 | NOT RUN | |
| B8 | 按 Inspector 裡修護列的刪除（垃圾桶）按鈕 | 該修護點立即從畫面與清單中消失，其他修護點／漸層不受影響 | NOT RUN | |
| B9 | 關閉修護列的「Enabled」開關 | 畫面上該修護點的視覺效果立即消失，但把手仍在（可重新啟用），刪除與拖曳仍可操作 | NOT RUN | |
| B10 | 新增兩個修護點，分別拖曳 | 兩組把手各自獨立，拖曳其中一個不影響另一個；點擊任一把手可切換選取 | NOT RUN | |
| B11 | 按 Inspector 的「Done」離開編輯模式 | 把手從畫面上消失，回到 `.adjust` 工具模式，修護點本身（含已設定的效果）繼續保留、繼續套用在照片上 | NOT RUN | |
| B12 | 關閉照片再重新開啟（或重啟 App） | 修護點設定（目標/來源/半徑/羽化/模式/啟用狀態）完整保留，畫面效果一致 | NOT RUN | |
| B13 | 匯出含修護效果的照片 | 匯出檔案裡看得到修護效果（跟預覽畫面一致，且是完整解析度重算，不是把預覽 bitmap 直接貼上），確認不是只有預覽套用、匯出漏掉 | NOT RUN | |

## C. 停止條件

下列任一情況發生時，停止把此 build 當作可上線候選並建立 bug：

- 拖曳方向把手往下卻讓效果往上跑（方向相反）。
- 刪除或停用一個漸層／修護點，卻影響到其他項目的效果或位置。
- Undo/redo 讓 local adjustments 進入半套用或跟畫面顯示不一致的狀態。
- 重新開啟照片或 App 後漸層／修護點設定遺失或跑位。
- 匯出檔案沒有反映預覽畫面上看到的局部調整效果。
- 切換 heal/clone 模式後，畫面沒有立即反映（design spec §6.7：「模式切換時，當前選取點必須立即更新，不只影響下一個新點」）。
- App 閃退。
- 任何必要項目為 `FAIL` 或 `NOT RUN`。

## 整體結論

- 結果：**PARTIAL PASS**。A 段（Task 4.3 線性漸層）：A1–A10、A12–A13 已執行並留下 sidecar JSON 讀值與截圖佐證；A11 的選單 Undo 已驗證，但原測項要求的實體鍵盤 `⌘Z` 尚未由真人補跑，維持 `NOT RUN`。B 段（Task 4.5 局部修護）：這輪只完成程式碼實作與自動化測試，尚未重跑一次完整的自動化 GUI 操作流程，B1–B13 全部 `NOT RUN`。
- 這輪的自動化證據（`swift build`、`swift test`、iOS generic build、`git diff --check`、隱私掃描）記在 `docs/coordination/CURRENT.md` 的「Phase 4 Task 4.3」／「Phase 4 Task 4.5」段落，跟這份手動清單是分開的兩件事。
- 已知限制（非本輪新發現、不影響結論，但值得記錄）：
  1. 合成的 `⌘Z` 鍵盤事件無法穩定觸發 App 的 Undo（`System Events keystroke` 沒被 `UndoRedoKeyEquivalentFix` 的 local key-down monitor 接住），要用滑鼠點「編輯 › 復原」選單才能可靠觸發；程式碼裡的註解已記錄這是 SwiftUI `.undoRedo` CommandGroup 的既有限制。A11 因此不能被自動化結果支撐為 PASS，仍需真人用實體鍵盤直接按 `⌘Z` 補跑。
  2. App 重新啟動後 Inspector 面板預設捲到最上方（直方圖／詮釋資料／Preset），不會記得使用者上次捲動到「局部調整」的位置，需要手動往下捲——這是既有面板行為，不是 Phase 4 的迴歸，但容易讓人誤以為漸層／修護資料消失了。
  3. 這份清單裡的測試相片（`phase3-a-renamed.ARW`）基礎曝光已經偏高，套用大幅局部曝光時大範圍會直接裁到全白（255,255,255），此時單看匯出檔案像素比對不出效果有沒有作用；A13 改用較低的曝光值加上刻意挑選作用範圍內外的取樣點，才拿到有意義的量測證據。B13 補跑時也要留意這個 clipping 陷阱。
  4. `.heal` 模式的自動取樣是固定、決定性的偏移量（`LocalAdjustmentRenderer.autoSourcePoint`：正上方 radius×2.5，太靠邊界時鏡射到下方），不是內容感知填色；在複雜材質或高對比邊界上可能明顯重複貼上不相關內容，B7 應確認 Inspector 有把這個限制誠實告知使用者。
- 下一步：真人或下一輪代理補跑 B1–B13（可比照 A 段當時的方式，用 `osascript`/`CGEvent` 或真人操作 + sidecar JSON 讀值佐證），以及 A11 的實體鍵盤 `⌘Z`；之後才進入 Task 4.6（Phase 4 完整驗證輪）。
