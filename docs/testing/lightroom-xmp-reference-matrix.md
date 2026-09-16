# Lightroom XMP 參考矩陣

這份矩陣把一份 XMP 套用前後的 Lightroom 與 LumaHarbor 輸出配成同一個 case。檔案只使用穩定 ID；RAW、XMP 與輸出影像放在 ignored 的私有資料夾，不寫入 Git。

## 四張參考影像

每個 case 必須提供：

- `lrNeutralID`：Lightroom 未套用 Preset 的輸出。
- `lrPresetID`：Lightroom 套用該 XMP 的輸出。
- `lhNeutralID`：LumaHarbor 未套用 Preset 的輸出。
- `lhPresetID`：LumaHarbor 套用該 XMP 的輸出。

影像統一使用原尺寸、16-bit TIFF、sRGB、無 resize、無輸出銳化、無浮水印。若 Lightroom 版本或 Profile 不能使用完全相同設定，需在驗收報告列出差異，不能把差異隱藏在 case ID 中。

## 建立流程

1. 用相同 RAW 建立 Lightroom neutral 與 Preset 輸出。
2. 在 LumaHarbor 使用相同 RAW，建立 neutral 與套用後輸出。
3. 將影像放進私有 reference image directory，檔名以矩陣中的 ID 加 `.tiff`。
4. 用 `Scripts/validate-lr-reference-matrix.zsh` 先驗證矩陣，再用 `swift run LumaHarborReferenceCompare` 計算效果差異。

## 狀態語意

- 矩陣模板可在沒有 reference image 時驗證 schema。
- 沒有實際四張影像時，case 是 `NOT RUN`，不是 PASS。
- 缺少任何一張影像、尺寸不一致或輸出色彩空間不一致時，case 失敗。
- 報告只輸出 fixture ID、case ID、尺寸、指標與門檻結果，不輸出私有絕對路徑、原始 XMP 或照片 metadata。
