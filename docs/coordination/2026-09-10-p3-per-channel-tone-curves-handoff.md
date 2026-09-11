# Handoff: P3 Per-channel Tone Curves

Follows `docs/coordination/HANDOFF_TEMPLATE.md`.

## Status

`DONE_WITH_CONCERNS`

## Git state

- Source branch: `claude/professional-editing-completion`
- Base for this phase: `acb30d43d75393c77e99c94ef12c1f6c38c95531` (P2 handoff metadata correction)
- Implementation commit: `75c1887` ("feat: add per-channel tone curves (P3)"), 28 files changed, 913 insertions, 62 deletions.
- This handoff and the `CURRENT.md` update land in a following coordination-only commit.
- Push, merge, rebase: none occurred.
- This session resumed a prior token-limit interruption; `docs/coordination/2026-09-10-p3-token-checkpoint.md` recorded that interruption's state and has been deleted now that the phase is complete (it was untracked scratch state from this same task, not a separate agent's work).

## Changes

### New files

- `docs/superpowers/specs/2026-09-10-per-channel-tone-curves.md` — the P3 spec (authored before code), covering the `AdvancedToneCurve` model, the RGBA LUT composition math, the Metal kernel change, XMP mapping for `crs:ToneCurvePV2012Red/Green/Blue`, Preset schema v2, and the Mac/iPad UI.
- `docs/superpowers/plans/2026-09-10-per-channel-tone-curves.md` — the file-by-file implementation plan.

### Modified — model and render

- `Sources/RawProcessingCore/Model/AdvancedToneCurve.swift` — added `redPoints`/`greenPoints`/`bluePoints` (each independently sanitised, same as the existing `points`), a new `ToneCurveChannel` enum (`.composite/.red/.green/.blue`), and `points(for:)`/`isIdentity(for:)`/`settingPoints(_:for:)`/`resetting(_:)`. `isIdentity` now requires all four channels empty. JSON: the three new keys default to `[]` when absent, so v1/v2 sidecars and presets decode unchanged.
- `Sources/RawProcessingCore/Pipeline/AdvancedToneCurveLUT.swift` — added `buildCombined(compositePoints:channelPoints:resolution:)`, composing a per-channel curve after the composite curve (fixed order per design spec §8 step 4). Returns the composite table directly when the channel is identity (exact, no quantisation); otherwise looks up the channel table by the composite table's own value, rounded to the nearest index.
- `Sources/RawProcessingCore/Kernels/AdjustmentKernels.metal` — `advancedToneCurve` kernel's three `lut.sample(...)` calls now read `.r`/`.g`/`.b` respectively instead of all three reading `.r`, matching the new RGBA-packed LUT texture. Signature unchanged.
- `Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift` — `applyAdvancedToneCurve` now builds three combined tables (`buildCombined` for red/green/blue against the shared composite curve) and packs them into one RGBA8 `CIImage` via the renamed `makeLUTImage(red:green:blue:)`. Still one kernel `apply` call.

### Modified — Preset/XMP

- `Sources/PresetCore/Model/PresetDocument.swift` — `currentSchemaVersion` raised from `1` to `2`. No other change; `validated()`'s existing bounds check already accepts v1 files, and `AdvancedToneCurve`'s own `Codable` conformance is what makes the missing per-channel keys degrade to identity.
- `Sources/PresetCore/XMP/XMPImportExport.swift` — added `XMPImporter.toneCurveChannel(for:)` (maps each of the four `crs:ToneCurvePV2012*` property IDs to a `ToneCurveChannel`), `importToneCurvePoints(_:)` (channel-agnostic point parser; `importToneCurve(_:)` is now a composite-only wrapper kept for its one existing caller, `XMPMappingTests.testMalformedToneCurvePointErrorNeverEchoesTheRawXMPValue`), and `exportToneCurvePoints(_:)`. The importer loop now recognises all four properties and merges them into one `AdvancedToneCurve` via `settingPoints`, appending `.advancedToneCurve` to `nativeFields` at most once even when multiple channel properties are present. A malformed channel is isolated — it falls back to `preservedProperties` with its own `malformedToneCurve` diagnostic without blocking the other three channels. The exporter always writes Composite (even when empty, preserving pre-P3 byte-for-byte behaviour for composite-only presets) and writes Red/Green/Blue only when that channel is non-identity, so a composite-only preset gains no new empty properties.

### Modified — UI

