# iPad RAW 編輯垂直切片驗收報告

> 安全提醒：本報告只記錄安全代號、雜湊與檔案系統類型，不含使用者本機的完整私人路徑；私人 `.ARW` 檔案本身不進入 Git。

## 0. 摘要

| 項目 | 內容 |
|---|---|
| 對應計畫 | `docs/superpowers/plans/2026-08-24-ipad-raw-editing-vertical-slice.md`（Task 8） |
| 驗收日期 | 2026-08-25（自動驗收於 2026-08-25 兩個階段完成：初次執行發現驗收基礎設施缺陷，修復後重新執行為最終結果） |
| 基準 commit | `114b1f669f91968137d8519ef4b71b819f277444`（`main`，即 Task 7 合併後的 HEAD） |
| Runner | `Scripts/run-ipad-vertical-slice-acceptance.zsh` |
| 自動驗收整體結論 | ☑ PASS（strict-concurrency build／swift test／iOS Simulator build／MVP preflight／MVP acceptance 五步驟全綠，見 §3） |
| 實機五項 gate | 全部 NOT RUN（沒有可用的真實 M1+ iPad，見 §6） |
| Task 8 Completion Gate | 尚未完成——自動驗收已 PASS，但仍缺真實 iPad 五項 gate（見 §6） |

## 1. 硬體與作業系統

| 項目 | 指令 | 結果 |
|---|---|---|
| 硬體型號 | `system_profiler SPHardwareDataType` | Mac mini（Mac16,10），Apple M4，32 GB |
| `uname -m` | `uname -m` | `arm64` |
| macOS 版本 | `sw_vers` | ProductVersion 26.6.2，Build 25G82 |

## 2. Xcode 與 Swift 工具鏈

| 項目 | 指令 | 結果 |
|---|---|---|
| Xcode 版本 | `xcodebuild -version` | Xcode 26.6，Build 17F113 |
| `xcode-select -p` | `xcode-select -p` | `/Applications/Xcode.app/Contents/Developer` |

## 3. 自動驗收（`Scripts/run-ipad-vertical-slice-acceptance.zsh`）

最新一次真實執行（三個 fixture 環境變數皆已匯出、exFAT 隨身碟已掛載）的 summary 相對路徑：

```
.build/ipad-vertical-slice/20260825T174535Z-86090-2136186817170/summary.md
```

（此次 run 的 summary 記錄 `Commit: 0dde97112bed216fa2492d8590be6dd19a73876c`——即 §5.4 修正完成前的 HEAD，因為這次真實驗收是在修正 commit `52b88f4` 落地**之前**、對照著仍在工作目錄中的修改跑的，用來驗證修正本身；`Repo state` 一項仍正確回報 PASS，因為 runner 全程沒有再變動 working tree。§5.4 的架構修正本身不影響任何 Task 8 產品程式碼或這五個步驟的實際行為，因此沒有必要在 commit 落地後重新執行一次數十分鐘的完整編譯鏈；目錄名稱格式沿用 timestamp+PID+random，見 §5.2 finding 5。）

摘要內容：

| 步驟 | 結果 |
|---|---|
| strict-concurrency build | PASS |
| swift test | PASS（executed=826, skipped=0, failures=0） |
| iOS Simulator build | PASS |
| MVP preflight | PASS |
| MVP acceptance | PASS |
| 隱私掃描（summary／全部 log 是否殘留私人絕對路徑） | PASS |
| **Overall result** | **PASS** |

### 3.1 已修復的驗收基礎設施問題（歷史紀錄，非目前限制）

本報告最初於 2026-08-25 稍早完成的第一次自動驗收中，`MVP acceptance` 步驟回報 **FAIL**。根因**不是**本 runner 的邏輯錯誤，也**不是** Task 1–7 交付的產品程式碼有 regression：既有 `Scripts/run-mvp-acceptance.zsh` 對 `RawFixtureTests` 步驟寫死呼叫 `evaluate_xctest_log "$RAWFIXTURE_LOG" 8`，要求「必須剛好執行 8 個測試」；但 `Tests/LumaHarborIntegrationTests/RawFixtureTests.swift` 當時已有 9 個案例（`testWhiteBalanceOffsetChangesTheRender` 是先前加入白平衡調整功能時新增，未同步更新這個寫死數字）。當時的完整證據（已遮蔽的 log 第 1898–1926 行）：

```
Test Suite 'RawFixtureTests' passed at 2026-08-25 21:09:53.307.
	 Executed 9 tests, with 0 failures (0 unexpected) in 6.964 (6.964) seconds
Test Suite 'LumaHarborPackageTests.xctest' passed at 2026-08-25 21:09:53.307.
	 Executed 9 tests, with 0 failures (0 unexpected) in 6.964 (6.965) seconds
Test Suite 'Selected tests' passed at 2026-08-25 21:09:53.307.
	 Executed 9 tests, with 0 failures (0 unexpected) in 6.964 (6.965) seconds
RawFixtureTests: command completed
RawFixtureTests: FAIL (executed 9 tests, expected exactly 8)
```

全部 9 個 `RawFixtureTests` 案例**當時就已經真的通過，0 failures**；問題純粹是驗收基礎設施的期望數量過期，不是任何 RAW 解碼、匯出或 Metal 渲染的 regression。

**修復方式**：在 `Scripts/run-mvp-acceptance.zsh` 加入具名常數 `RAWFIXTURE_EXPECTED_TEST_COUNT=9`（取代原本的裸數字 `8`），並在常數旁加註解，說明其對應 `RawFixtureTests.swift` 目前核准的 9 個測試方法名稱，且要求日後新增／移除 `RawFixtureTests` 案例時必須在同一 commit 同步更新這個常數與 `docs/testing/mvp-acceptance-report-template.md`。**刻意沒有改成動態計數**——固定的人工核准基準，才能確保測試意外消失或被跳過時這道 gate 仍會失敗，而不是悄悄跟著新的（可能更少的）數字自動通過。修復後 `evaluate_xctest_log` 的 under／exact／over 三種情境都在 runner self-test 中以這個新常數重新驗證，並以真實三個 fixture 目錄重跑整條驗收鏈，取得 §3 目前記錄的 PASS 結果。

修復本身不在 Task 8 原始授權範圍內（`Scripts/run-mvp-acceptance.zsh` 當時不在可修改清單），已取得使用者明確授權後才進行，並以獨立 commit 提交（見 commit 訊息）。

### 3.2 五個步驟的真實通過證據

- `strict-concurrency build`：`swift build -Xswiftc -strict-concurrency=complete` 於本機重複驗證（獨立執行一次、runner 內一次），皆 `Build complete`，無新增 strict-concurrency 錯誤。
- `swift test`：826 個測試全部通過，0 failures，0 skipped（三個 fixture 環境變數皆已匯出，`RawFixtureTests` 的 9 個案例作為 `swift test` 整套測試的一部分一併真實執行，非略過）。
- `iOS Simulator build`：`(cd Apps/LumaHarborPad.swiftpm && xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build)` 顯示 `** BUILD SUCCEEDED **`，產出真正的 iOS Simulator `.app`（非單純 library target 編譯）。
- `MVP preflight`：`Scripts/run-mvp-acceptance.zsh --preflight-only` 確認 arm64、完整 Xcode、`xcodebuild`／`swift` 可用，以及三個 fixture 目錄（RAW／APFS／exFAT）皆存在且檔案系統類型正確。
- `MVP acceptance`：`Scripts/run-mvp-acceptance.zsh` 完整跑一輪 strict-concurrency build → full swift test → `RawFixtureTests`（9/9，0 failures），Overall result PASS。

