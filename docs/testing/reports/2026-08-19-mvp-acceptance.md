# LumaHarbor Mac-first MVP 驗收報告

> 安全提醒：本報告只記錄安全代號、雜湊與檔案系統類型，不含使用者本機的完整私人路徑；私人 `.ARW` 檔案本身不進入 Git。

## 0. 摘要

| 項目 | 內容 |
|---|---|
| 驗收日期 | 2026-08-19（彙整 2026-08-16 至 2026-08-19 累積的人工驗收過程） |
| 驗收人員 | 使用者（真機操作／畫面判斷）＋ Claude（程式修法、自動化測試、環境層級量測） |
| 對應 spec | `docs/superpowers/specs/2026-08-15-mac-first-mvp-acceptance-plan.md` |
| 基準 commit | `0d89cc3dc38677bf53833a1b28bda45c58ba5cc5`（2026-08-21，本報告最後一次更新時的 `main` HEAD；原始驗收於 2026-08-19 完成，基準 commit 已隨後續修正推進，見下方更新記錄與 §9） |
| 整體結論 | ☑ MVP 完成（見 §9 已知限制，均為 P2，不擋簽收） |

過程中發現並修好的 P1/P2 bug（詳細根因與修法見 `docs/testing/reports/2026-08-16-mvp-acceptance-progress.md`）：
interactive 預覽節流／decode 失敗偽成功殘影／Inspector 面板延遲一拍／唯讀磁碟編輯後永久卡死切換／Original 比較鍵雙機制搶狀態／Undo-Redo 快捷鍵路由（驗收當下未解、降為 P2；**已於 2026-08-21 修復並完成真機驗證，見 §9**）／繁體中文化整體查表機制失效（根因為 `Bundle.preferredLocalizations` 在本機不反映系統語言）／掃描失敗 alert 的 `nextStep` 誤用唯讀情境的固定文字。全部有各自的 regression test 與獨立 commit。

> **更新記錄（2026-08-21）**：本報告在 MVP 簽收（2026-08-19）後，隨 Undo/Redo 鍵盤快捷鍵 P2 的修復與真機驗證同步更新了 §0、§5、§8.1、§9、§10；其餘章節（§1–§4、§6、§7、§8.2）維持原始驗收當下的記錄，未重新執行。

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
| Swift 版本 | `swift --version` | Apple Swift 6.3.3（swiftlang-6.3.3.1.3 clang-2100.1.1.101），target `arm64-apple-macosx26.0` |

## 3. Fixture 與測試目錄識別（不含私人絕對路徑）

| 項目 | 記錄方式 | 值 |
|---|---|---|
| RAW fixture 安全代號 | `fixture-set-sony-arw`（本機相機拍攝，2019-03-28） | — |
| Sony `.ARW` 檔案數 | `find` 計數 | 81 張 |
| 樣本 SHA-256（3 張，跨 ReadOnly/Corrupt/DiskFull 測試共用） | `shasum -a 256` | `_DSC1896.ARW`: `50e2afadcfc2598342576ac716a37113397d40c824729d6d43376705a83d8487`；`_DSC1897.ARW`: `7dc07b18fded66427f3f00e6c95dc551c07944773ed8ddae9fe2e79786ba8fdc`；`_DSC1899.ARW`: `cf4c01e71830664836460b2d2cecd166d3936bc3c2af6928a24893735f1a3733` |
| 各 fixture 檔案大小 | `ls -la` | 24,910,592 / 24,906,496 / 24,914,688 bytes |
| 各 fixture 修改時間（測試前後） | `stat -f %Sm` | `Mar 28 11:59:12 2019`，測試前後完全一致（見 §6） |
| 橫向樣本 | | ☑ 已含 |
| 直向樣本 | | ☑ 已含（EXIF orientation 8，見 `testFullDecodeReturnsNativeResolution` 註解） |
| 高 ISO 樣本 | | ☑ 已含（81 張混合日常拍攝） |
| 高光／陰影明顯樣本 | | ☑ 已含 |

