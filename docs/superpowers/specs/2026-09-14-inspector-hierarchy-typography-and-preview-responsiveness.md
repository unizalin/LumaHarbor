# Inspector Hierarchy, Typography, and Preview Responsiveness

**Status:** Ready for implementation
**Date:** 2026-09-14
**Target branch:** `claude/professional-editing-completion`
**Verified baseline:** `3110d572aa18912577374c2101240abf7793eb91`
**Scope:** macOS inspector and shared iPad adjustment components
**Tracking:** Local spec only. Do not create a GitHub Epic or Issue.

## 1. Context

The 2026-09-14 visual acceptance screenshots exposed three connected problems in the adjustment inspector:

1. Collapsed and expanded sections do not communicate a clear hierarchy.
2. Labels and numeric controls compete for width, especially in the narrow macOS inspector.
3. Slider feedback is functionally correct but can feel delayed because every intermediate value performs more state work than an interactive preview requires.

This is not a request to enlarge every font or restyle the whole application. The goal is to make the existing professional editor easier to scan, preserve complete localized labels, and reduce work performed during continuous adjustment gestures.

## 2. User Problem

### 2.1 Collapsed sections are ambiguous

The current macOS inspector has two visually similar disclosure levels:

- `InspectorView` creates the outer groups such as Basic, Color, Detail, and Curves.
- `ColorAdjustmentPanel` creates another disclosure row for every HSL band.

Both levels use a chevron followed by a short title. The inner red, orange, yellow, green, aqua, blue, purple, magenta, and black-and-white rows therefore look like peer tools rather than controls inside Color. When several bands are open, the repeated Hue, Saturation, and Luminance labels lose their channel context.

The outer headers also show reset and favorite actions on every row even when the section is neutral. This makes the action icons compete with the title and disclosure state.

### 2.2 Text is compressed by control geometry

`AdjustmentValueInput` currently reserves four large regions in every row: minus, numeric field, plus, and reset. The controls retain 44-point hit frames on macOS, where the inspector itself is designed for roughly 300 to 440 points. After panel padding and spacing, too little width remains for the localized label.

`BasicAdjustmentPanel` and `AdjustmentSliderRow` compensate with `minimumScaleFactor(0.8)`. This produces inconsistent perceived type size and can still lead to abbreviated text. Increasing the global font size alone would make the layout failure worse.

### 2.3 Interactive edits perform unnecessary repeated work

The preview scheduler already cancels or supersedes stale work and prevents old results from replacing newer results. The remaining cost is earlier in the edit flow:

- A basic or HSL slider writes a new adjustment for every tick.
- Each write records edit history, refreshes undo state, requests an interactive preview, reschedules the settled preview, and reschedules autosave.
- HSL rows do not currently connect their gesture lifecycle to `EditorSession`.

Curve editing already demonstrates a better transaction: intermediate values are previewed, then one final value is committed. Basic, HSL, and other continuous sliders should follow the same behavioral contract.

Existing real-RAW evidence measured warm 1600-pixel renders around 137 to 138 ms. This is inside the current 200 ms interaction budget but leaves little room for redundant state work, histogram work, and main-thread layout during rapid dragging.

## 3. Current-State Evidence

| Area | Evidence | Finding |
| --- | --- | --- |
| Outer disclosure | `Sources/LumaHarborApp/Views/InspectorView.swift` | Nine top-level groups share the same disclosure presentation. Basic and Color start expanded. |
| Inner disclosure | `Sources/AdjustmentUI/ColorAdjustmentPanel.swift` | Eight HSL bands and black-and-white controls add a second disclosure level. |
| Row sizing | `Sources/AdjustmentUI/AdjustmentValueInput.swift` | Four controls use large fixed hit regions on both platforms. |
| Label fallback | `Sources/AdjustmentUI/BasicAdjustmentPanel.swift`, `Sources/AdjustmentUI/AdjustmentSliderRow.swift` | Labels may shrink to 80 percent to fit. |
| Edit flow | `Sources/EditorCore/EditorSession.swift` | Every slider tick records history and reschedules preview, settled rendering, and autosave. |
| Correct stale-result handling | `Sources/RawProcessingCore/Preview/PreviewScheduler.swift` | Latest request wins and stale results are dropped. Preserve this behavior. |
| Existing transaction pattern | `Sources/AdjustmentUI/CurveAdjustmentPanel.swift`, `Sources/EditorCore/EditorSession.swift` | Curve preview and commit paths already separate interactive preview from the final history entry. |
| Performance reference | `docs/testing/reports/2026-08-16-mvp-acceptance-progress.md` | Warm 1600-pixel RAW preview was measured at about 137 to 138 ms on the recorded machine. Re-measure on the current build. |

