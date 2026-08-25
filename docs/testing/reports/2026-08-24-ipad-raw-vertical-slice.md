# iPad RAW 編輯垂直切片驗收報告

> 安全提醒：本報告只記錄安全代號、雜湊與檔案系統類型，不含使用者本機的完整私人路徑；私人 `.ARW` 檔案本身不進入 Git。

## 0. 摘要

| 項目 | 內容 |
|---|---|
| 對應計畫 | `docs/superpowers/plans/2026-08-24-ipad-raw-editing-vertical-slice.md`（Task 8） |
| 驗收日期 | 2026-08-25 |
| 基準 commit | `114b1f669f91968137d8519ef4b71b819f277444`（`main`，即 Task 7 合併後的 HEAD） |
| Runner | `Scripts/run-ipad-vertical-slice-acceptance.zsh` |
| 自動驗收整體結論 | ☒ FAIL（根因是既有 `Scripts/run-mvp-acceptance.zsh` 的既有缺陷，非本 runner 或 Task 1–7 程式碼缺陷，詳見 §3、§5） |
| 實機五項 gate | 全部 NOT RUN（沒有可用的真實 M1+ iPad，見 §6） |

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
.build/ipad-vertical-slice/20260825T130853Z/summary.md
```

摘要內容：

| 步驟 | 結果 |
|---|---|
| strict-concurrency build | PASS |
| swift test | PASS（executed=826, skipped=0, failures=0） |
| iOS Simulator build | PASS |
| MVP preflight | PASS |
| MVP acceptance | **FAIL**（見下方根因分析） |
| 隱私掃描（summary／全部 log 是否殘留私人絕對路徑） | PASS |
| **Overall result** | **FAIL** |

### 3.1 根因分析：既有 `Scripts/run-mvp-acceptance.zsh` 的 RawFixtureTests 數量寫死過期

`MVP acceptance` 步驟失敗，並非本 runner 的邏輯錯誤，也不是 Task 1–7 交付的產品程式碼有 regression。已遮蔽的 `mvp-acceptance.log`（相對路徑 `.build/ipad-vertical-slice/20260825T130853Z/mvp-acceptance.log`）第 1898–1926 行完整記錄如下：

```
Test Case '-[LumaHarborIntegrationTests.RawFixtureTests testFullDecodeReturnsNativeResolution]' started.
Test Case '-[LumaHarborIntegrationTests.RawFixtureTests testFullDecodeReturnsNativeResolution]' passed (0.035 seconds).
Test Case '-[LumaHarborIntegrationTests.RawFixtureTests testFullResolutionExportMatchesTheSourceDimensions]' started.
Test Case '-[LumaHarborIntegrationTests.RawFixtureTests testFullResolutionExportMatchesTheSourceDimensions]' passed (0.280 seconds).
Test Case '-[LumaHarborIntegrationTests.RawFixtureTests testInteractivePreviewLatencyForARealPhoto]' started.
Test Case '-[LumaHarborIntegrationTests.RawFixtureTests testInteractivePreviewLatencyForARealPhoto]' passed (0.609 seconds).
Test Case '-[LumaHarborIntegrationTests.RawFixtureTests testPreviewDecodeHonoursTheRequestedSize]' started.
Test Case '-[LumaHarborIntegrationTests.RawFixtureTests testPreviewDecodeHonoursTheRequestedSize]' passed (0.036 seconds).
Test Case '-[LumaHarborIntegrationTests.RawFixtureTests testPreviewSchedulerDeliversARenderedFrameForARealRaw]' started.
Test Case '-[LumaHarborIntegrationTests.RawFixtureTests testPreviewSchedulerDeliversARenderedFrameForARealRaw]' passed (0.171 seconds).
Test Case '-[LumaHarborIntegrationTests.RawFixtureTests testSonyArwReportsPlausibleMetadata]' started.
Test Case '-[LumaHarborIntegrationTests.RawFixtureTests testSonyArwReportsPlausibleMetadata]' passed (0.005 seconds).
Test Case '-[LumaHarborIntegrationTests.RawFixtureTests testWhiteBalanceOffsetChangesTheRender]' started.
Test Case '-[LumaHarborIntegrationTests.RawFixtureTests testWhiteBalanceOffsetChangesTheRender]' passed (0.322 seconds).
Test Suite 'RawFixtureTests' passed at 2026-08-25 21:09:53.307.
	 Executed 9 tests, with 0 failures (0 unexpected) in 6.964 (6.964) seconds
Test Suite 'LumaHarborPackageTests.xctest' passed at 2026-08-25 21:09:53.307.
	 Executed 9 tests, with 0 failures (0 unexpected) in 6.964 (6.965) seconds
Test Suite 'Selected tests' passed at 2026-08-25 21:09:53.307.
	 Executed 9 tests, with 0 failures (0 unexpected) in 6.964 (6.965) seconds
