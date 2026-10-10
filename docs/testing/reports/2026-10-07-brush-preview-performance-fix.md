# LumaHarbor 筆刷預覽效能修正驗收報告

日期：2026-10-10（Asia/Taipei）

狀態：`DONE_WITH_CONCERNS`

本輪已處理原驗收矩陣中的 7 個效能 FAIL。問題集中為兩個根因：warm RAW 每次 render 重複 decode，以及筆刷 coverage 對每個 mask 做全圖 raster／合成。Gemini 唯讀審查指出的 256×256／128×128 規格落差也已修正；程式、自動驗收與獨立審查均已完成。2026-10-08 另以此分支的 Debug app 完成可執行的 Mac 前景驗收與 iPad Simulator slice。Mac follow-up 補齊筆刷 Delete／Undo／Redo、Local off/on paste、batch sync、snapshot restore／刪除，並修正實測發現的快照未持久化缺陷；Simulator 補跑 Files 選取／Quick Look 後返回、真實 Split View 窄窗、paint、autosave 與重啟保存。2026-10-10 再完成 30 次 Release 前景 UI heartbeat，並修正量測暴露的 overlay gesture 座標重複位移。`DONE_WITH_CONCERNS` 保留給未完成的受控滴管矩陣、中途手勢競態、Files 直接交件、精確 Simulator zoom/source mapping、實體裝置／輸入與灰卡項目。

## 根因與分段數據

B/O 現在使用相同、互斥的 monotonic wall-time stage 邊界：RAW decode、global adjustment graph、validation/sampling、coverage raster、per-mask adjustment/blend、final `makeCGImage` materialization。平行 coverage worker 以 interval union 計算 wall time，不累加 CPU duration。Baseline 的 observer 是 test-only Release patch，不改 baseline production math。

Synthetic stress aggregate（兩輪合併，p50／p95，ms）：

| masks | variant | raw decode | global graph | validation/sampling | coverage raster | per-mask adjustment/blend | final materialization | stage total |
| ---: | :---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | B | 0.009 / 0.023 | 0.001 / 0.003 | 0.012 / 0.046 | 175.096 / 192.717 | 0.051 / 0.061 | 3.866 / 4.263 | 179.290 / 196.862 |
| 1 | O | 0.005 / 0.006 | 0.001 / 0.001 | 0.240 / 0.297 | 8.801 / 10.111 | 0.037 / 0.056 | 2.550 / 2.811 | 11.988 / 13.210 |
| 10 | B | 0.011 / 0.012 | 0.001 / 0.001 | 0.077 / 0.092 | 1754.617 / 1814.902 | 0.415 / 0.492 | 7.333 / 7.586 | 1762.474 / 1822.993 |
| 10 | O | 0.006 / 0.007 | 0.001 / 0.001 | 3.097 / 3.813 | 64.776 / 74.801 | 0.108 / 0.113 | 5.169 / 5.363 | 70.664 / 81.013 |

`stage total` 取自 16 筆兩輪樣本的 `stageDurationsSeconds.totalMaterialized`；同一批樣本的端到端 `totalDurationSeconds` 合併 p50／p95 則為 1 mask `12.084/13.337 ms`、10 masks `70.779/81.143 ms`。端到端數據另含 harness 邊界開銷，因此不得以它取代共用互斥 stage clock，也不得把兩者視為同一欄位。

coverage raster 是 synthetic stress 的主要成本；RAW decode 與 per-mask adjustment/blend 不是主要瓶頸。RAW warm 測量則證實 decoded-preview cache 能移除重複 decode 的成本。

## 修改檔案與設計理由

