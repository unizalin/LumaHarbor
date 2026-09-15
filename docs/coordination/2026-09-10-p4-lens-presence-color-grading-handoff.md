# Handoff: P4 Lens, Presence, Color Grading, Black & White, Rendering Profile

Follows `docs/coordination/HANDOFF_TEMPLATE.md`.

## Status

`DONE_WITH_CONCERNS`

## Git state

- Source branch: `claude/professional-editing-completion`
- Base for this phase: `2089d86` ("docs: record P3 per-channel tone curves completion and handoff")
- Implementation and handoff commits: see immediately following commits on this branch.
- Push, merge, rebase: none occurred.

## Changes

### New files (models)

- `Sources/RawProcessingCore/Model/PresenceAdjustments.swift` — texture/clarity/dehaze, -100...100 each.
- `Sources/RawProcessingCore/Model/ColorGradingAdjustments.swift` — `ColorGradeBand` (hue 0...360, saturation 0...100, luminance -100...100) × shadows/midtones/highlights/global, plus balance (-100...100) and blending (0...100, default 50).
- `Sources/RawProcessingCore/Model/MonochromeAdjustments.swift` — `isEnabled` + 8 band mixes (-100...100); `isIdentity` depends only on `isEnabled`, so disabling never discards queued mix values and never affects colour tools that ran earlier in the chain.
- `Sources/RawProcessingCore/Model/RenderingProfileSelection.swift` — `profileID`/`amount`/`fallbackReason`, plus `RenderingProfileCatalog` (4 built-in profiles: standard/vivid/flat/portrait, each a small set of contrast/saturation/shadow/highlight deltas layered onto existing primitives).
- `Sources/RawProcessingCore/Model/LensCorrectionAdjustments.swift` — `LensCorrectionMode` (off/automatic/manual/bundledProfile) + distortion/vignetting/tca amounts; `LensProfileDatabase.match(...)` — ships with zero bundled profiles and always returns `nil` (see Concerns).

### New files (UI)

- `Sources/AdjustmentUI/PresenceAdjustmentPanel.swift`, `ColorGradingAdjustmentPanel.swift`, `RenderingProfilePanel.swift`.

### New spec/plan

- `docs/superpowers/specs/2026-09-10-lens-presence-and-color-grading.md` — includes a mid-implementation revision recorded inline: the original plan's 33 granular `AdjustmentFieldID` cases for the 5 new groups was replaced with a mix of 3 granular (Presence, which has real native XMP mappings) + 4 whole-value leaves (ColorGrading/Monochrome/RenderingProfile/LensCorrection, which don't), matching the existing `.advancedToneCurve` precedent. Reasoning is in the spec's §7.
- `docs/superpowers/plans/2026-09-10-lens-presence-and-color-grading.md`.

### Modified — model plumbing

