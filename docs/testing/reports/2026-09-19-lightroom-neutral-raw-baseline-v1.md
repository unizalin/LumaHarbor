# Lightroom Neutral RAW Baseline v1 驗收報告

日期：2026-09-19
分支：`codex/lr-neutral-baseline-v1`

## 結論

目前完成的是 RAW neutral policy、shared render diagnostics、sidecar 穩定性與公開 reference 工具鏈驗證。Lightroom 與 LumaHarbor 的 Gate 2 像素級驗收維持 `NOT RUN`，因為本機沒有可配對的 Lightroom 輸出參考影像。

## 驗收矩陣

| 項目 | 狀態 | 證據／說明 |
| --- | --- | --- |
| 新 RAW policy | PASS | 新 RAW 的 persisted/requested policy 可記錄 Adobe Process 2012 v1，但 Gate 2 前 `effectivePolicy` 明確 fail closed 為 Native；user adjustments 仍為 neutral。 |
| 舊資料與 non-RAW policy | PASS | 既有 migration／persistence 測試通過。 |
| Mac／iPad recipe diagnostics | PASS | 兩端共用 presenter、穩定 row IDs 與相同 resolved recipe 語意。 |
| Sidecar unchanged rewrite | PASS | 首次寫入與後續重寫使用同一 canonical JSON 路徑。 |
| Reference matrix schema | PASS | schema v2、20 cases、80 image references 的公開模板驗證通過。 |
| Reference comparison metrics | PASS | 15 個公開 contract／metrics tests 全數通過。 |
| Lightroom Gate 2 neutral direct | NOT RUN | 缺少同一批 RAW 的 Lightroom 16-bit sRGB TIFF 參考。 |
| Preset effect／final direct | NOT RUN | 缺少 Lightroom 套用 XMP 後的配對輸出。 |
| Mac／iPad pixel parity | NOT RUN | 尚未有可比較的 reference TIFF 與實體 iPad 輸出。 |
| 實體 iPad smoke | NOT RUN | 本輪未重新安裝並驗收目前分支 build。 |
| Performance benchmark | NOT RUN | 尚未取得完整四張 reference 與同條件輸出。 |
| Repository privacy／diff hygiene | PASS | `git diff --check` 與敏感資料掃描通過；私人 RAW／XMP 未加入 Git。 |

## 已執行命令

- `swift test`：2444 executed、13 skipped、0 failures。
- `swift test --filter 'LightroomReferenceMatrixContractTests|ReferenceCompareCommandContractTests|ReferenceComparisonMetricsTests'`：15 executed、0 failures。
- `Scripts/validate-lr-reference-matrix.zsh`：公開模板驗證 PASS。
- `swift build --scratch-path ... -Xswiftc -strict-concurrency=complete`：PASS。
- macOS app bundle build：PASS。
- iPad generic Simulator `xcodebuild`：PASS。

## 下一步前置條件

需要從 Lightroom Classic 為同一批 RAW 匯出原尺寸、16-bit、embedded sRGB、無 resize／sharpening／watermark 的 neutral 與 XMP-applied TIFF。檔案只需放在未追蹤的私人 reference 目錄，以矩陣中的 stable IDs 命名；報告不會記錄私人路徑、檔名、影像內容或 XMP 內容。

## Fail-closed renderer 驗證（2026-09-21）

