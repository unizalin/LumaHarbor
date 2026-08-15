# LumaHarbor Lossless Bounded Scan Pipeline 實作規格

日期：2026-08-14

狀態：Approved implementation spec

基準：`7c75521`

上位規格：

- `2026-08-13-mac-first-mvp-design.md`
- `2026-08-14-thumbnail-scan-cancellation-hardening.md` §3.5、§3.6、§4.3、§6.4

## 1. 目的與範圍

本文件只完成 hardening addendum §6.4：把資料夾列舉到 service、以及 service 到 UI 的兩層掃描事件流改成 lossless bounded pipeline。

完成後，即使外接碟含有十萬個 RAW、metadata inspection 很慢或 UI 暫停消費，記憶體也不得隨尚未處理的檔案數線性成長；同時不得丟失、重複或重排 discovered batches。

本階段不得：

- 新增相片功能、調色功能、iPadOS 或批次操作。
- 改變 PhotoID、manifest、index、move detection 或 sidecar 語意。
- 以 `.bufferingNewest`、`.bufferingOldest` 或進度節流丟棄檔案／失敗事件。
- 重新引入 detached 全樹列舉、busy-loop、sleep polling 或 semaphore 阻塞 async executor。
- 把完整檔案清單、完整 metadata 或所有 UI events 暫存後再一次發布。

## 2. 現況與完成定義

現況有兩個 `.unbounded`：

1. `FolderScanner.scan(root:)` 的背景 enumerator 可無限制領先 service inspection。
2. `PhotoLibraryService.scan(libraryID:)` 可無限制領先 `LibraryViewModel` consumer。

本階段完成必須同時符合：

- `for await event in scanner.scan(root:)` 與 `for await event in service.scan(libraryID:)` 的呼叫語法保持可用。
- FolderScanner 與 service 每層最多保留「consumer 正在處理的一個 batch + 一個等待被取走的 batch」。producer 不得在第二個 batch 等待時預先建立第三個 batch。
- 檔案與 `.photoFailed` 事件 lossless；成功路徑每個支援檔案最多且至少出現一次。
- consumer cancellation／提早 `break` 會停止 producer，解除所有等待，且不得在稍後發布 late event。
- addendum §3.5 已有的 scan generation、partial commit、manifest、`lastSuccessfulScanAt` 與 `LibraryFolder.lastScanAt` 行為完全保留。

## 3. 固定架構決策

### 3.1 使用 acknowledgement channel，不使用一般 buffered stream

新增 package-internal、泛型、lossless 的單槽 async channel。名稱可依現有命名調整，但語意固定為 `AcknowledgedAsyncChannel<Element: Sendable>`：

- capacity 固定為 1。
- `send(_:)` 可把一個 element 放入空槽，但必須持續 suspend，直到 consumer 的 `next()` 實際取走該 element。
- 槽已滿時，下一次 `send(_:)` 必須 suspend，且不得覆寫或丟棄舊 element。
- consumer 取走 element 時，只恢復該 element 的 sender；sender 才能製作下一個 batch。
- `finish()` 保留已送入槽中的 element，consumer drain 後回傳 `nil`。
- `cancel()` 丟棄尚未交付的 element、拒絕 late send，並恢復所有 producer／consumer continuations。
- finish、cancel、consumer cancellation 與 producer failure 都必須 idempotent；任何 continuation 恰好 resume 一次。
- 不以 polling、`Task.yield()` 迴圈、`Thread.sleep`、`DispatchSemaphore.wait` 或無上限 waiter array 實作。

channel 必須只有一個 active producer 與一個 active consumer。若內部 API 可能被誤用，第二個同時 `next()`／`send()` 應以可測的 precondition 或明確 failure 結束，不得產生未定義 ordering。

### 3.2 對外回傳自訂 non-throwing AsyncSequence

以兩個 public、`Sendable`、non-throwing AsyncSequence 取代 public return type 的 `AsyncStream`：

- `FolderScanSequence`，`Element == ScanEvent`
- `LibraryScanSequence`，`Element == LibraryScanEvent`

既有 API 名稱與 `for await` 使用方式不變：

```swift
public func scan(root: URL) -> FolderScanSequence
public nonisolated func scan(libraryID: LibraryID) -> LibraryScanSequence
```

每次 `makeAsyncIterator()` 代表一次新的 scan run；每個 iterator 只能由一個 consumer 依序呼叫 `next()`。iterator／subscription lifetime token 被釋放、consumer task 被取消或 loop 提早結束時，必須取消所屬 producer。不得依賴 App process 結束回收。