- `Sources/RawProcessingCore/Preview/PreviewRenderInstrumentation.swift`：新增共享 stage model 與 interval-union collector。
- `Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift`：加入 decode、graph、validation、brush、materialization 分段計時；接入 bounded decoded-preview cache；取消後晚到結果不回填錯誤 context。
- `Sources/RawProcessingCore/Preview/DecodedPreviewCache.swift`：bounded LRU actor cache。key 綁定標準化 URL、檔案 size／mtime／generation、decode quality、decoder identifier、resolved RAW recipe、白平衡、lens correction、camera profile 與其他 decode inputs；interactive decode 與 full-resolution export 分離。
- `Sources/RawProcessingCore/Pipeline/BrushMaskRenderer.swift`：固定 128×128 bounded tile scratch／concurrency、相同幾何 coverage reuse、最多兩個 active mask worker，並在 cancellation 後 join 所有已啟動 worker。保留 mask 順序、paint／erase、geometry mapping、不同 mask adjustment、overlap、像素精度與 cancellation checkpoints。
- `Scripts/fixtures/brush-baseline-release-testability.patch`：以同一 stage 邊界讓 baseline B 可觀測，僅供驗收 harness 使用。
- `Scripts/analyze-brush-performance-abba.py`：只有 B/O 七段欄位完整且有限時才產生 `PERF-COVERAGE`；不完整舊 artifact 仍 fail closed 為 `NOT RUN`。
- `Tests/RawProcessingCoreTests/BrushPreviewABBAHarnessTests.swift` 與 analyzer tests：記錄 B/O stage JSON 並驗證完整 coverage matrix。
- `Tests/RawProcessingCoreTests/BrushMaskRendererTests.swift`：加入 128×128 tile acceptance contract，已先以 256 取得預期 RED，再改為 128 取得 GREEN。
- `Sources/LumaHarborApp/AppServices.swift`、`Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift`：將既有快照 sidecar 讀寫接入 Mac App 組裝層，並在照片選取的 generation／cancellation 邊界內載入快照。
- `Tests/LumaHarborAppTests/LibraryViewModelTransitionTests.swift`：加入建立快照、等待 sidecar、關閉並重開後重新載入的 app-level 回歸測試；先保存預期 RED，再由 `5d32550` 修正為 GREEN。
- `Sources/EditorCore/EditorSession.swift`、Mac／iPad editor views 與 `LibraryViewModel.swift`：把 render、history、brush display 的 observation boundary 分離，避免每個 preview frame 或已提交筆畫使整個 editor/root hierarchy 重算。
- `Sources/AdjustmentUI/BrushMaskOverlayView.swift`：一個 mask 使用一個 Canvas，並以明確 named overlay coordinate space 傳入 gesture location。量測時確認舊路徑把已是父座標的 location 再加 `imageFrame` 原點，造成 mapping 超界；`5530e91` 移除重複位移。
- `Sources/AdjustmentUI/BrushUIHeartbeatRecorder.swift`、`BrushUIPerformanceProbe.swift`、`Scripts/analyze-brush-ui-heartbeat.py`：加入 opt-in 16 ms heartbeat、gesture/pointer-up/visible-frame 邊界、fail-closed JSONL 與 B/O gate analyzer。

沒有降低解析度、刪除筆刷點、跳過調整、改 benchmark workload 或放寬門檻。

## 修改前後效能

### Synthetic stress（1600×1067）

| workload | B p50 / p95 | O p50 / p95 | 門檻 | 結果 |
| --- | ---: | ---: | ---: | --- |
| 1 mask round 1 | 180.794 / 216.295 ms | 12.105 / 13.244 ms | 30 / 60 ms | PASS |
| 1 mask round 2 | 180.506 / 186.025 ms | 12.067 / 13.337 ms | 30 / 60 ms | PASS |
| 10 masks round 1 | 1783.412 / 1824.322 ms | 70.907 / 81.143 ms | 100 / 150 ms | PASS |
| 10 masks round 2 | 1758.894 / 1792.669 ms | 70.099 / 71.513 ms | 100 / 150 ms | PASS |

### RAW warm preview

| masks | B p50 / p95 | O p50 / p95 | 門檻 | 結果 |
| ---: | ---: | ---: | ---: | --- |
| 0 | 172.412 / 183.000 ms | 36.285 / 39.805 ms | 150 / 150 ms | PASS |
| 1 | 190.245 / 204.335 ms | 39.560 / 49.993 ms | 150 / 150 ms | PASS |
| 10 | 385.381 / 393.690 ms | 56.002 / 61.015 ms | 150 / 150 ms | PASS |

### Original-size export

`PERF-EXPORT` 4/4、`PERF-MEM-EXPORT` 4/4 PASS。O p50：synthetic 24MP 1／10 masks=`123.601/382.940 ms`；真實 RAW 1／10 masks=`436.667/562.844 ms`。

### 前景 UI heartbeat

| 指標 | Baseline B | Candidate O `5530e91` | 門檻 | 結果 |
| --- | ---: | ---: | ---: | --- |
| heartbeat 額外延遲 p95 | 51.763 ms | 26.152 ms | ≤50 ms | PASS |
| heartbeat 額外延遲 max | 85.506 ms | 27.835 ms | ≤100 ms | PASS |
| warm preview p95 | 267.056 ms | 90.083 ms | ≤B×1.10（293.762 ms） | PASS |

B/O 各 30 次 Release 前景手勢；O 30/30 完整、0 取消。正式 O 樣本使用原生 drag，Accessibility 只負責進入筆刷模式，未落在計時中的 gesture 動作。