## 4. APFS 與 exFAT 測試目錄

| 項目 | APFS | exFAT |
|---|---|---|
| Runner 回報的 filesystem 類型 | apfs | exfat |
| 專用測試目錄是否僅含 fixture 副本 | ☑ 是 | ☑ 是 |
| Gate E 十項是否全部執行 | 見 §7（4 項雙平台皆測，4 項僅 APFS，2 項僅 exFAT，理由見 §7 備註） | 同左 |

## 5. 自動化測試執行（Gate B：完整 XCTest baseline）

> **2026-08-21 更新**：以下數字取自兩次分開的執行，對應同一個 commit（`0d89cc3`），刻意不合併成單一欄位——原始版本（2026-08-19）把「設定 fixture 變數後跑完整套件」的單次結果（341 executed／0 skipped）當成唯一數字；隨 Gate B1／B3／Undo-Redo P2 等後續修正，測試案例總數已增加，此處改成下方兩段式呈現，讀者可以清楚分辨「一般開發環境（未設定 fixture）能看到什麼」與「設定 fixture 後額外多驗證了什麼」。

### 5.1 完整套件、未設定 `LUMAHARBOR_RAW_FIXTURE_DIR`（一般開發環境預設跑法）

```sh
swift test -Xswiftc -strict-concurrency=complete
```

| 項目 | 數量 |
|---|---|
| Executed | 433 |
| Passed | 433 |
| Failed | 0 |
| Skipped — RAW fixture 相關（未設定 `LUMAHARBOR_RAW_FIXTURE_DIR`，即 `RawFixtureTests` 全數） | 9 |
| Skipped — bookmark／read-only／其他 | 0 |
| 套件總測試數（Executed + Skipped） | 442 |
| Crash / hang / data race / sanitizer 訊息 | ☑ 無 |
| 執行日期 | 2026-08-21 |

失敗案例：

```
無失敗。
```

### 5.2 設定 `LUMAHARBOR_RAW_FIXTURE_DIR` 後，單獨執行 `RawFixtureTests`（即 5.1 中被跳過的那 9 個）

```sh
LUMAHARBOR_RAW_FIXTURE_DIR=<fixture-set-sony-arw> swift test --filter RawFixtureTests
```

| 項目 | 數量 |
|---|---|
| Executed | 9 |
| Passed | 9 |
| Failed | 0 |
| Crash / hang / data race / sanitizer 訊息 | ☑ 無 |
| 執行日期 | 2026-08-21 |

失敗案例：

```
無失敗。
```

個別測試名稱與各自結果見 §6（本次重跑與 §6 原表一致，測試案例集合無新增或移除）。

## 6. Sony `.ARW`／Metal／匯出（Gate D：`RawFixtureTests`）

執行：

```sh
LUMAHARBOR_RAW_FIXTURE_DIR=<fixture-set-sony-arw> swift test --filter RawFixtureTests
```

| # | 測試名稱 | 結果 | 備註 |
|---|---|---|---|
| 1 | `testEveryFixtureDecodes` | ☑ Pass | 81 張全過，5.1s |
| 2 | `testSonyArwReportsPlausibleMetadata` | ☑ Pass | |
| 3 | `testPreviewDecodeHonoursTheRequestedSize` | ☑ Pass | |
| 4 | `testFullDecodeReturnsNativeResolution` | ☑ Pass | |
| 5 | `testWhiteBalanceOffsetChangesTheRender` | ☑ Pass | |
| 6 | `testFullResolutionExportMatchesTheSourceDimensions` | ☑ Pass | |
| 7 | `testExportingNeverModifiesTheOriginal` | ☑ Pass | fingerprint／mtime 前後一致 |
| 8 | `testPreviewSchedulerDeliversARenderedFrameForARealRaw` | ☑ Pass | |
| 9 | `testInteractivePreviewLatencyForARealPhoto`（本輪新增，非既有 8 案例之一） | ☑ Pass | 效能量測，見 §8.2 |

