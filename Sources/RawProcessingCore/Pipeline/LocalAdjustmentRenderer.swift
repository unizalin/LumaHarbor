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
/// Task 4.2 scope: linear gradient only. A `.spotHeal` entry is left
/// untouched by this renderer regardless of `isEnabled` -- that is Task
/// 4.4's job, and applying gradient math against heal-shaped geometry
/// (`radius`/`sourceX`/`sourceY`, not `angleDegrees`/`range`) would be
/// meaningless.
public enum LocalAdjustmentRenderer {
    public static func apply(_ localAdjustments: [LocalAdjustment], to image: CIImage) -> CIImage {
        var working = image
        for adjustment in localAdjustments where adjustment.isEnabled && adjustment.kind == .linearGradient {
            working = applyLinearGradient(adjustment, to: working)
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
        // `LocalAdjustmentGeometry.x`/`.y` are normalized, origin top-left
        // (matching `NormalizedCropRect`'s own convention); Core Image's
        // storage origin is bottom-left, y-up, so the y axis is flipped
        // converting from one to the other -- same conversion
        // `GeometryRenderer.cropped(_:to:)` already does for crop.
        let anchor = CGPoint(
            x: extent.minX + CGFloat(geometry.x) * extent.width,
            y: extent.minY + CGFloat(1 - geometry.y) * extent.height
        )

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