## 4. Fixture 與測試目錄識別（不含私人絕對路徑）

| 項目 | 值 |
|---|---|
| RAW fixture 相機型號 | Sony ILCE-6400（α6400），鏡頭 Sony E 16-300mm F3.5-6.7（由 `mdls` 讀出的 Spotlight metadata 確認） |
| RAW fixture 檔案數 | 81 個 `.ARW` |
| APFS 測試目錄檔案系統 | apfs（本機開機磁碟區的資料卷） |
| exFAT 測試目錄檔案系統 | exfat（外接隨身碟，磁碟區名稱 `Untitled`） |

## 5. Runner 本身的驗證

| 檢查 | 結果 |
|---|---|
| `zsh -n Scripts/run-ipad-vertical-slice-acceptance.zsh` | 通過，無語法錯誤 |
| `zsh -n Scripts/run-mvp-acceptance.zsh` | 通過，無語法錯誤 |
| `git diff --check` | 通過，無空白字元問題 |
| `Scripts/run-ipad-vertical-slice-acceptance.zsh __selftest` | 連續 10 次前景執行全部通過，每次結束後皆確認無殘留子程序 |
| `Scripts/run-mvp-acceptance.zsh` self-test（`LUMAHARBOR_RUNNER_SELFTEST=1`，含真實 signal tier） | 全部通過，含新的 under／exact／over 基準情境 |
| summary／全部 log 隱私掃描（grep `/Users/`、`/Volumes/`、`/private/var/`、`/private/tmp/`、`/var/`、`/tmp/`，以及 repo root／`$HOME`／三個 fixture 目錄的實際字串，見 §5.4 finding 3、4） | 通過，無殘留 |

### 5.1 Runner self-test 的第二輪修復（歷史紀錄，非目前限制）

第一輪修復（§3.1）完成後，`Scripts/run-ipad-vertical-slice-acceptance.zsh` 的 self-test 曾間歇性暴露兩個真實問題，已找到根因並修復：

1. **exit 141（SIGPIPE）導致 fail-fast 中途中斷**：`finalize_run` 原本用 `xcodebuild -version 2>/dev/null | head -n1` 取 Xcode 版本第一行；`head -n1` 讀滿一行就提早關閉讀取端，`xcodebuild` 仍在寫第二行時可能收到 SIGPIPE，在 `set -o pipefail` 下讓整條 pipeline 的結束碼變成 141，`set -e` 因此把它當成這一行失敗，整個 runner 在 `finalize_run` 執行到一半就意外中止——這正是「一般非 signal 失敗偶爾回傳 141 而非 1」的根本原因。修法：先完整取得 `xcodebuild -version` 的全部輸出（無 pipe，不會有任何一端提早關閉），再用 parameter expansion（`${xcode_version_output%%$'\n'*}`）取第一行，全篇搜尋確認這是唯一會在 `pipefail` 下產生非預期結束碼的 pipeline。
2. **TERM 中斷時 descendant 可能存活**：原本的 timeout／signal 清理邏輯會對同一個 root PID 呼叫兩次 `pgrep -P` 為基礎的子行程收集（一次送 TERM、等待後再收集一次送 KILL）；root 行程一旦先於其子行程結束，它的子行程會被 reparent（通常轉給 launchd），第二次以 root PID 為起點重新掃描就再也找不到它們，導致存活的 grandchild 逃過 KILL。修法：把收集（`collect_descendant_pids`）與送信號（`signal_pid_list`）拆開，只在送出第一個信號「之前」做一次完整的 PID 快照，TERM 與後續 KILL 都重複使用同一份快照，並改成由最深層 descendant 開始、root 最後才送信號。同時把 `run_with_timeout` 內原本用來即時鏡射 log 到終端機的背景 `tail -f` 整個移除——它是另一個「INT／TERM／HUP 剛好在錯的時間點打進來就可能殘留」的背景 PID 來源；現在每個步驟的輸出只寫進 log 檔，步驟結束後由呼叫端印出該步驟自己的 PASS／FAIL 一行。
3. **同時重寫 signal self-test 的中斷目標**：原本用裸的 `sleep 3` 當作步驟的替身指令，靠「等 log 檔出現」判斷已經開始執行、靠 `pgrep -f '^sleep 3$'` 這種名稱比對判斷有沒有殘留，兩者都有時序上的競態、也可能誤判其他程序。改成專用、確定性的兩層 helper：root helper 先把自己的 PID 寫進 pidfile，再啟動一個真正的 grandchild、等 grandchild 把自己的 PID 也寫進另一個 pidfile 且 `kill -0` 確認存活後，才 touch 一個 ready file；self-test 只等這個 ready file（不是猜固定秒數），確認就緒後才送出真正的 OS signal，事後也是直接用兩個 pidfile 內記錄的精確 PID 做「行程是否還在」的斷言，不再依賴名稱比對。

修復後 `LUMAHARBOR_IPAD_RUNNER_SELFTEST=1 Scripts/run-ipad-vertical-slice-acceptance.zsh` 在前景連續執行 10 次，每次都是 Overall PASS、exit 0，且每次結束後對 `interrupt-root`／`interrupt-child`／`fail-with-7`／`fake-swifttest`／runner 本身的精確程序檢查都確認無殘留。

### 5.2 Runner 的 pre-landing review 修正（本輪：runner 修正，非產品程式碼）

第二輪修復（§5.1）合併後，Codex 對 `Scripts/run-ipad-vertical-slice-acceptance.zsh` 做了一次完整的 pre-landing review，找出 7 項既有缺陷，每項都補了新的、確定性的 self-test 案例：

