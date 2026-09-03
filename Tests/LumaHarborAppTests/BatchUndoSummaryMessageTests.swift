import XCTest
@testable import LumaHarborApp
@testable import PhotoLibraryCore

/// Phase 3 Task 3.4: "Add localized report copy: affected N, failed M,
/// skipped K." -- `LibraryViewModel.batchUndoSummaryMessage(_:)` turns a
/// `BatchAdjustmentSyncService.BatchUndoSummary` into that copy, following
/// the same additive-parts convention `PresetBrowserView.restoreSummaryMessage`
/// already established for `PresetRestoreSummary` (skip a count that's
/// zero, join the rest in order).
///
/// These assertions are deliberately locale-agnostic (numbers and ordering
/// only, never the translated words themselves) -- `L10n.bundle` is a
/// `static let` resolved once from the real system language the first time
/// any test in this process calls `L10n.t` (see `Sources/Localization/
/// L10n.swift`'s own doc comment), so a unit test asserting exact English
/// copy would be flaky on a machine (or CI) whose system language isn't
/// English. `LocalizationSmokeTest` is what actually pins a language via
/// `L10n.resolveBundle(preferences:)` and belongs there instead.
final class BatchUndoSummaryMessageTests: XCTestCase {
    func testFullSuccessReportsOnlyTheAffectedCountWithNoSeparator() {
        var summary = BatchAdjustmentSyncService.BatchUndoSummary()
        summary.affected = 3

        let message = LibraryViewModel.batchUndoSummaryMessage(summary)

        XCTAssertTrue(message.contains("3"), "the affected count must appear")
        XCTAssertFalse(message.contains(","), "a single reported count must not be joined with a separator")
    }

    func testAZeroCountIsOmittedEntirely() {
        var summary = BatchAdjustmentSyncService.BatchUndoSummary()
        summary.affected = 2
        summary.skipped = 1
        // summary.failed stays 0.

        let message = LibraryViewModel.batchUndoSummaryMessage(summary)

        XCTAssertTrue(message.contains("2"))
        XCTAssertTrue(message.contains("1"))
        XCTAssertFalse(message.contains("0"), "the zero `failed` count must be omitted, not reported as \"0 failed\"")
    }

    /// Distinct digits (5/6/7), never 0 or 1, so each substring search can
    /// only match its own count.
    func testAffectedIsReportedBeforeFailedAndSkippedWhenAllThreeAreNonZero() throws {
        var summary = BatchAdjustmentSyncService.BatchUndoSummary()
        summary.affected = 5
        summary.failed = 6
        summary.skipped = 7

        let message = LibraryViewModel.batchUndoSummaryMessage(summary)

        let affectedRange = try XCTUnwrap(message.range(of: "5"))
        let failedRange = try XCTUnwrap(message.range(of: "6"))
        let skippedRange = try XCTUnwrap(message.range(of: "7"))
        XCTAssertTrue(affectedRange.lowerBound < failedRange.lowerBound, "affected must be reported before failed")
        XCTAssertTrue(failedRange.lowerBound < skippedRange.lowerBound, "failed must be reported before skipped")
    }

    func testAllZeroReportsANonEmptyFallbackRatherThanThreeZeroCounts() {
        let summary = BatchAdjustmentSyncService.BatchUndoSummary()

        let message = LibraryViewModel.batchUndoSummaryMessage(summary)

        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains("0"), "must not read as \"0 reverted, 0 failed, 0 skipped\"")
    }
}
