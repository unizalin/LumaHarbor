@preconcurrency import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// Applies `PhotoAdjustments.localAdjustments` to an already-decoded image
/// (design spec §6.6, roadmap Phase 4 "Task 4.2: Linear gradient render").
///
/// Runs *after* `GeometryRenderer` in both `CoreImagePreviewRenderer` and
/// `PhotoExporter`, matching `GeometryRenderer`'s own crop-goes-last
/// reasoning: a linear gradient's `x`/`y` anchor is a point the user placed
/// by dragging on the displayed (already rotated/cropped/straightened)
/// preview, so it must be interpreted in that same coordinate space, not the
/// pre-geometry source.
///
/// Both `.linearGradient` (Task 4.2) and `.spotHeal` (Task 4.4) entries are
/// applied here. A `.spotHeal` entry's own `.adjustments` (the shared mini
/// basic-adjustment patch) is ignored -- design spec §6.7 lists no
/// mini-adjustment fields for spot heal the way §6.6 does for gradients;
/// heal/clone is a content operation, not a tonal one.
public enum LocalAdjustmentRenderer {
    public static func apply(_ localAdjustments: [LocalAdjustment], to image: CIImage) -> CIImage {
        var working = image
        for adjustment in localAdjustments where adjustment.isEnabled {
            switch adjustment.kind {
            case .linearGradient:
                working = applyLinearGradient(adjustment, to: working)
            case .spotHeal:
                working = applySpotHeal(adjustment, to: working)
            }
        }
        return working
    }

