# LumaHarbor Mac-first MVP 驗收與收尾計畫

- 狀態：已核准，待 Claude 執行 Gate C 第一工作包
- 日期：2026-08-15
- 基準分支：`main`
- 基準 commit：`3a5f6798cfdd51fd6a814e43414ea261c60f23ea`
- 上位規格：`2026-08-13-mac-first-mvp-design.md`

## 1. 目的

目前主要功能與 lossless bounded scan pipeline 已完成 source-level review，但 Mac-first MVP 尚不能宣告完成。本階段的目標不是新增產品功能，而是用完整 Xcode、Apple Silicon、Sony `.ARW` 與外接儲存裝置，逐項關閉主規格 §13 的十個驗收條件。

完成時必須能回答三件事：

1. 所有自動化測試是否真的在完整 XCTest runtime 執行並通過，而不是只有 parse、typecheck 或 smoke。
2. Sony `.ARW` 的解碼、預覽、調整與完整尺寸 JPEG 匯出是否在 Apple Silicon／Metal 路徑正確。
3. APFS、exFAT、bookmark、離線／重接與唯讀情境是否在真實 App lifecycle 中不遺失資料。

## 2. 已知基準與限制

### 2.1 已通過

- `swift build -Xswiftc -strict-concurrency=complete`
- bounded pipeline 8 組 runtime smoke，含 10,000 筆 lossless／high-water `<= 2`
- 四個 test target strict-concurrency typecheck
- 全部測試原始碼 parse
- production 掃描路徑無 unbounded `AsyncStream`
- 共 316 個 `test*` 方法已存在；其中 `RawFixtureTests` 有 8 個真實 RAW 驗收案例

### 2.2 目前環境不能完成的事

目前開發主機實測為：

- `x86_64`
- `xcode-select -p` 指向 `/Library/Developer/CommandLineTools`
- `/Applications/Xcode.app` 不存在
- 未掛載 APFS／exFAT 測試 SSD

因此此機器不能提供 Apple Silicon、完整 XCTest、Metal/CIRAWFilter 或外接 SSD 的最終驗收證據。

### 2.3 已知測試缺口

- `FileBookmarkStore` 沒有獨立 unit tests；現有 bookmark／重啟恢復主要由 `LibraryLifecycleTests` 間接覆蓋，而且 host 無法建立 security-scoped bookmark 時會 skip。
- `startAccessingSecurityScopedResource()`／`stopAccessingSecurityScopedResource()` 的真實配對、stale bookmark 更新、App 重啟後恢復，仍須 sandboxed App／實機驗收。
- 主規格 §11 的 300 ms thumbnail、150 ms preview、快速切換 100 次與記憶體不線性成長，尚無 Apple Silicon Instruments 報告。

## 3. 安全與資料邊界

- 不直接使用或改寫使用者唯一一份相片；先複製 fixture 到專用測試目錄。
- 不格式化、不抹除、不重新分割任何磁碟。APFS／exFAT 測試只操作使用者指定的專用資料夾。
- 私人 Sony `.ARW` 不加入 Git、不上傳 CI、不寫進 log 的完整本機路徑。
- 測試前後記錄 RAW 的檔案大小、內容 fingerprint 與 modification date；任一變動即為 P0 data-corruption blocker。
- 自動化不可代替拔除／重接 SSD、資料夾選擇器、視覺品質與 Finder 匯出檔確認。

## 4. 執行順序

### Gate A：驗收機與素材就緒

必要條件：

1. Apple Silicon Mac，macOS 14 或更新。
2. 完整 Xcode，且 `xcode-select -p` 指向 Xcode Developer 目錄。
3. 至少兩張可由該 macOS 解碼的 Sony `.ARW`：一張橫向、一張直向；建議再加入高 ISO 與高光／陰影明顯的樣本。
4. 一個 APFS 測試目錄與一個 exFAT 測試目錄；兩者都只放 fixture 副本。
5. 保留至少一個可安全製造唯讀情境的測試目錄或唯讀 disk image。

Preflight 必須記錄：

```sh
uname -m
sw_vers
xcodebuild -version
xcode-select -p
swift --version
```

通過條件：`uname -m` 為 `arm64`、Xcode 可用、fixture 目錄含 `.ARW`、兩種檔案系統的專用目錄可識別。任何一項不成立就停止，不進入後續 gate。

### Gate B：完整 XCTest baseline

