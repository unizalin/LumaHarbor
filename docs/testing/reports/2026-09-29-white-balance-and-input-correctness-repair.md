# 白平衡與數值輸入正確性修正驗證報告

## 歷史結論更正（2026-09-30）

以下保留第一輪原始紀錄，不代表當前版本已驗收。獨立審查及第二輪 RED 測試反證了部分完成宣稱：原生輸入仍有無效文字不回復、精確值被捨入及取消後再提交問題；滴管舊候選會覆寫外部編輯；Temperature 新提交缺少最後限幅；非法 baseline 被當成有效能力。第二輪已修正並補上對應證據，詳見[第二輪報告](2026-09-29-white-balance-and-input-review-followup.md)。

本報告的 WB-04、WB-05、WB-08、INPUT-05、EYE-01／02／05 與 REG-02 未涵蓋各自全部 UI／整合條件，不能讀成整項 PASS；原 EYE-03 只驗 histogram 非空，不足以證明完整內容還原。新版矩陣以實際執行的原生事件、像素、完整 histogram bins、儲存重開與受控晚到回應重新判定；不把第二輪證據倒填成第一輪當時已驗證。

## 第一輪原始紀錄

- 日期：2026-09-29
- 工作樹分支：`codex/open-source-release-prep`
- 基準 HEAD：`8b8afa4ba2deb9a275234591f6493cb44ef047a0`
- 驗證對象：上述 HEAD 加上本工作樹既有 dirty／untracked 變更，以及本輪修正
- signing：保留 `Apps/LumaHarborPad.xcodeproj/project.pbxproj` 既有本機變更，未修改
- Git：未 commit、未 push、未 merge

## A～F 執行摘要

### A：失敗回歸測試

先加入並確認紅燈，再修改 production code。重現測試涵蓋：F1 越界 stored offset、F2 Tint 方向、F3 精確輸入與越界草稿、F4 無效取樣 release 後提示保留、F5 中性重取樣後影像／histogram 還原；另加入舊 sidecar 越界色溫保留與 decoder 最後防線測試。

### B：共用白平衡解析與資料相容性

- 新增 `WhiteBalancePresentation.resolve` 與 `storedOffsetIfResolvable`，以實際 RAW baseline 計算可用 stored offset 交集。
- UI、preset、preview/export decoder 共用 2,000…50,000 K 與 ±1,200 stored-unit 邊界。
- `CoreImageRawDecoder.resolvedWhiteBalance` 在 native filter assignment 前再次驗證，拒絕非法 baseline／offset。
- 有限越界舊 sidecar 在載入與非白平衡編輯時保留原始值；render／decoder 才以實際 baseline 安全限幅，讀取不 autosave、不改 sidecar bytes。
- Basic inspector 顯示舊白平衡被限幅的診斷；八語系補上範圍與 baseline 訊息。

### C：滴管方向

修正 green-to-neutral Tint 符號，使偏綠產生正 Tint、偏洋紅產生負 Tint；保留既有 stored Tint 與 native decoder 映射。受控 RGB 方向與有限／裁切／過暗拒絕測試通過。

### D：滴管生命週期與 render race

無效 sample 會清除可提交候選但保留原因；release 無候選不會清除原因或誤提交。有效 no-op 會恢復實際影像；可控 renderer 測試確認 warm → neutral 後 CGImage 像素、histogram 與 committed adjustments 一致，且不新增 Undo。

### E：數值欄位

- 新增 `parseExact`，編輯時不由顯示小數位量化有效值。
- 無效值回復權威模型值並提供可存取錯誤文字；外部 slider／reset／Undo 更新會取代 stale draft，不再由失焦覆寫新值。
- iPad 44 pt nudge／reset hit target 與 macOS accessibility adjustable action 保留。

### F：跨平台與回歸

- focused 修正套件：152 項通過（包含 WhiteBalancePresentation 10、WhiteBalanceEyedropper 16、RawDecoding 21、PhotoAdjustments 21、PresetApplicator 14、AdjustmentValueInput 10、EditorSessionEditing 37、EyedropperRendering 1、SidecarRepository 22）。
- `swift test`：1975 executed、9 skipped、1 failure；唯一 failure 是既有 `AppIconAssetContractTests.testIPadProjectDoesNotContainPersonalBundleIdentifier`（期待 0、實際 2，來自未動的 signing project 設定）。
- `swift build -Xswiftc -strict-concurrency=complete`：PASS。
- 真實 Sony RAW fixture suite：9/9 PASS；包含 white-balance render、export、原檔 fingerprint／mtime 不變。
- iPad generic device build：PASS；iPad generic Simulator build：PASS；均使用 `CODE_SIGNING_ALLOWED=NO`。

## 26 項驗收矩陣

狀態只使用 `PASS`、`FAIL`、`SKIPPED`、`NOT RUN`；括號是證據界線，不把未執行的手動／感知驗收冒充自動化通過。