- Adobe Process 2012 policy 仍保留在 persisted/requested `policy`；Gate 2 前的預設 `effectivePolicy` 為 native。
- Disabled／unsupported path 的 decoder option vector、working color space、camera profile stage、preview/export recipe 均回到 native；profile 名稱與 fallback 診斷仍保留且明確標示未套用。
- 舊 recipe 缺少 `effectivePolicy` 欄位時，Adobe policy 以 native fail closed 解碼，避免舊資料意外啟用未校正 renderer。
- TDD focused tests：resolver、preview/export parity、camera-profile suppression、legacy Codable fallback、paste/reset/batch rollback 全數 PASS；含私人 RAW 的實際 decoder／preview／export parity 為 2/2 PASS。
- 完整 `swift test`（啟用本機未追蹤私人 RAW fixture）：2453 executed、3 skipped、0 failures；diagnostics presentation 亦確認 fail-closed Adobe request 顯示為 native mode。
- fail-closed workflow focused tests：30/30 PASS；persisted Adobe policy 在 encode/decode、關閉重開、Undo、Reset、copy/paste 與 batch export 後仍保留，但每次的 `effectivePolicy`、decoder、色域、camera profile stage、preview/export 都維持 native。
- 公開 reference contracts：15/15 PASS；矩陣 validator：schema v2、20 cases、80 references PASS。
- strict-concurrency `swift build`、macOS `Scripts/build-app-bundle.sh debug`、iPad generic Simulator `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` 均 PASS。
- 實體 iPad smoke 為 `NOT RUN`：`xcrun devicectl list devices` 因 CoreDevice service XPC connection invalidated 而無法列出可用裝置，因此沒有安裝或宣稱真實裝置結果。
- Lightroom Gate 2 像素比對、Mac/iPad pixel parity 與 performance 仍為 `NOT RUN`；缺少四組 paired Lightroom neutral／XMP-applied TIFF，不能把私人 RAW 與 Lightroom parity 混為 Gate 2 證據。本輪未 push、merge、rebase、commit 或修改 main。

## Gate 2 production hardening handoff（2026-09-21）

> **歷史 freeze snapshot**：以下記錄的是接手當下、尚未執行本輪 P1-P4 前的狀態；最新結果請以下方「Production hardening implementation result」為準。

本節是本分支接手 Sol dirty worktree 後的 evidence freeze，不覆蓋先前報告。

| 項目 | 狀態 | 證據／限制 |
| --- | --- | --- |
| Worktree ownership | IN_PROGRESS | `codex/lr-neutral-baseline-v1`，HEAD `fb421507bfeed1b2ff146109e3540d91de0eba62`；既有 dirty files 保留，未 commit／push／merge／rebase。 |
| 現有 fail-closed contract | PASS | focused suites 28 executed、0 skipped、0 failures；persisted Adobe policy 不代表 effective Adobe renderer。 |
| Evidence freeze／P0 | PASS | 本節與 `docs/coordination/2026-09-21-lr-gate2-production-hardening-handoff.md` 已建立，後續以 successor spec 的 P1-P7 為準。 |
| P1-P3 production hardening | NOT RUN | 尚未完成 canonical execution-state normalization、reachable two-phase admission、strict artifact binding、bounded-memory comparator 與 atomic report validator。 |
| Lightroom Gate 2 4/4 | NOT RUN | 尚無四組同一 RAW 的 Lightroom neutral／XMP-applied paired 16-bit TIFF。 |
| Hold-out／production registry | NOT RUN | 尚無可審核 calibration artifact；production registry 必須保持空白。 |
| 效能／Mac／iPad／實體裝置 | NOT RUN | Gate 2 參考資料與實體裝置驗收尚未具備，不能宣告跨平台 parity。 |

後續禁止以 Exposure、tone、Presence、Curve、Detail 或單張照片特例補償差異；私人素材與絕對路徑只可留在未追蹤本機證據目錄。

## Production hardening implementation result（2026-09-21）

| Gate | 狀態 | 實際結果 |
| --- | --- | --- |
| P0 evidence freeze／ownership | PASS | CURRENT、report 與 handoff 已對齊；未 commit、push、merge、rebase 或修改 main。 |
| P1 canonical fail-closed recipe | PASS | effective native 時所有 derived execution state 回到 native；persisted Adobe policy 不被改寫。 |
| P2 strict artifact binding | PASS | manifest 驗證係數 digest、decoder identifier/version、option vector、工作色域、輸出轉換與 provenance schema；runtime mismatch 會拒絕 admission。 |
| P3 comparator／report hardening | PASS | comparator 移除 full-frame error/sorted/window 暫存；`--report` 使用 atomic JSON write，process test PASS。 |
| P4 regression/build/privacy | PASS | `swift test` 2477/14 skipped/0 failures；strict-concurrency、macOS bundle、iPad generic Simulator、matrix validator、diff/privacy gates PASS。 |
| P5 formal Lightroom 4/4 | NOT RUN | 四組 paired Lightroom 16-bit TIFF 尚未提供。 |
| P6 hold-out／production registry | NOT RUN | 沒有真實 training/hold-out evidence；registry 保持空白。 |
| P7 controlled rollout／physical iPad | NOT RUN | 尚未有可安全啟用 Adobe 的完整 gate evidence；實體 iPad 未安裝驗收。 |