對外 sequence 保持 non-throwing：現有 domain failure 繼續以 `.fileFailed`、`.photoFailed` 或 `.failed` event 表達；`CancellationError` 用來結束 iteration，不得轉成照片失敗。

### 3.3 FolderScanner 改成分頁 cursor

Foundation `FileManager.DirectoryEnumerator` 必須封裝在同步、具明確單一擁有者的 cursor/session 內。cursor 只暴露一個同步方法，例如：

```swift
func nextPage() -> FolderScanPage
```

`FolderScanPage` 可依實作拆成 step 或 page，但必須符合：

- 每次呼叫最多建立一個 `[ScannedFile]`，上限為 `batchSize`。
- cursor 保存 enumerator、累計 discovered/failed count 與目前 page state；不得保存歷史 batches。
- `.skipsHiddenFiles`、`.skipsPackageDescendants`、extension filtering、relative path、file size 與 modification date 行為不變。
- resource value error 仍繼續掃描並依序發布 `.fileFailed`。
- Foundation error handler 只可累積「目前一次 cursor 推進」產生的 failures；發布前不得開始下一次推進。測試用 cursor 必須能精確驗證沒有跨頁 read-ahead。
- cursor 建立與 `nextPage()` 都不得在 `MainActor` 上做磁碟列舉。
- `DirectoryEnumerator` 不可跨越未受保護的 concurrent calls。若以 `@unchecked Sendable` box 包裝，必須用 lock／單一 task ownership 證明序列化，並在型別旁註明 invariant。

FolderScanner producer 的順序固定為：

1. `send(.started)`。
2. 在 utility priority 的 off-actor 同步工作中呼叫一次 `nextPage()`。
3. 依 page 原順序 `await send` failures 與至多一個 discovered batch。
4. 只有當前述 send 已被 consumer 取走後，才允許呼叫下一次 `nextPage()`。
5. cursor 到尾端時 `send(.finished(summary))`，再 `finish()`。

取消檢查至少位於：cursor 推進前、每個 enumerated URL、resource read 前後、send 前後。取消時不得額外發布成功 `.finished`；若為保留現有 FolderScanner contract 而發布 `ScanSummary(wasCancelled: true)`，它必須是最後一個 event 且不得阻礙取消完成。兩種選擇擇一固定並以測試記錄；`PhotoLibraryService` 的 `LibraryScanResult.wasCancelled` contract 不變。

### 3.4 PhotoLibraryService producer 使用同一 backpressure contract

保留現有 `performScan` 主流程與 actor ownership，只把 `AsyncStream.Continuation.yield` 改成可等待的 emitter：

```swift
try await emitter.send(event)
```

所有 event 發送都必須 await，包括 `.started`、`.photoFailed`、`.photosIndexed`、`.failed` 與 `.finished`。producer 只有在 consumer 取走上一個 event 後才能繼續 inspection／commit 下一批。

不得因 backpressure 改變下列語意：

- 一個 discovered batch 仍逐檔 inspect，成功項目才組成 `.photosIndexed`。
- 取消前已完整 `index.upsert` 的 batch 可保留；未完整 inspect 的 batch 不 commit。
- consumer 停止後不再 inspect 下一個檔案、不 prune、不更新成功時間。
- 同 library 的新 scan generation 仍使舊 scan 成為 superseded；舊 producer 的 late result／send 被拒絕。
- offline、missing library、manifest damage 與 index failure 仍使用既有 domain event，不因 channel 關閉變成另一種使用者錯誤。

若 channel cancellation 發生在 domain event 已建立但尚未交付時，該 event 可以被丟棄，因為其 consumer 已不存在；這不是允許正常運作時 drop batches。對 index／manifest 的寫入仍須遵守 addendum §3.5 的 cancellation checkpoint。

### 3.5 明確的記憶體 invariant

以 discovered batch 為單位，任一層的 high-water mark 必須滿足：

```text
retained batch count <= 2
= 1 consumer-current + 1 channel-pending
```

當 channel-pending 存在時，它的 sender 尚未返回，因此 producer 不得建立下一個 batch。兩層 pipeline 疊加時，FolderScanner 不得因 service 正在等 UI 而持續列舉；backpressure 必須一路傳回 directory cursor。

允許固定大小的 manifest/index working state 與目前 batch 的 metadata；不允許任何與「尚未處理檔案總數」成正比的 queue。測試驗證以 instrumented counters 為準，不以易受 allocator/cache 影響的 RSS 猜測。

## 4. 取消、終止與 race contract

### 4.1 Consumer 取消或提早 break

