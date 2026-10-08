# iPad Simulator brush follow-up matrix

日期：2026-10-08（Asia/Taipei）

整體結果：`UI-SIM-01 PARTIAL`

## 固定環境

| 欄位 | 值 |
| --- | --- |
| Source SHA | `1dda4ad3f5c26a488fc8cce4cfc3172c87dd2a08` |
| Product／harness SHA | `7af212512f59768801081765808202fe84a85b25` |
| Follow-up 起始文件 SHA | `72945cf794cccf07d41f9c8d823bb230eceabcf4` |
| Target | iPad Pro 11-inch (M4)、iOS 18.6 Simulator |
| Configuration | Debug、unsigned Simulator build |
| Bundle | `org.lumaharbor.LumaHarborPad` |
| Product source drift check | exit 0；Source／Apps／package inputs 自既有 fresh build 後未變 |

本輪使用隔離的測試文件。畫面與檔案只在本機確認；公開矩陣不保存私人照片、檔名、路徑或裝置識別碼。

## 操作矩陣

| 案例 | 起始狀態 | 操作 | 預期 | 實際與保存結果 | 狀態 |
| --- | --- | --- | --- | --- | --- |
| Files 選取並回到編輯器 | 已存在 1 mask、1 paint stroke、局部曝光 0.1 | 在 Files 選取測試 RAW；檔案進入 Quick Look，再將 LumaHarbor 切回前景，開啟局部調整並展開筆刷 | Files 直接交給 app，且同一文件的筆刷狀態可讀 | 返回 app 後既有筆刷與局部曝光 0.1 仍在；Files 直接交件給 app 的語意未獲證明 | PARTIAL |
| Files app-copy 路徑 | 同上 | 檢查 Files 與 app 的可見流程 | 可證明文件已複製進 app 管理範圍 | UI 沒有顯示 storage mode，匿名 sidecar aggregate 也不能辨別來源語意 | NOT RUN |
| Files in-place 路徑 | 同上 | 檢查 Files 與 app 的可見流程 | 可證明文件持續以原位置存取 | UI 沒有顯示 storage mode，且不得以私人路徑推論 | NOT RUN |
| 真實 Split View 窄窗 | Files 與 LumaHarbor 均可前景顯示 | 由 iPad 多工選單選 Split View，再從 Dock 選 Files | LumaHarbor 進入窄版且 inspector／canvas 可操作 | LumaHarbor 與 Files 並列；局部調整、筆刷控制與 canvas 仍可存取 | PASS |
| 窄窗可用內容尺寸 | 約 60／40 Split View | 讀取視窗與 accessibility 狀態 | 取得產品內容區精確 logical point 尺寸 | 可證明是 iPad Split View，不是縮放 macOS 外框；工具沒有曝露 app pane 的精確 logical point 尺寸 | NOT RUN |
| 窄窗 paint 與 autosave | 1 mask、1 paint stroke、曝光 0.1 | 在窄版可見 canvas 繪製一筆，等待 `未儲存` 轉為 `已儲存` | 只新增一筆且保存 | 匿名聚合變為 1 mask、2 paint strokes、曝光 0.1 | PASS |
| 窄窗結果重啟持久化 | 上列已保存 | terminate／relaunch，開啟局部調整並展開筆刷，再讀匿名聚合 | stroke 與曝光保持 | UI 顯示曝光 0.1；匿名聚合仍為 1 mask、2 paint strokes、曝光 0.1 | PASS |
| 產品畫布 0.75× | 文件已開啟 | 尋找產品 zoom 控制／倍率讀值 | 精確設為 0.75×，paint／erase 並核對 source 落點 | iPad `PadEditorCanvasView` 將 scale clamp 在 1×～5×，0.75×不可達 | NOT RUN |
| 產品畫布 1× | 初始文件 workspace | 既有 paint、Undo／Redo 與本輪 paint | 在可證明的 1× 下核對 paint／erase source 落點 | 初始 workspace 為 1×，paint 與保存已通過；沒有可散布的可辨識 source marker 可完成原規格的 paint／erase 落點對照 | NOT RUN |
| 產品畫布 2× | 文件已開啟 | 嘗試由 pinch gesture 設定倍率 | 精確設為 2×，paint／erase 並核對 source 落點 | UI 無倍率讀值；pinch 可改變 scale，但無法證明精確 2×，故未把近似手勢判成 PASS | NOT RUN |

## 匿名保存結果

```text
JSON_DOCUMENTS_SCANNED=3
BRUSH_MASK_COUNT=1
STROKE_COUNT=2
STROKE_MODES={"paint":2}
EXPOSURE_VALUES=[0.1]
```

上述聚合在窄窗 paint 自動保存後與 terminate／relaunch 後一致。UI 重開後也顯示局部曝光 0.1。

## 限制與判定

- 使用 iPad 多工選單進入 Split View，並非縮小 Simulator 的 macOS 外框。
- accessibility tree 可核對控制與保存狀態，但不等於 hands-on VoiceOver 驗收。
- 不以 Simulator 顯示倍率代替產品畫布 zoom，不注入 sidecar，不從私人路徑推論 app-copy／in-place。
- 含私人照片內容的本機截圖未提交。

Files 選取／Quick Look 後返回編輯器可保留既有狀態；真實 Split View、窄窗 paint/autosave 與重啟保存均通過。Files 直接開啟 app、精確 zoom/source-marker、storage mode、鍵盤及 hands-on VoiceOver 尚未完整驗證，因此 `UI-SIM-01` 維持 `PARTIAL`。
