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
            || !parameters.isAdvancedToneCurveIdentity
            || !parameters.isSplitToningIdentity
            || !parameters.isHSLIdentity

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

            // 5.5. Advanced tone curve (spec §4.2 step 5.5) — a second,
            // independent curve layered on top of the four-slider one.
            if !parameters.isAdvancedToneCurveIdentity {
                working = Self.applyAdvancedToneCurve(parameters.advancedToneCurve, to: working)
            }

            // 6. HSL (spec §4.2 step 6).
            if !parameters.isHSLIdentity {
                working = Self.applyHSL(parameters.hsl, to: working)
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

        // 11. Grain (spec §4.2 step 11) — synthetic per-pixel luminance noise,
        // generated once at the image's own extent and blended in proportion
        // to amount. size / roughness shape the noise before blending: size
        // widens the grain (blur radius scales up), roughness widens
        // amountScale's magnitude, making the grain read more strongly.
        if !parameters.isGrainIdentity {
            working = Self.applyGrain(parameters.grain, to: working)
        }

        return working
    }

    private static func applyGrain(_ grain: Grain, to image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let noise = CIFilter.randomGenerator()
        guard var noiseImage = noise.outputImage else { return image }

        // size 0...100 -> blur radius 0...4; identical noise blurred more
        // reads as larger grain clumps.
        let blurRadius = (grain.size / 100) * 4
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

    /// Per-pixel 1D LUT lookup, run once per RGB channel with the same table
    /// (spec §4.3: colour is not touched, only tone). Core Image Kernel
    /// Language rather than a `.metal` file, so no Package.swift build-target
    /// changes are needed for one small kernel.
    ///
    /// Deliberately a plain `CIKernel`, not a `CIColorKernel`: a colour
    /// kernel's function must take one `__sample` argument per input image and
    /// is forbidden from calling `sample()`, `samplerCoord()` or
    /// `samplerTransform()` (see Apple's `CIKernel.h`). This kernel needs all
    /// three to do a dependent read out of the LUT texture, so declaring it as
    /// a `CIColorKernel` made `CIColorKernel(source:)` return nil and silently
    /// turned the whole advanced-curve stage into a no-op.
    private static let advancedToneCurveKernel: CIKernel? = {
        let source = """
        kernel vec4 advancedToneCurve(sampler image, sampler lut, float lutWidth) {
            vec4 pixel = sample(image, samplerCoord(image));
            float lastIndex = lutWidth - 1.0;
            vec2 lutSize = samplerSize(lut);
            // Only the table index is clamped -- it has to stay inside the
            // 256-texel texture -- while any extended-range excess is carried
            // around the lookup and added back afterwards. The pipeline works
            // in extended-range linear space (see ImageRenderService), so a
            // highlight at 1.5 must still read 1.5 after an identity curve
            // instead of being crushed into the LUT's own 0...1 domain.
            float rIn = clamp(pixel.r, 0.0, 1.0);
            float gIn = clamp(pixel.g, 0.0, 1.0);
            float bIn = clamp(pixel.b, 0.0, 1.0);
            float r = sample(lut, samplerTransform(lut, vec2(rIn * lastIndex + 0.5, lutSize.y * 0.5))).r + (pixel.r - rIn);
            float g = sample(lut, samplerTransform(lut, vec2(gIn * lastIndex + 0.5, lutSize.y * 0.5))).r + (pixel.g - gIn);
            float b = sample(lut, samplerTransform(lut, vec2(bIn * lastIndex + 0.5, lutSize.y * 0.5))).r + (pixel.b - bIn);
            return vec4(r, g, b, pixel.a);
        }
        """
        return CIKernel(source: source)
    }()

    private static func applyAdvancedToneCurve(_ curve: AdvancedToneCurve, to image: CIImage) -> CIImage {
        guard let kernel = advancedToneCurveKernel else { return image }
        let table = AdvancedToneCurveLUT.build(from: curve.points, resolution: 256)
        guard let lutImage = Self.makeLUTImage(table) else { return image }
        let extent = image.extent
        let arguments: [Any] = [image, lutImage, Double(table.count)]
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

    /// Packs a 1D `[Float]` table into a 1-row-high `CIImage` the kernel can
    /// sample, one red-channel texel per LUT entry.
    private static func makeLUTImage(_ table: [Float]) -> CIImage? {
        var pixelData = [UInt8]()
        pixelData.reserveCapacity(table.count * 4)
        for value in table {
            let byte = UInt8(max(0, min(255, value * 255)))
            pixelData.append(contentsOf: [byte, byte, byte, 255])
        }
        return pixelData.withUnsafeBytes { buffer -> CIImage? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            let data = Data(bytes: baseAddress, count: pixelData.count)
            return CIImage(
                bitmapData: data,
                bytesPerRow: table.count * 4,
                size: CGSize(width: table.count, height: 1),
                format: .RGBA8,
                colorSpace: nil
            )
        }
    }

    /// One pass over all 8 bands per pixel, blending each band's hue/sat/lum
    /// adjustment by `HSLKernelWeights`-equivalent triangular falloff (spec
    /// §4.3). The falloff math is duplicated here in CIKL rather than calling
    /// into `HSLKernelWeights` -- the GPU kernel can't call Swift -- so any
    /// change to the falloff shape must be made in both places; the unit
    /// tests on `HSLKernelWeights` exist specifically to keep this constant
    /// correct even though the kernel body itself can't be unit tested.
    private static let hslKernel: CIColorKernel? = {
        let source = """
        kernel vec4 hslAdjust(
            sampler image,
            float centers0, float centers1, float centers2, float centers3,
            float centers4, float centers5, float centers6, float centers7,
            float hues0, float hues1, float hues2, float hues3,
            float hues4, float hues5, float hues6, float hues7,
            float sats0, float sats1, float sats2, float sats3,
            float sats4, float sats5, float sats6, float sats7,
            float lums0, float lums1, float lums2, float lums3,
            float lums4, float lums5, float lums6, float lums7,
            float halfWidth
        ) {
            vec4 pixel = sample(image, samplerCoord(image));
            float maxC = max(pixel.r, max(pixel.g, pixel.b));
            float minC = min(pixel.r, min(pixel.g, pixel.b));
            float delta = maxC - minC;
            float luma = (maxC + minC) * 0.5;

            float hueDeg = 0.0;
            if (delta > 0.0001) {
                if (maxC == pixel.r) {
                    hueDeg = 60.0 * mod((pixel.g - pixel.b) / delta, 6.0);
                } else if (maxC == pixel.g) {
                    hueDeg = 60.0 * (((pixel.b - pixel.r) / delta) + 2.0);
                } else {
                    hueDeg = 60.0 * (((pixel.r - pixel.g) / delta) + 4.0);
                }
            }
            if (hueDeg < 0.0) { hueDeg = hueDeg + 360.0; }

            float centers[8];
            centers[0]=centers0; centers[1]=centers1; centers[2]=centers2; centers[3]=centers3;
            centers[4]=centers4; centers[5]=centers5; centers[6]=centers6; centers[7]=centers7;
            float hues[8];
            hues[0]=hues0; hues[1]=hues1; hues[2]=hues2; hues[3]=hues3;
            hues[4]=hues4; hues[5]=hues5; hues[6]=hues6; hues[7]=hues7;
            float sats[8];
            sats[0]=sats0; sats[1]=sats1; sats[2]=sats2; sats[3]=sats3;
            sats[4]=sats4; sats[5]=sats5; sats[6]=sats6; sats[7]=sats7;
            float lums[8];
            lums[0]=lums0; lums[1]=lums1; lums[2]=lums2; lums[3]=lums3;
            lums[4]=lums4; lums[5]=lums5; lums[6]=lums6; lums[7]=lums7;

            float hueShift = 0.0;
            float satShift = 0.0;
            float lumShift = 0.0;
            float totalWeight = 0.0;
            for (int i = 0; i < 8; i++) {
                float rawDistance = abs(mod(hueDeg, 360.0) - mod(centers[i], 360.0));
                float distance = min(rawDistance, 360.0 - rawDistance);
                float weight = max(0.0, 1.0 - distance / halfWidth);
                hueShift += weight * hues[i];
                satShift += weight * sats[i];
                lumShift += weight * lums[i];
                totalWeight += weight;
            }

            // halfWidth is wide enough that no hue falls in a dead zone
            // (HSLKernelWeights.halfWidthDegrees), which means the 30-degree-apart
            // bands now overlap by more than 1.0 near their shared midpoints.
            // Renormalise there so the blend never amplifies past what a single
            // band at full strength would do; below 1.0 the weights are left
            // alone, so a lone band still falls off toward zero at its edge
            // instead of being stretched back up to full strength.
            if (totalWeight > 1.0) {
                hueShift /= totalWeight;
                satShift /= totalWeight;
                lumShift /= totalWeight;
            }

            // hue in degrees/100 keeps the shift in the same -1...1-ish order
            // of magnitude as sat/lum before they're applied as fractional
            // adjustments -- a 100-degree slider maps to roughly a 27-degree
            // hue rotation, consistent with the ±100 UI range meaning "full
            // strength", not "spin the hue wheel".
            float shiftedHue = mod(hueDeg + hueShift * 0.27, 360.0);
            float newSat = clamp(1.0 + satShift / 100.0, 0.0, 2.0);
            float newLum = luma + (lumShift / 100.0) * 0.25;

            float c = delta * newSat;
            float x = c * (1.0 - abs(mod(shiftedHue / 60.0, 2.0) - 1.0));
            float m = newLum - c * 0.5;
            vec3 rgbPrime;
            if (shiftedHue < 60.0) { rgbPrime = vec3(c, x, 0.0); }
            else if (shiftedHue < 120.0) { rgbPrime = vec3(x, c, 0.0); }
            else if (shiftedHue < 180.0) { rgbPrime = vec3(0.0, c, x); }
            else if (shiftedHue < 240.0) { rgbPrime = vec3(0.0, x, c); }
            else if (shiftedHue < 300.0) { rgbPrime = vec3(x, 0.0, c); }
            else { rgbPrime = vec3(c, 0.0, x); }

            // Deliberately unclamped: the working space is extended-range
            // linear (see ImageRenderService), and clamping here destroyed
            // highlight headroom that later stages -- vignette darkening, the
            // final output transform -- are supposed to be able to pull back.
            // For a neutral band this reconstruction is an exact round-trip,
            // so an input channel above 1.0 comes back out above 1.0.
            return vec4(rgbPrime + m, pixel.a);
        }
        """
        return CIColorKernel(source: source)
    }()

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

    private static func applySplitToning(_ splitToning: SplitToning, to image: CIImage) -> CIImage {
        let extent = image.extent

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
        /// target: split toning runs inside the gamma-encoded stage, after
        /// `CILinearToSRGBToneCurve`, where a mid-grey image pixel also reads
        /// 0.5 numerically (verified by render). The flat colours in
        /// `applyVignette` sidestep the whole question by only ever using 0 and
        /// 1, which are fixed points of the transfer function.
        ///
        /// Standard HSB algorithm: hue in degrees 0...360, saturation and value
        /// in 0...1.
        func flatColor(hue: Double, saturation: Double) -> CIImage {
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

        let shadowColor = flatColor(hue: splitToning.shadowHue, saturation: splitToning.shadowSaturation)
        let highlightColor = flatColor(hue: splitToning.highlightHue, saturation: splitToning.highlightSaturation)

        // Luminance mask: 0 at black, 1 at white, biased by balance (positive
        // balance shrinks the shadow range so highlights dominate more of the
        // midtones, and vice versa) -- CIMaskToAlpha-style use of the source
        // image's own luminance via CIColorMatrix collapsing to grey, offset
        // by balance/200 before use as a blend mask.
        let luminanceMask = CIFilter.colorMatrix()
        luminanceMask.inputImage = image
        let lumaVector = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        luminanceMask.rVector = lumaVector
        luminanceMask.gVector = lumaVector
        luminanceMask.bVector = lumaVector
        luminanceMask.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        luminanceMask.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        let balanceOffset = splitToning.balance / 200
        let biasedMask = CIFilter.colorMatrix()
        biasedMask.inputImage = luminanceMask.outputImage
        biasedMask.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        biasedMask.gVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        biasedMask.bVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        biasedMask.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        biasedMask.biasVector = CIVector(x: CGFloat(balanceOffset), y: CGFloat(balanceOffset), z: CGFloat(balanceOffset), w: 0)
        guard let mask = biasedMask.outputImage else { return image }

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
