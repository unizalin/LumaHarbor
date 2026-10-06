# Brush scheduler cancellation acceptance evidence

日期：2026-10-06

- Product／harness／analyzer SHA：`5170fb18d06b49415dc6b1c56bf9dca250c05abd`
- PreviewScheduler quiescence fix：`2b3acc4dbab87d91684ef127608a873173fbf7e5`
- Production-route acceptance harness：`cf50e5695c2ee02e8fd006e50160293f834c7a0a`
- Configuration：Release
- Samples：preview cancellation 8、6000×4000 export cancellation 8
- SHA-256 (`acceptance.json`)：`b79e0d238be7d885c12dde38a760aa7bcf89fad5b20f043439b2396214da8b1d`

## TDD 與功能驗證

新增 `testPreviewSchedulerQuiescenceWaitsForCancelledProductionWorkerToJoin` 後，原 scheduler 的 RED 為 1 test、2 failures：`waitUntilQuiescent` 前身 `cancelAll` 已回傳，但 raster worker 仍 active。修正以 `liveTasks` 追蹤已啟動但尚未返回的所有 generation，並新增 `waitUntilQuiescent()`；GREEN focused matrix 為 19 tests、0 failures。

Codex root 另以 4 個 RED 案例確認原 acceptance analyzer 會接受缺欄位、unexpected 私密欄位、損壞 JSON 與非完整 commit SHA。`5170fb1` 改為 exact allowlist、巢狀欄位與數值檢查，schema 也收緊為六筆 record／三個 gate 的明確結構；最終 analyzer 單元測試 6/6 PASS。正式 raw log 再以同 SHA 獨立重算，輸出與本 artifact 逐位元相同。

50-cycle 診斷以同一個 production `PreviewScheduler` 與 `CoreImagePreviewRenderer` 執行。先做 5 次 warmup，再做 50 次 A raster barrier → submit B／cancel A → release → await quiescence。結果：

- B image 55/55 delivered；A 55/55 discarded；error 0。
- B token subject、generation、contextID、brush mapping 與 rendered histogram 各 55/55 通過。
- Coverage workers started/finished 55/55，active after join 0。
- warm plateau RSS 77,135,872 bytes；settled RSS 69,959,680 bytes；上限 110,690,304 bytes，PASS。

取消延遲由進入 coverage barrier 後開始，到 parent 與所有 worker join 為止；RAW decode 與 CGImageDestination encode 明列為本量測未涵蓋的不可搶占區段：

| Scenario | Samples | p95 | Worker join | Result |
| --- | ---: | ---: | --- | --- |
| Preview through scheduler | 8 | 0.052000 ms | 8/8、active 0 | PASS |
| 6000×4000 export | 8 | 0.370416 ms | 8/8、active 0 | PASS |

## Stage coverage 邊界

`PERF-COVERAGE` 維持 `NOT RUN`。目前 B 的 scalar renderer 與 O 的 tiled/parallel renderer都沒有提供相同且互斥的 validation、sampling、raster、blend/materialization wall-time 邊界；sampling 位於 coverage worker 內，平行 mask 也會重疊。將 worker CPU time 相加會冒充 wall time，複製 O 的 async rasterizer 到 B 又會改變 baseline math 與排程。

本 artifact 因此只把 `coverageIncludingSampling` 保存為 O-only 診斷；`validationSampling`、`coverageRaster`、`blendMaterialization` 均為 `null`。要解除 `NOT RUN`，B/O 都需要同一個 test-only production stage clock，在共同入口記錄互斥 wall-time span，並另在 CGImage materialization 完成後停表。

完整 allowlist artifact 見 [`acceptance.json`](acceptance.json)。本機 raw XCTest log 不提交；artifact 不含私人路徑、fixture 名稱或素材 digest。
