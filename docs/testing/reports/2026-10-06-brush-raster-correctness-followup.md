# Brush raster correctness follow-up 驗收報告

日期：2026-10-06

狀態：`DONE_WITH_CONCERNS`

## 2026-10-07 修正後重跑（目前權威結果）

本輪在同一分支完成兩項驗收契約修正後重新量測：`4fdbc1f` 對應 RAW／Export harness、`e7d6425` 對應 ABBA analyzer／harness 修正，並以 `4fdbc1f` 作為 runner 的 candidate／harness SHA。舊的 2026-10-06 數字與 artifact 仍保留為歷史資料，不覆寫。

- 完整 synthetic ABBA：480 筆，`validation PASS`、`overallResult DONE_WITH_CONCERNS`；`PERF-EMPTY` 10/10、`PERF-MEM-PREVIEW` 30/30、`PERF-PREVIEW` 16/20 PASS，stress 四個 preview gate 仍 FAIL。證據：[2026-10-07 full ABBA repair](../evidence/2026-10-07-brush-full-abba-repair/README.md)。
- RAW／Export：352 筆，`validation PASS`、`overallResult DONE_WITH_CONCERNS`；`PERF-EXPORT` 4/4、`PERF-MEM-EXPORT` 4/4、`PERF-MEM-PREVIEW` 9/9 PASS；warm RAW `INTERACTIVE-150` 的 0/1/10 masks 仍 3/3 FAIL。證據：[2026-10-07 RAW/export repair](../evidence/2026-10-07-brush-raw-export-repair/README.md)。
- RAW／Export 新版 schema v2 已把 context lifecycle、timer 前後建立次數、雙輪次順序與 distinct B/O SHA 納入 fail-closed 驗證；兩份 gate artifact 均可由 committed analyzer 逐位元重算，公開 artifact 隱私掃描無私人路徑。

## 1. 驗證對象

