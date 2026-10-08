# Brush preview performance fix — Gemini read-only review

日期：2026-10-08（Asia/Taipei）

審查工具：agy → Gemini 3.1 Pro High
審查模式：plan／唯讀
審查範圍：sanitized bundle，僅含必要的 source、tests、spec、報告與 gate summaries；未提供私人 RAW、JSONL raw samples、憑證、個人設定、`.git` 或 build products。

## Verdict

`APPROVED_WITH_CONCERNS`

## Follow-up resolution

`RESOLVED`（2026-10-08）

Sol 以 TDD 處理唯一 minor：先加入 `BrushMaskRenderer.coverageTileSize == 128` acceptance contract，確認原本 256 會產生預期 RED，再將實作對齊固定 128×128 並取得 GREEN。產品提交為 `7af212512f59768801081765808202fe84a85b25`。

修正後重新驗證：focused 31/31、synthetic stress／`PERF-COVERAGE`／preview memory、RAW warm 0／1／10 masks、original-size export／memory、50-cycle cancellation convergence 與完整 Release 2715 tests 全數 PASS；pixel parity 維持 max R8 byte error 0。因此原審查的唯一 concern 已解決，沒有新增 blocking 或 non-blocking finding。

### Blocking findings

None。

### Non-blocking finding

- **Severity：Minor**
- **原審查位置**：`Sources/RawProcessingCore/Pipeline/BrushMaskRenderer.swift:516`
- **現況**：實作使用 `let tileSize = 256`。
- **Spec**：[brush performance and acceptance repair spec](../../superpowers/specs/2026-10-06-brush-performance-and-acceptance-repair-spec.md) 指定第一版固定 `128×128` pixel tile。
- **影響**：Gemini 判定目前 bounded memory 與效能 gate 仍成立，但 strict spec compliance 有一項數值落差。
- **建議**：若要求嚴格遵循 spec，交給 Sol 將 tile size 改回 `128`，再重跑 pixel parity、synthetic stress、RSS、cancellation 與 full Release gates。這是 bounded follow-up，不是目前的 correctness blocker。

## Review results

- B/O 相同且互斥 stage wall-time 與 interval union：PASS。
- bounded mask fan-out 與 tile scratch：PASS。
- mask order、paint／erase、geometry、overlap 語意：PASS。
- decoded preview cache key、逐出與 context 隔離：PASS。
- analyzer 對不完整 stage artifact fail closed：PASS。
- 報告與 gate summary：一致。
- Mac／iPad／Pencil／VoiceOver／灰卡人工驗收：NOT RUN。

## Bounded next action

此 bounded action 已由 `7af2125` 完成。剩餘項目只有 Mac／iPad／Pencil／VoiceOver／灰卡人工 gate；Gemini 本次仍未修改任何檔案。