1. **`handle_terminating_signal` 在 `CURRENT_STEP_KEY` 為空時未設定 `overall_ok=0`**：訊號若發生在 preflight、兩個步驟之間，或 `finalize_run` 執行期間，先前可能出現所有步驟 SKIPPED、Overall 卻是 PASS。修法雙管齊下：handler 一進入就無條件設 `overall_ok=0`；`Overall result` 改成從 `STEP_STATE` 現場重新推導（每個必要步驟都必須確實讀到 `PASS`），不再只信任外部旗標。新增「訊號打在兩個步驟之間」與「訊號打在 `finalize_run` 執行中」兩個 self-test 案例。
2. **`finalize_run` 無條件呼叫 `xcodebuild -version`**：`xcodebuild` 不存在或回傳非零時，先前會在 `set -e` 下讓整個 script 中止，summary.md 完全不會產生。抽出 `collect_xcode_version()`，best-effort，永遠回傳某個值（失敗時回傳 `"unknown"`），絕不讓非零結束碼往外傳。新增 missing／failing 兩種情境的 self-test。
3. **`evaluate_xctest_log` 讓 `Executed 0 tests, with 0 failures` 通過**：明確拒絕 `executed == 0`。新增 0／1／正常數量三種 self-test 情境。
4. **`LUMAHARBOR_IPAD_SELFTEST_*_CMD` 在正式執行也會生效**：使用者 shell 裡若殘留先前互動除錯時匯出的環境變數，正式執行可能被悄悄接管。`step_command_for` 現在額外要求 `LUMAHARBOR_IPAD_SELFTEST_CHILD_MARKER` 指向一個「真的存在於磁碟上」的檔案——這個路徑由當次 `run_selftest()` 執行時新建、明確透過每個 case 自己 spawn 的 child 傳入，絕不是固定、可能殘留在使用者 shell 設定檔裡的值。新增案例：即使五個 override 環境變數都設定，但沒有這個 marker 檔案時，五個步驟仍然使用真正的正式指令。
5. **`RUN_DIR` 只用秒級 timestamp、`mkdir -p`**：同一秒內並行執行的兩個 runner 會共用同一個目錄、互相覆蓋 logs／summary。改成 timestamp+PID+random 的排他 `mkdir`（不加 `-p`），衝突時重試。新增兩個 fake runner 並行執行的 self-test，驗證產生兩個各自獨立、各自 Overall PASS 的目錄。
6. **`SUMMARY_WRITTEN` 設得太早**：`finalize_run` 執行到一半再收到訊號，可能跳過收尾、留下未遮蔽 log 或完全沒有 summary。改成 `notStarted／finalizing／finalized` 三態：`finalizing` 期間收到的訊號只記錄 `DEFERRED_SIGNAL` 就返回，讓被中斷的那次 `finalize_run` 呼叫自然接續執行完（含原子寫入與 privacy scan），呼叫端在 `finalize_run` 返回後才依 `DEFERRED_SIGNAL` 決定結束碼。同時把兩處 `redact_file` 的 `sed` 呼叫改成 `|| true`（best-effort），確保磁碟滿／權限錯誤這類遮蔽失敗不會在既有的 grep 安全網有機會攔截之前就讓整個 script 中止。
7. **路徑遮蔽 regex 不支援空白與 Unicode**：原本的字元類別只允許 `[A-Za-z0-9_./+=@%-]`，`/Volumes/Client Photos/secret.ARW` 這種帶空白的路徑只會被遮到 `/Volumes/Client`，privacy scan 卻誤判乾淨。新增「引號包住的路徑」專用 pattern（用配對的引號明確界定範圍，空白／中文／括號都安全涵蓋），並把沒加引號的 catch-all 改成排除清單（只排除引號、角括號、`|`），刻意允許空白與非 ASCII 字元通過——寧可多遮掉同一行後面幾個字（安全方向的犧牲），也不留下磁碟名稱或檔名的後半段。新增涵蓋空白、引號、括號與繁體中文的 self-test。

同一輪也依 review 要求額外處理：

- **Timeout 分支**：新增 self-test，用 `LUMAHARBOR_IPAD_STEP_TIMEOUT_SECONDS=1` 搭配永遠不會結束的目標指令，驗證 `TIMEOUT_HIT`／exit 124／下游 SKIPPED／summary FAIL／子程序完整清理全部正確。
- **Process group 評估**：認真評估過改用 OS process group（`kill -TERM -- -PGID`）取代目前的「PID 快照＋walk」設計，並明確判定不採用——macOS 沒有 `setsid`，要讓 zsh 的背景工作自動取得獨立 process group 必須開啟 job control（`setopt monitor`），但這在非互動式呼叫（本 runner 實際最常見的使用情境：CI、背景執行、沒有 controlling TTY）下風險更高，可能因為 SIGTTIN/SIGTTOU 造成新的一類卡死，比目前這道窄範圍的競態更難排查。改用兩個具體、範圍明確的緩解：(a) 在送出最終 KILL 之前、且只在 root PID 確認還活著時，額外重新掃描一次子程序樹，補上 grace period 期間新 fork 出來的子程序（不會重蹈「root 已死後重新掃描」的舊 bug）；(b) 每次送信號前用 `ps -o lstart=` 重新核對目標 PID 的啟動時間指紋，啟動時間對不上（代表已被系統回收給別的程序）就跳過，不盲目送出信號。
- **HEAD／dirty state 一致性**：runner 開始時記錄 `git rev-parse HEAD` 與 `git status --porcelain` 的變更檔案數，`finalize_run` 時重新核對；任一個變了就在 summary 加上「## Repo state」區塊回報 FAIL，避免長時間執行把混合版本的結果歸到錯誤的 commit。

修復後 self-test（含新增的 9 個案例，加上既有 17 個訊號／生命週期案例與 parser／redaction 檢查）在前景連續執行 10 次，每次都是 Overall PASS、exit 0，每次結束後對 runner 本身、`interrupt-root`／`interrupt-child`／helper／`sleep 3600` 的精確程序檢查都確認無殘留。真實 fixture 目錄下重跑完整 Task 8 自動驗收，`summary.md` 的 `Commit` 欄位與本輪修正完成的 HEAD 完全一致（見 §3 開頭）。

### 5.3 Codex 第二輪 pre-landing review：BLOCKED → 修正（本輪：runner 修正，非產品程式碼）

§5.2 的修正合併後，Codex 做了第二輪驗證並回報 **BLOCKED**，找到 4 項真實缺陷（其中一項是實際成功利用的 bypass，不是理論推測）：

1. **`LUMAHARBOR_IPAD_SELFTEST_CHILD_MARKER` 只驗證檔案存在**：Codex 直接把這個變數指向 `/etc/passwd`（幾乎每台 Unix 系統都存在的檔案），成功讓五個正式指令全部被 override 取代，且產生 `Overall result: PASS`。修法：新增 `selftest_child_authorized()`，要求 marker 檔案的**內容**必須與另一個環境變數 `LUMAHARBOR_IPAD_SELFTEST_CHILD_TOKEN` 完全相符——這個 token 是 `run_selftest()` 每次執行時用 `$RANDOM` 三次疊加牆鐘時間現場產生的隨機值，與 marker 路徑一起明確傳給每個 case 自己 spawn 的 child，絕不是任何既存檔案「碰巧」會有的內容。**誠實聲明範圍**：這無法防範「讀過本檔案原始碼、刻意手動複製兩個值」的使用者——在純 shell script、且驗證邏輯對呼叫者本身可見的前提下，沒有任何機制能做到這點——但確實堵住了 Codex 實際示範的那個漏洞：拿任意既存檔案當 marker。新增 self-test 完整重現 `/etc/passwd` 攻擊（外加「token 存在但不相符」的情境），驗證五個步驟都仍使用真正的正式指令。
2. **`DEFERRED_SIGNAL` 只在 `finalize_run` 某一個時間點被讀取一次**：如果訊號剛好落在「Overall 已判定為 PASS 並寫進暫存檔」之後、但「原子 `mv` 發布成真正的 summary.md」之前，先前的設計會把這個較晚抵達的訊號漏掉，發布出去的 summary 仍然錯誤地寫著 PASS。修法：在 `finalize_run` 內新增第二個 self-test 專用暫停點（緊接在 Overall 行寫入暫存檔之後、`mv` 之前），並在 `mv` 前的最後一刻再檢查一次 `DEFERRED_SIGNAL`——若這時才發現訊號已抵達，就地把暫存檔裡的 `Overall result: PASS` 改寫成 `FAIL`，然後才執行 `mv`。這個最終檢查與緊接其後的 `mv`，本身仍完整落在既有的 `SUMMARY_STATE == "finalizing"` 遞延保護範圍內：訊號若剛好打在這兩行上，一樣只會被記錄然後讓執行緒繼續，不會遺失。新增 self-test 精確在這個「Overall 已判定 PASS 之後」的窗口送出訊號，驗證最終發布的 summary 仍正確顯示 FAIL。
3. **`finalize_run` 對各步驟 log 呼叫 `redact_file` 沒有容錯**：`sed` 若失敗，`set -e` 會在 privacy scan 執行之前就讓整個 script 中止——而且問題比原本以為的更深：連 `redact_literal`／`redact_pattern` 內部真正呼叫 `sed` 的那一行都沒有 `|| true`，代表同一個檔案內第一個失敗的 pattern 就會讓「同一個 `redact_file` 呼叫」裡後面所有 pattern 全部跳過執行。修法：把 `|| true` 加在 `redact_literal`／`redact_pattern` 內部真正呼叫 `sed` 的那一行（而不只是外層呼叫點），並補上逐步驟 log 迴圈原本缺漏的 `|| true`。新增端到端 self-test：把一個永遠失敗的假 `sed` 塞進 child 的 `PATH` 最前面，並讓其中一個步驟的 log 刻意寫入一個真正的 `/Users/` 路徑，驗證 `finalize_run` 仍完整跑完、privacy scan 真的抓到這個未被遮蔽的洩漏，且 Privacy scan 與 Overall 都正確回報 FAIL。
4. **Repo state 只比較 `git status --porcelain` 的行數**：這個作法對「同一個 dirty 檔案內容又改變」「dirty A 換成 dirty B（檔案數不變）」「檔案在 tracked／untracked 之間切換」三種情境都是盲點，因為這些情境不一定會改變 porcelain 輸出的行數。修法：新增 `git_worktree_fingerprint()`，改成雜湊 `git diff HEAD --binary`（涵蓋所有 tracked 相對 HEAD 的差異，含 staged／unstaged 與實際內容）加上每個 untracked 檔案的路徑與內容。新增 self-test，針對一個獨立、用完即丟的 scratch git repo（完全不動到真正的專案 repo），驗證上述三種情境下 fingerprint 確實都會改變。

