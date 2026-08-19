import XCTest
@testable import RawProcessingCore

final class GrainTests: XCTestCase {
    func testNeutralIsIdentity() {
        let neutral = Grain.neutral
        XCTAssertEqual(neutral.amount, 0)
        XCTAssertEqual(neutral.size, 25)
        XCTAssertEqual(neutral.roughness, 50)
        XCTAssertTrue(neutral.isIdentity)
    }

    func testOnlyAmountDeterminesIdentity() {
        XCTAssertTrue(Grain(amount: 0, size: 90, roughness: 90).isIdentity)
        XCTAssertFalse(Grain(amount: 1).isIdentity)
    }

    func testClampsToZeroTo100() {
        let g = Grain(amount: 500, size: -5, roughness: 500)
        XCTAssertEqual(g.amount, 100)
        XCTAssertEqual(g.size, 0)
        XCTAssertEqual(g.roughness, 100)
    }

    func testRoundTripsThroughJSON() throws {
        let original = Grain(amount: 30, size: 40, roughness: 60)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(Grain.self, from: data), original)
    }

    func testMissingKeysFallBackToNeutral() throws {
        XCTAssertEqual(try JSONDecoder().decode(Grain.self, from: Data("{}".utf8)), .neutral)
    }
}
