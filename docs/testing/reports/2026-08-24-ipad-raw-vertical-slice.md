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
.build/ipad-vertical-slice/20260825T134258Z/summary.md
```

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
| `Scripts/run-ipad-vertical-slice-acceptance.zsh` self-test（`LUMAHARBOR_IPAD_RUNNER_SELFTEST=1`） | 連續 10 次前景執行全部通過，每次結束後皆確認無殘留子程序 |
| `Scripts/run-mvp-acceptance.zsh` self-test（`LUMAHARBOR_RUNNER_SELFTEST=1`，含真實 signal tier） | 全部通過，含新的 under／exact／over 基準情境 |
| summary／全部 log 隱私掃描（grep `/Users/`、`/Volumes/`、`/private/var/`、`/private/tmp/`） | 通過，無殘留 |

### 5.1 Runner self-test 的第二輪修復（歷史紀錄，非目前限制）

第一輪修復（§3.1）完成後，`Scripts/run-ipad-vertical-slice-acceptance.zsh` 的 self-test 曾間歇性暴露兩個真實問題，已找到根因並修復：

1. **exit 141（SIGPIPE）導致 fail-fast 中途中斷**：`finalize_run` 原本用 `xcodebuild -version 2>/dev/null | head -n1` 取 Xcode 版本第一行；`head -n1` 讀滿一行就提早關閉讀取端，`xcodebuild` 仍在寫第二行時可能收到 SIGPIPE，在 `set -o pipefail` 下讓整條 pipeline 的結束碼變成 141，`set -e` 因此把它當成這一行失敗，整個 runner 在 `finalize_run` 執行到一半就意外中止——這正是「一般非 signal 失敗偶爾回傳 141 而非 1」的根本原因。修法：先完整取得 `xcodebuild -version` 的全部輸出（無 pipe，不會有任何一端提早關閉），再用 parameter expansion（`${xcode_version_output%%$'\n'*}`）取第一行，全篇搜尋確認這是唯一會在 `pipefail` 下產生非預期結束碼的 pipeline。
2. **TERM 中斷時 descendant 可能存活**：原本的 timeout／signal 清理邏輯會對同一個 root PID 呼叫兩次 `pgrep -P` 為基礎的子行程收集（一次送 TERM、等待後再收集一次送 KILL）；root 行程一旦先於其子行程結束，它的子行程會被 reparent（通常轉給 launchd），第二次以 root PID 為起點重新掃描就再也找不到它們，導致存活的 grandchild 逃過 KILL。修法：把收集（`collect_descendant_pids`）與送信號（`signal_pid_list`）拆開，只在送出第一個信號「之前」做一次完整的 PID 快照，TERM 與後續 KILL 都重複使用同一份快照，並改成由最深層 descendant 開始、root 最後才送信號。同時把 `run_with_timeout` 內原本用來即時鏡射 log 到終端機的背景 `tail -f` 整個移除——它是另一個「INT／TERM／HUP 剛好在錯的時間點打進來就可能殘留」的背景 PID 來源；現在每個步驟的輸出只寫進 log 檔，步驟結束後由呼叫端印出該步驟自己的 PASS／FAIL 一行。
3. **同時重寫 signal self-test 的中斷目標**：原本用裸的 `sleep 3` 當作步驟的替身指令，靠「等 log 檔出現」判斷已經開始執行、靠 `pgrep -f '^sleep 3$'` 這種名稱比對判斷有沒有殘留，兩者都有時序上的競態、也可能誤判其他程序。改成專用、確定性的兩層 helper：root helper 先把自己的 PID 寫進 pidfile，再啟動一個真正的 grandchild、等 grandchild 把自己的 PID 也寫進另一個 pidfile 且 `kill -0` 確認存活後，才 touch 一個 ready file；self-test 只等這個 ready file（不是猜固定秒數），確認就緒後才送出真正的 OS signal，事後也是直接用兩個 pidfile 內記錄的精確 PID 做「行程是否還在」的斷言，不再依賴名稱比對。

修復後 `LUMAHARBOR_IPAD_RUNNER_SELFTEST=1 Scripts/run-ipad-vertical-slice-acceptance.zsh` 在前景連續執行 10 次，每次都是 Overall PASS、exit 0，且每次結束後對 `interrupt-root`／`interrupt-child`／`fail-with-7`／`fake-swifttest`／runner 本身的精確程序檢查都確認無殘留。

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
