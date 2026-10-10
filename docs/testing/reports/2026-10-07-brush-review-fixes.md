# 筆刷驗收工具審查修正與收尾

日期：2026-10-07。狀態：`DONE_WITH_CONCERNS`。

## 範圍與版本

- 延續 `codex/brush-performance-acceptance-repair`；本輪起始 HEAD：`6fd3d416d64093fb1ab9609497633915fe6702f9`，起始工作樹乾淨。
- 核心實作 SHA：`c9196b64826edb943da558b889af0d9c3c591ae1`；Gemini minor follow-up 與最新驗證程式 SHA：`b921082bcbb08906c1b8ad709b2abd6ec9ee812a`。
- 單一 writer：Codex root。原派給 Luna 的代理因 `Your workspace is out of credits. Add credits to continue.` 中止，沒有留下變更；root 接手完成。
- 修改兩個 analyzer、兩個 Python 測試檔、RAW／Export Swift harness 與 JSON schema；`Sources/`、效能門檻與原始樣本未更動。

## Finding 處置

| Finding | 本輪處置 | 狀態 |
| --- | --- | --- |
| P2：縮小影像仍通過資料驗證 | Synthetic 三種尺寸必須 1600×1067；RAW preview 長邊恰為 1600、短邊比例容許 1 pixel rounding，native 必須更大；跨 B/O／組別尺寸與方向一致。Synthetic export 限定 6000×4000 | 已修正與測試 |
| P2：bool／float 整數欄位與 compound 欄位誤判或崩潰 | 在分組前驗證型別，只讓有效 record 進統計；不合法輸入輸出 FAIL artifact，不產生 PASS gate；非有限或不可轉換數值拒絕 | 已修正與測試 |
| P2：context 常數被當成觀測 | Harness 改 v3、expectedContextCreationCount* 與 declared-from-construction-path；analyzer 支援歷史 v2，但兩版都附未實測限制，拒絕混用版本與 v3 舊欄位 | 宣告語意已釐清；runtime allocations 未量測 |
| P3：checksum／版本歸因錯誤 | README checksum 依既有檔案更正；e7d6425 契約修正、4fdbc1f scenario mapping／RAW 執行 HEAD 分開記錄 | 已更正 |

Gemini 提出 context 問題；尺寸、型別與文件錯誤由 Codex 本地覆核發現。Gemini 對樣本數總量及全面 fail-closed 的說法未採用；RAW changed 的 exposure 差異未證明構成目前 gate 缺陷。其後 Gemini 3.8 Flash High 對修正差異完成非原作者唯讀覆核，詳見[最終覆核報告](2026-10-07-brush-gemini-final-review.md)。

## 驗證

| 命令／檢查 | 結果 |
| --- | --- |
| RED：`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Scripts/tests -p 'test_analyze_brush_*.py'` | 34 tests；38 個 subtest failures、1 error；確認新反例會擊中舊行為。測試程式失敗；外層輸出摘要命令 exit 0，不混同為測試通過 |
| GREEN：`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Scripts/tests -p 'test_analyze_*.py'` | exit 0；34 tests、0 skip、0 failures |
| `swift test -c release --filter BrushRawExportABBAHarnessTests` | exit 0；XCTest 2 tests、1 opt-in skipped、0 failures；實際非跳過 1 test。標準 Release、沒有額外 DEBUG defines |
| 既有 480／352 samples 以修正 analyzer 重算 | 兩者 exit 0、validation PASS；summaries/gates 與原資料完全相同 |
| `git diff --check` | exit 0 |

Swift 編譯仍有既有 `BatchExportQueueTests.swift` 的 Swift 6 captured-var warnings；本輪未修改該檔案。沒有把 optional benchmark skip 當作新量測 PASS。

[重算 artifact、完整命令與 checksums](../evidence/2026-10-07-brush-review-fixes/README.md)。Synthetic 56 PASS／4 FAIL／7 NOT RUN；RAW／Export 17 PASS／3 FAIL。RAW 新輸出只增加 context 限制 metadata，歷史 v2 JSONL/gates 沒有覆寫。

## 尚未結案的範圍

- 本輪修正後非原作者覆核：`APPROVED`；無 blocking finding，兩個 minor 已修正並重驗。
- 新 schema v3 真實 workload 量測：`NOT RUN`；已驗證編譯與 v3 analyzer fixtures，沒有宣稱得到新效能數據。
- 完整產品 B→O 獨立審查、公平 stage coverage、Mac／實體 iPad／Pencil／鍵盤／VoiceOver／heartbeat／灰卡：仍待完成。
- 四個 synthetic stress 與三個 warm RAW 效能 FAIL 保留；不放寬門檻、不宣稱 READY。
- 本輪未跑完整 Debug／Release、GUI、build matrix 或重新量測效能；沒有 push、merge、rebase、安裝或發布。

## 下一步

本輪四類 finding 修正與 reviewer gate 已完成。下一步回到原計畫 Task 5 的公平 B/O stage 與產品／人工驗收；效能優化另行規劃。
