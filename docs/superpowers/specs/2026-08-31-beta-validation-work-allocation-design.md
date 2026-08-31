# LumaHarbor Beta 驗測分工設計

日期：2026-08-31

狀態：已確認，待實作計畫

## 1. 目的

在不公開上架 App Store 的前提下，將 LumaHarbor iPad 多來源 RAW 圖庫推進到可供少量受信任測試者使用的 RC（Release Candidate）。Codex 與 Claude 平行工作，但必須使用不同 branch、worktree 與不重疊的檔案範圍。

## 2. 目前基準

- Source-of-truth branch：`codex/ipad-multi-source-library-durability`
- 分工設計起點：`e305f9c`
- 自動 production acceptance 最近一次在 `a539f4a` 為 `PASS`。
- 完整 fixture production run：1111 executed、0 skipped、0 failures。
- 無 fixture 的一般 `swift test`：1111 executed、9 skipped、0 failures。
- 五項 M1+ iPad 實機 gate 仍全部為 `NOT RUN`。
- 正式 `RawFixtureTests` baseline 是 9，但 MVP runner self-test 與驗測報告範本仍使用 8。
- `Apps/LumaHarborPad.swiftpm/Package.swift` 有本機 Xcode signing／格式修改，不得納入本輪 commit。
- `docs/testing/reports/2026-08-26-ipad-multi-source-library.md` 有尚未提交的 2026-08-31 驗測證據，由 Codex 保留並獨立處理。

## 3. 採用方案

採用「平行專責、檔案隔離」：

- Codex 負責 runner 契約修正、既有驗測報告、RC 準備與完整自動驗收。
- Claude 只負責新增 Beta Test Kit 文件，之後對 Codex 的 runner 修正 commit 做唯讀獨立審查。
- 使用者負責 Apple signing、iPad 安裝，以及需要實體裝置、外接儲存與真實 Sony ARW 的操作。

不採用共用 worktree，也不讓 Claude 修改 runner 或既有驗測報告，以降低競態、dirty file 覆蓋與多輪 runner 歷史理解成本。

## 4. Branch 與 worktree

### 4.1 Codex

- 繼續使用 `codex/ipad-multi-source-library-durability`。
- 目前 worktree 的唯一寫入者為 Codex。
- 不得提交本機 Xcode `Package.swift` 修改。

### 4.2 Claude

- 從包含本分工 spec 的 commit 建立獨立 branch：`claude/ipad-beta-test-kit`；交接單必須提供該 commit 的完整 SHA。
- 使用獨立 worktree。
- 開始前必須讀取 `AGENTS.md`、`CLAUDE.md`、`docs/coordination/CURRENT.md`、本設計與既有 verification spec。
- Claude worktree 必須乾淨，且不得帶入 Codex worktree 的兩個未提交檔案。

## 5. 檔案所有權

### 5.1 Codex 可修改

- `Scripts/run-mvp-acceptance.zsh`
- `docs/testing/mvp-acceptance-report-template.md`
- `docs/testing/reports/2026-08-26-ipad-multi-source-library.md`
- 必要的 runner focused test／self-test 程式碼，但不得擴大到產品功能。
- RC 與 coordination 狀態文件，但須使用獨立 commit。

### 5.2 Claude 可修改

只允許新增下列檔案：

- `docs/testing/beta/TESTER_GUIDE.md`
- `docs/testing/beta/REAL_DEVICE_CHECKLIST.md`
- `docs/testing/beta/BUG_REPORT_TEMPLATE.md`
- `docs/testing/beta/PRIVACY.md`
- `docs/testing/beta/RC_CHECKLIST.md`
- `docs/testing/reports/2026-08-31-raw-fixture-baseline-review.md`，僅在第二階段收到 Codex commit SHA 後建立。

### 5.3 Claude 禁止修改

- `Scripts/`
- `Sources/`
- `Tests/`
- `Apps/`
- `AGENTS.md`
- `CLAUDE.md`
- `docs/coordination/CURRENT.md`
- 既有 multi-source 驗測報告
- 本設計未列入 Claude 可修改範圍的任何檔案

若 Claude 發現需要修改禁止範圍，只能寫入 concern／finding，不得直接修正。

## 6. Codex 工作內容

### 6.1 修正 RAW fixture baseline 漂移

Codex 必須：

1. 讓 `run_selftest()` 使用與 production gate 相同的 `RAWFIXTURE_EXPECTED_TEST_COUNT=9`，避免 self-test 硬編碼 8。
2. 保留 under／exact／over 三態測試，分別驗證 8／9／10。
3. 更新驗測報告範本為 9 項，加入 `testInteractivePreviewLatencyForARealPhoto`。
4. 不改變 production gate 對 9 項、0 skipped、0 failures 的 fail-closed 契約。

驗證：

- `zsh -n Scripts/run-mvp-acceptance.zsh`
- MVP runner self-test
- 完整 `swift test`
- `git diff --check`

修正與驗測報告更新使用不同 commit。

### 6.2 整理既有驗測證據

- 保存並獨立提交 2026-08-31 production runner 證據。
- 不把本機 `Package.swift` signing／格式修改帶入 commit。
- 報告不得包含私人 fixture、掛載點或使用者家目錄。

### 6.3 準備 RC

只有下列條件成立後才能建立 RC1：

- runner baseline 修正已通過 Claude 獨立審查；
- Beta Test Kit 已審查並整合；
- production acceptance 在 RC commit 實際 `PASS`；
- worktree 除明確 local-only signing 設定外沒有來源不明修改；
- RC commit、build number 與測試證據能互相對應。

