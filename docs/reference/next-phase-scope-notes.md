# 下一階段（MVP 之後）範圍筆記——2026-08-16 使用者決定

- **不是規格，是決定記錄**：這裡只記使用者在對話中做的範圍決定，正式排入計畫時要走 spec → 核准 → 驗收 的既有流程，不能直接照這份筆記動手實作。
- 觸發脈絡：使用者貼了 AwayPhotoRawEditor 的完整截圖（裁切/漸層/修護工具、風格檔套用、多選縮圖批次），希望 LumaHarbor 也做到類似完整度。對照規格 §14 後續階段路線圖：裁切/旋轉/漸層/修護對應 §14.1，風格檔與批次對應 §14.2。

## 使用者決定的三件事

1. **風格檔（preset）系統要兩者都做**：
   - LumaHarbor 自己內建一套風格檔系統（類似 AwayPhotoRawEditor 的內建＋自訂風格檔模式）。
   - **同時**要能讀取真正的 Lightroom 匯出的 `.xmp` 風格檔。這兩件事技術難度差很多——LumaHarbor 自己的調色管線（Core Image 為基礎）跟 Lightroom 的調色演算法不是同一套，直接套用 Lightroom `.xmp` 的參數值到 LumaHarbor 的調整鏈，畫面結果不會跟 Lightroom 裡看到的一樣，這點寫 spec 時要跟使用者明確對齊「相容」的定義是「讀得懂檔案格式、套用等價調整」還是「像素級輸出一致」（後者幾乎不可能做到）。

2. **匯出要「完整方式」**：
   - 單張匯出（MVP 已有）與批次匯出都要。
   - 格式不只 JPEG，要涵蓋其他常見圖檔格式（使用者原話「要完整方式」，沒有指定明確格式清單，寫 spec 時需要跟使用者確認實際要哪些格式，例如 TIFF／PNG／HEIC 等）。

3. **時程決定**：先把目前 Mac-first MVP 的人工驗收（Gate D/E/F，見 [`2026-08-15-mac-first-mvp-acceptance-plan.md`](../superpowers/specs/2026-08-15-mac-first-mvp-acceptance-plan.md)）做完、正式簽收，**再**開新 spec 規劃這一整塊。使用者明確選擇「先驗收完再做」而不是「現在就開始寫新 spec」。

## 下一步（等 MVP 簽收後）

寫一份新的 spec 文件（比照現有 `docs/superpowers/specs/` 的格式與核准流程），至少要涵蓋：
- 裁切/旋轉/漸層/修護等局部與幾何工具的資料模型與 UI（可參考 [`awayphotoraweditor-design-notes.md`](awayphotoraweditor-design-notes.md) 裡對應章節的設計參考）。
- 風格檔系統的稀疏覆寫模型 + Lightroom `.xmp` 匯入的相容性範圍界定。
- 批次多選同步編輯的正確性模型（同一份參考筆記裡已經整理過 AwayPhotoRawEditor 踩過的坑）。
- 匯出格式清單需先跟使用者確認。
