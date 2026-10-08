# Brush UI follow-up evidence

日期：2026-10-08（Asia/Taipei）

狀態：`IN_PROGRESS`

本目錄保存筆刷 Alpha 整合收尾的人工操作矩陣。公開證據只記匿名計數、環境與狀態；含私人照片、檔名、路徑或裝置識別碼的本機截圖不提交。

## 版本

- Branch：`luna/brush-preview-performance-fix`
- 本輪文件基準：`72945cf794cccf07d41f9c8d823bb230eceabcf4`
- Simulator app source：`1dda4ad3f5c26a488fc8cce4cfc3172c87dd2a08`
- 已驗證產品／harness：`7af212512f59768801081765808202fe84a85b25`
- Target：iPad Pro 11-inch (M4)、iOS 18.6 Simulator、Debug

`git diff --quiet 1dda4ad3..72945cf -- Sources Apps Package.swift Package.resolved` exit 0，因此沿用已 fresh build、install、launch 且 exit 0 的 Simulator bundle；兩者之間只有文件／證據變動，沒有重建產品。

## 目前證據

- [Simulator matrix](simulator-matrix.md)：Files 選取／Quick Look 後返回編輯器、真實 iPad Split View 窄窗、paint 與重啟持久化已補證。
- Mac follow-up matrix：Task 3 尚未完成。

Simulator sidecar 只以匿名聚合值讀取。Split View 增筆前為 1 mask／1 paint stroke／局部曝光 0.1；增筆、自動保存及 terminate／relaunch 後為 1 mask／2 paint strokes／局部曝光 0.1。

`UI-SIM-01` 仍為 `PARTIAL`：Files 可選取並預覽測試 RAW，回到 app 後既有編輯仍在，但本輪沒有證明 Files 直接把文件交給 LumaHarbor。產品 iPad 畫布將倍率限制在 1×～5×，且 UI 沒有精確倍率讀值，原驗收要求的 0.75×不可達，2×也無法從 UI 證明為精確倍率。Files 的 app-copy／in-place 模式亦無 UI 證據可獨立判別。這些列維持 `NOT RUN`，沒有注入 sidecar 或使用 Simulator 顯示倍率代替產品操作。