- consumer 正在 `next()` 時取消：立即關閉 subscription，喚醒 channel waiters，取消 producer。
- consumer 處理 event 時提早 `break`：iterator lifetime token 釋放後關閉 subscription；producer 若卡在 `send` 必須被喚醒。
- cursor 正在 cooperative I/O：收到 cancellation 後停止。
- cursor／decoder 正在 non-cooperative sync I/O：只允許目前操作返回；返回後丟棄結果，不得 send、commit 或開始下一項。

### 4.2 Producer 正常結束或失敗

- 正常結束只發布一次 `.finished`，channel drain 後 iterator 回 `nil`。
- domain failure event 依既有 ordering 發布；不新增重複 `.finished`。
- producer task 意外退出也必須 finish/cancel channel，consumer 不得永久 suspend。

### 4.3 Finish／cancel race

- cancel 勝過尚未被 consumer 取走的 late event。
- 已被 consumer 取走的 event 不回收；後續 state mutation 仍須做 generation/cancellation check。
- 舊 generation 的 sender 不得關閉、清除或 resume 新 generation 的 channel／producer。

## 5. 測試 seam

不得用十萬個真實檔案才能測 backpressure。FolderScanner 增加 package-internal injectable cursor factory／protocol，production adapter 使用 FileManager，測試 adapter 至少能記錄：

- `nextPage()` 呼叫次數。
- 已製作與已交付的 page/batch 數。
- 目前與最大 retained batch 數。
- cancellation／close 次數。
- 可由 gate 暫停某次推進，並可模擬 file failure、EOF 與 non-cooperative return。

PhotoLibraryService 沿用 decoder gate、index/manifest fixtures；如不足，可增加 internal diagnostics hook，但不得把測試計數器做成使用者 API。

## 6. 必要自動化測試

### 6.1 Channel 單元測試

1. `send` 在 element 被 `next()` 取走前不返回。
2. consumer 暫停時只有一個 pending element，第二個 sender 不得覆寫或前進。
3. ordering lossless：大量有序 elements 收到的內容完全一致。
4. finish 會 drain pending element，之後 `next() == nil`。
5. cancel 會喚醒 blocked sender／receiver；late send 被拒絕。
6. send、finish、cancel race 不 double-resume、不 hang；重複 finish/cancel 安全。

### 6.2 FolderScanner 測試

1. slow consumer 取到第一個 discovered batch 後停在 gate；instrumented cursor 證明最多只有下一個 batch pending，且沒有第三次 page read-ahead。
2. consumer 在第三批 `break`；cursor 不再推進，close/cancel 恰好一次。
3. 10,000 個 synthetic entries、混合 extension 與 failures：所有支援檔案／failure 按來源順序恰好交付一次，最大 retained discovered batches `<= 2`。
4. 空目錄、剛好整除 batch size、最後不足一批，各自只產生一次 terminal event，summary count 正確。
5. cancellation 發生於 page read 前、resource read 後與 pending send 時，都不產生下一批。
6. production FileManager adapter 的既有 recursive、hidden、relative path、case-insensitive extension tests 全部保留。

### 6.3 PhotoLibraryService／整合測試

1. UI consumer 取到第一個 `.photosIndexed` 後停在 gate；service 最多讓下一個 batch 等待，不 inspect 第三批，FolderScanner cursor 也不繼續推進。
2. consumer break/cancel 後沒有後續 `.photosIndexed`／`.photoFailed`，也不 inspect 下一檔。
3. 取消前已 commit batch 保留；不 prune；manifest 與 folder successful timestamps 不變。
4. non-cooperative inspection 返回後結果丟棄，channel 沒有 late event。
5. 立即啟動第二次 scan：第一次 sender/cursor 不污染、關閉或清理第二次 generation。
6. 正常完整掃描的 file set、index rows、manifest records 與原實作一致；沒有 drop、duplicate 或 reorder。
7. 既有 `ScanCancellationTests`、`LibraryLifecycleTests` 與 App view-model scan tests 全部保持 source-compatible，除 return type 的型別斷言需合理更新。

## 7. 實作順序

1. 先新增 acknowledgement channel 與純單元測試；尚未接 production。
2. 新增同步 paged cursor 與 injectable test cursor。
3. 把 `FolderScanner.scan` 換成 `FolderScanSequence`，跑既有與 bounded tests。
4. 把 `PhotoLibraryService.scan` 換成 `LibraryScanSequence`，所有 send 改為 await。
5. 補 cancellation、generation、slow UI 與 end-to-end high-water tests。
6. 跑 §8 全部驗證，再更新 addendum §6.4 狀態與 `/Users/u/AI-Shared/HANDOFF.md`。

