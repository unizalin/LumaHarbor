# LumaHarbor Thumbnail、掃描取消與編輯保存強化規格

日期：2026-08-14

狀態：Approved addendum

基準：`319bf7e`

上位規格：`2026-08-13-mac-first-mvp-design.md`

## 1. 目的

本文件固定下一個實作階段的行為。它不是新增產品功能，而是修正 Mac-first MVP 現有實作中會造成編輯遺失、錯誤快取、取消失效或大量資料夾記憶體成長的問題。

若本文件與上位規格衝突，以「不遺失使用者編輯、RAW 永不修改、取消後不得發布過期結果、掃描不得線性堆積記憶體」為優先。不得藉本階段加入 iPadOS、批次編輯、視覺回歸框架或新調色功能。

## 2. Codex review 已確認的問題

### 2.1 P0：切換照片會取消 autosave 並丟掉未保存編輯

目前 `LibraryViewModel.selectedPhotoID`／`selectedLibraryID` 的 `didSet` 會直接呼叫關閉流程；`EditorViewModel.close()` 隨即取消 `autosaveTask` 並清空 `history`，沒有先保存。使用者在 700 ms debounce 內切換照片、關閉編輯器或切換資料庫時，調整可能永遠不寫入 sidecar。

這違反上位規格 §2.4、§6.2、§8.2 與 §13.5，屬資料安全阻擋項。

### 2.2 P1：Thumbnail cache identity 與實際像素不一致

`ThumbnailProvider.thumbnailData` 接受 `adjustments` 並會套用處理管線，但 cache key 只有 `photoID + pixelDimension`。同一照片的 neutral 與 edited 請求會共用同一份 bytes；先完成者永久污染後續結果。UI 目前又沒有把 saved adjustments 傳入 thumbnail，也沒有在保存後 invalidate。

### 2.3 P1：Thumbnail 取消不會傳進 detached producer

Thumbnail producer 由 `Task` 再包 `Task.detached`。caller 取消不保證中止 detached decode/render；取消後仍可能寫入 cache。`invalidate` 也只刪除既有檔案，不會阻止舊 in-flight producer 稍後把已失效結果寫回。

### 2.4 P1：掃描取消會等待 detached inspection，且可能誤記成功時間

`PhotoLibraryService.inspect` 使用 `Task.detached`，未把 caller cancellation 明確轉送。取消發生於 fingerprint 或 metadata read 時，工作可能繼續；結果回來後若缺少 cancellation checkpoint，仍可能進入 index/manifest。

此外 `performScan` 不論 `cancelled` 都會把 `LibraryFolder.lastScanAt` 改為現在。UI 以 `lastScanAt == nil` 判斷是否需要首次掃描，因此取消的首次掃描會被誤認為已完成。

### 2.5 P1：兩層 unbounded AsyncStream 可線性累積掃描批次

`FolderScanner.scan` 與 `PhotoLibraryService.scan` 都使用 `.unbounded`。檔案 enumerator 可能比 fingerprint／metadata inspection 快很多，導致大量 `ScannedFile` batches 排在記憶體中。這不符合上位規格 §11「串流與分頁，不把全部 RAW 或 metadata 一次載入記憶體」。

現有 `FolderScannerTests.testCancellationStopsTheWalk` 只證明 consumer 可以 `break`；它沒有證明背景 enumerator 已停止，也沒有量測 break 後是否仍持續產生批次。

## 3. 本階段的產品決策

### 3.1 編輯離開前必須 flush；失敗時不得靜默切走

照片切換、資料庫切換與關閉編輯器必須走同一個 async transition：

1. 若目前 edit state 不 dirty，可直接切換。
2. 若 dirty，先把當下完整 `PhotoAdjustments` 原子保存至 sidecar。
3. 保存成功後才清除 history、切換 selection 或關閉 editor。
4. 保存失敗時保留原 selection、editor history、preview 與 dirty state，顯示具下一步的錯誤；不得先切畫面再丟資料。
5. 保存進行中若 adjustment 又改變，flush 必須繼續處理最新 snapshot，直到目前 history 已保存；不得把舊 snapshot 的成功誤標為全部已保存。

不得以 fire-and-forget save 取代上述順序。直接綁定 `@Published selectedPhotoID`／`selectedLibraryID` 的同步 setter 若無法保證此流程，應改成明確的 request-selection API 與 read-only selection state；View 端透過自訂 `Binding` 或 action 發出 request。

本階段至少覆蓋「滑桿改動後立即選下一張」與「保存失敗時停留原照片」；App process 被強制終止的復原不在本階段自動化範圍，仍列實機驗收。

### 3.2 MVP grid thumbnail 固定為 neutral source thumbnail

