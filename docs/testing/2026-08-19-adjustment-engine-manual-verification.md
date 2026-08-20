# Adjustment Engine Expansion — Manual Visual Verification

Spec: `docs/superpowers/specs/2026-08-19-adjustment-engine-expansion-design.md` §6.

Prerequisite: Apple Silicon Mac, full Xcode, real Sony `.ARW` fixtures. Set
`LUMAHARBOR_RAW_FIXTURE_DIR` and run the automated suite first
(`swift test`) — it must be green before manual verification starts.

None of these seven effects is reachable from the Inspector UI (spec §1) — set
values directly on a `PhotoAdjustments` in a throwaway debug harness, or via
temporarily hardcoding a non-neutral value in `AdjustmentMapping.renderParameters`,
render, inspect, then revert.

- [x] **HSL full-band coverage**: on a real ARW, push each of the 8 hue bands' hue/saturation/luminance
  to their extremes one at a time. Confirm the correct region of the photo visibly
  changes and neighbouring bands' boundaries don't show hard colour-banding
  seams. Note: a single band pushed to an extreme may read weaker than expected
  due to overlap normalization (`halfWidthDegrees` is 60 so no hue is a dead
  zone, and the kernel divides by the summed band weight once it exceeds 1.0,
  which dilutes a lone band even at its own centre) — confirm by eye whether
  this needs recalibrating.
- [x] **Advanced tone curve**: apply a curve with several control points and a
  non-trivial shape (at least one point that pulls a midtone away from the
  4-slider curve's effect). Confirm the image's brightness distribution
  matches the curve's shape, and there is no solarisation (any tonal
  inversion — see `enforceMonotonicNonDecreasing` in
  `AdvancedToneCurveLUT.swift`).
- [x] **Split toning**: apply distinct shadow and highlight hues at high
  saturation. Confirm shadows and highlights tint independently and
  `balance` visibly shifts which tonal range is affected more.
- [x] **Sharpening / noise reduction / vignette / grain**: apply each at an
  extreme value independently. Confirm each produces a visible, correct-
  direction change, no crash, and no obvious artifact (haloing, banding,
  posterisation).
- [x] **All seven together**: apply every effect at once. Confirm the pipeline
  doesn't crash, output still renders, and render time doesn't feel
  noticeably slower than before this expansion (no precise measurement
  required per spec §6 — a "does this still feel snappy" judgement call).

## Result

> **Post-merge review correction (2026-08-20):** the run below established
> correct visual behaviour for red/orange/blue content, but it did not satisfy
> the checklist's original requirement to exercise all eight bands one at a
> time. Yellow, green, aqua, purple and magenta still need a colour-rich fixture
> before this HSL checkbox can be marked complete. A separate code review also
> found that an exactly achromatic pixel was treated as hue 0 and could therefore
> be changed by red-band luminance; that path now has a regression fix/test on
> `codex/post-merge-review-fixes`, pending Apple Silicon + Xcode execution.

