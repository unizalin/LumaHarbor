import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Builds the Core Image graph for one set of adjustments.
///
/// Spec §9 pipeline:
///   ARW → CIRAWFilter decode → linear wide-gamut working image
///       → basic adjustment chain → display transform → Metal render
///
/// White balance is already baked in by the decoder (see `CoreImageRawDecoder`),
/// so this type covers exposure, tone and colour.
public struct AdjustmentPipeline: Sendable {
    public init() {}

    /// Applies the chain to an already-decoded image.
    ///
    /// Every stage is skipped when its parameter is at identity — a neutral
    /// photo renders as a straight passthrough, which is what makes the
    /// before/after comparison exact rather than approximately equal.
    public func apply(_ adjustments: PhotoAdjustments, to image: CIImage) -> CIImage {
        apply(AdjustmentMapping.renderParameters(for: adjustments), to: image)
    }

    public func apply(_ parameters: RenderParameters, to image: CIImage) -> CIImage {
        var working = image

        // 1. Exposure, in linear light, where an EV step is a clean multiply.
        if !parameters.isExposureIdentity {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = working
            filter.ev = Float(parameters.exposureEV)
            working = filter.outputImage ?? working
        }

        let needsPerceptualStage = !parameters.isToneCurveIdentity
            || !parameters.isContrastIdentity
            || !parameters.isSaturationIdentity
            || !parameters.isVibranceIdentity

        if needsPerceptualStage {
            // 2. Move to a gamma-encoded space. Tone curves, contrast and
            // saturation are all defined against perceptual values; running them
            // on linear data crushes shadows and skews hue.
            let toGamma = CIFilter.linearToSRGBToneCurve()
            toGamma.inputImage = working
            working = toGamma.outputImage ?? working

            // 3. Blacks / shadows / highlights / whites as one curve.
            if !parameters.isToneCurveIdentity {
                working = Self.applyToneCurve(parameters.toneCurve, to: working)
            }

            // 4. Contrast and saturation share one filter pass.
            if !parameters.isContrastIdentity || !parameters.isSaturationIdentity {
                let colorControls = CIFilter.colorControls()
                colorControls.inputImage = working
                colorControls.brightness = 0
                colorControls.contrast = Float(parameters.contrast)
                colorControls.saturation = Float(parameters.saturation)
                working = colorControls.outputImage ?? working
            }

            // 5. Vibrance last, so it acts on the already-graded colours.
            if !parameters.isVibranceIdentity {
                let vibrance = CIFilter.vibrance()
                vibrance.inputImage = working
                vibrance.amount = Float(parameters.vibrance)
                working = vibrance.outputImage ?? working
            }

            // 6. Back to linear so the CIContext's own output transform is the
            // only place the display/export encoding is decided.
            let toLinear = CIFilter.sRGBToneCurveToLinear()
            toLinear.inputImage = working
            working = toLinear.outputImage ?? working
        }

        // 8. Sharpening (spec §4.2 step 8) — a post-colour detail effect, so it
        // runs after the perceptual stage and its own linear round-trip, not
        // inside it.
        if !parameters.isSharpeningIdentity {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = working
            filter.sharpness = Float(parameters.sharpening.amount * AdjustmentMapping.sharpenLuminanceSharpnessSpan)
            filter.radius = Float(parameters.sharpening.radius)
            working = filter.outputImage ?? working
        }

        // 9. Noise reduction (spec §4.2 step 9). CINoiseReduction exposes one
        // noise-level knob and one sharpness knob, not independent
        // luminance/colour controls, so both amounts are averaged into the
        // former and both detail values into the latter (see the span
        // constants' doc comments in AdjustmentMapping).
        if !parameters.isNoiseReductionIdentity {
            let filter = CIFilter.noiseReduction()
            filter.inputImage = working
            let averageAmount = (parameters.noiseReduction.luminanceAmount + parameters.noiseReduction.colorAmount) / 2
            let averageDetail = (parameters.noiseReduction.luminanceDetail + parameters.noiseReduction.colorDetail) / 2
            filter.noiseLevel = Float(averageAmount * AdjustmentMapping.noiseReductionNoiseLevelSpan)
            filter.sharpness = Float(averageDetail * AdjustmentMapping.noiseReductionSharpnessSpan)
            working = filter.outputImage ?? working
        }

        // 10. Vignette (spec §4.2 step 10). Built with an explicit radial-alpha
        // composite rather than CIVignette/CIVignetteEffect because both only
        // ever darken; this adjustment is bidirectional (spec §3.6: negative
        // darkens, positive brightens).
        if !parameters.isVignetteIdentity {
            working = Self.applyVignette(parameters.vignette, to: working)
        }

        return working
    }