修復後 self-test（本輪再新增 6 個案例，總計涵蓋前兩輪的 26 個既有案例）在前景連續執行 10 次，每次都是 Overall PASS、exit 0，每次結束後對 runner 本身與所有 helper 的精確程序檢查都確認無殘留。`Scripts/run-mvp-acceptance.zsh` self-test（本輪未變動）重新驗證仍全數通過。真實 fixture 目錄下重跑完整 Task 8 自動驗收，`summary.md` 的 `Commit` 欄位（`c75ac623241ce7871569fd9324cf5eeac1583179`）與本輪修正完成的最終 HEAD 完全一致（見 §3 開頭）。

### 5.4 Codex 第三輪 pre-landing review：BLOCKED → 架構修正（本輪：runner 修正，非產品程式碼）

§5.3 的修正合併後，Codex 做了第三輪驗證並再次回報 **BLOCKED**，這次的核心批評不是某個個別缺陷，而是修法本身的方向：`selftest_child_authorized()` 這種「呼叫者可以自行偽造 marker＋token 憑證」的檢查，無論再怎麼加強驗證邏輯，本質上都無法真正堵住呼叫者本人偽造憑證——Codex 再次示範了這一點，自行建立一組彼此相符的 marker 檔案與 token，成功讓五個正式指令全部被 override 取代並產生 `Overall result: PASS`。這一輪不再修補憑證檢查本身，而是做架構修正：把「self-test 可以替換指令」這個能力，從正式執行路徑上徹底移除。

1. **正式 runner 不得解析任何 self-test override 環境變數**：`step_command_for` 移除整段 `selftest_child_authorized` 檢查，變成完全純函式——五個步驟的指令永遠是寫死的正式指令，函式本體不再有任何一處讀取 `LUMAHARBOR_IPAD_SELFTEST_*` 這個變數名稱。self-test 需要替換指令的能力被移到一個結構上完全獨立的內部子指令 `__selftest_simulate_steps <5 個步驟指令> [--pause-at=／--pause-ready=／--pause-go=／--fake-mv= 旗標]`，只有明確以這個字串作為第一個 argv 呼叫本檔案時才會啟用，並透過 `selftest_simulated_command_for`（另一個獨立的 resolver 函式）與 `COMMAND_RESOLVER` 間接呼叫、`run_acceptance_flow()`（正式與 self-test 共用的執行骨架）串接起來。新增 self-test：即使呼叫者手動匯出全部五個 override 變數，外加一組彼此相符、自行捏造的 marker／token（完整重現 Codex 這次的攻擊手法），驗證 `step_command_for` 五個步驟仍然回傳真正的正式指令——因為現在已經沒有任何檢查分支可以被這組憑證通過。
2. **消除 finalize signal race**：Codex 用一個可控制、會暫停的 `mv` 替身，示範在「最後一次 `DEFERRED_SIGNAL` 檢查」通過之後、`mv` 真正執行完成之前送出 TERM，仍能讓 `Overall result: PASS` 被發布出去——因為 trap 返回後不會重新執行呼叫端原本那個已經跑過的 `if` 檢查。修法：把單次「檢查→修正→mv」改成有上限（20 次）的發布保護迴圈——`mv` 之後立刻對照剛發布出去的正式檔案再檢查一次 `DEFERRED_SIGNAL`，如果這時才發現訊號已抵達且檔案仍寫著 PASS，就地修正成 FAIL 後重新發布，如此重複到確認一致為止；同時新增統一的 self-test 專用暫停點機制 `selftest_pause_at()`（純粹用 script 全域變數控制，不透過任何環境變數），涵蓋使用者要求的全部四個時間窗：(a) 最後一次檢查後、`mv` 前；(b) `mv` 執行期間（透過 `--fake-mv=` 替換成一個會先暫停、確認訊號送達後才真正執行 `mv` 的替身腳本）；(c) `mv` 後、`SUMMARY_STATE` 設為 `finalized` 前；(d) `finalized` 後、程式真正退出前。新增對應四個（加上原有的 finalize-start 共五個）self-test 案例，其中 (a)(b) 兩個窗口驗證最終發布的 summary 確實被修正為 FAIL，(c)(d) 兩個窗口驗證此時檔案早已正確發布，訊號只需要讓程式本身的結束碼正確反映（143／130／129），不需要也不應該再改動已經正確的檔案內容。
3. **Privacy scan 檢查實際的 repo root、`$HOME`、三個 fixture 目錄，而非僅四個通用前綴**：Codex 重現 `/tmp/customer-secret/private-photo.ARW`（`/private/tmp/` 的裸 `/tmp/` 別名）留在 log 中，Privacy 與 Overall 仍雙雙回報 PASS，因為原本的偵測與遮蔽 regex 都只涵蓋 `/Users/`、`/Volumes/`、`/private/var/`、`/private/tmp/` 這四個前綴，既沒有把 `/tmp/`、`/var/` 這兩個 macOS 上會被系統符號連結解析掉的裸別名算進去，也沒有直接比對這次執行實際關心的那幾個具體字串。修法：`has_private_path` 與 `redact_file` 都新增 `/tmp/`、`/var/` 這兩個裸別名的偵測與遮蔽 pattern；`has_private_path` 另外用 `grep -qF` 直接比對 repo root、`$HOME`、三個 fixture 目錄的實際字串本身，不再只靠通用前綴間接涵蓋。
4. **Privacy scanner 明確區分 grep 結束碼**：`grep` 回傳 0（找到洩漏）、1（確定乾淨）、2 以上（掃描本身失敗，例如檔案不存在、權限錯誤、或 `grep` 執行檔本身有問題）三種語意截然不同的結果，原本的實作只用 `grep -Eq ... ; return $?`，等於把「掃描失敗」與「乾淨」混為一談，掃描失敗時反而回報乾淨。修法：抽出 `_privacy_grep_result()`，明確只有結束碼 1 才算「這一項檢查乾淨、繼續看下一項」，0 與 2 以上一律視為「不乾淨」（fail closed）。新增 self-test：把一個永遠回傳結束碼 2 的假 `grep`放進 `PATH` 最前面，驗證 `has_private_path` 對一個內容完全乾淨的檔案仍正確回報「不乾淨」（因為掃描本身失敗，不能假裝乾淨）。
5. **`git_worktree_fingerprint` 不再對任意 untracked 路徑天真地 `cat`**：改用 `git ls-files --others --exclude-standard -z` 搭配 zsh 的 `${(0)}` NUL-safe 陣列切割（不再用會把 `exit` 侷限在自己那層 pipeline subshell、無法讓外層察覺失敗的 `pipe | while read` 寫法），對每個 untracked 項目先確認型別再決定怎麼處理：symlink 只記錄 `readlink` 讀到的目標路徑、絕不 dereference；一般檔案才記錄型別／權限模式／大小並讀取內容；其他型別（FIFO、device、socket……）只記錄型別與權限模式、刻意完全不讀取內容——避免對一個沒有寫入端的 FIFO 執行 `cat` 導致整個函式（進而整個驗收流程）永久卡死。同時把 `git diff`／`git ls-files`／最終 `shasum` 的每一步都明確檢查結束碼，任一步失敗就回傳空字串加非零結束碼（fail closed），絕不產出一個「穩定但錯誤」、可能讓兩次失敗擷取被誤判為「沒有變化」的雜湊值。新增四個 self-test：FIFO（驗證不會卡死）、symlink（改變目標會改變雜湊）、檔名含換行字元（驗證 NUL-safe 切割不會被换行字元打斷列舉）、`git` 本身失敗（驗證雜湊確實回傳空字串而非一個看似合法的值）。
6. **Self-test artifacts 與正式驗收證據完全隔離**：新增 `SELFTEST_RUN_TREE`（`.build/ipad-vertical-slice-selftest/`），與正式執行使用的 `PRODUCTION_RUN_TREE`（`.build/ipad-vertical-slice/`）在檔案系統上完全分開；`__selftest_simulate_steps` 產生的每一份 summary.md 額外在檔案最開頭強制加上「**Run mode: SELFTEST**」字樣，即使某個正式報表收集器只看檔案內容、不管它來自哪個路徑，也能單靠內容本身判斷並拒絕一份 self-test 產物。新增 self-test 直接驗證：跑一次完整的假通過模擬後，`PRODUCTION_RUN_TREE` 底下沒有出現任何新目錄，且新產生的目錄確實在 `SELFTEST_RUN_TREE` 底下、summary.md 確實帶有這個標記。

