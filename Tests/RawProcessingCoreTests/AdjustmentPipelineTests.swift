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