## Execution start recheck (2026-09-22)

- Existing fail-closed implementation evidence is preserved. The feature flag remains disabled by default and both generated production registries remain empty.
- P4 automated tests/build/privacy evidence remains PASS from the prior run; full-resolution 6000x4000 peak RSS and wall-time measurement remains `NOT RUN`.
- The available private source corpus has five RAW inputs and five XMP inputs, but no paired Lightroom/LumaHarborPad TIFF references. Reference generation is therefore the next required step; formal 4/4, hold-out, calibration, Mac/iPad parity and physical-device smoke remain `NOT RUN`.
- No product code, private material, private path, filename, hash, commit, push, merge, rebase or main-branch mutation occurred in this recheck.

這一輪沒有宣告 Gate 2 通過，也沒有使用 Exposure、tone、Presence、Curve、Detail 或單張照片特例補償差異。

## Gate 2 execution evidence (2026-09-22)

- Task 1 process hardening: PASS. Eight process cases executed with zero skips and zero failures; unsafe report destinations (matrix, directory, symlink, and traversal into the reference root) returned non-zero without loading reference pixels.
- Task 2 streaming metrics: PASS. Tile heights 1, 4, and 7 matched the existing array metrics within `1e-9` for mean, P95, SSIM, and clipping deltas.
- Task 2 full-resolution synthetic process gate: PASS. A temporary 6000x4000 16-bit embedded-sRGB TIFF comparison completed with peak RSS `904167424` bytes (under the 1.5 GB budget) and aggregate wall time approximately 331 seconds. The test generated and removed its temporary inputs; no path, basename, or digest was retained here.
- Task 2A export preflight: PASS for existing automated TIFF contracts (54 tests: 50 `PhotoExportTests` and 4 `PadExportOptionsTests`). Actual Lightroom/LumaHarborPad paired references remain unavailable, so neutral 4/4 and hold-out admission are `NOT RUN`.
- Matrix template validation: PASS (`schema=2`, `cases=20`, sanitized stable IDs only).
- Adobe renderer remains disabled and production artifact registries remain empty.

## Gate 2 final verification (2026-09-22)

| Gate | 狀態 | 實際結果 |
| --- | --- | --- |
| Task 1 process hardening | PASS | 8 cases、0 skipped、0 failures；matrix／directory／symlink／reference-root traversal report destinations 均在讀取像素前拒絕。 |
| Task 2 bounded streaming metrics | PASS | tile height 1／4／7 與既有 array metrics 的四項指標差異均小於 `1e-9`。 |
| Full-resolution synthetic performance | PASS | 6000x4000、16-bit embedded-sRGB TIFF；peak RSS `904167424` bytes，小於 1.5 GB；aggregate wall time 約 331 秒；素材為暫存且未保留識別資訊。 |
| Task 2A export preflight | PASS | `PhotoExportTests` 50/50、`PadExportOptionsTests` 4/4；僅驗證既有自動化 TIFF contract。 |
| 完整 Swift tests | PASS | 2488 executed、15 skipped、0 failures。 |
| Strict concurrency／Mac bundle／iPad Simulator | PASS | 三項 build 均完成。 |
| Lightroom neutral 4/4／XMP target／hold-out | NOT RUN | 尚無同一批 RAW 的 Lightroom/LumaHarborPad paired 16-bit TIFF 與 hold-out evidence。 |
| Production registry／controlled enablement | NOT RUN | registry 維持空白，Adobe renderer 維持 fail closed。 |
| Mac/iPad pixel parity／實體 iPad | NOT RUN | 缺 paired references；本輪未宣稱實體裝置結果。 |
| Git/privacy hygiene | PASS | `git diff --check` 通過；本輪差異未加入私人素材、路徑、檔名或 hash。 |

