import XCTest
@testable import RawProcessingCore

final class LensCorrectionAdjustmentsTests: XCTestCase {
    func testNeutralIsOffAndIdentity() {
        let neutral = LensCorrectionAdjustments.neutral
        XCTAssertEqual(neutral.mode, .off)
        XCTAssertNil(neutral.profileID)
        XCTAssertEqual(neutral.distortionAmount, 0)
        XCTAssertEqual(neutral.vignettingAmount, 0)
        XCTAssertEqual(neutral.tcaAmount, 0)
        XCTAssertTrue(neutral.isIdentity)
    }

    func testIdentityIsDeterminedOnlyByMode() {
        // Switching mode to automatic with all amounts still at zero must not
        // read as identity -- automatic delegates correction to the decoder,
        // which is a real, non-neutral behaviour change.
        var automatic = LensCorrectionAdjustments.neutral
        automatic.mode = .automatic
        XCTAssertFalse(automatic.isIdentity)

        var manualButZero = LensCorrectionAdjustments.neutral
        manualButZero.mode = .manual
        XCTAssertFalse(manualButZero.isIdentity, "Selecting manual mode is itself a non-neutral choice, even before dialing in amounts")
    }

    func testClampsAmountsToDocumentedRanges() {
        var lens = LensCorrectionAdjustments(mode: .manual, distortionAmount: 999, vignettingAmount: -999, tcaAmount: 999)
        XCTAssertEqual(lens.distortionAmount, 100)
        XCTAssertEqual(lens.vignettingAmount, -100)
        XCTAssertEqual(lens.tcaAmount, 100)
        lens.tcaAmount = -999
        XCTAssertEqual(lens.tcaAmount, -100)
    }

    func testRoundTripsThroughJSON() throws {
        let original = LensCorrectionAdjustments(
            mode: .bundledProfile, profileID: "sony.fe-24-70mm-f28-gm",
            distortionAmount: 40, vignettingAmount: -20, tcaAmount: 10
        )
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(LensCorrectionAdjustments.self, from: data), original)
    }

    func testMissingKeysFallBackToNeutral() throws {
        XCTAssertEqual(try JSONDecoder().decode(LensCorrectionAdjustments.self, from: Data("{}".utf8)), .neutral)
    }

    // MARK: - Decoder instruction (P4: which CIRAWFilter setting each mode implies)

    func testAutomaticModeEnablesDecoderLensCorrectionIfSupported() {
        var lens = LensCorrectionAdjustments.neutral
        lens.mode = .automatic
        XCTAssertEqual(lens.decoderShouldEnableLensCorrection, true)
    }

    func testOffModeExplicitlyDisablesDecoderLensCorrection() {
        XCTAssertEqual(LensCorrectionAdjustments.neutral.decoderShouldEnableLensCorrection, false)
    }

    func testManualModeExplicitlyDisablesDecoderLensCorrection() {
        var lens = LensCorrectionAdjustments.neutral
        lens.mode = .manual
        XCTAssertEqual(lens.decoderShouldEnableLensCorrection, false)
    }

    func testBundledProfileModeExplicitlyDisablesDecoderLensCorrection() {
        var lens = LensCorrectionAdjustments.neutral
        lens.mode = .bundledProfile
        XCTAssertEqual(lens.decoderShouldEnableLensCorrection, false)
    }

    func testUnknownModeStringFailsClosedToOffRatherThanCrashing() throws {
        // A future app version's new mode, or a hand-edited sidecar, must
        // degrade safely rather than fail to decode the whole photo.
        let json = Data(#"{"mode": "some-future-mode"}"#.utf8)
        let decoded = try JSONDecoder().decode(LensCorrectionAdjustments.self, from: json)
        XCTAssertEqual(decoded.mode, .off)
    }
}

final class LensProfileDatabaseTests: XCTestCase {
    func testMatchAlwaysReturnsNilWithTheEmptyBundledDatabase() {
        // P4 ships the matching engine with zero bundled profiles (spec §1
        // item 1) -- a real Lensfun-derived database is a future, separately
        // authorised data-import task. This test locks in the safe-fallback
        // contract that future task must not break: no match ever means "no
        // matching profile", never a guess.
        let result = LensProfileDatabase.match(
            cameraMake: "Sony", cameraModel: "ILCE-7RM4",
            lensModel: "FE 24-70mm F2.8 GM", focalLengthMM: 35, aperture: 4.0
        )
        XCTAssertNil(result)
    }
}