修正過程中另外發現並修好兩個屬於這次重寫本身引入的新缺陷（皆由 runner 自己的 self-test 抓到，而非人工肉眼發現）：

- `LUMAHARBOR_IPAD_RUNNER_SELFTEST=1` 這個環境變數在頂層執行時會被匯出，因此也會保留在 `spawn_simulated_run` 之後每一個透過 `exec` 啟動的巢狀模擬 child 的環境裡；`__selftest_simulate_steps` 的 argv 檢查如果排在這個環境變數檢查**之後**，每個巢狀 child 就會先撞到環境變數檢查、遞迴呼叫 `run_selftest()` 本身，完全忽略自己收到的 `__selftest_simulate_steps` argv，導致目標步驟的模擬指令永遠不會真正被執行——外顯症狀是每一個訊號類 self-test 案例都在 20 秒的 ready-handshake 逾時後回報「the interrupt-target helper never signalled ready」。修法：把 `__selftest_simulate_steps` 這個明確、無歧義的 argv 判斷移到 `LUMAHARBOR_IPAD_RUNNER_SELFTEST` 環境變數判斷**之前**，讓明確的呼叫方式永遠優先於行程繼承來的環境變數。
- `git_worktree_fingerprint` 一開始的實作把整段多行邏輯包在一個 `out="$( ... )" || out=""` 裡；zsh（與 bash 相同）對「用 `||` 保護一個指令」的 errexit 豁免，會延伸進入該指令自己開的 subshell 內部——導致 `$( ... )` 內部真正呼叫 `git` 失敗時，`set -e` 並不會像沒有 `||` 保護時那樣讓這個 subshell 提前中止，後面的指令反而會繼續往下執行，最後仍拼湊出一個非空、看似合法的雜湊值，完全沒有真正 fail closed。修法：改成用 `if var="$(...)"; then ... else ...; fi` 的形式分別包住 `git diff`、`git ls-files`、內容彙整、`shasum` 四個階段——前兩者本來就只包一個指令，指令本身的結束碼就是 substitution 的結束碼，不受這個豁免延伸的影響；內容彙整階段內部改用明確的 `|| exit 1` 主動中止該層 subshell，不依賴 errexit 的隱性行為。新增的「`git` 本身失敗」self-test（見 finding 5）正是抓到這個回歸的案例。

修復後 self-test（本輪再新增約 12 個案例，加上前三輪累計的既有案例）在前景連續執行 10 次，每次都是 Overall PASS、exit 0，每次結束後對 runner 本身與所有 helper／`interrupt-root`／`interrupt-child`／`fake-swifttest`／`fail-with-7` 的精確程序檢查都確認無殘留。`Scripts/run-mvp-acceptance.zsh` self-test（本輪未變動）重新驗證仍全數通過。真實 fixture 目錄下重跑完整 Task 8 自動驗收，五個步驟、Repo state、Privacy scan 全部 PASS（見 §3 開頭；該次 run 是在本輪修正 commit 落地前、對照工作目錄中的修改執行，驗證的正是本節所述的架構修正本身）。本輪修正完成後的最終 HEAD 為 `52b88f4`（commit 訊息：「fix: eliminate forgeable self-test override channel, close finalize publish race, harden privacy scan and worktree fingerprint」）。

### 5.5 Codex 第四輪 pre-landing review：BLOCKED → 修正 publish state machine（本輪：runner 修正，非產品程式碼）

§5.4 的修正合併後，Codex 做了第四輪驗證並再次回報 **BLOCKED**：架構隔離、privacy scanner 與 fingerprint 的修正本身有效，但發布（publish）狀態機尚未完成——Codex 用一個永遠 `exit 1` 的假 `mv` 示範「五個步驟全部 PASS、runner 結束碼 0、但 `summary.md` 從未真正被寫出」，同時指出既有的四個 self-test signal 時窗中有兩個（`after-mv-before-finalized`、`after-finalized`）把「維持 Overall PASS」當成預期結果，與「任何被訊號中斷的 run 都不該留下 PASS 產物」這條驗收規則本身矛盾。

