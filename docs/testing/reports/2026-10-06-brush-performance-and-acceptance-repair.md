# Brush performance and acceptance repair report

## 2026-10-06 追補更正（優先於下方歷史結論）

目前產品仍為 `DONE_WITH_CONCERNS`。本次只新增[後續修正规格](../../superpowers/specs/2026-10-06-brush-raster-correctness-and-verification-followup-spec.md)，沒有修改產品或重跑產品測試；先前檢測的結果與本次讀碼核對範圍見該規格 §2。

- **列位置缺陷**：`BrushMaskRenderer.renderCoverage` 只翻轉 tile 內列，未翻轉 tile 的全圖位置；height=240 的索引反例已核對，新增失敗像素測試仍為 `NOT RUN`。下方「保留 row flip」不可視為已證明。
- **Oracle 範圍**：180×120 案例只跨水平 tile，量的是 blend 後 CGImage bytes；下方「R8 差 0」不是直接 R8 比較證據。sync／async 相等也不能排除兩者共用的錯誤。
- **取消範圍**：既有測試在 callback 計數到9時自行拋錯，未呼叫父 Task.cancel，且 async 為單 mask；真實 raster 中段取消、平行 worker 結束與無晚到發布仍需驗證。
- **Release 範圍**：前次原始 Release integration 命令因 DEBUG-only helper 缺失而編譯 FAIL（exit 1、0 tests）。加 `-Xswiftc -DDEBUG` 後才通過；下方 Release synthetic 數字須解讀為該組態的診斷樣本，不是標準 Release 或正式 B/O gate PASS。
- **RAW 範圍**：前次 141～148 ms 為空筆刷的 production preview，包含 decode、adjust 與 CGImage 產生；並非單獨 decode，也不能代表一／十 mask 的互動效能。

後續依 F1 像素→F2 Release→F3 真實取消→F4 B/O 與 RSS→F5 驗收交接執行。以下保留首次交付的命令、樣本與文字作歷史紀錄；與本區塊衝突時以更正為準。

## 首次交付紀錄

日期：2026-10-06
狀態：`DONE_WITH_CONCERNS`
分支：`codex/brush-performance-acceptance-repair`
基準：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`（mainline white-balance／brush integration candidate）
實作 commit：`26c3390`（`Optimize brush coverage and wire cancellable async rendering`）

本輪依 [repair spec](../../superpowers/specs/2026-10-06-brush-performance-and-acceptance-repair-spec.md) 完成 coverage rasterizer、取消傳遞、preview／export 接線、context reuse，以及可重現的 Release harness。實作已提交，但基線 B/O 差異、原尺寸 export／RSS、實機操作與灰卡色彩驗收尚未執行，因此不宣稱整合 READY。

## 變更

- `BrushMaskRenderer` 改為固定 128×128 tile 的 bounded R8 coverage，保留 stroke／sample／paint／erase 順序、row flip、非零 extent 與 scalar 像素語意；validation、sampling、rasterization、R8 conversion 都可取消。
- 新增 `applyValidatedAsync`。不同 mask 的 coverage 可並行，最後仍依原 mask 順序 composite；單一 mask 走直接路徑，避免不必要的 task-group 開銷。
- preview 與 export 改用 async renderer；`runOffActor` 補上 async overload，保留 parent-to-detached cancellation forwarding。
- `ImageRenderService.configured(for:)` 對相同 working/output color-space recipe 重用 service，遇不同 output transform 建立隔離 service。
- 新增 deterministic workload、獨立 scalar oracle、取消 probe、async order integration test 與 `Scripts/run-brush-performance-acceptance.sh`。

## 自動化證據

| Gate／檢查 | 結果 |
| --- | --- |
| Full SwiftPM regression | `swift test --scratch-path "$TASK_SWIFT_SCRATCH"`：2,696 executed、18 skipped、0 failures |
| Strict concurrency build | `swift build --scratch-path "$TASK_STRICT_SCRATCH" -Xswiftc -strict-concurrency=complete`：exit 0；只有既有 strict warnings |
| Cancellation／scalar oracle | 4 tests executed、0 failures；coverage bytes 與獨立 scalar oracle 最大差 0；sync／async composite byte-identical |
| Context identity／isolation | 4 tests executed、0 failures；相同 recipe 重用 instance，不同 output transform 隔離 |
| Release harness | 16 samples × 0／1／10 masks，test 1 executed、0 skipped、0 failures |
| Diff hygiene | `git diff --check`：PASS；新增 script mode 為 executable |

Release harness command：

```sh
LUMAHARBOR_BRUSH_PERF_SAMPLES=16 \
LUMAHARBOR_BRUSH_PERF_SCRATCH_PATH="$TASK_PERF_SCRATCH" \
Scripts/run-brush-performance-acceptance.sh
```

固定 workload 為 1600×1067、0／1／10 masks、每 mask 10 strokes、每 stroke 100 points、seed `LH-BRUSH-PERF-ACCEPTANCE-20261006`、`preferMetal=true`。下表以 16 筆 raw JSON duration 計算，p50 是排序後中央兩筆平均，p95 是 nearest-rank `ceil(0.95×16)=16`，時間單位為 ms。

| masks | coverage p50 | coverage p95 | end-to-end p50 | end-to-end p95 | incremental p50／p95 vs empty |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 0.002 | 0.004 | 2.274 | 2.431 | — |
| 1 | 11.058 | 11.202 | 13.635 | 13.815 | 11.361／11.383 |
| 10 | 19.964 | 21.321 | 25.561 | 26.417 | 23.287／23.986 |

依本輪 absolute synthetic thresholds，單 mask coverage ≤20 ms、十 mask ≤80 ms，preview incremental ≤30／100 ms，且 150 ms interactive total target 仍保留；目前 synthetic O 通過這些 absolute／incremental 目標。完整 raw JSON 是該 command 的三筆 stdout record；此 report 保留其統計與固定 seed，未把私有 scratch 或使用者路徑提交。

## 尚未完成的驗收

- **P3 B/O comparison：`NOT RUN`**。尚未在同一硬體以 candidate exact SHA 建立 baseline B，故不能宣稱 `PERF-EMPTY` 的 regression delta 或 `PERF-EXPORT` 的 50% improvement。
- **原尺寸 export／memory：`NOT RUN`**。尚未執行 6000×4000 一／十 mask、peak RSS、50 次取消／切圖 settled RSS。
- **取消產品矩陣：`PARTIAL`**。注入 cancellation 已確認 coverage 中段拋出 `CancellationError`；8 次 preview／8 次原尺寸 cancel、worker 結束與無晚到發布尚未完成。
- **P4 UI／裝置／灰卡：`NOT RUN`**。Mac 前景操作、實體 iPad／觸控／Pencil／鍵盤／VoiceOver、灰卡 D65 Lab／ΔE00 與獨立 reviewer 尚未執行。既有 Lightroom Gate 2 維持原狀。
- **既存 renderer semantics concern**：rendererVersion 1 目前仍未把 persisted density／pressure 重新解釋成可見 opacity；本輪只修效能與可取消性，沒有偷偷改資料語意。若產品規格要求壓力顯色，需另開 correctness 修正與版本政策。

下一個 bounded action 是在同一台參考機器跑 candidate B 與本 branch O 的 ABBA Release workload，再補原尺寸 export／RSS；在那些證據完成前維持 `DONE_WITH_CONCERNS`。
