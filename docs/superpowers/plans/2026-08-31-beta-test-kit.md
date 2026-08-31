# iPad Beta Test Kit Implementation Plan

> **For Claude Code:** REQUIRED SUB-SKILL: Use the executing-plans workflow and complete this plan task-by-task. Do not begin the later code-review phase; this plan ends after the Beta Test Kit commit.

**Goal:** Produce a safe, tester-friendly document kit for private iPad Beta validation without modifying product code, runners, existing reports, or shared coordination state.

**Architecture:** The kit is five Markdown files under one new directory. It separates tester instructions, real-device execution evidence, bug intake, privacy rules, and release-candidate approval so a failed or unrun check cannot be mistaken for approval. The kit describes Beta/RC distribution only; it does not claim App Store readiness or final release approval.

**Tech Stack:** Markdown, Git, shell validation with `rg` and `git diff --check`.

## Global Constraints

- Start from exact commit `9cbc953915f5eb6c8385ef0125e0c6685a5c14c0` on branch `claude/ipad-beta-test-kit` in a separate worktree.
- Read and obey `AGENTS.md`, `CLAUDE.md`, `docs/coordination/CURRENT.md`, `docs/superpowers/specs/2026-08-31-beta-validation-work-allocation-design.md`, and `docs/testing/2026-08-29-ipad-multi-source-library-verification-spec.md` before editing.
- Create or modify only these five files:
  - `docs/testing/beta/TESTER_GUIDE.md`
  - `docs/testing/beta/REAL_DEVICE_CHECKLIST.md`
  - `docs/testing/beta/BUG_REPORT_TEMPLATE.md`
  - `docs/testing/beta/PRIVACY.md`
  - `docs/testing/beta/RC_CHECKLIST.md`
- Do not modify anything under `Scripts/`, `Sources/`, `Tests/`, or `Apps/`.
- Do not modify `AGENTS.md`, `CLAUDE.md`, `docs/coordination/CURRENT.md`, or any existing acceptance report.
- Do not add real user names, Apple IDs, team IDs, device identifiers, file names, fixture paths, volume names, provider account names, or temporary paths.
- Keep `PASS`, `FAIL`, `SKIPPED`, and `NOT RUN` distinct. Never treat `SKIPPED` or `NOT RUN` as `PASS`.
- Do not push, merge, rebase, cherry-pick, remove worktrees, or change signing/provisioning.
- Stop immediately after the one documentation commit and report its full SHA.

---

### Task 1: Establish the isolated documentation boundary

**Files:**
- Read: `AGENTS.md`
- Read: `CLAUDE.md`
- Read: `docs/coordination/CURRENT.md`
- Read: `docs/superpowers/specs/2026-08-31-beta-validation-work-allocation-design.md`
- Read: `docs/testing/2026-08-29-ipad-multi-source-library-verification-spec.md`

- [ ] **Step 1: Verify branch and base**

Run:

```bash
git status --short --branch
git rev-parse HEAD
git branch --show-current
```

Expected:

- Branch is `claude/ipad-beta-test-kit`.
- Initial HEAD is `9cbc953915f5eb6c8385ef0125e0c6685a5c14c0`.
- Worktree is clean before creating the five assigned files.

If the branch, base, or cleanliness differs, stop and report the discrepancy. Do not reset, stash, clean, or overwrite anything.

- [ ] **Step 2: Read the controlling documents**

Run:

```bash
sed -n '1,240p' AGENTS.md
sed -n '1,80p' CLAUDE.md
sed -n '1,240p' docs/coordination/CURRENT.md
sed -n '1,280p' docs/superpowers/specs/2026-08-31-beta-validation-work-allocation-design.md
sed -n '1,320p' docs/testing/2026-08-29-ipad-multi-source-library-verification-spec.md
```

Expected: the controlling documents confirm separate worktrees, single-writer file ownership, privacy-safe evidence, and the five-file Claude boundary.

---

### Task 2: Write the private Beta tester guide

**Files:**
- Create: `docs/testing/beta/TESTER_GUIDE.md`

- [ ] **Step 1: Create the guide with this complete structure**

Write the following content, preserving its meaning and status vocabulary. Minor wording improvements in natural zh-TW are allowed, but do not add unsupported product claims.

