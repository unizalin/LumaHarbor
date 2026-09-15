import XCTest
@testable import AdjustmentUI

/// Inspector hierarchy/typography spec (2026-09-14) §5.4: rows switch
/// composition at a fixed width threshold instead of continuously scaling
/// type. Pure model, independent of any SwiftUI measurement.
final class AdaptiveRowLayoutTests: XCTestCase {
    func testWidthAtOrAboveThresholdUsesInlineComposition() {
        XCTAssertEqual(AdaptiveRowLayout.composition(forAvailableWidth: 340), .inline)
        XCTAssertEqual(AdaptiveRowLayout.composition(forAvailableWidth: 440), .inline)
        XCTAssertEqual(AdaptiveRowLayout.composition(forAvailableWidth: 1000), .inline)
    }

    func testWidthBelowThresholdUsesStackedComposition() {
        XCTAssertEqual(AdaptiveRowLayout.composition(forAvailableWidth: 339.9), .stacked)
        XCTAssertEqual(AdaptiveRowLayout.composition(forAvailableWidth: 300), .stacked)
        XCTAssertEqual(AdaptiveRowLayout.composition(forAvailableWidth: 0), .stacked)
    }

    func testThresholdIsExactly340Points() {
        XCTAssertEqual(AdaptiveRowLayout.stackedWidthThreshold, 340)
    }
}