- `Sources/AdjustmentUI/CurveAdjustmentPanel.swift` — the panel's private `ToneCurveChannel` enum was removed; the UI now uses `RawProcessingCore.ToneCurveChannel` directly (`.rgb` renamed `.composite`, same "RGB" localized label — Lightroom/Photoshop convention for the master curve, so no new label string was needed). `ToneCurveEditorModel.points(for:channel:)` gained a `channel` parameter defaulting to `.composite` for source compatibility with any caller that predates per-channel curves. The single "Reset" button was split into "Reset Channel" (resets only the selected Composite/R/G/B curve, disabled when that channel is already identity) and "Reset All" (resets the whole `AdvancedToneCurve`, disabled when the whole curve is identity) — both still route through `editor.updateAdjustments(_:)`, the same single-undo-per-gesture path every other reset in this codebase uses. `statusText` now reports the selected channel's own point count and identity state.
- 8-language `Localizable.strings` — added one new key, `"Reset Channel"`. `"Reset All"` already existed in all 8 languages from an earlier task and was reused unchanged. en/zh-Hant hand-written; the other 6 are real, Photoshop/Lightroom-consistent translations of "channel" (色版/通道/チャンネル/채널/canal/canal/Kanal), not English passthrough.

### Modified — tests only

- `Tests/AdjustmentUITests/AdjustmentGroupPanelsContractTests.swift`, `Tests/AdjustmentUITests/CurveHistogramContractTests.swift` — updated the two pre-existing source-contract assertions that checked for the single `Button(L10n.t("Reset")` string, now checking for both new button strings.

## Behavior changes

1. **New, real functionality**: Composite, Red, Green, and Blue tone curves are now independently editable and independently rendered — previously the R/G/B segmented control only changed the graph's stroke colour while writing to the same shared `points` array (P2 handoff's own "已驗證現況" table flagged this gap; it's what this phase closes).
2. **New**: per-channel reset ("Reset Channel") alongside the existing whole-curve reset (renamed "Reset All" in this panel, matching the key the rest of the app already used for other domain-reset buttons).
3. **XMP**: `crs:ToneCurvePV2012Red/Green/Blue` are now imported and exported. Previously these were silently preserved-but-unmapped, meaning a Lightroom preset with per-channel curves imported with those curves invisibly dropped rather than applied. A malformed value in one channel is isolated from the other three.
4. **No behavior change** for: composite-only curves (byte-identical XMP export, same `AdvancedToneCurve(points:)` semantics), batch sync, copy/paste, and undo — `.advancedToneCurve` was already a single whole-value field/leaf everywhere in `AdjustmentPatch`/`PhotoAdjustments`, so the three new arrays travel automatically with no new plumbing.

## Verification

All commands run in this worktree at the HEAD created by this phase's implementation commit.

- New/changed test files RED→GREEN, one file at a time, per TDD: `AdvancedToneCurveTests`, `AdvancedToneCurveLUTTests`, `AdjustmentPipelineTests` (3 new golden-pixel cases), `XMPImportExportTests` (4 new cases), `PresetDocumentTests` (3 new cases), `ToneCurveEditorModelTests` (2 new cases), `PhotoAdjustmentsTests` (2 new cases), `AdjustmentPatchExtractionTests` (2 new cases), `PresetApplicatorTests` (1 new case). Two implementation bugs were caught this way and fixed before GREEN:
  - `buildCombined`'s first draft round-tripped every sample through an index lookup even when the channel curve was identity, which quantised an exact composite value to the nearest `1/255` step for no reason (caught by `testBuildCombinedWithEmptyChannelEqualsCompositeAlone`). Fixed by returning the composite table directly when the channel is identity.
  - The first `testExportRoundTripsAllFourChannels` built a bare `PresetDocument(patch:)` with no `xmpEnvelope`/`ProcessVersion`, which `XMPExporter`'s `baseDocument(for:)` correctly refuses to treat as a recognised process version on reimport (this is existing, correct behavior, not a bug) — the test itself was wrong. Fixed by importing from an inline XMP fixture first (as every other round-trip test in this file does), so the preset carries a real `xmpEnvelope`.
