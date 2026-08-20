# Adjustment Engine Expansion — Manual Visual Verification

Spec: `docs/superpowers/specs/2026-08-19-adjustment-engine-expansion-design.md` §6.

Prerequisite: Apple Silicon Mac, full Xcode, real Sony `.ARW` fixtures. Set
`LUMAHARBOR_RAW_FIXTURE_DIR` and run the automated suite first
(`swift test`) — it must be green before manual verification starts.

None of these seven effects is reachable from the Inspector UI (spec §1) — set
values directly on a `PhotoAdjustments` in a throwaway debug harness, or via
temporarily hardcoding a non-neutral value in `AdjustmentMapping.renderParameters`,
render, inspect, then revert.

- [ ] **HSL**: on a real ARW, push each of the 8 hue bands' hue/saturation/luminance
  to their extremes one at a time. Confirm the correct region of the photo visibly
  changes and neighbouring bands' boundaries don't show hard colour-banding
  seams. Note: a single band pushed to an extreme may read weaker than expected
  due to overlap normalization (`halfWidthDegrees` is 60 so no hue is a dead
  zone, and the kernel divides by the summed band weight once it exceeds 1.0,
  which dilutes a lone band even at its own centre) — confirm by eye whether
  this needs recalibrating.
- [ ] **Advanced tone curve**: apply a curve with several control points and a
  non-trivial shape (at least one point that pulls a midtone away from the
  4-slider curve's effect). Confirm the image's brightness distribution
  matches the curve's shape, and there is no solarisation (any tonal
  inversion — see `enforceMonotonicNonDecreasing` in
  `AdvancedToneCurveLUT.swift`).
- [ ] **Split toning**: apply distinct shadow and highlight hues at high
  saturation. Confirm shadows and highlights tint independently and
  `balance` visibly shifts which tonal range is affected more.
- [ ] **Sharpening / noise reduction / vignette / grain**: apply each at an
  extreme value independently. Confirm each produces a visible, correct-
  direction change, no crash, and no obvious artifact (haloing, banding,
  posterisation).
- [ ] **All seven together**: apply every effect at once. Confirm the pipeline
  doesn't crash, output still renders, and render time doesn't feel
  noticeably slower than before this expansion (no precise measurement
  required per spec §6 — a "does this still feel snappy" judgement call).

## Result

(Fill in after running: date, machine, which items passed, any follow-up
issues filed.)
