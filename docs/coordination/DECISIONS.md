# Cross-Agent Decisions

This file is append-only. When a decision is replaced, retain the original entry and add a link to the replacing decision.

## D-001 — Git-backed Markdown is the shared coordination source

- Date: 2026-08-31
- Decision: Project rules, current validated state, durable decisions, and handoff requirements live in committed Markdown.
- Reason: Both Codex and Claude can read the same versioned content without sharing internal tool state.
- Impact: Chat summaries and temporary files may assist a session but are not authoritative project state.

## D-002 — Agents edit through separate worktrees

- Date: 2026-08-31
- Decision: Codex and Claude use separate branches and worktrees whenever either agent edits files.
- Reason: Concurrent writes in one worktree can overwrite uncommitted user or agent changes.
- Impact: If a worktree is shared, one agent is the sole writer and the other is review-only.

## D-003 — `CURRENT.md` records the last validated baseline

- Date: 2026-08-31
- Decision: `CURRENT.md` records the full SHA of the latest fully validated product/evidence commit, not the SHA of the commit containing `CURRENT.md` itself.
- Reason: A file cannot contain its own final Git commit SHA without creating recursive self-reference.
- Impact: Coordination-only commits after the recorded baseline must be inspected before product editing begins.

## D-004 — Evidence states remain distinct

- Date: 2026-08-31
- Decision: `PASS`, `FAIL`, `SKIPPED`, and `NOT RUN` are recorded as separate states.
- Reason: Unavailable fixtures or hardware do not prove product behavior.
- Impact: Final sign-off remains blocked while any required real-device gate is `NOT RUN`.

## D-005 — Local settings and sensitive data stay outside coordination commits

- Date: 2026-08-31
- Decision: Credentials, chat state, private fixture paths, private absolute paths, tool caches, and local Xcode signing changes are not committed as shared coordination data.
- Reason: The agents need shared project facts, not shared identity or machine-private state.
- Impact: Handoffs use repository-relative paths and redact private filesystem details.

## D-006 — Sidecar schema v3 ships without `snapshots`

- Date: 2026-09-10
- Decision: `PhotoSidecar.currentSchemaVersion = 3` adds `curation` only. The approved professional editing completion spec's §6.1 bundles `curation` and `snapshots` into one version bump; `docs/superpowers/plans/2026-09-10-curation-sidecar-v3-and-migration.md` implements P1 only (curation) and defers `EditSnapshot`/`snapshots` to P6, where it will ship as its own schema version.
- Reason: The task authorizing that plan explicitly excludes P2 and later phases, including P6 (Snapshot). Defining `EditSnapshot` now, only to satisfy a version-number bundling in the spec text, would be scope creep with no test coverage or consumer.
- Impact: A future P6 plan bumps `PhotoSidecar.currentSchemaVersion` again (to 4) when it adds `snapshots`; that plan must re-verify v1/v2/v3 sidecars all still decode.

## D-007 — P4 manual/profile lens correction runs after decoder-baked white balance, not literally before it

- Date: 2026-09-11
- Decision: The professional editing completion design spec's §8 canonical render order lists "Lens correction" as step 2, before "White balance, exposure" (step 3). `CoreImageRawDecoder` already bakes white balance into `CIRAWFilter`'s demosaic (`filter.neutralTemperature`/`neutralTint`, set before `outputImage` is read) — there is no post-decode hook that runs before that baking. Automatic mode (`CIRAWFilter.isLensCorrectionSupported`/`isLensCorrectionEnabled`) genuinely runs at decode time, before/alongside white balance, matching the spec exactly. Manual and bundled-profile mode correction (geometric distortion, vignetting, TCA), which cannot use `CIRAWFilter`'s internal correction, instead runs as the first stage of `AdjustmentPipeline.apply`, immediately after the decoder's already-white-balanced output.
- Reason: White balance is a uniform per-channel gain applied during demosaic; it is not achievable to defer it until after a post-decode filter without re-implementing demosaicing. A uniform gain commutes with geometric warps and per-channel radial scaling to first order, so the visual difference between the spec's idealized ordering and this implementation is negligible. Re-deriving RAW decoding to expose a pre-white-balance geometry hook is out of scope for P4 and would risk the decoder's own correctness guarantees.
- Impact: P4's spec and its golden-pixel render tests document this explicitly rather than silently matching the letter of §8. Any future phase that revisits RAW decoding architecture should re-check whether a true pre-white-balance hook becomes available and, if so, migrate manual/profile lens correction to it as a non-breaking render-order change (with a new golden-image regression test per §8's own rule that any order change is a compatibility change).

## D-008 — Codex, Claude, and Gemini use one shared read protocol