- `Sources/RawProcessingCore/Model/PhotoAdjustments.swift` — 5 new fields, all with neutral defaults and graceful missing-key decode (P0-era convention).
- `Sources/RawProcessingCore/Model/AdjustmentMapping.swift` — `RenderParameters` carries all 5 new groups plus their own `isXIdentity` flags.
- `Sources/PresetCore/Model/AdjustmentFieldID.swift` — `presenceTexture/presenceClarity/presenceDehaze` (granular) + `colorGrading/monochrome/renderingProfile/lensCorrection` (whole-value leaves).
- `Sources/PresetCore/Model/AdjustmentPatch.swift`, `PhotoAdjustmentsFieldAccess.swift`, `XMP/XMPImportExport.swift` (`AdjustmentPatchBuilder`), `Application/PresetApplicator.swift` — every exhaustive `switch` over `AdjustmentFieldID` updated (the compiler forced most of these; `PresetApplicator.apply` and its own dedicated regression test, `PresetApplicatorTests.testEveryFieldIDReachesTheAppliedResult`, are the one non-exhaustive-switch call site the P0 review already flagged as needing manual attention for every new field, and this phase confirmed that test still catches a genuinely missed wiring step — it did, twice, during this phase's own development).
- `Sources/PresetCore/XMP/XMPMappingRegistry.swift` — three new native mappings: `crs:Texture` → `.presenceTexture`, `crs:Clarity2012` → `.presenceClarity`, `crs:Dehaze` → `.presenceDehaze`, all `.approximate` level (P4 spec §5.1: this render is a documented simplification of Adobe's own algorithm).

### Modified — render (`Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift`, `Kernels/AdjustmentKernels.metal`)

- **Lens correction**: new first pipeline stage (before Exposure), manual/bundledProfile modes only. `.automatic` is handled entirely inside `CoreImageRawDecoder` (`isLensCorrectionSupported`/`isLensCorrectionEnabled`) — see `docs/coordination/DECISIONS.md` D-007 for why manual/profile correction can't run strictly before white balance the way design spec §8 step 2 idealizes (white balance is baked into `CIRAWFilter`'s demosaic before any post-decode hook exists). Distortion uses `CIPinchDistortion`/`CIBumpDistortion` (stock filters, no custom warp kernel — deliberate risk-avoidance choice, spec §1 item 3); vignetting reuses the existing artistic `Vignette`'s `CIRadialGradient`-multiply technique with a single amount; TCA scales isolated R/B channel layers by a uniform affine transform in opposite directions (a documented simplification — real lateral CA grows with radius, this doesn't).
- **Presence**: texture/clarity share one `applyLocalContrast` helper (positive → `CIUnsharpMask`, negative → `CIGaussianBlur`, different radii); dehaze uses `CIColorControls` contrast+saturation.
- **Color Grading**: extracted `flatColor`/`balancedLuminanceMask` out of the existing `applySplitToning` into shared private statics (no behavior change — full pre-existing split-toning test suite still passes unchanged), then built a genuine 3-zone (shadow/midtone/highlight weight derived from the shared luminance mask) + global implementation. Each zone's flat colour is soft-lit against the *original* image individually before being spatially blended in, specifically because `soft-light(0.5 grey, x) == x` is an unconditional identity — a first draft that instead built one hard-blended composite of all zones and soft-lit *that* once at the end leaked grey into a dark pixel when only Highlights was set, because the per-zone masks don't sum to a clean complement the way Split Toning's original 2-zone masks do. See the golden-pixel tests and the function's own doc comment for the fix.
- **Monochrome**: new `monochromeMixer` Metal kernel, reusing `hslAdjust`'s triangular hue-band falloff weighting (same 8 centers, same `halfWidth`) to blend each band's mix into a Rec.709-luma-based grayscale output. Achromatic pixels keep `mixShift == 0` (map straight to their own luma), extended-range highlights aren't upper-clamped, matching `hslAdjust`'s and `advancedToneCurve`'s own conventions.
- **Rendering Profile**: blends `RenderingProfileCatalog` coefficients onto `CIColorControls` (contrast/saturation) and, for flat/portrait, a synthetic `PhotoAdjustments(highlights:shadows:)` run through the existing `ToneCurveMapping.controlPoints(for:)`/`applyToneCurve` rather than inventing a second tone-curve mechanism.
- Render order within the existing perceptual stage: Vibrance → Presence → Advanced curve → HSL → Color Grading → Monochrome → Rendering Profile → Split Toning (design spec §8 step 5's "Presence、HSL、Color Grading、Monochrome、Rendering Profile" group, in that relative order; Split Toning is the group's own pre-existing tool run after all of them).

### Modified — decode (`Sources/RawProcessingCore/Decoding/RawDecoding.swift`, `CoreImageRawDecoder.swift`; `Preview/CoreImagePreviewRenderer.swift`; `Export/PhotoExporter.swift`)

- `RawDecodeRequest` gained `lensCorrection: LensCorrectionAdjustments`; both the interactive preview and export decode-request builders now pass `request.adjustments.lensCorrection`/`request.adjustments.lensCorrection` through. `LensCorrectionAdjustments.decoderShouldEnableLensCorrection` (pure, unit-tested) separates the mode→setting mapping from the actual `CIRAWFilter` side effect, which stays untestable without a real RAW file (same convention this codebase already uses for every other `CoreImageRawDecoder` behavior).

### Modified — UI

- `Sources/AdjustmentUI/InspectorCatalog/{InspectorSectionID,InspectorCatalog}.swift` — two new sections, `presence` (submode `.light`, alongside Basic/Curve) and `colorGrading` (submode `.color`, alongside White Balance/HSL). `resetting(.geometry, in:)` now also clears `lensCorrection` (Lens Correction is mounted inside the Geometry UI group, so its shared "Reset Geometry" domain-reset action covers it too).
- `Sources/AdjustmentUI/ColorAdjustmentPanel.swift` — added a "Black & White" `DisclosureGroup` with the enable toggle and 8 mix sliders, shown only while enabled.
- `Sources/AdjustmentUI/GeometryAdjustmentPanel.swift` — added a "Lens Correction" `DisclosureGroup` (mode picker + distortion/vignetting/TCA sliders, shown only in manual/bundledProfile mode). The panel's existing "Reset" button now also resets `lensCorrection`, and its `disabled` condition checks both `geometry.isIdentity` and `lensCorrection.isIdentity`.
- `Sources/LumaHarborApp/Views/InspectorView.swift` — two new Mac `DisclosureGroup`s (Presence, Color Grading) alongside the existing seven; `RenderingProfilePanel` mounted at the top of the existing Basic group.
- 8-language `Localizable.strings` — 23 new keys (Texture/Clarity/Dehaze/Presence/Color Grading/Midtones/Global/Balance/Blending/Black & White/Lens Correction/Off/Automatic/Manual/Bundled Profile/Distortion/Vignetting/Chromatic Aberration/Rendering Profile/Standard/Vivid/Flat/Portrait/No Matching Profile). en/zh-Hant/zh-Hans/ja/ko/es/fr/de all hand-written. `Tests/LumaHarborAppTests/EightLanguageLocalizationGateTests.swift`'s `intentionalEnglishMatchAllowlist` gained a few genuine cross-language cognates (de "Standard"; fr "Standard"/"Portrait"/"Texture"; es "Manual") after that pre-existing gate (stricter than the P2-era zh-Hant-only check — it applies to all 8 languages) caught a first draft that had picked identical words for "Global"/"Balance" in German/French/Spanish where a real, distinct alternative existed (fixed to Gesamt/Général/General and Gleichgewicht instead of leaning on the allowlist for those two).