先在未修改 production code 的基準 commit 執行：

```sh
swift test -Xswiftc -strict-concurrency=complete
```

要求：

- 四個 test target 全部 compile、link、execute。
- 記錄 executed／passed／failed／skipped 數量與完整失敗名稱。
- bookmark 相關 skip、read-only skip 與 RAW fixture skip 必須分開列出；skip 不得當成通過。
- 先保存原始 log，再開始修正，避免失去 baseline 證據。

通過條件：非環境限定測試 0 failure；任何 crash、hang、data race、double-resume 或 sanitizer 訊息都視為 blocker。

### Gate C：Claude 第一工作包—驗收工具與測試缺口

Claude 只處理下列範圍，不改產品功能：

1. 新增 `FileBookmarkStore` unit tests：save/load round-trip、排序、單一損壞檔隔離、remove、idempotence、未知檔案忽略。
2. 建立一個 repo 內 acceptance runner，負責 preflight、完整 XCTest、`RawFixtureTests`、strict-concurrency build 與結果摘要；不得自行安裝 Xcode、掛載或修改磁碟。
3. 新增驗收報告模板，記錄硬體、OS、Xcode、fixture 代號／hash、filesystem、測試數、skip、效能與人工結果。
4. runner 必須在缺 fixture、非 `arm64`、缺 Xcode 或缺測試目錄時 fail closed，明確說明缺哪一項。

除非測試需要且 spec 先補充，Claude 不得為了方便測試而改公開 API、bookmark 格式、sidecar schema、掃描語意或 UI 流程。

Codex review gate：檢查 runner 不會洩漏私人路徑、不會對磁碟做 destructive operation、測試不是只 parse/typecheck，並在可用環境重跑後才 commit。

#### Gate C 實作狀態（2026-08-15，Claude 實作，Codex review 通過，待 commit）

新增檔案（尚未 commit）：

- `Tests/PhotoLibraryCoreTests/FileBookmarkStoreTests.swift`：13 個測試，覆蓋 save/load round-trip、`load` 未知 library 回傳 nil、同 library 重複 save 覆寫、`loadAll` 依 `addedAt` 排序（刻意以非插入順序 save 驗證排序來源）、`loadAll` 對不存在目錄回傳空陣列、單一損壞 JSON／空檔隔離且其他有效檔仍可讀、忽略非 JSON 檔案與忽略 JSON 但 schema 不符的檔案、remove、remove 只刪對應 library、remove 對未知 library 與重複 remove 皆為 no-op。全部使用真實暫存目錄（`TemporaryDirectoryTestCase`）與合成 `bookmarkData`，不依賴 security-scoped bookmark runtime，無 sleep。
- `Scripts/run-mvp-acceptance.zsh`：repo 內 acceptance runner。`--preflight-only` 供無 Apple Silicon／Xcode 主機做 fail-closed 驗證；預設完整跑 preflight → strict-concurrency build → 完整 `swift test -Xswiftc -strict-concurrency=complete` → `swift test --filter RawFixtureTests`。preflight 驗 `arm64`、`/Applications/Xcode.app`、`xcode-select -p` 指向 Xcode、`xcodebuild -version`、`swift --version`，以及三個必要環境變數（`LUMAHARBOR_RAW_FIXTURE_DIR` 存在且至少一個大小寫皆可的 `.ARW`；`LUMAHARBOR_APFS_TEST_DIR`／`LUMAHARBOR_EXFAT_TEST_DIR` 存在且經 `df`＋`mount`（而非解析路徑文字，避免空白路徑歧義）識別為對應 filesystem）；任一項缺失即整體 fail closed，不進入後續步驟。全程只讀（`stat`／`df`／`mount`／glob 列檔名），不 mount、格式化、刪除或 chmod 使用者測試資料。從不印出三個環境變數的完整路徑，只印變數名稱、PASS/FAIL 與必要時的安全 basename。結果與原始 log 寫入 repo-ignored 的 `.build/mvp-acceptance/<timestamp>/`（`preflight.log`、`strict-build.log`、`swift-test.log`、`raw-fixture-test.log`、`summary.md`）。任一步驟失敗即整體 exit non-zero，後續步驟標記 `SKIPPED (...)` 而非宣稱 PASS。
- `docs/testing/mvp-acceptance-report-template.md`：驗收報告模板，涵蓋硬體/OS/Xcode/Swift、fixture 安全代號與 SHA-256（不含私人絕對路徑）、APFS/exFAT、Gate B executed/passed/failed/skipped 分類、`RawFixtureTests` 8 案例逐項與人工補驗、Gate E 十項 APFS/exFAT 對照表、Gate F 人工矩陣與 Instruments 指標、P0/P1/P2 清單、主規格 §13 十項 sign-off。