RawFixtureTests: command completed
RawFixtureTests: FAIL (executed 9 tests, expected exactly 8)
```

全部 9 個 `RawFixtureTests` 案例（含針對真實 Sony `.ARW` fixture 的解碼、匯出、預覽延遲、metadata 與白平衡測試）**都真的通過，0 failures**。唯一的問題是既有 `Scripts/run-mvp-acceptance.zsh`（第 1027 行左右）呼叫
`evaluate_xctest_log "$RAWFIXTURE_LOG" 8`，寫死「必須剛好執行 8 個測試」；但 `RawFixtureTests` 目前有 9 個案例（`testWhiteBalanceOffsetChangesTheRender` 很可能是先前加入白平衡調整功能時新增、未同步更新這個寫死數字）。因為執行數量（9）與寫死的期望值（8）不符，`evaluate_xctest_log` 判定為 FAIL，導致 `Scripts/run-mvp-acceptance.zsh` 整體以 exit code 1 結束，連帶讓本 runner 的 `MVP acceptance` 步驟也記錄為 FAIL。

**這是 Task 8 授權修改清單之外的既有測試基礎設施缺陷**（`Scripts/run-mvp-acceptance.zsh` 不在本任務可修改的檔案清單內，也不是本 runner 新增的邏輯），依指示原樣停止並回報，未嘗試修正。使用者已確認先如實回報 FAIL，不在本次任務內修改該檔案。

### 3.2 其餘四個步驟的真實通過證據

- `strict-concurrency build`：`swift build -Xswiftc -strict-concurrency=complete` 於本機重複驗證兩次（獨立執行一次、runner 內一次），皆 `Build complete`，無新增 strict-concurrency 錯誤。
- `swift test`：826 個測試全部通過，0 failures，0 skipped（三個 fixture 環境變數皆已匯出，`RawFixtureTests` 的 9 個案例作為 `swift test` 整套測試的一部分一併真實執行，非略過）。
- `iOS Simulator build`：`(cd Apps/LumaHarborPad.swiftpm && xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build)` 顯示 `** BUILD SUCCEEDED **`，產出真正的 iOS Simulator `.app`（非單純 library target 編譯）。
- `MVP preflight`：`Scripts/run-mvp-acceptance.zsh --preflight-only` 確認 arm64、完整 Xcode、`xcodebuild`／`swift` 可用，以及三個 fixture 目錄（RAW／APFS／exFAT）皆存在且檔案系統類型正確。

## 4. Fixture 與測試目錄識別（不含私人絕對路徑）

| 項目 | 值 |
|---|---|
| RAW fixture 相機型號 | Sony ILCE-6400（α6400），鏡頭 Sony E 16-300mm F3.5-6.7（由 `mdls` 讀出的 Spotlight metadata 確認） |
| RAW fixture 檔案數 | 81 個 `.ARW` |
| APFS 測試目錄檔案系統 | apfs（本機開機磁碟區的資料卷） |
| exFAT 測試目錄檔案系統 | exfat（外接隨身碟，磁碟區名稱 `Untitled`） |

## 5. Runner 本身的驗證（不依賴上面的既有缺陷）

以下驗證與 §3.1 的既有缺陷無關，全部通過：

| 檢查 | 結果 |
|---|---|
| `zsh -n Scripts/run-ipad-vertical-slice-acceptance.zsh` | 通過，無語法錯誤 |
| `git diff --check` | 通過，無空白字元問題 |
| Runner self-test（`LUMAHARBOR_IPAD_RUNNER_SELFTEST=1`） | 全部通過，見 commit 訊息與對話紀錄的 RED→GREEN 證據 |
| summary／全部 log 隱私掃描（grep `/Users/`、`/Volumes/`、`/private/var/`、`/private/tmp/`） | 通過，無殘留 |

## 6. 實機五項 gate（NOT RUN）

本次任務環境沒有可用、已簽署的真實 M1 以上 iPad 裝置可供操作，以下五項一律 **NOT RUN**，未猜測結果，未標為 PASS：

1. Files／外接 SSD 原地開啟 Sony RAW，調整 exposure，RAW checksum 不變 — **NOT RUN**
2. 同一 RAW 選「複製到此 iPad」，拔除 SSD 後仍能重開及調整 — **NOT RUN**
3. 連續拖動十個基本滑桿，預覽最後值一致，無永久 spinner 或舊 frame 假成功 — **NOT RUN**
4. work／focus、橫向／直向切換保留照片、調整值、縮放，且不新增 Undo — **NOT RUN**
5. force quit 後重開 App 副本，最後完整 autosave 可恢復；未完成寫入不覆蓋前一版 — **NOT RUN**

依計畫 Global Constraints 與 Task 8 說明，這不阻止先提交 runner與本報告，但 Task 8 Completion Gate（尤其「真實 M1+ iPad 能從 Files／外接 SSD 開啟 Sony RAW」等四項）仍未完成，待有真實裝置與使用者自行以 Xcode 26.6 選擇 Development Team 簽署後另行執行並更新本報告。

## 7. 已知限制

1. **`Scripts/run-mvp-acceptance.zsh` 的 `RawFixtureTests` 期望數量寫死為 8，實際已有 9 個案例**（見 §3.1）。這會讓自動驗收的 `MVP acceptance` 步驟持續回報 FAIL，直到該檔案更新寫死數字為止；此檔案不在 Task 8 授權修改清單內，本次未修正。
2. 實機五項 gate 全部 NOT RUN（見 §6），需要真實 M1+ iPad 裝置與使用者親自簽署、操作後才能完成。
3. 完整照片庫、單一寫入者租約、Preset/XMP UI、批次匯出等仍是刻意排除在本週垂直切片之外的後續計畫項目（見計畫文件 Spec Coverage and Deferred Plans），未在本報告範圍內驗證。