- Date: 2026-09-12
- Decision: `docs/coordination/SHARED_AGENT_READ_PROTOCOL.md` is the single cross-agent protocol for startup reading order, source precedence, evidence labels, privacy scanning, Git safety, and handoff output. `AGENTS.md` remains the stable project-rule entrypoint; `CLAUDE.md` imports it; `GEMINI.md` is an entrypoint that does not define a second rule set.
- Reason: Separate agent-specific instructions caused inconsistent baselines, duplicated reading protocols, and a risk that an agent would treat a stale handoff or partial spec as the current product state.
- Impact: Every agent must begin with the same Git/status snapshot and shared documents. The former Gemini protocol remains only as a compatibility reference. Any future change to the shared workflow must update the shared protocol and this append-only decision log together.

## D-009 — `origin/main` is the sole integrated baseline; agent branches are task-scoped

- Date: 2026-09-16
- Decision: Codex、Claude 與 Gemini 的新工作都從當時最新的 `origin/main` 建立獨立短期 branch/worktree，分別使用 `codex/<task>`、`claude/<task>`、`gemini/<task>`。不再以 `*-latest`、`*-current` 或任何長期代理分支表示最新版，也不把所有歷史 branch 強制移動到 `main`。
- Reason: 多個長期代理分支與舊 worktree 會讓 branch 名稱看起來像不同最新版，且歷史重寫後 SHA 無法只靠名稱或日期判斷。單一整合基準加上 task-scoped worktree 能保留差異、避免覆蓋 dirty files，並讓三個代理使用同一個起點。
- Impact: `origin/main` 是唯一正式版本；舊 branch/worktree 只作為 snapshot 或未整合工作保留。開始新任務前必須遵循 `docs/coordination/SHARED_GIT_WORKFLOW.md`；更新、整合或清理既有 branch/worktree 仍需先保全獨有內容並取得使用者明確授權。

## D-010 — iPhone joins the universal iOS app through a dedicated mobile shell

- Date: 2026-09-17
- Decision: iPhone 與 iPad 使用同一個 Universal iOS App、服務與資料層。iPhone 首版採行動編輯器範圍，以全螢幕畫布和單一工具工作區呈現共享 Inspector 內容；不建立第三份調整實作，也不把 iPad 可移動浮動面板縮到手機。既有 Local Adjustments 在 iPhone 必須渲染並保存，但首版僅顯示唯讀摘要。
- Reason: 共用核心已能承載手機，但現有 iPad Inspector 尚有 standalone／inlined 雙份來源。先整併來源並共享 Inspector composition，可避免三平台在欄位、狀態與調整行為上漂移；手機另用符合有限畫面與單手觸控的殼層，才能保留照片作為主要內容。
- Impact: 實作依 `docs/superpowers/specs/2026-09-17-cross-device-workspace-and-iphone-editor-design.md` 分成獨立 Phase。Phase 0 必須先完成 iPad 來源整併；後續才可啟用 phone device family。Mac、iPad、iPhone 共用 catalog、editing state 與資料契約，但可使用不同平台容器與密度。

## D-011 — Public releases use semantic versions

- Date: 2026-09-28
- Decision: Public releases use `MAJOR.MINOR.PATCH` as the product version. The current public version is `0.1.0`; internal build `3` remains separate deployment metadata for Mac and iPad.
- Reason: Product names and public archive names must remain stable and understandable, while Apple deployment metadata still needs a synchronized, positive build number.
- Impact: Public artifacts use only the product version. Technical evidence records product version, internal build, and tested commit separately. Repeated distribution requires a patch bump rather than reusing the same public version with a different build.

## D-012 — Mainline integration adopts Sidecar v5 for brush-mask coexistence

- Date: 2026-10-05
- Decision: The mainline integration target raises `PhotoSidecar.currentSchemaVersion` to v5. It reads v1–v5, preserves unknown data, rejects v6+ without overwrite, and writes v5 at the shared effective-save boundary. The v5 contract includes `adjustments.brushMasks` while retaining curation and snapshots.
- Reason: Mainline already carries the v4 snapshot contract; the integration must add brush-mask data without reverting to the source experiment's v3 or discarding mainline fields.
- Impact: Curation migration and snapshot deletion paths must be rechecked against v5. Existing v3 decision D-006 remains historical and is not rewritten; no source signing or private fixture state enters the target.

## D-013 — Legacy local brush and new brush masks coexist independently

- Date: 2026-10-05
- Decision: Existing `LocalAdjustmentKind.brush` / `LocalAdjustmentGeometry.brushStrokes` remain unchanged. New ordered `PhotoAdjustments.brushMasks` use their own model, coordinate mapping, render stage, preview/export wiring, and persistence; both may be present and render once each.
- Reason: The two brush systems have different data contracts and compatibility histories. Reinterpreting or automatically converting the legacy local brush would risk data loss and alter established rendering semantics.
- Impact: Integration tests must cover side-by-side persistence, rendering, undo/snapshot behavior, and removal of one system without mutating the other. No automatic legacy conversion or XMP mapping is introduced.