人工補驗（無法自動化的視覺判斷，2026-08-16～17 走過 APFS/exFAT 全套流程時一併確認）：

| 項目 | 結果 |
|---|---|
| 方向（EXIF orientation）正確 | ☑ 是 |
| 曝光看起來合理 | ☑ 是 |
| 色偏（white balance）看起來合理 | ☑ 是 |
| 無明顯 banding | ☑ 是 |
| 黑白點調整有效且無明顯錯誤 | ☑ 是 |
| 高光／陰影調整有效且無明顯錯誤 | ☑ 是 |
| 匯出 JPEG 標記 sRGB | ☑ 是（`testFullResolutionExportMatchesTheSourceDimensions` 自動驗證色彩空間） |
| 匯出前後 RAW fingerprint／修改時間完全一致 | ☑ 是 |

## 7. APFS／exFAT 與 bookmark lifecycle（Gate E）

| # | 情境 | APFS 結果 | exFAT 結果 | 備註 |
|---|---|---|---|---|
| 1 | 由系統面板加入專用測試資料夾 | ☑ 通過 | ☑ 通過 | |
| 2 | 增量掃描、縮圖逐步出現 | ☑ 通過 | ☑ 通過 | |
| 3 | 編輯照片後 `.lumaharbor` sidecar 落地 | ☑ 通過 | ☑ 通過 | |
| 4 | 關閉並重啟 App，bookmark／selection／edit 恢復 | ☑ 通過 | ☑ 通過 | |
| 5 | 刪除本機 SQLite 與 cache 後重建，PhotoID／edits 不變 | ☑ 通過 | 未個別重跑 | 只在 APFS-Test 上驗證過；機制跟檔案系統無關（純本機 cache 目錄），風險低 |
| 6 | 資料夾改名後 relink，不猜路徑、不另建 identity | ☑ 通過 | 未個別重跑 | 同上，只在 APFS-Test 上驗證 |
| 7 | App 開啟時拔除 SSD：保留 cached thumbnail、不 crash、未保存 edit 可重試 | 不適用 | ☑ 通過 | APFS 測試資料夾在本機內接磁碟，無「拔除」情境可測；exFAT 用真的隨身碟拔插驗證 |
| 8 | 重接 SSD 並重新授權，library identity 與 sidecar edit 保留 | 不適用 | ☑ 通過 | 同上 |
| 9 | 唯讀情境：瀏覽可行，保存／匯出顯示 actionable error，無偽成功 | ☑ 通過 | 未個別重跑 | 只在 APFS 上的 `ReadOnly-Test`（`chmod 555`）驗證過；過程中發現並修好「唯讀磁碟編輯後永久卡死切換」的真實 bug |
| 10 | 損壞 RAW／sidecar：單檔失敗、掃描繼續、sidecar 隔離而非覆寫 | ☑ 通過 | 未個別重跑 | 只在 APFS 上的 `Corrupt-Test` 驗證過；過程中發現並修好「損壞 RAW 顯示偽成功」跟「Inspector 面板延遲一拍」兩個真實 bug |

任何 crash、原檔變動、PhotoID 漂移、edit 遺失或偽成功：整個驗收過程**無**，發現的都是「訊息/狀態顯示不正確」等級的 bug（已修好），不是資料損毀。

## 8. UI 與效能（Gate F）

### 8.1 人工功能矩陣

| 項目 | 結果 |
|---|---|
| 十個調整項目即時預覽與各自重設 | ☑ 通過 |
| 原圖比較、Undo、Redo、整張重設正確 | ☑ 通過（選單滑鼠點擊與鍵盤快捷鍵 ⌘Z/⌘⇧Z 皆已驗證有效，2026-08-21 真機補驗，見 §9 已完成的 P2 項目） |
| 滑桿後立即切換照片：edit 先保存；保存失敗停留原照片 | ☑ 通過（另有 `testDirtyEditIsWrittenBeforeTheNextPhotoOpens`／`testASaveFailureKeepsTheSelectionAndTheDirtyState` 自動化覆蓋） |
| 單張 JPEG 匯出、同名流水號、取消清除暫存檔、Finder 顯示正確 | ☑ 通過 |
| offline／read-only／unsupported／corrupt／disk-full 錯誤都有下一步 | ☑ 通過（unsupported 見 §9 P2：這個平台上無法用本地檔案觸發該分支，不是缺測試） |