| ID | 結果 | 方法與證據 |
| --- | --- | --- |
| WB-01 | PASS | `WhiteBalancePresentationTests` 覆蓋 2,000、4,536.72802734375、5,500、10,000、50,000 baseline 與 stored endpoints；結果有限且落在合法 Kelvin。 |
| WB-02 | PASS | `RawDecodingTests.testDecoderResolvesTheF1OffsetAgainstItsActualBaseline` 重播 F1 offset；decoder helper 與 resolver 均回到 2,000 K 邊界，RAW suite 另確認 WB offset 會改變實際 render。 |
| WB-03 | PASS | Kelvin／offset round-trip、mired slider、`parseExact` 精度與 decoder offset boundary 測試通過。 |
| WB-04 | PASS | invalid baseline、non-finite decoder request、缺 baseline／invalid baseline preset 均拒絕或保留原值並回報診斷。 |
| WB-05 | PASS（核心） | decoder 最後防線與 2,000／50,000 核心端點解析通過；真實 RAW 端點逐一量測未另行執行。 |
| WB-06 | PASS | `PhotoAdjustmentsTests` 與 `SidecarRepositoryTests.testLegacyOutOfRangeTemperatureLoadsWithoutRewritingTheSidecar` 確認有限越界舊值保留、載入不改 bytes。 |
| WB-07 | NOT RUN | 尚未用真實 sidecar、session、Undo／Redo、重開流程重播越界舊檔完整生命週期。 |
| WB-08 | PASS（核心） | `PresetApplicatorTests` 覆蓋 native／absolute、合法／越界／缺 baseline／invalid baseline；preset preview／commit 手動流程未另行重播。 |
| TINT-01 | PASS | `WhiteBalanceEyedropperTests` 覆蓋偏綠正 delta、偏洋紅負 delta、中性零 delta。 |
| TINT-02 | NOT RUN | 尚未取得固定 RAW ROI／灰卡並量測規格 E 指標與逐案例改善；RAW suite 只證明方向與 render 有效。 |
| TINT-03 | PASS | 既有 stored Tint、AdjustmentMapping、preset 與 reset 測試通過；本輪只改滴管估計符號。 |
| INPUT-01 | NOT RUN | 尚無宿主 TextField 自動化重播 6500→60000→Enter→移焦點的 UI evidence。 |
| INPUT-02 | NOT RUN | pure parser 覆蓋空字串、文字、越界與非有限拒絕；真實 Enter／blur UI 尚未執行。 |
| INPUT-03 | NOT RUN | `parseExact` 與 source contract 通過；真實 Enter 再 blur、Escape 零提交尚未執行。 |
| INPUT-04 | NOT RUN | source contract 覆蓋外部更新取代 draft；reset／Undo／Redo／換照片期間的真實宿主 UI 尚未執行。 |
| INPUT-05 | PASS（contract） | macOS accessibility adjustable action、iPad nudge/reset 44 pt metrics、錯誤 accessibility contract 通過；實機觸控操作未執行。 |
| EYE-01 | PASS（session） | tooDark reject→release、無候選不清除原因，以及 core clipped／outOfRange／nonFinite issue tests 通過；真實 UI gesture release 未執行。 |
| EYE-02 | PASS（session） | `testInvalidSampleAfterAValidPreviewCannotBeReleasedAsTheOldCandidate` 確認有效→無效→release 不提交舊候選，下一次有效取樣清除錯誤。 |
| EYE-03 | PASS | `EditorSessionEyedropperRenderingTests` 以可控 renderer 驗證 warm→neutral 後 CGImage red channel、histogram、displayed adjustments 與 Undo。 |
| EYE-04 | NOT RUN | 尚未建立可控延遲 renderer，重播舊 render 晚於 neutral／cancel／換照片完成的完整矩陣。 |
| EYE-05 | PASS（session） | eyedropper preview 不 dirty、不寫 sidecar；有效 commit 一筆 Undo，neutral no-op 零 Undo；重開完整流程未另行執行。 |
| EYE-06 | NOT RUN | 尚未用來源 frame 更新、移出圖片、無像素與 preview failure 的 UI／可控排程矩陣重播。 |
| PARITY-01 | NOT RUN | preview／export 已共用 decoder resolver，但尚未量測相同 recipe 的實際 preview/export 像素與容差。 |
| PARITY-02 | NOT RUN | macOS／iPad Simulator／實體 iPad 的主要輸入與滴管操作尚未手動重播；兩種 iPad generic build 已 PASS。 |
| REG-01 | FAIL（既有環境差異） | 完整 suite 1975/9 skipped/1 known signing failure；strict build、RAW suite、iOS device／Simulator builds PASS，無新增 failure。 |
| REG-02 | PASS（完整性）／NOT RUN（手動） | RAW fixture export 測試確認來源 fingerprint／mtime 不變；Solo／Geometry／filmstrip／曝光的手動代表性回歸尚未執行。 |

## 已知限制與後續

本輪不能標示「本規格完整驗收通過」：WB-07、TINT-02、INPUT-01～04 的真實 UI／感知量測、EYE-04／06、PARITY-01／02 與部分手動回歸仍是 `NOT RUN`。完整 `swift test` 的 signing contract 失敗保留原樣，未以修改 project signing 方式消除。

## 第二輪交叉核對

2026-09-30 依第二輪規格重新實作 RF-01～06，並另建[第二輪修正驗證報告](2026-09-29-white-balance-and-input-review-followup.md)。本報告保留第一輪當時的歷史結果；第二輪的 focused／完整 suite 數字、26 項狀態與真實 TextField 證據以新報告為準，不把本報告的 152 項 focused 或任何 `PASS（核心）` 解讀成第二輪完整驗收通過。
