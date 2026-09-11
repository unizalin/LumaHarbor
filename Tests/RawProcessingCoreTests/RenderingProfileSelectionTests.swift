import XCTest
@testable import RawProcessingCore

final class RenderingProfileSelectionTests: XCTestCase {
    func testNeutralIsIdentity() {
        let neutral = RenderingProfileSelection.neutral
        XCTAssertNil(neutral.profileID)
        XCTAssertEqual(neutral.amount, 100)
        XCTAssertNil(neutral.fallbackReason)
        XCTAssertTrue(neutral.isIdentity)
    }

    func testAnyProfileIDBreaksIdentityRegardlessOfAmount() {
        XCTAssertFalse(RenderingProfileSelection(profileID: "lumaharbor.vivid", amount: 0).isIdentity)
    }

    func testAmountClampsToZeroToOneHundred() {
        var selection = RenderingProfileSelection(profileID: "lumaharbor.vivid", amount: 999)
        XCTAssertEqual(selection.amount, 100)
        selection = RenderingProfileSelection(profileID: "lumaharbor.vivid", amount: -999)
        XCTAssertEqual(selection.amount, 0)
    }

    func testRoundTripsThroughJSON() throws {
        let original = RenderingProfileSelection(profileID: "lumaharbor.flat", amount: 60, fallbackReason: nil)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(RenderingProfileSelection.self, from: data), original)
    }

    func testMissingKeysFallBackToNeutral() throws {
        XCTAssertEqual(try JSONDecoder().decode(RenderingProfileSelection.self, from: Data("{}".utf8)), .neutral)
    }
}

final class RenderingProfileCatalogTests: XCTestCase {
    func testAllFourBuiltInProfilesExist() {
        XCTAssertEqual(
            Set(RenderingProfileCatalog.allProfileIDs),
            ["lumaharbor.standard", "lumaharbor.vivid", "lumaharbor.flat", "lumaharbor.portrait"]
        )
    }

    func testStandardProfileHasNoCoefficients() {
        let coefficients = try? XCTUnwrap(RenderingProfileCatalog.coefficients(for: "lumaharbor.standard"))
        XCTAssertEqual(coefficients?.saturationDelta, 0)
        XCTAssertEqual(coefficients?.contrastDelta, 0)
    }

    func testVividProfileIncreasesSaturationAndContrast() throws {
        let coefficients = try XCTUnwrap(RenderingProfileCatalog.coefficients(for: "lumaharbor.vivid"))
        XCTAssertGreaterThan(coefficients.saturationDelta, 0)
        XCTAssertGreaterThan(coefficients.contrastDelta, 0)
    }

    func testFlatProfileReducesContrastAndLiftsShadows() throws {
        let coefficients = try XCTUnwrap(RenderingProfileCatalog.coefficients(for: "lumaharbor.flat"))
        XCTAssertLessThan(coefficients.contrastDelta, 0)
        XCTAssertGreaterThan(coefficients.shadowsDelta, 0)
        XCTAssertLessThan(coefficients.highlightsDelta, 0)
    }

    func testUnknownProfileIDReturnsNil() {
        XCTAssertNil(RenderingProfileCatalog.coefficients(for: "not-a-real-profile"))
    }
}