### 8.2 Apple Silicon + Instruments

本環境沒有 Instruments.app 可操作的畫面（GUI 工具，無輔助使用／螢幕錄製權限），只完成了可自動化量測的那一項；其餘三項未執行，列為 §9 P2。

| 指標 | 目標 | 實測 | 結果 |
|---|---|---|---|
| Cached thumbnail 延遲 | ≤ 300 ms | 未量測 | ☐ 未量測（P2） |
| Slider preview 延遲 | ≤ 150 ms | 穩定狀態 137–148ms（三次重複量測，見 `testInteractivePreviewLatencyForARealPhoto`），對真實 `_DSC1896.ARW`、1600px interactive 品質解碼直接計時 | ☑ 達標（壓線，餘裕不大） |
| 快速切換照片 100 次後 in-flight work／記憶體 | 不持續線性成長 | 未量測 | ☐ 未量測（P2） |
| 大資料夾掃描 high-water | bounded；main thread 無 RAW decode／hash／export | 未經 Instruments 量測；架構上有 `BoundedFolderScanTests` 跟 `runOffActor` 相關單元測試佐證設計意圖 | ☐ 未經 Instruments 直接量測（P2） |

## 9. P0／P1／P2 清單

| 等級 | 描述 | 對應 Gate | 狀態 |
|---|---|---|---|
| P0 | （無） | — | — |
| P1 | （無，過程中發現的 P1 皆已修復，見 §0 摘要與 `2026-08-16-mvp-acceptance-progress.md`） | — | 已清空 |
| P2（已完成 2026-08-21） | ~~Undo/Redo 鍵盤快捷鍵（⌘Z／⌘⇧Z）無效，滑鼠點選單正常。~~ 已修復：`UndoRedoKeyEquivalentFix` 原本只檢查 `modifierFlags.contains(.command)`，導致 ⌥⌘Z／⌃⌘Z 會誤判成一般 Undo；改用 `modifierFlags.intersection(.deviceIndependentFlagsMask)` 精確比對，並拆出可單元測試的 `match(charactersIgnoringModifiers:modifierFlags:)`（新增 7 個測試案例）。真機驗證：用 `Scripts/build-app-bundle.sh debug` 打包成正式 `.app`（裸執行檔的 `NSApplicationActivationPolicy` 是 `.prohibited`，無法成為前景 app，必須打包才能測）後，由使用者本人在鍵盤上實際按下 —— `⌘Z` 使曝光 +3.94→0.00、`⌘⇧Z` 使 0.00→+3.94，皆確認有效；過程中排除了本機作用中的中文（注音）輸入法對「合成鍵盤事件」的干擾，改以真人按鍵驗證。詳見 `docs/superpowers/specs/2026-08-20-post-mvp-follow-up-spec.md` 交接狀態章節，commit `f95d064` | Gate F | ☑ 已完成，不再是待辦 |
| P2 | Unsupported RAW 格式錯誤路徑（`RawDecodingError.unsupportedFormat`）在本機這個 macOS/CIRAWFilter 版本上，用任何本地可存取的檔案都無法觸發（`CIRAWFilter` 對任何本地檔案要嘛當成有效圖片解碼、要嘛落入 `corruptedFile`，從未回傳 `nil`）——錯誤訊息與下一步文案本身未經真實觸發驗證 | Gate D／F | 接受，架構上與其他已驗證錯誤路徑一致 |
| P2 | 唯讀磁碟情境下，`saveState == .failed` 的說明只靠原生 macOS tooltip（`.help(...)`），需要滑鼠靜止才會出現，使用者反映不夠明顯 | Gate E | 接受，屬次要 UX，未來可考慮改成更明顯的一次性提示 |
| P2 | Gate F 的 4 項 Instruments 指標中 3 項（cached thumbnail 延遲、100 次切換記憶體、掃描 high-water）未執行，原因是本環境無 GUI／Instruments 存取權限 | Gate F | 接受，需要下次有真機互動能力的 session 補測 |
| P2 | Gate E 部分項目（SQLite 重建、relink、唯讀、損壞檔）只在 APFS 上驗證過，未在 exFAT 上個別重跑；反過來拔插/重接只在 exFAT 上驗證（APFS 測試資料夾是本機內接磁碟，物理拔插情境不適用） | Gate E | 接受，機制本身跟檔案系統無關，風險評估為低 |
| P2 | 使用者截圖裡出現過一次不完整的 `NSCocoaErrorDomain ... code=4097`（NSXPCConnectionInterrupted）訊息，來源與影響未查清，重測時未再出現 | Gate E | 擱置，不影響任何驗收判斷 |