未改動任何 production 原始碼；`BookmarkStoring` 公開 API、`.lumaharbor` sidecar schema、掃描語意與 UI 流程均未動。

**實際執行的命令與結果**（本機：`x86_64`、`xcode-select -p` 為 `/Library/Developer/CommandLineTools`、無 `/Applications/Xcode.app`）：

| 命令 | 結果 |
|---|---|
| `swift build -Xswiftc -strict-concurrency=complete` | exit 0 |
| 四個 test target（含新檔）`swiftc -typecheck -enable-testing -strict-concurrency=complete -I /private/tmp -I .build/x86_64-apple-macosx/debug/Modules` | 各 exit 0，0 error |
| 全部 `Tests/**/*.swift` + `Package.swift` `swiftc -frontend -parse` | exit 0，0 error |
| `git diff --check` | exit 0，無輸出 |
| `zsh -n Scripts/run-mvp-acceptance.zsh` | exit 0 |
| `Scripts/run-mvp-acceptance.zsh --preflight-only`（env 變數皆未設） | 依預期 fail closed，exit 1，逐項列出缺失（arm64／Xcode.app／xcode-select／xcodebuild／三個環境變數），無私人路徑輸出 |
| `Scripts/run-mvp-acceptance.zsh --preflight-only`（以合成 fixture 目錄與 `$HOME`／`/tmp` 作為假 APFS/exFAT 目錄手動驗證） | 正確判斷 `.ARW`（含大小寫）、正確識別 `apfs`，並在 filesystem 類型不符時正確 FAIL；含空白路徑目錄同樣正確識別 |
| `Scripts/run-mvp-acceptance.zsh`（無 `--preflight-only`，preflight 失敗情境） | 正確跳過 build/test 步驟並標記 `SKIPPED`，不宣稱 PASS，exit 1 |

**環境阻擋（非產品失敗，未真正執行 XCTest）**：

- 本機 `x86_64`、只有 Command Line Tools、無 `/Applications/Xcode.app`，因此 runner 的 preflight 必然 fail closed；`FileBookmarkStoreTests` 與其餘 313+13 個測試方法尚未在真正 XCTest runtime 執行，typecheck／parse 通過不等於測試通過。
- 未取得 Apple Silicon、Sony `.ARW` fixture、APFS／exFAT 專用測試目錄，因此 runner 的完整路徑（strict build → full test → `RawFixtureTests`）與 `docs/testing/mvp-acceptance-report-template.md` 都尚未在真實條件下填寫過。
- Gate D/E/F（Sony ARW、Metal/CIRAWFilter、APFS/exFAT bookmark lifecycle、UI、Instruments）仍待 Gate A 就緒後在目標機執行；本工作包不涵蓋。

#### Gate C Codex review 第一輪：兩個 blocker 已修（2026-08-15，Claude，未 commit）

Codex review 找到兩個真的問題，皆已修正：

1. **`run_logged_step` 只看 `swift test` exit code，會把有 skip 的執行誤標 PASS。** `swift test` 在 XCTest 回報 skipped tests 時通常仍 exit 0；原本的 runner 只檢查指令 exit code，等於把「有 skip」跟「真正全部執行且通過」混為一談，違反 spec「skip 不得當成通過」。修法：新增 `parse_xctest_summary`（抓 log 中最後一行 XCTest `Executed N tests, with (M tests? skipped, )?F failures? (...)` 摘要，回傳 executed/skipped/failures 三個數字；抓不到就視為無法判定，不得放行）與 `evaluate_xctest_log`（skipped 必須恰好 0；若指定必要 executed 數則必須完全相等；failures 必須 0；任一條件不成立就回傳非零並附上具體原因字串）。「full swift test」與「RawFixtureTests」兩步驟現在在指令 exit 0 之後還會呼叫 `evaluate_xctest_log`，只有真正 0 skip（且 RawFixtureTests 恰好 executed 8）才標 `PASS`；否則標 `FAIL (原因)`，`overall_ok` 一併歸零。**strict-concurrency build 步驟不套用此檢查**（它沒有 test skip 的概念，維持只看 exit code）。regex 特別處理 XCTest 單複數（`test skipped` vs `tests skipped`，包含 `0 tests skipped`）：判斷邏輯是把擷取到的數字跟 `0` 做數值比較，不是用「有沒有出現 skipped 字樣」這種容易把「0 tests skipped」誤判成「有 skip」的字串比對。
2. **報告模板 `RawFixtureTests` 表格第 2–8 列測試名稱是空的。** 已補上 `Tests/LumaHarborIntegrationTests/RawFixtureTests.swift` 現有的完整 8 個測試名稱（`testEveryFixtureDecodes`、`testSonyArwReportsPlausibleMetadata`、`testPreviewDecodeHonoursTheRequestedSize`、`testFullDecodeReturnsNativeResolution`、`testWhiteBalanceOffsetChangesTheRender`、`testFullResolutionExportMatchesTheSourceDimensions`、`testExportingNeverModifiesTheOriginal`、`testPreviewSchedulerDeliversARenderedFrameForARealRaw`），與原始碼逐一核對過。

