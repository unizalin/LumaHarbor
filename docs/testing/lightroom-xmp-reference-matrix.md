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
4. 每次比較建立只供該 mode 使用的乾淨目錄，不沿用前一次輸出。
5. 用 `Scripts/validate-lr-reference-matrix.zsh` 先驗證矩陣，再用 `LumaHarborReferenceCompare` 計算差異。

比較命令必須明確指定一種 mode：

```sh
swift run LumaHarborReferenceCompare \
  --mode neutralDirect \
  --case fixture-a \
  --lr-neutral <id> --lr-preset <id> \
  --lh-neutral <id> --lh-preset <id> \
  --matrix <matrix.json> --images <clean-directory>
```

- `neutralDirect`：直接比較 Lightroom 與 LumaHarbor neutral。
- `presetEffect`：比較兩邊的 `(preset - neutral)` 效果場。
- `finalDirect`：直接比較兩邊套用 preset 後的最終影像。

Neutral Gate 2 使用批次命令，只取四個 unique raw ID 的 neutral pair，不重複計算五個 preset fixture：

```sh
swift run LumaHarborReferenceCompare \
  --all-neutral \
  --matrix <matrix.json> \
  --images <clean-directory>
```

`--all-neutral` 會輸出四筆逐案結果；任一筆缺 reference 會標為 `NOT RUN`，任一筆 metrics 或 metadata 失敗會讓 process exit non-zero。單案例與批次共用同一個 16-bit embedded-sRGB loader、metrics 與 thresholds v2。

輸出 JSON 一律包含 `mode`。三種 mode 各自判定 PASS／FAIL，彼此不能抵銷。

## 狀態語意

- 矩陣模板可在沒有 reference image 時驗證 schema。
- 沒有實際四張影像時，case 是 `NOT RUN`，不是 PASS。
- 缺少任何一張影像、尺寸不一致或輸出色彩空間不一致時，case 失敗。
- 同一 image ID 同時存在多種候選副檔名時失敗，避免讀到前次輸出的殘留檔。
- 不同 case 的影像內容 hash 相同時失敗；只允許同一 `rawID`、同一 neutral 欄位與同一 neutral ID 被多個 preset case 明確共用。
- 報告只輸出 fixture ID、case ID、尺寸、指標與門檻結果，不輸出私有絕對路徑、原始 XMP 或照片 metadata。