## 4. Design Principles

1. **One visible hierarchy:** a top-level inspector group may collapse, but its content must not repeat the same disclosure pattern without a clearly different visual treatment.
2. **Full names before density:** do not replace localized titles with ellipses or shrink them until they look unrelated to adjacent text.
3. **Adaptive rows, stable controls:** change the row composition at width thresholds instead of continuously scaling type.
4. **Immediate local feedback:** the displayed number and slider thumb must update synchronously with the gesture.
5. **One gesture, one edit:** continuous dragging creates one undoable history entry and one autosave commit.
6. **Presentation state is not photo data:** section expansion, selected HSL band, and histogram collapse do not modify the sidecar, preset, undo history, or render result.
7. **Shared semantics, platform metrics:** macOS and iPad use the same labels and adjustment behavior while retaining appropriate pointer and touch target sizes.

## 5. Proposed Change

### 5.1 Top-level inspector groups

Keep the existing top-level groups for compatibility, but revise their presentation and state rules.

The inspector must express three visible hierarchy levels. Do not align every disclosure title and field to the same leading edge.

| Level | Examples | Leading inset from inspector content | Visual treatment | Disclosure behavior |
| --- | --- | --- | --- | --- |
| Level 1: feature group | Basic, Color, Detail, Curves | 0 pt | Full-width row, `.subheadline.weight(.semibold)`, strongest divider, modified summary | Primary disclosure level |
| Level 2: subsection | White Balance, HSL, Black and White, Sharpening, Noise Reduction | 12 to 16 pt | `.callout.weight(.semibold)`, subtle leading guide, lighter divider, no favorite icon | May disclose only when the subsection contains several controls |
| Level 3: editor and field | Red band editor, Hue, Saturation, Luminance, Exposure | 24 to 28 pt | `.callout`, no disclosure chevron, selected-band swatch or field icon where useful | Direct controls only |

Hierarchy requirements:

- Every nested level increases indentation. A child title must never share the same leading edge, type weight, divider strength, and chevron size as its parent.
- Level 1 rows use the largest disclosure chevron and may include the modified summary and group actions.
- Level 2 rows use a smaller disclosure indicator and subsection reset action only when required. They must not repeat the Level 1 favorite and action cluster.
- Level 3 controls never use a disclosure row. The selected HSL band appears as a subsection heading with its swatch and full name above Hue, Saturation, and Luminance.
- Use spacing and one subtle leading guide to show containment. Do not wrap each level in another card or rounded rectangle.
- Collapsing Level 1 hides all descendants. Reopening it restores the previous Level 2 expansion and selected-band state.
- Collapsing Level 2 hides only that subsection and does not collapse its Level 1 parent or reset values.
- Keyboard focus order and VoiceOver reading order follow Level 1, Level 2, then Level 3.

- On first presentation, expand only Basic. Do not automatically expand Basic and Color together.
- Preserve every user-controlled expansion state while switching tabs, resizing the window, or selecting an HSL band.
- Search and smart-follow may reveal the target group, but must not collapse unrelated groups or reset the target adjustment.
- Make the title area the main disclosure target. Nested action buttons must not trigger disclosure or reset.
- Add a secondary summary to collapsed groups:
  - Neutral: `未調整`
  - Modified: localized count such as `3 項已調整`
- Show a compact modified indicator next to the summary. Do not rely on color alone.
- Move reset and favorite actions into a trailing menu by default. A selected favorite may remain visible as a filled star. Pointer hover, keyboard focus, and VoiceOver focus may reveal the individual actions.
- Apply the hierarchy table's cumulative inset and subtle leading guide so that the group boundary remains visible while scrolling.

The reset action must always require an explicit button or menu selection. Clicking a group title, label, disclosure chevron, or numeric value must never reset an adjustment.

### 5.2 HSL color-band editor

Remove the nested disclosure group for each HSL band.

Replace it with:

1. An adaptive color-band selector.
2. One editor for the currently selected band.
3. Three clearly titled rows: Hue, Saturation, and Luminance.

Selector requirements:

- Use a grid rather than a horizontally scrolling strip, so every band remains discoverable.
- At 340 points or wider, use four columns.
- Below 340 points, use two columns.
- Each item includes a color swatch and the complete localized band name, for example Red or Red Color according to the locale.
- Minimum item height is 32 points on macOS and 44 points on iPad.
- Selected, modified, focused, and disabled states must be distinguishable without color alone.
- Only one band editor is visible at a time.
- Changing the selected band must not render the photo, write history, save the sidecar, or reset any values.
- Retain the selected band while Color is collapsed and reopened or while the inspector is resized. The state may reset when a new editor session is created.