## Gate 狀態

| Gate／檢查 | 結果 |
| --- | --- |
| Synthetic stress performance | PASS，4/4 |
| Synthetic preview memory | PASS，4/4 |
| B/O `PERF-COVERAGE` | PASS，4/4；共同互斥 stage clock 已具備 |
| RAW warm `INTERACTIVE-150` | PASS，3/3 |
| RAW preview memory | PASS，9/9 |
| Original-size export | PASS，4/4 |
| Original-size export memory | PASS，4/4 |
| Pixel parity／scalar oracle | PASS，max R8 byte error 0 |
| Cancellation focused matrix | PASS，9/9 |
| 50-cycle worker convergence／RSS | PASS，55/55 joined，active 0 |
| Analyzer unit tests | PASS，41/41；UI heartbeat analyzer 子集合 6/6 |
| 128×128 tile acceptance contract | PASS，RED／GREEN 已保存 |
| Focused Release tests | PASS，31/31 |
| Full Release regression | PASS，`2c1d1e3` 驗證狀態 2733 tests、22 skipped、0 failures |
| Gemini 程式／spec 唯讀審查 | `APPROVED_WITH_CONCERNS`；唯一 minor 已由 `7af2125` 解決 |
| Gemini Mac 文件唯讀審查 | 初審 `CHANGES_REQUESTED`；端到端與 stage total 的來源說明補正後，follow-up=`APPROVED`、無 finding |
| `UI-MAC-01` 原生數值欄位 | PASS；Enter／blur／Escape／±／reset／非法值／焦點中 Undo/Redo 同步／同值外部 revision 使舊草稿失效均通過 |
| `UI-MAC-02` 白平衡滴管 | PARTIAL；啟用、單次取樣提交、明確取消通過；四色方向、切圖與晚到結果未跑 |
| `UI-BRUSH-01` | PASS；paint／erase、兩支筆刷切換、size／feather／flow／density、enable、select、Delete、Undo／Redo、autosave 與重開均通過；刪除一支不改另一支 mask／stroke |
| `UI-BRUSH-02` | PARTIAL；完成筆畫 Undo/Redo 與 close-to-library／reopen 通過；中途換圖／geometry／snapshot／cancel／close 未手動執行 |
| `STORE-01` | PASS；paint→原尺寸 TIFF export→close→reopen、Local off/on paste、batch sync、snapshot restore、快照寫入／重開、刪除最後快照／重開均通過；快照接線缺陷已修正並加入回歸測試 |
| `PERF-UI` | PASS；B/O 各 30 次完整 Release 前景手勢，O heartbeat p95/max=`26.152/27.835 ms`，warm preview p95=`90.083 ms` |
| `UI-SIM-01` | PARTIAL；fresh build／install／launch、直向／橫向、Files 選取／Quick Look 後返回、真實 Split View 窄窗、筆刷 paint、完成筆畫 Undo／Redo、曝光變更、autosave 與 relaunch persistence 通過；Files 直接交件、app-copy／in-place、精確 0.75x／1x／2x source mapping、鍵盤與 hands-on VoiceOver 未完成 |
| `UI-DEVICE-01`／`UI-INPUT-01` | NOT RUN；CoreDevice 中 iPad／iPhone 均為 unavailable |
| 灰卡色彩 gate | NOT RUN；未找到合格 RAW 灰卡與受控 ROI reference |

`PERF-COVERAGE` 不再是 NOT RUN；RAW/export harness 沒有把 stage coverage 反推成 gate，仍以其自身的 total wall-time、RSS 與 published-file checks 驗收。

## Mac 前景驗收

Mac 測試固定綁定本 worktree 的 `build/LumaHarbor.app`，configuration=`Debug`，平台為 macOS 26.7.1 arm64／Xcode 26.6；原效能候選 SHA=`7af2125`，snapshot follow-up SHA=`5d32550`。同機另有已安裝版程序，因此已排除其早期 smoke 觀察，所有正式結果都在精確 app bundle 路徑與暫存 RAW 副本上重跑。

數值欄位各種提交／取消路徑與 Undo 粒度通過。調整筆刷 sidecar 實際保存兩支 mask；第一支依序保存 paint、erase 兩筆，Undo 只移除 erase、Redo 恢復 erase，切換第二支再切回時 exposure 狀態沒有串線。Task 3 follow-up 另確認刪除第二支、Undo／Redo 與重開都不改第一支；Local off 不覆蓋目標筆刷，Local on 與 batch sync 依序複製兩支筆刷。Snapshot restore 在同一工作階段通過，但首次重開發現快照消失；最短反例確認 Mac 組裝層沒有接入已存在的快照讀寫。`5d32550` 修正後，建立快照會寫入 sidecar、重開可載回，刪除唯一快照後重開仍為空。前景匯出產生 4000×6000、16-bit TIFF，沒有降解析度。歷史 slice 見 [`mac-ui-manual-summary.txt`](../evidence/2026-10-07-brush-preview-performance-fix/mac-ui-manual-summary.txt)，follow-up 逐列紀錄見 [`mac-matrix.md`](../evidence/2026-10-08-brush-ui-followup/mac-matrix.md)。

