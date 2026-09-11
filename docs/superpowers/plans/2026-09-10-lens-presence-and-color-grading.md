# P4 Implementation Plan：Lens、Presence、Color Grading、B&W、Rendering Profile

- 依據：`docs/superpowers/specs/2026-09-10-lens-presence-and-color-grading.md`、`docs/coordination/DECISIONS.md` D-007。
- 提交邊界：整個 P4 一個實作 commit + 一個交接文件 commit。

## 逐步順序（先測試後實作）

1. **Models**（一次寫完 5 個 struct,每個都有自己的測試檔）：`PresenceAdjustments`、`ColorGradeBand`+`ColorGradingAdjustments`、`MonochromeAdjustments`、`RenderingProfileSelection`+`RenderingProfileCatalog`、`LensCorrectionMode`+`LensCorrectionAdjustments`。全部加入 `PhotoAdjustments`（欄位、init、CodingKeys、encode、decode、`isNeutral`/`modifiedKinds` 若適用)。
2. **RenderParameters／AdjustmentMapping**：把 5 個新 struct 接進 `RenderParameters`,新增對應 `isXIdentity`。
3. **Render — Presence**：`applyPresence`（texture/clarity/dehaze),接入 perceptual 階段。
4. **Render — Color Grading**：把 `applySplitToning` 的 `flatColor` 抽成 shared private helper,新增 `applyColorGrading`（3-zone + global + balance/blending)。
5. **Render — Monochrome**：新 Metal kernel `monochromeMixer`（重用 hslAdjust 的 8-band falloff),`AdjustmentPipeline.applyMonochrome`。
6. **Render — Rendering Profile**：`RenderingProfileCatalog` 四個內建 profile,`applyRenderingProfile`（用既有 colorControls/toneCurve 語意插值)。
7. **Render — Lens Correction**：
   - `RawDecodeRequest` 新增 `lensCorrection: LensCorrectionAdjustments` 欄位;`CoreImageRawDecoder.decode` 新增 automatic 分支。
   - `AdjustmentPipeline.apply` 最前面新增 `applyLensCorrection`（distortion/vignetting/TCA,只在 manual/bundledProfile 模式執行)。
   - `LensProfileDatabase`（空資料庫,`match(...)` 永遠回傳 nil,附測試證明介面正確可用、之後塞真實資料不需要改邏輯)。
8. **Preset/XMP**：`AdjustmentFieldID` 新增欄位、`AdjustmentPatch` 新增 5 個 nested patch、`XMPMappingRegistry` 新增 Texture/Clarity2012/Dehaze 三個原生 mapping,其餘新欄位不加 mapping（走既有 preserved 路徑,新增回歸測試證明不遺失)。
9. **UI**：`InspectorCatalog` 新增 `presence`、`colorGrading` 兩個 section;`PresenceAdjustmentPanel`、`ColorGradingAdjustmentPanel`（新檔,比照 `EffectsAdjustmentPanel`／`ColorAdjustmentPanel` 慣例);既有 `ColorAdjustmentPanel`／`GeometryAdjustmentPanel`／`BasicAdjustmentPanel` 分別掛載 Monochrome／Lens Correction／Rendering Profile 控制項。8 語 `Localizable.strings` 新增字串。

## 驗證指令

同 P3（`swift test` 全套、strict-concurrency build、iPad Simulator xcodebuild、`git diff --check`、privacy scan)。

## Rollback

單一實作 commit;回退即完整回到 P3 baseline。

## Handoff

完成後寫 `docs/coordination/2026-09-10-p4-lens-presence-color-grading-handoff.md`,更新 `CURRENT.md`,下一步指向 P5。
