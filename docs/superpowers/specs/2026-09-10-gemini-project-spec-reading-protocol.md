# Gemini 專案規格讀取與交接協定

- 狀態：可直接使用，僅定義讀取、核對與回報流程
- 日期：2026-09-10
- 適用專案：LumaHarbor
- 適用代理：Gemini 或任何沒有本次對話上下文的唯讀審查代理
- Issue 策略：只使用專案內的 spec、plan、report 與 coordination 文件，不建立 GitHub Epic 或 Issue

## 1. 目的

Gemini 每次進入專案時，必須能從檔案與 Git 狀態重建可靠上下文，回答三件事：

1. 目前產品基準是哪個分支與完整 HEAD SHA。
2. 哪些功能已實作、哪些只有規格、哪些已驗測、哪些仍是 `NOT RUN`。
3. 下一個可以執行的單一工作是什麼，以及它依賴哪些規格與驗收證據。

本協定解決的問題是「只讀到某一份 Claude spec 就誤以為整個產品完成」。Gemini 必須讀取規格家族、目前狀態與驗測報告的交集，才可提出結論。

## 2. 讀取權限與禁止事項

Gemini 的預設角色是唯讀審查與交接整理：

- 可以讀取 Git 狀態、spec、plan、report、handoff、原始碼與測試。
- 未收到明確的「開始實作」指示前，不得修改原始碼、測試、設定或文件。
- 不得建立 GitHub Issue、Epic、PR、branch、worktree 或發布產物。
- 不得讀取或輸出 `.codex/`、`.claude/`、認證檔、金鑰、provisioning、bookmark data、UDID 或內部快取。
- 不得把本機絕對路徑、帳號名稱、掛載點、fixture 私有位置或 Team ID 寫入報告。
- 不得把 `CURRENT.md` 的舊內容當成比目前 Git 狀態更可靠的證據；若兩者衝突，標記 `BLOCKED` 並停止提出修改建議。

## 3. 必讀順序

每次都從專案根目錄開始，依序完成以下讀取。不要跳到原始碼後才補讀規格。

### 3.1 Git 身分與工作樹

```sh
git rev-parse --show-toplevel
git branch --show-current
git rev-parse HEAD
git status --short --branch
git log --oneline -8
```

記錄 branch、完整 HEAD、工作樹是否乾淨，以及是否存在別的代理或使用者未提交變更。只要 `status` 與 `CURRENT.md` 的 dirty files 不一致，就先停在 `NEEDS_CONTEXT`。

### 3.2 共用規則

依序讀：

1. `AGENTS.md`
2. `CLAUDE.md`（確認它只匯入 `AGENTS.md`，不把它當成第二套規則）
3. `docs/coordination/CURRENT.md`
4. `docs/coordination/DECISIONS.md`

`AGENTS.md` 是代理協作規則；`CURRENT.md` 是目前基準與待辦；`DECISIONS.md` 是已定案的架構取捨。Gemini 不得默默推翻其中任何一項，若要建議反轉，必須明確列出原決定與理由。

### 3.3 正式規格索引

先列出完整檔案，不可只挑檔名含 Gemini 的文件：

```sh
rg --files docs/superpowers/specs docs/testing | sort
```

目前 LumaHarbor 的規格分層如下：

| 層級 | 主要文件 | 用途 |
| --- | --- | --- |
| 產品基線 | `docs/superpowers/specs/2026-08-13-mac-first-mvp-design.md` | Mac-first MVP、資料安全與平台邊界 |
| 核心資料與掃描 | `2026-08-14-lossless-bounded-scan-pipeline.md`、`2026-08-14-thumbnail-scan-cancellation-hardening.md` | RAW、索引、取消與來源安全 |
| 跨平台調整 | `2026-08-19-adjustment-engine-expansion-design.md`、`2026-08-24-cross-platform-adjustments-design.md` | 調整模型、渲染與 Mac/iPad 共用語意 |
| iPad 圖庫與 UI | `2026-08-26-ipad-multi-source-photo-library-design.md`、`2026-08-30-ipad-ui-ux-state-contract.md`、`2026-09-08-ipad-m-series-ui-ux-optimization-design.md`、`2026-09-09-ipad-studio-rails-mac-feature-parity-design.md` | 來源、工作區、觸控與 Mac 功能對齊 |
| XMP／Preset | `2026-08-21-preset-xmp-compatibility-design.md`、`2026-08-21-photo-xmp-migration-phase2.md` | 匯入、匯出、相容與資料遷移 |
| 發布與測試 | `2026-08-15-mac-first-mvp-acceptance-plan.md`、`2026-08-31-beta-validation-work-allocation-design.md`、`2026-09-07-app-icon-distribution-usage-design.md` | Alpha、Mac ZIP、iPad 安裝與驗收邊界 |
| 目前總規格 | `docs/superpowers/specs/2026-09-10-professional-editing-completion-design.md` | P0-P7 完整專業修圖路線與不可回歸項目 |
| 本協定 | 本文件 | Gemini 的讀取與回報格式 |