## iPad Simulator slice

以 source HEAD `1dda4ad3f5c26a488fc8cce4cfc3172c87dd2a08` fresh build iPad Pro 11-inch (M4)、iOS 18.6 Simulator，unsigned Debug build exit 0。後續文件 HEAD `72945cf` 與該 source 間的 Sources／Apps／package inputs diff check exit 0，因此沿用相同 bundle。直向啟動與橫向旋轉均正常；局部調整可建立一支 adjustment brush 並繪製 paint stroke。匿名 sidecar aggregate 在 paint／Undo／Redo 後依序為 1／0／1 stroke；局部曝光由 0.0 調成 0.1 後，terminate／relaunch 仍保存 1 paint stroke 與 exposure=0.1。自動化 accessibility tree 可讀取 canvas、enable、delete、brush mode，以及 size／feather／flow／density／exposure 的 label／role／value。

Task 2 follow-up 另從 Files 選取測試 RAW；檔案先進入 Quick Look，切回 LumaHarbor 後可讀到既有筆刷與 exposure=0.1。這證明返回 app 後狀態仍在，不證明 Files 已直接把文件交給 app。再由 iPad 多工選單進入真實 Split View 窄窗，inspector／canvas 仍可操作。窄窗新增一筆後由 `未儲存` 轉為 `已儲存`，匿名聚合從 1 mask／1 paint stroke 變為 1 mask／2 paint strokes；terminate／relaunch 後仍為 1／2 且 exposure=0.1。

此結果仍只把 `UI-SIM-01` 維持在 PARTIAL。Files 直接交件及 app-copy／in-place 語意無法由 UI 獨立判別；工具也沒有曝露窄窗精確 logical point 尺寸。iPad 畫布將倍率限制在 1×～5×且沒有精確倍率讀值，因此 0.75×不可達，2×也無法從 UI 證明為精確倍率；原規格的 0.75×／1×／2× paint／erase source-marker mapping 保留 NOT RUN。hardware keyboard 與 hands-on VoiceOver 亦未執行；accessibility tree 可讀不等於 VoiceOver 人工驗收。實體 Pencil、實體裝置旋轉／Split View、真實效能 heartbeat 與灰卡色彩量測也不能由 Simulator 取代。歷史紀錄見 [`ipad-simulator-manual-summary.txt`](../evidence/2026-10-07-brush-preview-performance-fix/ipad-simulator-manual-summary.txt)，本次逐列結果見 [`simulator-matrix.md`](../evidence/2026-10-08-brush-ui-followup/simulator-matrix.md)。含私人照片的本機截圖沒有提交。

## 可重現驗證

完整原始 artifact、環境、SHA、命令、exit code 與 checksum 見[證據目錄](../evidence/2026-10-07-brush-preview-performance-fix/README.md)。

## 尚未完成與 bounded next action

產品效能修正、自動驗收、兩輪獨立唯讀 review、Mac 可執行 follow-up、PERF-UI，以及 Simulator 的 Files 選取／Split View／窄窗保存 follow-up 已完成。Mac 筆刷功能、資料保存與前景 heartbeat gate 已補為 PASS；中途手勢與受控四色滴管因操作通道／素材限制仍為 PARTIAL／NOT RUN。2026-10-10 使用者接受 `DONE_WITH_CONCERNS`，PR #2 已依 D-014 作 Alpha 例外 squash-merged 至 `main`，merge SHA=`8e64407c49d3bea108d9951ba878e29303670296`。同一 SHA 的 Mac Release `0.1.0 (3)` 已完成 build、codesign、安裝、產物雜湊核對與 launch smoke，均 PASS；實體 iPad 仍為 `unavailable`，signed install／版本核對／launch 為 `BLOCKED`。這不會把未完成 gate 改為 PASS，也不會豁免未來版本。裝置與受控素材到位後仍須補實體 iPad／Pencil／鍵盤／VoiceOver、四色滴管與灰卡矩陣；Simulator Files 直接交件與精確 zoom/source mapping 仍需要可觀測 storage mode／倍率及可散布 marker。
