# 筆刷跨 tile 正確性與驗收證據追補規格

- 日期：2026-10-06
- 識別：`LH-BRUSH-CORRECTNESS-FOLLOWUP-20261006`
- 版本：1.1（實作後狀態與後續計畫更新）
- 文件狀態：`IMPLEMENTED`（F1～F3）；F4 部分驗證，F5 自動回歸與文件已有證據，必要驗收尚未全數完成。
- 產品狀態：`DONE_WITH_CONCERNS`。跨 tile 列位置與標準 Release 編譯已修正，取消生命週期與 warm synthetic ABBA 已驗；真實 RAW、完整效能矩陣、人工操作與獨立審查仍待完成。

## 1. 目的、權威與範圍

讓使用者畫下的筆刷，在多個垂直 tile、預覽與原尺寸匯出中保持相同來源位置；同時讓 Release 測試、取消與效能證據能驗證實際產品行為。先證明畫對位置，再比較速度。

本文件承接下列文件，取代其中「下一步先跑 B/O」的順序，以及對 row flip、oracle、取消和效能證據過度延伸的結論。既有門檻、資料保存、色彩與人工驗收要求仍有效。

1. [前輪修正规格](2026-10-06-brush-performance-and-acceptance-repair-spec.md)，尤其 §4～§6、§9。
2. [前輪驗收報告](../../testing/reports/2026-10-06-brush-performance-and-acceptance-repair.md)。原數據保留為歷史樣本，追補說明優先。
3. [前輪交接文件](../../coordination/2026-10-06-brush-performance-acceptance-repair-handoff.md)。
4. [主線整合規格](2026-10-05-mainline-white-balance-brush-integration.md)，尤其 §7、§12、§13。
5. [共用讀取協定](../../coordination/SHARED_AGENT_READ_PROTOCOL.md)、[Git 流程](../../coordination/SHARED_GIT_WORKFLOW.md)、[CURRENT](../../coordination/CURRENT.md)、[DECISIONS](../../coordination/DECISIONS.md)。

本輪包含五項工作：跨 tile 列位置與獨立像素測試、Release 測試支援、真實父 Task 取消、B/O 與記憶體量測、證據文件修正。必要的 validation／allocation 防回歸也屬於 renderer 驗收。

不包含 UI 重設計、新遮罩、資料遷移、重解釋 density／pressure、GPU rasterizer、跨照片 cache、RAW decoder 重寫、Adobe renderer 啟用、版本升級、推送／合併／發布。Mac／iPad 操作、灰卡與獨立審查沿用前輪必要 gate，缺設備／素材仍記 `NOT RUN`；正式 Lightroom Gate 2 維持獨立。

## 2. 已核對基準與證據邊界

目前版本：O／warm ABBA harness=`c425cb7fdc93442e915c13eee913bf175fc15758`；最終回歸／analyzer=`4e74bf3813ac4e6f6dbdc27b10d8a779c4ef3786`。下方 §2.1～2.3 保留 F0 起草時的基準與問題，不代表缺陷仍存在。現況以[驗收報告](../../testing/reports/2026-10-06-brush-raster-correctness-followup.md)為準，執行順序見[後續計畫](../plans/2026-10-06-brush-acceptance-completion.md)。

### 2.1 Git 與執行位置

| 角色 | 完整 SHA／狀態 | 用途 |
| --- | --- | --- |
| B：優化前 candidate | `1de07dcfeb2ed217a75d1c04978da6a5936f379a` | scalar 行為與正式效能比較基準 |
| U：已知缺陷的優化產品 | `26c3390ba59e0e2ae416618d6e832a5c0eeba98d` | 重現缺陷；效能僅作診斷，不作正確性 oracle |
| 本次核對 HEAD | `37d1580b4a1924fce58d688ff668ba6b536d3868` | U 之後只有 spec／report／coordination 文件 |
| 目前分支 | `codex/brush-performance-acceptance-repair` | 延續該候選的文件工作；寫入前 tracked／untracked 狀態乾淨 |
| 本機 `origin/main` | `82542e73aae8f16b0ba7e4d9d36a8a42451a7319` | 正式整合基準；本輪未查遠端最新值 |
| O：本次修正產品（補記） | `c425cb7fdc93442e915c13eee913bf175fc15758` | warm ABBA 產品與 harness；`4e74bf3813ac4e6f6dbdc27b10d8a779c4ef3786` 僅修正 analyzer，最終回歸綁定後者 |

