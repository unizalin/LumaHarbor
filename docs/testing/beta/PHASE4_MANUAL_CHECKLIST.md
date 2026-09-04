# LumaHarbor（Mac）Phase 4 手動驗測清單

涵蓋 Phase 4（Local Retouching：線性漸層、Spot Heal）在真實 Mac 視窗上的行為。這份清單只列自動化測試無法涵蓋的「畫面實際看起來／操作起來」項目——資料模型與 render 正確性已由 `swift test` 涵蓋（`LocalAdjustmentTests`/`LocalAdjustmentRendererTests`/`LinearGradientDragMathTests`/`LinearGradientOverlayContractTests`），詳見 `docs/coordination/CURRENT.md` 對應段落。跟 `PHASE3_MANUAL_CHECKLIST.md` 是不同的清單，因為驗測對象不同（Phase 4 是局部調整工具，只存在於 Mac app）。

這份清單目前只涵蓋 **Task 4.3（Mac linear gradient UI）** 的拖曳把手部分——roadmap 自己要求的「manual screenshot checklist for drag handles」。Spot heal（Task 4.4/4.5）完成後會補上對應章節；Phase 4 的完整驗證輪（含 focused tests/`swift test`/`git diff --check`/隱私掃描彙整）是 Task 4.6 的範圍，不在這份文件裡。

## 測試資訊

- Build：尚未建立（這份清單建立於 Task 4.3 完成時，尚未實際跑過任何一項）。
- 測試日期／時間：**NOT RUN**
- 測試者代號：**NOT RUN**
- Mac 型號／macOS 版本：**NOT RUN**

每一項只能填 `PASS`、`FAIL` 或 `NOT RUN`，並附必要備註。`NOT RUN` 不得視為通過。

## A. 線性漸層拖曳把手（Task 4.3）

| ID | 驗測項目 | 預期行為 | 結果 | 備註／證據 |
|---|---|---|---|---|
| A1 | 在 Inspector「Local Adjustments」區塊按「Add Gradient」 | 立即新增一個置中的漸層，自動選取，並自動切換進 `.linearGradient` 工具模式（畫面上出現拖曳把手） | NOT RUN | |
| A2 | 拖曳漸層的**位置把手**（中心點） | 把手跟著滑鼠移動，漸層的作用區域（用曝光效果目視確認亮暗變化）跟著移動；放開後位置固定 | NOT RUN | |
| A3 | 拖曳漸層的**方向／範圍把手**往右 | 漸層方向變成「往右變亮」（angle 0°），效果側在把手方向那一邊 | NOT RUN | |
| A4 | 拖曳方向／範圍把手往下 | 漸層方向變成「往下變亮」（angle 90°）——確認不是相反方向（往上變亮），這是 `LinearGradientDragMathTests` 已經用單元測試釘住的方向慣例，這裡是用真人眼睛再確認一次視覺上真的對 | NOT RUN | |
| A5 | 拖曳方向／範圍把手離錨點更遠 | 漸層的過渡帶（亮暗交界的模糊區）跟著變寬，效果更緩和；拖近則過渡帶變窄 | NOT RUN | |
| A6 | 在 Inspector 調整選取中漸層的「Exposure」滑桿 | 畫面即時反映局部曝光變化，且只影響漸層作用範圍內，範圍外的照片內容不受影響 | NOT RUN | |
| A7 | 按 Inspector 裡漸層列的刪除（垃圾桶）按鈕 | 該漸層立即從畫面與清單中消失，其他漸層（如果有）不受影響 | NOT RUN | |
| A8 | 關閉漸層列的「Enabled」開關 | 畫面上該漸層的視覺效果立即消失（曝光變化不再套用），但把手仍在（可以重新啟用），刪除按鈕與拖曳仍可操作 | NOT RUN | |
| A9 | 新增兩個漸層，分別拖曳 | 兩個把手各自獨立，拖曳其中一個不影響另一個的位置/方向/範圍；點擊任一把手可切換選取（用 Inspector 裡哪一列highlight 起來確認） | NOT RUN | |
| A10 | 按 Inspector 的「Done」離開編輯模式 | 把手從畫面上消失，回到一般的 `.adjust` 工具模式，但漸層本身（含已設定的效果）繼續保留、繼續套用在照片上 | NOT RUN | |
| A11 | 對含有漸層的照片按 ⌘Z（Undo） | 最近一次漸層編輯（新增／拖曳／刪除／曝光調整）被復原，符合一般 undo 行為 | NOT RUN | |
| A12 | 關閉照片再重新開啟（或重啟 App） | 漸層設定（位置/方向/範圍/曝光/啟用狀態）完整保留，畫面效果一致 | NOT RUN | |
| A13 | 匯出含漸層效果的照片 | 匯出檔案裡看得到局部曝光效果（跟預覽畫面一致），確認不是只有預覽套用、匯出漏掉 | NOT RUN | |

## B. 停止條件

下列任一情況發生時，停止把此 build 當作可上線候選並建立 bug：

- 拖曳方向把手往下卻讓效果往上跑（方向相反）。
- 刪除或停用一個漸層，卻影響到其他漸層的效果或位置。
- Undo/redo 讓 local adjustments 進入半套用或跟畫面顯示不一致的狀態。
- 重新開啟照片或 App 後漸層設定遺失或跑位。
- 匯出檔案沒有反映預覽畫面上看到的局部調整效果。
- App 閃退。
- 任何必要項目為 `FAIL` 或 `NOT RUN`。

## 整體結論

- 結果：**NOT RUN**（這份清單是在 Task 4.3 自動化實作完成時建立的，尚未有人在真實 Mac 上操作過）。
- 這輪的自動化證據（`swift build`、`swift test`、iOS generic build、`git diff --check`、隱私掃描）記在 `docs/coordination/CURRENT.md` 的「Phase 4 Task 4.3」段落，跟這份手動清單是分開的兩件事——自動化證據 PASS 不代表這份清單可以視為 PASS。
- 下一步：找時間在真實 Mac 上跑過這 13 項，或等 Task 4.4/4.5（spot heal）做完後一次補齊剩下的章節與 Task 4.6 的完整驗證輪。
