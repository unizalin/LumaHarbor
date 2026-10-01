import Foundation
import SwiftUI
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

    func testParseRejectsOutOfRangeValuesAndInvalidText() {
        XCTAssertNil(PadAdjustmentPolicy.parse("99", range: -1...1, fractionDigits: 1))
        XCTAssertNil(PadAdjustmentPolicy.parse("not a number", range: -1...1, fractionDigits: 1))
        XCTAssertNil(PadAdjustmentPolicy.parse("", range: -1...1, fractionDigits: 1))
    }

    func testParseExactPreservesAValidValueBeyondDisplayPrecision() {
        XCTAssertEqual(
            PadAdjustmentPolicy.parseExact("4536.72802734375", range: 2_000...50_000) ?? 0,
            4536.72802734375,
            accuracy: 0.0000001
        )
    }

    func testFormattedUsesStableDecimalPlaces() {
        XCTAssertEqual(PadAdjustmentPolicy.formatted(1.2, fractionDigits: 2), "1.20")
        XCTAssertEqual(PadAdjustmentPolicy.formatted(-0.25, fractionDigits: 1), "-0.2")
    }

    func testNumericInputKeepsFineAdjustmentButtonsVisibleOnTouchPlatforms() throws {
        let source = try Self.loadSource("Sources/AdjustmentUI/AdjustmentValueInput.swift")

        XCTAssertTrue(source.contains("systemName: \"minus\""), "each numeric field needs a visible decrease button")
        XCTAssertTrue(source.contains("systemName: \"plus\""), "each numeric field needs a visible increase button")
        XCTAssertTrue(source.contains("#if os(iOS)"), "visible nudge buttons are a touch-platform affordance")
        XCTAssertTrue(source.contains("step: Double = 0.1"), "fine controls need an explicit step size")
        XCTAssertTrue(source.contains("accessibilityKey: \"Increase\""))
        XCTAssertTrue(source.contains("accessibilityKey: \"Decrease\""))
    }

    func testMacNumericInputHidesPermanentNudgesAndExposesAnAccessibleAdjustmentAction() throws {
        let source = try Self.loadSource("Sources/AdjustmentUI/AdjustmentValueInput.swift")

        XCTAssertTrue(source.contains(".accessibilityAdjustableAction"), "macOS needs an accessible increment/decrement path when the buttons are hidden")
        XCTAssertTrue(source.contains("case .increment"))
        XCTAssertTrue(source.contains("case .decrement"))
        XCTAssertTrue(source.contains("#if os(macOS)"), "the compact Mac control must be distinct from the iPad touch layout")
    }

    @MainActor
    func testExternalAuthoritativeUpdatesReplaceAnActiveDraftWithoutIgnoringTheBinding() {
        var value = 6500.0
        var writes = 0
        let controller = AdjustmentInputController(value: Binding(get: { value }, set: { value = $0; writes += 1 }),
            range: 2000...50000, fractionDigits: 0, identity: "photo", revision: 0, unit: "K")
        controller.focus()
        controller.edit("7000")
        value = 5500
        controller.submit()
        XCTAssertEqual(value, 5500)
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(controller.state.draft, "5500")
        XCTAssertFalse(controller.state.isEditing)
    }

    @MainActor
    func testNumericInputHasAOneShotCommitAndEscapeCancellationPath() {
        var value = 6500.0
        var writes: [Double] = []
        let controller = AdjustmentInputController(value: Binding(get: { value }, set: { value = $0; writes.append($0) }),
            range: 2000...50000, fractionDigits: 0, identity: "photo", revision: 0, unit: "K")
        controller.focus()
        controller.edit("7000.125")
        controller.submit()
        controller.submit()
        XCTAssertEqual(writes, [7000.125])
        controller.focus()
        controller.edit("8000")
        controller.cancel()
        controller.submit()
        XCTAssertEqual(value, 7000.125)
        XCTAssertEqual(writes.count, 1)
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
