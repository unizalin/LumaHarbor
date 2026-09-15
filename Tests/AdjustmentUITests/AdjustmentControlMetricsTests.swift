import XCTest
@testable import AdjustmentUI

/// Inspector hierarchy/typography spec (2026-09-14) §5.4's platform metrics
/// table. These tests run on the macOS host, so they pin the macOS branch of
/// each constant; the iOS branch is exercised by the iPad Simulator
/// `xcodebuild` used elsewhere in this repo's verification, not by
/// `swift test` on macOS.
final class AdjustmentControlMetricsTests: XCTestCase {
    func testMacOSNudgeHitTargetIsWithinTheSpecifiedRange() {
        XCTAssertTrue((28...32).contains(AdjustmentControlMetrics.nudgeHitTarget), "macOS nudge/reset hit target must be 28-32pt")
    }

    func testMacOSNumericFieldWidthIsWithinTheSpecifiedRange() {
        XCTAssertTrue((64...72).contains(AdjustmentControlMetrics.numericFieldWidth), "macOS numeric field width must be 64-72pt")
    }

    func testMacOSRowVerticalGapIsWithinTheSpecifiedRange() {
        XCTAssertTrue((6...8).contains(AdjustmentControlMetrics.rowVerticalGap), "macOS row vertical gap must be 6-8pt")
    }

    func testMacOSDoesNotReserveTheIPadMinimumHitTarget() {
        XCTAssertLessThan(AdjustmentControlMetrics.nudgeHitTarget, 44, "macOS pointer controls must not reserve the iPad-sized 44pt frame")
    }

    func testMacOSActionHeightStaysCompact() {
        XCTAssertEqual(AdjustmentControlMetrics.actionMinimumHeight, 36)
    }
}
