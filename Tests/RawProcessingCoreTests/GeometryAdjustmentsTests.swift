import XCTest
@testable import RawProcessingCore

final class GeometryAdjustmentsTests: XCTestCase {
    // MARK: - Neutral / identity

    func testNeutralIsIdentity() {
        let geometry = GeometryAdjustments.neutral
        XCTAssertNil(geometry.crop)
        XCTAssertEqual(geometry.cropAspectRatio, .freeform)
        XCTAssertEqual(geometry.rotationDegrees, 0)
        XCTAssertFalse(geometry.flipHorizontal)
        XCTAssertFalse(geometry.flipVertical)
        XCTAssertEqual(geometry.straightenDegrees, 0)
        XCTAssertEqual(geometry.perspectiveHorizontal, 0)
        XCTAssertEqual(geometry.perspectiveVertical, 0)
        XCTAssertTrue(geometry.isIdentity)
    }

    func testAnyNonDefaultFieldIsNotIdentity() {
        XCTAssertFalse(GeometryAdjustments(rotationDegrees: 90).isIdentity)
        XCTAssertFalse(GeometryAdjustments(flipHorizontal: true).isIdentity)
        XCTAssertFalse(GeometryAdjustments(crop: NormalizedCropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)).isIdentity)
    }

    // MARK: - Rotation (§6.5: "旋轉 90 度" is a discrete action)

    func testRotationSnapsToTheNearestQuarterTurn() {
        XCTAssertEqual(GeometryAdjustments(rotationDegrees: 44).rotationDegrees, 0)
        XCTAssertEqual(GeometryAdjustments(rotationDegrees: 46).rotationDegrees, 90)
        XCTAssertEqual(GeometryAdjustments(rotationDegrees: 179).rotationDegrees, 180)
    }

    func testRotationWrapsIntoZeroToThreeSixty() {
        XCTAssertEqual(GeometryAdjustments(rotationDegrees: -90).rotationDegrees, 270)
        XCTAssertEqual(GeometryAdjustments(rotationDegrees: 450).rotationDegrees, 90)
        XCTAssertEqual(GeometryAdjustments(rotationDegrees: 720).rotationDegrees, 0)
    }

    func testRotationRejectsNonFiniteInputSafely() {
        XCTAssertEqual(GeometryAdjustments(rotationDegrees: .nan).rotationDegrees, 0)
        XCTAssertEqual(GeometryAdjustments(rotationDegrees: .infinity).rotationDegrees, 0)
    }

    func testRotatedClockwiseCyclesThroughAllFourQuarterTurns() {
        var geometry = GeometryAdjustments.neutral
        let expected: [Double] = [90, 180, 270, 0]
        for expectedValue in expected {
            geometry = geometry.rotatedClockwise()
            XCTAssertEqual(geometry.rotationDegrees, expectedValue)
        }
    }

    func testRotatedCounterclockwiseIsTheInverseOfClockwise() {
        let geometry = GeometryAdjustments.neutral.rotatedClockwise().rotatedCounterclockwise()
        XCTAssertEqual(geometry.rotationDegrees, 0)
    }

    // MARK: - Flip

    func testFlippingHorizontalTogglesOnlyThatAxis() {
        let flipped = GeometryAdjustments.neutral.flippingHorizontal()
        XCTAssertTrue(flipped.flipHorizontal)
        XCTAssertFalse(flipped.flipVertical)
        XCTAssertFalse(flipped.flippingHorizontal().flipHorizontal, "flipping twice returns to unflipped")
    }

    func testFlippingVerticalTogglesOnlyThatAxis() {
        let flipped = GeometryAdjustments.neutral.flippingVertical()
        XCTAssertTrue(flipped.flipVertical)
        XCTAssertFalse(flipped.flipHorizontal)
    }

    // MARK: - Straighten (fine-angle slider, independent of the 90° rotate action)

    func testStraightenIsClampedToPlusMinus45() {
        XCTAssertEqual(GeometryAdjustments(straightenDegrees: 60).straightenDegrees, 45)
        XCTAssertEqual(GeometryAdjustments(straightenDegrees: -60).straightenDegrees, -45)
        XCTAssertEqual(GeometryAdjustments(straightenDegrees: 12.5).straightenDegrees, 12.5, "in-range values pass through exactly")
    }

    func testStraightenRejectsNonFiniteInputSafely() {
        XCTAssertEqual(GeometryAdjustments(straightenDegrees: .nan).straightenDegrees, 0)
    }

    // MARK: - Perspective

    func testPerspectiveIsClampedToPlusMinus100() {
        XCTAssertEqual(GeometryAdjustments(perspectiveHorizontal: 150).perspectiveHorizontal, 100)
        XCTAssertEqual(GeometryAdjustments(perspectiveVertical: -150).perspectiveVertical, -100)
    }

    // MARK: - Reset

    func testResetReturnsEveryFieldToNeutral() {
        let edited = GeometryAdjustments(
            crop: NormalizedCropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
            cropAspectRatio: .square,
            rotationDegrees: 90,
            flipHorizontal: true,
            flipVertical: true,
            straightenDegrees: 10,
            perspectiveHorizontal: 20,
            perspectiveVertical: -20
        )
        XCTAssertEqual(edited.reset(), .neutral)
    }

    func testResettingCropClearsCropAndAspectRatioButNotOtherFields() {
        let edited = GeometryAdjustments(
            crop: NormalizedCropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
            cropAspectRatio: .square,
            rotationDegrees: 90
        )
        let result = edited.resettingCrop()
        XCTAssertNil(result.crop)
        XCTAssertEqual(result.cropAspectRatio, .freeform)
        XCTAssertEqual(result.rotationDegrees, 90, "resetting crop must not touch rotation")
    }

    func testResettingRotationLeavesFlipAndStraightenAlone() {
        let edited = GeometryAdjustments(rotationDegrees: 180, flipHorizontal: true, straightenDegrees: 5)
        let result = edited.resettingRotation()
        XCTAssertEqual(result.rotationDegrees, 0)
        XCTAssertTrue(result.flipHorizontal)
        XCTAssertEqual(result.straightenDegrees, 5)
    }

    func testResettingStraightenLeavesRotationAlone() {
        let edited = GeometryAdjustments(rotationDegrees: 90, straightenDegrees: 20)
        let result = edited.resettingStraighten()
        XCTAssertEqual(result.straightenDegrees, 0)
        XCTAssertEqual(result.rotationDegrees, 90)
    }

    func testResettingPerspectiveZeroesBothAxes() {
        let edited = GeometryAdjustments(perspectiveHorizontal: 40, perspectiveVertical: -40)
        let result = edited.resettingPerspective()
        XCTAssertEqual(result.perspectiveHorizontal, 0)
        XCTAssertEqual(result.perspectiveVertical, 0)
    }

    // MARK: - Codable / sidecar compatibility

    func testEncodesEveryDocumentedKeyWhenCropIsSet() throws {
        let withCrop = GeometryAdjustments(crop: NormalizedCropRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        let data = try JSONEncoder().encode(withCrop)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            [
                "crop", "cropAspectRatio", "rotationDegrees", "flipHorizontal",
                "flipVertical", "straightenDegrees", "perspectiveHorizontal", "perspectiveVertical"
            ]
        )
    }

    func testNeutralOmitsTheCropKeyEntirelyRatherThanEncodingNull() throws {
        let data = try JSONEncoder().encode(GeometryAdjustments.neutral)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            [
                "cropAspectRatio", "rotationDegrees", "flipHorizontal",
                "flipVertical", "straightenDegrees", "perspectiveHorizontal", "perspectiveVertical"
            ]
        )
        XCTAssertNil(object["crop"], "no crop means the key is absent, not null")
    }

    func testRoundTripsThroughJSON() throws {
        let original = GeometryAdjustments(
            crop: NormalizedCropRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5),
            cropAspectRatio: .custom(width: 4, height: 3),
            rotationDegrees: 180,
            flipHorizontal: true,
            flipVertical: false,
            straightenDegrees: -12.5,
            perspectiveHorizontal: 30,
            perspectiveVertical: -15
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GeometryAdjustments.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEmptyJSONObjectDecodesToNeutral() throws {
        // Exactly what a sidecar written before this struct existed omits:
        // no "geometry" key at all reaches this decoder in practice (see
        // `PhotoAdjustmentsTests`), but this pins the struct's own standalone
        // all-keys-missing behaviour too.
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(GeometryAdjustments.self, from: json)
        XCTAssertEqual(decoded, .neutral)
    }

    func testOutOfRangeValuesInJSONAreClampedNotRejected() throws {
        let json = Data(#"""
        {"rotationDegrees": 460, "straightenDegrees": 999, "perspectiveHorizontal": -999}
        """#.utf8)
        let decoded = try JSONDecoder().decode(GeometryAdjustments.self, from: json)
        XCTAssertEqual(decoded.rotationDegrees, 90)
        XCTAssertEqual(decoded.straightenDegrees, 45)
        XCTAssertEqual(decoded.perspectiveHorizontal, -100)
    }
}

final class NormalizedCropRectTests: XCTestCase {
    func testFullIsTheEntireNormalizedFrame() {
        let full = NormalizedCropRect.full
        XCTAssertEqual(full.x, 0)
        XCTAssertEqual(full.y, 0)
        XCTAssertEqual(full.width, 1)
        XCTAssertEqual(full.height, 1)
        XCTAssertTrue(full.isFull)
    }

    func testInRangeValuesPassThroughUnchanged() {
        let rect = NormalizedCropRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        XCTAssertEqual(rect.x, 0.1)
        XCTAssertEqual(rect.y, 0.2)
        XCTAssertEqual(rect.width, 0.3)
        XCTAssertEqual(rect.height, 0.4)
    }

    func testNegativeOriginClampsToZero() {
        let rect = NormalizedCropRect(x: -0.5, y: -0.2, width: 0.3, height: 0.3)
        XCTAssertEqual(rect.x, 0)
        XCTAssertEqual(rect.y, 0)
    }

    func testOversizedDimensionsClampToOne() {
        let rect = NormalizedCropRect(x: 0, y: 0, width: 5, height: 5)
        XCTAssertEqual(rect.width, 1)
        XCTAssertEqual(rect.height, 1)
    }

    func testOriginPlusSizePastTheEdgeSlidesTheOriginBackKeepingTheRequestedSize() {
        let rect = NormalizedCropRect(x: 0.8, y: 0.9, width: 0.5, height: 0.5)
        XCTAssertEqual(rect.width, 0.5, "size is preserved")
        XCTAssertEqual(rect.height, 0.5)
        XCTAssertEqual(rect.x, 0.5, "origin slides left so x + width == 1")
        XCTAssertEqual(rect.y, 0.5, "origin slides up so y + height == 1")
    }

    func testZeroOrNegativeDimensionsFloorToTheMinimum() {
        let zero = NormalizedCropRect(x: 0, y: 0, width: 0, height: 0)
        XCTAssertEqual(zero.width, NormalizedCropRect.minimumDimension)
        XCTAssertEqual(zero.height, NormalizedCropRect.minimumDimension)

        let negative = NormalizedCropRect(x: 0, y: 0, width: -1, height: -1)
        XCTAssertEqual(negative.width, NormalizedCropRect.minimumDimension)
        XCTAssertEqual(negative.height, NormalizedCropRect.minimumDimension)
    }

    func testNonFiniteInputFallsBackToTheFullFrameRatherThanPropagatingNaN() {
        let rect = NormalizedCropRect(x: .nan, y: 0, width: .infinity, height: 0.5)
        XCTAssertEqual(rect, .full)
    }

    func testAspectRatioIsWidthOverHeight() {
        let rect = NormalizedCropRect(x: 0, y: 0, width: 0.8, height: 0.4)
        XCTAssertEqual(rect.aspectRatio, 2)
    }

    func testCodableRoundTrip() throws {
        let original = NormalizedCropRect(x: 0.15, y: 0.25, width: 0.5, height: 0.35)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NormalizedCropRect.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMissingKeysDecodeToTheFullFrame() throws {
        let decoded = try JSONDecoder().decode(NormalizedCropRect.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, .full)
    }

    func testOutOfRangeJSONValuesAreClampedNotRejected() throws {
        let json = Data(#"{"x": -1, "y": 2, "width": 3, "height": -3}"#.utf8)
        let decoded = try JSONDecoder().decode(NormalizedCropRect.self, from: json)
        XCTAssertGreaterThanOrEqual(decoded.x, 0)
        XCTAssertLessThanOrEqual(decoded.x + decoded.width, 1.0001)
        XCTAssertGreaterThanOrEqual(decoded.y, 0)
        XCTAssertLessThanOrEqual(decoded.y + decoded.height, 1.0001)
        XCTAssertGreaterThanOrEqual(decoded.width, NormalizedCropRect.minimumDimension)
        XCTAssertGreaterThanOrEqual(decoded.height, NormalizedCropRect.minimumDimension)
    }
}

final class CropAspectRatioTests: XCTestCase {
    func testFreeformAndOriginalHaveNoFixedRatio() {
        XCTAssertNil(CropAspectRatio.freeform.fixedRatio)
        XCTAssertNil(CropAspectRatio.original.fixedRatio)
    }

    func testSquareRatioIsOne() {
        XCTAssertEqual(CropAspectRatio.square.fixedRatio, 1)
    }

    func testCustomRatioIsWidthOverHeight() {
        XCTAssertEqual(CropAspectRatio.custom(width: 4, height: 3).fixedRatio, 4.0 / 3.0)
        XCTAssertEqual(CropAspectRatio.custom(width: 16, height: 9).fixedRatio!, 16.0 / 9.0, accuracy: 0.0001)
    }

    func testCustomRatioWithNonPositiveDimensionsIsTreatedAsUnconstrained() {
        XCTAssertNil(CropAspectRatio.custom(width: 0, height: 3).fixedRatio)
        XCTAssertNil(CropAspectRatio.custom(width: -4, height: 3).fixedRatio)
        XCTAssertNil(CropAspectRatio.custom(width: .nan, height: 3).fixedRatio)
    }

    func testEveryCaseRoundTripsThroughJSON() throws {
        let cases: [CropAspectRatio] = [.freeform, .original, .square, .custom(width: 5, height: 7)]
        for original in cases {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(CropAspectRatio.self, from: data)
            XCTAssertEqual(decoded, original)
        }
    }
}
