# Brush performance and acceptance repair handoff

## 2026-10-06 追補交接（目前有效）

- **狀態與 owner**：Codex 延續 `codex/brush-performance-acceptance-repair`，本次只寫文件，產品仍為 `DONE_WITH_CONCERNS`。開始時工作樹乾淨；未修改其他來源工作樹或 push／merge／rebase。
- **基準**：B=`1de07dcfeb2ed217a75d1c04978da6a5936f379a`；產品 U=`26c3390ba59e0e2ae416618d6e832a5c0eeba98d`；撰寫前 HEAD=`37d1580b4a1924fce58d688ff668ba6b536d3868`，U 至 HEAD 僅文件差異。後續文件 commit 不改變產品 SHA。
- **本次變更**：新增[追補 spec](../superpowers/specs/2026-10-06-brush-raster-correctness-and-verification-followup-spec.md)，更新原 spec、report、本 handoff 與 CURRENT。這五份文件構成本輪全部變更；以文件提交後的 `git status --short` 核對 dirty state。
- **修正證據解讀**：跨垂直 tile 的全圖 row mapping 有讀碼確認的缺陷，RED 像素測試尚未執行；oracle 只有水平跨 tile／blend bytes，並未直接證明 R8 相同；取消測試只是注入錯誤。原始 Release integration 編譯 FAIL，`-DDEBUG` 結果不能覆蓋它。RAW 141～148 ms 是空筆刷 production preview，不能代表一／十 mask。
- **驗證邊界**：前次 full Debug 2,696／18／0、focused 186／2／0、RAW 10／1／0 與 build／封裝結果保留為歷史證據；本次只核對文件、連結與 diff，沒有重跑產品 gate。正式 B/O、export／RSS、真實取消、操作／灰卡與獨立 review 仍未完成。
- **唯一下一步**：依追補 F1，在 height=240／257 的非對稱 coverage 測試先重現 U 的像素失敗，再修正全圖列位置；之後依序處理 Release、真實取消與效能。不要直接從正式 B/O 開始。

以下為首次交付快照；其中 row flip／R8／取消與下一步的結論由以上更正取代，歷史樣本保留。

## 首次交付快照

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