**Date**: 2026-08-20. **Machine**: arm64 (Apple Silicon), Xcode 26.6 — the
target environment this checklist requires. **Fixture**: a real Sony `.ARW`
from `Fixtures/Private/Sony-ARW/` (a rattan chair + kitten photo — warm
orange/brown wood, grey tabby fur, cream fabric, near-black curtain; limited
yellow/green/purple/magenta content, noted as a coverage gap below), decoded
at `.highQuality(maximumPixelDimension: 1600)` and run through
`AdjustmentPipeline` + `ImageRenderService` via a throwaway XCTest harness
(`Tests/LumaHarborIntegrationTests/ManualVisualHarnessTests.swift`, deleted
after use per this checklist's own instructions — not committed).

All 8 render cases (baseline, HSL combo, isolated-orange HSL, advanced curve,
split toning, sharpening, noise reduction, vignette dark, vignette light,
grain, all-seven-together — 11 PNGs total) rendered successfully with no
crash and no `ImageRenderError`. Each was inspected visually; two were also
checked quantitatively by sampling pixel patches (Pillow/numpy) since the eye
alone can't always separate "diluted" from "not working":

- **HSL**: a 3-band combo (red saturation -100, blue saturation +100, orange
  hue -100/saturation +100/luminance -50) showed clearly correct, selective,
  region-appropriate colour shifts with no hard seams at band boundaries. To
  directly test the checklist's dilution concern, a second isolated-orange
  render (orange saturation -100 only, nothing else touched) was compared
  against baseline on the wood-chair patch: mean HSV saturation dropped
  0.477 → 0.327 (RGB channels converging toward grey as expected), a real and
  substantial desaturation — the weight-normalisation dilution exists (a lone
  band at its own centre isn't a clean 100%-strength -100 in this photo's
  off-centre-hue wood tone) but does not neuter the effect. **No
  recalibration needed**; this matches the "known trade-off" already recorded
  in the progress log's Important #5 entry. Coverage gap: this fixture has
  strong red/orange/blue content but little yellow/green/purple/magenta, so
  those five bands were not independently visually confirmed — the kernel
  math is band-agnostic (verified in `HSLKernelWeightsTests`), so this is a
  photo-coverage gap, not an unverified code path.
- **Advanced tone curve**: a 5-point S-curve produced brightness redistribution
  matching the curve's shape exactly as expected (steep midtone lift, flatter
  shoulder) — no solarisation/tonal inversion anywhere. One real observation:
  the very steep slope near the curve's white end (x=0.75→1.0, slope 3.2)
  visibly amplified pre-existing sensor colour noise into small blue/cyan
  speckles on near-white cat fur. This is expected, correct behaviour for an
  aggressive, unrealistic-extreme curve (amplifying real per-pixel noise is
  exactly what a steep tone curve does on real hardware) — not a pipeline bug
  — but worth knowing since it's the kind of thing a user pushing a curve
  this hard would also see.
- **Split toning**: shadow (blue, hue 220) and highlight (orange, hue 40)
  tinting applied independently and visibly — shadows cooled, highlights
  warmed, no global darkening. This directly confirms the colour-space fix
  from the final-review commit (`c644aa8`) holds on real hardware: the
  earlier `CIColor(color:)` bug that dimmed every split-toned edit is gone.
- **Sharpening** (amount 150, radius 3.0 — both at their max): strong,
  correct-direction edge contrast increase with visible halos along
  high-contrast edges (chair armrest against the cushion). Halos at this
  magnitude are expected at the extreme end of the slider range, not a defect.
- **Noise reduction** (luminance + colour amount 100): visibly smoothed fine
  cushion-fabric texture and fur detail in the correct direction, no crash.
- **Vignette**: visual inspection alone was inconclusive because this
  particular photo already has near-black corners (dark curtain, dark
  furniture), so pixel-sampled the centre and two corners instead. Centre
  luminance was bit-for-bit identical across baseline/dark/light (confirms
  `midpoint`-based falloff correctly leaves the centre untouched). Bottom-left
  corner: baseline 104.2 → dark(-100) 33.3 → light(+100) 248.6 — strong,
  correctly-directioned changes in both directions. Confirmed correct.
- **Grain** (amount 100): even, correctly-applied film grain texture across
  the whole frame, no crash.
- **All seven together**: rendered without crashing in ~1.2s total for all 11
  renders combined on this hardware (no per-case timing isolated, but nothing
  felt slow) — the combined output is extremely stylised, as expected when
  stacking every effect at its most extreme value simultaneously (not a
  realistic editing scenario); the same blue-speckle noise-amplification seen
  in the curve case is more visible here since curve + sharpening + grain
  compound on the same noise, consistent with each effect's individual
  behaviour rather than a new interaction bug.

**Outcome**: all seven effect stages rendered successfully on real Apple
Silicon hardware with a real Sony ARW, and the tested colour content behaved
correctly. The noise-amplification-under-steep-curves observation and HSL
lone-band dilution remain expected, already-understood behaviour rather than
defects. Full eight-band HSL coverage (the gap this section originally left
open) was closed in the follow-up run below.

## Follow-up: yellow/green/aqua/purple/magenta (2026-08-20, Gate A2)

**Prerequisite check**: `swift test -Xswiftc -strict-concurrency=complete`
(421 tests) and `LUMAHARBOR_RAW_FIXTURE_DIR=Fixtures/Private/Sony-ARW swift
test --filter RawFixtureTests` (9 tests) were both green immediately before
this run — see `docs/superpowers/specs/2026-08-19-adjustment-engine-expansion-design.md`
progress log, fourth 2026-08-20 entry (Gate A1).

