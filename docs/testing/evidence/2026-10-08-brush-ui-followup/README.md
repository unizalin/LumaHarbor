# Brush UI follow-up evidence

日期：2026-10-08（Asia/Taipei）

狀態：`DONE_WITH_CONCERNS`

本目錄保存筆刷 Alpha 整合收尾的人工操作矩陣。公開證據只記匿名計數、環境與狀態；含私人照片、檔名、路徑或裝置識別碼的本機截圖不提交。

## 版本

- Branch：`luna/brush-preview-performance-fix`
- 本輪 Mac 修正基準：`5d32550029fd317e377a732fa68b57ec2ff2cf85`
- Simulator app source：`1dda4ad3f5c26a488fc8cce4cfc3172c87dd2a08`
- 已驗證產品／harness：`7af212512f59768801081765808202fe84a85b25`
- Target：iPad Pro 11-inch (M4)、iOS 18.6 Simulator、Debug

`git diff --quiet 1dda4ad3..72945cf -- Sources Apps Package.swift Package.resolved` exit 0，因此沿用已 fresh build、install、launch 且 exit 0 的 Simulator bundle；兩者之間只有文件／證據變動，沒有重建產品。

## 目前證據

- [Simulator matrix](simulator-matrix.md)：Files 選取／Quick Look 後返回編輯器、真實 iPad Split View 窄窗、paint 與重啟持久化已補證。
- [Mac matrix](mac-matrix.md)：筆刷刪除／Undo／Redo／重開、Local off/on paste、batch sync、snapshot restore／持久化／刪除最後快照已補證；發現並修正 Mac 快照沒有接入 sidecar 讀寫的缺陷。

Simulator sidecar 只以匿名聚合值讀取。Split View 增筆前為 1 mask／1 paint stroke／局部曝光 0.1；增筆、自動保存及 terminate／relaunch 後為 1 mask／2 paint strokes／局部曝光 0.1。

`UI-SIM-01` 仍為 `PARTIAL`：Files 可選取並預覽測試 RAW，回到 app 後既有編輯仍在，但本輪沒有證明 Files 直接把文件交給 LumaHarbor。產品 iPad 畫布將倍率限制在 1×～5×，且 UI 沒有精確倍率讀值，原驗收要求的 0.75×不可達，2×也無法從 UI 證明為精確倍率。Files 的 app-copy／in-place 模式亦無 UI 證據可獨立判別。這些列維持 `NOT RUN`，沒有注入 sidecar 或使用 Simulator 顯示倍率代替產品操作。

## 硬體、素材與 PERF-UI 依賴

- `xctrace` 重新查詢時，配對 iPad 與 iPhone 都列在 offline；實體觸控、旋轉、Split View、來源離線／重接、Pencil、硬體鍵盤及 hands-on VoiceOver 維持 `NOT RUN`。解除條件是裝置重新上線並可由目前 Xcode destination 使用。
- 可散布 fixture inventory 沒有灰卡／色卡候選，也沒有受控 ROI reference。私有 inventory 先前亦沒有可辨識的合格組合；灰卡 gate 維持 `NOT RUN`。解除條件是同一 RAW 的 D65 reference、固定 ROI 與 provenance 可散布。
- checkout 中沒有符合規格的 UI heartbeat recorder。現有 renderer stage clock、preview scheduler latency 與 accessibility 操作都不能替代 16 ms UI heartbeat。

PERF-UI recorder 的後續設計固定如下：在 UI process 以單調時鐘記錄 display heartbeat；每個手勢由 pointer-down 到最後一次可見 frame 建立唯一 gesture ID；B/O 各執行 30 次相同腳本並保留每個 frame interval，不只存摘要。原始 JSONL 至少包含 schema version、匿名 build/variant、gesture kind／ID、display refresh interval、monotonic start/end、frame interval、missed-heartbeat count、sample completeness 與取消原因。錄製工作不得跑在 renderer worker 上，也不得把平行 CPU duration 相加；缺 frame、app 退到背景、gesture 取消或 recorder overflow 必須 fail closed，該次樣本無效並保留原因。需先加入時鐘／gesture boundary／缺樣與取消的單元測試，再開發產品或 test-host recorder。
