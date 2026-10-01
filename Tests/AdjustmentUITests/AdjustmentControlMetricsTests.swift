import Foundation
import XCTest

final class AdjustmentControlMetricsTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private static func source() throws -> String {
        try String(
            contentsOf: Self.repositoryRootURL
                .appendingPathComponent("Sources/AdjustmentUI/AdjustmentControlMetrics.swift"),
            encoding: .utf8
        )
    }

    func testControlMetricsKeepTouchTargetsLargerThanVisualGlyphs() throws {
        let source = try Self.source()
        XCTAssertTrue(source.contains("nudgeHitTarget"))
        XCTAssertTrue(source.contains("nudgeVisualDiameter"))
        XCTAssertTrue(source.contains("resetHitTarget"))
        XCTAssertTrue(source.contains("resetVisualDiameter"))
    }

    func testNumericFieldHasAPlatformAwareWidth() throws {
        let source = try Self.source()
        XCTAssertTrue(source.contains("numericFieldWidth"))
        XCTAssertTrue(source.contains("#if os(macOS)"))
        XCTAssertTrue(source.contains("#else"))
    }

    func testSharedSliderRowUsesACompactSingleLineLayoutOnMac() throws {
        let source = try String(
            contentsOf: Self.repositoryRootURL
                .appendingPathComponent("Sources/AdjustmentUI/AdjustmentSliderRow.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("#if os(macOS)"))
        XCTAssertTrue(
            source.contains("Slider(") && source.contains("AdjustmentValueInput"),
            "the Mac row must keep the slider and numeric value in one horizontal control row"
        )
        XCTAssertTrue(source.contains("compactRow"))
    }
}