文件由 Codex 在既有候選工作樹單獨寫入。後續實作先核對 owner、dirty files、main 與候選 ancestry；延續尚未合併候選時記錄相依例外，另建隔離工作樹須符合使用者授權與專案流程。不能為了取得基準而修改 B／SOURCE、合併／rebase，或重設他人的 dirty files。

### 2.2 缺陷清單

下列行號指向 U 的檔案內容；後續編輯後以函式名稱定位。

| ID | 優先 | 查證內容 | 證據範圍 |
| --- | --- | --- | --- |
| PIX-01 | P0 | `BrushMaskRenderer.swift:385` 只翻轉 tile 內列，`outputRow = tileStartY + row` 沒有把 tile 放到全圖翻轉後的位置 | 已讀程式碼並核對索引反例；新增跨 tile 失敗像素測試尚未執行 |
| PIX-02 | P0 | `BrushMaskScalarOracleTests.swift:12` 的影像為 180×120，只跨水平 tile；實際比較的是 blend 後 CGImage bytes | 不能證明垂直跨 tile 正確，也不能宣稱已直接量到 R8 coverage 差 0 |
| REL-01 | P1 | `EditorSession.swift:465,1603` 的六個 internal test helper 被 `#if DEBUG` 包住，但測試在 Release 仍引用它們 | 前次原始 Release integration 命令 exit 1，測試執行數 0；屬建置 FAIL |
| CAN-01 | P1 | `BrushMaskCancellationTests.swift:19,43` 在第九次 callback 自行拋錯，沒有 stage barrier 或父 Task.cancel；async case 只有一個 mask | 只證明錯誤可傳遞。sync 第九次在 stamp 準備階段；async 單 mask 第九次可在首 tile 邊界，尚無 raster 中段證據 |
| EVID-01 | P1 | benchmark 只量同一個 synthetic request 的 O，沒有 B、ABBA、變動情境或正式 RAW 筆刷負載；script 全域指定 `-DDEBUG` | optimized configuration + DEBUG define 的診斷數據，不能視為一般 Release 或 P3 已通過 |
| DOC-01 | P2 | 舊 spec 仍寫 SPEC ONLY；報告把 oracle／取消／synthetic 結果延伸成較廣結論，交接下一步未反映新 finding | 需保留歷史紀錄並加入更正與 gate 對照 |

### 2.3 前次檢測結果如何使用

前次在上述 HEAD 執行的命令，現存本機 log 與對話結果包括：完整 Debug suite 2,696 executed／18 skipped／0 failures、focused 186／2／0、RAW fixture 10／1／0；strict build、Mac Release、generic Simulator／device build、codesign、privacy、ZIP 解壓與 checksum 成功。這些是歷史檢測，不是本次 spec 撰寫時重跑，也不涵蓋 PIX-01 的缺失案例。

原始 `swift test -c release --filter BrushMaskPerformanceAcceptanceTests` 是 FAIL；補 `-Xswiftc -DDEBUG` 才是 1／0／0。不得用後者覆蓋前者。前次 synthetic 一／十 mask coverage p50 約 11.015／19.990 ms，為 U 的診斷樣本；不能抵銷畫錯位置的缺陷。

另更正先前口頭說明：`RawFixtureTests.testInteractivePreviewLatencyForARealPhoto` 實際計時 `CoreImagePreviewRenderer.render`，包含 decode、adjust 與 CGImage 產生，但 `PhotoAdjustments` 只有 exposure、沒有 brushMasks。141～148 ms 是空筆刷 production preview，不是單獨 decode，也不是含一／十 mask 的完整互動證據。樣本數是 cold 1、warm 3，測試沒有硬性效能 assertion，不能推論正式 p95 gate PASS。

## 3. 不可退化契約

