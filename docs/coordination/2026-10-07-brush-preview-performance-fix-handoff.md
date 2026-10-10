# Brush preview performance fix handoff

## Status

`DONE_WITH_CONCERNS`

原驗收矩陣的 7 個效能 FAIL 已完成程式修正與自動驗收。`PERF-COVERAGE` 已由 NOT RUN 解除為 B/O 共同 stage clock 的 4/4 PASS。Gemini 唯讀審查的唯一 minor 已由 Sol 完成 128×128 tile 對齊與全套回歸；Mac 前景、30 次 `PERF-UI` 與 iPad Simulator 可執行 slice 已補跑，但實體裝置、輸入、灰卡與部分人工競態仍未完成，因此保留 `DONE_WITH_CONCERNS`。

## Git state

- Writer：Luna；128×128 follow-up：Sol；worktree owner：本 task 的 Codex workspace。
- Branch：`luna/brush-preview-performance-fix`。
- Performance product／harness HEAD：`7af212512f59768801081765808202fe84a85b25`。
- Mac snapshot follow-up product HEAD：`5d32550029fd317e377a732fa68b57ec2ff2cf85`。
- UI observation isolation HEAD：`ae8c59a457aa6f6298da43278edd53588562661e`。
- PERF-UI gesture fix／正式量測 HEAD：`5530e91f8f7cae86b6d6633cfd38f13d72bc896b`。
- 驗證契約 HEAD：`2c1d1e39bff060a62b208ed4371793b72a3f438b`。
- Base：`origin/main`=`82542e73aae8f16b0ba7e4d9d36a8a42451a7319`。
- Baseline B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`。
- 延續候選父版本：`eae30121ec7ef089b4a048a50151993c205e2686`；這是本 task 的相依例外，不表示已整合到 `main`。
- Branch 先前版本已推送至 `origin/luna/brush-preview-performance-fix`；本輪 `ae8c59a`、`5530e91`、`2c1d1e3` 與驗收文件提交尚未 push。Draft PR [#2](https://github.com/unizalin/LumaHarbor/pull/2) 維持 OPEN；遠端 `main` 尚未變動；沒有 merge 或 rebase，不得覆蓋其他 worktree。

## Changes

產品 commits：

- `b640823` — stage instrumentation、bounded decoded-preview cache 與 exact invalidation key。
- `26e7358` — bounded tile raster、repeated-geometry coverage reuse、bounded mask fan-out、cancellation join 與 scalar oracle。
- `f97760a` — B/O 共享 stage coverage gate、baseline test-only stage observer 與完整 stage schema。
- `f13de10` — 以當時 candidate SHA 保存 synthetic／RAW/export evidence 與文件。
- `462b30a` — 保存 agy → Gemini 3.1 Pro High 唯讀審查報告。
- `7af2125` — 將 coverage tile 對齊固定 128×128，並加入 acceptance contract。
- `5d32550` — 將 Mac snapshot load/save 接入 AppServices 與照片選取流程，加入重開持久化回歸測試。
- `ae8c59a` — 分離 render／history／brush display observation boundary，以一個 Canvas 繪製每個 mask，並加入 opt-in heartbeat recorder、probe 與 analyzer。
- `5530e91` — 以明確 named overlay coordinate space 修正 gesture location 重複加 image origin，加入 RED→GREEN contract。
- `2c1d1e3` — 更新 toolbar source contract，使其驗證新的 `EditorHistoryControls` 邊界與實際 undo／redo action。

主要檔案：

- `Sources/RawProcessingCore/Preview/PreviewRenderInstrumentation.swift`
- `Sources/RawProcessingCore/Preview/DecodedPreviewCache.swift`
- `Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift`
- `Sources/RawProcessingCore/Pipeline/BrushMaskRenderer.swift`
- `Scripts/fixtures/brush-baseline-release-testability.patch`
- `Scripts/analyze-brush-performance-abba.py`
- `Tests/RawProcessingCoreTests/BrushPreviewABBAHarnessTests.swift`
- `Tests/RawProcessingCoreTests/CoreImagePreviewRendererTests.swift`
- `Tests/RawProcessingCoreTests/BrushMaskScalarOracleTests.swift`
- `Tests/RawProcessingCoreTests/BrushMaskRendererTests.swift`
- `Sources/AdjustmentUI/BrushMaskOverlayView.swift`
- `Sources/AdjustmentUI/BrushUIHeartbeatRecorder.swift`
- `Sources/AdjustmentUI/BrushUIPerformanceProbe.swift`
- `Sources/EditorCore/EditorSession.swift`
- `Scripts/analyze-brush-ui-heartbeat.py`

設計保證：mask 順序、paint／erase 語意、geometry mapping、不同 mask adjustment、overlap、像素精度與 cancellation checkpoints 保持；沒有降低解析度、刪除筆刷點、跳過調整或放寬 benchmark 門檻。Cache 不跨照片、recipe 或 render context 誤用，且 full-resolution export 不共用 interactive decoded cache。

## Root cause and stage evidence

Shared B/O stage wall time（synthetic stress aggregate p50/p95，ms）：

- 1 mask：B coverage `175.096/192.717`，O `8.801/10.111`；O total materialized `11.988/13.210`。
- 10 masks：B coverage `1754.617/1814.902`，O `64.776/74.801`；O total materialized `70.664/81.013`。
- 同一批 16 筆兩輪樣本的端到端 `totalDurationSeconds` 合併 p50/p95 為 1 mask `12.084/13.337 ms`、10 masks `70.779/81.143 ms`；這包含 shared stage clock 外的 harness 邊界開銷，不等同 total materialized。
- decode、global graph 與 per-mask adjustment/blend 均是次要 stage；RAW warm 的 cache 修正則把 0／1／10 masks 降到 O `36.285/39.805`、`39.560/49.993`、`56.002/61.015 ms`。

## Verification

- Synthetic stress：64 records，validation PASS；1 mask O round 1／2=`12.105/13.244`、`12.067/13.337 ms`，10 masks=`70.907/81.143`、`70.099/71.513 ms`；`PERF-COVERAGE` 4/4 PASS；preview memory 4/4 PASS。
- RAW／export：352 records，validation PASS；warm `INTERACTIVE-150` 3/3 PASS；preview memory 9/9 PASS；original-size export 4/4 PASS；export memory 4/4 PASS。
- Pixel parity／scalar oracle：PASS，max R8 byte error 0。
- 128×128 acceptance contract：預期 RED 後 GREEN；focused Release 31 tests、0 failures。
- Analyzer unit tests：41/41 PASS；UI heartbeat analyzer 子集合 6/6 PASS。
- 50-cycle scheduler：55/55 workers finished、active after join 0、B delivered 55、A discarded 55、failed 0；settled RSS `49,168,384` bytes，limit `89,735,168` bytes。
- Full Release suite：`2c1d1e3` 驗證狀態重跑 2733 tests、22 skipped、0 failures；`LibraryViewModelTransitionTests` 13/13、`SnapshotWorkflowTests` 9/9 PASS。
- PERF-UI：B/O 各 30 次 Release 前景手勢，O 30/30 完整、0 取消；heartbeat 額外延遲 p50/p95/max=`0.227/26.152/27.835 ms`，warm preview p50/p95=`80.540/90.083 ms`。`PERF-UI-HEARTBEAT`、`PERF-UI-WARM-PREVIEW` 與總 gate 均 PASS。
- UI coordinate fix：真實 App 診斷確認 gesture start location 已在 overlay 座標，但舊程式又加一次 `imageFrame` 原點而超出 mapping；`5530e91` 修正後真實 drag 可提交，gesture／contract／recorder focused tests 29/29 PASS。
- Mac Debug 前景：`UI-MAC-01`、`UI-BRUSH-01`、`STORE-01` PASS；`UI-MAC-02`、`UI-BRUSH-02` PARTIAL。除既有 paint／erase、設定、export 外，筆刷 Delete／Undo／Redo／重開、Local off/on paste、batch sync、snapshot restore／持久化／刪除最後快照均通過。修正前 snapshot 重開消失；`5d32550` 接入 sidecar load/save 後，app-level test、Debug build 與 GUI 重開複驗通過。歷史紀錄見 [Mac UI summary](../testing/evidence/2026-10-07-brush-preview-performance-fix/mac-ui-manual-summary.txt)，follow-up 見 [Mac matrix](../testing/evidence/2026-10-08-brush-ui-followup/mac-matrix.md)。
- iPad Simulator：`UI-SIM-01` PARTIAL。iPad Pro 11-inch (M4)、iOS 18.6 fresh Debug build／install／launch、直向／橫向、Files 選取／Quick Look 後返回、真實 Split View 窄窗、建立 brush、paint、完成筆畫 Undo／Redo、exposure 0.0→0.1 與 terminate／relaunch persistence 通過；accessibility tree 可讀主要 brush controls。Files 直接交件與 app-copy／in-place、精確 0.75x／1x／2x source mapping、keyboard 與 hands-on VoiceOver 未完成。完整紀錄見 [Simulator matrix](../testing/evidence/2026-10-08-brush-ui-followup/simulator-matrix.md)。
- Artifact checksums：見 `docs/testing/evidence/2026-10-07-brush-preview-performance-fix/README.md`。

## Independent review

程式／spec 的 agy → Gemini 3.1 Pro High sanitized read-only review 為 `APPROVED_WITH_CONCERNS`，無 blocking finding。唯一 minor 是 spec 指定第一版固定 128×128 tile，但審查當時實作為 256×256；`7af2125` 已修正並重跑 parity、synthetic stress、RSS、cancellation、RAW/export 與 full Release gates，全數 PASS。完整紀錄見 [程式／spec Gemini review](../testing/reports/2026-10-08-brush-preview-performance-fix-gemini-review.md)。

Mac 文件差異的 Gemini 初審為 `CHANGES_REQUESTED`：`CURRENT.md` 引用兩輪合併的端到端 p50/p95，卻沒有在證據與報告中說明它不同於 stage total。本輪已從 `synthetic-stress-samples.jsonl` 重算並補上兩組數據的來源與邊界；同一模型 follow-up verdict=`APPROVED`、無 finding，並確認沒有 overclaim 或隱私洩漏。完整紀錄見 [Mac 文件 Gemini review](../testing/reports/2026-10-08-brush-preview-performance-fix-mac-ui-gemini-review.md)。

## Remaining bounded action

產品、自動效能驗收、兩輪獨立唯讀 review、可執行的 Mac follow-up、PERF-UI 與 iPad Simulator slice 已收尾。實體 iPad／iPhone 仍 offline；沒有合格灰卡／ROI reference。下一個 bounded action 是在裝置／受控素材到位後補實體 iPad／Pencil／鍵盤／VoiceOver／旋轉／Split View、四色滴管與灰卡矩陣。中途手勢人工案例需能同時維持 pointer-down 與觸發第二動作的輸入通道。必要 gate 未完成前維持 Draft；本輪 commit 尚未 push。不要修改門檻或 benchmark。未經使用者另行授權，不 merge、rebase、刪除 branch/worktree 或修改其他 worktree。

## 2026-10-08 實作方向補充

使用者要求先寫實作方向。已新增[文件同步、操作驗收與 Alpha 整合計畫](../superpowers/plans/2026-10-08-brush-alpha-integration-followup.md)，取代上節剩餘工作的執行順序；不取代既有驗收門檻或測試結果。起始 HEAD=`f365f88d3ba22df329886651dd5573c35a3b5416`，本次僅 plan／coordination 變更。下一步為 Task 1 更新根目錄 README（目前仍寫 v4，候選程式為 v5），再補 Simulator／Mac 子項。是否採用 Alpha 例外合併在具體結果齊備後決定，目前沒有授權 merge main。