1. **`PUBLISH_MV_CMD` 的 `mv` 失敗不再被 `|| true` 吞掉**：發布迴圈重寫為明確追蹤 `publish_converged`（只有真正確認乾淨發布成功的那一條路徑會設為 1）與 `publish_ok`（額外要求 `verify_published_summary` 這個純 zsh、完全不依賴任何外部指令結束碼的 postcondition 檢查通過）。`mv` 失敗時用 `continue` 交給 20 次上限內的重試，而不是假裝已發布；`SUMMARY_STATE` 只有在 `publish_ok` 為真時才會被設成 `finalized`，`mv` 永久失敗時维持在 `finalizing`（代表「嘗試過但從未真正完成」），`overall_ok` 也直接把 `publish_ok` 乘進去，確保這種情況下 runner 一定非零結束碼。
2. **`finalize_run` 結束前的 postcondition 驗證**：新增 `verify_published_summary()`，純 zsh 實作（不呼叫 `grep`／`sed`，用 `${(@f)content}` 逐行比對），檢查 `summary.md` 存在、是一般檔案（非 symlink）、可讀、恰好一行 `Overall result: `，且若 `DEFERRED_SIGNAL` 非空則該行必須精確是 `Overall result: FAIL`。同時新增 `force_summary_overall_fail()`，同樣純 zsh（讀檔、`${content//Overall result: PASS/Overall result: FAIL}` 字串取代、寫回、透過 `PUBLISH_MV_CMD` 重新發布），作為完全不依賴 `grep`／`sed`／`mv` 結束碼語意的最終權威修正手段，在發布迴圈之後、以及兩個較晚的暫停點（`after-mv-before-finalized`、`after-finalized`）之後都會呼叫一次；20 次上限耗盡時 `publish_converged` 保持 0，同樣直接 fail closed，不看檔案內容是否碰巧正確。
3. **發布迴圈內的 `grep`／`sed` 錯誤不再被誤判為成功**：重用既有的 `_privacy_grep_result`（原本只給 privacy scan 用，其「exit 1 才算乾淨，0 與 2+ 都算不乾淨」的 fail-closed 語意本來就是通用的）判斷發布迴圈自己的兩次 `grep` 檢查；新增四個端到端 self-test：`run_publish_mv_permanent_failure_selftest_case`（無訊號、`mv` 永久失敗，驗證非零結束碼且不產生宣稱 PASS 的 `summary.md`）、`run_publish_sed_permanent_failure_selftest_case`（訊號＋`sed` 永久失敗，驗證仍能透過純 zsh fallback 發布出正確的 FAIL）、`run_publish_grep_permanent_failure_selftest_case`（訊號＋`grep` 固定回傳 2）、`run_publish_cap_exhausted_selftest_case`（訊號＋一個永遠謊報「PASS 仍在」的假 `grep`，逼迫 20 次上限用盡）。四個 fake 工具都刻意窄範圍（只攔截 `Overall result: PASS` 這個特定字串的呼叫），讓其餘呼叫（如 privacy scan 自己的 `grep`）維持使用真正的系統指令，避免與既有的 privacy-scan-specific 案例混淆測試對象。`runner-diagnostic.log` 新增 `Publish:`／`Publish result:` 兩行記錄迴圈是否真正收斂，讓「20 次上限耗盡」這個特定情境可以被自動化斷言直接驗證，而不只是間接推論。
4. **四個 signal 時窗全部改為要求 Overall FAIL**：`after-mv-before-finalized` 與 `after-finalized` 這兩個既有 self-test 案例的 `expect_fail` 參數從 0 改成 1，並修正實作使其真正符合這個更嚴格、更簡單的驗收規則——「任何被訊號中斷的 run，無論訊號落在發布序列的哪一個時間點（甚至是 `SUMMARY_STATE` 已經設成 `finalized`、只差 process 尚未真正 exit 的最後一刻），已發布的 `summary.md` 都不能留下 Overall PASS」。修法：`handle_terminating_signal` 一開始就無條件呼叫一次 `force_summary_overall_fail`（不看 `DEFERRED_SIGNAL`，因為光是進到這個 handler 就代表確實收到了終止訊號），涵蓋「`SUMMARY_STATE` 已經是 `finalized`、这次訊號不會再進入 `finalizing` 分支」的情境；`finalize_run` 內部三個呼叫點則需要 `[[ -n "$DEFERRED_SIGNAL" ]]` 才觸發，因為單純呼叫 `finalize_run` 而沒有任何訊號時，內容本來就有可能是真正、合法的 PASS，不可以被無條件改寫。
5. **`LUMAHARBOR_IPAD_RUNNER_SELFTEST` 環境變數 dispatch 改為明確 argv subcommand**：頂層 self-test 觸發方式從 `LUMAHARBOR_IPAD_RUNNER_SELFTEST=1 Scripts/run-ipad-vertical-slice-acceptance.zsh` 改成 `Scripts/run-ipad-vertical-slice-acceptance.zsh __selftest`（`__selftest_simulate_steps` 的 argv 檢查維持在最前面，語意不變）。理由與 §5.4 finding 1 移除 `LUMAHARBOR_IPAD_SELFTEST_*` 環境變數的動機一致：一個互動除錯時 `export` 過的環境變數，可能殘留在同一個 shell 之後某次真正的、零參數的正式 invocation 裡，讓使用者以為自己跑的是正式驗收、實際上悄悄變成 self-test，且 argv 上完全看不出任何痕跡。改成 argv subcommand 後，每次呼叫的行為完全由當次命令列本身決定，不受 shell 環境殘留影響。

修正過程中另外發現並修好兩個屬於這次重寫本身引入的新缺陷（皆由本輪新增或既有的 self-test 案例抓到，而非人工肉眼發現）：

- **`cmd; rc=$?` 這個兩行寫法本身不受 `set -e` 保護**：發布迴圈最初的實作把 `grep -q ... "$file" 2>/dev/null` 與 `grep_rc=$?`拆成兩行以取得三態結束碼，但這個寫法在 zsh（與 bash 相同）的 `set -e` 語意下完全沒有被保護——`errexit` 會在 `grep` 這一行本身結束碼非零時立刻中止整個 script，`grep_rc=$?` 這一行根本沒有機會執行。這與 `has_private_path` 裡外觀相同的既有寫法之所以長年沒事，純粹是因為 `has_private_path` 每次都剛好被呼叫在 `if has_private_path ...; then` 這種本來就豁免 `errexit` 的位置——zsh 的豁免會沿著呼叫鏈往下延伸進整個函式本體，但發布迴圈裡的呼叫是 `while` 迴圈本體內的裸陳述式，沒有任何外層豁免可以繼承。修法：全部改成 `cmd 2>/dev/null && rc=0 || rc=$?` 這種本身就是一個完整 `&&`/`||` list 的寫法，無論放在什麼呼叫位置都不受影響地正確擷取結束碼。這正是 Codex 那個「假 `mv` 永遠 exit 1，結果 runner RC=0」的原始 bug 之所以在早期修正嘗試中又立刻復發成「finalize-start／before-mv 訊號案例反而變成 RC=1、沒有 `summary.md`」的根本原因，由這兩個 self-test 案例（重新啟用後）直接抓到。
- **`force_summary_overall_fail` 在無訊號時被誤用**：最初把它安插在發布迴圈之後與兩個較晚暫停點之後時沒有加上 `[[ -n "$DEFERRED_SIGNAL" ]]` 的前置判斷，導致完全正常、未受任何訊號中斷的 PASS run（`run_fakepass_selftest_case`、`run_concurrent_runs_selftest_case` 兩個既有案例立刻抓到）也會被這個函式誤判「內容含有 Overall result: PASS」而強制改寫成 FAIL——因為這個函式本身只看檔案內容、不看有沒有發生訊號。修法：`finalize_run` 內的三個呼叫點都補上 `DEFERRED_SIGNAL` 前置判斷（只有真的發生過訊號才允許強制修正）；`handle_terminating_signal` 開頭那個呼叫點維持無條件（光是進到這個 handler 本身就已經是訊號發生的證明，不需要再看 `DEFERRED_SIGNAL`）。