- Pipeline 維持 RAW recipe／global → brushMasks → geometry → 舊 local adjustments → preview options 或 export resize／encode。
- Sidecar v5、rendererVersion 1、UUID、stroke／mask 順序、精確參數、curation、snapshot、clipboard 與 batch 保存行為不變；不載入即寫回，不以修復重新排序或刪資料。
- 繼續使用 throwing renderer。非法資料明確失敗，取消沿用 `CancellationError`／export `.cancelled`，不能吞錯回原圖。
- 保留相同 recipe 的 context reuse、不同 recipe 的隔離、Native fail-closed、geometry source mapping 與 scheduler 的 subject／generation／contextID 過期拒絕。
- 修正目標是恢復 B 的全圖 row flip。U 的錯誤位置不是新的相容行為；不增加 rendererVersion，也不自動補償已保存的座標。
- density／pressure 可見效果的既存 concern 保留，不能以這次座標修正宣稱壓力顯色已驗收。

## 4. FIX-PIX：全圖列位置與獨立像素驗證

### 4.1 索引規則

對 tile 內的來源列 `localY`，唯一輸出 bitmap 列是：

```text
sourceGlobalY = tileStartY + localY
bitmapRow = height - 1 - sourceGlobalY
alphaIndex = localY * tileWidth + localX
byteIndex = bitmapRow * width + tileStartX + localX
```

`height` 是全圖 `ceil(imageExtent.height)`；`tileHeight` 只控制迴圈長度。R8 量化、gray color space、extent translation 與 crop 沿用 B，不能再額外翻轉每個 tile 或先行修改來源座標來抵銷錯誤。

索引反例：height=240 時，全圖來源 y=0 應寫入 bitmap row=239；U 寫入127。來源 y=239 應寫入0；U 寫入128。這是可手算的索引證據，仍須以真實 coverage／materialization 測試重現。

### 4.2 測試矩陣與門檻

先保留 B 的 scalar rasterization／sampling 作 test-only oracle，維持獨立實作與來源 SHA。expected 不得呼叫 production renderer、production row mapping 或共用待測 sampling 函式。

| ID | 輸入 | 斷言 |
| --- | --- | --- |
| PIX-A | width=180，height 127／128／129／240／256／257；另 257×259、1600×1067 | 直接 R8 coverage 與 scalar 全幅比對；跨128列與不足一 tile 的尾列皆涵蓋 |
| PIX-B | 原點 (0,0)、(7,11)、(-13,-5)；非對稱 top／bottom／left／right 單點及跨 tile 筆畫 | 位置 ≤1 output pixel；四角標記與全圖 row flip 一致，不能只比尺寸或 checksum |
| PIX-C | paint→erase→paint、低 flow、feather 0／1、單點、重複點、稀疏／密集共線；disabled／neutral／空／未知版本／非法 patch | 與 B 的順序及錯誤契約一致；取消不產生部分成功結果 |
| PIX-D | 獨立灰／白／非對稱控制影像；sync 與 async 各自和 oracle blend 比較；至少3個有實際非零覆蓋且重疊的不同 adjustment masks | 明確驗證 mask 順序；不得只用 sync==async 或全空 erase mask 當通過依據 |
| PIX-E | flip、90/180/270、非中央 crop、straighten、perspective、corner pins 及既有組合案例；preview 與 full 對齊 source landmarks | round-trip ≤來源短邊 1e-6；落點 ≤1 output pixel；同尺寸未改區域 ≤1/255 |

直接 R8 與 blend pixel 比對分開報告。固定 scalar 向量要求 R8 byte-identical（max byte error=0）；若既有浮點捷徑導致不一致，先保留／恢復 B 的運算順序，不調寬測試來讓 row bug 過關。最終 materialized channels 延續原 ≤1/255 門檻，並列 max error 與座標；不同解析度不聲稱 byte-identical。

新增測試必須先在 U 看見與位置錯誤相符的 assertion failure，修正後同測試 PASS；不是以編譯失敗冒充 RED。可在隔離快照重現，禁止 reset 使用者的工作樹。首個有界交付只含此修正與測試，不順便調整其他 brush math。

## 5. FIX-REL：標準 Release 測試可執行

六個支援符號為 `setWhiteBalanceBaselineForTesting`、`advanceEyedropperGenerationForTesting`、`enableComparisonForTesting`、`beginEyedropperForTesting`、`undoCountForTesting`、`redoCountForTesting`。

採最小修正：將這六個既有 internal 宣告移出上述兩段 `#if DEBUG` 條件，仍保留在能存取 private state 的原檔案內，以 `@testable import EditorCore` 使用。維持 actor isolation、不升為 public，不提供 App UI／CLI 的測試模式；不移除其他模組的 DEBUG guard，不因 test support 改寫 Package 的全域 flags。

