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
            case .radialGradient:
                working = applyRadialGradient(adjustment, to: working)
            case .brush:
                working = applyBrush(adjustment, to: working)
            case .luminanceRange:
                working = applyLuminanceRange(adjustment, to: working)
            case .colorRange:
                working = applyColorRange(adjustment, to: working)
            case .subject:
                working = applySubject(adjustment, to: working)
            case .background:
                working = applyBackground(adjustment, to: working)
            case .spotHeal:
                working = applySpotHeal(adjustment, to: working)
            }
        }
        return working
    }

    private static func applyMaskedAdjustment(_ adjustment: LocalAdjustment, mask: CIImage, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        guard adjustment.adjustments.isEmpty == false else { return image }

        var finalMask = mask.cropped(to: extent)

        // Handle inversion
        if adjustment.isInverted {
            let invert = CIFilter.colorInvert()
            invert.inputImage = finalMask
            finalMask = invert.outputImage?.cropped(to: extent) ?? finalMask
        }

        // Handle opacity (0...100)
        let opacity = Swift.min(Swift.max(adjustment.opacity, 0), 100) / 100.0
        if opacity < 0.999 {
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = finalMask
            matrix.rVector = CIVector(x: CGFloat(opacity), y: 0, z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: CGFloat(opacity), z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(opacity), w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
            finalMask = matrix.outputImage?.cropped(to: extent) ?? finalMask
        }

        let adjustedImage = LocalAdjustmentPatchRenderer.apply(adjustment.adjustments, to: image)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = adjustedImage
        blend.backgroundImage = image
        blend.maskImage = finalMask
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    private static func applyLinearGradient(_ adjustment: LocalAdjustment, to image: CIImage) -> CIImage {
        let mask = linearGradientMask(adjustment.geometry, extent: image.extent)
        return applyMaskedAdjustment(adjustment, mask: mask, to: image)
    }

    private static func applyRadialGradient(_ adjustment: LocalAdjustment, to image: CIImage) -> CIImage {
        let mask = radialGradientMask(adjustment.geometry, extent: image.extent)
        return applyMaskedAdjustment(adjustment, mask: mask, to: image)
    }

    private static func applyBrush(_ adjustment: LocalAdjustment, to image: CIImage) -> CIImage {
        let mask = brushMask(adjustment.geometry, extent: image.extent)
        return applyMaskedAdjustment(adjustment, mask: mask, to: image)
    }

    private static func applyLuminanceRange(_ adjustment: LocalAdjustment, to image: CIImage) -> CIImage {
        let mask = luminanceRangeMask(adjustment.geometry, extent: image.extent, sourceImage: image)
        return applyMaskedAdjustment(adjustment, mask: mask, to: image)
    }

    private static func applyColorRange(_ adjustment: LocalAdjustment, to image: CIImage) -> CIImage {
        let mask = colorRangeMask(adjustment.geometry, extent: image.extent, sourceImage: image)
        return applyMaskedAdjustment(adjustment, mask: mask, to: image)
    }

    private static func applySubject(_ adjustment: LocalAdjustment, to image: CIImage) -> CIImage {
        let mask = VisionSegmentationService.generateForegroundMask(for: image)
        return applyMaskedAdjustment(adjustment, mask: mask, to: image)
    }

    private static func applyBackground(_ adjustment: LocalAdjustment, to image: CIImage) -> CIImage {
        let fgMask = VisionSegmentationService.generateForegroundMask(for: image)
        let invert = CIFilter.colorInvert()
        invert.inputImage = fgMask
        let bgMask = invert.outputImage?.cropped(to: image.extent) ?? fgMask
        return applyMaskedAdjustment(adjustment, mask: bgMask, to: image)
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

    private static func radialGradientMask(_ geometry: LocalAdjustmentGeometry, extent: CGRect) -> CIImage {
        let center = imagePoint(x: geometry.x, y: geometry.y, extent: extent)
        let minDim = min(extent.width, extent.height)
        let radiusX = max(CGFloat(geometry.radius), 0.001) * minDim
        let radiusY = max(CGFloat(geometry.radialRadiusY ?? geometry.radius), 0.001) * minDim
        let maxRadius = max(radiusX, radiusY)

        let featherFraction = CGFloat(min(max(geometry.feather / 100, 0), 1))
        let innerRadius = max(maxRadius * (1 - featherFraction), 0)

        guard let filter = CIFilter(name: "CIRadialGradient") else {
            return CIImage(color: .white).cropped(to: extent)
        }
        filter.setValue(CIVector(cgPoint: center), forKey: "inputCenter")
        filter.setValue(Float(innerRadius), forKey: "inputRadius0")
        filter.setValue(Float(maxRadius), forKey: "inputRadius1")
        filter.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
        filter.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor1")

        var mask = filter.outputImage ?? CIImage(color: .clear)

        if radiusY > 0 && radiusX > 0 && abs(radiusX - radiusY) > 0.001 {
            let scaleY = radiusY / radiusX
            var t = CGAffineTransform(translationX: -center.x, y: -center.y)
            t = t.concatenating(CGAffineTransform(scaleX: 1.0, y: scaleY))
            t = t.concatenating(CGAffineTransform(translationX: center.x, y: center.y))
            mask = mask.transformed(by: t)
        }
        return mask.cropped(to: extent)
    }

    private static func brushMask(_ geometry: LocalAdjustmentGeometry, extent: CGRect) -> CIImage {
        let strokes = geometry.brushStrokes
        guard !strokes.isEmpty else {
            let center = imagePoint(x: geometry.x, y: geometry.y, extent: extent)
            let radiusPixels = max(CGFloat(geometry.radius), 0.001) * min(extent.width, extent.height)
            return healMask(center: center, radius: radiusPixels, feather: geometry.feather, extent: extent)
        }

        var accumulatedMask = CIImage(color: .clear).cropped(to: extent)
        for stroke in strokes {
            let radiusPixels = max(CGFloat(stroke.radius), 0.001) * min(extent.width, extent.height)
            for point in stroke.points {
                let center = imagePoint(x: point.x, y: point.y, extent: extent)
                let pressureScale = CGFloat(point.pressure ?? 1.0)
                let effectiveRadius = max(radiusPixels * pressureScale, 1.0)
                let dotMask = healMask(center: center, radius: effectiveRadius, feather: stroke.feather, extent: extent)
                let composite = CIFilter.sourceOverCompositing()
                composite.inputImage = dotMask
                composite.backgroundImage = accumulatedMask
                accumulatedMask = composite.outputImage?.cropped(to: extent) ?? accumulatedMask
            }
        }
        return accumulatedMask
    }

    private static func luminanceRangeMask(_ geometry: LocalAdjustmentGeometry, extent: CGRect, sourceImage: CIImage) -> CIImage {
        let minLum = CGFloat(geometry.luminanceMin ?? 0.0)
        let maxLum = CGFloat(geometry.luminanceMax ?? 1.0)
        let feather = CGFloat(geometry.feather) / 100.0 * 0.2

        let grayscaleFilter = CIFilter.colorMatrix()
        grayscaleFilter.inputImage = sourceImage
        grayscaleFilter.rVector = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        grayscaleFilter.gVector = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        grayscaleFilter.bVector = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        grayscaleFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let gray = grayscaleFilter.outputImage?.cropped(to: extent) else {
            return CIImage(color: .white).cropped(to: extent)
        }

        return rangeLUTMask(gray: gray, minVal: minLum, maxVal: maxLum, feather: feather, extent: extent)
    }

    private static func rangeLUTMask(gray: CIImage, minVal: CGFloat, maxVal: CGFloat, feather: CGFloat, extent: CGRect) -> CIImage {
        var table = [UInt8](repeating: 0, count: 256)
        let f = max(feather, 0.001)
        for i in 0..<256 {
            let v = CGFloat(i) / 255.0
            var weight: CGFloat = 0
            if v >= minVal && v <= maxVal {
                let distToEdge = min(v - minVal, maxVal - v)
                weight = min(distToEdge / f, 1.0)
            } else if v < minVal && minVal - v <= f {
                weight = max(1.0 - (minVal - v) / f, 0)
            } else if v > maxVal && v - maxVal <= f {
                weight = max(1.0 - (v - maxVal) / f, 0)
            }
            table[i] = UInt8(round(weight * 255.0))
        }
        let data = Data(table)
        let colorTable = CIFilter.colorMap()
        colorTable.inputImage = gray
        let lutImage = CIImage(bitmapData: data, bytesPerRow: 256, size: CGSize(width: 256, height: 1), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        colorTable.gradientImage = lutImage
        return colorTable.outputImage?.cropped(to: extent) ?? gray
    }

    private static func colorRangeMask(_ geometry: LocalAdjustmentGeometry, extent: CGRect, sourceImage: CIImage) -> CIImage {
        let targetHue = geometry.colorTargetHue ?? 0.0
        let tolerance = geometry.colorHueTolerance ?? 30.0

        let angleRadians = -CGFloat(targetHue * .pi / 180.0)
        let hueAdjust = CIFilter.hueAdjust()
        hueAdjust.inputImage = sourceImage
        hueAdjust.angle = Float(angleRadians)
        guard let shifted = hueAdjust.outputImage?.cropped(to: extent) else {
            return CIImage(color: .white).cropped(to: extent)
        }

        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = shifted
        matrix.rVector = CIVector(x: 1, y: -0.5, z: -0.5, w: 0)
        matrix.gVector = CIVector(x: 1, y: -0.5, z: -0.5, w: 0)
        matrix.bVector = CIVector(x: 1, y: -0.5, z: -0.5, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let redDominance = matrix.outputImage?.cropped(to: extent) else {
            return CIImage(color: .white).cropped(to: extent)
        }

        let scale = CGFloat(max(180.0 / max(tolerance, 5.0), 1.0))
        let scaleFilter = CIFilter.colorMatrix()
        scaleFilter.inputImage = redDominance
        scaleFilter.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        scaleFilter.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
        scaleFilter.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
        scaleFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)

        let clampFilter = CIFilter.colorClamp()
        clampFilter.inputImage = scaleFilter.outputImage
        clampFilter.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clampFilter.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)

        return clampFilter.outputImage?.cropped(to: extent) ?? redDominance
    }

    // MARK: - Spot heal / clone / red-eye

    private static func applySpotHeal(_ adjustment: LocalAdjustment, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let geometry = adjustment.geometry
        if geometry.healMode == .redEye {
            return applyRedEye(adjustment, to: image)
        }

        let target = imagePoint(x: geometry.x, y: geometry.y, extent: extent)
        let source = resolvedSourcePoint(for: geometry, extent: extent)

        let dx = target.x - source.x
        let dy = target.y - source.y
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

    private static func applyRedEye(_ adjustment: LocalAdjustment, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let geometry = adjustment.geometry
        let target = imagePoint(x: geometry.x, y: geometry.y, extent: extent)
        let pupilRadius = max(CGFloat(geometry.redEyePupilRadius ?? geometry.radius), 0.001) * min(extent.width, extent.height)
        let mask = healMask(center: target, radius: pupilRadius, feather: geometry.feather, extent: extent)

        let desatRed = CIFilter.colorMatrix()
        desatRed.inputImage = image
        desatRed.rVector = CIVector(x: 0.0, y: 0.5, z: 0.5, w: 0)
        desatRed.gVector = CIVector(x: 0.0, y: 1.0, z: 0.0, w: 0)
        desatRed.bVector = CIVector(x: 0.0, y: 0.0, z: 1.0, w: 0)
        desatRed.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1)
        guard let desaturated = desatRed.outputImage?.cropped(to: extent) else { return image }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = desaturated
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
        case .redEye:
            return imagePoint(x: geometry.x, y: geometry.y, extent: extent)
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
