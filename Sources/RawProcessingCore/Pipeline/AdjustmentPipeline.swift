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

        return working
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