接著移除 `run-brush-performance-acceptance.sh` 的 `-Xswiftc -DDEBUG` 與其不再適用註解。`swift test -c release` 需能建置所有 test targets，原始 filtered integration 與完整 Release suite 均須通過，不能排除失敗檔案、將有用測試改成 skip，或只跑舊 binary。

保留 public API 與實際 white-balance／Undo 行為；普通 Mac/iPad Release build 不帶自訂 DEBUG define，正式呼叫路徑不得引用 `ForTesting` helper。新增 internal cancellation／oracle 測試接口亦須能在標準 Release test 使用。

## 6. FIX-CAN：可證明的父 Task 中途取消

### 6.1 Stage probe 與 barrier

建立 internal、per-invocation 的觀測接口，production 預設關閉，不用全域 mutable counter。事件至少含 request ID、mask index、stage（validation／sampling／rasterization／conversion）、已處理迭代數，以及 worker started／finished。probe 只觀測與同步測試，不自行拋 `CancellationError`。接口須符合 Swift concurrency isolation，關閉時不配置事件或逐 pixel 呼叫 closure；批次邊界與既有取消檢查共用。

barrier 到達條件必須是已處理非空 stamp 的至少4,096次 raster pixel iteration；conversion case 另在已有 alpha 結果、R8 已處理4,096 pixels 時到達。stage 必須真實反映正在執行的迴圈，不能用 callback 次數反推。validation 內部既有批次 `validated()` 若含大迴圈，也須確認取消上界，不只在其前後加 check。

控制流程：worker 報告指定 stage 已到達 → 測試 coordinator 呼叫父 `Task.cancel()` → 解開 barrier → await 全部 task 結束 → 檢查錯誤與無發布。超時視為測試 FAIL，且 teardown 保證解開 barrier／cancel／join，避免 cooperative executor 或主 actor 死鎖。sleep 只能作 watchdog，不能證明已進入 stage；不得用 count=9 或任意錯誤視為取消成功。

### 6.2 必測行為

| ID | 場景 | 驗收 |
| --- | --- | --- |
| CAN-A | 單 mask direct async route、sync renderer 在 detached worker 內，各在 raster／conversion 取消 | default `Task.checkCancellation()` 導出 CancellationError；probe 不替代真正 cancel |
| CAN-B | 至少3個 active masks，保證至少2個 coverage worker 已 started，再取消父 task | 所有 started worker 都有 finished，active count 歸0；task group 不回傳部分成功影像 |
| CAN-C | 經 `CoreImagePreviewRenderer`／scheduler 的 production route，A 覆蓋中被 B 取代、切圖與取消 | A 不發布 image／histogram／error；B 的 subject／generation／mapping 正確；計數含已取消仍存活工作 |
| CAN-D | 經 `PhotoExporter`，6000×4000 synthetic decoder，coverage 中途取消 | `.cancelled`、temporary file 清理、無目的檔成功發布；來源不變；所有 worker 已結束 |
| CAN-E | 進入 validation／sampling 後取消；預先取消；error 與 cancel 競合 | 下一可控邊界退出；無吞錯、無 hanging task，錯誤類型符合既有契約 |

最遲每4,096次 pixel／point 迭代及每個 tile 邊界可協作取消；新 metadata 派送長迴圈也不能無界等待。PNG/TIFF encode、RAW decode 等不可搶占平台區段另報，不把等待混入 coverage 取消數字。

效能測量另跑 Release：preview 8次、原尺寸8次，從 cancel 呼叫到父與全部子工作結束的 p95 ≤100 ms；記錄 barrier 釋放時間與 stage。functional correctness 不依賴機器快慢，timeout／超過門檻的樣本原樣保留。

## 7. FIX-PERF：正確輸出後的 B/O 驗收

### 7.1 比較協定

PIX、REL、CAN functional gates 通過後才計正式效能。B 是 §2.1 的 scalar candidate，O 是修正後產品；U 可保留作診斷第三欄，不取代 B，也不能用較快的錯圖通過驗收。

