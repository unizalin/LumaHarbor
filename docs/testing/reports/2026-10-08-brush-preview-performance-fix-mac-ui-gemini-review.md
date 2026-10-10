# Brush preview performance fix — Mac 文件 Gemini 唯讀審查

日期：2026-10-08（Asia/Taipei）

審查工具：agy → Gemini 3.1 Pro High

審查模式：sandbox／唯讀

初審範圍：`7af2125..159fbeb` 的五份 sanitized 文件差異；未提供私人 RAW、憑證、個人設定、`.git`、build products 或本機代理狀態。

## Initial verdict

`CHANGES_REQUESTED`

### Finding

- **Severity**：High（文件證據一致性）
- **位置**：`docs/coordination/CURRENT.md`
- **問題**：`CURRENT.md` 將 `12.084/13.337` 與 `70.779/81.143 ms` 寫成兩輪合併 total wall time，但 evidence README 與驗收報告只列出 stage total `11.988/13.210` 與 `70.664/81.013 ms`，未說明兩組數字來自不同欄位。
- **Gemini 建議**：改成已列出的 stage total，或明確引用逐輪結果。

## Local verification and resolution

本地直接由 `synthetic-stress-samples.jsonl` 的 16 筆 O 樣本重算：

- 1 mask `totalDurationSeconds` 合併 p50/p95=`12.084/13.337 ms`。
- 10 masks `totalDurationSeconds` 合併 p50/p95=`70.779/81.143 ms`。
- 同批樣本的 `stageDurationsSeconds.totalMaterialized` 合併 p50/p95 分別為 `11.988/13.210` 與 `70.664/81.013 ms`。

因此初審 finding 對「文件缺乏來源與邊界說明」成立，但數字不是捏造。修正方式是保留兩組可重算的數據，並在 evidence README、驗收報告、`CURRENT.md` 與 handoff 明確區分：stage total 只涵蓋 B/O 共用互斥 stage clock；端到端 total duration 另含 harness 邊界的少量開銷。

## Follow-up verdict

`APPROVED`

同一模型以修正後的 sanitized diff 與四組本地重算值完成 follow-up，結果如下：

- End-to-end 與 stage total 已在所有文件中正確區分：PASS。
- 初審 `CHANGES_REQUESTED` 已如實保存：PASS。
- Bounded next action 與尚未執行的人工 gate 保持清楚：PASS。
- 沒有誇大硬體／人工驗收：PASS。
- Privacy check：PASS。
- Findings：none。

Gemini 全程未修改任何檔案。