新增的 parser/self-check 用內部函式 `run_selftest`，由**未公開的環境變數** `LUMAHARBOR_RUNNER_SELFTEST=1` 觸發（不是新的 CLI 參數，`--preflight-only` 是唯一對外參數，維持不變），用合成 XCTest summary 文字驗證 6 種情境：0 skip 通過、1 test skipped 失敗、executed=7/required=8 失敗、executed=8/required=8 且 0 skip 通過、executed=9/required=8 失敗、log 裡完全沒有 summary 行時失敗（不得誤判成通過）。全部使用 `mktemp -d` 建立的私有暫存目錄，跟使用者的 fixture／APFS／exFAT 測試目錄無關，執行完自行 `rm -rf` 清理自己的暫存目錄（不是對使用者測試資料的破壞性操作）。

**本輪重跑的命令與結果**（本機同前：`x86_64`、CommandLineTools、無 Xcode）：

| 命令 | 結果 |
|---|---|
| `zsh -n Scripts/run-mvp-acceptance.zsh` | exit 0 |
| `LUMAHARBOR_RUNNER_SELFTEST=1 Scripts/run-mvp-acceptance.zsh` | exit 0，6 個合成情境全部符合預期（PASS/FAIL 各自正確） |
| `Scripts/run-mvp-acceptance.zsh --preflight-only`（env 變數皆未設） | exit 1，fail closed，訊息不含私人路徑 |
| `Scripts/run-mvp-acceptance.zsh --bogus-flag` | exit 2，未知參數被拒絕（確認沒有意外新增 CLI 參數） |
| `git diff --check` | 第一次抓到 spec 文件一處 trailing whitespace，已修正；重跑 exit 0 |
| `swift build -Xswiftc -strict-concurrency=complete` | exit 0（production 未變動） |
| `PhotoLibraryCoreTests`（含既有 `FileBookmarkStoreTests.swift`，本輪未改）`swiftc -typecheck -enable-testing -strict-concurrency=complete -I /private/tmp -I .build/x86_64-apple-macosx/debug/Modules` | exit 0 |

未再改動任何 production 原始碼，也未改動 `FileBookmarkStoreTests.swift`；只動 `Scripts/run-mvp-acceptance.zsh`、`docs/testing/mvp-acceptance-report-template.md` 與本 spec 檔案。

#### Gate C Codex review 第二輪：兩個 runner blocker 已修（2026-08-15，Claude，未 commit）

Codex 第二輪只 review `Scripts/run-mvp-acceptance.zsh`，找到兩個真的問題，皆已修正；`FileBookmarkStoreTests.swift`、`docs/testing/mvp-acceptance-report-template.md` 本輪未再改動：

