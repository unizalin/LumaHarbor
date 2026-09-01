# LumaHarborPad Beta RC 檢查清單

## 候選版本

- RC 編號：
- Branch：
- Commit（完整 SHA）：
- Version：
- Build：
- 建立日期／時間：
- 建立者代號：

## 1. 原始碼與自動驗收

| Gate | 結果 | 證據／備註 |
|---|---|---|
| 工作樹與候選 commit 已確認 | NOT RUN | |
| strict-concurrency build | NOT RUN | |
| 完整 `swift test` | NOT RUN | |
| iOS Simulator build | NOT RUN | |
| MVP preflight | NOT RUN | |
| MVP acceptance | NOT RUN | |
| RAW fixture 核准基線 9/9、0 skipped、0 failures | NOT RUN | |
| `git diff --check` | NOT RUN | |
| Privacy scan | NOT RUN | |

## 2. 實機驗測

| Gate | 結果 | 證據／備註 |
|---|---|---|
| APFS 來源 | NOT RUN | |
| exFAT 離線與 relink | NOT RUN | |
| 檔案提供者重新授權 | NOT RUN | |
| Sony ARW 非破壞式編輯 | NOT RUN | |
| iPad 旋轉、Split View、Stage Manager | NOT RUN | |
| 移除來源不刪除原檔 | NOT RUN | |

## 3. 文件與隱私

| Gate | 結果 | 證據／備註 |
|---|---|---|
| `TESTER_GUIDE.md` 與本 build 一致 | NOT RUN | |
| `REAL_DEVICE_CHECKLIST.md` 已完成 | NOT RUN | |
| 已知問題與限制已列出 | NOT RUN | |
| Bug 回報不含私人或簽署資料 | NOT RUN | |
| 散布名單與 Beta 範圍已確認 | NOT RUN | |

## 4. 簽署與安裝

| Gate | 結果 | 證據／備註 |
|---|---|---|
| Bundle Identifier 與候選設定正確 | NOT RUN | |
| Development／Ad Hoc 簽署由專案擁有者完成 | NOT RUN | |
| 指定 iPad 可安裝、信任並啟動 | NOT RUN | |
| 重新安裝或升級不造成非預期資料遺失 | NOT RUN | |

## 5. 已知問題

- Blocker：
- High：
- Medium：
- Low：
- 接受風險與理由：

## 6. 決策

- 決策：NOT RUN
- 可選值：`APPROVED FOR PRIVATE BETA`／`BLOCKED`／`NOT RUN`
- 決策者：
- 日期／時間：
- 未完成項目：

只有所有必要 gate 為 `PASS`，且沒有未接受的 Blocker／High 問題，才能標記 `APPROVED FOR PRIVATE BETA`。任何 `FAIL`、`SKIPPED` 或 `NOT RUN` 都必須明列；本文件不代表正式版或 App Store 上架核准。