提交可在 B/O 執行的共同 harness 與固定 workload generator。B 缺少 coverage 觀測入口時，只可在隔離 baseline 快照加入 test-only wrapper、測試檔及六個 internal helper 的相同可測性修正，必須保存完整 instrumentation patch、digest 與 allowlist diff，證明 render math／輸出未變；不能在 B 改成 optimized async rasterizer，或修改受保護來源工作樹。直接使用 B 的產品 API 量端到端。

先建置全部待測版本，再計時；量測時不並行編譯、跑完整 suite 或啟動 Simulator。使用相同硬體／電源／OS／Xcode／decoder／recipe／output color space，記 thermal state，無法取得的欄位明列 unavailable。context 生命週期一致，context 建立數另列。

主 workload 完全沿用前輪 §5.1 的 UUID／seed／0、1、10 masks／路徑／參數；至少一次 warmup。每個 scenario 兩輪：第一輪 `B O O B` 區塊重複4次，第二輪 `O B B O` 區塊重複4次，各輪 B/O 各8個樣本。B/O 以各自 sample ordinal 對應相同 exposure 序列，不以 wall-clock 出場次序改變內容。

| scenario | 明確輸入變化 |
| --- | --- |
| cold first open | 每樣本新 renderer/context；與 warm 分表 |
| warm unchanged | 相同 immutable request，仍真正 materialize，記明未改動 |
| parameter changed | ordinal 偶數 global exposure +0.05、奇數 -0.05；neutral 對照維持0；B/O 對應相同序列 |
| stroke appended | 從共同 base 複製，每樣本只在 mask0 追加 (0.15,0.35)→(0.85,0.65) 的兩點 paint stroke，style 沿用主 workload；不能逐樣本無界累積。0 mask 對照保持空筆刷，不記成追加成功 |
| stress vectors | paint→erase→paint、size=1、geometry 非 neutral；使用已提交且 B/O 共用的 fixture 定義 |

每個 timed sample 必須有輸出尺寸／結果驗證；獨立像素比較在計時外進行。coverage raster bytes、lazy graph 建立、CGImage materialization 不混用名稱。

### 7.2 產品量測與記憶體

- synthetic 1600×1067：coverage、validation/sampling、blend/materialization 與總時間分列；階段重疊時不把平行子 task 耗時相加冒充 wall time。
- 真實 RAW：以 production preview 量0／1／10 masks；依前輪環境變數私有注入，public artifact 不含檔名／路徑／RAW digest。標 native／decoded／output 三種尺寸。
- 匯出：24MP 6000×4000 synthetic case 加上真實 RAW 原尺寸；每輪 B/O 一／十 mask 各至少3次，新檔名，計時含 encode、close 與 atomic publish。不得將 source downsample 到24MP 假稱原尺寸。
- RSS：對已建置、隔離執行的測試程序量 peak，分開0／1／10 mask preview/export；不包含 compiler 或取代用 buffer 估算。索引、sample metadata、並行 worker、CIImage backing 都計入。
- 50次「編輯→coverage 進入→cancel→切圖」在同程序進行，先量 warm plateau，最後 join 工作並 wait for quiescence，再量 settled RSS。task count 使用實際 started/finished probe，不能只讀 scheduler dictionary。
- 若並行 mask metadata 造成超標，使用有界 worker 數／批次與既有 R8 graph，保持 mask composite 順序；不得降解析度、刪點或逐 stamp 降低精度。

### 7.3 沿用門檻

| Gate | 每輪判定 |
| --- | --- |
| PERF-EMPTY | O p50 ≤B p50＋max(5 ms,B p50×5%)；O p95 ≤B p95＋10 ms |
| PERF-COVERAGE | 1600px 一／十 mask coverage p50 ≤20／80 ms；B 已達標時回歸 ≤max(2 ms,B×5%) |
| PERF-PREVIEW | O 相對 O empty 的增量 p50 ≤30／100 ms、p95 ≤60／150 ms；synthetic 與 RAW 各列 |
| INTERACTIVE-150 | 真實 RAW production preview 依0／1／10 masks、cold／warm／changed 分列絕對時間；暖樣本 p50及p95均≤150 ms才標該情境 PASS，cold另列；不得由 incremental 或 empty 推導其他情境 |
| PERF-EXPORT | 各一／十 mask median 比 B 改善≥50%；B已≤5／15秒時可少於50%，但O須維持 absolute budget且無>5%回歸 |
| PERF-MEM | preview peak ≤B＋32 MiB；full export peak ≤B且24MP case ≤768 MiB；50次後 settled ≤warm plateau＋32 MiB |
| PERF-CANCEL | 8次preview、8次原尺寸 coverage中途取消，p95≤100 ms且worker全結束、無晚到發布 |
| PERF-UI | 既有16 ms heartbeat額外延遲p95≤50 ms、max≤100 ms；同裝置至少30次動作、暖預覽p95不比B差>10% |