Apply the same selector pattern to the black-and-white color mixer when it is enabled. Do not introduce another stack of eight disclosure groups.

### 5.3 Typography and density

Use semantic type styles and fixed hierarchy rather than arbitrary font sizes.

| Element | Style | Notes |
| --- | --- | --- |
| Inspector title | `.headline` | Existing title hierarchy may remain. |
| Top-level group title | `.subheadline.weight(.semibold)` | Must be visually stronger than field labels. |
| Subsection title | `.callout.weight(.semibold)` | Used for White Balance, HSL, and Black and White. |
| Adjustment label | `.callout` | Full localized label, one line where the width permits. |
| Numeric value | `.callout.monospacedDigit()` | Stable width while values change. |
| Summary and metadata | `.caption` | Do not use `.caption2` for primary navigation or field labels. |

Requirements:

- Do not use viewport-width-based font scaling.
- Letter spacing remains zero.
- Do not allow primary labels to scale below 90 percent.
- Do not show `...` for supported localized labels at the required widths.
- Keep numeric values to one decimal place unless a specific adjustment contract requires greater precision.
- Preserve Dynamic Type and accessibility sizes. At accessibility sizes, rows may become vertically stacked.

### 5.4 Adaptive adjustment rows

Create shared row metrics rather than hard-coding the same control size for macOS and iPad.

For available row width of 340 points or more:

- First line: full label on the leading side; minus, numeric value, plus, and reset on the trailing side.
- Second line: slider uses the full available width.

For available row width below 340 points or at accessibility text sizes:

- First line: full-width label.
- Second line: numeric and nudge controls aligned to the trailing edge.
- Third line: full-width slider.

Platform metrics:

| Control | macOS | iPad |
| --- | --- | --- |
| Nudge/reset hit target | 28 to 32 pt | At least 44 pt |
| Numeric field width | 64 to 72 pt | 72 to 88 pt |
| Row vertical gap | 6 to 8 pt | 8 to 12 pt |

Use familiar minus, plus, and reset icons with tooltips or accessibility labels. Do not add text-filled pill buttons when a standard icon expresses the action.

### 5.5 Histogram density

Keep the histogram visible by default because it provides continuous editing feedback, but give it an explicit compact disclosure control in its header.

- Expanded height remains within the existing stable 96 to 132 point range.
- Collapsed state displays the title, current RGB or luminance mode, and clipping status without the graph.
- Remember collapse state for the current editor session only.
- Collapsing or expanding the histogram performs zero preview submissions and zero histogram recomputations.
- Retain the current clipping labels and accessibility descriptions.

### 5.6 Interactive adjustment transaction

Generalize the existing curve-edit transaction into a shared continuous-adjustment transaction.

Required lifecycle:

1. `begin`: capture the committed baseline once.
2. `preview`: update the visible adjustment state immediately and submit coalesced latest-wins preview work.
3. `commit`: record one history item, request the final settled render, and schedule one autosave.
4. `cancel`: restore the baseline without adding history.

Behavior rules:

- Slider drag, pointer drag, keyboard continuous adjustment, and accessibility adjustable actions use this lifecycle.
- A single plus or minus click is one discrete commit.
- Repeated button presses may create repeated commits, but values must clamp at the declared range and must never wrap or jump to zero.
- Reset is a separate explicit commit.
- Do not change `PreviewScheduler` latest-wins or stale-result protection.
- Do not decode RAW data because a disclosure, band selection, tab selection, or panel resize changed.
- Histogram work must follow delivered preview generations. It must not display a generation older than the visible preview.
- Add cancellation checkpoints or bounded downsampling to histogram pixel processing so it cannot monopolize the main thread.

## 6. Performance Budgets

Measure on an Apple Silicon Mac and a supported physical iPad using the same representative RAW fixture and 1600-pixel interactive preview size.

| Interaction | Budget |
| --- | --- |
| Slider thumb and numeric value update | p95 at or below 16 ms from input event |
| Group expand or collapse | p95 at or below 50 ms, with zero render requests |
| HSL band selection | p95 at or below 50 ms, with zero render requests |
| Inspector tab or domain switch | p95 at or below 100 ms |
| Warm interactive RAW preview | p95 at or below 200 ms |
| Histogram update for delivered preview | p95 at or below 250 ms |
| Main-thread stall during continuous editing | No stall above 50 ms; no recurring stall above 16 ms caused by inspector layout |
| History and autosave work | Exactly one history entry and one autosave scheduling event per completed continuous gesture |