    private static func applyLinearGradient(_ adjustment: LocalAdjustment, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        guard adjustment.adjustments.isEmpty == false else { return image }

        let mask = linearGradientMask(adjustment.geometry, extent: extent)
        let adjustedImage = LocalAdjustmentPatchRenderer.apply(adjustment.adjustments, to: image)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = adjustedImage
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    /// Builds a black-to-white `CILinearGradient` mask from
    /// `LocalAdjustmentGeometry`'s position/angle/range/feather (design spec
    /// §6.6: "位置、角度、範圍、羽化").
    ///
    /// Convention, chosen to match `GeometryRenderer.clockwiseRadians(_:)`
    /// for consistency across this codebase's two renderers: `angleDegrees`
    /// is measured clockwise, with `0` meaning the effect grows stronger
    /// toward the visual *right* of the anchor and weaker toward the left;
    /// `90` grows stronger toward the visual *bottom*.
    ///
    /// `range` (normalized `[0, 1]`, `0.3` default) sets the half-length of
    /// the transition band as a fraction of the image's diagonal, anchored
    /// symmetrically around the pivot point; `feather` (`0...100`) widens
    /// that same band further -- `0` is as hard an edge as this
    /// implementation produces, `100` roughly doubles the transition
    /// distance. The two knobs are deliberately allowed to overlap in
    /// effect (both widen the band) rather than trying to keep them
    /// analytically orthogonal, which is more precision than a first-pass
    /// linear gradient tool needs (spec: "先做...不追求 AI 修圖").
    private static func linearGradientMask(_ geometry: LocalAdjustmentGeometry, extent: CGRect) -> CIImage {
        let anchor = imagePoint(x: geometry.x, y: geometry.y, extent: extent)

        let diagonal = (extent.width * extent.width + extent.height * extent.height).squareRoot()
        let halfLength = max(CGFloat(geometry.range), 0.01) * diagonal / 2
        let featherMultiplier = 1 + CGFloat(geometry.feather) / 100
        let totalHalfLength = halfLength * featherMultiplier

        // Positive on-screen angle rotates clockwise; Core Image's own
        // trigonometric convention is counterclockwise in its y-up space,
        // so the y component is negated -- the same sign flip
        // `GeometryRenderer.clockwiseRadians(_:)` applies for the same
        // reason, pinned here by
        // `LocalAdjustmentRendererTests.testAngleZeroAppliesMoreEffect...`
        // and `...testAngle90AppliesMoreEffect...`.
        let radians = CGFloat(geometry.angleDegrees) * .pi / 180
        let direction = CGVector(dx: cos(radians), dy: -sin(radians))

        let point0 = CGPoint(x: anchor.x - direction.dx * totalHalfLength, y: anchor.y - direction.dy * totalHalfLength)
        let point1 = CGPoint(x: anchor.x + direction.dx * totalHalfLength, y: anchor.y + direction.dy * totalHalfLength)

        let filter = CIFilter.linearGradient()
        filter.point0 = point0
        filter.point1 = point1
        filter.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        filter.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        let mask = filter.outputImage ?? CIImage(color: .clear)
        return mask.cropped(to: extent)
    }

    /// Converts `LocalAdjustmentGeometry`'s normalized, origin-top-left
    /// coordinates (matching `NormalizedCropRect`'s own convention) into
    /// Core Image's bottom-left-origin, y-up pixel space -- the same
    /// conversion `GeometryRenderer.cropped(_:to:)` already does for crop.
    /// Shared by the linear gradient anchor and every spot heal point below.
    private static func imagePoint(x: Double, y: Double, extent: CGRect) -> CGPoint {
        CGPoint(
            x: extent.minX + CGFloat(x) * extent.width,
            y: extent.minY + CGFloat(1 - y) * extent.height
        )
    }

    // MARK: - Spot heal / clone (Task 4.4)

    /// A conservative, non-AI patch clone: translates a copy of the whole
    /// image so the sampled source patch lands on the target point, then
    /// blends that translated copy over the original through a soft-edged
    /// circular mask centered on the target. This is deliberately simple --
    /// no content-aware fill, no seam blending beyond the mask's own
    /// feather, no texture synthesis. On a patterned or high-contrast
    /// background it can visibly repeat an edge or a recognizable shape from
    /// the source; it is honest about that limitation rather than promising
    /// AI-retouching quality (roadmap Phase 4 goal: "先做...不追求 AI 修圖").
    /// `.heal` mode's own "auto-sampled surrounding texture" (design spec
    /// §6.7) is likewise a fixed, deterministic offset -- see
    /// `autoSourcePoint(for:extent:)` -- not a learned or analyzed choice.
    private static func applySpotHeal(_ adjustment: LocalAdjustment, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let geometry = adjustment.geometry
        let target = imagePoint(x: geometry.x, y: geometry.y, extent: extent)
        let source = resolvedSourcePoint(for: geometry, extent: extent)

        let dx = target.x - source.x
        let dy = target.y - source.y
        // Target and source coincide (a fresh point, or the user dragged
        // them onto each other) -- nothing would move; skip the transform
        // and mask entirely rather than composite a no-op.
        guard dx != 0 || dy != 0 else { return image }

        let translated = image.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        let radiusPixels = max(CGFloat(geometry.radius), 0.001) * min(extent.width, extent.height)
        let mask = healMask(center: target, radius: radiusPixels, feather: geometry.feather, extent: extent)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = translated
        blend.backgroundImage = image
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    /// Resolves which point this spot heal entry actually samples from,
    /// re-evaluated from `geometry` on every render call (nothing here is
    /// cached across calls) -- design spec §6.7: "模式切換時，當前選取點必須
    /// 立即更新，不只影響下一個新點" (switching mode must immediately update
    /// the currently selected point, not only affect the next new point).
    /// `.heal` always ignores `sourceX`/`sourceY`, even a value left over
    /// from a previous `.clone` selection, so flipping `healMode` alone
    /// changes rendered behavior with no other field needing to change.
    private static func resolvedSourcePoint(for geometry: LocalAdjustmentGeometry, extent: CGRect) -> CGPoint {
        switch geometry.healMode {
        case .clone:
            if let sourceX = geometry.sourceX, let sourceY = geometry.sourceY {
                return imagePoint(x: sourceX, y: sourceY, extent: extent)
            }
            // Clone mode selected but no source point placed yet -- fall
            // back to the same conservative auto-offset heal mode uses,
            // rather than sampling the target itself (a guaranteed no-op)
            // or crashing.
            return autoSourcePoint(for: geometry, extent: extent)
        case .heal:
            return autoSourcePoint(for: geometry, extent: extent)
        }
    }

    /// `.heal`'s "auto-sampled surrounding texture" (design spec §6.7),
    /// implemented as a fixed offset directly above the target by a
    /// multiple of the brush radius -- mirrored below the target instead
    /// when that would fall outside the image (too close to the top edge).
    /// Conservative and deterministic, not content-aware: it reads fine
    /// against a roughly uniform nearby background, but can visibly sample
    /// unrelated content on a busy image. `.clone` mode with an explicit
    /// source point is the reliable path for anything but a small blemish
    /// on a flat area.
    private static func autoSourcePoint(for geometry: LocalAdjustmentGeometry, extent: CGRect) -> CGPoint {
        let offsetNormalized = min(geometry.radius * autoHealOffsetMultiplier, 0.45)
        let above = geometry.y - offsetNormalized
        let normalizedY = above >= 0 ? above : min(geometry.y + offsetNormalized, 1)
        return imagePoint(x: geometry.x, y: normalizedY, extent: extent)
    }

    private static let autoHealOffsetMultiplier: Double = 2.5

    /// A white-centered, soft-edged circular mask (`CIRadialGradient`),
    /// analogous to `AdjustmentPipeline.applyVignette`'s own radial mask:
    /// `feather` `0` produces as hard an edge as this implementation
    /// produces (a thin fixed-width transition, never literally zero-width,
    /// to avoid degenerate `radius0 == radius1` artifacts); `100` fades the
    /// full radius from the center outward.
    private static func healMask(center: CGPoint, radius: CGFloat, feather: Double, extent: CGRect) -> CIImage {
        let outerRadius = max(radius, 1)
        let featherFraction = CGFloat(min(max(feather / 100, 0), 1))
        let featherDistance = max(featherFraction * outerRadius, 0.5)
        let innerRadius = max(outerRadius - featherDistance, 0)

        let gradient = CIFilter.radialGradient()
        gradient.center = center
        gradient.radius0 = Float(innerRadius)
        gradient.radius1 = Float(outerRadius)
        gradient.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        gradient.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        let mask = gradient.outputImage ?? CIImage(color: .clear)
        return mask.cropped(to: extent)
    }
}

/// Applies one `LocalAdjustmentPatch`'s mini-adjustments to a *full copy* of
/// an image -- the caller (`LocalAdjustmentRenderer`) is what confines the
/// result to the gradient's masked region via `CIBlendWithMask`.
///
/// Reuses `AdjustmentPipeline` for the seven fields it already knows how to
/// render (exposure/contrast/highlights/shadows/whites/blacks/saturation),
/// by synthesizing a `PhotoAdjustments` with every *other* field left at
/// its identity default -- `AdjustmentPipeline.apply(_:to:)` already skips
/// every stage whose parameter is at identity, so this costs nothing extra
/// for the fields a local adjustment never touches (vignette, grain, HSL,
/// sharpening, ...), and there is no risk of a local edit accidentally
/// carrying one of those along.
///
/// `temperature`/`tint` are the two fields `AdjustmentPipeline` does *not*
/// render at all -- for the photo's *global* white balance those are baked
/// into the RAW decode itself (`CoreImageRawDecoder`'s own doc comment:
/// "`CITemperatureAndTint` after the fact would fight the decoder's own
/// rendering"). That constraint is about not fighting a whole-frame
/// decision with a second whole-frame one; it does not apply here, because
/// there is no such thing as a per-region RAW decode -- a local warm/cool
/// shift can only ever happen post-decode. `CITemperatureAndTint` is used
/// directly for exactly those two fields, entirely independent of
/// `AdjustmentPipeline`.
enum LocalAdjustmentPatchRenderer {
    static func apply(_ patch: LocalAdjustmentPatch, to image: CIImage) -> CIImage {
        var working = image

        let basicAdjustments = PhotoAdjustments(
            exposure: patch.exposure ?? 0,
            contrast: patch.contrast ?? 0,
            highlights: patch.highlights ?? 0,
            shadows: patch.shadows ?? 0,
            whites: patch.whites ?? 0,
            blacks: patch.blacks ?? 0,
            saturation: patch.saturation ?? 0
        )
        if !basicAdjustments.isNeutral {
            working = AdjustmentPipeline().apply(basicAdjustments, to: working)
        }

        if let temperature = patch.temperature, temperature != 0 {
            working = applyTemperatureShift(temperature, to: working)
        }
        if let tint = patch.tint, tint != 0 {
            working = applyTintShift(tint, to: working)
        }

        return working
    }

    /// ±100 maps to the same ±4500K span `AdjustmentMapping
    /// .kelvinPerTemperatureUnit` uses for the global slider, shifting away
    /// from a fixed 6500K neutral reference -- there is no per-region
    /// as-shot baseline to shift from the way the global control has one.
    private static func applyTemperatureShift(_ value: Double, to image: CIImage) -> CIImage {
        let neutralKelvin: CGFloat = 6500
        let offset = CGFloat(value) * CGFloat(AdjustmentMapping.kelvinPerTemperatureUnit)
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: neutralKelvin, y: 0)
        filter.targetNeutral = CIVector(x: neutralKelvin - offset, y: 0)
        return filter.outputImage ?? image
    }

    private static func applyTintShift(_ value: Double, to image: CIImage) -> CIImage {
        let neutralKelvin: CGFloat = 6500
        let offset = CGFloat(value) * CGFloat(AdjustmentMapping.tintPerUnit)
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: neutralKelvin, y: 0)
        filter.targetNeutral = CIVector(x: neutralKelvin, y: -offset)
        return filter.outputImage ?? image
    }
}
