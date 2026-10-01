# Lightroom Classic 調整功能對照稽核

日期：2026-09-29
範圍：LumaHarbor 目前已提供的 Develop／調整面板功能。
基準：Adobe 官方 Lightroom Classic Develop 文件；本稽核比較控制項語意、方向、渲染接線與資料往返，不宣稱逐像素複製 Lightroom。

## 結果摘要

| 功能 | 程式鏈路 | 狀態 | 說明 |
|---|---|---|---|
| Exposure | model → mapping → Core Image → UI | PASS | EV 線性曝光，正負方向與中性 identity 有測試。 |
| Temperature | model → baseline → RAW decoder → Kelvin UI | FIXED／需 RAW 校色 | 內部仍是 baseline-relative offset；UI 改為 2,000–50,000 K，滑桿使用 mired 方向。 |
| Tint | model → RAW decoder → UI | PASS／需 RAW 校色 | 仍使用相對 tint；滴管方向測試已存在。 |
| Contrast | model → `CIColorControls` → UI | PASS | 灰階陰影／高光方向與 identity 有測試；尚未做 Lightroom RAW fixture 容差校正。 |
| Highlights / Shadows / Whites / Blacks | model → tone curve → UI | PASS | 端點、單調性與交互作用有 pipeline 測試。 |
| Vibrance / Saturation | model → Core Image → UI | PASS | Saturation 完全去飽和、正向擴張已有測試；膚色保護尚未以實拍 fixture 驗證。 |
| Tone Curve | model → monotonic points/LUT → pipeline | PASS | 大於 LUT 尺寸的影像有 ROI regression test。 |
| HSL / Color Mixer | model → Metal HSL kernel → UI | PASS／需色域校正 | 八色 band 的方向、選擇性與灰色保護已有測試。 |
| Split Toning | model → luminance mask → pipeline | PASS／功能範圍較小 | Shadow／Highlight 方向已測；Lightroom 的 Midtones、Blending、Color Grading 三向輪盤尚未提供。 |
| Sharpening | model → luminance + unsharp + edge mask → UI | FIXED／近似 | `detail` 與 `masking` 不再被忽略；Core Image 不是 Lightroom 的頻率分離演算法，需實拍細節校色。 |
| Noise Reduction | model → luminance pass + color pass → UI | FIXED／近似 | 不再把四個欄位平均成一個 pass；Core Image 仍沒有 Lightroom 的獨立 chroma/luma 引擎。 |
| Vignette | model → radial mask → UI | PASS／需視覺校色 | 正負方向、feather 與 roundness 有合成測試。 |
| Grain | model → random/blur/soft-light → UI | PASS／需解析度校色 | amount/size/roughness 會改變輸出；preview/export 尺度有測試。 |
| Geometry | model → rotate/flip/straighten/perspective/crop | PASS | 旋轉後裁切與輸出尺寸契約已有 renderer 測試。 |
| Local linear gradient | model → mask → mini patch → UI | PASS／近似 | Exposure、tone、saturation、temperature、tint 可局部套用；沒有 Lightroom Brush/Radial/Range Mask。 |
| Local spot heal | model → translated patch → feather mask | PASS／近似 | Heal／Clone 模式有 deterministic fallback；不是 AI content-aware fill。 |
| Preset / XMP | model → sparse patch → import/export | PASS／需 Kelvin fixture | 相對 sidecar 與 Adobe absolute Kelvin 轉換鏈路已保留；真實 XMP/RAW baseline 尚未完成校色。 |
| Reset / Undo / Batch | history → gesture → sync | PASS | 既有測試涵蓋 reset、compound undo 與批次手勢；temperature 新 binding 使用同一手勢邊界。 |

## 本輪已調整

1. RAW Temperature 不再顯示一般 `±100` 數值；改以 absolute Kelvin value input 與 cool→warm 的 mired slider 呈現，sidecar 仍保存相對 offset，避免破壞舊檔。
2. 將 RAW temperature 的儲存範圍擴大至 `±1200` stored units（每單位 45 K），讓不同相機 baseline 仍能涵蓋 2,000–50,000 K。
3. Sharpening 的 `detail` 透過 unsharp-mask pass 生效，`masking` 透過 edge-derived mask 生效。
4. Noise Reduction 不再把 luminance/color amount/detail 平均；兩組控制各自形成一個 pass。
5. 新增失敗優先的 pipeline regression tests，固定驗證上述欄位確實改變影像。
6. macOS 數值輸入移除常駐加減按鈕，改由鍵盤與 VoiceOver adjustable action 操作；iPad 保留觸控用 44pt nudge buttons。
7. 數值文字輸入超出欄位範圍時拒絕提交並保留原值，不再靜默夾到邊界。
8. Inspector 新增 workspace-scoped Solo Mode 與群組釘選；Geometry 改為直接區塊，首次進入時 Crop／Straighten 展開。
9. 滴管改用集中式 Kelvin／Tint mapping 與 AdjustmentCatalog 邊界；極暗、裁切、非有限或超出範圍的取樣會拒絕預覽並顯示原因。

## 尚未完成的人工 gate

- 使用同一組 Sony ARW／灰卡／色卡，在 Lightroom Classic 與 LumaHarbor 逐張比較 Kelvin、Tint、tone endpoints、HSL、sharpen、noise、geometry、local、preset round-trip 與 export。
- 量測不同 RAW baseline 下 absolute Kelvin 的誤差與 eyedropper 收斂速度。
- 對不支援的 Lightroom 功能（Brush、Radial、Range Mask、AI Subject/Sky/People、Midtones Color Grading）維持明確的 unsupported 狀態，不以無作用滑桿冒充。

本輪環境檢查確認已安裝 Lightroom Classic，但它目前連到使用者既有 catalog；為避免未經確認地寫入個人 catalog，本輪沒有匯入測試 RAW、建立 XMP 或執行跨程式逐像素／ΔE 對照。因此上述 Lightroom 對照仍記錄為 `NOT RUN`，不能宣稱已完成 Lightroom parity。

參考：

- [Adobe Lightroom Classic：調整影像色調與色彩](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/image-tone-color.html)
- [Adobe Lightroom Classic：Develop 模組工具](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/develop-module-tools.html)
- [Adobe Lightroom Classic：Masking](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/masking.html)