```markdown
# LumaHarborPad 私人 Beta 測試指南

## 測試定位

這是私人 Beta／RC 驗測，不是正式版核准，也不代表 App Store 上架準備完成。測試目的是確認 iPad 能從多種來源瀏覽、開啟及非破壞式編輯 Sony `.ARW`，並在重新啟動、來源中斷與重新授權後維持正確狀態。

## 測試前準備

- Apple Silicon iPad，iPadOS 17 或更新版本。
- 由專案擁有者提供並簽署的 Ad Hoc／Development 測試版。
- 一個 APFS 外接來源、一個 exFAT 外接來源，以及一個可重新授權的檔案提供者來源。
- 測試者自己有權使用的 Sony `.ARW` 樣本；不要上傳私人 RAW 原檔到公開服務。
- iPad 有足夠儲存空間，並能在需要時連線完成安裝或來源授權。

## 安裝與首次啟動

1. 依專案擁有者提供的方式安裝指定 build。
2. 記錄 build、commit、iPad 型號與 iPadOS 版本。
3. 首次開啟後，確認畫面有明確的空狀態與「加入來源」入口。
4. 若系統要求信任、檔案存取或提供者授權，只授予本次測試必要的權限。

## 建議測試順序

1. 加入 APFS 來源並等待索引完成。
2. 加入 exFAT 來源並等待索引完成。
3. 加入檔案提供者來源並確認可重新授權。
4. 在合併圖庫中測試搜尋、排序、切換資料夾與回到編輯器後的位置保存。
5. 開啟 Sony `.ARW`，依序測試 Exposure、Contrast、Highlights、Shadows、Whites、Blacks、Temperature、Tint、Vibrance 與 Saturation。
6. 等待自動儲存完成後關閉 App，再重新開啟同一張照片確認編輯仍存在。
7. 拔除外接來源，確認離線狀態；重新接回並選擇正確資料夾完成 relink。
8. 測試移除來源，確認 App 只移除索引／授權，不刪除 RAW 原檔。
9. 依 `REAL_DEVICE_CHECKLIST.md` 記錄每一項結果。

## 等待、錯誤與離線狀態

- 掃描、開圖、產生預覽、套用編輯或重新連結需要時間時，畫面應顯示 loading／進度或可理解的等待狀態。
- 同一動作不得因重複點擊而重複啟動；若可取消，取消後必須回到可操作狀態。
- 權限不足、來源離線、提供者需要重新授權或格式無法開啟時，應顯示原因與可執行的下一步。
- 若畫面持續無反應、loading 不會結束、照片顯示錯誤或 App 閃退，該項記為 `FAIL`。

## 結果定義

- `PASS`：實際完成並符合預期。
- `FAIL`：已執行，但結果不符合預期或無法完成。
- `SKIPPED`：測試流程主動略過；必須寫明原因，不得算通過。
- `NOT RUN`：尚未執行；不得算通過。

## 回報方式

發現問題時，複製 `BUG_REPORT_TEMPLATE.md`，填入可重現步驟、預期／實際結果、來源類型、build、裝置環境與去識別化證據。不要附上 Apple 憑證、帳號、完整本機路徑、真實檔名或未經授權的 RAW 原檔。
```

---

### Task 3: Write the real-device checklist

**Files:**
- Create: `docs/testing/beta/REAL_DEVICE_CHECKLIST.md`

- [ ] **Step 1: Create the checklist with explicit evidence states**

```markdown
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
```

---

### Task 4: Write the bug-report and privacy contracts

**Files:**
- Create: `docs/testing/beta/BUG_REPORT_TEMPLATE.md`
- Create: `docs/testing/beta/PRIVACY.md`

- [ ] **Step 1: Create the bug-report template**

```markdown
# LumaHarborPad Beta 問題回報

## 摘要

- 標題：
- 嚴重度：Blocker／High／Medium／Low
- 首次發生日期／時間：
- 是否可穩定重現：是／否／偶發

## Build 與環境

- Build：
- Commit（完整 SHA）：
- iPad 型號：
- iPadOS：
- 畫面模式：全螢幕／Split View／Stage Manager
- 來源類型：APFS／exFAT／檔案提供者／其他
- 網路狀態：線上／離線／不適用

## 重現步驟

1.
2.
3.

## 預期結果


## 實際結果


## 頻率與影響

- 發生頻率：
- 是否阻擋繼續測試：
- 是否造成閃退、資料遺失或錯誤編輯：

## 原檔完整性

- RAW 原檔 checksum 是否改變：是／否／未檢查
- RAW 原檔大小是否改變：是／否／未檢查
- 是否發生重新命名、移動、覆寫或刪除：是／否／未檢查

## 證據

- 截圖／錄影代號：
- 去識別化 log 代號：
- 相關 checklist ID：

## 隱私確認

- [ ] 未包含 Apple ID、Team ID、UDID、憑證或 provisioning profile。
- [ ] 未包含真實使用者名稱、完整本機路徑、磁碟名稱或提供者帳號。
- [ ] 未附上未經授權的 RAW 原檔。
- [ ] 截圖與 log 已依 `PRIVACY.md` 去識別化。
```

- [ ] **Step 2: Create the privacy rules**