- Branch：`codex/brush-performance-acceptance-repair`
- Scalar baseline B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`
- 原 optimized candidate U：`26c3390ba59e0e2ae416618d6e832a5c0eeba98d`
- 追補規格：`a2cf22266828f16a68d857df92c3a6c2c2cbf654`
- ABBA 最終回歸／analyzer SHA：`4e74bf3813ac4e6f6dbdc27b10d8a779c4ef3786`
- ABBA 產品 O／harness SHA：`c425cb7fdc93442e915c13eee913bf175fc15758`；後者到最終回歸版本只修改 analyzer，未改 renderer。
- 完整五情境 ABBA／parity SHA：`a4278c15606ed6e79d414fcf646acb37c30b223f`；此 commit 只修正 changed benchmark 的 neutral 0-mask control 並新增契約測試，產品 renderer 與 `4e74bf3` 相同。
- Scheduler quiescence SHA：`2b3acc4dbab87d91684ef127608a873173fbf7e5`；production-route harness SHA：`cf50e5695c2ee02e8fd006e50160293f834c7a0a`；Release acceptance analyzer／artifact SHA：`5170fb18d06b49415dc6b1c56bf9dca250c05abd`。
- 真實 RAW／原尺寸 export harness、runner 與 analyzer SHA：`8bc6819cae1ead2225f265116bb6822d9ecf087c`。
- 狀態沒有提升為 READY：三個 warm RAW `INTERACTIVE-150` 與四個 synthetic stress gate FAIL；公平 stage、人工裝置與獨立 reviewer gate 尚未完成。

## 2. 實作結果

| 階段 | Commit | 結果 | 內容 |
| --- | --- | --- | --- |
| F1 像素正確性 | `29718d2` | PASS | 修正跨垂直 tile 的全圖 row mapping；新增直接 R8 oracle、127/128/129/240/256/257 等高度、非零重疊 masks、正負原點與 sync/async 比對。 |
| F2 標準 Release | `bc89693` | PASS | 六個 EditorSession internal test helper 不再依賴全域 `-DDEBUG`；acceptance script 移除該 workaround。 |
| F3 取消生命週期 | `1ded16a` | PASS | 新增 per-invocation stage/worker observer、validation/sampling cooperative cancellation、preview/export 注入點與真正父 Task 取消測試。 |
| F4 可重現證據 | `c425cb7` | PARTIAL PASS | 新增 B/O ABBA runner、schema、baseline testability patch、取消延遲及記憶體診斷；正式 warm synthetic ABBA 通過，其他必要情境仍有 NOT RUN。 |
| F4 證據完整性 | `4e74bf3` | PASS | analyzer 改為拒絕缺 mandatory 欄位、unexpected 欄位、錯誤 order/round/maskCount，以及不一致的 harness、instrumentation 或 product SHA。 |
| F4 完整 synthetic matrix | `a4278c1` | PARTIAL PASS | 五情境 480 records validation PASS；pixel parity PASS，cold/warm/changed/appended 通過，stress preview 延遲四個 gate FAIL。 |
| F5 scheduler／取消驗收 | `2b3acc4`、`cf50e56`、`5170fb1` | PARTIAL PASS | scheduler 可等待所有 superseded live tasks join；production-route 50-cycle、8+8 cancellation 與 settled RSS PASS；acceptance analyzer／schema 已 fail closed。公平 B/O stage coverage 仍 NOT RUN。 |
| F4 真實 RAW／原尺寸 export | `8bc6819` | PARTIAL PASS | 176 records validation PASS；PERF-EXPORT 4/4、export RSS 4/4、preview RSS 9/9 PASS；warm RAW INTERACTIVE-150 0/1/10 masks 均 FAIL。 |

F1 的 RED 是實際像素 assertion failure：U 上兩個案例分別有 61,680 與 66,049 bytes 差異。修正後 focused matrix 19/19 PASS。這不是編譯失敗或 sync/async 互相比對。

F2 的 RED 是移除 `-DDEBUG` 後標準 Release test target 因六個 helper 缺失而編譯失敗；GREEN filtered Release 1/1 PASS，最終完整標準 Release suite 亦通過。

F3 已涵蓋 sync raster、async conversion、三個 active masks 且至少兩個 worker、validation、sampling、pre-cancel、PreviewScheduler A→B stale suppression，以及 6000×4000 export 取消後無 final/tmp 發布。Task 3 後續補上 scheduler 的 live-task join 介面與完整 50-cycle production-route 證據，取代早期只直接取消 renderer 的診斷限制。

## 3. B/O warm ABBA 結果

96 筆既有樣本已原樣保存於[證據目錄](../evidence/2026-10-06-brush-warm-abba/README.md)，含 samples、重算 gates 與 checksum。此次重算 exit 0、validation PASS，不是新一輪效能量測。當時完整硬體／供電／OS／Xcode 清單未存於樣本，後續矩陣需補記。

下表 incremental p50/p95 是「有遮罩組的分位數」減「empty 組的同一分位數」，不是逐筆差值的分位數；因此 round 2 一個 mask 的 incremental p95 小於 incremental p50 並非總延遲分布倒置。

正式命令以 4 blocks、warm scenario、0/1/10 masks 執行兩輪；round 1 為 `B O O B`，round 2 為 `O B B O`。共接受 96 筆 record，baseline SHA、product SHA、harness SHA 與 instrumentation digest 均一致；validation `PASS`，整體仍為 `DONE_WITH_CONCERNS`。

| Round | Gate | O p50 | O p95 | 結果 |
| --- | --- | ---: | ---: | --- |
| 1 | empty total | 2.253 ms | 2.392 ms | PASS |
| 1 | 1 mask incremental | 11.525 ms | 11.730 ms | PASS |
| 1 | 10 masks incremental | 24.201 ms | 25.128 ms | PASS |
| 2 | empty total | 2.151 ms | 2.452 ms | PASS |
| 2 | 1 mask incremental | 11.719 ms | 11.525 ms | PASS |
| 2 | 10 masks incremental | 24.343 ms | 26.845 ms | PASS |

| Round | Masks | B peak RSS | O peak RSS | 結果 |
| --- | ---: | ---: | ---: | --- |
| 1 | 0 | 46,776,320 | 46,727,168 | PASS |
| 1 | 1 | 66,813,952 | 52,953,088 | PASS |
| 1 | 10 | 85,983,232 | 109,625,344 | PASS；低於 B + 32 MiB |
| 2 | 0 | 46,759,936 | 46,727,168 | PASS |
| 2 | 1 | 66,797,568 | 52,969,472 | PASS |
| 2 | 10 | 85,983,232 | 111,640,576 | PASS；低於 B + 32 MiB |

另有 Release 診斷：preview cancellation p95 0.080 ms、24MP export cancellation p95 0.309 ms；50 個 measured cycles 加 5 次 warmup 後，workers 55/55、active 0，settled RSS 比 warm plateau 增加 16 KiB。這些結果支持 cancellation lifecycle，但不取代下表標為 NOT RUN 的完整產品 gate。

analyzer 的 fail-closed 測試另以完整 96 筆資料得到 exit 0；移除一個 mandatory 欄位後得到 exit 1、validation `FAIL`，僅接受 95 筆資料。

## 4. 完整五情境 ABBA 與像素核對

完整證據、checksum 與重算結果見[full ABBA evidence](../evidence/2026-10-06-brush-full-abba/README.md)。第一次 480 筆矩陣找出 changed 的 0-mask 對照也套用 ±0.05 exposure；該資料保留為診斷，不用於正式 changed 判定。新增契約測試先在原 harness 出現 16 assertions failure，修正後 Release focused suite 2 executed、1 skipped、0 failures。

修正後正式矩陣以 `a4278c15606ed6e79d414fcf646acb37c30b223f` 執行 480 筆，兩輪順序、B/O sample ordinal、1600×1067 輸出與 metadata 一致；所有 sample thermal state 為 nominal。analyzer exit 0、validation PASS，結果為 56 PASS、4 FAIL、7 NOT RUN：

- PERF-EMPTY 10/10 PASS；PERF-MEM-PREVIEW 30/30 PASS。
- PERF-PREVIEW 16/20 PASS；cold、warm、changed、appended 兩輪全部通過。
- stress 1 mask：round 1 p50/p95 增量 81.211/82.507 ms；round 2 81.314/81.308 ms，超過 30/60 ms 預算。
- stress 10 masks：round 1 132.794/144.226 ms；round 2 133.732/135.118 ms，p50 超過 100 ms 預算。
- 其餘 coverage stage、RAW、完整 export 效能、export RSS 與 UI 保持 NOT RUN；scheduler 50-cycle 與正式 synthetic cancellation artifact 已在下一節補齊。

計時外 pixel parity 從 immutable B/O archive 產生相同 workload：B/O capture 各 1 executed、0 skipped、0 failures；18 份 production preview RGBA8 與 66 份 direct R8 的最大 byte error 都是 0。因此 stress 是效能 FAIL，沒有觀察到像素回歸。

## 5. Scheduler、取消與 settled RSS

完整 allowlist artifact、checksum、TDD RED/GREEN 與量測邊界見 [scheduler cancellation evidence](../evidence/2026-10-06-brush-scheduler-cancellation/README.md)。`testPreviewSchedulerQuiescenceWaitsForCancelledProductionWorkerToJoin` 在修正前為 1 test／2 failures：scheduler 的最新請求字典已清空，但 raster worker 仍 active。`2b3acc4` 另追蹤所有已啟動 generation，並提供 `waitUntilQuiescent()`；`BrushMaskCancellationTests|PreviewSchedulerTests` 隨後 19/19 PASS。

`cf50e56` 的 Release runner 在同一 scheduler 先做 5 次 warmup，再做 50 次 A raster barrier → submit B/cancel A → release → await/join；`5170fb1` 收緊 analyzer／schema 後重新量測。B image 55/55 delivered、A 55/55 discarded、error 0；subject/generation/context/mapping 與 rendered histogram 各 55/55 通過。workers 55/55、active 0；warm plateau 77,135,872 bytes，settled 69,959,680 bytes，低於 110,690,304 bytes 上限，因此 `PERF-MEM-50-CANCEL` PASS。

preview 與 6000×4000 export 各 8 次，由 coverage barrier release 到 parent/worker join 的 p95 分別為 0.052000 ms 與 0.370416 ms，workers 各 8/8、active 0，`PERF-CANCEL` PASS。此數字明確排除 barrier 前已完成的 synthetic decode，以及未進入的 CGImageDestination encode；它不代表 decode/encode 本身可被搶占。

`5170fb1` 的 analyzer TDD 先以 4 個 RED 案例證明舊版本會接受缺欄位、unexpected 私密欄位、損壞 JSON 與短 SHA；修正後 6/6 PASS。正式 raw log 再獨立重算，結果與 artifact 逐位元相同，SHA-256 為 `b79e0d238be7d885c12dde38a760aa7bcf89fad5b20f043439b2396214da8b1d`。

`PERF-COVERAGE` 仍為 NOT RUN。B 的 scalar renderer 與 O 的 tiled/parallel renderer沒有共同且互斥的 validation、sampling、raster、blend/materialization wall-time 邊界；sampling 位於 worker 內且 mask 可平行重疊。artifact 只保存 O-only `coverageIncludingSampling` 診斷，一／十 masks p50 為 11.503／21.438 ms；其餘 stage 欄位為 null，未拿混合數字判定正式 coverage gate。

## 6. 真實 RAW preview 與原尺寸 export/RSS

完整去識別化樣本、gate、checksum、重算與操作命令見 [real RAW/export evidence](../evidence/2026-10-06-brush-raw-export/README.md)。既有私有 fixture 可用；`RawFixtureTests` 10 executed、1 optional reference skipped、0 failures，required RAW case 全部通過。公開文件與 artifact 均未保存 fixture 名稱、路徑或來源 digest。

`8bc6819` 新增 production preview／`PhotoExporter` 共用 harness、序列 ABBA runner、sample schema 與 fail-closed analyzer。Analyzer TDD 8/8 PASS，涵蓋缺 fixture、downscaled export、publish/reopen 未完成、unexpected 私密欄位、短 SHA、複合型別及 real-RAW RSS 規則；Release 計時邊界 1/1 PASS。正式 runner 先編譯 B/O，再執行 144 筆真實 RAW preview 與 32 筆 synthetic／真實 RAW full export，共 176 records；validation PASS、thermal 176/176 nominal，來源量測前後完整 digest 一致。

真實 RAW native 為 6000×4000；preview decoded/output 為 1067×1600。原尺寸 export 的 decoder 實際回傳 4000×6000，published JPEG 為 6000×4000，方向差異核對後尺寸一致，沒有 downscale。每個 export timer 都包含 production export return、atomic publish 及重新開啟 published JPEG 的尺寸驗證。

| Masks | O warm p50 | O warm p95 | INTERACTIVE-150 |
| ---: | ---: | ---: | --- |
| 0 | 149.303 ms | 155.067 ms | FAIL |
| 1 | 155.957 ms | 160.231 ms | FAIL |
| 10 | 167.483 ms | 172.726 ms | FAIL |

`PERF-MEM-PREVIEW` 9/9 PASS。cold 與 changed 的完整 B/O p50/p95 已保存在 evidence，但依規格不拿 cold 冒充 warm gate。

| Source | Masks | B median | O median | PERF-EXPORT | PERF-MEM-EXPORT |
| --- | ---: | ---: | ---: | --- | --- |
| synthetic-24mp | 1 | 0.324965 s | 0.191194 s | PASS | PASS |
| synthetic-24mp | 10 | 2.733026 s | 0.322321 s | PASS | PASS |
| real-raw | 1 | 0.574573 s | 0.452315 s | PASS | PASS |
| real-raw | 10 | 2.277552 s | 0.498927 s | PASS | PASS |

B 的四組 median 已低於一／十 masks 的 5／15 秒 absolute budget，因此依「O 維持 absolute budget 且不回歸超過 5%」判定；四組都通過。24MP O peak RSS 為 180,502,528／439,091,200 bytes，均低於 B 與 768 MiB；真實 RAW O peak RSS 為 284,606,464／579,223,552 bytes，均低於 B。

正式 `brush-raw-export-samples.jsonl` 與 `brush-raw-export-gates.json` SHA-256 分別為 `475509638b350051a01f719b13200503ea9732a390030053fcdd3871e60d5256`、`31bf6393cf4b5f04588de7ceb256cc29485ebda9e530e1e91a80114ecb053e6f`。獨立 analyzer 重算逐位元相同；公開 artifact 私密路徑掃描 PASS。20 個 gate 合計 17 PASS、3 FAIL，整體保持 `DONE_WITH_CONCERNS`。

## 7. 最終 SHA 自動驗證

主要命令如下；已去除歷史私人暫存位置，以 TASK 變數表示。各變數由執行者指定新的本機 scratch／output 位置；這些完整 regression 命令是歷史命令的去識別化寫法，本次沒有重跑。Task 2 另執行 Release focused harness、完整 synthetic ABBA 與 untimed parity capture；其證據已保存至上述目錄，其餘原始 build/test log 維持本機保存。

```sh
LUMAHARBOR_BRUSH_ABBA_BLOCKS=4 \
LUMAHARBOR_BRUSH_ABBA_SCENARIOS=warm \
LUMAHARBOR_BRUSH_ABBA_MASK_COUNTS='0 1 10' \
LUMAHARBOR_BRUSH_ABBA_RUN_ROOT="$TASK_ABBA_ROOT" \
Scripts/run-brush-performance-abba.sh

