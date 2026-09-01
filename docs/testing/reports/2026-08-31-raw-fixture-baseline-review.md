# RAW Fixture Baseline 修正 — 獨立唯讀 Review

日期：2026-08-31

審查者：Claude（`claude/ipad-beta-test-kit`，唯讀審查，未修改 Codex branch）

## 審查對象

- Codex baseline-fix commit 全 SHA：`f5dce94716d740ede6ad46c1632361ccf03efd8b`
- Commit message：`test: align RAW fixture acceptance baseline`
- Diff range：`f5dce94716d740ede6ad46c1632361ccf03efd8b^..f5dce94716d740ede6ad46c1632361ccf03efd8b`
- Parent commit：`f145a32f0476998e2976b5d1e38aaa159e39c974`
- 所在 branch：`codex/ipad-multi-source-library-durability`

## 檔案範圍確認

`git diff-tree --no-commit-id --name-only -r f5dce94716d740ede6ad46c1632361ccf03efd8b` 結果，逐一與預期比對：

- `Scripts/run-mvp-acceptance.zsh`
- `docs/testing/mvp-acceptance-report-template.md`

結果：`PASS`。恰好兩個檔案，未觸及 `Sources/`、`Tests/`、`Apps/` 或任何 Claude Beta Test Kit 文件。

## 必查事項逐項結果

### 1. `RAWFIXTURE_EXPECTED_TEST_COUNT=9` 定義位置與共用性

- 以 `git show f5dce94716d740ede6ad46c1632361ccf03efd8b:Scripts/run-mvp-acceptance.zsh` 取出修正後檔案內容獨立檢查（非依賴本 worktree 的舊版檔案，本 worktree 分支自更早的祖先 commit，未包含此修正）。
- 常數定義於第 50 行，位於 `run_selftest()`（第 130 行）之前。
- production RAW fixture gate（第 1037 行 `evaluate_xctest_log "$RAWFIXTURE_LOG" "$RAWFIXTURE_EXPECTED_TEST_COUNT"`）與 self-test 共用同一個常數，只有一處定義（`rg -n 'RAWFIXTURE_EXPECTED_TEST_COUNT' Scripts/run-mvp-acceptance.zsh` 只回傳這三處引用）。

結果：`PASS`。

### 2. self-test under/exact/over 對應 8/9/10

- self-test 以 `rawfixture_under=$((RAWFIXTURE_EXPECTED_TEST_COUNT - 1))`、`rawfixture_over=$((RAWFIXTURE_EXPECTED_TEST_COUNT + 1))` 動態推導，不再硬編碼。
- 獨立執行結果（於 `/private/tmp` 以 `git show` 匯出腳本後直接執行，未複製或信任 Codex 提供的文字）：

  ```
  selftest: executed=8, required=9 -> FAIL (expected FAIL): ok
  selftest: executed=9, required=9 -> PASS (expected PASS): ok
  selftest: executed=10, required=9 -> FAIL (expected FAIL): ok
  ```

結果：`PASS`，與必查條件的 8/9/10 一致，且為本次審查實際重跑取得，非照抄。

### 3. `evaluate_xctest_log` fail-closed 未被弱化

- 本次 diff 未變更 `evaluate_xctest_log` 函式本體（第 100–123 行），僅變更呼叫端的參數推導方式。
- 逐條確認函式內容：
  - `skipped != 0` → `return 1`（skipped 不可通過）。
  - `failures != 0` → `return 1`（failures 不可通過）。
  - `parse_xctest_summary` 失敗（unparsable）→ `return 1`。
  - `[[ -n "$required" ]] && (( executed != required ))` → `return 1`（executed 不等於 required 不可通過）。

結果：`PASS`，四個 fail-closed 條件全部維持。

### 4. 驗測報告範本列出 9 個測試名稱，各恰好一次

- 以 `git show f5dce94716d740ede6ad46c1632361ccf03efd8b:Tests/LumaHarborIntegrationTests/RawFixtureTests.swift` 取出實際測試檔，`rg -c '^    func test'` 回傳 `9`，函式名稱為：
  `testEveryFixtureDecodes`、`testSonyArwReportsPlausibleMetadata`、`testPreviewDecodeHonoursTheRequestedSize`、`testFullDecodeReturnsNativeResolution`、`testWhiteBalanceOffsetChangesTheRender`、`testFullResolutionExportMatchesTheSourceDimensions`、`testExportingNeverModifiesTheOriginal`、`testPreviewSchedulerDeliversARenderedFrameForARealRaw`、`testInteractivePreviewLatencyForARealPhoto`。