    private static func applyVignette(_ vignette: Vignette, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let centre = CGPoint(x: extent.midX, y: extent.midY)
        let halfDiagonal = (extent.width * extent.width + extent.height * extent.height).squareRoot() / 2

        // midpoint 0...100 -> inner radius 0...halfDiagonal (where the effect
        // starts); feather 0...100 -> how far past the inner radius it takes to
        // reach full strength. roundness biases the gradient toward a circle
        // (positive) or the image's own aspect ratio (negative) by scaling the
        // gradient anisotropically before compositing -- a first-pass
        // approximation flagged for manual visual confirmation (spec §6, this
        // plan's Task 8).
        let innerRadius = (vignette.midpoint / 100) * halfDiagonal
        let featherDistance = max((vignette.feather / 100) * halfDiagonal, 1)
        let outerRadius = innerRadius + featherDistance

        let gradient = CIFilter.radialGradient()
        gradient.center = centre
        gradient.radius0 = Float(innerRadius)
        gradient.radius1 = Float(outerRadius)
        let brightening = vignette.amount > 0
        let tintAlpha = CGFloat(abs(vignette.amount) / 100)
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        gradient.color1 = brightening
            ? CIColor(red: 1, green: 1, blue: 1, alpha: tintAlpha)
            : CIColor(red: 0, green: 0, blue: 0, alpha: tintAlpha)
        guard var mask = gradient.outputImage else { return image }

        if vignette.roundness != 0 {
            // Scale the gradient about the image centre before cropping: a
            // positive roundness compresses it toward a circle on the longer
            // axis, negative stretches it to hug the frame's own aspect ratio.
            let aspect = extent.width / extent.height
            let bias = vignette.roundness / 100
            let scaleX = aspect >= 1 ? 1 - bias * (1 - 1 / aspect) : 1
            let scaleY = aspect < 1 ? 1 - bias * (1 - aspect) : 1
            let toOrigin = CGAffineTransform(translationX: -centre.x, y: -centre.y)
            let scale = CGAffineTransform(scaleX: scaleX, y: scaleY)
            let backToCentre = CGAffineTransform(translationX: centre.x, y: centre.y)
            mask = mask.transformed(by: toOrigin.concatenating(scale).concatenating(backToCentre))
        }

        let composite = CIFilter.sourceOverCompositing()
        composite.inputImage = mask.cropped(to: extent)
        composite.backgroundImage = image
        return composite.outputImage ?? image
    }

    private static func applyToneCurve(_ points: [ToneCurvePoint], to image: CIImage) -> CIImage {
        guard points.count == 5 else { return image }
        let filter = CIFilter.toneCurve()
        filter.inputImage = image
        filter.point0 = CGPoint(x: points[0].x, y: points[0].y)
        filter.point1 = CGPoint(x: points[1].x, y: points[1].y)
        filter.point2 = CGPoint(x: points[2].x, y: points[2].y)
        filter.point3 = CGPoint(x: points[3].x, y: points[3].y)
        filter.point4 = CGPoint(x: points[4].x, y: points[4].y)
        return filter.outputImage ?? image
    }
}