swift test --scratch-path "$TASK_DEBUG_SCRATCH"
swift test -c release --scratch-path "$TASK_RELEASE_SCRATCH"
CLANG_MODULE_CACHE_PATH="$TASK_CLANG_CACHE" \
SWIFTPM_MODULECACHE_OVERRIDE="$TASK_SWIFTPM_CACHE" \
swift build --scratch-path "$TASK_STRICT_SCRATCH" \
  -Xswiftc -strict-concurrency=complete

LUMAHARBOR_SCRATCH_PATH="$TASK_MAC_SCRATCH" \
Scripts/build-app-bundle.sh release
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$TASK_SIM_DATA" \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$TASK_DEVICE_DATA" \
  CODE_SIGNING_ALLOWED=NO build

codesign --verify --deep --strict --verbose=2 build/LumaHarbor.app
Scripts/verify-release-privacy.sh build/LumaHarbor.app
LUMAHARBOR_RELEASE_DIR="$TASK_UNPUBLISHED_RELEASE" \
Scripts/package-mac-release.sh release
git diff a2cf222..HEAD --check
```

| 驗證 | 結果 |
| --- | --- |
| `swift test --scratch-path <fresh-debug>` | PASS；2,708 executed、21 skipped、0 failures |
| `swift test -c release --scratch-path <fresh-release>` | PASS；2,708 executed、21 skipped、0 failures |
| `swift build --scratch-path <fresh-strict> -Xswiftc -strict-concurrency=complete` | PASS；既有 Swift 6 warnings 保留 |
| `Scripts/build-app-bundle.sh release` | PASS；Release app 組裝並 ad-hoc signed |
| generic iOS Simulator build，`CODE_SIGNING_ALLOWED=NO` | PASS |
| generic iOS device build，`CODE_SIGNING_ALLOWED=NO` | PASS |
| `codesign --verify --deep --strict --verbose=2 build/LumaHarbor.app` | PASS |
| `Scripts/verify-release-privacy.sh build/LumaHarbor.app` | PASS |
| fresh unpublished `Scripts/package-mac-release.sh release` | PASS；ZIP、SHA-256、簽章與隱私掃描完成；notarization SKIPPED |
| `git diff a2cf222..HEAD --check` | PASS |
| 新增差異中的 private user/mount/temp-home/team scan | PASS |

第一次 strict-concurrency 重跑因沙箱禁止寫入使用者 module cache 而 exit 1；將 `CLANG_MODULE_CACHE_PATH` 與 `SWIFTPM_MODULECACHE_OVERRIDE` 指向工作樹外的暫存目錄後，同一原始碼驗證 PASS。此失敗不涉及編譯器診斷或程式碼變更。

## 8. Gate 狀態與限制

| Gate | 狀態 | 說明 |
| --- | --- | --- |
| PIX-A～D | PASS | 直接 R8、全圖 row flip、重疊 mask order、sync/async 獨立 oracle 已驗。 |
| PIX-E | PASS WITH EXISTING COVERAGE | 既有 geometry mapping 回歸與完整 suites 通過；本輪沒有新增完整人工 landmark corpus。 |
| REL | PASS | 不需全域 DEBUG define 的完整標準 Release suite 通過。 |
| CAN-A～E | PASS | 真正父 Task 取消、worker join、stale suppression、export cleanup 已自動驗證。 |
| PERF-EMPTY / preview RSS | PASS（五情境 synthetic） | empty 10/10、preview RSS 30/30 PASS。 |
| PERF-PREVIEW | FAIL（stress） | 20 個五情境 gate 中 16 PASS；stress 一／十 mask 兩輪共四個 FAIL。 |
| PERF-COVERAGE | NOT RUN | B/O 無共同且互斥的 stage wall-time 入口；O-only coverageIncludingSampling 一／十 masks p50 11.503／21.438 ms 只作診斷。 |
| cold / warm / changed / appended / stress ABBA | EXECUTED | 正式 480 records validation PASS；stress 延遲 gate FAIL。 |
| INTERACTIVE-150 | FAIL | 真實 RAW warm 0/1/10 masks p50/p95 已執行；三組均至少一個統計值超過 150 ms。cold/changed 另列，不冒充 warm。 |
| PERF-EXPORT / PERF-MEM-EXPORT | PASS | synthetic-24mp 與真實 RAW、一／十 masks 共 4 組；原尺寸與 publish/reopen 已驗，效能 4/4、RSS 4/4 PASS。 |
| PERF-MEM-50-CANCEL | PASS | 完整 production PreviewScheduler：5 warmup＋50 measured，A/B 發布與 mapping/histogram 正確，workers 55/55、active 0，settled 在 +32 MiB 內。 |
| PERF-CANCEL | PASS（synthetic coverage boundary） | preview/export 各 8 次 p95 0.052000／0.370416 ms，worker 全 join、無晚到發布；decode/encode 不可搶占區段另列。 |
| PERF-UI | NOT RUN | 未在 GUI 裝置執行 heartbeat 與 30 次操作。 |
| RawFixtureTests（Task 4 SHA） | PASS WITH OPTIONAL SKIP | 10 executed、1 optional reference skipped、0 failures；required RAW case 全部通過。 |
| Mac／實體 iPad／Pencil／輸入矩陣／灰卡 | NOT RUN | 無人工解鎖與實體驗收。Simulator/device generic build 不能取代操作驗收。 |
| 獨立 reviewer | NOT RUN | Sol 為主要 writer，Codex root 做整合與證據 validator review；仍不構成規格要求的非 writer 獨立覆核。 |
| notarization | SKIPPED | 本輪只產生本機未發布 alpha 封裝。 |

## 9. 判定與下一步

跨垂直 tile 像素錯位、標準 Release testability、取消生命週期、完整 scheduler 50-cycle、五情境 synthetic B/O、真實 RAW preview 與原尺寸 export/RSS 已具可重算證據。原尺寸 export 與 RSS 通過；synthetic stress 四個 gate、warm RAW 三個 INTERACTIVE-150 gate 明確 FAIL。公平 B/O stage coverage、人工裝置與獨立審查仍缺，因此分支保持 `DONE_WITH_CONCERNS`。

下一個有界工作是[後續計畫 Task 5](../../superpowers/plans/2026-10-06-brush-acceptance-completion.md)：安排非原作者唯讀審查，並依設備可用性分列 Mac／實體 iPad、heartbeat、輸入與灰卡操作。公平 B/O stage coverage 仍需先提供共同的互斥 production stage clock，不能由 O-only 混合時間推論通過。
