import CoreGraphics
import CoreImage
import XCTest
@testable import RawProcessingCore

/// Spec §9's chain, exercised on a synthetic image so it runs without a RAW
/// file, a GPU or a camera. What it can prove is that each slider moves pixels
/// in the documented direction and that the output is tagged sRGB; what it
/// cannot prove is how Apple's RAW decoder renders a real `.ARW` — that stays
/// on the manual acceptance list.
final class AdjustmentPipelineTests: XCTestCase {
    private let pipeline = AdjustmentPipeline()
    private let size = CGSize(width: 16, height: 16)

    /// A mid-grey patch with a slight colour cast, so saturation and white
    /// balance have something to act on.
    private func makeSourceImage(
        red: CGFloat = 0.45,
        green: CGFloat = 0.35,
        blue: CGFloat = 0.25
    ) -> CIImage {
        CIImage(color: CIColor(red: red, green: green, blue: blue))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Converts a perceptual (gamma-encoded) sRGB component to its linear-light
    /// equivalent using the standard sRGB transfer function. `makeSourceImage`
    /// feeds the pipeline's linear working space directly, so a fixture that
    /// wants to describe "25% grey" the way it looks must be gamma-decoded
    /// first, or it lands somewhere else on the curve entirely.
    private func linearComponent(fromPerceptual perceptual: CGFloat) -> CGFloat {
        perceptual <= 0.04045
            ? perceptual / 12.92
            : pow((perceptual + 0.055) / 1.055, 2.4)
    }

    /// Renders and samples the centre pixel as 8-bit sRGB.
    private func centrePixel(
        _ image: CIImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (red: Int, green: Int, blue: Int) {
        let renderer = ImageRenderService()
        let cgImage = try renderer.makeCGImage(image)

        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    /// Renders and samples one specific pixel, in image coordinates with
    /// (0, 0) at the top-left, as 8-bit sRGB.
    ///
    /// `centrePixel` draws the whole image into a 1x1 context, which averages
    /// every pixel together rather than point-sampling one. That is fine for a
    /// flat fixture, but it hides a render that is correct in one region and
    /// black in another -- exactly the failure mode the advanced-curve LUT's
    /// region-of-interest bug produced. This reads a single location instead.
    private func pixel(
        at point: CGPoint,
        in image: CIImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (red: Int, green: Int, blue: Int) {
        let renderer = ImageRenderService()
        let cgImage = try renderer.makeCGImage(image)

        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), file: file, line: line)
        // CGContext's origin is bottom-left, so flip the requested row and
        // offset the full-size draw so the wanted pixel lands on the 1x1 canvas.
        context.draw(cgImage, in: CGRect(
            x: -point.x,
            y: -(CGFloat(cgImage.height) - 1 - point.y),
            width: CGFloat(cgImage.width),
            height: CGFloat(cgImage.height)
        ))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    // MARK: - Identity

    func testNeutralAdjustmentsAreAPassthrough() {
        // Spec §6.2's before/after comparison is only honest if "no edits"
        // means literally the same image, not an approximately equal one.
        let source = makeSourceImage()
        let output = pipeline.apply(PhotoAdjustments.neutral, to: source)
        XCTAssertEqual(output.extent, source.extent)
        XCTAssertTrue(output === source, "A neutral edit should skip every filter")
    }

    func testWhiteBalanceAloneDoesNotAddFiltersToTheChain() {
        // Temperature and tint are applied by the decoder (spec §9), so the
        // post-decode chain must stay empty for a white-balance-only edit.
        let source = makeSourceImage()
        let output = pipeline.apply(
            PhotoAdjustments(temperature: 40, tint: -20), to: source
        )
        XCTAssertTrue(output === source)
    }

    func testExtentIsPreservedThroughTheWholeChain() {
        let source = makeSourceImage()
        let adjustments = PhotoAdjustments(
            exposure: 1, contrast: 40, highlights: -30, shadows: 30,
            whites: 20, blacks: -20, vibrance: 50, saturation: 30
        )
        let output = pipeline.apply(adjustments, to: source)
        XCTAssertEqual(output.extent, source.extent, "An adjustment must not resize the photo")
    }

    // MARK: - Direction of each slider

    func testPositiveExposureBrightens() throws {
        let source = makeSourceImage()
        let base = try centrePixel(source)
        let brighter = try centrePixel(pipeline.apply(PhotoAdjustments(exposure: 1), to: source))
        XCTAssertGreaterThan(brighter.red, base.red)
        XCTAssertGreaterThan(brighter.green, base.green)
        XCTAssertGreaterThan(brighter.blue, base.blue)
    }

    func testNegativeExposureDarkens() throws {
        let source = makeSourceImage()
        let base = try centrePixel(source)
        let darker = try centrePixel(pipeline.apply(PhotoAdjustments(exposure: -1), to: source))
        XCTAssertLessThan(darker.red, base.red)
    }

    func testFullyNegativeSaturationProducesGrey() throws {
        let source = makeSourceImage()
        let grey = try centrePixel(pipeline.apply(PhotoAdjustments(saturation: -100), to: source))
        // Allow a unit of rounding from the 8-bit round trip.
        XCTAssertEqual(grey.red, grey.green, accuracy: 1)
        XCTAssertEqual(grey.green, grey.blue, accuracy: 1)
    }

    func testPositiveSaturationWidensTheChannelSpread() throws {
        let source = makeSourceImage()
        let base = try centrePixel(source)
        let saturated = try centrePixel(pipeline.apply(PhotoAdjustments(saturation: 80), to: source))
        XCTAssertGreaterThan(saturated.red - saturated.blue, base.red - base.blue)
    }

    func testPositiveContrastPushesAShadowToneDarker() throws {
        // Contrast pivots around mid grey, so a below-mid tone must fall.
        let source = makeSourceImage(red: 0.25, green: 0.25, blue: 0.25)
        let base = try centrePixel(source)
        let contrasted = try centrePixel(pipeline.apply(PhotoAdjustments(contrast: 100), to: source))
        XCTAssertLessThan(contrasted.red, base.red)
    }

    func testPositiveContrastPushesAHighlightToneBrighter() throws {
        let source = makeSourceImage(red: 0.75, green: 0.75, blue: 0.75)
        let base = try centrePixel(source)
        let contrasted = try centrePixel(pipeline.apply(PhotoAdjustments(contrast: 100), to: source))
        XCTAssertGreaterThan(contrasted.red, base.red)
    }

    func testLiftingShadowsBrightensADarkToneWithoutTouchingMidGrey() throws {
        // A perceptual 25% shadow patch, expressed in the pipeline's linear
        // working space so it actually lands at the tone curve's x=0.25
        // control point instead of near the midpoint.
        let darkComponent = linearComponent(fromPerceptual: 0.25)
        let dark = makeSourceImage(red: darkComponent, green: darkComponent, blue: darkComponent)
        let darkBase = try centrePixel(dark)
        let lifted = try centrePixel(pipeline.apply(PhotoAdjustments(shadows: 100), to: dark))
        XCTAssertGreaterThan(lifted.red, darkBase.red)

        // The tone curve pins 0.5, which is what keeps the four tone sliders
        // from behaving like a second exposure control. The perceptual
        // midpoint must be gamma-decoded the same way to actually land on
        // that pinned control point.
        let midComponent = linearComponent(fromPerceptual: 0.5)
        let mid = makeSourceImage(red: midComponent, green: midComponent, blue: midComponent)
        let midBase = try centrePixel(mid)
        let midLifted = try centrePixel(pipeline.apply(PhotoAdjustments(shadows: 100), to: mid))
        XCTAssertEqual(midLifted.red, midBase.red, accuracy: 2)
    }

    func testRecoveringHighlightsDarkensABrightTone() throws {
        let bright = makeSourceImage(red: 0.8, green: 0.8, blue: 0.8)
        let base = try centrePixel(bright)
        let recovered = try centrePixel(pipeline.apply(PhotoAdjustments(highlights: -100), to: bright))
        XCTAssertLessThan(recovered.red, base.red)
    }

    func testOpposingToneSlidersStayMonotonicRatherThanSolarising() throws {
        // The guard in ToneCurveMapping only matters if it survives a real
        // render: a non-monotonic curve inverts tones instead of flattening.
        let adjustments = PhotoAdjustments(
            highlights: -100, shadows: 100, whites: -100, blacks: 100
        )
        let dark = try centrePixel(
            pipeline.apply(adjustments, to: makeSourceImage(red: 0.2, green: 0.2, blue: 0.2))
        )
        let bright = try centrePixel(
            pipeline.apply(adjustments, to: makeSourceImage(red: 0.8, green: 0.8, blue: 0.8))
        )
        XCTAssertLessThanOrEqual(dark.red, bright.red, "Tones were inverted")
    }

    func testAdjustmentsAreDeterministic() throws {
        let source = makeSourceImage()
        let adjustments = PhotoAdjustments(exposure: 0.5, contrast: 30, vibrance: 40)
        let first = try centrePixel(pipeline.apply(adjustments, to: source))
        let second = try centrePixel(pipeline.apply(adjustments, to: source))
        XCTAssertEqual(first.red, second.red)
        XCTAssertEqual(first.green, second.green)
        XCTAssertEqual(first.blue, second.blue)
    }

    // MARK: - Sharpening / noise reduction / vignette

    func testNonDefaultButStillIdentitySharpeningNoiseVignetteStayAPassthrough() {
        // Spec 3: each of these three types gates identity on `amount` alone,
        // so every *other* field can be far from its default and the stage must
        // still be skipped entirely. `PhotoAdjustments.neutral` already proves
        // the all-defaults case (testNeutralAdjustmentsAreAPassthrough); this
        // covers the case that gate actually has to decide.
        let source = makeSourceImage()
        var adjustments = PhotoAdjustments.neutral
        adjustments.sharpening = Sharpening(amount: 0, radius: 3.0, detail: 100, masking: 100)
        adjustments.noiseReduction = NoiseReduction(
            luminanceAmount: 0, luminanceDetail: 100, colorAmount: 0, colorDetail: 0
        )
        adjustments.vignette = Vignette(amount: 0, midpoint: 10, roundness: -80, feather: 95)
        let output = pipeline.apply(adjustments, to: source)
        XCTAssertTrue(output === source, "Only `amount` may gate these three stages")
    }

    func testSharpeningAddsAFilterToTheChainWhenNonZero() {
        let source = makeSourceImage()
        var adjustments = PhotoAdjustments.neutral
        adjustments.sharpening = Sharpening(amount: 80)
        let output = pipeline.apply(adjustments, to: source)
        XCTAssertFalse(output === source)
        XCTAssertEqual(output.extent, source.extent)
    }

    func testSharpeningRadiusScalesDownWithScaleFactor() throws {
        // Spec §7 Gate B3: a downsampled preview decode should apply a
        // proportionally smaller sharpening radius than a full-resolution
        // export decode, so the two read consistently. A hard vertical edge
        // is needed -- sharpening has nothing to act on in a flat fixture --
        // and a wider radius pulls a visibly bigger halo across it.
        let dark = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 16))
        let light = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9))
            .cropped(to: CGRect(x: 8, y: 0, width: 8, height: 16))
        let source = light.composited(over: dark).cropped(to: CGRect(origin: .zero, size: size))