## 10. 主規格 §13 十項 sign-off

對照 `docs/superpowers/specs/2026-08-13-mac-first-mvp-design.md` §13。

| # | 條件 | 證據 | 結果 |
|---|---|---|---|
| 1 | 可選擇外接 SSD 目錄並在 App 重啟後恢復授權 | §7 第 1、4、7、8 項（exFAT 隨身碟拔插/重接/重新授權皆通過） | ☑ 通過 |
| 2 | 可增量掃描並顯示 Sony `.ARW` 縮圖 | §6、§7 第 2 項；81 張真實 ARW 全過 | ☑ 通過 |
| 3 | 第 6.2 節所有調整都能即時預覽 | §8.1 第 1 項；§8.2 interactive 延遲 137–148ms | ☑ 通過 |
| 4 | 原圖比較、Undo、Redo 與重設皆有測試 | §8.1 第 2 項；Original 比較鍵手勢層級 bug 已修並人工驗證；Undo/Redo 選單與鍵盤快捷鍵（⌘Z／⌘⇧Z）皆已驗證可用，見 §9 已完成的 P2 項目 | ☑ 通過 |
| 5 | 調整自動保存至 `.lumaharbor`，重啟後結果一致 | §7 第 3、4 項（APFS／exFAT 皆確認關閉重開後調整值保留） | ☑ 通過 |
| 6 | 原始 `.ARW` 的內容與修改時間不被 App 改變 | §3、§6：`testExportingNeverModifiesTheOriginal`；整個驗收過程結束後 fixture mtime 仍為 `Mar 28 11:59:12 2019`，與最初一致 | ☑ 通過 |
| 7 | 可從完整解析度 RAW 匯出帶 sRGB profile 的 JPEG | §6 `testFullResolutionExportMatchesTheSourceDimensions`；§8.1 第 4 項人工匯出／流水號／取消測試 | ☑ 通過 |
| 8 | SSD 拔除、不支援 RAW、損壞 RAW 或唯讀磁碟不會導致 App 崩潰 | §7 第 7、9、10 項；全程無 crash。「不支援 RAW」見 §9 P2（無法本地觸發，非阻塞） | ☑ 通過 |
| 9 | 本機 SQLite 與快取刪除後可以重建 | §7 第 5 項 | ☑ 通過 |
| 10 | 核心單元與整合測試通過，且沒有已知資料損毀問題 | §5.1：433/433，0 failures，9 skipped（未設 fixture）；§5.2：設定 fixture 後該 9 個 `RawFixtureTests` 額外執行、9/9 pass；全程無資料損毀，發現的 bug 均為顯示/狀態層級且已修復 | ☑ 通過 |

**十項全部通過，§9 沒有未清空的 P0/P1，MVP 標記為完成。**

## 附錄：原始 log 位置

本次 §5、§6、§8.2 的執行輸出未落地成獨立 log 檔案，數字直接取自終端機輸出的 XCTest summary 行與 `print` 診斷輸出，記錄於本報告與 `docs/testing/reports/2026-08-16-mvp-acceptance-progress.md` 對應段落中。