原規格的 INTERACTIVE-150 未定義足夠統計細節，本文件補明暖 p50／p95 的判定，未放寬原≤150 ms目標。其他門檻沿用前輪。p50為中位數，p95為nearest-rank `ceil(0.95*n)`，n=8時就是最大值；export n=3報median/max，不稱穩態p95。

### 7.4 證據產物

提交 JSON schema、harness、操作說明與去識別化 raw sample artifact。schema至少含 `schemaVersion`、`productSHA`、`harnessSHA`、`instrumentationDigest`、`configuration`、`defines`、`scenario`、`variant`、`round`、`order`、`sampleOrdinal`、`seed`、三種尺寸、recipe IDs、stage durations、total duration、pixel error、worker counts、cancel outcome、RSS、thermal state、result。失敗／取消是 record，不丟棄或補抽後只留快樣本。

資料不存在用null及原因，不填0；未知gate維持NOT RUN。公開欄位採allowlist，private raw log不提交；統計必須能從提交的samples重新算出。效能測試本身 exit 0只證明有執行，harness要另算門檻並輸出逐gate結果；缺mandatory欄位或超標不得顯示整體PASS。功能、效能、設備與灰卡各有結果，不用其中一類的成功取代另一類。

## 8. FIX-DOC 與分段交付

### 8.1 文件修正

舊 report／handoff 加日期明確的更正區塊，保留原表與原命令歷史；指出 direct R8未驗、僅水平跨tile、counter-only取消、全域DEBUG define與empty RAW preview範圍。舊spec更新為已有候選實作、由本追補規格約束；本新 spec 已實作 F1～F3，後續狀態更新保留原驗收門檻。

最終新增 `docs/testing/reports/2026-10-06-brush-raster-correctness-followup.md` 與對應 handoff；每個下列階段填 PASS／FAIL／SKIPPED／NOT RUN，附完整產品 SHA、exact command、exit、executed/skipped/failures、raw artifact與未完成原因。F0 時 CURRENT 的下一步為 PIX-01 失敗測試；該階段已完成，目前下一步依後續計畫 Task 2 執行完整 synthetic ABBA。歷史PASS不代表最終O沿用通過，產品變更後重驗受影響gate。

### 8.2 任務順序與目標檔案

| 階段 | 檔案範圍 | 交付／停止條件 |
| --- | --- | --- |
| F0 | spec／report／handoff／CURRENT | 凍結 B/U SHA、保留前次結果與更正；文件交付不執行產品修正 |
| F1 | `BrushMaskRenderer.swift`、`BrushMaskScalarOracleTests.swift`、`BrushMaskPerformanceAcceptanceTests.swift` | 跨垂直tile RED→GREEN、直接R8／非對稱blend／geometry；未過不做正式perf |
| F2 | `Sources/EditorCore/EditorSession.swift`、`Scripts/run-brush-performance-acceptance.sh` | 六個internal helper可測，移除全域DEBUG；原始Release命令＋full Release PASS |
| F3 | renderer、`CancellableWork.swift`、preview/export內部測試注入、cancel／scheduler tests | stage barrier＋real cancel、worker join、cleanup、stale-result測試 PASS |
| F4 | `BrushMaskPerformanceTests.swift`、integration acceptance、script與schema／artifact | B/O ABBA、RAW preview、export/RSS／50次取消；每gate有結果，不放寬門檻 |
| F5 | regression／build／privacy與文件 | 最終SHA重新驗證，更新新report/CURRENT/handoff，保留人工gate狀態 |

F1→F2→F3→F4→F5。F1優先避免量到錯誤影像；F2使其後Release證據不受DEBUG workaround污染；F3先確認worker生命週期，再解讀F4記憶體。F0只整理已知事實，不能把後續工作標已完成。

