@preconcurrency import CoreImage
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
    ///
    /// - Parameter scaleFactor: how far `image` has already been downscaled
    ///   from the source RAW's native pixel size (1 for a full-resolution
    ///   export decode, `<1` for a downsampled interactive/preview decode —
    ///   see `CoreImageRawDecoder.scaleFactor`). Spec §7 Gate B3: sharpening
    ///   and grain are defined against `1`, so a downsampled preview scales
    ///   their pixel-radius knobs down by the same factor rather than
    ///   applying the same absolute radius the full-resolution export would,
    ///   which would otherwise read as visibly tighter/finer in preview than
    ///   in the exported file. Export always passes `1`, so exported output
    ///   is unaffected by this parameter's existence.
    public func apply(_ adjustments: PhotoAdjustments, to image: CIImage, scaleFactor: Double = 1) -> CIImage {
        apply(AdjustmentMapping.renderParameters(for: adjustments), to: image, scaleFactor: scaleFactor)
    }

    public func apply(_ parameters: RenderParameters, to image: CIImage, scaleFactor: Double = 1) -> CIImage {
        var working = image

        // 0. Lens correction, manual/bundled-profile modes only (design spec
        // §8 step 2; .automatic instead runs inside CoreImageRawDecoder --
        // see D-007 for why this can't run strictly before white balance).
        if !parameters.isLensCorrectionIdentity {
            working = Self.applyLensCorrection(parameters.lensCorrection, to: working)
        }

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
            || !parameters.isAdvancedToneCurveIdentity
            || !parameters.isSplitToningIdentity
            || !parameters.isHSLIdentity
            || !parameters.isPresenceIdentity
            || !parameters.isColorGradingIdentity
            || !parameters.isMonochromeIdentity
            || !parameters.isRenderingProfileIdentity

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

            // 5.6. Presence (P4, design spec §8 step 5): texture, clarity,
            // dehaze — local/mid-frequency contrast tools distinct from the
            // global contrast slider above.
            if !parameters.isPresenceIdentity {
                working = Self.applyPresence(parameters.presence, to: working, scaleFactor: scaleFactor)
            }

            // 5.5. Advanced tone curve (spec §4.2 step 5.5) — a second,
            // independent curve layered on top of the four-slider one.
            if !parameters.isAdvancedToneCurveIdentity {
                working = Self.applyAdvancedToneCurve(parameters.advancedToneCurve, to: working)
            }

            // 6. HSL (spec §4.2 step 6).
            if !parameters.isHSLIdentity {
                working = Self.applyHSL(parameters.hsl, to: working)
            }

            // 6.5. Color Grading (P4, design spec §8 step 5) — a three-zone
            // (shadows/midtones/highlights) plus global successor to Split
            // Toning below, layered before it so a user combining both tools
            // sees Color Grading's broader strokes first.
            if !parameters.isColorGradingIdentity {
                working = Self.applyColorGrading(parameters.colorGrading, to: working)
            }

            // 6.6. Monochrome (P4): an 8-band colour-to-grey mixer. Runs after
            // every colour tool above so it truly replaces the final colour
            // result, not fights with tools applied later.
            if !parameters.isMonochromeIdentity {
                working = Self.applyMonochrome(parameters.monochrome, to: working)
            }

            // 6.7. Rendering Profile (P4): a small set of built-in creative
            // styles layered as coefficients onto the existing tone/colour
            // primitives.
            if !parameters.isRenderingProfileIdentity {
                working = Self.applyRenderingProfile(parameters.renderingProfile, to: working)
            }

            // 7. Split toning (spec §4.2 step 7): tint shadows and highlights
            // independently using a luminance mask to blend two flat colour
            // layers, weighted by `balance`.
            if !parameters.isSplitToningIdentity {
                working = Self.applySplitToning(parameters.splitToning, to: working)
            }

            // 6. Back to linear so the CIContext's own output transform is the
            // only place the display/export encoding is decided.
            let toLinear = CIFilter.sRGBToneCurveToLinear()
            toLinear.inputImage = working
            working = toLinear.outputImage ?? working
        }

        // 8. Sharpening (spec §4.2 step 8) — a post-colour detail effect, so it
        // runs after the perceptual stage and its own linear round-trip, not
        // inside it. CISharpenLuminance exposes exactly two knobs
        // (`inputSharpness`, `inputRadius`), so only `amount` and `radius` are
        // read here: `Sharpening.detail` and `Sharpening.masking` have no
        // corresponding filter parameter in this implementation. They are still
        // decoded, clamped and round-tripped so a Lightroom-authored sidecar or
        // (next spec) an imported `.xmp` keeps them intact for a future
        // implementation that can honour them, rather than silently dropping
        // them on the first save.
        if !parameters.isSharpeningIdentity {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = working
            filter.sharpness = Float(parameters.sharpening.amount * AdjustmentMapping.sharpenLuminanceSharpnessSpan)
            filter.radius = Float(parameters.sharpening.radius * scaleFactor)
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

        // 11. Grain (spec §4.2 step 11) — synthetic per-pixel luminance noise,
        // generated once at the image's own extent and blended in proportion
        // to amount. size / roughness shape the noise before blending: size
        // widens the grain (blur radius scales up), roughness widens
        // amountScale's magnitude, making the grain read more strongly.
        if !parameters.isGrainIdentity {
            working = Self.applyGrain(parameters.grain, to: working, scaleFactor: scaleFactor)
        }

        return working
    }

    private static func applyGrain(_ grain: Grain, to image: CIImage, scaleFactor: Double) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let noise = CIFilter.randomGenerator()
        guard var noiseImage = noise.outputImage else { return image }

        // size 0...100 -> blur radius 0...4 at scaleFactor 1 (spec §7 Gate
        // B3); identical noise blurred more reads as larger grain clumps.
        // Scaling the radius down with the image keeps a downsampled preview
        // from showing visibly coarser clumps than the full-resolution
        // export will actually have. This does not fully solve
        // resolution-dependence for grain: the *unblurred* random noise
        // texture underneath is generated at one sample per decoded pixel,
        // so its base frequency is still tied to decode resolution the same
        // way a sensor's own pixel-level noise is -- fixing that would mean
        // generating grain at a fixed physical frequency independent of
        // decode size, which is a larger change than this radius fix covers.
        let blurRadius = (grain.size / 100) * 4 * scaleFactor
        if blurRadius > 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = noiseImage
            blur.radius = Float(blurRadius)
            noiseImage = blur.outputImage ?? noiseImage
        }

        // Recentre the (0...1 per channel, high-frequency) random noise around
        // 0.5 grey and scale its deviation by amount and roughness, so it can
        // be composited as a soft-light layer that leaves flat mid-tones
        // mostly alone and roughens texture elsewhere.
        let amountScale = (grain.amount / 100) * (0.15 + (grain.roughness / 100) * 0.25)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = noiseImage
        let vector = CIVector(x: CGFloat(amountScale), y: 0, z: 0, w: 0)
        matrix.rVector = vector
        matrix.gVector = vector
        matrix.bVector = vector
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.biasVector = CIVector(x: 0.5 - 0.5 * amountScale, y: 0.5 - 0.5 * amountScale, z: 0.5 - 0.5 * amountScale, w: 1)
        guard let scaledNoise = matrix.outputImage else { return image }

        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = scaledNoise.cropped(to: extent)
        blend.backgroundImage = image
        return blend.outputImage ?? image
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

    /// Manual/bundled-profile lens correction only -- `.automatic` runs
    /// entirely inside `CoreImageRawDecoder` and never reaches this function
    /// (design spec §6.4, D-007). Built entirely from stock Core Image
    /// filters (P4 spec §1 item 3): no custom warp kernel, so the geometric
    /// correction here is a documented approximation of a true Lensfun-style
    /// polynomial radial model, not a literal match.
    private static func applyLensCorrection(_ lens: LensCorrectionAdjustments, to image: CIImage) -> CIImage {
        guard lens.mode == .manual || lens.mode == .bundledProfile else { return image }
        var working = image
        if lens.distortionAmount != 0 {
            working = Self.applyLensDistortion(amount: lens.distortionAmount, to: working)
        }
        if lens.vignettingAmount != 0 {
            working = Self.applyLensVignetting(amount: lens.vignettingAmount, to: working)
        }
        if lens.tcaAmount != 0 {
            working = Self.applyLensTCA(amount: lens.tcaAmount, to: working)
        }
        return working
    }

    /// Positive corrects barrel distortion (pulls the frame in from the
    /// edges, `CIPinchDistortion`); negative corrects pincushion distortion
    /// (pushes it back out, `CIBumpDistortion`). Both are Apple's own stock
    /// radial-displacement filters, not a Lensfun polynomial evaluator.
    private static func applyLensDistortion(amount: Double, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let center = CGPoint(x: extent.midX, y: extent.midY)
        // Reaches the corners, not just the inscribed circle, so the effect
        // is visible across the whole frame rather than only near the centre.
        let radius = Float((extent.width * extent.width + extent.height * extent.height).squareRoot() / 2)
        if amount > 0 {
            let filter = CIFilter.pinchDistortion()
            filter.inputImage = image
            filter.center = center
            filter.radius = radius
            filter.scale = Float(amount / 100)
            return filter.outputImage?.cropped(to: extent) ?? image
        } else {
            let filter = CIFilter.bumpDistortion()
            filter.inputImage = image
            filter.center = center
            filter.radius = radius
            filter.scale = Float(-amount / 100)
            return filter.outputImage?.cropped(to: extent) ?? image
        }
    }

    /// Corrects lens light falloff: positive brightens the corners (undoing
    /// vignetting the lens itself produced), negative darkens them further.
    /// Same `CIRadialGradient`-multiply technique as the artistic `Vignette`
    /// tool (`applyVignette` above), but with only one control -- lens
    /// vignetting falls off on a roughly fixed radial curve, unlike the
    /// artistic tool's independently adjustable midpoint/feather/roundness.
    private static func applyLensVignetting(amount: Double, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let halfDiagonal = (extent.width * extent.width + extent.height * extent.height).squareRoot() / 2

        let gradient = CIFilter.radialGradient()
        gradient.center = center
        gradient.radius0 = Float(halfDiagonal * 0.3)
        gradient.radius1 = Float(halfDiagonal)
        let brightening = amount > 0
        let tintAlpha = CGFloat(abs(amount) / 100)
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        gradient.color1 = brightening
            ? CIColor(red: 1, green: 1, blue: 1, alpha: tintAlpha)
            : CIColor(red: 0, green: 0, blue: 0, alpha: tintAlpha)
        guard let mask = gradient.outputImage else { return image }

        let composite = CIFilter.sourceOverCompositing()
        composite.inputImage = mask.cropped(to: extent)
        composite.backgroundImage = image
        return composite.outputImage ?? image
    }

    /// Corrects lateral chromatic aberration by uniformly scaling the red and
    /// blue channels in opposite directions relative to the frame centre,
    /// leaving green untouched. A single deliberate simplification (P4 spec
    /// §1 item 3): real lateral CA magnitude grows with distance from centre
    /// (radially-varying), while a uniform affine scale is constant across
    /// the frame -- a real, testable correction, just not a literal
    /// per-radius match.
    private static func applyLensTCA(amount: Double, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let k = amount / 100 * 0.01 // small: a few pixels of channel shift at the frame edge, not a visible re-crop

        func isolateChannel(_ vector: CIVector) -> CIImage {
            let filter = CIFilter.colorMatrix()
            filter.inputImage = image
            filter.rVector = vector
            filter.gVector = vector
            filter.bVector = vector
            filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            filter.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            return filter.outputImage ?? image
        }
        func scaled(_ layer: CIImage, by scale: CGFloat) -> CIImage {
            let toOrigin = CGAffineTransform(translationX: -center.x, y: -center.y)
            let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
            let backToCenter = CGAffineTransform(translationX: center.x, y: center.y)
            return layer.transformed(by: toOrigin.concatenating(scaleTransform).concatenating(backToCenter))
        }

        let redLayer = scaled(isolateChannel(CIVector(x: 1, y: 0, z: 0, w: 0)), by: 1 + CGFloat(k))
        let greenLayer = isolateChannel(CIVector(x: 0, y: 1, z: 0, w: 0))
        let blueLayer = scaled(isolateChannel(CIVector(x: 0, y: 0, z: 1, w: 0)), by: 1 - CGFloat(k))

        let redPlusGreen = CIFilter.additionCompositing()
        redPlusGreen.inputImage = redLayer.cropped(to: extent)
        redPlusGreen.backgroundImage = greenLayer.cropped(to: extent)
        guard let rg = redPlusGreen.outputImage else { return image }

        let withBlue = CIFilter.additionCompositing()
        withBlue.inputImage = blueLayer.cropped(to: extent)
        withBlue.backgroundImage = rg
        guard let rgb = withBlue.outputImage else { return image }

        // The three isolated-channel layers each zero out alpha via their own
        // `aVector`, so this final pass restores the original alpha rather
        // than compositing three transparent layers.
        let restoreAlpha = CIFilter.colorMatrix()
        restoreAlpha.inputImage = rgb
        restoreAlpha.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        restoreAlpha.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        restoreAlpha.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        restoreAlpha.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        restoreAlpha.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return restoreAlpha.outputImage?.cropped(to: extent) ?? image
    }

    /// Loads both Core Image kernels used by this pipeline from the
    /// `CoreImageKernels.metallib` the `CompileMetalKernels` build plugin compiles
    /// from `Sources/RawProcessingCore/Kernels/AdjustmentKernels.metal`
    /// (spec §7 Gate B1). Both are declared `CIKernel`, not `CIColorKernel`:
    /// each needs a dependent texture read (the LUT lookup, the 8-band
    /// weighted blend) that only a general kernel's `sampler` argument
    /// supports -- see the doc comment on `hslAdjust` in the .metal file for
    /// why the CIKL predecessor got away with this from a `CIColorKernel`
    /// property despite the same restriction.
    private static let resourceBundle: Bundle? = {
        #if LUMAHARBOR_APP_BUNDLE
        guard let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("LumaHarbor_RawProcessingCore.bundle") else {
            return nil
        }
        return Bundle(url: resourceURL)
        #else
        return Bundle.module
        #endif
    }()

    private static let kernelLibrary: Data? = {
        guard let url = resourceBundle?.url(forResource: "CoreImageKernels", withExtension: "metallib") else { return nil }
        return try? Data(contentsOf: url)
    }()

    private static let advancedToneCurveKernel: CIKernel? = {
        guard let library = kernelLibrary else { return nil }
        return try? CIKernel(functionName: "advancedToneCurve", fromMetalLibraryData: library)
    }()

    /// Builds one RGBA 1D LUT texture packing all three composed channel
    /// tables (Composite∘Red in R, Composite∘Green in G, Composite∘Blue in
    /// B), so a single kernel pass can map R/G/B independently while still
    /// reading only one resource (P3, design spec §6.2/§8 step 4).
    private static func applyAdvancedToneCurve(_ curve: AdvancedToneCurve, to image: CIImage) -> CIImage {
        guard let kernel = advancedToneCurveKernel else { return image }
        let redTable = AdvancedToneCurveLUT.buildCombined(
            compositePoints: curve.points, channelPoints: curve.redPoints, resolution: 256
        )
        let greenTable = AdvancedToneCurveLUT.buildCombined(
            compositePoints: curve.points, channelPoints: curve.greenPoints, resolution: 256
        )
        let blueTable = AdvancedToneCurveLUT.buildCombined(
            compositePoints: curve.points, channelPoints: curve.bluePoints, resolution: 256
        )
        guard let lutImage = Self.makeLUTImage(red: redTable, green: greenTable, blue: blueTable) else { return image }
        let extent = image.extent
        let arguments: [Any] = [image, lutImage, Double(redTable.count)]
        // Input 0 is the source image, which is read 1:1, so its region of
        // interest is the destination rect. Input 1 is the 256x1 LUT, which
        // every destination pixel may read anywhere in -- returning the
        // destination rect for it means Core Image only guarantees the sliver
        // of LUT that happens to overlap the tile, and everything outside that
        // sliver samples undefined data (in practice: pure black past the
        // first ~256px of any real-sized image).
        return kernel.apply(
            extent: extent,
            roiCallback: { index, rect in index == 0 ? rect : lutImage.extent },
            arguments: arguments
        ) ?? image
    }

    /// Packs three 1D `[Float]` tables into one 1-row-high RGBA8 `CIImage`
    /// the kernel can sample -- red table in the R component, green table in
    /// G, blue table in B. Alpha is fixed at opaque; it carries no data.
    private static func makeLUTImage(red: [Float], green: [Float], blue: [Float]) -> CIImage? {
        let count = red.count
        guard count == green.count, count == blue.count else { return nil }
        var pixelData = [UInt8]()
        pixelData.reserveCapacity(count * 4)
        for i in 0..<count {
            let r = UInt8(max(0, min(255, red[i] * 255)))
            let g = UInt8(max(0, min(255, green[i] * 255)))
            let b = UInt8(max(0, min(255, blue[i] * 255)))
            pixelData.append(contentsOf: [r, g, b, 255])
        }
        return pixelData.withUnsafeBytes { buffer -> CIImage? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            let data = Data(bytes: baseAddress, count: pixelData.count)
            return CIImage(
                bitmapData: data,
                bytesPerRow: count * 4,
                size: CGSize(width: count, height: 1),
                format: .RGBA8,
                colorSpace: nil
            )
        }
    }

    /// See `AdjustmentKernels.metal`'s `hslAdjust` for the falloff math
    /// (spec §4.3), duplicated there rather than calling into
    /// `HSLKernelWeights` -- the GPU kernel can't call Swift -- so any
    /// change to the falloff shape must be made in both places; the unit
    /// tests on `HSLKernelWeights` exist specifically to keep this constant
    /// correct even though the kernel body itself can't be unit tested.
    private static let hslKernel: CIKernel? = {
        guard let library = kernelLibrary else { return nil }
        return try? CIKernel(functionName: "hslAdjust", fromMetalLibraryData: library)
    }()

    private static let monochromeKernel: CIKernel? = {
        guard let library = kernelLibrary else { return nil }
        return try? CIKernel(functionName: "monochromeMixer", fromMetalLibraryData: library)
    }()

    /// Colour adjustments applied earlier (HSL, Color Grading, etc.) are
    /// preserved but invisible while disabled -- guarded entirely by
    /// `isEnabled`, matching `MonochromeAdjustments.isIdentity` (design spec
    /// §6.3: "停用時保留彩色調整").
    private static func applyMonochrome(_ monochrome: MonochromeAdjustments, to image: CIImage) -> CIImage {
        guard monochrome.isEnabled, let kernel = monochromeKernel else { return image }
        let mixes = [
            monochrome.red, monochrome.orange, monochrome.yellow, monochrome.green,
            monochrome.aqua, monochrome.blue, monochrome.purple, monochrome.magenta
        ]
        let centers = HSLKernelWeights.bandCenters
        var arguments: [Any] = [image]
        arguments.append(contentsOf: centers.map { Double($0) })
        arguments.append(contentsOf: mixes.map { Double($0) })
        arguments.append(HSLKernelWeights.halfWidthDegrees)
        let extent = image.extent
        return kernel.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: arguments) ?? image
    }

    /// Texture and Clarity are both approximated as a signed local-contrast
    /// tool: a positive amount sharpens at the tool's characteristic radius
    /// (small for Texture, large for Clarity), a negative amount softens at
    /// the same radius (P4 spec §5.1 — a documented simplification, not a
    /// literal Lightroom-formula match). Dehaze approximates the common
    /// "contrast + saturation, weighted toward lifting black point" recipe.
    private static func applyPresence(_ presence: PresenceAdjustments, to image: CIImage, scaleFactor: Double) -> CIImage {
        var working = image
        working = Self.applyLocalContrast(amount: presence.texture, radius: 1.5 * scaleFactor, to: working)
        working = Self.applyLocalContrast(amount: presence.clarity, radius: 40 * scaleFactor, to: working)
        if presence.dehaze != 0 {
            let t = presence.dehaze / 100 // -1...1
            let colorControls = CIFilter.colorControls()
            colorControls.inputImage = working
            colorControls.brightness = 0
            colorControls.contrast = Float(1 + t * 0.3)
            colorControls.saturation = Float(1 + t * 0.25)
            working = colorControls.outputImage ?? working
        }
        return working
    }

    /// Shared by Texture and Clarity: positive sharpens, negative blurs, at
    /// the caller's chosen radius. `amount` is -100...100.
    private static func applyLocalContrast(amount: Double, radius: Double, to image: CIImage) -> CIImage {
        guard amount != 0 else { return image }
        if amount > 0 {
            let filter = CIFilter.unsharpMask()
            filter.inputImage = image
            filter.radius = Float(radius)
            filter.intensity = Float(amount / 100 * 2)
            return filter.outputImage ?? image
        } else {
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = image
            filter.radius = Float(-amount / 100 * radius)
            return filter.outputImage?.cropped(to: image.extent) ?? image
        }
    }

    /// Blends `RenderingProfileCatalog`'s coefficients onto the existing
    /// contrast/saturation primitives, scaled by `amount` (P4 spec §4).
    /// Unrecognised or absent `profileID` is a no-op — never guessed.
    private static func applyRenderingProfile(_ selection: RenderingProfileSelection, to image: CIImage) -> CIImage {
        guard let profileID = selection.profileID,
              let coefficients = RenderingProfileCatalog.coefficients(for: profileID) else { return image }
        let t = selection.amount / 100
        guard coefficients.saturationDelta != 0 || coefficients.contrastDelta != 0
            || coefficients.shadowsDelta != 0 || coefficients.highlightsDelta != 0 else { return image }

        var working = image
        if coefficients.contrastDelta != 0 || coefficients.saturationDelta != 0 {
            let colorControls = CIFilter.colorControls()
            colorControls.inputImage = working
            colorControls.brightness = 0
            colorControls.contrast = Float(1 + (coefficients.contrastDelta / 100) * t)
            colorControls.saturation = Float(1 + (coefficients.saturationDelta / 100) * t)
            working = colorControls.outputImage ?? working
        }
        if coefficients.shadowsDelta != 0 || coefficients.highlightsDelta != 0 {
            let toneInput = PhotoAdjustments(
                highlights: coefficients.highlightsDelta * t, shadows: coefficients.shadowsDelta * t
            )
            working = Self.applyToneCurve(ToneCurveMapping.controlPoints(for: toneInput), to: working)
        }
        return working
    }

    private static func applyHSL(_ hsl: HSLAdjustments, to image: CIImage) -> CIImage {
        guard let kernel = hslKernel else { return image }
        let bands = [hsl.red, hsl.orange, hsl.yellow, hsl.green, hsl.aqua, hsl.blue, hsl.purple, hsl.magenta]
        let centers = HSLKernelWeights.bandCenters
        var arguments: [Any] = [image]
        arguments.append(contentsOf: centers.map { Double($0) })
        arguments.append(contentsOf: bands.map { Double($0.hue) })
        arguments.append(contentsOf: bands.map { Double($0.saturation) })
        arguments.append(contentsOf: bands.map { Double($0.luminance) })
        arguments.append(HSLKernelWeights.halfWidthDegrees)
        let extent = image.extent
        return kernel.apply(extent: extent, roiCallback: { _, rect in rect }, arguments: arguments) ?? image
    }

    /// HSB -> RGB done here in plain Swift, then tagged with the pipeline's
    /// own working colour space so no colour matching happens at all.
    ///
    /// The previous `NSColor(brightness: 0.5)` + `CIColor(color:)` build
    /// carried a calibrated/sRGB space, so `CIImage(color:)` colour-matched
    /// it into the linear working space and a nominal 0.5 grey arrived as
    /// 0.2140 — measured, not assumed. The soft-light blend below assumes
    /// this flat layer is neutral at exactly 0.5 in the *same* space the
    /// image is in, so every split-toning edit dimmed the whole frame
    /// instead of only tinting it.
    ///
    /// `CIColor(red:green:blue:alpha:)` with no colour space does **not**
    /// fix that: it is sRGB-tagged too and measures the same 0.2140. Only
    /// the explicit `colorSpace:` overload lands on 0.5. That is the right
    /// target: split toning and colour grading both run inside the
    /// gamma-encoded stage, after `CILinearToSRGBToneCurve`, where a mid-grey
    /// image pixel also reads 0.5 numerically (verified by render). The flat
    /// colours in `applyVignette` sidestep the whole question by only ever
    /// using 0 and 1, which are fixed points of the transfer function.
    ///
    /// Standard HSB algorithm: hue in degrees 0...360, saturation and value
    /// in 0...1. Shared by `applySplitToning` and `applyColorGrading`.
    private static func flatColor(hue: Double, saturation: Double, extent: CGRect) -> CIImage {
        let value = 0.5
        let s = min(max(saturation / 100, 0), 1)
        let wrapped = hue.truncatingRemainder(dividingBy: 360)
        let sector = (wrapped < 0 ? wrapped + 360 : wrapped) / 60
        let c = value * s
        let x = c * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let m = value - c
        let primed: (r: Double, g: Double, b: Double)
        switch sector {
        case ..<1.0: primed = (c, x, 0)
        case ..<2.0: primed = (x, c, 0)
        case ..<3.0: primed = (0, c, x)
        case ..<4.0: primed = (0, x, c)
        case ..<5.0: primed = (x, 0, c)
        default: primed = (c, 0, x)
        }
        let red = CGFloat(primed.r + m)
        let green = CGFloat(primed.g + m)
        let blue = CGFloat(primed.b + m)
        let color = CIColor(
            red: red, green: green, blue: blue, alpha: 1,
            colorSpace: ImageRenderService.workingColorSpace
        ) ?? CIColor(red: red, green: green, blue: blue, alpha: 1)
        return CIImage(color: color).cropped(to: extent)
    }

    /// 0 at black, 1 at white, biased by `balanceOffset` (already divided by
    /// its slider span) -- shared luminance-mask base for `applySplitToning`
    /// and `applyColorGrading`. Not clamped to 0...1 -- callers that need
    /// clamping (a mask consumer like `CIBlendWithMask`) do it themselves,
    /// since `applyColorGrading` clamps only after also blurring for
    /// `blending`.
    private static func balancedLuminanceMask(of image: CIImage, balanceOffset: Double) -> CIImage? {
        let luminanceMask = CIFilter.colorMatrix()
        luminanceMask.inputImage = image
        let lumaVector = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        luminanceMask.rVector = lumaVector
        luminanceMask.gVector = lumaVector
        luminanceMask.bVector = lumaVector
        luminanceMask.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        luminanceMask.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        let biasedMask = CIFilter.colorMatrix()
        biasedMask.inputImage = luminanceMask.outputImage
        biasedMask.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        biasedMask.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        biasedMask.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        biasedMask.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        biasedMask.biasVector = CIVector(x: CGFloat(balanceOffset), y: CGFloat(balanceOffset), z: CGFloat(balanceOffset), w: 0)
        return biasedMask.outputImage
    }

    private static func clamped01(_ image: CIImage) -> CIImage? {
        let filter = CIFilter.colorClamp()
        filter.inputImage = image
        filter.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        filter.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return filter.outputImage
    }

    /// Three-zone (shadows/midtones/highlights) plus a uniform global tint,
    /// layered as a design-spec-documented successor to Split Toning below
    /// (P4 spec §5.2). Shadow/midtone/highlight weights come from the same
    /// luminance mask `applySplitToning` uses, split into a triangular
    /// midtone peak and two complementary ramps; `blending` blurs that mask
    /// spatially before deriving the weights, softening the zone boundaries
    /// (a documented simplification of Lightroom's own falloff-curve control,
    /// not a literal match).
    private static func applyColorGrading(_ grading: ColorGradingAdjustments, to image: CIImage) -> CIImage {
        let extent = image.extent
        let shadowColor = Self.flatColor(hue: grading.shadows.hue, saturation: grading.shadows.saturation, extent: extent)
        let midtoneColor = Self.flatColor(hue: grading.midtones.hue, saturation: grading.midtones.saturation, extent: extent)
        let highlightColor = Self.flatColor(hue: grading.highlights.hue, saturation: grading.highlights.saturation, extent: extent)
        let globalColor = Self.flatColor(hue: grading.global.hue, saturation: grading.global.saturation, extent: extent)

        guard var luminance = Self.balancedLuminanceMask(of: image, balanceOffset: grading.balance / 200) else { return image }
        if grading.blending > 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = luminance
            blur.radius = Float(grading.blending / 100 * 30)
            luminance = blur.outputImage?.cropped(to: extent) ?? luminance
        }
        guard let clampedLuminance = Self.clamped01(luminance) else { return image }

        // highlightWeight = clamp(2L - 1, 0...1); shadowWeight = clamp(1 - 2L, 0...1).
        func weight(scale: Double, bias: Double) -> CIImage? {
            let filter = CIFilter.colorMatrix()
            filter.inputImage = clampedLuminance
            let vector = CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0)
            filter.rVector = vector
            filter.gVector = vector
            filter.bVector = vector
            filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            filter.biasVector = CIVector(x: CGFloat(bias), y: CGFloat(bias), z: CGFloat(bias), w: 0)
            return Self.clamped01(filter.outputImage ?? clampedLuminance)
        }
        guard let highlightWeight = weight(scale: 2, bias: -1),
              let shadowWeight = weight(scale: -2, bias: 1) else { return image }
        // midtoneWeight = clamp(1 - shadowWeight - highlightWeight, 0...1).
        // shadowWeight and highlightWeight never overlap by construction (one
        // ramps 0...0.5, the other 0.5...1), so their sum stays in 0...1 and
        // `CIAdditionCompositing` is exact, not an approximation.
        let combinedExtremes = CIFilter.additionCompositing()
        combinedExtremes.inputImage = shadowWeight
        combinedExtremes.backgroundImage = highlightWeight
        guard let extremesSum = Self.clamped01(combinedExtremes.outputImage ?? shadowWeight) else { return image }
        let invert = CIFilter.colorInvert()
        invert.inputImage = extremesSum
        guard let midtoneWeight = invert.outputImage else { return image }

        // Soft-light each zone's flat colour against the *original* image
        // individually -- not a single hard-blended "recipe" layer soft-lit
        // once at the end -- because soft-light(0.5 grey, x) = x is an exact
        // identity for *any* background x, unconditionally. That identity is
        // what makes a saturation-0 zone (whose flat colour is exactly 0.5
        // grey) a true no-op: `tinted == image` exactly, so blending it back
        // in at *any* spatial weight still yields `image`. Soft-lighting a
        // single hard-blended composite of all three zones first does not
        // have this property -- the composite is only exactly 0.5 when
        // *every* zone is simultaneously unsaturated, so a single real zone
        // (e.g. only Highlights set) let its neighbours' spatial weight leak
        // grey into supposedly-untouched tones.
        func softLightTint(_ color: CIImage, over background: CIImage) -> CIImage {
            let filter = CIFilter.softLightBlendMode()
            filter.inputImage = color
            filter.backgroundImage = background
            return filter.outputImage?.cropped(to: extent) ?? background
        }
        func blend(_ color: CIImage, mask: CIImage, over background: CIImage) -> CIImage {
            let filter = CIFilter.blendWithMask()
            filter.inputImage = color
            filter.backgroundImage = background
            filter.maskImage = mask
            return filter.outputImage ?? background
        }

        let shadowTinted = softLightTint(shadowColor, over: image)
        let midtoneTinted = softLightTint(midtoneColor, over: image)
        let highlightTinted = softLightTint(highlightColor, over: image)

        let withShadows = blend(shadowTinted, mask: shadowWeight, over: image)
        let withMidtones = blend(midtoneTinted, mask: midtoneWeight, over: withShadows)
        let withHighlights = blend(highlightTinted, mask: highlightWeight, over: withMidtones)

        guard grading.global.saturation > 0 else { return withHighlights }
        return softLightTint(globalColor, over: withHighlights)
    }

    private static func applySplitToning(_ splitToning: SplitToning, to image: CIImage) -> CIImage {
        let extent = image.extent

        let shadowColor = Self.flatColor(hue: splitToning.shadowHue, saturation: splitToning.shadowSaturation, extent: extent)
        let highlightColor = Self.flatColor(hue: splitToning.highlightHue, saturation: splitToning.highlightSaturation, extent: extent)

        guard let biasedMaskImage = Self.balancedLuminanceMask(of: image, balanceOffset: splitToning.balance / 200) else { return image }
        let mask = biasedMaskImage

        // balanceOffset can push the mask outside 0...1 (e.g. a luma-0.9
        // highlight pixel with balance +40 biases to 1.1); CIBlendWithMask
        // doesn't clamp its mask input and extrapolates past either source
        // instead of fully committing, so clamp before using it as a mask.
        let clampedMaskFilter = CIFilter.colorClamp()
        clampedMaskFilter.inputImage = mask
        clampedMaskFilter.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clampedMaskFilter.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        guard let clampedMask = clampedMaskFilter.outputImage else { return image }

        let invert = CIFilter.colorInvert()
        invert.inputImage = clampedMask
        guard let invertedMask = invert.outputImage else { return image }

        let shadowsBlend = CIFilter.blendWithMask()
        shadowsBlend.inputImage = shadowColor
        shadowsBlend.backgroundImage = image
        shadowsBlend.maskImage = invertedMask
        guard let withShadows = shadowsBlend.outputImage else { return image }

        let highlightsBlend = CIFilter.blendWithMask()
        highlightsBlend.inputImage = highlightColor
        highlightsBlend.backgroundImage = withShadows
        highlightsBlend.maskImage = clampedMask
        guard let withHighlights = highlightsBlend.outputImage else { return withShadows }

        // The flat tint layers are opaque colour, so blending them straight in
        // would flatten contrast entirely; soft-light keeps the underlying
        // luminance structure while still shifting hue, matching how
        // Lightroom's split toning reads.
        let softLight = CIFilter.softLightBlendMode()
        softLight.inputImage = withHighlights
        softLight.backgroundImage = image
        return softLight.outputImage?.cropped(to: extent) ?? image
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
