# P5: Advanced Masks, AI Repair, and Perspective Implementation Plan

- 狀態：實作中（TDD）
- 日期：2026-09-11
- 前置條件：P0-P4 通過

## 任務細項與執行順序

### Task 1: 模型與測試先行 (TDD)
1. 撰寫 `Tests/RawProcessingCoreTests/AdvancedMasksModelTests.swift`：
   - 測試 `LocalAdjustmentKind` 的新 case 解碼與編碼
   - 測試 `LocalAdjustment` 的 `name`、`opacity`、`isInverted` 預設值與相容性解碼
   - 測試 `LocalAdjustmentGeometry` 的 `BrushStroke`、Range、AI mask metadata 序列化與 clamps
   - 測試 `GeometryAdjustments` 的 `cornerPins` 四角透視
2. 修改 `Sources/RawProcessingCore/Model/LocalAdjustment.swift`：
   - 擴充 `LocalAdjustmentKind`、`LocalAdjustment`、`LocalAdjustmentGeometry`、`SpotHealMode`
   - 新增 `BrushStroke`、`BrushPoint` 等輔助型別
3. 修改 `Sources/RawProcessingCore/Model/GeometryAdjustments.swift`：
   - 新增 `PerspectiveCornerPins`、`NormalizedPoint`
   - 更新 `isIdentity` 與 `resettingPerspective()`

### Task 2: 渲染器與 Vision Segmentation (TDD)
1. 撰寫 `Tests/RawProcessingCoreTests/AdvancedMasksRenderTests.swift`：
   - 測試 Radial Gradient 遮罩生成與渲染
   - 測試 Brush 遮罩合成與渲染
   - 測試 Luminance Range 與 Color Range 遮罩
   - 測試 Subject / Background 離線 fallback 與 Inversion
   - 測試 Spot Heal 的 Red-Eye 處理
   - 測試 `GeometryRenderer` 的四角透視轉換
2. 建立 `Sources/RawProcessingCore/Vision/VisionSegmentationService.swift`：
   - 支援離線與安全 fallback 的主體分割遮罩服務
3. 修改 `Sources/RawProcessingCore/Pipeline/LocalAdjustmentRenderer.swift`：
   - 實作所有新遮罩的 mask 生成、inversion、opacity 合成
   - 實作 Red-Eye 去除
4. 修改 `Sources/RawProcessingCore/Pipeline/GeometryRenderer.swift`：
   - 實作 `cornerPins` 的 `CIPerspectiveTransform` 校正

### Task 3: UI 與 iPad 面板補齊 (TDD)
1. 撰寫 `Tests/AdjustmentUITests/AdvancedMasksUIContractTests.swift` 與補強 `PadCatalogWiringContractTests.swift`。
2. 更新 `Sources/AdjustmentUI/LocalAdjustmentsPanel.swift`：
   - 提供新增各類型遮罩的按鈕與面板
   - 支援遮罩命名、反轉、不透明度、刪除、複製
   - 支援 Red-Eye 移除選項
3. 更新 `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift`（及獨立的 `PadInspectorHost.swift`）：
   - 掛載 P4 的 `RenderingProfilePanel`、`PresenceAdjustmentPanel` 與 `ColorGradingAdjustmentPanel`
4. 更新 8 國語言 `Localizable.strings`：
   - 補充所有新遮罩與透視鍵值，通過 parity 與 fallback 檢查

### Task 4: 完整驗證
- 執行 `swift test` 全套測試
- 執行 strict concurrency build
- 執行 iPad Simulator build
- 執行 privacy 檢查
- 提交 P5 phase commit 並更新 `CURRENT.md` 與 handoff