RC 不代表最終 APPROVED；五項實機 gate 未完成時只能稱為 Beta／RC。

## 7. Claude 工作內容

### 7.1 Beta Test Kit

#### `TESTER_GUIDE.md`

包含：

- 適用 iPad 與 iPadOS 條件。
- Ad Hoc／Apple Configurator 安裝前提，不包含憑證私鑰。
- 首次啟動、加入資料夾、等待掃描、瀏覽、開啟 ARW、返回圖庫的基本流程。
- 如何辨識 loading、offline、需要授權與失敗狀態。
- 如何回報 build number、iPad 型號、iPadOS 與儲存來源類型。

#### `REAL_DEVICE_CHECKLIST.md`

以現有 verification spec 為來源，提供測試者可勾選版本：

1. APFS 加入、掃描、重開。
2. exFAT 拔除、離線、重新連接。
3. Files provider 重新授權。
4. 三來源搜尋、排序與狀態恢復。
5. Sony ARW 編輯、autosave、重開與 checksum。
6. 移除來源不刪除 RAW／sidecar／manifest。

每項結果只能是 `PASS`、`FAIL` 或 `NOT RUN`。

#### `BUG_REPORT_TEMPLATE.md`

要求：

- App version／build number。
- iPad 型號、iPadOS、方向與視窗模式。
- 儲存來源與 filesystem 類型，但不記私人完整路徑。
- 重現步驟、預期結果、實際結果。
- 截圖／錄影的安全檔名。
- crash、資料遺失、來源錯接、索引錯亂與 checksum 變化欄位。

#### `PRIVACY.md`

明確禁止：

- 上傳未授權 RAW 原檔。
- 暴露完整使用者、掛載點、provider 或 fixture 路徑。
- 分享 Apple 帳號、憑證、provisioning profile 或私鑰。
- 在截圖中留下私人檔名、帳號或雲端資料夾。

#### `RC_CHECKLIST.md`

包含：

- 固定 branch、commit、version、build number。
- 自動驗收與 privacy scan。
- Archive／簽署／安裝 smoke test。
- Beta Test Kit 與「What to Test」一致性。
- `PASS`／`FAIL`／`SKIPPED`／`NOT RUN` 分離。
- 已知問題、回退條件與停止散布條件。

### 7.2 獨立 review

Claude 完成 Beta Test Kit 後停止。收到 Codex runner 修正的完整 commit SHA 才進入第二階段：

- 以唯讀方式審查該 commit，不修改 Codex branch。
- 確認 self-test 與 production gate 共用同一 baseline。
- 確認 under／exact／over 為 8／9／10。
- 確認範本列出 9 項且名稱與測試檔一致。
- 檢查沒有把 skip 或測試數漂移當成 PASS。
- 將結論寫到 `docs/testing/reports/2026-08-31-raw-fixture-baseline-review.md`，狀態只能是 `APPROVED` 或 `BLOCKED`。

## 8. 使用者工作內容

- 在 Xcode 選取自己的 Development Team。
- 提供或連接 M1+ iPad、APFS、exFAT 與 Files provider。
- 在 Mac 記錄 Sony ARW 操作前後 SHA-256。
- 執行需要實體拔插、重新授權、旋轉、Split View 與 Stage Manager 的步驟。
- 決定是否收集測試者 UDID 並建立 Ad Hoc profile。
- 不將 Apple 帳號、憑證私鑰或私人 RAW 交給代理或測試者。

## 9. 平行流程與整合 gate

1. Codex 繼續使用目前 integration branch；Claude 從包含本分工 spec 的完整 commit SHA 建立獨立 branch 與 worktree。
2. Codex 修 runner；Claude 寫 Beta Test Kit，兩邊檔案不重疊。
3. 兩邊各自 commit，禁止 push／merge／rebase，除非使用者另行授權。
4. Codex 完成 focused verification 後，提供 runner 修正 SHA 給 Claude。
5. Claude 執行唯讀 review 並 commit review report。
6. Codex re-review Beta Test Kit 與 Claude review 結論。
7. 經使用者授權後才整合 Claude commits。
8. 在整合後的精確 commit 跑 production acceptance。
9. 使用者完成五項實機 gate，再決定是否產生 Ad Hoc RC1。

## 10. 失敗處理

- 任一代理碰到另一方擁有的 dirty file，立即停止該檔案的修改。
- Beta Test Kit 若與 verification spec 衝突，以 verification spec 為準並回報差異。
- Runner self-test、完整測試或 production acceptance 任一失敗，RC 建立停止。
- 任一實機案例發生 crash、資料遺失、來源身份誤接、RAW checksum 改變或偽成功，停止散布該 build。
- 缺少實機、外接儲存或 fixture 時，相關 gate 保持 `NOT RUN`。

## 11. 完成條件

本輪分工完成需同時符合：

- Codex runner baseline 修正完成且驗證通過。
- 2026-08-31 驗測報告已獨立提交。
- Claude Beta Test Kit 五份文件完成且無敏感資料。
- Claude runner review 為 `APPROVED`。
- Codex 對 Claude 文件 re-review 沒有阻擋 finding。
- 整合 commit 的 production acceptance 為 `PASS`。

整體 iPad 多來源功能只有在五項實機 gate 也全部 `PASS` 後，才能從 `BLOCKED` 改為 `APPROVED`。

## 12. 非目標

- 不公開上架 App Store。
- 不在本輪建立 Enterprise、Custom App 或 Unlisted App 散布。
- 不讓 Claude 修改產品 Swift 程式碼。
- 不新增產品功能或重新設計 UI。
- 不自動 push、merge、rebase、刪除 branch 或 worktree。