日期較新的文件不會自動取代日期較舊的文件。只有文件內明寫「取代範圍」或 `CURRENT.md` 指定的目前規格，才可視為取代；其餘是補充或相依規格。

### 3.4 執行計畫與交接

依目前 `CURRENT.md` 的 Next action，只讀取該階段的 plan、handoff 與 report。例如目前 P0/P1 相關檔案為：

- `docs/superpowers/plans/2026-09-10-curation-sidecar-v3-and-migration.md`
- `docs/coordination/2026-09-10-p0-p1-curation-sidecar-v3-handoff.md`
- `docs/testing/reports/2026-09-09-professional-editing-phase1.md`

若 Next action 指向另一階段，改讀該階段的文件；不要把所有歷史 report 當成目前完成證明。

### 3.5 程式碼與測試核對

文件讀完後，才用 `rg` 依 spec 內的檔案參考與符號核對目前程式碼。每個結論都要能指向：

- 一個規格段落，說明應有行為。
- 一個目前檔案或測試，說明實際行為。
- 一個命令或報告，說明驗證狀態。

只看到 model 或 UI 字串，不代表功能已接到渲染、sidecar、undo、batch、export 與兩個平台。

## 4. 來源優先順序

遇到矛盾時，按以下順序判斷：

1. 使用者本次明確指示。
2. `AGENTS.md` 的安全、協作與 Git 規則。
3. 目前工作樹中實際可重現的程式碼與測試結果。
4. 已核准的產品 spec。
5. implementation plan。
6. `CURRENT.md`、handoff 與 report 中的歷史摘要。

第 3 項若與第 4 至 6 項矛盾，不得直接改文件迎合程式碼；應報告「文件漂移」，列出檔案、行為與需要補做的驗證。

## 5. 狀態標籤

Gemini 的矩陣只能使用下列標籤：

| 標籤 | 定義 |
| --- | --- |
| `IMPLEMENTED` | 程式碼已存在，且沒有證據顯示只做了假 UI 或半套流程 |
| `PASS` | 指定命令或人工 gate 有可追溯的成功證據 |
| `FAIL` | 指定命令明確失敗，需列出測試名稱或錯誤摘要 |
| `SKIPPED` | 測試框架明確標記 skip，需說明原因 |
| `NOT RUN` | 需要的命令、真機、素材或人工步驟尚未執行 |
| `SPEC ONLY` | 只有 spec/plan，沒有可驗證的實作證據 |
| `NEEDS_CONTEXT` | branch、dirty files、HEAD 或文件互相矛盾，不能安全判斷 |

`PASS` 不可由 `IMPLEMENTED` 推導；`NOT RUN` 也不可寫成「應該可以」。

## 6. 目前總規格的讀法

`2026-09-10-professional-editing-completion-design.md` 的 P0-P7 是範圍路線，不是單一版本已完成清單。Gemini 必須逐項讀取該文件的 phase table、dependency graph、不可回歸項目與 definition of done，再以 `CURRENT.md` 對照：

- P0：基準保護測試。
- P1：Portable curation、PhotoSidecar v3、SQLite projection 與 migration。
- P2：共用 Professional Inspector Catalog。
- P3：真正獨立的 Composite／R／G／B Tone Curve。
- P4：Lens Correction、Color Grading、Presence、Black & White 與 Profile。
- P5：Brush、Radial、Range、Subject／Background mask 與裝置端 AI。
- P6：Snapshot、A/B、clipping/gamut、Soft Proof 與比較流程。
- P7：Mac／iPad 自動化、視覺、真機、效能、資料耐久與發布驗收。