Mac-first MVP 的 grid thumbnail 定義為「由原始 RAW 產生、未套用 sidecar adjustments 的中性縮圖」。是否有編輯以現有 edit badge 表示；edited thumbnail 留待 MVP 後另行設計。

因此本階段應：

- 從 `ThumbnailProvider` public API 移除容易誤用的 `adjustments` 輸入與不實註解。
- 移除 ThumbnailProvider 不再需要的 `AdjustmentPipeline` dependency。
- cache identity 固定為 versioned `photoID + pixelDimension`；若更改縮圖編碼或色彩策略，必須 bump cache key version。
- 不得使用 Swift `hashValue` 作持久 cache key，因為跨 process 不穩定。
- 保存編輯後只需可靠更新 index/UI 的 `hasEdits` badge，不因調整而 invalidate neutral thumbnail。

這個決策刻意避免同一照片產生無上限 adjustment variants，也讓 SSD 離線時不需先讀 sidecar 才能命中 cache。

### 3.3 Thumbnail cache 與 coalescing invariants

同一 cache key 的併發請求可以共用一個 producer，但必須符合：

- cache hit 永遠先於 online/source 檢查，且不得呼叫 decoder。
- 已快取時離線仍回傳 bytes；未快取且離線回 `ThumbnailError.unavailableOffline`，並提供 recovery suggestion。
- 同 key 的多個 waiter 最多觸發一次 decode/render。
- 單一 waiter 取消時，該 waiter 必須得到 cancellation，不得收到成功 bytes；其他仍在等待的 waiter 不受影響。
- 最後一個 waiter 取消、provider invalidate 或 provider teardown 時，producer 必須收到 cancellation。
- producer 取消或 generation 已失效時不得寫入 cache。
- `invalidate(photoID:)` 返回後，舊 producer 即使不合作、稍後正常回值，也不得重新填回已失效 cache。
- in-flight cleanup 必須以 key + generation/token 比對；舊 producer 不得清掉後來的新 producer。
- render/encode failure 統一映射為有下一步的 `ThumbnailError`；不得把內部 `ImageRenderError` 裸漏給 UI。

共享 producer 的取消不得只寫一個 `Task.isCancelled` 表面檢查。測試必須用可控制的 gate，分別覆蓋 cooperative producer 與忽略取消後才回值的 producer。

### 3.4 Pinning 與 cache lifecycle

- `pin(photoID:)` 在 entry 尚未產生前呼叫也必須保護稍後 store 的同 key entry。
- pinned entry 可暫時讓 cache 超出 budget；unpin 後下一次 eviction 必須可移除。
- `removeAll()` 必須同時清除不再有效的 pin state，避免同 key 日後永久不可 eviction。
- cache write 失敗不得讓已成功產生的 thumbnail bytes 變成畫面失敗；但 disk-full 診斷必須保留可觀察性。若本階段不增加 UI warning channel，至少以明確 diagnostics/result state 留給上層，不得靜默宣稱已快取。

### 3.5 Scan cancellation invariants

掃描取消分成 cooperative 與 non-cooperative I/O：

- cancellation 必須轉送至 enumerator、fingerprint worker 與目前 inspection task。
- fingerprint 的 chunk 邊界必須檢查 cancellation。
- cooperative decoder 收到取消後應儘快停止。
- 無法中斷的同步 decoder 最多允許完成「目前這一個檔案」；回值後必須再次檢查 cancellation，丟棄該結果且不得開始下一個檔案。
- cancellation 不得被轉成 `.photoFailed`、failed asset 或 unsupported asset。
- 取消後不得 prune 未掃到的既有 index rows。
- 已完整 commit 到 index 的先前 batches 可以保留；為保住其 PhotoID，可把對應 partial manifest 原子寫回，但不得更新 `manifest.lastSuccessfulScanAt`。
- `LibraryFolder.lastScanAt` 只代表成功完整掃描。取消時保持原值；首次掃描取消後仍為 `nil`。
- `LibraryScanResult.wasCancelled` 必須為 true；`completedAt` 只代表工作停止時間，不代表成功。
- late producer/event 不得在新 scan 已開始後污染新 scan。若允許同 library 重開掃描，需以 generation/token 隔離。

### 3.6 掃描必須 lossless 且 bounded

不得以 `.bufferingNewest`／`.bufferingOldest` 丟棄檔案批次來假裝有界。FolderScanner 與 service consumer 間必須有 lossless backpressure，且任何時刻最多保留一個尚未處理的 discovered batch（另加目前處理中的 batch）。

可採 custom bounded async channel、producer/consumer acknowledgement，或把 enumeration 改成 pull-based AsyncSequence；不得用 busy-loop polling。PhotoLibraryService 對 UI 的事件流也不得無上限累積：UI 只需目前批次與進度，設計必須保證批次不遺失並有明確的消費節奏。

