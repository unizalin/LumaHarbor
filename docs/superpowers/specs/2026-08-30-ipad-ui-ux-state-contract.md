# LumaHarbor iPad UI/UX 狀態契約

日期：2026-08-30
狀態：實機使用後補強 spec，接在 iPad 多來源 RAW 圖庫 Task 8 之後

## 1. 目的

iPad 版已具備多來源 RAW 圖庫的主要功能，但實機使用時仍會遇到「點了像沒反應」、「等待時不知道 App 在做什麼」、「權限或唯讀限制不夠直白」這類問題。本文件把使用者會觸發的長時間或高風險操作整理成一致狀態契約，後續修正不得只補單點 spinner。

## 2. 全域規則

1. 任何可能超過一個 render pass 的操作，都必須有可見文字，不只是一個無標籤 spinner。
2. 涉及外接磁碟、Files provider、security-scoped bookmark 或 RAW 解碼的操作，失敗時必須說明「發生什麼、哪些資料沒有被修改、下一步」。
3. RAW 原檔永遠不可被修改。所有移除、重新掃描、重新連接與編輯流程的文案都不得暗示 RAW 會被搬移、覆蓋或刪除。
4. `readOnly`、`offline`、`needsAuthorization` 必須是三種不同的使用者理解狀態，不得混成同一個錯誤。
5. 不把私人絕對路徑、Team ID、完整掛載點或 provider 內部錯誤直接顯示給使用者。

## 3. 功能狀態矩陣

| 操作 | 觸發點 | 等待狀態 | 成功狀態 | 失敗狀態 | RAW 安全文案 |
|---|---|---|---|---|---|
| 加入來源 | 空狀態、側欄加號 | `Adding source…`，接著 `Scanning source…` | 來源出現在側欄，照片逐批出現 | 無法加入、重疊來源、權限不足 | 必須說明只讀原位置 RAW，不搬移、不修改 |
| 掃描來源 | 來源 context menu | `Scanning source…` | 最新索引出現在目前 scope | partial failure 可重試，不 prune | 必須說明掃描不修改 RAW |
| 重新連接來源 | 離線／需要存取權來源 | `Reconnecting source…` | 原來源恢復 online，不產生副本 | 身份不符、權限不足、provider 失敗 | 必須說明不依名稱或路徑誤接來源 |
| 移除來源 | swipe/context menu destructive action | `Removing source…` | 來源從 App 清單消失 | 移除失敗時不宣稱成功 | 必須說明 RAW 檔案留在原位 |
| 開啟照片 | 點縮圖 | `Preparing photo…`，進 editor 後 `Decoding RAW…` | editor 顯示可編輯照片 | 離線、唯讀儲存限制、權限不足、不可解碼 | 必須說明開啟不修改 RAW |
| 下一頁載入 | 捲動接近底部 | `Loading more photos…` | 新 page 追加，不跳位 | 保留已載入結果並提示可重試 | 不需要額外 RAW 文案 |
| 搜尋／排序／切 scope | toolbar、側欄 | 快速時可保留舊結果；慢時要有 query loading | 新查詢結果穩定顯示 | 保留可理解錯誤，不混入舊 cursor | 不需要額外 RAW 文案 |

## 4. 目前已完成

- 加入來源後已有可見等待 overlay。
- 掃描中會讓 overlay 維持顯示，但目前文案仍需區分「加入」與「掃描」。
- 開啟照片已有 `Preparing photo…`，並保留最短可見時間，避免閃一下等於沒看到。
- 下一頁載入已有 `Loading more photos…`。
- 移除來源已有確認視窗，並已補上 `Removing source…` 與 RAW 不刪除文案。

## 5. 尚缺或需要重驗

1. 掃描中的全域 overlay 不應永遠顯示 `Adding source…`；手動重新掃描時應顯示 `Scanning source…`。
2. 重新連接來源缺少明確等待狀態與身份驗證中的文案。
3. 來源列尚未明確顯示 per-source scan 狀態與 partial failure summary。
4. 搜尋／排序／切 scope 的慢查詢狀態需要實機確認是否會像卡住。
5. 唯讀來源可開啟 RAW，但儲存／匯出限制需要更直白的使用者文案與實測。
6. Files provider 權限失效、重新授權與 timeout 文案尚未實機驗證。

## 6. 下一輪實作順序

1. 分離 `Adding source…` 與 `Scanning source…` overlay。
2. 補 `Reconnecting source…` 等待狀態與測試。
3. 在來源列補掃描中、partial failure 的文字狀態。
4. 實測搜尋／排序／切 scope，必要時補 query loading。
5. 實測唯讀／離線／需要存取權三種錯誤文案。

## 7. 驗收條件

- 每個表列操作都有對應的可見文字、失敗文案與測試或實機證據。
- `swift test` 全綠，iPad app generic build 成功。
- 真實 iPad 上 APFS、exFAT、Files provider 與 Sony `.ARW` gate 不得有 `NOT RUN`。
- Sony `.ARW` 操作前後 SHA-256 完全一致。
- 移除來源後外接來源上的 RAW、sidecar、manifest 均未被刪除或修改。
