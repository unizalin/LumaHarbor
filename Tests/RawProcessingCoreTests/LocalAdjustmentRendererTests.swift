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

    /// Left half pure blue (red channel 0), right half pure red (red channel
    /// 255) -- unlike `makeFlatImage`, spot heal/clone need actual pixel
    /// content difference between a source and a target region to prove
    /// content was actually copied; a flat fixture would make clone/heal
    /// invisible to a pixel assertion. A horizontal split needs no
    /// visual/Core-Image y-flip (unlike `GeometryRendererTests`'
    /// `makeQuadrantImage`, which does), since x means the same thing in
    /// both coordinate systems.
    private func makeHalvesImage(size: CGSize? = nil) -> CIImage {
        let size = size ?? self.size
        let halfWidth = size.width / 2
        let left = CIImage(color: CIColor(red: 0, green: 0, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: halfWidth, height: size.height))
        let right = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: halfWidth, y: 0, width: size.width - halfWidth, height: size.height))
        return left.composited(over: right).cropped(to: CGRect(origin: .zero, size: size))
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

    func testDisabledSpotHealIsSkipped() throws {
        let source = makeHalvesImage()
        let heal = LocalAdjustment(
            kind: .spotHeal,
            isEnabled: false,
            geometry: LocalAdjustmentGeometry(x: 0.2, y: 0.5, sourceX: 0.8, sourceY: 0.5, radius: 0.15, feather: 0, healMode: .clone)
        )
        let output = LocalAdjustmentRenderer.apply([heal], to: source)
        let target = try samplePoint(CGPoint(x: 12, y: 32), of: output)
        XCTAssertEqual(target.red, 0, accuracy: 2, "a disabled spot heal entry must render as if it were never added -- the left (blue) half must stay untouched")
    }

    // MARK: - Spot heal / clone (Task 4.4)

    func testCloneCopiesContentFromSourceToTarget() throws {
        let source = makeHalvesImage()
        let heal = LocalAdjustment(
            kind: .spotHeal,
            geometry: LocalAdjustmentGeometry(x: 0.2, y: 0.5, sourceX: 0.8, sourceY: 0.5, radius: 0.15, feather: 0, healMode: .clone)
        )
        let output = LocalAdjustmentRenderer.apply([heal], to: source)

        let target = try samplePoint(CGPoint(x: 12, y: 32), of: output)
        XCTAssertGreaterThan(target.red, 200, "clone must copy the source region's red content onto the target -- got \(target)")

        let farFromTarget = try samplePoint(CGPoint(x: 2, y: 2), of: output)
        XCTAssertEqual(farFromTarget.red, 0, accuracy: 2, "clone must stay confined to the brush radius around the target")
    }

    func testMovingTheSourcePointChangesWhatIsCloned() throws {
        let source = makeHalvesImage()
        func heal(sourceX: Double) -> LocalAdjustment {
            LocalAdjustment(
                kind: .spotHeal,
                geometry: LocalAdjustmentGeometry(x: 0.2, y: 0.5, sourceX: sourceX, sourceY: 0.5, radius: 0.1, feather: 0, healMode: .clone)
            )
        }
        let redSourcedOutput = LocalAdjustmentRenderer.apply([heal(sourceX: 0.8)], to: source)
        let blueSourcedOutput = LocalAdjustmentRenderer.apply([heal(sourceX: 0.25)], to: source)

        let targetPoint = CGPoint(x: 12, y: 32)
        let redSourced = try samplePoint(targetPoint, of: redSourcedOutput)
        let blueSourced = try samplePoint(targetPoint, of: blueSourcedOutput)
        XCTAssertGreaterThan(
            redSourced.red, blueSourced.red + 100,
            "moving the source point must change what content clone copies onto an unchanged target -- red-sourced=\(redSourced) blue-sourced=\(blueSourced)"
        )
    }

    func testMovingTheTargetPointMovesWhereTheEffectAppears() throws {
        let source = makeHalvesImage()
        func heal(targetX: Double) -> LocalAdjustment {
            LocalAdjustment(
                kind: .spotHeal,
                geometry: LocalAdjustmentGeometry(x: targetX, y: 0.5, sourceX: 0.8, sourceY: 0.5, radius: 0.08, feather: 0, healMode: .clone)
            )
        }
        let targetNearLeftEdge = LocalAdjustmentRenderer.apply([heal(targetX: 0.15)], to: source)
        let targetFurtherRight = LocalAdjustmentRenderer.apply([heal(targetX: 0.35)], to: source)

        let pointA = CGPoint(x: 9, y: 32) // 0.15 * 64, still left (blue) half of the untouched source
        let pointB = CGPoint(x: 22, y: 32) // 0.35 * 64, likewise left half, far from pointA's brush radius

        let atA_whenTargetIsA = try samplePoint(pointA, of: targetNearLeftEdge)
        let atB_whenTargetIsA = try samplePoint(pointB, of: targetNearLeftEdge)
        XCTAssertGreaterThan(atA_whenTargetIsA.red, 200, "the effect must land at the target point")
        XCTAssertEqual(atB_whenTargetIsA.red, 0, accuracy: 2, "a point well outside the target's brush radius must stay untouched")

        let atB_whenTargetIsB = try samplePoint(pointB, of: targetFurtherRight)
        XCTAssertGreaterThan(
            atB_whenTargetIsB.red, 200,
            "moving the target point must move where the effect appears, not just widen the original spot"
        )
    }

    func testSwitchingHealModeOnTheSameAdjustmentImmediatelyChangesBehaviorWithoutClearingTheSourcePoint() throws {
        // Design spec 6.7: "模式切換時，當前選取點必須立即更新，不只影響下一個
        // 新點" -- switching mode must immediately change how the currently
        // selected point renders, not merely apply to the next point the user
        // creates. Modeled here at the render layer: the same `LocalAdjustment`
        // (same id, same geometry, same lingering `sourceX`/`sourceY`) renders
        // differently the instant only `healMode` flips -- proving the switch
        // takes effect immediately and isn't gated on clearing/resetting the
        // source point first.
        let source = makeHalvesImage()
        let geometry = LocalAdjustmentGeometry(x: 0.1, y: 0.5, sourceX: 0.8, sourceY: 0.5, radius: 0.05, feather: 0, healMode: .heal)
        var adjustment = LocalAdjustment(kind: .spotHeal, geometry: geometry)
        let targetPoint = CGPoint(x: 6, y: 32)

        let healOutput = LocalAdjustmentRenderer.apply([adjustment], to: source)
        let healed = try samplePoint(targetPoint, of: healOutput)
        XCTAssertEqual(
            healed.red, 0, accuracy: 10,
            "heal mode must ignore the stale explicit source point (which points at the red half) and auto-sample nearby still-blue texture instead -- got \(healed)"
        )

        adjustment.geometry.healMode = .clone
        let cloneOutput = LocalAdjustmentRenderer.apply([adjustment], to: source)
        let cloned = try samplePoint(targetPoint, of: cloneOutput)
        XCTAssertGreaterThan(
            cloned.red, 200,
            "flipping healMode to .clone on the very same adjustment must immediately start using the explicit source point that was already there, with no other field changed -- got \(cloned)"
        )
    }

    func testHealModeWithNoExplicitSourcePointAutoSamplesRatherThanCrashing() throws {
        let source = makeHalvesImage()
        let heal = LocalAdjustment(
            kind: .spotHeal,
            geometry: LocalAdjustmentGeometry(x: 0.1, y: 0.5, radius: 0.05, feather: 0, healMode: .heal)
        )
        let output = LocalAdjustmentRenderer.apply([heal], to: source)
        XCTAssertEqual(output.extent, source.extent)
        let target = try samplePoint(CGPoint(x: 6, y: 32), of: output)
        XCTAssertEqual(target.red, 0, accuracy: 10, "with no source placed, heal must still auto-sample nearby texture rather than crash or leave a hole")
    }

    func testTargetAndSourceAtTheSamePointIsAHarmlessNoOp() throws {
        let source = makeHalvesImage()
        let heal = LocalAdjustment(
            kind: .spotHeal,
            geometry: LocalAdjustmentGeometry(x: 0.2, y: 0.5, sourceX: 0.2, sourceY: 0.5, radius: 0.1, feather: 0, healMode: .clone)
        )
        let output = LocalAdjustmentRenderer.apply([heal], to: source)
        let target = try samplePoint(CGPoint(x: 12, y: 32), of: output)
        XCTAssertEqual(target.red, 0, accuracy: 2, "cloning a point onto itself must not corrupt or crash -- it's a no-op")
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