> 2026-08-14 實作決策：具體 channel、sequence、paged cursor、取消 race 與 high-water 驗收，以 [`2026-08-14-lossless-bounded-scan-pipeline.md`](2026-08-14-lossless-bounded-scan-pipeline.md) 為準。

## 4. 必要測試

### 4.1 編輯保存

- dirty edit 後立即選下一張：sidecar 為最新 adjustments，之後才切換。
- save failure：selection 不變、history 不變、dirty 不變、錯誤有 next step。
- save 中再次改 slider：最後保存的是最新 snapshot。
- reset 回 neutral 後保存：index 與 UI badge 的 `hasEdits` 變為 false。

### 4.2 ThumbnailProvider

- cache hit 不呼叫 decoder，source URL 即使不存在亦可回傳。
- cached offline success；uncached offline actionable failure。
- cache miss decode/render/store；第二次 request 不再 decode。
- N 個同 key concurrent requests 只 decode 一次。
- 取消一個 waiter 不影響另一 waiter。
- 最後 waiter 取消會中止 cooperative producer且不寫 cache。
- non-cooperative producer 在 invalidate/cancel 後回值也不能填回 cache。
- invalidate 後新 request 會啟動新 generation，舊 completion 不得清除新 in-flight。
- pin-before-store、unpin eviction、removeAll clears pin state。
- neutral-only API 不再接受 adjustments；cache key 有明確 format version。

### 4.3 Scan

- consumer cancel 發生在 cooperative metadata read：停止且無後續 index/event。
- cancel 發生在 non-cooperative metadata read：release 後丟棄當前結果，不處理下一檔。
- 取消前已 commit 的 batch 可保留；取消後不 prune 舊 rows。
- manifest 與 `LibraryFolder.lastScanAt` 保留前一次 successful timestamp。
- 首次 scan 取消後 `lastScanAt == nil`。
- 立即啟動第二次 scan：第一次 late completion 不得污染第二次。
- 以 instrumented producer/consumer 證明 buffered discovered batches 上限，不只量測 consumer break 的返回時間。

## 5. 驗證與交付門檻

Claude 實作階段不得 commit/push；由 Codex review 後處理。交付前至少需要：

1. `swift build -Xswiftc -strict-concurrency=complete` 完整 compile + link。
2. 所有 Tests `swiftc -frontend -parse`。
3. 三個 test target 以本機 synthetic XCTest module 執行 `swiftc -typecheck -enable-testing -strict-concurrency=complete`。
4. `git diff --check`。
5. Codex 以不依賴 XCTest 的 runtime smoke 覆蓋至少 Thumbnail cancellation/invalidation 與 scan non-cooperative cancellation state commit。

本機只有 CommandLineTools，synthetic XCTest typecheck 不等於測試執行。完整 Xcode 的 `swift test`、Apple Silicon、Sony ARW、Metal/CIRAWFilter、APFS/exFAT 與 bookmark 實機驗收仍是 MVP completion gate，不得因本階段 source-level 驗證通過而標記 MVP 完成。

## 6. 實作順序

1. 先修 P0 selection/close flush，避免繼續累積資料遺失路徑。
2. 固定 neutral thumbnail API 與 cache key version，再做 coalescing/cancellation/invalidation。
3. 修 scan cancellation state semantics。
4. 最後處理 lossless bounded scan pipeline；不得以 drop batches 的方式快速收尾。
5. 每一小段更新 `/Users/u/AI-Shared/HANDOFF.md`；context 使用約 80% 或出現 usage warning 時停止新增功能、保留可 build 的 dirty tree交給 Codex。

## 7. 實作狀態（2026-08-15，Codex review 通過）

- §6.1 P0 selection/close flush：已實作。
- §6.2 neutral thumbnail API 與 cache key version：已實作。
- §6.3 scan cancellation state semantics：已實作。
- §6.4 lossless bounded scan pipeline：**已實作**，細節與範圍見
  `2026-08-14-lossless-bounded-scan-pipeline.md` §10。§3.5 的 scan generation、
  partial commit、manifest 與 `LibraryFolder.lastScanAt` 語意在改為 bounded
  pipeline 後保持不變，既有 `ScanCancellationTests` 未經修改即通過 typecheck。

上述項目已通過 Codex 原始碼覆核；bounded pipeline 另通過 strict build、8 組
runtime smoke、四個 test target 的 strict-concurrency typecheck、全部測試原始碼
parse 與 `git diff --check`。但**本機無 XCTest module，完整 XCTest assertions
仍未真正執行**。Mac-first MVP 整體仍未完成，勿據此標記 MVP 完成。
