# Camera Profile Fallback Task 7

日期：2026-09-19

## 已完成

- 建立 `CameraProfileFallback` 純值格式：版本、camera match、source profile、3×3 matrix、三條單調 LUT、provenance。
- 加入係數 validation：有限值、9 個 matrix 係數、LUT 端點 0/1、單調性、版本與 provenance。
- 加入 deterministic least-squares calibrator：training 與 hold-out ID 必須不重疊；fit 只使用 training；hold-out RMSE 必須優於 identity baseline。
- 加入 `CameraProfileRenderer`：matrix 後套用 per-channel LUT；identity fallback 為 passthrough；profile stage 位於 decode／As Shot WB 後、Exposure／Basic tone 前。
- preview 與 export 都使用 decoder 回傳的同一份 resolved recipe。
- 新增 `LumaHarborProfileCalibrate` developer-only executable；輸入由環境變數指定，輸出只含 sanitized coefficients、穩定 profile ID、camera match、provenance 與 aggregate metrics。
- known camera／profile 在 generated coefficients 缺席時明確維持 `preservedNotApplied`；unknown camera 不會進 renderer。

## 驗證

- `CameraProfileRendererTests`：5/5 PASS。
- `CameraProfileCalibrationTests`：3/3 PASS。
- `ProfileCalibrationCommandContractTests`：2/2 PASS。
- `RawRenderRecipeResolverTests`：5/5 PASS。
- Task 7 focused 合計：15/15 PASS。
- RawProcessingCore 全套：608 executed、1 skipped、0 failures。
- `swift build -Xswiftc -strict-concurrency=complete`：PASS。
- `swift run LumaHarborProfileCalibrate --help`：PASS。
- `git diff --check`：PASS。

## 尚未宣稱的部分

本輪沒有合法的 Lightroom paired reference hold-out 與可散布 provenance，因此 `Sources/RawProcessingCore/Profile/Generated/AdobeCompatibleProfileFallbacksV1.swift` 維持空 registry。這表示目前仍是「可校正、可驗證的 fallback plumbing」，不是 Adobe Color／Adobe Standard 的視覺等價實作。完整 `swift test` 在既有跨平台 contract suite 執行期間被 xctest signal 11 中止；沒有以此宣稱 full suite 通過。

下一步是使用去識別的 Lightroom／LumaHarbor paired samples 執行 CLI；只有 hold-out 有改善、training 與 hold-out ID 分離、係數可散布且不需要 per-photo branch，才把結果寫入 generated registry。