- 以 `git show f5dce94716d740ede6ad46c1632361ccf03efd8b:docs/testing/mvp-acceptance-report-template.md` 取出修正後範本全文，逐一比對上述 9 個名稱，每個都以反引號包裹的完整名稱恰好出現 1 次，且範本中沒有列出這 9 個以外的其他 `test*` 名稱。

結果：`PASS`，範本與測試檔名稱一對一，未新增、未遺漏、未重複。

### 5. 未修改禁止範圍

`git diff-tree` 確認變更檔案僅為 `Scripts/run-mvp-acceptance.zsh` 與 `docs/testing/mvp-acceptance-report-template.md`，未觸及 `Sources/`、`Tests/`、`Apps/` 或任何 Claude Beta Test Kit 文件。

結果：`PASS`。

### 6. 未把 `SKIPPED` 或 `NOT RUN` 當 `PASS`

self-test 與 `evaluate_xctest_log` 對 skipped 一律 `FAIL`／`return 1`，未見任何把 `SKIPPED` 或 `NOT RUN` 標記為 `PASS` 的邏輯變更。

結果：`PASS`。

### 7. 隱私掃描

- 對本次 diff 全文執行 `rg -n 'TBD|TODO|FIXME|/Users/|/Volumes/|/private/|Apple ID|Team ID|UDID|BEGIN.*(PRIVATE|CERTIFICATE)'`，唯一命中為既有未變更的 context line `LUMAHARBOR_RAW_FIXTURE_DIR=/path/to/private/fixtures`（範本中原有的示意路徑，非本次新增，也非真實使用者路徑）。
- `git diff --check` 對整個 commit 範圍執行，exit code `0`，無 whitespace 問題。

結果：`PASS`，未發現私人路徑、fixture 路徑、volume 名稱、Apple ID、Team ID、UDID、憑證或 provisioning profile。

## 獨立重跑的驗證指令與結果

以下指令由本次審查在隔離環境（`/private/tmp`，非任何 worktree）針對以 `git show` 匯出的修正後腳本重新執行，未直接採信 Codex 提供的既有結果：

| 指令 | 結果 |
|---|---|
| `zsh -n <匯出的 run-mvp-acceptance.zsh>` | `PASS`，exit 0 |
| `LUMAHARBOR_RUNNER_SELFTEST=1 zsh <匯出的 run-mvp-acceptance.zsh>` | `PASS`，exit 0，含 `executed=8/9/10, required=9` 三案例皆符合預期 |
| `git diff --check f5dce94716d740ede6ad46c1632361ccf03efd8b^..f5dce94716d740ede6ad46c1632361ccf03efd8b` | `PASS`，exit 0 |
| `git diff-tree --no-commit-id --name-only -r f5dce94716d740ede6ad46c1632361ccf03efd8b` | 恰好兩個預期檔案 |
| `rg -c '^    func test' <匯出的 RawFixtureTests.swift>` | `9` |
| Privacy scan（見上）| `PASS`，無命中新增私人資料 |

未獨立重跑項目：`swift test` 完整套件（1111 executed／9 skipped／0 failures）與 production RAW fixture gate（需要私人 fixture 路徑與完整 Xcode 工具鏈，屬於 Codex 或使用者在其環境執行的範圍，本次唯讀審查未在 Claude worktree 安裝或執行完整建置）。Codex 提供的對應數據與本次獨立驗證的靜態、可重現部分（常數位置、self-test 邏輯、fail-closed 行為、測試名稱對應、diff 範圍、whitespace）互相一致，未發現矛盾。

## 結論

**`APPROVED`**

沒有 blocking issue。七項必查事項全部通過，且關鍵項目（self-test 8/9/10 行為、`evaluate_xctest_log` fail-closed 契約、測試名稱對應、檔案範圍、隱私掃描）皆由本次審查獨立重跑驗證，非僅比對 Codex 提供的文字。

## 備註

- 本 review 僅涵蓋 `f5dce94716d740ede6ad46c1632361ccf03efd8b` 這一顆 commit 的 diff range；未審查該 branch 上其他 commit，也未對 Codex branch 做任何修改。
- 完整 `swift test` 與 production RAW fixture gate（需要私人 fixture 路徑）未在本次審查環境重跑，留待 Codex／使用者在其環境的後續驗收流程中確認；本結論不取代該項驗收。