修復後 self-test（本輪新增 4 個發布失敗端到端案例，加上前四輪累計的既有案例，總計 132 個斷言）在前景連續執行 10 次，每次都是 Overall PASS、exit 0，每次結束後對 runner 本身與所有 helper 的精確程序檢查都確認無殘留。`Scripts/run-mvp-acceptance.zsh` self-test（本輪未變動）重新驗證仍全數通過（含 timeout／hanging-command 案例；signal-interruption 分層因本次環境未匯出三個 fixture 目錄環境變數而 SKIPPED，非失敗）。

**本輪未能重新執行真實 Task 8 自動驗收**：本次工作階段沒有可用的 exFAT 外接隨身碟（`/Volumes/` 下無對應磁碟區）、也沒有匯出 `LUMAHARBOR_RAW_FIXTURE_DIR`／`LUMAHARBOR_APFS_TEST_DIR`／`LUMAHARBOR_EXFAT_TEST_DIR` 三個環境變數，因此無法跑完整的 `strict build → swift test → iOS Simulator build → MVP preflight → MVP acceptance` 五步驟。本輪修正對「正常、無訊號、`mv` 未曾失敗」路徑的行為刻意保持不變（`run_fakepass_selftest_case` 與 `run_concurrent_runs_selftest_case` 這兩個既有案例正是用來守住這一點，見上方「兩個新回歸」說明），因此 §3 記錄的既有真實 PASS 證據理論上不受本輪修正影響；但既有規則要求 Task 8 自動驗收必須在真實 fixture 下重新執行才能視為本輪修正的最終確認，待使用者重新掛載 exFAT 隨身碟並匯出三個 fixture 目錄環境變數後補做。

### 5.6 Codex 第五輪 pre-landing review：BLOCKED → 修正 evidence protocol 與平行隔離（本輪：runner 修正，非產品程式碼）

§5.5 的修正合併後，Codex 做了第五輪驗證並再次回報 **BLOCKED**：架構本身方向正確，但 Codex 用一個「第一次呼叫成功、第二次起永遠 `exit 1`」的假 `mv`，精確在 `after-mv-before-finalized` 暫停點送出 TERM，示範了發布迴圈之後的三個 `force_summary_overall_fail || true`（兩個較晚暫停點各一次，加上 `handle_terminating_signal` 開頭那一次）全部把修正失敗吞掉，最終結果是 `RC=143`、`MV_COUNT=4`，但 `summary.md` 仍讀 `Overall result: PASS`——結束碼正確，但已發布的檔案內容仍然是假的 PASS，而 `publish_ok`／`SUMMARY_STATE` 對這個矛盾一無所知。

1. **重新定義可驗證的 evidence protocol，不再宣稱無條件保證**：finalize_run 與 force_summary_overall_fail 上方的註解重寫為明確的三層保證——(1) **結束碼**：`exit_for_signal` 的訊號對應完全在行程記憶體內完成，不經過任何磁碟 I/O，是唯一無條件成立的保證，collector 必須把訊號範圍內的非零結束碼視為比 `summary.md` 內容本身更權威；(2) **`summary.md` 內容**：只有在修正真的成功寫回時才保證讀到 FAIL；(3) **`CORRECTION_MARKER_NAME`（`PUBLISH_CORRECTION_FAILED`）評估標記**：修正失敗時，用完全不經過 `PUBLISH_MV_CMD`（正是這個機制本身壞掉）的純 `print > file` 直接寫入 `$RUN_DIR`，代表「這次的 `summary.md` 內容不可信任，請以結束碼為準」；連這個純寫入都失敗時，才真正沒有任何磁碟層級的保證可言，此時只剩結束碼。
2. **correction failure 不再被 `|| true` 吞掉**：新增 `recheck_late_checkpoint()`，在兩個較晚暫停點（`after-mv-before-finalized`、`after-finalized`）之後都會呼叫，各自重新執行 `force_summary_overall_fail` 並用新版 `verify_published_summary(..., "FAIL")` 重新驗證；驗證不過就呼叫 `record_publish_correction_failure()` 寫下 tier-3 標記，並回傳失敗，讓 `finalize_run` 把 `publish_ok`／`overall_ok` 清零、`SUMMARY_STATE` 保持（或改回）`finalizing`，絕不設成 `finalized`。`handle_terminating_signal` 開頭那個無條件呼叫也同步補上明確的失敗處理（原本同樣是 `|| true`），因為訊號精確落在 `after-finalized` 暫停點時，`SUMMARY_STATE` 已經是 `finalized`，會直接從 trap 內部呼叫 `exit_for_signal` 離開，`finalize_run` 自己的 `recheck_late_checkpoint` 永遠不會被執行到——這是這個修正必須留下 tier-3 標記的唯一機會，也是它必須放在這裡（而不只是 `finalize_run` 內部）的原因。新增 `_run_late_signal_mv_permanent_failure_selftest_case`（涵蓋 `after-mv-before-finalized` 與 `after-finalized` 兩個暫停點），精確重現 Codex 這次的手法：驗證結束碼 143、`mv` 至少被呼叫兩次（`after-mv-before-finalized` 實際觀察到 4 次、`after-finalized` 觀察到 2 次，因為後者的 bypass 路徑本來就少一次修正嘗試機會）、且 `PUBLISH_CORRECTION_FAILED` 標記確實存在。
3. **`verify_published_summary` 改為接收明確的預期結果**：新增第二參數 `<expected: PASS|FAIL>`，`Overall result: ` 那一行必須逐字等於 `Overall result: ${expected}`；不再從 `DEFERRED_SIGNAL` 內部推斷，呼叫端自己決定這次應該預期什麼。新增 `run_verify_published_summary_selftest_case` 直接單元測試：PASS 檔案只能通過 PASS 預期、FAIL 檔案只能通過 FAIL 預期、`Overall result: UNKNOWN`／空值／完全沒有 Overall 行／重複兩行 Overall，以及非法的 `expected` 參數本身，全部必須被拒絕。
4. **`find_selftest_run_dir_for_pid` 改回同時要求 before/after 差集與精確 PID 相符**：上一輪把「找自己的 run directory」從純 before/after 目錄差集改成純 PID 字串比對，解決了兩個獨立 `__selftest` suite 互相污染彼此偵測的問題（finding 3），但引入了另一個真實回歸——兩個 suite 同時跑、加上它們各自巢狀的 `run_concurrent_runs_selftest_case` 又各自再產生兩個子行程，這種密集的行程建立／回收速度，足以讓作業系統的 PID 配置在單次 self-test 執行期間就重複使用同一個號碼；純 PID 比對因此可能撈到一個「剛好重複用到同一個 PID、但其實是更早、已經結束的另一個案例」的舊目錄。這不是理論推測，而是實際重現：`run_concurrent_runs_selftest_case` 的「兩個 run 目錄各自都有 Overall PASS 的 summary.md」斷言，在兩個 `__selftest` suite 同時執行時間歇性失敗，追下去正是撈到了舊目錄。修法：`find_selftest_run_dir_for_pid` 現在要求同時符合「PID 字串比對」與「在呼叫者於 spawn 之前拍下的目錄快照裡不存在」兩個條件——前者排除其他 suite 這段時間內產生的目錄，後者排除任何在這次 spawn 之前就已存在的目錄（含被重複使用的舊 PID 目錄），單獨任何一個條件都不足以同時堵住兩種情境。新增 `run_parallel_selftest_suites_case`：兩個完整、獨立的 `Scripts/run-ipad-vertical-slice-acceptance.zsh __selftest` 呼叫同時執行，只斷言兩者都 exit 0；用 `LUMAHARBOR_IPAD_SELFTEST_NESTED_PARALLEL_GUARD` 環境變數避免這兩個巢狀 suite 又各自再遞迴產生兩個，這個變數純粹是 self-test 內部防止遞迴爆炸的機制，只在已經透過明確 `__selftest` argv 進入 self-test 之後才會被檢查，與正式執行路徑的環境變數免疫保證無關、也不重新開啟它。