工作量以五個可審查切片交付：F1索引與pixel matrix、F2測試組態、F3並行取消、F4量測工具／執行、F5跨平台驗收／交接各一組；取消及RAW量測風險最高。尚無可信工時估計，以各階段exit gate管理，不承諾從舊測試數量推算時程。

## 9. 驗證入口與完成條件

各 TASK 路徑使用本輪新建目錄；先 build B/O 再計時，測試結束核對非零匹配。下列命令分別記 exit/counts，不用最後一個成功命令遮蔽前一步失敗。

```sh
swift test --scratch-path "$TASK_DEBUG_SCRATCH" --filter 'BrushMaskScalarOracleTests|BrushMaskRendererTests|BrushCoordinateMappingTests|BrushMaskPerformanceAcceptanceTests'
swift test --scratch-path "$TASK_DEBUG_SCRATCH" --filter 'BrushMaskCancellationTests|PreviewSchedulerTests|PhotoExportTests|EditorSessionEyedropperRenderingTests|EditorSessionBrushMaskGestureTests'
swift test -c release --scratch-path "$TASK_RELEASE_SCRATCH" --filter 'BrushMaskPerformanceAcceptanceTests'
swift test -c release --scratch-path "$TASK_RELEASE_SCRATCH"
swift test --scratch-path "$TASK_DEBUG_SCRATCH"
swift build --scratch-path "$TASK_STRICT_SCRATCH" -Xswiftc -strict-concurrency=complete
swift test --scratch-path "$TASK_DEBUG_SCRATCH" --filter RawFixtureTests
LUMAHARBOR_BRUSH_PERF_SCRATCH_PATH="$TASK_PERF_SCRATCH" Scripts/run-brush-performance-acceptance.sh
LUMAHARBOR_SCRATCH_PATH="$TASK_MAC_SCRATCH" Scripts/build-app-bundle.sh release
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' -derivedDataPath "$TASK_SIM_DATA" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS' -derivedDataPath "$TASK_DEVICE_DATA" CODE_SIGNING_ALLOWED=NO build
Scripts/verify-release-privacy.sh build/LumaHarbor.app
LUMAHARBOR_RELEASE_DIR="$TASK_UNPUBLISHED_RELEASE" Scripts/package-mac-release.sh release
git diff --check
```

F4須擴充既有script與操作說明，提供上述B/O配對、原尺寸、取消/RSS的可重現入口；單獨執行舊O-only script不能宣稱完整驗收。RAW環境由`LUMAHARBOR_RAW_FIXTURE_DIR`私有注入，optional reference export的skip與required RAW執行結果分開。封裝先核對既有bundle，避免刪除來源不明產物；使用新的未發布輸出目錄，驗checksum與ZIP解壓內容，簽署設定無差異。

- **此追補的程式修正通過**：PIX-A～E、REL、CAN-A～E、必要資料／recipe回歸與標準Release／Debug測試均有最終SHA證據；所有效能／memory gates逐項完成，必要build/RAW/privacy通過，獨立審查無未處理阻擋finding。
- **整合READY**：在上述基礎上，完成前輪Mac／Simulator／實體iPad基本操作、適用輸入、灰卡與所有原必需gate；任何必要FAIL／NOT RUN仍為DONE_WITH_CONCERNS，不以文件完成冒充產品完成。
- 獨立審查須由非writer覆核像素、取消、recipe、allocation與benchmark；writer自查不算獨立review。無reviewer記NOT RUN。
- PUBLIC release／notarization與Lightroom Gate 2仍屬另案，不能混成這輪已授權或已完成的工作。

## 10. 回退與唯一下一步

保持B與U可追溯，產品／測試與文件以可審查commit分離。若出現像素、資料或取消回歸，停止採用該候選；回退應另開可審查修正，保留使用者sidecar與已保存brush資料，不做hard reset或降schema。U含已知row defect，不能直接回退至U就稱為安全發布版本。

下一個有界動作：依[後續計畫 Task 2](../plans/2026-10-06-brush-acceptance-completion.md)，執行 cold／warm／changed／appended／stress 的完整 synthetic B/O ABBA，核對 480 筆資料與逐 gate 結果。此步不依賴私人 RAW 或實體裝置；其後補 scheduler、RAW/export 與人工驗收。