**決策：READY ONLY WITH RENDERER DISABLED。** 必要的 Gate 2 4/4、hold-out、跨平台 parity 與實體 iPad 尚未完成，因此不得填入 production artifact registry 或開啟 Adobe renderer。

**實體 iPad 重試（2026-09-22）**：`xcrun devicectl list devices` 顯示一台已配對且可用的 iPad；但目前分支的 generic iOS device build 因 Xcode 錯誤「Signing for `LumaHarborPad` requires a development team」失敗。未安裝或宣稱實機結果，physical iPad acceptance 維持 `NOT RUN`；不修改 signing identity。

## Private neutral export smoke（2026-09-22）

本節只記錄去識別化的本機驗證結果，不構成 Gate 2 admission，也不保存私人檔名、路徑、hash 或影像內容。

| 項目 | 狀態 | 實際結果 |
| --- | --- | --- |
| 真實 RAW 16-bit TIFF export preflight | PASS | 目前提供的 4 張 Sony ARW 全數匯出成功；輸出為 16-bit、7008×4672、embedded sRGB、無 Alpha。 |
| Lightroom neutral 對 Luma neutral | FAIL | `neutralDirect` 4/4 均完成比較但未達 thresholds；沒有把 FAIL 改寫成 NOT RUN。 |
| clipping thresholds | PASS | 四張的 highlight／shadow clipping delta 均在 v2 門檻內；其他像素差異指標仍失敗。 |
| XMP preset effect／final direct | NOT RUN | 尚未取得每張 RAW 對應的完整 Lightroom XMP-applied paired TIFF。 |
| hold-out／calibration／production registry | NOT RUN | neutral baseline 尚未通過，故不進入校正、hold-out 或 registry admission。 |

`neutralDirect` 的 4 張聚合指標（僅保留數值，不保留素材識別）為：mean absolute error 約 `0.3333–0.3478`、P95 約 `0.7772–0.8164`、luminance SSIM 約 `0.0094–0.0123`。這表示目前 Lightroom 與 native LumaHarbor 的 RAW baseline 仍有實質顯色差異，不能用 Exposure、tone、Presence、Curve、Detail 或單張照片特例補償。

因此最新決策仍是 **READY ONLY WITH RENDERER DISABLED**：Adobe feature flag 維持關閉，production artifact registries 維持空白；本次新增的 TIFF RGB container 修正只解決輸出格式 Alpha mismatch，不代表 renderer parity 已通過。

## Latest regression verification（2026-09-22）

- `swift test`：2491 executed、16 skipped、0 failures。
- TIFF RGB container focused tests：2/2 PASS（8-bit／16-bit 均無 Alpha channel；16-bit precision 保留）。
- Private RAW fixture suite：10/10 PASS（包含 4 張真實 RAW 的 16-bit TIFF export preflight）；XMP fixture suite：5/5 PASS。
- strict-concurrency build、macOS app bundle、iPad generic Simulator build、matrix validator 與 `git diff --check`：PASS。
- 實體 iPad 仍為 `NOT RUN`；Mac 鎖定／CoreDevice 或 signing 限制下未宣稱實機驗收。

## 16-bit byte-order correction and neutral rerun（2026-09-22）

先前「Private neutral export smoke」所列的 `neutralDirect` 數值已被本節取代，不得再作為 Gate 2 證據。根因是 16-bit TIFF reader 以 big-endian bitmap context 寫入 host-endian `UInt16` buffer，之後又直接以 host byte order 讀值，導致真實 TIFF sample 發生 byte swap；既有 synthetic fixture 使用相同錯誤 byte order，因此先前未能暴露問題。