同步完成的清理項目：

5. **`runner-diagnostic.log` 拆成三個獨立欄位**：`Publish loop converged`（發布迴圈本身有沒有在上限內確認乾淨發布，0 可能是 `mv` 永久失敗、也可能是 `grep`／`sed` 永久失敗或說謊、也可能是真的把 20 次上限用完，三者外觀完全一樣）、`Late correction`（`not-needed`／`ok`／`failed` 三態，記錄「這一次提早的修正嘗試」——即發布迴圈之後、兩個較晚暫停點之前那一次——有沒有需要、有沒有成功；兩個較晚暫停點各自的修正結果改由 `PUBLISH_CORRECTION_FAILED` 標記檔案記錄，理由見上方 finding 2）、`Summary verified`（最終 `verify_published_summary` 的實際結果）。避免「`Publish loop converged: 0`」被誤讀成「一定是 20 次上限被用完」。
6. **SELFTEST 標記移到 `summary.md` 真正的第一行**：原本的「**Run mode: SELFTEST**」粗體段落雖然在檔案很前面，但不是逐字的第一行；如果這個標記真的要當作 collector 的信任邊界（文件與註解一直是這樣宣稱的），就必須讓「只讀第一行」的 collector 也能可靠判斷。修法：在粗體說明段落之前，加印一行不含任何 Markdown 格式的裸字串 `Run mode: SELFTEST`，且保證是整個檔案的第一行；`run_isolation_selftest_case` 新增直接讀取第一行並逐字比對的斷言。
7. **`run_checkpoint_signal_selftest_case` 移除已不可達的 `expect_fail=0` 分支**：§5.5 已經讓全部四個 finalize_run 訊號時窗與 interstep 時窗都只呼叫 `expect_fail=1`，原本的 `expect_fail=0`（「訊號來得太晚，PASS 保留」）分支從此沒有任何呼叫端會走到，整段連同這個參數一起移除，函式簽章從 5 個參數縮成 4 個。
8. **移除 `finalize_run` 內未使用的 `commit` 區域變數**、**發布重試上限抽成具名常數 `PUBLISH_RETRY_LIMIT=20`**、**修正殘留的「finding 1 (see below)」review 對話式註解**（改成直接指向 `step_command_for` 自己的說明，不再依賴一個編號在檔案裡實際上並不存在的「finding 1」）。
9. **§5 表格內目前的 self-test 指令更新為 `Scripts/run-ipad-vertical-slice-acceptance.zsh __selftest`**（§5.1／§5.4 內的歷史敘述保持原樣，因為那些段落記錄的是各自當時真實使用的呼叫方式，不宜回溯改寫）。

修正過程中另外發現並修好一個屬於這次修正本身引入的新回歸（由 finding 3 新增的 `run_parallel_selftest_suites_case` 間歇重現，見 finding 3 說明）：`find_selftest_run_dir_for_pid` 從純 before/after 目錄差集改成純 PID 比對後，在兩個 `__selftest` suite 同時執行的高密度行程情境下可能撈到因 PID 重複使用而產生的舊目錄；修法已併入 finding 3 描述的雙條件設計。

修復後 self-test（本輪新增 12 個案例——4 個發布相關端到端／單元測試、2 個 Codex late-signal 重現、1 個平行 suite 驗證，加上為既有案例補上的 `before_dirs`／PID 雙條件比對——加上前五輪累計的既有案例，總計 151 個斷言）在前景連續執行 **10 次**，每次都是 Overall PASS、exit 0，每次結束後對 runner 本身與所有 helper 的精確程序檢查都確認無殘留（`run_parallel_selftest_suites_case` 本身會讓每次執行額外背景執行兩個完整的巢狀 `__selftest` suite，總執行時間因此明顯拉長，但仍在前景連續 10 次驗證的範圍內完成）。`Scripts/run-mvp-acceptance.zsh` self-test（本輪未變動）重新驗證仍全數通過。`git diff --check` 通過，無空白字元問題。

**本輪同樣未能重新執行真實 Task 8 自動驗收**：原因與 §5.5 相同——本次工作階段沒有可用的 exFAT 外接隨身碟、也沒有匯出三個 fixture 目錄環境變數。待使用者重新掛載隨身碟並匯出環境變數後補做。

## 6. 實機五項 gate（NOT RUN）

本次任務環境沒有可用、已簽署的真實 M1 以上 iPad 裝置可供操作，以下五項一律 **NOT RUN**，未猜測結果，未標為 PASS：

1. Files／外接 SSD 原地開啟 Sony RAW，調整 exposure，RAW checksum 不變 — **NOT RUN**
2. 同一 RAW 選「複製到此 iPad」，拔除 SSD 後仍能重開及調整 — **NOT RUN**
3. 連續拖動十個基本滑桿，預覽最後值一致，無永久 spinner 或舊 frame 假成功 — **NOT RUN**
4. work／focus、橫向／直向切換保留照片、調整值、縮放，且不新增 Undo — **NOT RUN**
5. force quit 後重開 App 副本，最後完整 autosave 可恢復；未完成寫入不覆蓋前一版 — **NOT RUN**

依計畫 Global Constraints 與 Task 8 說明，這不阻止先提交 runner與本報告，但 Task 8 Completion Gate（尤其「真實 M1+ iPad 能從 Files／外接 SSD 開啟 Sony RAW」等四項）仍未完成，待有真實裝置與使用者自行以 Xcode 26.6 選擇 Development Team 簽署後另行執行並更新本報告。

## 7. 已知限制

1. 實機五項 gate 全部 NOT RUN（見 §6），需要真實 M1+ iPad 裝置與使用者親自簽署、操作後才能完成。
2. 完整照片庫、單一寫入者租約、Preset/XMP UI、批次匯出等仍是刻意排除在本週垂直切片之外的後續計畫項目（見計畫文件 Spec Coverage and Deferred Plans），未在本報告範圍內驗證。