每一步都需保持 compile；不得先刪除既有取消保護再等待後續步驟補回。

## 8. 驗證與交付門檻

Claude 實作階段不得 commit/push；由 Codex review 後處理。Claude 結束前需回報實際執行的命令、exit code、未執行原因與 dirty files。

最低門檻：

1. `swift build -Xswiftc -strict-concurrency=complete` 完整 compile + link。
2. 所有 Tests 以 `swiftc -frontend -parse` 通過。
3. 三個 test target 以本機 synthetic XCTest module 執行 `swiftc -typecheck -enable-testing -strict-concurrency=complete`。
4. acknowledgement channel 與 bounded pipeline 的不依賴 XCTest runtime smoke，至少覆蓋 slow consumer、cancel blocked sender、10,000 synthetic entries 及 high-water `<= 2`。
5. `git diff --check`。
6. `rg -n "AsyncStream\(bufferingPolicy: \.unbounded\)" Sources/PhotoLibraryCore` 不得再命中掃描路徑。
7. Codex review 必須檢查 continuation lifetime、double-resume、iterator early-break、Task cancellation forwarding、actor isolation 與 generation race。

本機只有 CommandLineTools 時，不得把 parse、synthetic typecheck 或 runtime smoke 宣稱為完整 XCTest 通過。完整 Xcode `swift test` 與實機大資料夾掃描仍列 MVP completion gate。

## 9. 交付內容

Claude 交付應包含：

- channel／sequence／cursor production code。
- channel、FolderScanner、PhotoLibraryService 與 integration tests。
- 本文件與 hardening addendum 的 implementation status 更新。
- `/Users/u/AI-Shared/HANDOFF.md` 的進度、驗證、剩餘風險與 Codex review checklist。

不得包含 commit、push、無關格式化或 MVP 以外功能。

## 10. 實作狀態（2026-08-15，Codex review 通過）

**這一節只描述本規格的範圍。Mac-first MVP 整體仍未完成**——完整 Xcode `swift test`、Apple Silicon、Sony ARW、Metal/CIRAWFilter、APFS/exFAT 與 bookmark 實機驗收都還沒做。

已實作並經 Codex 原始碼覆核：

| 規格條目 | 狀態 |
|---|---|
| §3.1 acknowledgement channel | 完成 `Sources/PhotoLibraryCore/Scanning/AcknowledgedAsyncChannel.swift` |
| §3.2 `FolderScanSequence` / `LibraryScanSequence` | 完成；`for await` 呼叫語法未變，兩個 iterator 皆為 **class**，`deinit` 取消 producer |
| §3.3 分頁 cursor | 完成 `FolderScanCursor.swift`（protocol + `FileManagerFolderScanCursor` + factory） |
| §3.3 cancellation 時的 `.finished` | **固定選擇：嘗試送出但絕不阻塞**。consumer 已離開時 send 會 throw，該事件即被丟棄，因此實務上只有跑完的 walk 會交付 `.finished` |
| §3.4 service 全部 send 改 await | 完成；`emit` 以 channel 自身的 `isCancelled` 判斷 consumer 是否還在，不用跨 await 的 captured flag |
| §3.5 high-water ≤ 2 | 以 instrumented cursor 的 `nextPageCallCount - deliveredBatches + 1` 計數驗證 |
| §6.1 channel 單元測試 | 完成 19 個 |
| §6.2 FolderScanner 測試 | 完成 12 個（含 10,000 synthetic entries） |
| §6.3 service／整合測試 | 新增 9 個；既有 `ScanCancellationTests`／`LibraryLifecycleTests` **未修改即 source-compatible** |
| §8.6 `rg` gate | `Sources/PhotoLibraryCore` 已無 `AsyncStream(bufferingPolicy: .unbounded)` |

Codex 已獨立通過 `swift build -Xswiftc -strict-concurrency=complete`、8 組 runtime smoke（含 10,000 筆 high-water、pre-cancelled receiver、failure page budget 與 two-phase acknowledgement cancellation）、四個 test target 的 strict-concurrency typecheck、全部測試原始碼 parse，以及 `git diff --check`。

完整 XCTest 仍未真正執行：目前 Command Line Tools 環境沒有 XCTest module。Apple Silicon、Sony ARW、Metal/CIRAWFilter、APFS/exFAT 與 bookmark 仍須在完整 Xcode／實機環境驗收，不能把本節視為整體 MVP 完成。