## Behavior changes

1. **New, real functionality**: Texture/Clarity/Dehaze, 3-zone Color Grading, an 8-band Black & White mixer, 4 built-in creative rendering profiles, and lens correction (automatic via the system decoder, or manual/bundled-profile geometric correction) are all live, renderable, and reachable from both platforms' shared Inspector catalog.
2. **iPad UI wiring is not part of this phase's changes.** The P2 catalog already routes iPad through `InspectorCatalog.allSections`/`sections(in:)`, so the two new sections and updated Geometry/Color sections are *data-model-visible* to iPad's existing `PadInspectorHost`/`PadToolRail` machinery, but no iPad-specific panel-mounting code was added or verified this phase (see Concerns).
3. **No behavior change** for existing Split Toning, HSL, curve, or any P0-P3 render path — the `flatColor`/`balancedLuminanceMask` extraction was verified against the full pre-existing test suite with zero new failures.

## Verification

- New/changed test files RED→GREEN throughout, one function group at a time. Real bugs caught and fixed before GREEN:
  - `applyColorGrading`'s hard-blend-then-single-soft-light draft leaked grey into a dark pixel when only one zone was set (caught by `testHighlightColorGradingDoesNotVisiblyTintADarkPixel`); fixed by soft-lighting each zone against the original image individually before spatial blending (see the function's own doc comment for the identity this relies on).
  - `PresetApplicator.apply` initially didn't wire the 4 new whole-value leaves through at all (caught by the pre-existing, deliberately-generic `testEveryFieldIDReachesTheAppliedResult`).
  - `EightLanguageLocalizationGateTests`'s pre-existing allowlist gate caught 9 identical-to-English translations across de/fr/es on the first localization pass; fixed with either a genuinely distinct word or (for real cognates) an allowlist entry.
- `swift test` (full suite) → **PASS**. 2150 executed, 9 skipped, 0 failures, stable across 3 consecutive runs.
- **One non-reproducible crash investigated and resolved as stale incremental-build state, not a code defect**: mid-phase, `swift test` intermittently produced a SIGSEGV or SIGBUS crash in unrelated, unmodified tests (`CurationDurabilityTests`, then later `XMPImportExportTests`). Both times, the exact same filtered test run was verified to (a) pass cleanly on the P3 baseline via `git stash`, (b) still crash reproducibly with the P4 diff applied via incremental build, and (c) pass cleanly and stayed clean across repeated runs once `swift package clean && swift build --build-tests` produced a from-scratch build. This is now the second time this exact class of environment flake has appeared in this branch's history (the P3 handoff recorded a similar one-off "2 failures" case that didn't reproduce); recorded here for whoever next hits it, with the specific fix (`swift package clean` before re-investigating, not just re-running) documented since a bare re-run alone did not previously make it obvious this was a build-cache issue rather than a logic bug.
- `swift build -Xswiftc -strict-concurrency=complete` → **PASS**, exit 0.
- `xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` → **PASS**, `** BUILD SUCCEEDED **`.
- `git diff --check` → **PASS**, no whitespace errors.
- Privacy scan (`git diff` over all changed/new tracked files, plus a direct scan of every new untracked file) for `/Users/…`, `/Volumes/…`, `DEVELOPMENT_TEAM=`, private-key headers → **PASS**, no hits.

Not run in this task (genuinely unavailable, carried forward unchanged from every prior phase):