If the current hardware cannot meet a budget, record the fixture, device, build configuration, median, p95, and root cause. Do not silently weaken the budget.

## 7. Implementation Plan

### Phase 1: Presentation state and hierarchy

- Add a pure presentation model for expanded groups, selected HSL band, histogram collapse, and modification summaries.
- Change the default top-level expansion to Basic only.
- Replace HSL band disclosures with the adaptive selector and one active editor.
- Add collapsed neutral or modified summaries.
- Keep presentation state out of sidecars and edit history.

### Phase 2: Adaptive type and controls

- Add shared platform-aware row metrics.
- Implement the 340-point row transition.
- Remove reliance on 80-percent label scaling.
- Reduce macOS control footprint while retaining 44-point iPad targets.
- Verify every supported localization at required widths.

### Phase 3: Interactive edit transaction

- Generalize the curve preview-and-commit pattern.
- Migrate Basic, White Balance, HSL, Color Grading, Detail, Presence, Vignette, and Grain continuous controls.
- Preserve discrete plus, minus, and reset semantics.
- Add generation-aware histogram throttling and cancellation checkpoints.

### Phase 4: Measurement and visual acceptance

- Add signposts or test-clock instrumentation for input, preview submission, preview delivery, and histogram delivery.
- Capture macOS widths at 300, 340, 360, and 440 points.
- Capture iPad portrait, landscape, split view, and bottom drawer states.
- Run physical-device interaction checks before release packaging.

## 8. Acceptance Criteria

### Hierarchy

- [ ] First presentation expands Basic only.
- [ ] Color contains no per-band nested `DisclosureGroup`.
- [ ] Exactly one HSL band editor is visible at a time.
- [ ] Level 1, Level 2, and Level 3 use distinct cumulative indentation, type weight, divider strength, and disclosure treatment.
- [ ] No child disclosure title is visually aligned as a peer of its parent.
- [ ] Level 3 adjustment controls contain no disclosure chevrons.
- [ ] Collapsing a parent hides descendants without clearing the child's expansion, selected-band, or adjustment state.
- [ ] Every collapsed top-level group shows a complete title and neutral or modified summary.
- [ ] Expanded content has a clear visual inset or guide distinct from the group header.
- [ ] Clicking a title, chevron, label, or numeric field never resets a value.
- [ ] Search and smart-follow reveal a target without clearing unrelated expansion state.

### Typography and layout

- [ ] No primary label displays `...` at 300, 340, 360, or 440 point macOS inspector widths.
- [ ] No primary label scales below 90 percent.
- [ ] Numeric values use one decimal place and remain aligned while changing sign or magnitude.
- [ ] macOS pointer controls do not reserve iPad-sized 44-point frames unless required for accessibility.
- [ ] iPad touch targets remain at least 44 by 44 points.
- [ ] Rows switch to the stacked layout below 340 points without overlap, clipping, or horizontal scrolling.
- [ ] Dynamic Type and VoiceOver preserve the complete label and control purpose.

### Interaction and performance

- [ ] Slider and numeric values update locally within the 16 ms p95 budget.
- [ ] One continuous gesture creates exactly one undo history entry.
- [ ] One continuous gesture schedules exactly one autosave after commit.
- [ ] Plus and minus clamp at the supported range and never wrap or reset to zero.
- [ ] Group expansion, histogram collapse, HSL band selection, and panel resizing submit zero photo previews.
- [ ] Stale previews and histograms never replace newer visible generations.
- [ ] The 200 ms interactive preview and 250 ms histogram p95 budgets pass on recorded test hardware.

### Cross-platform behavior

- [ ] The shared HSL selector and adjustment semantics are mounted in both macOS and iPad composition paths.
- [ ] macOS inspector resizing does not change edit values or reset presentation state.
- [ ] iPad rotation and bottom-drawer transitions do not clip labels or move controls outside the safe area.
- [ ] No signing, provisioning, bundle identifier, or source RAW settings change.

## 9. Testing Plan

### Unit tests

- Expansion state preserves unrelated groups and defaults to Basic only.
- Modification summaries return neutral and localized modified counts.
- HSL selector exposes all eight bands and one active band.
- Adaptive row policy selects inline or stacked composition at the threshold.
- Nudge, reset, clamp, and one-decimal formatting retain current value semantics.
- Interactive transaction begin, preview, commit, and cancel produce the expected final model state.