1. **`run_logged_step` 在指令 exit 0 就先印出 `PASS`，之後才對 test step 做 `evaluate_xctest_log` skip 判定，導致 console 在有 skip 時會先出現一個錯誤的 `PASS`。** 即使最終 summary 檔與最終 exit code 是對的，console 這一行本身已經是矛盾／誤導狀態。修法：`run_logged_step` 改成中性輸出，指令跑完只印 `"<name>: command completed"` 或 `"<name>: command failed"`，不再自稱 PASS/FAIL。新增 `announce_step_result`，是全腳本唯一印出某個 step 最終 PASS/FAIL(原因) 的地方：strict build 由呼叫端在拿到 `run_logged_step` 結果後立刻呼叫；full swift test／RawFixtureTests 則是在 `run_logged_step` 成功之後、`evaluate_xctest_log` 也判定通過後才呼叫並印 `PASS`，任一環節失敗就只印 `FAIL (原因)`，不會有 console 先 PASS 後 FAIL 的矛盾輸出。console 與 `summary.md` 現在保證是同一份最終狀態字串。
2. **`parse_xctest_summary` 只認得 `"N tests skipped, F failures"`（逗號分隔），沒有涵蓋 XCTest 另一種常見措辭 `"N tests skipped and F failures"`（`and` 分隔）。** 若實機 XCTest 印出的是 `and` 形式，原本的 regex 完全不會命中 skip 子句，會直接落到「沒有 skip 子句」那個分支、把 skip 數當成 0——等於 Finding 1 修好的問題在另一種措辭下又會重現。修法：regex 的分隔字改成 `(,| and)`，兩種分隔都能命中，並保留原本「擷取到的數字跟 0 做數值比較」而非「有沒有出現 skipped 字樣」的判斷方式，`0 tests skipped` 兩種分隔形式一樣不會被誤判成有 skip。

self-check（`LUMAHARBOR_RUNNER_SELFTEST=1`，同上一輪，未新增 CLI 參數）新增兩個情境並保留原有 6 個：`and`-form 單數 skip（`"1 test skipped and 0 failures"`）必須 FAIL、comma-form 複數 skip（`"2 tests skipped, 0 failures"`）必須 FAIL；連同原有的 0 skip 通過、comma-form 單數 skip 失敗、executed=7/8/9 vs required=8、log 無 summary 行，現為 8 個情境全部通過。另外用一個獨立於 self-check 的臨時 harness（複製 `run_logged_step`／`announce_step_result`／`evaluate_xctest_log` 邏輯，餵一個會印出帶 skip 摘要且 exit 0 的假指令）人工確認過 console 輸出順序：`"==> RawFixtureTests"` → 指令原始輸出 → `"RawFixtureTests: command completed"` → `"RawFixtureTests: FAIL (1 test(s) skipped ...)"`，全程沒有出現任何 `PASS` 字樣。

**本輪重跑的命令與結果**（本機同前：`x86_64`、CommandLineTools、無 Xcode）：

| 命令 | 結果 |
|---|---|
| `zsh -n Scripts/run-mvp-acceptance.zsh` | exit 0 |
| `LUMAHARBOR_RUNNER_SELFTEST=1 Scripts/run-mvp-acceptance.zsh` | exit 0，8 個合成情境（含新增的 and-form 單數與 comma-form 複數 skip）全部符合預期 |
| `Scripts/run-mvp-acceptance.zsh --preflight-only`（env 變數皆未設） | exit 1，fail closed，訊息不含私人路徑 |
| `git diff --check` | exit 0，無輸出 |

未改動任何 production 或 test 原始碼；只改 `Scripts/run-mvp-acceptance.zsh` 與本 spec 檔案（本節）。

### Gate D：Sony ARW／Metal／匯出

使用 repo 外 fixture：

```sh
LUMAHARBOR_RAW_FIXTURE_DIR=/path/to/private/fixtures \
  swift test --filter RawFixtureTests
```

8 個既有案例不得 skip，並確認：

- 每個 fixture 可由 `CIRAWFilter` 解碼。
- EXIF 尺寸、SONY make/model 與拍攝時間合理。
- 1024 px preview 不意外使用完整解析度。
- full decode 尺寸等於 RAW native size。
- white balance 調整確實改變輸出。
- JPEG 尺寸正確且標記 sRGB。
- 匯出前後 RAW fingerprint 與 modification date 完全一致。
- real-RAW preview scheduler 交付有效畫面。

人工補驗：方向、曝光、色偏、banding、黑白點與高光／陰影調整不能有明顯錯誤。

### Gate E：APFS／exFAT 與 bookmark lifecycle

兩種 filesystem 各完整執行一次：

