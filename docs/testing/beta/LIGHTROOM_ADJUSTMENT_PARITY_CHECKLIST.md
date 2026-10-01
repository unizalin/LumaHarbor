# Lightroom 調整功能人工驗收清單

這份清單用於真實 RAW fixture 的手動驗收；單元測試通過不等於與 Lightroom 逐像素一致。

## 測試條件

- [ ] 使用同一份原始 Sony ARW，不覆寫原檔。
- [ ] Lightroom Classic 與 LumaHarbor 使用相同輸出色彩空間、位元深度與尺寸。
- [ ] 記錄 Lightroom 的 as-shot Temperature/Tint 與 LumaHarbor 顯示的 baseline。
- [ ] 每次只改一個控制，另存 before/after 影像與 sidecar/XMP。

## Basic

- [ ] Exposure：`-1 / 0 / +1 EV`，灰階 ramp 單調且高光裁切方向正確。
- [ ] Temperature：輸入 `3200 K / 5500 K / 6500 K`，顯示值與輸出色偏方向一致。
- [ ] Tint：`-50 / 0 / +50`，綠↔洋紅方向一致。
- [ ] Contrast、Highlights、Shadows、Whites、Blacks：分別以暗部、中間調、高光 patch 驗證。
- [ ] Vibrance 與 Saturation：確認 Vibrance 不等同於全域 Saturation。

## Curve／Color

- [ ] Tone Curve：黑點、白點、S-curve 與反向操作不產生 solarize。
- [ ] HSL：八色 patch 各自修改 Hue/Saturation/Luminance，確認非目標色不被顯著影響。
- [ ] Split Toning：暗部／亮部方向與 Balance 驗證；記錄 Midtones/Color Grading 為 unsupported。

## Detail／Effects

- [ ] Sharpening：Amount、Radius、Detail、Masking 各自改變邊緣；平坦區不應同樣放大 halo。
- [ ] Noise Reduction：Luminance 與 Color 分別驗證，記錄 Core Image 近似差異。
- [ ] Vignette：正負 Amount、Midpoint、Roundness、Feather，確認裁切後座標。
- [ ] Grain：Amount、Size、Roughness，確認 preview/export 視覺尺度接近。

## Geometry／Local／Workflow

- [ ] Rotate、Flip、Straighten、Perspective、Crop：確認順序與輸出尺寸。
- [ ] Linear Gradient：位置、角度、範圍、羽化與局部 tone/color。
- [ ] Spot Heal：Heal／Clone、source point、feather。
- [ ] Reset、Undo、preset preview/cancel/commit、XMP round-trip、batch gesture undo。

## 結果記錄

對每一項填寫 `PASS`、`FAIL` 或 `NOT RUN`，並附 fixture 名稱、Lightroom 版本、LumaHarbor build 與觀察差異。只有全部人工 gate 通過後，才可宣稱「已完成 Lightroom 語意校正」。