```markdown
# LumaHarborPad Beta 隱私與證據處理規則

## 原則

只收集重現問題與判斷結果所需的最少資料。測試文件、issue、聊天與 commit 不得成為私人照片、帳號資訊或簽署秘密的保存位置。

## 可以記錄

- App build 與完整 commit SHA。
- iPad 型號、iPadOS 與畫面模式。
- 來源類型，例如 APFS、exFAT 或檔案提供者。
- 去識別化的測試代號、時間、checklist ID 與錯誤訊息摘要。
- 不含私人內容的裁切截圖或螢幕錄影。
- RAW 原檔 checksum 是否改變的結果；不必公開原始檔。

## 禁止記錄或提交

- Apple ID、Team ID、UDID、序號、憑證、私鑰、密碼、token、provisioning profile。
- 真實使用者名稱、完整本機路徑、掛載名稱、提供者帳號或可識別的私人資料夾名稱。
- 未經授權的 RAW、JPEG、縮圖、sidecar 或照片中繼資料。
- 含有私人路徑或帳號資訊的完整 log。
- 任何為了方便而複製進 Git 的測試照片或簽署檔案。

## 去識別化方式

- 來源以 `APFS-A`、`EXFAT-A`、`PROVIDER-A` 等代號表示。
- 照片以 `RAW-001` 等代號表示，不寫真實檔名。
- 本機與暫存位置只描述為「測試工作目錄」或「外接來源」，不保留完整路徑。
- 截圖先裁掉帳號、裝置識別、路徑、照片內容與通知。
- log 只摘錄必要錯誤段落，並再次檢查是否含私人字串。

## RAW 與原檔完整性

- 只使用測試者有權使用的 Sony `.ARW`。
- App 的編輯應保存為非破壞式狀態，不得修改 RAW 原檔。
- 若 checksum、檔案大小、名稱或位置非預期改變，立即停止 RC 驗測並回報 Blocker。

## 簽署與散布

- Apple 帳號、憑證與 provisioning 只由專案擁有者在受控環境操作。
- 測試者只取得已簽署 build 與必要安裝說明，不取得簽署秘密。
- Beta build 不得轉傳給未列入測試範圍的人員。

## 保存與刪除

- 只保存仍需追蹤的去識別化證據。
- 問題結案後，依專案擁有者的保存政策移除不再需要的截圖、錄影與 log。
- 刪除本機證據時使用可復原方式；永久刪除需先確認明確目標。
```

---

### Task 5: Write the RC decision checklist

**Files:**
- Create: `docs/testing/beta/RC_CHECKLIST.md`

- [ ] **Step 1: Create the gate checklist**

```markdown
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
```

---

### Task 6: Validate scope, language, and privacy, then commit

**Files:**
- Verify: all five files under `docs/testing/beta/`

- [ ] **Step 1: Verify the file boundary**

Run:

```bash
git status --short
git diff --name-only
```

Expected untracked or modified paths are exactly the five assigned files. If any other path appears, stop and report it without deleting or reverting user work.

- [ ] **Step 2: Verify required concepts and status vocabulary**

Run:

```bash
rg -n 'PASS|FAIL|SKIPPED|NOT RUN' docs/testing/beta
rg -n 'APFS|exFAT|檔案提供者|Sony.*ARW|relink|loading|Split View|Stage Manager' docs/testing/beta
rg -n 'checksum|非破壞|不刪除|重新授權' docs/testing/beta
```

Expected: all commands find the concepts in the appropriate files.

- [ ] **Step 3: Run placeholder, privacy, and whitespace checks**

Run:

```bash
if rg -n 'TBD|TODO|FIXME|/Users/|/Volumes/|/private/' docs/testing/beta; then
  print -u2 -- 'Unexpected placeholder or private path in Beta Test Kit'
  exit 1
fi
git diff --check -- docs/testing/beta
```

Expected: both checks exit 0 with no output.

- [ ] **Step 4: Self-review the documents as a first-time tester**

Confirm manually:

- A tester can tell what hardware, sources, and build are required.
- Every real-device gate has a result field and evidence field.
- Removing a source is explicitly non-destructive.
- Waiting, offline, relink, reauthorization, and error recovery are testable.
- RAW integrity is checked after editing.
- The RC decision cannot pass with `FAIL`, `SKIPPED`, or `NOT RUN`.
- No document claims final release or App Store approval.

- [ ] **Step 5: Stage only the five files and commit**

Run:

```bash
git add \
  docs/testing/beta/TESTER_GUIDE.md \
  docs/testing/beta/REAL_DEVICE_CHECKLIST.md \
  docs/testing/beta/BUG_REPORT_TEMPLATE.md \
  docs/testing/beta/PRIVACY.md \
  docs/testing/beta/RC_CHECKLIST.md
git diff --cached --name-only
git diff --cached --check
git commit -m "docs: add iPad beta test kit"
git rev-parse HEAD
git status --short --branch
```

Expected:

- Commit contains exactly the five files.
- Worktree is clean after the commit.
- No push, merge, rebase, cherry-pick, signing change, or code change occurred.

## Stop Boundary

Stop after Task 6. Return the full commit SHA, changed-file list, validation results, and any concern. Do not start the separate review of Codex's RAW fixture baseline until a later handoff supplies the exact Codex commit SHA and a new bounded review task.