- `swift test` (full suite) → **PASS**. 2068 executed, 9 skipped, 0 failures. Net +29 over the P2 baseline (2039 executed) — short of this phase's own spec target of "+32 minimum" (`docs/superpowers/specs/2026-09-10-per-channel-tone-curves.md` §7 item 4). The gap was left as-is rather than padded with low-value assertions: every added test in this phase closes a genuine gap (a new type, a new render path, a new XMP property, a new schema version, a new UI affordance, or a whole-value-field regression specific to per-channel data); there was no remaining untested surface area identified worth a 3-test top-up.
- One flake observed and not reproduced: a single `swift test` full-suite run reported "2 failures" with no further detail captured (output was truncated before the failure lines); the very next full-suite run, with no code changes in between, was clean (0 failures), and a third run afterward was also clean. Not chased further since it did not reproduce and no test in this phase touches timing, concurrency, or shared mutable state beyond what pre-existing, previously-green tests already touch. Flagged here for visibility, not as a known defect.
- `swift build -Xswiftc -strict-concurrency=complete` → **PASS**, exit 0, no warnings surfaced in output.
- `xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` → **PASS**, `** BUILD SUCCEEDED **`.
- `git diff --check` → **PASS**, no whitespace errors.
- Privacy scan: `git diff` over all changed/new tracked files plus a direct scan of the three new untracked doc files, for `/Users/…`, `/Volumes/…`, `DEVELOPMENT_TEAM=`, private-key headers, and bare UUIDs → **PASS**, no hits (one line in the plan document itself references the pattern `/Users/…` descriptively, as instructional text about what to scan for — not an actual path).

Not run in this task (genuinely unavailable, not skipped by choice, unchanged from every prior phase's handoff):

- `Scripts/run-mvp-acceptance.zsh` — **NOT RUN**. Requires exported private RAW/APFS/exFAT fixtures, not available in this environment.
- Real M1+ iPad / Apple silicon Mac manual UI verification of the new Reset Channel/Reset All buttons and the per-channel segmented curve editing — **NOT RUN**. No physical device or Simulator UI interaction tool was available in this environment. Recommend a manual pass before this is treated as fully done: dragging a point on Red/Green/Blue and confirming only that channel's preview changes, confirming "Reset Channel" vs "Reset All" disabled states track the correct scope, and confirming the two-button row still fits at the Mac Inspector's documented 280pt minimum width and the iPad Compact trailing-dock width (same open concern the P2 handoff raised for its own new controls, now with two more buttons added to the same row).

## Dirty files

None. `git status --short` is clean once this phase's commit lands (verify after committing).

## Concerns and blockers

- **Test-count shortfall against this phase's own spec target**: see Verification above. Judged not to warrant padding; flagged for whoever reviews this phase to confirm they agree with that judgment call.
- **Unreproduced test flake**: see Verification above. Worth a second look if it recurs, but not chased further this session since it did not reproduce.
- **No manual/visual verification of the new UI**: same standing gap pattern as every prior phase (P0 through P2) — this environment has no device/Simulator UI interaction tool.
- **Carried forward, unchanged from prior phases**: `Scripts/run-mvp-acceptance.zsh` and real-device manual QA remain `NOT RUN`.

## Next action

Start P4, "Lens + Presence + Color Grading" (design spec §16 item 4 — file `2026-09-10-lens-presence-and-color-grading.md` does not exist yet and must be authored first, matching how every prior phase authored its own plan/spec before coding). P4's prerequisite is P3 (this phase, now complete). Per the design spec §6.3/§6.4/§15: new `PresenceAdjustments` (texture/clarity/dehaze), `ColorGradingAdjustments` (shadows/midtones/highlights/global hue/saturation/luminance + balance/blending), `MonochromeAdjustments` (enabled + 8-colour mix), `RenderingProfileSelection` (profileID/amount/fallbackReason), and `LensCorrectionAdjustments` (mode/profileID/distortion/vignetting/TCA/manual fallback/enabled) all need models, render kernels, Preset/XMP mapping, batch policy, sidecar fields, and shared-catalog Mac/iPad UI wiring through the P2 `InspectorCatalog`. The lens correction source-of-truth ordering in design spec §6.4 (Off → Automatic/CIRAWFilter → bundled Lensfun-derived profile → manual fallback, never both Core Image and Lensfun at once) and the Lensfun database licensing/attribution requirement (§17: CC BY-SA 3.0 database only, not the LGPL library) should be read closely before starting — this is the largest and most novel piece of P4.

## Suggested skills

- `test-driven-development` — continue red/green, matching this phase's `buildCombined` and XMP round-trip bugs both being caught by tests before implementation was considered done.
- `verification-before-completion` — before claiming P4 complete, rerun the same verification matrix as this handoff.
- `handoff` — use again when phase ownership changes or when this phase's manual-verification gap is closed.
