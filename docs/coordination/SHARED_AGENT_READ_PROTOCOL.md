# LumaHarbor 共用代理讀取協定

- 狀態：現行、跨代理共用規則
- 適用代理：Codex、Claude、Gemini，以及任何讀取本專案的其他代理
- 目的：讓不同代理在沒有聊天上下文時，仍能從同一套 Git 文件、目前狀態與驗證證據重建可靠上下文
- Issue 策略：不建立 GitHub Epic、Issue 或其他追蹤項目；工作以專案內的 spec、plan、report、handoff 與 Git commit 為準

## 1. 權威來源與優先順序

本協定定義「如何讀取」，不取代產品規格或安全規則。遇到矛盾時，依下列順序判斷：

1. 使用者本次明確指示。
2. `AGENTS.md` 的專案安全、協作與 Git 規則。
3. 目前工作樹中的實際程式碼、測試與可重現命令結果。
4. 已核准的產品 spec。
5. implementation plan。
6. `CURRENT.md`、handoff 與歷史 report。

若 Git 狀態、目前程式碼與文件不一致，不得自行猜測最新來源；先標記 `NEEDS_CONTEXT`，完成唯讀釐清後才能寫入。

## 2. 代理角色與預設權限

- 預設角色是唯讀讀取、核對與回報。
- 只有收到明確的實作指示後，才可修改原始碼、測試或文件。
- `push`、force-push、merge、rebase、刪除 branch/worktree、重置工作樹與發布操作，都需要使用者明確授權；不能由「開始工作」或「請檢查」推定授權。
- 不建立 GitHub Issue、Epic、PR、branch 或 worktree，除非使用者明確要求。
- 不讀取或輸出 `.codex/`、`.claude/` 的登入資料、聊天記錄、快取、內部狀態資料庫或其他認證資料。

## 3. 必讀順序

每次進入專案，先定位 Git 根目錄，再依序讀取。不可先跳入原始碼而事後補讀規則。

### 3.1 定位與狀態快照

```sh
git rev-parse --show-toplevel
git branch --show-current
git rev-parse HEAD
git status --short --branch
git worktree list --porcelain
git log --oneline -8
```

記錄目前 branch、完整 HEAD、工作樹 dirty files、worktree 清單與最近 commit。報告使用 repository-relative 路徑；不要把本機帳號、主機名稱或完整檔案系統路徑寫入共用文件。

### 3.2 共用入口與目前狀態

依序讀取：

1. `AGENTS.md`
2. `CLAUDE.md`（若存在，確認它只匯入 `AGENTS.md`，不得形成第二套規則）
3. `GEMINI.md`（若存在，視為入口提示，不得覆蓋 `AGENTS.md`）
4. `docs/coordination/SHARED_AGENT_READ_PROTOCOL.md`
5. `docs/coordination/CURRENT.md`
6. `docs/coordination/DECISIONS.md`

將第 3.1 節的 Git 快照與 `CURRENT.md` 比對。若 branch、dirty files、worktree owner 或 source-of-truth 不一致，就停止寫入並回報 `NEEDS_CONTEXT`。若 HEAD 只是晚於 `CURRENT.md` 所記錄的產品基準，先檢查差異是否只包含 coordination-only 文件；確認沒有產品程式碼、測試或設定變更後，才可繼續。

### 3.3 規格、計畫與證據

- 先讀 `AGENTS.md` 的 Canonical project artifacts 索引。
- 依 `CURRENT.md` 的 `Next action` 只讀取目前工作的 spec、plan、handoff 與 report。
- 若需要確認完整規格家族，再列出 `docs/superpowers/specs` 與 `docs/testing`；不可只挑檔名含某個代理名稱的文件。
- 日期較新的文件不會自動取代較舊文件。只有文件明寫取代範圍，或 `CURRENT.md` 指定為目前基準，才可視為取代。
- 文件讀完後，才用 `rg` 依 spec 的檔案與符號參考核對原始碼、測試、sidecar、render、undo、batch 與 export 連線。

## 4. 目前狀態與證據契約

每個結論都必須能指向三種證據：

1. spec 段落：說明應有行為或驗收條件。
2. 目前檔案或測試：說明實際實作位置。
3. 命令、log 或 report：說明驗證狀態。

不得只因看見 model、UI 字串或一個測試就宣稱完整功能已接通。

狀態標籤固定使用：

| 標籤 | 定義 |
| --- | --- |
| `IMPLEMENTED` | 程式碼已存在，且沒有證據顯示只是展示層或半套流程 |
| `PASS` | 指定命令或人工 gate 有可追溯的成功證據 |
| `FAIL` | 指定命令明確失敗，列出測試名稱或錯誤摘要 |
| `SKIPPED` | 測試框架明確跳過，列出原因 |
| `NOT RUN` | 命令、素材、硬體或人工步驟尚未執行 |
| `SPEC ONLY` | 只有 spec/plan，沒有可驗證實作證據 |
| `NEEDS_CONTEXT` | Git、文件或工作樹互相矛盾，不能安全判斷 |