- `Scripts/run-mvp-acceptance.zsh` — **NOT RUN**. Requires exported private RAW/APFS/exFAT fixtures.
- Real M1+ iPad / Apple silicon Mac manual UI verification — **NOT RUN**. No device/Simulator UI interaction tool in this environment. This phase specifically needs verification of: the two new Mac `DisclosureGroup`s' layout at the documented 280pt Inspector minimum width; the Geometry panel's new Lens Correction sub-group not crowding the existing Crop/Straighten controls; the Color panel's new Black & White toggle+8-sliders group; VoiceOver reading order through all of the above; and — most importantly, since this is a real, uninvestigated gap — **whether the iPad `PadInspectorHost`/`PadToolRail` actually surface the two new catalog sections and the updated Geometry/Color content at all**, since no iPad-side panel-mounting code was touched this phase (see Concerns).
- Real RAW file test of `.automatic` lens correction mode (`CIRAWFilter.isLensCorrectionSupported`/`isLensCorrectionEnabled`'s actual visual effect) — **NOT RUN**, same standing limitation as the rest of `CoreImageRawDecoder`'s behavior.
- Real Lensfun profile data acquisition — **explicitly out of scope**, not merely deferred (see Concerns).

## Dirty files

None. `git status --short` is clean once this phase's commits land (verify after committing).

## Concerns and blockers

- **iPad panel mounting for the 5 new groups was not touched or verified this phase.** The shared `InspectorCatalog` already declares the two new sections and the updated Geometry/Color content, so iPad's *search*, *favorites*, and *section list* should already reflect them (those read `InspectorCatalog.allSections` directly, per P2). But whether `PadInspectorHost`/`PadToolRail` actually *render* a working `PresenceAdjustmentPanel`/`ColorGradingAdjustmentPanel`/Black & White toggle/Lens Correction picker when a user navigates to those sections on iPad was not verified — Mac's `InspectorView` was the only platform this phase mounted new panels into. Whoever picks up P5 (or a dedicated iPad-parity pass) should check this before treating P4 as fully cross-platform-complete; it may already work if iPad's existing submode-based content-switching is generic enough, or it may need explicit new cases added to iPad's own content-switch statements the same way Mac's `macGroup(for:)` needed them.
- **`LensProfileDatabase` ships with zero real profiles, by design** (see spec §1 item 1) — this is not a placeholder bug, `match` always returning `nil` is the correct "no matching profile" fallback the design spec itself requires. A future task that wants real Lensfun-derived bundled profiles needs to acquire that licensed (CC BY-SA 3.0) data through a channel this environment doesn't have (no verified network fetch), then populate the backing table `LensProfileDatabase.match` reads from — the matching contract itself should not need to change.
- **Geometric lens correction (distortion/TCA) uses stock Core Image filters, not a literal Lensfun polynomial model**, and TCA specifically uses a uniform (non-radius-varying) channel scale. Both are documented, deliberate simplifications (spec §1 item 3) made specifically to avoid the risk of writing an unverifiable custom `CIWarpKernel` in an environment with no way to visually confirm it. Real-world correction accuracy against an actual distorted lens has not been (and cannot be, in this environment) verified.
- **Color Grading's "Blending" control is a spatial mask blur, not Lightroom's own falloff-curve steepness control** — a documented approximation (spec §5.2), functionally real (it does soften zone transitions) but not a literal match.
- **Test-count note**: this phase added many more tests than P3's shortfall (exact final delta wasn't tallied against a fixed target the way P3's spec set one, since this spec's own §12 didn't set a numeric floor after the mid-implementation field-ID-count revision) — every model, render, XMP, and catalog change has direct test coverage; no padding.
- **Carried forward, unchanged from every prior phase**: `Scripts/run-mvp-acceptance.zsh` and real-device manual QA remain `NOT RUN`.

## Next action

Start P5, "Advanced Masks, AI Repair and Perspective" (design spec §16 item 5 — file `2026-09-10-advanced-masks-ai-repair-and-perspective.md` does not exist yet). P5's prerequisite is P3 (complete); per the dependency graph in design spec §9 it does not depend on P4, but this branch's actual sequence does P4 first. Before starting, resolve or explicitly re-scope this handoff's iPad-mounting concern (above) if P5's own mask UI work will also touch iPad's Inspector — doing so once, deliberately, for both gaps together may be more efficient than two separate iPad passes. Design spec §6.5 requires every mask type to be non-destructive/undoable/offline; on-device AI (subject/background) must use only `Vision` framework capabilities already on the device, with an explicit, tested fallback path when unsupported or when inference fails — no downloaded models, matching this branch's now well-established "ship the real fallback, not a placeholder" pattern from `LensProfileDatabase` above.

## Suggested skills

- `test-driven-development` — this phase's two real bugs (Color Grading's grey leak, `PresetApplicator`'s missing wiring) were both caught by tests written *before* the fix, not discovered by manual reasoning after the fact.
- `verification-before-completion` — before claiming P5 complete, rerun the same verification matrix as this handoff, and if `swift test` produces an unexplained crash, try `swift package clean` before assuming it's a real regression (see this handoff's Verification section).
- `handoff` — use again when phase ownership changes, and to close the iPad-mounting gap this handoff flags once it's addressed.
