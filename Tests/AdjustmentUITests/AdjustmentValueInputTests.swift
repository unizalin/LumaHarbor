import Foundation
import XCTest
@testable import AdjustmentUI

final class AdjustmentValueInputTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AdjustmentUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
    }()

    private static func loadSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRootURL.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

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

    func testNumericInputKeepsFineAdjustmentButtonsVisible() throws {
        let source = try Self.loadSource("Sources/AdjustmentUI/AdjustmentValueInput.swift")

        XCTAssertTrue(source.contains("systemName: \"minus\""), "each numeric field needs a visible decrease button")
        XCTAssertTrue(source.contains("systemName: \"plus\""), "each numeric field needs a visible increase button")
        XCTAssertTrue(source.contains("step: Double = 0.1"), "fine controls need an explicit step size")
        XCTAssertTrue(source.contains("accessibilityKey: \"Increase\""))
        XCTAssertTrue(source.contains("accessibilityKey: \"Decrease\""))
    }

    func testNudgePolicyIsDefinedForButtonActions() throws {
        let source = try Self.loadSource("Sources/AdjustmentUI/PadAdjustmentPolicy.swift")
        XCTAssertTrue(source.contains("public static func adjusted("), "button actions must use the shared clamp and rounding policy")
        XCTAssertTrue(source.contains("Avoid exposing a signed zero"), "nudge results should not expose signed zero")
    }

    func testAdjustedNudgeUsesDisplayPrecisionAndClampsToRange() {
        XCTAssertEqual(
            PadAdjustmentPolicy.adjusted(1.2, by: 0.1, range: -5...5, fractionDigits: 1),
            1.3
        )
        XCTAssertEqual(
            PadAdjustmentPolicy.adjusted(5, by: 0.1, range: -5...5, fractionDigits: 1),
            5
        )
        XCTAssertEqual(
            PadAdjustmentPolicy.adjusted(0.05, by: -0.1, range: -5...5, fractionDigits: 1),
            -0.1
        )
    }
}
