import CoreGraphics
import CoreImage
import XCTest
@testable import RawProcessingCore

/// Synthetic-image tests for `LocalAdjustmentRenderer` (Phase 4 Task 4.2):
/// gradient mask direction, feather, and local exposure. Tolerance-based
/// throughout -- a linear gradient is a continuous interpolation by
/// definition, so there is no exact pixel-count assertion to make, only "the
/// effect side reads differently from the background side" and "widening
/// feather visibly softens a fixed sample point" -- matching
/// `GeometryRendererTests`' own tolerance-based straighten/perspective tests.
final class LocalAdjustmentRendererTests: XCTestCase {
    private let size = CGSize(width: 64, height: 64)

    // MARK: - Fixture

    /// A flat mid-grey field -- deliberately not the `GeometryRendererTests`
    /// four-quadrant marker, because a gradient's effect (a uniform exposure
    /// boost) needs a uniform starting color to read cleanly as "brighter
    /// here, unchanged there" without a quadrant boundary confounding the
    /// sample points.
    private func makeFlatImage(size: CGSize? = nil) -> CIImage {
        let size = size ?? self.size
        return CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Visual/on-screen coordinates, (0,0) at the top-left, matching
    /// `GeometryRendererTests.sample(_:of:)`'s own convention.
    private func samplePoint(
        _ point: CGPoint,
        of image: CIImage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (red: Int, green: Int, blue: Int) {
        let renderer = ImageRenderService()
        let cgImage = try renderer.makeCGImage(image)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), file: file, line: line)
        context.draw(cgImage, in: CGRect(
            x: -point.x,
            y: -(CGFloat(cgImage.height) - 1 - point.y),
            width: CGFloat(cgImage.width),
            height: CGFloat(cgImage.height)
        ))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func brightness(_ sample: (red: Int, green: Int, blue: Int)) -> Int {
        sample.red + sample.green + sample.blue
    }

    // MARK: - Neutral / identity

    func testEmptyLocalAdjustmentsIsAnExactPassthrough() throws {
        let source = makeFlatImage()
        let output = LocalAdjustmentRenderer.apply([], to: source)
        XCTAssertEqual(output.extent, source.extent)
        let sample = try samplePoint(CGPoint(x: 32, y: 32), of: output)
        XCTAssertEqual(sample.red, 128, accuracy: 2)
    }

    func testDisabledLocalAdjustmentIsSkipped() throws {
        let source = makeFlatImage()
        let gradient = LocalAdjustment(
            kind: .linearGradient,
            isEnabled: false,
            geometry: LocalAdjustmentGeometry(x: 0.5, y: 0.5, angleDegrees: 0, range: 1, feather: 0),
            adjustments: LocalAdjustmentPatch(exposure: 3)
        )
        let output = LocalAdjustmentRenderer.apply([gradient], to: source)
        let sample = try samplePoint(CGPoint(x: 32, y: 32), of: output)
        XCTAssertEqual(sample.red, 128, accuracy: 2, "a disabled local adjustment must render exactly as if it were absent")
    }

    func testSpotHealEntriesAreIgnoredByThisRenderer() throws {
        // Task 4.2's own scope boundary (roadmap): spot heal render is Task
        // 4.4's job. A spotHeal entry must not crash or silently apply
        // gradient math against heal-shaped geometry.
        let source = makeFlatImage()
        let heal = LocalAdjustment(
            kind: .spotHeal,
            geometry: LocalAdjustmentGeometry(x: 0.5, y: 0.5, radius: 0.3, healMode: .heal),
            adjustments: LocalAdjustmentPatch(exposure: 3)
        )
        let output = LocalAdjustmentRenderer.apply([heal], to: source)
        let sample = try samplePoint(CGPoint(x: 32, y: 32), of: output)
        XCTAssertEqual(sample.red, 128, accuracy: 2)
    }

    // MARK: - Gradient mask direction

    /// angle 0 = the effect travels left-to-right (0% at the anchor's left,
    /// 100% at the anchor's right, matching `GeometryRenderer`'s own
    /// clockwise-from-pointing-right convention for consistency across this
    /// codebase's two renderers).
    func testAngleZeroAppliesMoreEffectToTheRightOfTheAnchorThanTheLeft() throws {
        let source = makeFlatImage()
        let gradient = LocalAdjustment(
            kind: .linearGradient,
            geometry: LocalAdjustmentGeometry(x: 0.5, y: 0.5, angleDegrees: 0, range: 0.5, feather: 10),
            adjustments: LocalAdjustmentPatch(exposure: 3)
        )
        let output = LocalAdjustmentRenderer.apply([gradient], to: source)

        let left = try samplePoint(CGPoint(x: 4, y: 32), of: output)
        let right = try samplePoint(CGPoint(x: 60, y: 32), of: output)
        XCTAssertGreaterThan(
            brightness(right), brightness(left) + 30,
            "angle 0 must brighten the right side of the anchor more than the left -- left=\(left) right=\(right)"
        )
    }

    /// angle 180 reverses which side gets the effect -- the two renders must
    /// not be identical, and the side that was dim at angle 0 must now be
    /// the bright one.
    func testAngle180ReversesWhichSideGetsTheEffect() throws {
        let source = makeFlatImage()
        func gradient(angle: Double) -> LocalAdjustment {
            LocalAdjustment(
                kind: .linearGradient,
                geometry: LocalAdjustmentGeometry(x: 0.5, y: 0.5, angleDegrees: angle, range: 0.5, feather: 10),
                adjustments: LocalAdjustmentPatch(exposure: 3)
            )
        }
        let at0 = LocalAdjustmentRenderer.apply([gradient(angle: 0)], to: source)
        let at180 = LocalAdjustmentRenderer.apply([gradient(angle: 180)], to: source)

        let leftAt0 = try samplePoint(CGPoint(x: 4, y: 32), of: at0)
        let leftAt180 = try samplePoint(CGPoint(x: 4, y: 32), of: at180)
        XCTAssertGreaterThan(
            brightness(leftAt180), brightness(leftAt0) + 30,
            "the side that was dim at angle 0 must be the bright side at angle 180 -- 0deg-left=\(leftAt0) 180deg-left=\(leftAt180)"
        )
    }

    /// angle 90 travels top-to-bottom instead of left-to-right -- the
    /// brightened axis rotates with it.
    func testAngle90AppliesMoreEffectBelowTheAnchorThanAbove() throws {
        let source = makeFlatImage()
        let gradient = LocalAdjustment(
            kind: .linearGradient,
            geometry: LocalAdjustmentGeometry(x: 0.5, y: 0.5, angleDegrees: 90, range: 0.5, feather: 10),
            adjustments: LocalAdjustmentPatch(exposure: 3)
        )
        let output = LocalAdjustmentRenderer.apply([gradient], to: source)

        let above = try samplePoint(CGPoint(x: 32, y: 4), of: output)
        let below = try samplePoint(CGPoint(x: 32, y: 60), of: output)
        XCTAssertGreaterThan(
            brightness(below), brightness(above) + 30,
            "angle 90 must brighten below the anchor more than above -- above=\(above) below=\(below)"
        )
    }

    // MARK: - Feather

    /// A fixed sample point that sits well inside the full-effect zone at
    /// low feather, but still inside the softening transition at high
    /// feather -- so the *same point* reads less-adjusted as feather grows,
    /// without needing to know the mask's exact analytic shape.
    func testWideningFeatherSoftensTheTransitionAtAFixedSamplePoint() throws {
        let source = makeFlatImage()
        func gradient(feather: Double) -> LocalAdjustment {
            LocalAdjustment(
                kind: .linearGradient,
                geometry: LocalAdjustmentGeometry(x: 0.5, y: 0.5, angleDegrees: 0, range: 0.15, feather: feather),
                // A modest boost -- strong enough to read clearly, short of
                // clipping to pure white at partial mask strength, which
                // would make a hard and a soft edge indistinguishable at
                // this sample point for the wrong reason (both saturated).
                adjustments: LocalAdjustmentPatch(exposure: 1.2)
            )
        }
        let hardEdge = LocalAdjustmentRenderer.apply([gradient(feather: 0)], to: source)
        let softEdge = LocalAdjustmentRenderer.apply([gradient(feather: 100)], to: source)

        // Just past the anchor -- already fully inside the effect zone when
        // the edge is hard (range 0.15 on a 64-wide canvas puts the hard
        // edge's full-effect point around x=39), still transitioning when
        // it is soft (feather 100 pushes that same boundary out to ~x=46).
        let point = CGPoint(x: 40, y: 32)
        let hard = try samplePoint(point, of: hardEdge)
        let soft = try samplePoint(point, of: softEdge)
        XCTAssertGreaterThan(
            brightness(hard), brightness(soft) + 15,
            "a hard edge should already be near full effect at this point while a soft one is still transitioning -- hard=\(hard) soft=\(soft)"
        )
    }

    func testZeroFeatherAndZeroRangeStillProducesAValidMask() throws {
        // Degenerate input (both knobs at their floor) must not crash or
        // divide by zero -- it just means "as hard an edge as this
        // implementation can produce", not literally infinitely sharp.
        let source = makeFlatImage()
        let gradient = LocalAdjustment(
            kind: .linearGradient,
            geometry: LocalAdjustmentGeometry(x: 0.5, y: 0.5, angleDegrees: 0, range: 0, feather: 0),
            adjustments: LocalAdjustmentPatch(exposure: 3)
        )
        let output = LocalAdjustmentRenderer.apply([gradient], to: source)
        XCTAssertEqual(output.extent, source.extent)
    }

    // MARK: - Local exposure

    func testLocalExposureBrightensTheEffectSideAndLeavesTheFarSideUnchanged() throws {
        let source = makeFlatImage()
        let gradient = LocalAdjustment(
            kind: .linearGradient,
            geometry: LocalAdjustmentGeometry(x: 0.5, y: 0.5, angleDegrees: 0, range: 0.5, feather: 5),
            adjustments: LocalAdjustmentPatch(exposure: 3)
        )
        let output = LocalAdjustmentRenderer.apply([gradient], to: source)

        let effectSide = try samplePoint(CGPoint(x: 60, y: 32), of: output)
        let farSide = try samplePoint(CGPoint(x: 2, y: 32), of: output)
        XCTAssertGreaterThan(brightness(effectSide), 128 * 3, "a +3 EV local exposure boost must visibly brighten the effect side")
        XCTAssertEqual(brightness(farSide), 128 * 3, accuracy: 6, "the far side, outside the gradient's reach, must be unaffected")
    }

    func testNegativeLocalExposureDarkensTheEffectSide() throws {
        let source = makeFlatImage()
        let gradient = LocalAdjustment(
            kind: .linearGradient,
            geometry: LocalAdjustmentGeometry(x: 0.5, y: 0.5, angleDegrees: 0, range: 0.5, feather: 5),
            adjustments: LocalAdjustmentPatch(exposure: -3)
        )
        let output = LocalAdjustmentRenderer.apply([gradient], to: source)

        let effectSide = try samplePoint(CGPoint(x: 60, y: 32), of: output)
        XCTAssertLessThan(brightness(effectSide), 128 * 3, "a negative local exposure must darken the effect side")
    }

    func testUnsetPatchFieldsHaveNoEffect() throws {
        let source = makeFlatImage()
        let gradient = LocalAdjustment(
            kind: .linearGradient,
            geometry: LocalAdjustmentGeometry(x: 0.5, y: 0.5, angleDegrees: 0, range: 1, feather: 0),
            adjustments: LocalAdjustmentPatch()
        )
        let output = LocalAdjustmentRenderer.apply([gradient], to: source)
        let sample = try samplePoint(CGPoint(x: 60, y: 32), of: output)
        XCTAssertEqual(sample.red, 128, accuracy: 2, "an empty patch (no fields set) must render as a pure passthrough")
    }

    // MARK: - Multiple entries composite in order

    func testMultipleEnabledEntriesBothApply() throws {
        // `CILinearGradient` plateaus at `color1` past `point1` rather than
        // fading back down -- the same "graduated half-plane, not a
        // localized blob" behavior a real linear-gradient tool has (its
        // effect legitimately extends to the far edge of the frame once
        // past the transition). So each gradient here points its 100%-effect
        // side toward its own nearby edge and its 0%-effect side toward the
        // centre, which is what actually produces a genuinely untouched
        // middle between two independent gradients -- two gradients both
        // pointing the same direction would instead have the first one's
        // plateau cover the second gradient's anchor entirely.
        let source = makeFlatImage()
        let first = LocalAdjustment(
            kind: .linearGradient,
            geometry: LocalAdjustmentGeometry(x: 0.2, y: 0.5, angleDegrees: 180, range: 0.15, feather: 5),
            adjustments: LocalAdjustmentPatch(exposure: 2)
        )
        let second = LocalAdjustment(
            kind: .linearGradient,
            geometry: LocalAdjustmentGeometry(x: 0.8, y: 0.5, angleDegrees: 0, range: 0.15, feather: 5),
            adjustments: LocalAdjustmentPatch(exposure: 2)
        )
        let output = LocalAdjustmentRenderer.apply([first, second], to: source)

        let nearFirst = try samplePoint(CGPoint(x: 2, y: 32), of: output)
        let nearSecond = try samplePoint(CGPoint(x: 62, y: 32), of: output)
        let middle = try samplePoint(CGPoint(x: 32, y: 32), of: output)
        XCTAssertGreaterThan(brightness(nearFirst), 128 * 3, "the first gradient's effect side must be brighter")
        XCTAssertGreaterThan(brightness(nearSecond), 128 * 3, "the second gradient's effect side must be brighter")
        XCTAssertEqual(brightness(middle), 128 * 3, accuracy: 10, "roughly untouched between the two gradients' effect zones")
    }
}

private func XCTAssertEqual(
    _ expression1: Int,
    _ expression2: Int,
    accuracy: Int,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertLessThanOrEqual(abs(expression1 - expression2), accuracy, message, file: file, line: line)
}