### Integration tests

- Ten rapid slider updates produce fewer preview submissions than updates and deliver the final value.
- Ten rapid slider updates followed by release create one history entry and one autosave event.
- Disclosure and HSL selection changes produce zero renderer calls.
- A canceled gesture restores the baseline and produces no history entry.
- Histogram generation always matches the visible preview generation.
- Basic, White Balance, HSL, Color Grading, Detail, Presence, Vignette, and Grain share the transaction contract.

### Contract tests

- `ColorAdjustmentPanel` contains no per-band disclosure construction.
- Both macOS and iPad hosts mount the shared HSL selector.
- Primary adjustment labels do not use `minimumScaleFactor(0.8)`.
- The iPad project file continues to reference the active inline or extracted inspector host as expected.

### Manual visual checks

- macOS: 300, 340, 360, and 440 point inspector widths at normal and accessibility text sizes.
- iPad: portrait, landscape, split view, bottom drawer, hardware keyboard, and pointer.
- Expand several top-level groups, collapse them, switch tabs, resize, and confirm retained state.
- Drag every continuous control quickly and slowly. Confirm immediate numbers, correct final image, one-step undo, and no value jump to zero.

Record physical-device checks as `PASS`, `FAIL`, or `NOT RUN`. Do not infer a pass from simulator or automated test results.

## 10. Files Expected to Change

| File or area | Intended change |
| --- | --- |
| `Sources/LumaHarborApp/Views/InspectorView.swift` | Group header, summary, default expansion, histogram collapse, action placement |
| `Sources/AdjustmentUI/ColorAdjustmentPanel.swift` | Adaptive HSL and black-and-white band selector |
| `Sources/AdjustmentUI/AdjustmentSliderRow.swift` | Adaptive row composition and shared metrics |
| `Sources/AdjustmentUI/BasicAdjustmentPanel.swift` | Shared row behavior and interactive transaction wiring |
| `Sources/AdjustmentUI/AdjustmentValueInput.swift` | Platform-specific metrics and complete-label layout |
| `Sources/AdjustmentUI/HistogramPanel.swift` | Compact disclosure state and generation-aware update behavior |
| `Sources/EditorCore/EditorSession.swift` | Generic continuous adjustment preview, commit, and cancel lifecycle |
| `Sources/RawProcessingCore/Preview/PreviewScheduler.swift` | Only if instrumentation is required; preserve scheduling semantics |
| `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift` | Verify shared panel mounting and responsive host behavior |
| `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadInspectorHost.swift` | Keep extracted host contract aligned if this path remains supported |
| `Sources/Localization/Resources/*/Localizable.strings` | Complete section summaries and color-band names |
| `Tests/AdjustmentUITests/*` | Presentation, HSL, row metrics, and value-input coverage |
| `Tests/EditorCoreTests/*` | One-gesture-one-commit transaction coverage |
| `Tests/LumaHarborAppTests/*` | Inspector hierarchy, zero-render, and cross-host contract coverage |
| `Tests/RawProcessingCoreTests/*` | Generation and histogram scheduling coverage if implementation changes |

## 11. Do Not Touch

- `Apps/LumaHarborPad.xcodeproj/project.pbxproj` signing or provisioning values
- Source RAW bytes or source-file naming behavior
- Sidecar schema and snapshot schema
- Preset, XMP, or cross-device compatibility contracts
- Export color management or render math
- Git history, branch protection, remote branches, or release packaging

Do not stage unrelated existing worktree changes. In particular, preserve the current user-owned local signing change.

## 12. Rollback

Keep each phase independently revertible.

- Presentation changes may revert to the previous disclosure UI without altering photo data.
- Transaction changes must remain behind the existing committed adjustment model, so rollback cannot corrupt sidecars or history.
- Instrumentation must be removable without changing production rendering behavior.
- If a physical-device performance regression appears, keep the hierarchy and typography work while reverting only the transaction or histogram scheduling commit.

## 13. Effort and Handoff

Estimated implementation effort is two to four focused engineering days, followed by physical-device visual and latency acceptance. Use separate commits for hierarchy, adaptive controls, interactive transactions, and measurement evidence.

Before implementation, re-read:

- `AGENTS.md`
- `docs/coordination/SHARED_AGENT_READ_PROTOCOL.md`
- `docs/coordination/CURRENT.md`
- this specification

After each phase, update `docs/coordination/CURRENT.md` with the exact branch, commit, dirty files, tests run, and any `NOT RUN` physical-device checks. Do not create an Epic or GitHub Issue.