- 修正後的 reader／streaming focused tests：8/8 PASS；process-level CLI tests：9/9 PASS，並新增已知 16-bit sample error magnitude 的端到端契約。
- 同一批去識別化、全尺寸 16-bit embedded-sRGB neutral references 已重新執行 4/4；四組皆完成比較，但仍未達 Gate 2 thresholds。
- 修正後聚合範圍：mean absolute error 約 `0.0555–0.1173`、P95 約 `0.1871–0.4836`、luminance SSIM 約 `0.2847–0.6621`。Highlight／shadow clipping delta 4/4 PASS，但不代表整體像素 parity 通過。
- 完整 `swift test`：2493 executed、2 skipped、0 failures。Strict-concurrency build、macOS app bundle、iPad generic Simulator build、公開矩陣 validator 均 PASS。
- XMP effect／final、hold-out、production registry、Mac/iPad pixel parity 與實體 iPad 驗收仍為 `NOT RUN`。

**決策仍為 READY ONLY WITH RENDERER DISABLED。** Adobe renderer 維持 fail closed，production registries 維持空白；不得以 Exposure、tone、Presence、Curve、Detail 或單張照片特例補償目前差異。

## Layer isolation and independent hold-out（2026-09-22）

本節延續 byte-order 修正後的同一批去識別化 reference。所有私人來源、輸出、檔名、路徑、hash 與係數均留在 Git 外。

| 單一變因 | Formal 4/4 | Hold-out | 結論 |
| --- | --- | --- | --- |
| 舊 decoder 強制向量 | FAIL | FAIL | 會覆蓋 per-RAW defaults，MAE 約 `0.3334–0.3401`、P95 約 `0.7768–0.7935`、SSIM 約 `0.0092–0.0111`，拒絕。 |
| 保留 per-RAW decoder defaults | FAIL | FAIL | Decoder pixels 與 Native 5/5 完全一致，移除了人為惡化，但 Lightroom neutral parity 仍未通過。 |
| 只切換 linear Display P3 工作域 | FAIL | FAIL | 指標變動極小且方向不一致，無法解釋 baseline 差異。 |
| Linear Display P3 camera matrix | FAIL | FAIL | Training RMSE 約改善 2.2%，但 4/4 未過；hold-out MAE 約 `0.0921`、P95 約 `0.3306`、SSIM 約 `0.6534`，highlight clipping delta 約 `0.1196`。Artifact 拒絕。 |

校正工具現要求每筆 paired sample 明確帶有 `colorDomain=linear-display-p3-v1`。舊格式缺少 domain，或直接提供 encoded-sRGB 數值，均會在矩陣求解前 fail closed。這項合約只防止錯誤校正資料進入 pipeline，不代表目前已有可接納的 Adobe camera profile。

**Gate 結果：formal neutral 4/4 = FAIL；independent hold-out = FAIL；production artifact admission = REJECTED。** Adobe renderer 繼續 fail closed，production registries 維持空白。

## Layer-isolation regression verification（2026-09-22）

- Calibration domain／artifact focused suites：12/12 PASS。
- 私人 RAW fail-closed／preserve-defaults suite：3/3 PASS；私人 XMP fixture suite：5/5 PASS，兩者均以 Git 外環境注入且無 skip。
- 完整 `swift test`：2496 executed、17 skipped、0 failures。一般完整套件不注入私人素材；上述兩個 focused runs 是對應 evidence。
- Strict-concurrency build、macOS app bundle、iPad generic Simulator build、公開矩陣 validator（schema v2、20 cases、80 references）：PASS。
- `git diff --check`、private-material status scan、changed-diff privacy scan、obsolete decoder vector ID scan：PASS。
- 實體 iPad：`NOT RUN`。Task 5 已因 4/4 與 hold-out FAIL 觸發停止條件，不進入 renderer enablement／device admission。

**最終決策不變：READY ONLY WITH RENDERER DISABLED。**