1. 由系統面板加入專用測試資料夾。
2. 增量掃描、縮圖逐步出現，不等待全部掃完。
3. 編輯一張照片並確認 `.lumaharbor` sidecar 落地。
4. 關閉 App、重新啟動，確認 bookmark 恢復、selection／edit 可重新載入。
5. 刪除本機 SQLite 與 cache 後重建，PhotoID 與 edits 不變。
6. 將資料夾改名後走 relink，不能猜路徑或另建 identity。
7. App 開啟時拔除 SSD：保留 cached thumbnail，不 crash；未保存 edit 留在記憶體並可在重接後 retry。
8. 重接 SSD 並重新授權，既有 library identity 與 sidecar edit 保留。
9. 唯讀情境允許瀏覽，但保存與匯出顯示 actionable error，不能顯示偽成功。
10. 加入損壞 RAW 與損壞 sidecar：單檔失敗、掃描繼續、sidecar 被隔離而非覆寫。

通過條件：APFS 與 exFAT 的十項都留有結果；任何 crash、原檔變動、PhotoID 漂移、edit 遺失或偽成功都是 blocker。

### Gate F：UI 與效能

人工功能矩陣：

- 十個調整項目都能即時預覽與各自重設。
- 原圖比較、Undo、Redo、整張重設正確。
- 滑桿後立即切換照片時，edit 先保存；保存失敗時停留原照片。
- 單張 JPEG 匯出、同名流水號、取消清除暫存檔、Finder 顯示正確。
- offline、read-only、unsupported、corrupt、disk-full 類錯誤都有下一步。

Apple Silicon + Instruments：

- cached thumbnail 目標 `<= 300 ms`。
- slider preview 目標 `<= 150 ms`；超時時先有互動品質畫面。
- 快速切換照片 100 次後，in-flight work 與記憶體不持續線性成長。
- 大資料夾掃描 high-water 維持 bounded，UI main thread 不執行 RAW decode、hash 或 JPEG export。

效能未達目標可列 P1，但若 UI 無回應、記憶體持續線性成長或工作不能取消，升級為 blocker。

### Gate G：修正、回歸與最終簽核

每個實際失敗各自建立小型工作包：

1. 保存完整重現步驟、環境與 log。
2. Claude 實作最小修正與 regression test，不混入其他功能。
3. Codex 做 source review，重跑受影響 target、完整 suite 與對應實機案例。
4. 一個修正一個可回溯 commit；P0／P1 未清空前不得標記 MVP 完成。

最終通過需要：

- 主規格 §13 十項全部有自動或人工證據。
- 完整 XCTest 0 failure；環境限定 skip 都已有對應實機結果。
- Sony `.ARW`、APFS、exFAT、bookmark、Metal/CIRAWFilter、JPEG sRGB 全部通過。
- 無已知 data-corruption blocker。
- 驗收報告列出仍接受的 P2／限制，且不把 MVP 後功能混入本階段。

## 5. 分工

### Claude

- 依明確工作包實作 runner、測試缺口或具體 regression fix。
- 不 commit／push；接近用量上限時先更新 `/Users/u/AI-Shared/HANDOFF.md`。
- 不因環境失敗改動產品語意，也不把 skip 宣稱為 pass。

### Codex

- 維護 spec、baseline 與驗收矩陣。
- review Claude diff，獨立重現與驗證 blocker。
- 通過後負責 commit／push，並更新 HANDOFF。

### 使用者／實機操作者

- 指定可安全使用的 APFS／exFAT 測試目錄與私人 Sony `.ARW` fixture。
- 執行或允許資料夾選擇、App 重啟、SSD 拔除／重接與視覺品質判斷。
- 確認測試目錄內資料可被寫入／隔離；原始照片不進入自動化修改範圍。

## 6. 下一個可執行動作

Gate C 已完成並通過 Codex review。推送後在另一台驗收機：

1. checkout 最新 `origin/main`，確認符合 Gate A 的 Apple Silicon + Xcode、Sony `.ARW` fixtures、APFS 與 exFAT 專用測試目錄都已就緒。
2. 設定 `LUMAHARBOR_RAW_FIXTURE_DIR`、`LUMAHARBOR_APFS_TEST_DIR`、`LUMAHARBOR_EXFAT_TEST_DIR`，先執行 `Scripts/run-mvp-acceptance.zsh --preflight-only`。
3. preflight 通過後執行 `Scripts/run-mvp-acceptance.zsh`，保存 `.build/mvp-acceptance/<timestamp>/` 的原始 logs 與 summary。
4. 複製 `docs/testing/mvp-acceptance-report-template.md` 填寫 Gate D、E、F 與主規格 §13 sign-off；只針對實際失敗建立後續修正工作包。
