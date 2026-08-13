import XCTest
@testable import RawProcessingCore

final class PhotoAdjustmentsTests: XCTestCase {
    func testNeutralIsAllZeroes() {
        for kind in AdjustmentKind.allCases {
            XCTAssertEqual(PhotoAdjustments.neutral[kind], 0, "\(kind)")
        }
        XCTAssertTrue(PhotoAdjustments.neutral.isNeutral)
        XCTAssertTrue(PhotoAdjustments.neutral.modifiedKinds.isEmpty)
    }

    func testSubscriptRoundTripsEveryKind() {
        var adjustments = PhotoAdjustments.neutral
        for (offset, kind) in AdjustmentKind.allCases.enumerated() {
            // A distinct value per kind so a copy/paste slip in the switch shows up.
            let value = Double(offset + 1) * (kind == .exposure ? 0.25 : 3)
            adjustments[kind] = value
            XCTAssertEqual(adjustments[kind], value, "\(kind)")
        }
        XCTAssertEqual(Set(adjustments.modifiedKinds), Set(AdjustmentKind.allCases))
    }

    func testSubscriptClampsToTheCatalogRange() {
        var adjustments = PhotoAdjustments.neutral
        adjustments[.exposure] = 99
        XCTAssertEqual(adjustments.exposure, 5)
        adjustments[.saturation] = -400
        XCTAssertEqual(adjustments.saturation, -100)
    }

    func testInitClampsOutOfRangeValues() {
        let adjustments = PhotoAdjustments(exposure: 20, contrast: -900, vibrance: 250)
        XCTAssertEqual(adjustments.exposure, 5)
        XCTAssertEqual(adjustments.contrast, -100)
        XCTAssertEqual(adjustments.vibrance, 100)
    }

    func testResettingOneAdjustmentLeavesTheOthers() {
        let edited = PhotoAdjustments(exposure: 1.5, contrast: 40, saturation: -20)
        let reset = edited.resetting(.contrast)
        XCTAssertEqual(reset.contrast, 0)
        XCTAssertEqual(reset.exposure, 1.5)
        XCTAssertEqual(reset.saturation, -20)
    }

    // MARK: - Sidecar encoding

    func testEncodesEveryDocumentedKey() throws {
        let data = try JSONEncoder().encode(PhotoAdjustments.neutral)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        // Spec §8.2 fixes this exact key set.
        XCTAssertEqual(
            Set(object.keys),
            [
                "exposure", "temperature", "tint", "contrast", "highlights",
                "shadows", "whites", "blacks", "vibrance", "saturation"
            ]
        )
    }

    func testRoundTripsThroughJSON() throws {
        let original = PhotoAdjustments(
            exposure: 1.25, temperature: -30, tint: 12, contrast: 45,
            highlights: -60, shadows: 25, whites: 10, blacks: -15,
            vibrance: 33, saturation: -8
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMissingKeysFallBackToDefaults() throws {
        // A sidecar written before a key existed must still open.
        let json = Data(#"{"exposure": 2.0}"#.utf8)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: json)
        XCTAssertEqual(decoded.exposure, 2.0)
        XCTAssertEqual(decoded.contrast, 0)
        XCTAssertEqual(decoded.saturation, 0)
    }

    func testOutOfRangeValuesInJSONAreClampedNotRejected() throws {
        // Hand-edited or future-version files degrade instead of failing to open.
        let json = Data(#"{"exposure": 99.0, "contrast": -5000}"#.utf8)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: json)
        XCTAssertEqual(decoded.exposure, 5)
        XCTAssertEqual(decoded.contrast, -100)
    }

    func testEncodingIsStableForIdenticalValues() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(PhotoAdjustments(exposure: 1))
        let second = try encoder.encode(PhotoAdjustments(exposure: 1))
        XCTAssertEqual(first, second)
    }
}
