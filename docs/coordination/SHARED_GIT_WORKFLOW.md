# LumaHarbor 跨代理共用 Git 工作流程

- 狀態：現行
- 適用代理：Codex、Claude、Gemini，以及任何受指派修改本專案的代理
- 目的：所有代理使用同一個正式基準，同時保留各自獨立、可審查、可回復的工作空間

## 1. 唯一正式版本

- `origin/main` 是唯一整合版與最新正式基準。
- 代理 branch 只代表一項尚未整合的工作，不是另一個「最新版」。
- branch 名稱、commit 日期或 AI 名稱都不能證明版本較新；必須核對 base、tree diff、測試與 `CURRENT.md`。
- 舊 branch/worktree 在確認沒有獨有成果前不得刪除，也不得為了看似一致而全部 reset、rebase 或 force-push 到 `main`。

## 2. 一項任務一個擁有者

每項可寫入的任務必須同時具備：

1. 一個明確的寫入代理。
2. 一個從當時最新 `origin/main` 建立的短期 branch。
3. 一個只給該 branch 使用的 worktree。
4. 一個寫入範圍，以及其他代理的 review-only 邊界。

Branch 命名：

| 寫入代理 | 格式 | 範例 |
| --- | --- | --- |
| Codex | `codex/<task>` | `codex/xmp-reference-renderer` |
| Claude | `claude/<task>` | `claude/ipad-inspector-polish` |
| Gemini | `gemini/<task>` | `gemini/preset-compatibility-audit` |

不要建立 `*-latest`、`*-current` 或長期累積所有任務的代理專屬分支。新任務使用新的描述性名稱。

## 3. 開始工作

先執行唯讀快照：

```sh
git rev-parse --show-toplevel
git branch --show-current
git rev-parse HEAD
git status --short --branch
git worktree list --porcelain
git ls-remote origin refs/heads/main
```

然後：

1. 確認遠端 `main` SHA 與 `CURRENT.md` 記載的正式基準相容。
2. 確認目前 worktree 沒有別人或使用者留下的未提交內容。
3. 需要寫入時，從最新 `origin/main` 建立新的代理 task branch/worktree。
4. 在 `CURRENT.md` 記錄 owner、branch、base SHA、dirty files 與本次範圍。

若既有 task branch 落後 `origin/main`，只先計算差異：

```sh
git rev-list --left-right --count origin/main...HEAD
git diff --stat origin/main...HEAD
```

不得自動 merge、rebase、reset 或 force-push。先確認該 branch 是否仍有獨有成果，再取得使用者授權。

## 4. 工作期間

- 同一個 worktree 同一時間只有一個寫入者。
- 其他代理可以從自己的 worktree 審查，但不能修改寫入者的 dirty files。
- 只 stage 本次負責的明確路徑，不使用會把未知檔案一起加入的批次 stage。
- 本機 Xcode signing、Team、provisioning、私人 fixture 路徑與代理內部狀態維持 local-only。
- 產品修改、測試修改與 coordination-only 文件若需要獨立審查，使用不同 commit。

## 5. 驗證與交接

交接前必須：

1. 執行與風險相稱的 build/test，並保留 `PASS`、`FAIL`、`SKIPPED`、`NOT RUN` 的差異。
2. 執行 `git diff --check` 與必要的隱私掃描。
3. 更新 `CURRENT.md`，但其中的產品基準仍記錄最近一次完整驗證的 commit，不記錄無法自我引用的 coordination commit SHA。
4. 依 `HANDOFF_TEMPLATE.md` 記錄 writer、branch、base、HEAD、commit、changed files、tests、dirty files、風險與唯一下一步。
5. push、merge、rebase、刪除 branch/worktree 或將 branch 直接更新到 `main` 前，取得使用者明確授權。

## 6. 整合完成後

- 經驗證且獲授權的成果才能進入 `main`。
- 整合後，`origin/main` 再次成為所有新任務的唯一出發點。
- 已整合的 task branch 可以在確認遠端 SHA、dirty files 與 worktree 都已保全後刪除。
- 未整合或來源不明的 branch 保留為 snapshot，先封存再整理。
- 不把歷史 branch 全部改指向 `main`；那會抹去它們原本提供的比較與復原價值。

## 7. 共用與不共用的資料

跨代理共用：

- Git commit 與 branch。
- `AGENTS.md`、本文件、`CURRENT.md`、`DECISIONS.md` 與 handoff。
- Spec、plan、測試、report 與可重現命令結果。

不得跨代理共用：

- 登入憑證、API key、token 或簽章身分。
- 聊天紀錄、快取、內部狀態資料庫。
- `.codex/`、`.claude/`、`.gemini/` 內的工具專屬私人狀態。
- 使用者或其他代理尚未提交的工作目錄。
