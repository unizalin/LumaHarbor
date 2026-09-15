# P3 Implementation Plan：Per-channel Tone Curves

- 依據：`docs/superpowers/specs/2026-09-10-per-channel-tone-curves.md`
- 前置：P0（完成）。實際分支歷史上在 P2 之後執行。
- 提交邊界：整個 P3 一個實作 commit + 一個交接文件 commit（比照 P0/P1/P2）。

## 逐檔變更順序（先測試後實作，每一步先確認新測試 RED）

1. **`Sources/RawProcessingCore/Model/AdvancedToneCurve.swift`**
   - 新增 `redPoints/greenPoints/bluePoints`（各自 `didSet` sanitise，比照 `points`）。
   - 新增 `ToneCurveChannel` enum。
   - 新增 `points(for:)`／`isIdentity(for:)`／`settingPoints(_:for:)`／`resetting(_:)`。
   - `isIdentity` 改為四條皆空。
   - `CodingKeys` 加三個新 key；`init(from:)` 對新 key 用 `decodeIfPresent ?? []`；`encode` 全部 encode。
   - 測試檔：`Tests/RawProcessingCoreTests/AdvancedToneCurveTests.swift` 先寫新案例（RED），再改實作（GREEN）。

2. **`Sources/RawProcessingCore/Pipeline/AdvancedToneCurveLUT.swift`**
   - 新增 `buildCombined(compositePoints:channelPoints:resolution:)`。
   - 測試檔：`Tests/RawProcessingCoreTests/AdvancedToneCurveLUTTests.swift` 先寫 5 個新案例。

3. **`Sources/RawProcessingCore/Kernels/AdjustmentKernels.metal`**
   - `advancedToneCurve` 的三個 `lut.sample(...).r` 改成 `.r/.g/.b`。
   - 無法直接單元測試（沿用既有「手動驗證＋pipeline golden pixel」策略,見檔案頂部既有註解慣例）。

4. **`Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift`**
   - `makeLUTImage` 簽名改為 `(red: [Float], green: [Float], blue: [Float])`。
   - `applyAdvancedToneCurve` 改為呼叫三次 `buildCombined`（R/G/B 各自對 `curve.points` + 對應 channel points）,打包成一張 RGBA8 image。
   - 測試檔：`Tests/RawProcessingCoreTests/AdjustmentPipelineTests.swift` 新增 §3.3 的三個 golden-pixel 案例（先 RED，確認目前實作在 redPoints-only 案例下輸出全通道一致地改變,證明目前是 bug,再修正到 GREEN）。

5. **`Sources/PresetCore/XMP/XMPImportExport.swift`**
   - `importToneCurve` 保留（composite 用),新增功能：四個 property ID 迴圈時各自呼叫,並用 `settingPoints` 疊加到 `builder.advancedToneCurve`。
   - `exportToneCurve` 保留（composite 用),新增 red/green/blue 各自「非 identity 才輸出」的路徑。
   - 測試檔：`Tests/PresetCoreTests/XMPImportExportTests.swift`、`Tests/PresetCoreTests/XMPMappingTests.swift`、新 fixture（如需要,新增一個含 `ToneCurvePV2012Red/Green/Blue` 的 `.xmp` fixture 到 `Tests/PresetCoreTests/Fixtures/XMP/`）。

6. **`Sources/PresetCore/Model/PresetDocument.swift`**
   - `currentSchemaVersion` 改為 `2`。
   - 測試檔：新增或擴充既有 schema version 測試,確認 v1 fixture 仍可 `validated()`。

7. **`Sources/AdjustmentUI/CurveAdjustmentPanel.swift`**
   - 移除私有 `ToneCurveChannel`,改用 `RawProcessingCore.ToneCurveChannel`（`.rgb` → `.composite`)。
   - `ToneCurveEditorModel.points(for:)` 加 `channel` 參數。
   - `onChange` 寫入改用 `settingPoints`。
   - Reset 按鈕拆成 "Reset Channel" / "Reset All"。
   - `statusText` 改逐 channel。
   - 測試檔：`Tests/AdjustmentUITests/ToneCurveEditorModelTests.swift` 加 channel 參數案例；新增或擴充 contract 測試驗證兩顆按鈕與 disabled 條件（source-contract 風格,比照既有 `PadCatalogWiringContractTests`）。

8. **8 語 `Localizable.strings`**
   - 新增 `"Reset Channel"`、`"Reset All"` 兩個 key,en/zh-Hant 手寫,其餘 6 語真實翻譯。
   - 測試：既有 `LocalizationKeyParityContractTests` 應自動涵蓋（若該測試檔是逐 key 列舉、非動態掃描,需要新增對應案例)。

## 驗證指令（每步之後跑對應 filter,最後跑全套）

```
swift test --filter 'AdvancedToneCurveTests|AdvancedToneCurveLUTTests|AdjustmentPipelineTests|XMPMappingTests|XMPImportExportTests|AdjustmentPatchTests|AdjustmentPatchExtractionTests|ToneCurveEditorModelTests|LocalizationKeyParityContractTests'
swift test
swift build -Xswiftc -strict-concurrency=complete
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
git diff --check
rg -n 'TBD|TODO|FIXME|fatalError|try!' <每個變更的 production .swift 檔>
privacy scan（git diff 掃 /Users/…、/Volumes/…、DEVELOPMENT_TEAM=、UUID、私鑰 header）
```

## Rollback

單一實作 commit;回退即完整回到 P2 baseline（見 spec §8）。

## Handoff

完成後寫 `docs/coordination/2026-09-10-p3-per-channel-tone-curves-handoff.md`,更新 `docs/coordination/CURRENT.md`,下一步指向 P4。
