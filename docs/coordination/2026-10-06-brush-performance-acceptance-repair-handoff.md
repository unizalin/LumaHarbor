# Brush performance and acceptance repair handoff

日期：2026-10-06
作者：Codex
分支：`codex/brush-performance-acceptance-repair`
基準：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`
實作 commit：`26c3390`

## 已完成

- `BrushMaskRenderer` 使用 bounded 128×128 tile coverage，維持原 stroke/sample/paint/erase 順序與 row-flip/R8 行為。
- validation、sampling、tile/stamp rasterization 與 R8 conversion 都有可注入 cancellation check；取消會拋 `CancellationError`。
- 新增 `applyValidatedAsync`：獨立 mask coverage 可平行，composite 仍依原 mask 順序；單 mask 直接路徑。
- preview／export 改用 async renderer；`runOffActor` 補 async overload。
- 同一 working/output color-space recipe 重用 `ImageRenderService`，不同 output transform 保持隔離。
- 新增 deterministic performance harness、scalar oracle、cancellation tests、async materialization integration test 與 Release script。

## 驗證

- Full suite：2,696 executed、18 skipped、0 failures。
- Strict build：`swift build --scratch-path "$TASK_SWIFT_SCRATCH" -Xswiftc -strict-concurrency=complete` exit 0；只見既有 strict warnings。
- Release synthetic：16 samples、0／1／10 masks；coverage p50 0.002／11.058／19.964 ms，p95 0.004／11.202／21.321 ms；end-to-end p50 2.274／13.635／25.561 ms，p95 2.431／13.815／26.417 ms。
- Scalar oracle：最大 R8 byte 差 0；sync／async composite byte-identical。
- `git diff --check`：PASS。

## 變更路徑

- `Sources/RawProcessingCore/Pipeline/BrushMaskRenderer.swift`
- `Sources/RawProcessingCore/Pipeline/CancellableWork.swift`
- `Sources/RawProcessingCore/Pipeline/ImageRenderService.swift`
- `Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift`
- `Sources/RawProcessingCore/Export/PhotoExporter.swift`
- `Tests/RawProcessingCoreTests/BrushMaskPerformanceTests.swift`
- `Tests/RawProcessingCoreTests/BrushMaskCancellationTests.swift`
- `Tests/RawProcessingCoreTests/BrushMaskScalarOracleTests.swift`
- `Tests/LumaHarborIntegrationTests/BrushMaskPerformanceAcceptanceTests.swift`
- `Scripts/run-brush-performance-acceptance.sh`
- `docs/testing/reports/2026-10-06-brush-performance-and-acceptance-repair.md`

## 尚待處理

- 沒有 candidate B/O ABBA 配對資料，不能宣稱 regression delta 或 export improvement。
- 原尺寸 6000×4000 export、peak RSS、50 次取消／切圖 settled RSS 尚未執行。
- Mac／實體 iPad／Pencil／鍵盤／VoiceOver、灰卡 D65 Lab／ΔE00 與獨立 reviewer 尚未執行。
- rendererVersion 1 的 persisted density／pressure 可見 opacity 語意維持原 concern，未在本輪改寫。
- 不要把 synthetic O PASS 解讀成整合 READY；正式狀態是 `DONE_WITH_CONCERNS`。

## 下一個 bounded action

在同一參考機器以 candidate SHA 與本 branch O 各完成 Release ABBA workload，再補一／十 mask 原尺寸 export、peak RSS 與取消後 worker 結束證據；結果回寫 report 與 `CURRENT.md`。在此之前不要 push、merge、rebase，也不要修改來源 worktree。