`PASS` 不可由 `IMPLEMENTED` 推導；`NOT RUN` 不得改寫為「應該可以」。需要實體 iPad、Mac、外接磁碟或特定素材時，必須保留 `NOT RUN` 或 `SKIPPED`。

## 5. 多代理協作規則

- Codex、Claude、Gemini 同時修改時，使用不同 branch 與 worktree。
- 同一個檔案同一時間只指定一個寫入者；其他代理只能 review-only。
- 不覆蓋、回復、搬移或刪除另一代理或使用者尚未提交的變更。
- 交接前更新 `CURRENT.md`、使用 `HANDOFF_TEMPLATE.md`，並記錄 branch、完整 HEAD、base、改動檔案、測試、skip/not-run、dirty files、風險與一個明確下一步。
- 代理內部登入狀態、聊天紀錄、快取與工具資料庫不屬於共用上下文；只用 Git 中的 Markdown、程式碼、測試與 commit 傳遞資訊。

## 6. 隱私與發布檢查

共用文件、commit、測試輸出與發布產物不得包含：

- 私人絕對路徑、帳號名稱、主機名稱或掛載點。
- API key、token、密碼、私鑰、`.p12`、provisioning profile、UDID 或 Team ID。
- 私有 RAW fixture 的完整位置、bookmark data、聊天資料庫或代理內部狀態。

隱私掃描必須同時涵蓋：

- 目前文字檔與 Git 歷史中的 blob/diff。
- binary、`.app`、ZIP、`dist/`、`build/` 與 SwiftPM/Xcode 產物。
- 發布 ZIP 解壓後的完整內容，而不只是檔名或 changed text files。

報告中使用 repository-relative 路徑與 `<REDACTED>` 佔位符。Xcode 本機 signing、Team、provisioning 與格式化變更預設為 local-only，除非使用者明確授權，不得 stage 或 commit。

## 7. 唯讀審查回報格式

任何沒有實作授權的審查，至少輸出：

- `Reading scope`：實際讀過的 repository-relative 路徑。
- `Baseline`：branch、完整 HEAD、worktree 與 dirty files。
- `Status matrix`：各 phase 的實作狀態與自動／人工驗測狀態。
- `Verified findings`：每項附 spec、程式／測試檔案與命令或 report 證據。
- `Risks and blockers`：只列可證明問題，區分目前檔案、目前歷史與遠端狀態。
- `One next action`：只選一個有明確檔案範圍與依賴的下一步。
- `Handoff`：給下一代理的短摘要。

回報結尾只能使用：

- `DONE`
- `DONE_WITH_CONCERNS`
- `NEEDS_CONTEXT`

## 8. 實作與交接完成條件

實作代理在回報完成前必須：

1. 以與風險相稱的命令驗證，記錄實際 exit code、測試數、failure、skip 與未執行 gate。
2. 執行 `git diff --check`。
3. 對變更檔案及相關 binary/發布產物執行隱私掃描。
4. 更新 `CURRENT.md` 的 source-of-truth、owner、dirty files、證據與下一步。
5. 不把本機 signing 或其他來源不明的 dirty file 混入產品 commit。

只有在必要 gate 已有證據且沒有未揭露 blocker 時，才能使用 `DONE`；只要仍有明確 `FAIL` 或必要 `NOT RUN`，使用 `DONE_WITH_CONCERNS`。

## 9. 代理啟動提示詞

以下提示詞可直接交給 Codex、Claude 或 Gemini；它只授權讀取，不授權實作：

```text
請以唯讀模式審查 LumaHarbor，先讀取 AGENTS.md、CLAUDE.md（若有）、GEMINI.md（若有）、docs/coordination/SHARED_AGENT_READ_PROTOCOL.md、CURRENT.md 與 DECISIONS.md。

先回報 git branch、完整 HEAD、status、worktree 與最近 commit；若與 CURRENT.md 不一致，停止並輸出 NEEDS_CONTEXT。
接著依 CURRENT.md 的 Next action 讀取對應 spec、plan、handoff、report，再核對程式碼與測試。

禁止修改檔案、建立 Issue/PR/branch/worktree、merge、rebase、reset、刪除或 push。
回報時使用 IMPLEMENTED、PASS、FAIL、SKIPPED、NOT RUN、SPEC ONLY、NEEDS_CONTEXT，並以 repository-relative 路徑呈現證據；不得輸出私人絕對路徑、帳號、憑證、Team ID、UDID 或私有 fixture 位置。
```