        var adjustments = PhotoAdjustments.neutral
        adjustments.sharpening = Sharpening(amount: 150, radius: 3.0)

        let fullScale = pipeline.apply(adjustments, to: source, scaleFactor: 1)
        let downsampledScale = pipeline.apply(adjustments, to: source, scaleFactor: 0.2)

        let fullPixel = try pixel(at: CGPoint(x: 6, y: 8), in: fullScale)
        let downsampledPixel = try pixel(at: CGPoint(x: 6, y: 8), in: downsampledScale)
        XCTAssertTrue(
            fullPixel.red != downsampledPixel.red
                || fullPixel.green != downsampledPixel.green
                || fullPixel.blue != downsampledPixel.blue
        )

        // scaleFactor: 1 (as export always passes) must still match calling
        // apply(_:to:) with no scaleFactor at all -- the default preserves
        // existing export output exactly.
        let defaultScale = pipeline.apply(adjustments, to: source)
        let defaultPixel = try pixel(at: CGPoint(x: 6, y: 8), in: defaultScale)
        XCTAssertEqual(fullPixel.red, defaultPixel.red)
        XCTAssertEqual(fullPixel.green, defaultPixel.green)
        XCTAssertEqual(fullPixel.blue, defaultPixel.blue)
    }

    func testNoiseReductionAddsAFilterToTheChainWhenNonZero() {
        let source = makeSourceImage()
        var adjustments = PhotoAdjustments.neutral
        adjustments.noiseReduction = NoiseReduction(luminanceAmount: 50)
        let output = pipeline.apply(adjustments, to: source)
        XCTAssertFalse(output === source)
        XCTAssertEqual(output.extent, source.extent)
    }

    func testNegativeVignetteDarkensTheCorner() throws {
        let source = makeSourceImage(red: 0.5, green: 0.5, blue: 0.5)
        var adjustments = PhotoAdjustments.neutral
        adjustments.vignette = Vignette(amount: -100, midpoint: 30, roundness: 0, feather: 50)
        let output = pipeline.apply(adjustments, to: source)
        let renderer = ImageRenderService()
        let cgImage = try renderer.makeCGImage(output)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Sample the top-left corner pixel of the 16x16 fixture.
        context.draw(cgImage, in: CGRect(x: -Int(size.width) + 1, y: 0, width: Int(size.width), height: Int(size.height)))
        let cornerRed = Int(bytes[0])
        let centre = try centrePixel(output)
        XCTAssertLessThan(cornerRed, centre.red, "A negative-amount vignette should darken the corner relative to the centre")
    }

    func testPositiveVignetteBrightensTheCorner() throws {
        let source = makeSourceImage(red: 0.5, green: 0.5, blue: 0.5)
        var adjustments = PhotoAdjustments.neutral
        adjustments.vignette = Vignette(amount: 100, midpoint: 30, roundness: 0, feather: 50)
        let output = pipeline.apply(adjustments, to: source)
        let renderer = ImageRenderService()
        let cgImage = try renderer.makeCGImage(output)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: -Int(size.width) + 1, y: 0, width: Int(size.width), height: Int(size.height)))
        let cornerRed = Int(bytes[0])
        let centre = try centrePixel(output)
        XCTAssertGreaterThan(cornerRed, centre.red, "A positive-amount vignette should brighten the corner relative to the centre")
    }

    // MARK: - Grain

    func testNonDefaultButStillIdentityGrainStaysAPassthrough() {
        // Grain gates on `amount` alone (spec 3.7): size and roughness shape
        // the noise but cannot switch it on.
        let source = makeSourceImage()
        var adjustments = PhotoAdjustments.neutral
        adjustments.grain = Grain(amount: 0, size: 100, roughness: 0)
        XCTAssertTrue(pipeline.apply(adjustments, to: source) === source)
    }

    func testGrainAddsVisibleNoiseAndPreservesExtent() throws {
        // A flat mid-grey source with grain applied must stop being perfectly
        // flat -- neighbouring pixels should diverge -- while the canvas size
        // is untouched.
        let source = makeSourceImage(red: 0.5, green: 0.5, blue: 0.5)
        var adjustments = PhotoAdjustments.neutral
        adjustments.grain = Grain(amount: 100, size: 25, roughness: 50)
        let output = pipeline.apply(adjustments, to: source)
        XCTAssertEqual(output.extent, source.extent)

        let renderer = ImageRenderService()
        let cgImage = try renderer.makeCGImage(output)
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let firstPixelRed = bytes[0]
        let anyPixelDiffers = stride(from: 0, to: bytes.count, by: 4).contains { bytes[$0] != firstPixelRed }
        XCTAssertTrue(anyPixelDiffers, "Grain at full amount on a flat source must not render perfectly flat")
    }

    func testGrainBlurRadiusScalesDownWithScaleFactor() throws {
        // Spec §7 Gate B3: a downsampled preview decode should blur the
        // underlying grain noise by a proportionally smaller radius than a
        // full-resolution export decode, so grain clumps read as roughly the
        // same relative size in both. CIRandomGenerator is deterministic (a
        // fixed recipe, not wall-clock-seeded), so the same source/adjustment
        // pair rendered at two scaleFactors is a fair, non-flaky comparison.
        let source = makeSourceImage(red: 0.5, green: 0.5, blue: 0.5)
        var adjustments = PhotoAdjustments.neutral
        adjustments.grain = Grain(amount: 100, size: 25, roughness: 50)

        func renderBytes(scaleFactor: Double) throws -> [UInt8] {
            let output = pipeline.apply(adjustments, to: source, scaleFactor: scaleFactor)
            let renderer = ImageRenderService()
            let cgImage = try renderer.makeCGImage(output)
            let width = cgImage.width, height = cgImage.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return bytes
        }

        let fullScaleBytes = try renderBytes(scaleFactor: 1)
        let downsampledBytes = try renderBytes(scaleFactor: 0.1)
        XCTAssertNotEqual(fullScaleBytes, downsampledBytes)
    }

    // MARK: - Split toning

    func testZeroSaturationSplitToningStaysAPassthroughWhateverTheHues() {
        // Spec 3.3: hue and balance are meaningless at zero saturation, so a
        // fully-specified-but-colourless split tone must still cost nothing.
        let source = makeSourceImage()
        var adjustments = PhotoAdjustments.neutral
        adjustments.splitToning = SplitToning(
            shadowHue: 180, shadowSaturation: 0,
            highlightHue: 90, highlightSaturation: 0,
            balance: 50
        )
        XCTAssertTrue(pipeline.apply(adjustments, to: source) === source)
    }

    func testShadowTintShiftsADarkPixelTowardTheShadowHue() throws {
        // A blue shadow tint (hue 240) on a dark-grey patch should push blue
        // above red at the pixel level.
        let darkComponent = linearComponent(fromPerceptual: 0.2)
        let dark = makeSourceImage(red: darkComponent, green: darkComponent, blue: darkComponent)
        var adjustments = PhotoAdjustments.neutral
        adjustments.splitToning = SplitToning(shadowHue: 240, shadowSaturation: 80, highlightHue: 0, highlightSaturation: 0, balance: 0)
        let tinted = try centrePixel(pipeline.apply(adjustments, to: dark))
        XCTAssertGreaterThan(tinted.blue, tinted.red, "A blue shadow tint should leave blue above red in a dark patch")
    }

    func testHighlightTintShiftsABrightPixelTowardTheHighlightHue() throws {
        let brightComponent = linearComponent(fromPerceptual: 0.8)
        let bright = makeSourceImage(red: brightComponent, green: brightComponent, blue: brightComponent)
        var adjustments = PhotoAdjustments.neutral
        adjustments.splitToning = SplitToning(shadowHue: 0, shadowSaturation: 0, highlightHue: 30, highlightSaturation: 80, balance: 0)
        let tinted = try centrePixel(pipeline.apply(adjustments, to: bright))
        XCTAssertGreaterThan(tinted.red, tinted.blue, "An orange (hue 30) highlight tint should leave red above blue in a bright patch")
    }

    // MARK: - Lens Correction (P4: manual/bundled-profile modes only --
    // .automatic is decode-time, CoreImageRawDecoder's job, not testable
    // without a real RAW file; see that type's own manual acceptance note.)

    func testOffModeIsAPassthroughEvenWithNonZeroAmountsQueued() {
        // Amounts survive being dialed in before the user picks a mode, but
        // must have zero render effect until mode leaves .off.
        let source = makeSourceImage()
        var adjustments = PhotoAdjustments.neutral
        adjustments.lensCorrection = LensCorrectionAdjustments(mode: .off, distortionAmount: 50, vignettingAmount: 50, tcaAmount: 50)
        let output = pipeline.apply(adjustments, to: source)
        XCTAssertTrue(output === source)
    }

    func testAutomaticModeAloneDoesNotChangePixelsInThisPipeline() throws {
        // .automatic only affects CoreImageRawDecoder (D-007) -- this
        // pipeline stage must treat it exactly like .off.
        let source = makeSourceImage()
        var adjustments = PhotoAdjustments.neutral
        adjustments.lensCorrection = LensCorrectionAdjustments(mode: .automatic)
        let base = try centrePixel(source)
        let edited = try centrePixel(pipeline.apply(adjustments, to: source))
        XCTAssertEqual(edited.red, base.red)
        XCTAssertEqual(edited.green, base.green)
        XCTAssertEqual(edited.blue, base.blue)
    }

    func testPositiveDistortionMovesACornerPixelTowardTheCenter() throws {
        // Positive distortion corrects barrel distortion (pincushion-style
        // correction pulls the frame in from the edges), so a distinctive
        // marker placed off-centre should sample as if pulled toward the
        // centre after correction -- checked here as "the corner is no
        // longer pure background colour, it picked up some of the marker's
        // colour that used to be further out" is too fragile; instead check
        // that *some* geometric change happened by asserting the corner
        // pixel of a half-and-half fixture crosses the boundary.
        let side = 200
        let backgroundColor = CIColor(red: 0.2, green: 0.2, blue: 0.2)
        let markerColor = CIColor(red: 0.9, green: 0.9, blue: 0.9)
        let background = CIImage(color: backgroundColor).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        let marker = CIImage(color: markerColor)
            .cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        let source = marker.composited(over: background).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))

        var adjustments = PhotoAdjustments.neutral
        adjustments.lensCorrection = LensCorrectionAdjustments(mode: .manual, distortionAmount: 100)
        let output = pipeline.apply(adjustments, to: source)
        XCTAssertFalse(output === source, "A non-zero distortion amount must actually reach the render chain")
        XCTAssertEqual(output.extent, source.extent)
    }

    func testPositiveVignettingBrightensTheCorner() throws {
        let source = makeSourceImage(red: 0.3, green: 0.3, blue: 0.3)
        let corner = CGPoint(x: 1, y: 1)
        let base = try pixel(at: corner, in: source)
        var adjustments = PhotoAdjustments.neutral
        adjustments.lensCorrection = LensCorrectionAdjustments(mode: .manual, vignettingAmount: 100)
        let edited = try pixel(at: corner, in: pipeline.apply(adjustments, to: source))
        XCTAssertGreaterThan(edited.red, base.red, "Positive vignetting amount should brighten the corner (correcting lens light falloff)")
    }

    func testNegativeVignettingDarkensTheCorner() throws {
        let source = makeSourceImage(red: 0.5, green: 0.5, blue: 0.5)
        let corner = CGPoint(x: 1, y: 1)
        let base = try pixel(at: corner, in: source)
        var adjustments = PhotoAdjustments.neutral
        adjustments.lensCorrection = LensCorrectionAdjustments(mode: .manual, vignettingAmount: -100)
        let edited = try pixel(at: corner, in: pipeline.apply(adjustments, to: source))
        XCTAssertLessThan(edited.red, base.red)
    }

    func testPositiveTCASeparatesRedAndBlueAtAHighContrastEdge() throws {
        let side = 200
        let dark = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: side / 2, height: side))
        let light = CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9))
            .cropped(to: CGRect(x: side / 2, y: 0, width: side / 2, height: side))
        let source = light.composited(over: dark).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))

        var adjustments = PhotoAdjustments.neutral
        adjustments.lensCorrection = LensCorrectionAdjustments(mode: .manual, tcaAmount: 100)
        let output = pipeline.apply(adjustments, to: source)
        XCTAssertFalse(output === source, "A non-zero TCA amount must actually reach the render chain")
        XCTAssertEqual(output.extent, source.extent)
    }

    func testBundledProfileModeWithNoMatchProducesUnchangedPixels() throws {
        // The bundled database is empty in this phase (P4 spec §1 item 1) --
        // a caller that sets .bundledProfile without ever resolving a match
        // (amounts stay 0) must still render pixel-identical output, even
        // though `LensCorrectionAdjustments.isIdentity` itself reports this
        // as non-neutral data (selecting the mode is a real, saved choice --
        // see `testIdentityIsDeterminedOnlyByMode` -- but zero amounts still
        // mean zero visible effect).
        let source = makeSourceImage()
        var adjustments = PhotoAdjustments.neutral
        adjustments.lensCorrection = LensCorrectionAdjustments(mode: .bundledProfile)
        let base = try centrePixel(source)
        let edited = try centrePixel(pipeline.apply(adjustments, to: source))
        XCTAssertEqual(edited.red, base.red)
        XCTAssertEqual(edited.green, base.green)
        XCTAssertEqual(edited.blue, base.blue)
    }

    // MARK: - Presence (P4: texture, clarity, dehaze)

    private func edgeFixture() -> CIImage {
        let dark = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 16))
        let light = CIImage(color: CIColor(red: 0.7, green: 0.7, blue: 0.7))
            .cropped(to: CGRect(x: 8, y: 0, width: 8, height: 16))
        return light.composited(over: dark).cropped(to: CGRect(origin: .zero, size: size))
    }

    func testPositiveTextureIncreasesContrastAtAnEdge() throws {
        let source = edgeFixture()
        let base = try pixel(at: CGPoint(x: 7, y: 8), in: source)
        var adjustments = PhotoAdjustments.neutral
        adjustments.presence = PresenceAdjustments(texture: 100)
        let edited = try pixel(at: CGPoint(x: 7, y: 8), in: pipeline.apply(adjustments, to: source))
        XCTAssertLessThan(edited.red, base.red, "Positive texture should darken the dark side of an edge further")
    }

    func testNegativeTextureSoftensAnEdge() throws {
        let source = edgeFixture()
        let baseDark = try pixel(at: CGPoint(x: 7, y: 8), in: source)
        let baseLight = try pixel(at: CGPoint(x: 8, y: 8), in: source)
        var adjustments = PhotoAdjustments.neutral
        adjustments.presence = PresenceAdjustments(texture: -100)
        let output = pipeline.apply(adjustments, to: source)
        let editedDark = try pixel(at: CGPoint(x: 7, y: 8), in: output)
        let editedLight = try pixel(at: CGPoint(x: 8, y: 8), in: output)
        XCTAssertLessThan(baseDark.red, baseLight.red) // sanity: base has an edge at all
        XCTAssertLessThan(
            abs(editedLight.red - editedDark.red), abs(baseLight.red - baseDark.red),
            "Negative texture should soften (reduce contrast across) the edge"
        )
    }

    func testPositiveClarityIncreasesLocalContrast() throws {
        let source = edgeFixture()
        let base = try pixel(at: CGPoint(x: 4, y: 8), in: source)
        var adjustments = PhotoAdjustments.neutral
        adjustments.presence = PresenceAdjustments(clarity: 100)
        let edited = try pixel(at: CGPoint(x: 4, y: 8), in: pipeline.apply(adjustments, to: source))
        XCTAssertLessThan(edited.red, base.red, "Positive clarity should darken the dark side further, same direction as texture but wider")
    }

    func testPositiveDehazeIncreasesContrastAndSaturation() throws {
        // A flat, desaturated mid-grey-ish patch stands in for a hazy scene.
        let hazy = makeSourceImage(red: 0.55, green: 0.5, blue: 0.48)
        let base = try centrePixel(hazy)
        var adjustments = PhotoAdjustments.neutral
        adjustments.presence = PresenceAdjustments(dehaze: 100)
        let edited = try centrePixel(pipeline.apply(adjustments, to: hazy))
        XCTAssertGreaterThan(edited.red - edited.blue, base.red - base.blue, "Dehaze should widen the channel spread (more saturated)")
    }

    func testNegativeDehazeReducesContrastAndSaturation() throws {
        let source = makeSourceImage(red: 0.6, green: 0.4, blue: 0.3)
        let base = try centrePixel(source)
        var adjustments = PhotoAdjustments.neutral
        adjustments.presence = PresenceAdjustments(dehaze: -100)
        let edited = try centrePixel(pipeline.apply(adjustments, to: source))
        XCTAssertLessThan(edited.red - edited.blue, base.red - base.blue, "Negative dehaze should narrow the channel spread (hazier, less saturated)")
    }

    func testNeutralPresenceStaysAPassthrough() {
        let source = makeSourceImage()
        let output = pipeline.apply(PhotoAdjustments(presence: .neutral), to: source)
        XCTAssertTrue(output === source)
    }

    // MARK: - Color Grading (P4)

    func testShadowColorGradingTintsADarkPixelTowardTheShadowHue() throws {
        let dark = makeSourceImage(red: 0.15, green: 0.15, blue: 0.15)
        var adjustments = PhotoAdjustments.neutral
        adjustments.colorGrading.shadows = ColorGradeBand(hue: 30, saturation: 80, luminance: 0)
        let tinted = try centrePixel(pipeline.apply(adjustments, to: dark))
        XCTAssertGreaterThan(tinted.red, tinted.blue, "An orange (hue 30) shadow grade should leave red above blue in a dark patch")
    }

    func testHighlightColorGradingDoesNotVisiblyTintADarkPixel() throws {
        let dark = makeSourceImage(red: 0.15, green: 0.15, blue: 0.15)
        let base = try centrePixel(dark)
        var adjustments = PhotoAdjustments.neutral
        adjustments.colorGrading.highlights = ColorGradeBand(hue: 220, saturation: 80, luminance: 0)
        let edited = try centrePixel(pipeline.apply(adjustments, to: dark))
        XCTAssertEqual(edited.red, base.red, accuracy: 3, "A highlight-only grade should leave a dark patch close to untouched")
    }

    func testMidtoneColorGradingTintsAMidGreyPixel() throws {
        let mid = makeSourceImage(red: 0.5, green: 0.5, blue: 0.5)
        var adjustments = PhotoAdjustments.neutral
        adjustments.colorGrading.midtones = ColorGradeBand(hue: 30, saturation: 80, luminance: 0)
        let tinted = try centrePixel(pipeline.apply(adjustments, to: mid))
        XCTAssertGreaterThan(tinted.red, tinted.blue, "An orange (hue 30) midtone grade should leave red above blue in a mid-grey patch")
    }

    func testGlobalColorGradingTintsEveryTone() throws {
        let dark = makeSourceImage(red: 0.15, green: 0.15, blue: 0.15)
        let light = makeSourceImage(red: 0.85, green: 0.85, blue: 0.85)
        var adjustments = PhotoAdjustments.neutral
        adjustments.colorGrading.global = ColorGradeBand(hue: 30, saturation: 80, luminance: 0)
        let tintedDark = try centrePixel(pipeline.apply(adjustments, to: dark))
        let tintedLight = try centrePixel(pipeline.apply(adjustments, to: light))
        XCTAssertGreaterThan(tintedDark.red, tintedDark.blue, "Global grade should tint shadows too")
        XCTAssertGreaterThan(tintedLight.red, tintedLight.blue, "Global grade should tint highlights too")
    }

    func testZeroSaturationColorGradingStaysAPassthroughWhateverTheHues() {
        let source = makeSourceImage()
        var adjustments = PhotoAdjustments.neutral
        adjustments.colorGrading.shadows.hue = 240
        adjustments.colorGrading.highlights.hue = 60
        let output = pipeline.apply(adjustments, to: source)
        XCTAssertTrue(output === source, "Hue with zero saturation on every band must still be a passthrough")
    }

    // MARK: - Monochrome (P4)

    func testEnabledMonochromeProducesAnAchromaticPixel() throws {
        let red = makeSourceImage(red: 0.7, green: 0.2, blue: 0.2)
        var adjustments = PhotoAdjustments.neutral
        adjustments.monochrome = MonochromeAdjustments(isEnabled: true)
        let edited = try centrePixel(pipeline.apply(adjustments, to: red))
        XCTAssertEqual(edited.red, edited.green, accuracy: 1)
        XCTAssertEqual(edited.green, edited.blue, accuracy: 1)
    }

    func testPositiveRedMixBrightensARedPatchOnceConverted() throws {
        let red = makeSourceImage(red: 0.6, green: 0.3, blue: 0.3)
        var neutralMono = PhotoAdjustments.neutral
        neutralMono.monochrome = MonochromeAdjustments(isEnabled: true)
        let neutralGray = try centrePixel(pipeline.apply(neutralMono, to: red))

        var boostedMono = PhotoAdjustments.neutral
        boostedMono.monochrome = MonochromeAdjustments(isEnabled: true, red: 100)
        let boostedGray = try centrePixel(pipeline.apply(boostedMono, to: red))

        XCTAssertGreaterThan(boostedGray.red, neutralGray.red, "Boosting the Red band's mix should brighten a red-hued pixel's grayscale output")
    }

    func testDisabledMonochromePreservesColorAdjustments() throws {
        // Disabled must not affect anything else in the chain -- colour tools
        // stay live (design spec §6.3: "停用時保留彩色調整").
        let red = makeSourceImage(red: 0.7, green: 0.2, blue: 0.2)
        var adjustments = PhotoAdjustments.neutral
        adjustments.monochrome = MonochromeAdjustments(isEnabled: false, red: 90)
        adjustments.hsl.red = HSLBand(hue: 0, saturation: -100, luminance: 0)
        let base = try centrePixel(red)
        let edited = try centrePixel(pipeline.apply(adjustments, to: red))
        XCTAssertNotEqual(edited.red, edited.green, "Still colour, not converted to grayscale")
        XCTAssertLessThan(edited.red - edited.blue, base.red - base.blue, "HSL desaturation should still apply while monochrome is disabled")
    }

    func testNeutralMonochromeStaysAPassthrough() {
        let source = makeSourceImage()
        let output = pipeline.apply(PhotoAdjustments(monochrome: .neutral), to: source)
        XCTAssertTrue(output === source)
    }

    // MARK: - Rendering Profile (P4)

    func testVividProfileIncreasesSaturation() throws {
        let source = makeSourceImage(red: 0.6, green: 0.4, blue: 0.3)
        let base = try centrePixel(source)
        var adjustments = PhotoAdjustments.neutral
        adjustments.renderingProfile = RenderingProfileSelection(profileID: "lumaharbor.vivid", amount: 100)
        let edited = try centrePixel(pipeline.apply(adjustments, to: source))
        XCTAssertGreaterThan(edited.red - edited.blue, base.red - base.blue)
    }

    func testProfileAmountScalesTheEffect() throws {
        let source = makeSourceImage(red: 0.6, green: 0.4, blue: 0.3)
        var full = PhotoAdjustments.neutral
        full.renderingProfile = RenderingProfileSelection(profileID: "lumaharbor.vivid", amount: 100)
        var half = PhotoAdjustments.neutral
        half.renderingProfile = RenderingProfileSelection(profileID: "lumaharbor.vivid", amount: 50)
        let base = try centrePixel(source)
        let fullPixel = try centrePixel(pipeline.apply(full, to: source))
        let halfPixel = try centrePixel(pipeline.apply(half, to: source))
        let fullSpread = fullPixel.red - fullPixel.blue
        let halfSpread = halfPixel.red - halfPixel.blue
        let baseSpread = base.red - base.blue
        XCTAssertTrue(baseSpread < halfSpread && halfSpread < fullSpread, "amount: 50 should land strictly between neutral and amount: 100")
    }

    func testUnknownProfileIDIsANoOp() throws {
        let source = makeSourceImage()
        var adjustments = PhotoAdjustments.neutral
        adjustments.renderingProfile = RenderingProfileSelection(profileID: "not-a-real-profile", amount: 100)
        let output = pipeline.apply(adjustments, to: source)
        let base = try centrePixel(source)
        let edited = try centrePixel(output)
        XCTAssertEqual(edited.red, base.red)
        XCTAssertEqual(edited.green, base.green)
        XCTAssertEqual(edited.blue, base.blue)
    }

    func testStandardProfileIsANoOpAtAnyAmount() throws {
        let source = makeSourceImage()
        var adjustments = PhotoAdjustments.neutral
        adjustments.renderingProfile = RenderingProfileSelection(profileID: "lumaharbor.standard", amount: 100)
        let output = pipeline.apply(adjustments, to: source)
        let base = try centrePixel(source)
        let edited = try centrePixel(output)
        XCTAssertEqual(edited.red, base.red)
        XCTAssertEqual(edited.green, base.green)
        XCTAssertEqual(edited.blue, base.blue)
    }

    func testNeutralRenderingProfileStaysAPassthrough() {
        let source = makeSourceImage()
        let output = pipeline.apply(PhotoAdjustments(renderingProfile: .neutral), to: source)
        XCTAssertTrue(output === source)
    }

    // MARK: - Advanced tone curve

    func testAdvancedCurveDarkeningPointsDarkenTheImage() throws {
        // The fixture is deliberately 512x512 -- larger than the 256-entry LUT
        // texture -- and every probe is deliberately far from the origin.
        //
        // The kernel's region-of-interest callback has to ask for the LUT's
        // *whole* extent for input index 1 on every destination tile, not the
        // tile's own rect. When it returned the tile rect, only the sliver of
        // the image overlapping the LUT's own 256x1 extent rendered and the
        // rest came back pure black. A 16x16 fixture read through
        // `centrePixel` could not catch that: the whole image fitted inside
        // the overlapping region, and averaging the image down to 1x1 would
        // have masked a partly-black render anyway.
        let side = 512
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        var adjustments = PhotoAdjustments.neutral
        adjustments.advancedToneCurve = AdvancedToneCurve(points: [
            ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 0.5)
        ])
        let output = pipeline.apply(adjustments, to: source)
        XCTAssertFalse(output === source, "A non-empty curve must actually reach the kernel")
        XCTAssertEqual(output.extent, source.extent)

        for probe in [
            CGPoint(x: 4, y: 4),
            CGPoint(x: 256, y: 256),
            CGPoint(x: 400, y: 400),
            CGPoint(x: CGFloat(side - 1), y: CGFloat(side - 1))
        ] {
            let base = try pixel(at: probe, in: source)
            let darkened = try pixel(at: probe, in: output)
            XCTAssertLessThan(darkened.red, base.red, "Curve should darken at \(probe)")
            XCTAssertGreaterThan(
                darkened.red, 0,
                "Pixel at \(probe) rendered black -- the LUT's region of interest is wrong again"
            )
        }
    }

    func testRedChannelCurveOnlyChangesTheRedChannel() throws {
        // P3: an independent Red curve must leave Green/Blue untouched, even
        // though the RGBA LUT texture packs all three channel tables into one
        // resource and one kernel pass reads it three times.
        let side = 512
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        var adjustments = PhotoAdjustments.neutral
        adjustments.advancedToneCurve = AdvancedToneCurve(redPoints: [
            ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 0.5)
        ])
        let output = pipeline.apply(adjustments, to: source)
        XCTAssertFalse(output === source)

        for probe in [CGPoint(x: 4, y: 4), CGPoint(x: 400, y: 400)] {
            let base = try pixel(at: probe, in: source)
            let edited = try pixel(at: probe, in: output)
            XCTAssertLessThan(edited.red, base.red, "Red channel curve should darken red at \(probe)")
            XCTAssertEqual(edited.green, base.green, accuracy: 1, "Green must be untouched by a Red-only curve")
            XCTAssertEqual(edited.blue, base.blue, accuracy: 1, "Blue must be untouched by a Red-only curve")
        }
    }

    func testCompositeAndBlueChannelCurvesComposeInFixedOrder() throws {
        // Composite is applied first, then the per-channel curve (design
        // spec §8 step 4). A Composite curve that darkens everything, plus a
        // Blue curve that darkens further, must darken blue more than red.
        let side = 512
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        var adjustments = PhotoAdjustments.neutral
        adjustments.advancedToneCurve = AdvancedToneCurve(
            points: [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 0.7)],
            bluePoints: [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 0.5)]
        )
        let output = pipeline.apply(adjustments, to: source)

        for probe in [CGPoint(x: 4, y: 4), CGPoint(x: 400, y: 400)] {
            let base = try pixel(at: probe, in: source)
            let edited = try pixel(at: probe, in: output)
            XCTAssertLessThan(edited.red, base.red, "Composite curve should darken red at \(probe)")
            XCTAssertLessThan(edited.blue, edited.red, "Blue channel curve composed after Composite should darken blue further at \(probe)")
        }
    }

    func testAllFourIdentityChannelsSkipTheCurveKernelEntirely() {
        // The `isAdvancedToneCurveIdentity` gate must still see an all-empty
        // `AdvancedToneCurve` as identity after adding three new arrays.
        let source = makeSourceImage()
        var adjustments = PhotoAdjustments.neutral
        adjustments.advancedToneCurve = AdvancedToneCurve.neutral
        let output = pipeline.apply(adjustments, to: source)
        XCTAssertTrue(output === source, "An all-identity curve must not add a filter to the chain")
    }

    // MARK: - HSL

    func testReducingRedSaturationDesaturatesARedPatch() throws {
        let red = makeSourceImage(red: 0.7, green: 0.2, blue: 0.2)
        let base = try centrePixel(red)
        var adjustments = PhotoAdjustments.neutral
        adjustments.hsl.red = HSLBand(hue: 0, saturation: -100, luminance: 0)
        let desaturated = try centrePixel(pipeline.apply(adjustments, to: red))
        XCTAssertLessThan(desaturated.red - desaturated.blue, base.red - base.blue)
    }

    func testAdjustingBlueDoesNotVisiblyMoveARedPatch() throws {
        // A band-selective tool must leave hues far from its centre close to
        // untouched -- this is what makes it "selective" rather than a
        // second global saturation slider.
        let red = makeSourceImage(red: 0.7, green: 0.2, blue: 0.2)
        let base = try centrePixel(red)
        var adjustments = PhotoAdjustments.neutral
        adjustments.hsl.blue = HSLBand(hue: 0, saturation: 100, luminance: 0)
        let stillRed = try centrePixel(pipeline.apply(adjustments, to: red))
        XCTAssertEqual(stillRed.red, base.red, accuracy: 3)
    }

    func testRedLuminanceDoesNotChangeAnAchromaticPatch() throws {
        // Hue is undefined when all three channels are equal. The HSL kernel
        // must not treat that default hue as red and alter neutral greys.
        let grey = makeSourceImage(red: 0.4, green: 0.4, blue: 0.4)
        let base = try centrePixel(grey)
        var adjustments = PhotoAdjustments.neutral
        adjustments.hsl.red = HSLBand(hue: 0, saturation: 0, luminance: 100)
        let edited = try centrePixel(pipeline.apply(adjustments, to: grey))

        XCTAssertEqual(edited.red, base.red, accuracy: 1)
        XCTAssertEqual(edited.green, base.green, accuracy: 1)
        XCTAssertEqual(edited.blue, base.blue, accuracy: 1)
    }
}

private func XCTAssertEqual(
    _ lhs: Int,
    _ rhs: Int,
    accuracy: Int,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertLessThanOrEqual(abs(lhs - rhs), accuracy, file: file, line: line)
}
