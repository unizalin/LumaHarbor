import XCTest
@testable import RawProcessingCore

final class VignetteTests: XCTestCase {
    func testNeutralIsIdentity() {
        let neutral = Vignette.neutral
        XCTAssertEqual(neutral.amount, 0)
        XCTAssertEqual(neutral.midpoint, 50)
        XCTAssertEqual(neutral.roundness, 0)
        XCTAssertEqual(neutral.feather, 50)
        XCTAssertTrue(neutral.isIdentity)
    }

    func testOnlyAmountDeterminesIdentity() {
        XCTAssertTrue(Vignette(amount: 0, midpoint: 90, roundness: 80, feather: 10).isIdentity)
        XCTAssertFalse(Vignette(amount: 1).isIdentity)
        XCTAssertFalse(Vignette(amount: -1).isIdentity)
    }

    func testClampsToDocumentedRanges() {
        let v = Vignette(amount: 999, midpoint: -5, roundness: -999, feather: 999)
        XCTAssertEqual(v.amount, 100)
        XCTAssertEqual(v.midpoint, 0)
        XCTAssertEqual(v.roundness, -100)
        XCTAssertEqual(v.feather, 100)
        XCTAssertEqual(Vignette(amount: -999).amount, -100)
    }

    func testRoundTripsThroughJSON() throws {
        let original = Vignette(amount: -40, midpoint: 60, roundness: 20, feather: 70)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Vignette.self, from: data), original)
    }

    func testMissingKeysFallBackToNeutral() throws {
        XCTAssertEqual(try JSONDecoder().decode(Vignette.self, from: Data("{}".utf8)), .neutral)
    }
}
