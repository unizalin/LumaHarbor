# Handoff: P5 Advanced Masks, AI Repair, and Perspective

Follows `docs/coordination/HANDOFF_TEMPLATE.md`.

## Status

`DONE_WITH_CONCERNS`

## Git state

- Source branch: `claude/professional-editing-completion`
- Base for this phase: `4cdf40f` ("docs: add Gemini IDE P5-P7 handoff")
- Implementation commit: `feat: add advanced masks, AI repair, and perspective (P5)`
- Ahead / behind: Ahead of `main` / `origin` on feature branch; no push, merge, or rebase occurred.

## Changes

### New files (spec / plan)

- `docs/superpowers/specs/2026-09-10-advanced-masks-ai-repair-and-perspective.md`
- `docs/superpowers/plans/2026-09-10-advanced-masks-ai-repair-and-perspective.md`

### New files (services & tests)

- `Sources/RawProcessingCore/Vision/VisionSegmentationService.swift`: Wraps Apple Vision framework (`VNGenerateForegroundInstanceMaskRequest`, iOS 17+ / macOS 14+); completely offline and on-device without network; provides SHA-256 digest computation; includes deterministic synthetic fallback for unit tests and headless environments.
- `Tests/RawProcessingCoreTests/AdvancedMasksModelTests.swift`: 8 tests covering local adjustment kinds, geometry serialization, inversion, opacity clamping, range masks, corner pins perspective, and backward compatibility with 5-parameter initializer.
- `Tests/RawProcessingCoreTests/AdvancedMasksRenderTests.swift`: 7 tests verifying radial gradient masks, brush stroke rasterization, luminance range masks, color range masks, mask inversion & opacity scaling, perspective corner pins correction, and red-eye desaturation.

### Modified files (models & rendering)

- `Sources/RawProcessingCore/Model/LocalAdjustment.swift`:
  - `LocalAdjustmentKind` expanded to support `.radialGradient`, `.brush`, `.luminanceRange`, `.colorRange`, `.subject`, `.background`, and `.spotHeal`.
  - `LocalAdjustment` added `name: String`, `opacity: Double` (0...100, default 100), `isInverted: Bool` (default false), while preserving the 5-parameter `init` for backward compatibility.
  - `SpotHealMode` added `.redEye`.
  - `LocalAdjustmentGeometry` expanded to support `BrushStroke`, `BrushPoint`, `radialRadiusY`, range mask parameters (`luminanceMin`/`luminanceMax`, `colorTargetHue`/`colorHueTolerance`), AI metadata (`maskRelativePath`, `maskDigest`, `visionRevision`, `reconstructionNeeded`), and `redEyePupilRadius`.
- `Sources/RawProcessingCore/Model/GeometryAdjustments.swift`:
  - Added `PerspectiveCornerPins` and `NormalizedPoint` representing 4-corner perspective distortion.
  - Integrated `cornerPins` into `GeometryAdjustments` with `isIdentity` check and `resettingPerspective()` support.
- `Sources/RawProcessingCore/Pipeline/LocalAdjustmentRenderer.swift`:
  - Implemented CoreImage rendering for radial gradient masks, brush strokes (`CILineOverlay`/`CISourceOverCompositing`), luminance range (`CIColorMatrix`), color range (hue-distance weighting), and subject/background masks.
  - Implemented mask inversion (`CIColorInvert`) and opacity attenuation (`CIColorMatrix`).
  - Implemented red-eye repair algorithm desaturating and darkening the pupil region.
- `Sources/RawProcessingCore/Pipeline/GeometryRenderer.swift`:
  - Implemented `cornerPinsCorrected` using `CIPerspectiveCorrection` to map four corner coordinates back to rectangular geometry.

### Modified files (UI & iPad parity)

- `Sources/AdjustmentUI/LocalAdjustmentsPanel.swift`:
  - Added "Add Mask" menu with options for Linear Gradient, Radial Gradient, Brush, Luminance Range, Color Range, Subject, and Background.
  - Added per-mask UI for name, Invert toggle, and Opacity slider.
  - Added Red-Eye mode option and Pupil Radius slider under Spot Heal.
- `Sources/AdjustmentUI/GeometryAdjustmentPanel.swift`:
  - Added Perspective controls (Horizontal and Vertical) with reset support.
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift` & `PadInspectorHost.swift`:
  - Mounted `RenderingProfilePanel` and `PresenceAdjustmentPanel` in `.light` submode.
  - Mounted `ColorGradingAdjustmentPanel` in `.color` submode, resolving the P4 inspection gap between Mac and iPad.

### Modified files (Localization)

- Added 25+ localization strings in 8 languages (`en`, `zh-Hant`, `zh-Hans`, `ja`, `ko`, `de`, `fr`, `es`).
- Updated `Tests/LumaHarborAppTests/EightLanguageLocalizationGateTests.swift` with legitimate homographs ("Horizontal", "Vertical", "Perspective" in German/French/Spanish).

## Verification

- `swift test`: **PASS** (2165 tests, 9 skipped, 0 failures).
- `swift build -Xswiftc -strict-concurrency=complete`: **PASS** (0 warnings, 0 errors).
- `xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`: **BUILD SUCCEEDED**.
- `git diff --check`: **PASS** (no trailing whitespace or conflict markers).
- Privacy scan: **PASS** (no private home paths, team IDs, or private keys).
- Physical device Neural Engine inference: **NOT RUN** (runs on simulated fallback in CI/unit tests).
- `Scripts/run-mvp-acceptance.zsh`: **NOT RUN** (requires private external fixture volumes).

## Dirty files

None after the phase commit.

## Concerns and blockers

- **Apple Vision real-device execution**: `VNGenerateForegroundInstanceMaskRequest` requires iOS 17+ / macOS 14+ with Neural Engine. In unit tests and headless environments, `VisionSegmentationService` gracefully degrades to a deterministic synthetic gradient fallback without crashing. Real device verification will take place during P7 acceptance.
- **iPad standalone `PadInspectorHost.swift` vs `PadEditorView.swift`**: Both copies have been kept in sync with identical panel mountings.

## Next action

Proceed to **Phase 6: Snapshots, Soft Proof, and Professional Preview**:
1. Review `DECISIONS.md` D-006 regarding `PhotoSidecar.currentSchemaVersion = 4` and snapshot undo/redo compound transaction rules.
2. Draft spec and plan: `docs/superpowers/specs/2026-09-10-snapshots-soft-proof-and-professional-preview.md`.
3. Implement `EditSnapshot` model, sidecar v4 migration, snapshot manager, A/B toggle, clipping/gamut overlays, and Soft Proof pipeline.
4. TDD unit tests, 8-language localization, iPad/Mac UI, and full verification.
