# Codex／Claude 共用協作資料設計

日期：2026-08-31

狀態：已確認，待實作

## 1. 目的

讓 Codex 與 Claude 在不同 Git branch 與 worktree 工作時，仍能讀取同一套專案規則、目前進度、架構決策與交接格式，降低規格、測試證據及分支狀態不同步的風險。

本設計不讓兩個代理共用登入憑證、聊天紀錄、快取、工具內部狀態或同一份未提交工作目錄。

## 2. 核心原則

1. Git 內的 Markdown 文件是跨代理唯一共用資料來源。
2. Codex 與 Claude 同時修改專案時，必須使用不同 branch 與 worktree。
3. 每次開始工作前讀取共用資料；每次交接前更新進度並 commit。
4. `SKIPPED`、`NOT RUN` 與 `PASS` 必須分開記錄，不得互換。
5. 不覆蓋、回復或刪除另一個代理或使用者尚未提交的變更。
6. 不把私人 fixture 路徑、帳號、憑證或其他敏感資訊寫進共用文件。

## 3. 文件架構

### 3.1 `AGENTS.md`

專案層級共同規則，也是 Codex 與 Claude 的必讀入口。內容包括：

- 使用繁體中文回報進度。
- 不同代理使用不同 branch 與 worktree。
- 開始工作前必讀的共用文件路徑。
- 交接與提交規則。
- 禁止未授權的 push、merge、rebase 與破壞性操作。
- 私密資料與本機 Xcode 設定的處理規則。
- 目前專案的正式 spec、plan、verification spec 與 report 索引。

`AGENTS.md` 只保存穩定規則與索引，不保存會頻繁變動的 HEAD 或測試數量，避免每次工作都修改根規則。

### 3.2 `CLAUDE.md`

只包含：

```text
@AGENTS.md
```

Claude 由此匯入與 Codex 相同的專案規則，不另行維護重複版本。

### 3.3 `docs/coordination/CURRENT.md`

目前專案進度的唯一來源，保存：

- source-of-truth branch 與完整 commit SHA。
- base branch 與相對 ahead／behind 狀態。
- 現在負責修改的代理與 worktree。
- 最近一次自動測試及實機驗測證據。
- 尚未完成的 gate。
- 已知 dirty files 及其擁有者。
- 下一個明確工作項目。
- 最近更新時間與更新者。

每次交接必須更新並 commit。另一個代理若讀到的工作目錄 HEAD 與文件記載的 source-of-truth HEAD 不一致，應先停止修改，重新確認 branch 或以唯讀方式檢查差異。

### 3.4 `docs/coordination/DECISIONS.md`

以追加方式保存已確認、會影響兩個代理的決定。每筆記錄包含：

- 日期與決定編號。
- 背景與問題。
- 最終決定。
- 影響範圍。
- 被取代時指向新決定，但不刪除原紀錄。

不記錄一般實作細節；能由 commit、spec 或測試直接看出的內容，以連結引用取代重複敘述。

### 3.5 `docs/coordination/HANDOFF_TEMPLATE.md`

提供固定交接格式：

- Status。
- Branch／HEAD／base。
- 修改檔案與 commit。
- 已執行測試及實際結果。
- `SKIPPED`／`NOT RUN` 項目。
- Dirty files 與擁有者。
- 已知問題及風險。
- 下一步與禁止事項。

交接內容必須能讓新代理不依賴聊天紀錄就開始工作。

## 4. 工作流程

### 4.1 開始工作

1. 讀取 `AGENTS.md`。
2. 讀取 `docs/coordination/CURRENT.md` 與仍有效的 `DECISIONS.md`。
3. 確認目前 branch、HEAD、worktree 與 dirty files。
4. 若需要修改，建立或使用代理專屬 branch/worktree。
5. 若狀態與 `CURRENT.md` 不一致，在寫入前先釐清，不能自行假設最新來源。

### 4.2 工作期間

- 一個檔案同一時間只由一個代理負責修改。
- 另一個代理可以唯讀審查，但不得改寫相同工作目錄。
- 長時間工作可更新 commentary，但不把未證實結果寫成正式 PASS。
- 新的跨代理架構決定追加到 `DECISIONS.md`。

### 4.3 交接

1. 執行與風險相稱的測試。
2. 記錄實際測試數量、failure、skip 與未執行項目。
3. 更新 `CURRENT.md`。
4. 使用 `HANDOFF_TEMPLATE.md` 產生交接摘要。
5. 將產品修改、測試及 coordination 文件一併 commit；若 coordination 更新需要獨立審閱，可使用單獨 commit。
6. 回報 dirty files，並說明是否屬於使用者或本機工具設定。

## 5. 衝突與失敗處理

- `CURRENT.md` 若同時被修改，以 commit 歷史及實際 branch HEAD 判斷；不得直接覆蓋另一方內容。
- 若兩個代理都需要修改同一產品檔案，先指定單一寫入者，另一方改為 review-only。
- 若驗測證據與文件不一致，以可重現的 log、summary 與 commit SHA 為準，修正文檔後再交接。
- 若工作目錄存在來源不明的 dirty file，先停止處理該檔案，標記擁有者並在 `CURRENT.md` 記錄。
- 無法取得實機或 fixture 時，對應項目只能記為 `NOT RUN` 或 `SKIPPED`。

## 6. 安全與隱私

共用文件不得包含：

- API key、密碼、憑證或 provisioning 私密內容。
- Claude／Codex 的登入資料、聊天資料庫、快取或內部狀態。
- 私人 RAW fixture 的完整本機路徑。
- 未經遮蔽的使用者名稱、掛載路徑或測試暫存路徑。

本機 Xcode 自動產生的 signing team、格式變更或開發者個人設定，除非使用者明確要求納入版本控制，否則標記為 local-only。

## 7. 驗證方式

實作後必須確認：

1. 根目錄存在 `AGENTS.md` 與 `CLAUDE.md`。
2. `CLAUDE.md` 只有 `@AGENTS.md`，沒有重複規則。
3. `AGENTS.md` 連結的 coordination、plan、spec 與 report 路徑均存在。
4. `CURRENT.md` 記載的 branch 與 commit 可以由 Git 解析。
5. 共用文件沒有 placeholder、私人絕對路徑或敏感資料。
6. `git diff --check` 通過。
7. 現有產品程式碼與測試不因加入協作文件而改變。

## 8. 初始狀態內容

第一次建立 `CURRENT.md` 時，以 `codex/ipad-multi-source-library-durability` 為 source of truth，記錄：

- 自動驗收最近一次在 `a539f4a` 為 PASS：1111 executed、0 skipped、0 failures。
- 五項真實 M1+ iPad gate 仍為 `NOT RUN`。
- `Apps/LumaHarborPad.swiftpm/Package.swift` 為本機 Xcode signing／格式變更，不得混入 coordination commit。
- `docs/testing/reports/2026-08-26-ipad-multi-source-library.md` 有尚未提交的 2026-08-31 驗測證據，必須保留並另行處理。
- MVP runner 的正式 RAW fixture baseline 是 9，但 self-test 與報告範本仍使用 8，需在最終 landing 前修正。

## 9. 非目標

- 不同步兩個代理的內部記憶或聊天內容。
- 不允許兩個代理同時寫入同一 worktree。
- 不建立自動 push、merge 或 rebase 流程。
- 不用 coordination 文件取代既有產品 spec、測試報告或 Git commit。
- 不為了同步狀態引入外部資料庫、服務或第三方 plugin。
