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
        XCTAssertEqual(
            Set(object.keys),
            [
                "exposure", "temperature", "tint", "contrast", "highlights",
                "shadows", "whites", "blacks", "vibrance", "saturation",
                "advancedToneCurve", "hsl", "splitToning", "sharpening",
                "noiseReduction", "vignette", "grain", "geometry", "localAdjustments",
                "presence", "colorGrading", "monochrome", "renderingProfile", "lensCorrection"
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

    func testNewFieldsDefaultToNeutral() {
        let adjustments = PhotoAdjustments.neutral
        XCTAssertEqual(adjustments.advancedToneCurve, .neutral)
        XCTAssertEqual(adjustments.hsl, .neutral)
        XCTAssertEqual(adjustments.splitToning, .neutral)
        XCTAssertEqual(adjustments.sharpening, .neutral)
        XCTAssertEqual(adjustments.noiseReduction, .neutral)
        XCTAssertEqual(adjustments.vignette, .neutral)
        XCTAssertEqual(adjustments.grain, .neutral)
        XCTAssertEqual(adjustments.geometry, .neutral)
    }

    // MARK: - P4: Presence, Color Grading, Monochrome, Rendering Profile, Lens Correction

    func testP4FieldsDefaultToNeutral() {
        let adjustments = PhotoAdjustments.neutral
        XCTAssertEqual(adjustments.presence, .neutral)
        XCTAssertEqual(adjustments.colorGrading, .neutral)
        XCTAssertEqual(adjustments.monochrome, .neutral)
        XCTAssertEqual(adjustments.renderingProfile, .neutral)
        XCTAssertEqual(adjustments.lensCorrection, .neutral)
    }

    func testOldSidecarWithoutP4KeysDecodesToNeutralExpansions() throws {
        // Exactly what every real sidecar on disk looks like before P4.
        let json = Data(#"""
        {"exposure": 1.0, "temperature": 0, "tint": 0, "contrast": 0, "highlights": 0,
         "shadows": 0, "whites": 0, "blacks": 0, "vibrance": 0, "saturation": 0,
         "advancedToneCurve": {}, "hsl": {}, "splitToning": {},
         "sharpening": {}, "noiseReduction": {}, "vignette": {}, "grain": {}, "geometry": {}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: json)
        XCTAssertEqual(decoded.exposure, 1.0)
        XCTAssertEqual(decoded.presence, .neutral)
        XCTAssertEqual(decoded.colorGrading, .neutral)
        XCTAssertEqual(decoded.monochrome, .neutral)
        XCTAssertEqual(decoded.renderingProfile, .neutral)
        XCTAssertEqual(decoded.lensCorrection, .neutral)
    }

    func testRoundTripsP4FieldsThroughJSON() throws {
        var original = PhotoAdjustments.neutral
        original.presence = PresenceAdjustments(texture: 30, clarity: -10, dehaze: 40)
        original.colorGrading.shadows = ColorGradeBand(hue: 220, saturation: 20, luminance: -5)
        original.monochrome = MonochromeAdjustments(isEnabled: true, red: 30)
        original.renderingProfile = RenderingProfileSelection(profileID: "lumaharbor.vivid", amount: 80)
        original.lensCorrection = LensCorrectionAdjustments(mode: .manual, distortionAmount: 20)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testOldSidecarWithoutNewFieldsDecodesToNeutralExpansions() throws {
        // Exactly the old MVP sidecar shape — none of the seven new keys present.
        let json = Data(#"""
        {"exposure": 1.0, "temperature": 0, "tint": 0, "contrast": 0, "highlights": 0,
         "shadows": 0, "whites": 0, "blacks": 0, "vibrance": 0, "saturation": 0}
        """#.utf8)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: json)
        XCTAssertEqual(decoded.exposure, 1.0)
        XCTAssertEqual(decoded.advancedToneCurve, .neutral)
        XCTAssertEqual(decoded.hsl, .neutral)
        XCTAssertEqual(decoded.splitToning, .neutral)
        XCTAssertEqual(decoded.sharpening, .neutral)
        XCTAssertEqual(decoded.noiseReduction, .neutral)
        XCTAssertEqual(decoded.vignette, .neutral)
        XCTAssertEqual(decoded.grain, .neutral)
        XCTAssertEqual(decoded.geometry, .neutral)
    }

    /// The most realistic backward-compat case: a sidecar written by Phase 1
    /// (every pre-geometry key present) but with no "geometry" key at all —
    /// exactly what every real sidecar on disk looks like before this task.
    func testPhase1SidecarWithoutGeometryKeyDecodesToNeutralGeometry() throws {
        let json = Data(#"""
        {"exposure": 1.0, "temperature": 0, "tint": 0, "contrast": 0, "highlights": 0,
         "shadows": 0, "whites": 0, "blacks": 0, "vibrance": 0, "saturation": 0,
         "advancedToneCurve": {}, "hsl": {}, "splitToning": {},
         "sharpening": {}, "noiseReduction": {}, "vignette": {}, "grain": {}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: json)
        XCTAssertEqual(decoded.exposure, 1.0)
        XCTAssertEqual(decoded.geometry, .neutral)
    }

    // MARK: - Per-channel tone curves (P3)

    func testRoundTripsAllFourToneCurveChannelsThroughJSON() throws {
        var original = PhotoAdjustments.neutral
        original.advancedToneCurve = AdvancedToneCurve(
            points: [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)],
            redPoints: [ToneCurvePoint(x: 0, y: 0.1), ToneCurvePoint(x: 1, y: 0.9)],
            greenPoints: [ToneCurvePoint(x: 0, y: 0.2), ToneCurvePoint(x: 1, y: 0.8)],
            bluePoints: [ToneCurvePoint(x: 0, y: 0.3), ToneCurvePoint(x: 1, y: 0.7)]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.isNeutral)
    }

    func testP2EraSidecarWithOnlyCompositeCurveKeyDecodesOtherChannelsAsIdentity() throws {
        // Exactly what every real sidecar written before P3 looks like: the
        // nested "advancedToneCurve" object only ever had a "points" key.
        let json = Data(#"""
        {"exposure": 0.5, "temperature": 0, "tint": 0, "contrast": 0, "highlights": 0,
         "shadows": 0, "whites": 0, "blacks": 0, "vibrance": 0, "saturation": 0,
         "advancedToneCurve": {"points": [{"x": 0, "y": 0}, {"x": 1, "y": 0.8}]},
         "hsl": {}, "splitToning": {}, "sharpening": {}, "noiseReduction": {},
         "vignette": {}, "grain": {}, "geometry": {}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: json)
        XCTAssertEqual(decoded.advancedToneCurve.points, [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 0.8)])
        XCTAssertTrue(decoded.advancedToneCurve.isIdentity(for: .red))
        XCTAssertTrue(decoded.advancedToneCurve.isIdentity(for: .green))
        XCTAssertTrue(decoded.advancedToneCurve.isIdentity(for: .blue))
    }

    func testRoundTripsNewFieldsThroughJSON() throws {
        var original = PhotoAdjustments.neutral
        original.sharpening = Sharpening(amount: 40)
        original.hsl.red = HSLBand(hue: 10, saturation: 20, luminance: -5)
        original.vignette = Vignette(amount: -30)
        original.geometry = GeometryAdjustments(rotationDegrees: 90, flipHorizontal: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Local adjustments (Phase 4 Task 4.1)

    func testNeutralHasNoLocalAdjustments() {
        XCTAssertTrue(PhotoAdjustments.neutral.localAdjustments.isEmpty)
    }

    /// Every sidecar on disk before this task has no "localAdjustments" key
    /// at all -- including one that already has every other Phase 1-3 key,
    /// matching `testPhase1SidecarWithoutGeometryKeyDecodesToNeutralGeometry`'s
    /// own realism bar.
    func testSidecarWithoutLocalAdjustmentsKeyDecodesToAnEmptyArray() throws {
        let json = Data(#"""
        {"exposure": 1.0, "temperature": 0, "tint": 0, "contrast": 0, "highlights": 0,
         "shadows": 0, "whites": 0, "blacks": 0, "vibrance": 0, "saturation": 0,
         "advancedToneCurve": {}, "hsl": {}, "splitToning": {},
         "sharpening": {}, "noiseReduction": {}, "vignette": {}, "grain": {}, "geometry": {}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: json)
        XCTAssertEqual(decoded.exposure, 1.0)
        XCTAssertTrue(decoded.localAdjustments.isEmpty)
    }

    func testMultipleLocalAdjustmentsRoundTripInOrder() throws {
        var original = PhotoAdjustments.neutral
        let gradient = LocalAdjustment(kind: .linearGradient, geometry: LocalAdjustmentGeometry(angleDegrees: 30))
        let heal = LocalAdjustment(kind: .spotHeal, geometry: LocalAdjustmentGeometry(x: 0.2, y: 0.2))
        let secondGradient = LocalAdjustment(kind: .linearGradient, isEnabled: false)
        original.localAdjustments = [gradient, heal, secondGradient]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: data)

        XCTAssertEqual(decoded.localAdjustments.map(\.id), [gradient.id, heal.id, secondGradient.id])
        XCTAssertEqual(decoded, original)
    }

    func testDisablingOneLocalAdjustmentDoesNotAffectTheOthers() {
        let first = LocalAdjustment(kind: .linearGradient)
        var second = LocalAdjustment(kind: .spotHeal)
        var adjustments = PhotoAdjustments.neutral
        adjustments.localAdjustments = [first, second]

        second.isEnabled = false
        adjustments.localAdjustments[1] = second

        XCTAssertTrue(adjustments.localAdjustments[0].isEnabled)
        XCTAssertFalse(adjustments.localAdjustments[1].isEnabled)
    }

    func testDeletingOneLocalAdjustmentLeavesTheRestInOrder() {
        let first = LocalAdjustment(kind: .linearGradient)
        let second = LocalAdjustment(kind: .spotHeal)
        let third = LocalAdjustment(kind: .linearGradient)
        var adjustments = PhotoAdjustments.neutral
        adjustments.localAdjustments = [first, second, third]

        adjustments.localAdjustments.removeAll { $0.id == second.id }

        XCTAssertEqual(adjustments.localAdjustments.map(\.id), [first.id, third.id])
    }

    func testNonEmptyLocalAdjustmentsMakeThePhotoNonNeutral() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.localAdjustments = [LocalAdjustment(kind: .linearGradient)]
        XCTAssertFalse(adjustments.isNeutral)
    }
}
