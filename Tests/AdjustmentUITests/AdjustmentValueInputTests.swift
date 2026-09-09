import XCTest
@testable import AdjustmentUI

final class AdjustmentValueInputTests: XCTestCase {
    func testClampRejectsNonFiniteAndBoundsValues() {
        XCTAssertEqual(PadAdjustmentPolicy.clamp(12, to: -1...1), 1)
        XCTAssertEqual(PadAdjustmentPolicy.clamp(-12, to: -1...1), -1)
        XCTAssertEqual(PadAdjustmentPolicy.clamp(.infinity, to: -1...1), -1)
        XCTAssertEqual(PadAdjustmentPolicy.clamp(.nan, to: -1...1), -1)
    }

    func testParseAcceptsCommaDecimalAndRoundsToFieldPrecision() {
        XCTAssertEqual(PadAdjustmentPolicy.parse(" 1,236 ", range: -10...10, fractionDigits: 2), 1.24)
        XCTAssertEqual(PadAdjustmentPolicy.parse("-2.4", range: -10...10, fractionDigits: 0), -2)
    }

    func testParseClampsValuesAndRejectsInvalidText() {
        XCTAssertEqual(PadAdjustmentPolicy.parse("99", range: -1...1, fractionDigits: 1), 1)
        XCTAssertNil(PadAdjustmentPolicy.parse("not a number", range: -1...1, fractionDigits: 1))
        XCTAssertNil(PadAdjustmentPolicy.parse("", range: -1...1, fractionDigits: 1))
    }

    func testFormattedUsesStableDecimalPlaces() {
        XCTAssertEqual(PadAdjustmentPolicy.formatted(1.2, fractionDigits: 2), "1.20")
        XCTAssertEqual(PadAdjustmentPolicy.formatted(-0.25, fractionDigits: 1), "-0.2")
    }
}
