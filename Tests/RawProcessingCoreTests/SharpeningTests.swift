import XCTest
@testable import RawProcessingCore

final class SharpeningTests: XCTestCase {
    func testDefaultsMatchLightroomConventionAndAreIdentity() {
        let neutral = Sharpening.neutral
        XCTAssertEqual(neutral.amount, 0)
        XCTAssertEqual(neutral.radius, 1.0)
        XCTAssertEqual(neutral.detail, 25)
        XCTAssertEqual(neutral.masking, 0)
        XCTAssertTrue(neutral.isIdentity)
    }

    func testOnlyAmountDeterminesIdentity() {
        // detail/masking away from default must NOT break identity on their own.
        XCTAssertTrue(Sharpening(amount: 0, detail: 80, masking: 50).isIdentity)
        XCTAssertFalse(Sharpening(amount: 1).isIdentity)
    }

    func testClampsToDocumentedRanges() {
        let s = Sharpening(amount: 999, radius: 10, detail: -5, masking: 500)
        XCTAssertEqual(s.amount, 150)
        XCTAssertEqual(s.radius, 3.0)
        XCTAssertEqual(s.detail, 0)
        XCTAssertEqual(s.masking, 100)
        XCTAssertEqual(Sharpening(radius: 0).radius, 0.5)
    }

    func testRoundTripsThroughJSON() throws {
        let original = Sharpening(amount: 60, radius: 1.5, detail: 40, masking: 20)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Sharpening.self, from: data), original)
    }

    func testMissingKeysFallBackToNeutral() throws {
        XCTAssertEqual(try JSONDecoder().decode(Sharpening.self, from: Data("{}".utf8)), .neutral)
    }
}