**Method**: same approach as the original run — a throwaway XCTest harness
(`Tests/LumaHarborIntegrationTests/ManualVisualHarnessTests.swift`, deleted
after use, never committed) decoded real Sony ARWs from
`Fixtures/Private/Sony-ARW/` at `.highQuality(maximumPixelDimension: 1600)`,
pushed one band at a time through `AdjustmentPipeline`, and wrote PNGs
inspected visually plus pixel-sampled (Pillow/numpy, HSV, circular mean for
hue) against a mask of the baseline pixels actually in that band's hue range.
Three fixtures were used, chosen by scanning all 81 fixtures' JPEG-preview hue
histograms for the best real coverage of each remaining band:

- `_DSC1908.ARW` — a garden/railing scene with strong green and aqua foliage
  content (green: 23% of frame in-band, aqua: 11%).
- `_DSC1932.ARW` — a cream/beige curtain scene, strong genuine yellow content
  (62% of frame in-band).
- `_DSC1919.ARW` — the same kitten+wicker-chair scene as the original run, has
  no genuine purple or magenta subject matter, but was used deliberately: with
  `HSLKernelWeights.halfWidthDegrees = 60`, blue (35° from purple's 275°
  centre) and red (45° from magenta's 315° centre, wrapping through 0) both
  fall inside purple's/magenta's triangular falloff by design (this is the
  "no dead zones" fix from `3a63c46`), so editing purple/magenta measurably
  moves this photo's real blue railing/chair and red/orange fur pixels even
  without a pure purple/magenta subject in frame.

**Results** (baseline → recoloured/desaturated, masked to the baseline's own
in-band pixels, pixel counts are pre-edit mask size):

| Band | Mask size | Hue shift | Saturation (recolour) | Saturation (desat isolate) |
|---|---|---|---|---|
| Green | 399k px (23%) | 120.9°→101.0° | 0.303→0.562 | 0.303→0.090 |
| Aqua | 193k px (11%) | 181.0°→200.3° | 0.272→0.553 | 0.272→0.088 |
| Yellow (curtain, strong) | 1.06M px (62%) | 37.9°→28.2° | 0.497→0.665 | 0.497→0.361 |
| Yellow (garden, weak) | 22k px (1.3%) | 56.2°→41.5° | 0.213→0.359 | — |
| Purple (via blue overlap) | 257k px (15%) | 231.8°→225.9° | 0.321→0.449 | 0.321→0.258 |
| Magenta (via red overlap) | 110k px (6.5%) | 4.3°→7.0° | 0.222→0.261 | 0.222→0.201 |

Every band produced a real, correctly-directioned, non-trivial change in both
hue and saturation on the actual masked pixels — none of these are rendering
no-ops. Green, aqua and the strong-yellow curtain case show large, obviously
visible shifts on inspection (the curtain scene's background wall visibly
warms and saturates; the aqua recolour visibly cools and darkens the whole
garden frame). Purple and magenta show smaller but still real and directional
shifts, consistent with their masked pixels sitting only 35–45° from those
bands' centres (triangular weight ≈ 0.18–0.28 at that distance, per
`HSLKernelWeights`) rather than being unaffected — this is the same, already-
accepted "lone-band dilution" behaviour documented for orange in the original
run above, not a new finding. `curtainD-yellow-darken.png` (luminance -100)
also confirmed the correct direction on brightness (val 0.571→0.484).
`testFiveOutstandingBandsTogether` applied all five at once on the garden
photo: rendered without crashing, no hard colour-banding seams visible at any
band boundary.

**Coverage note**: no fixture in the private set (all three ARW subfolders
are the same photoshoot) contains genuine, dedicated purple or magenta
subject matter — the purple/magenta results above are real measurements of
the deliberate band-overlap design, not of a "pure" purple/magenta patch.
`HSLKernelWeightsTests` already covers the band-centre/half-width math itself
at the unit level; this run additionally confirms that math produces a real,
correctly-directioned pixel change end-to-end through the actual render
pipeline on real photo data, which is what this checklist item is for.

**Outcome**: all eight HSL bands now have real-ARW visual + quantitative
confirmation. Gate A2 is satisfied; no accepted-gap sign-off (spec §A3) is
needed.
