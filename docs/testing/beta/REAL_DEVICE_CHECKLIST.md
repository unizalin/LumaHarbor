# LumaHarborPad 實機驗測清單

## 測試資訊

- Build：
- Commit（完整 SHA）：
- 測試日期／時間：
- 測試者代號：
- iPad 型號：
- iPadOS：
- APFS 來源代號：
- exFAT 來源代號：
- 檔案提供者類型：

每一項只能填 `PASS`、`FAIL` 或 `NOT RUN`，並附必要備註。`NOT RUN` 不得視為通過。

## A. 安裝與啟動

| ID | 驗測項目 | 結果 | 備註／證據 |
|---|---|---|---|
| A1 | 指定簽署 build 可安裝並啟動 | NOT RUN | |
| A2 | 首次啟動空狀態與加入來源入口可見 | NOT RUN | |
| A3 | 拒絕或缺少權限時有可理解的提示與下一步 | NOT RUN | |

## B. APFS 來源

| ID | 驗測項目 | 結果 | 備註／證據 |
|---|---|---|---|
| B1 | 可選擇 APFS 資料夾並加入來源 | NOT RUN | |
| B2 | 掃描期間顯示 loading／進度，完成後照片可見 | NOT RUN | |
| B3 | 關閉並重開 App 後來源與索引仍存在 | NOT RUN | |
| B4 | 移除來源前有確認，移除後 RAW、sidecar 與 manifest 仍存在且未修改 | NOT RUN | |

## C. exFAT 來源與重新連結

| ID | 驗測項目 | 結果 | 備註／證據 |
|---|---|---|---|
| C1 | 可選擇 exFAT 資料夾並加入來源 | NOT RUN | |
| C2 | 拔除磁碟後來源顯示離線，不閃退、不假裝可用 | NOT RUN | |
| C3 | 接回磁碟並選擇正確資料夾後可 relink | NOT RUN | |
| C4 | 選擇錯誤資料夾時拒絕連結並保留原離線來源 | NOT RUN | |
| C5 | relink 後搜尋、排序與照片識別不產生明顯重複 | NOT RUN | |

## D. 檔案提供者來源

| ID | 驗測項目 | 結果 | 備註／證據 |
|---|---|---|---|
| D1 | 可加入檔案提供者資料夾 | NOT RUN | |
| D2 | 檔案尚未下載時有明確等待狀態 | NOT RUN | |
| D3 | 授權失效時顯示需要重新授權 | NOT RUN | |
| D4 | 重新授權後可恢復瀏覽與開圖 | NOT RUN | |

## E. 多來源圖庫與 iPad 介面

| ID | 驗測項目 | 結果 | 備註／證據 |
|---|---|---|---|
| E1 | 三種來源可同時顯示於合併圖庫 | NOT RUN | |
| E2 | 來源、資料夾、搜尋與排序切換結果正確 | NOT RUN | |
| E3 | 進入編輯器再返回後維持合理的選取與捲動位置 | NOT RUN | |
| E4 | 直向與橫向旋轉後沒有遮擋、截斷或操作遺失 | NOT RUN | |
| E5 | Split View 可用，縮放後主要操作仍可到達 | NOT RUN | |
| E6 | Stage Manager 可用，調整視窗後主要操作仍可到達 | NOT RUN | |
| E7 | 掃描、開圖與重新連結期間重複點擊不會重複啟動工作 | NOT RUN | |

## F. Sony ARW 非破壞式編輯

| ID | 驗測項目 | 結果 | 備註／證據 |
|---|---|---|---|
| F1 | 真實 Sony `.ARW` 可開啟並顯示預覽 | NOT RUN | |
| F2 | Exposure 調整可見且可還原 | NOT RUN | |
| F3 | Contrast 調整可見且可還原 | NOT RUN | |
| F4 | Highlights 調整可見且可還原 | NOT RUN | |
| F5 | Shadows 調整可見且可還原 | NOT RUN | |
| F6 | Whites 調整可見且可還原 | NOT RUN | |
| F7 | Blacks 調整可見且可還原 | NOT RUN | |
| F8 | Temperature 調整可見且可還原 | NOT RUN | |
| F9 | Tint 調整可見且可還原 | NOT RUN | |
| F10 | Vibrance 調整可見且可還原 | NOT RUN | |
| F11 | Saturation 調整可見且可還原 | NOT RUN | |
| F12 | 自動儲存完成後重開 App，十項編輯狀態仍存在 | NOT RUN | |
| F13 | 編輯前後 RAW 原檔 checksum 與檔案大小不變 | NOT RUN | |

## G. 停止條件

下列任一情況發生時，停止把此 build 當作 RC 候選並建立 bug：

- RAW 原檔被修改、覆寫、重新命名或刪除。
- 錯誤資料夾被接受為原來源的 relink。
- App 閃退、資料庫損壞、編輯狀態跨照片錯置。
- 權限或提供者授權失效後沒有復原路徑。
- 關鍵 loading 永不結束且無法取消或重試。
- 任何必要項目為 `FAIL` 或 `NOT RUN`。

## 整體結論

- 結果：NOT RUN
- 阻擋問題：
- 未執行項目與原因：
- 證據位置（僅填去識別化名稱）：