不得因 P0/P1 已完成就宣稱 P2-P7 完成。每個 phase 都要分開列出實作與驗測狀態。

## 7. Gemini 啟動提示詞

以下內容可以直接交給 Gemini。它是讀取任務，不是實作授權：

```text
你正在審查 LumaHarbor，請先以唯讀模式讀取專案，不要修改任何檔案，不要建立 Issue、PR、branch 或 worktree。

請嚴格依序讀取：
1. AGENTS.md、CLAUDE.md
2. docs/coordination/CURRENT.md、docs/coordination/DECISIONS.md
3. AGENTS.md 的 Canonical project artifacts
4. CURRENT.md 的 Next action 所指向的 spec、plan、handoff、report
5. 最後才讀相關原始碼與測試

開始前執行並回報：git branch --show-current、git rev-parse HEAD、git status --short --branch、git log --oneline -8。
若 Git 狀態與 CURRENT.md 不一致，停止並回報 NEEDS_CONTEXT，不要自行修正。

請輸出：
- Reading scope：實際讀過的相對路徑
- Baseline：branch、完整 HEAD、dirty files
- Status matrix：每個 P0-P7 的 IMPLEMENTED / SPEC ONLY 與 PASS / FAIL / SKIPPED / NOT RUN
- Verified findings：每項附 spec 段落、程式或測試檔案、命令或 report 證據
- Risks and blockers：只列可證明的問題，包含文件漂移與未驗收 gate
- One next action：只選一個有依賴關係與檔案範圍的下一步
- Handoff：給下一個代理的 5-10 行摘要

不得輸出任何私人絕對路徑、帳號、金鑰、Team ID、UDID、bookmark data 或私有 fixture 位置。使用 PASS、FAIL、SKIPPED、NOT RUN、SPEC ONLY、NEEDS_CONTEXT，不要用「大致完成」或「應該沒問題」。
```

## 8. 回報格式

Gemini 的最終回報至少包含以下表格：

| Phase | 實作狀態 | 自動驗測 | 人工／真機驗收 | 證據 |
| --- | --- | --- | --- | --- |
| P0 | `IMPLEMENTED` / `SPEC ONLY` | `PASS` / `FAIL` / `NOT RUN` | `NOT RUN` 或實際結果 | 相對路徑與命令 |

回報結尾固定使用下列其中一種狀態：

- `DONE`：本次唯讀核對完成，沒有未揭露的阻塞。
- `DONE_WITH_CONCERNS`：核對完成，但仍有明確 `FAIL` 或 `NOT RUN`。
- `NEEDS_CONTEXT`：Git、文件或工作樹不一致，不能安全判定。

## 9. 驗收標準

本協定完成的判定是可重複的讀取行為，而不是文件長度：

1. Gemini 能在沒有本次對話記憶時找到 `AGENTS.md`、`CURRENT.md`、`DECISIONS.md` 與目前總規格。
2. Gemini 能回報目前 branch、完整 HEAD 與 dirty files，且能發現與 `CURRENT.md` 的差異。
3. Gemini 能把 P0-P7 分開標記，不把 spec-only、實作完成與驗測通過混成一個狀態。
4. Gemini 能指出目前 Next action 對應的唯一 plan、handoff、report 與檔案範圍。
5. Gemini 的回報不含私人絕對路徑、憑證、帳號、Team ID、UDID 或私有 fixture 位置。
6. Gemini 在未收到明確實作授權時不修改工作樹、不建立 Issue，並輸出 `DONE`、`DONE_WITH_CONCERNS` 或 `NEEDS_CONTEXT` 之一。

## 10. 不在本協定範圍

- Gemini 自動實作 P2-P7。
- Gemini 替 Claude 或 Codex 合併、推送、發布或簽章。
- 重新定義產品功能、資料 schema 或 UI/UX 決策。
- 以網路搜尋結果取代本機 spec、程式碼與測試證據。
