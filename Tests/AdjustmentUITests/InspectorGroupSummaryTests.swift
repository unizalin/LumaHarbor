import XCTest
@testable import AdjustmentUI
import RawProcessingCore

/// Inspector hierarchy/typography spec (2026-09-14) §5.1: every collapsed
/// top-level group shows a neutral or localized-count modified summary.
/// Pure function over `PhotoAdjustments` -- no `EditorSession` involved, so
/// this is fully testable without an open photo.
final class InspectorGroupSummaryTests: XCTestCase {
    func testNeutralAdjustmentsReportNotAdjustedForEverySection() {
        for section in InspectorSectionID.allCases {
            XCTAssertEqual(
                InspectorGroupSummary.summary(for: section, in: .neutral),
                .notAdjusted,
                "\(section) must report .notAdjusted for neutral adjustments"
            )
        }
    }

    func testBasicSectionCountsOnlyItsOwnModifiedFields() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.exposure = 1.0
        adjustments.contrast = 20

        XCTAssertEqual(InspectorGroupSummary.summary(for: .basic, in: adjustments), .adjusted(count: 2))
        XCTAssertEqual(InspectorGroupSummary.summary(for: .whiteBalance, in: adjustments), .notAdjusted)
    }

    func testWhiteBalanceSectionCountsTemperatureAndTint() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.temperature = 500

        XCTAssertEqual(InspectorGroupSummary.summary(for: .whiteBalance, in: adjustments), .adjusted(count: 1))
    }

    func testHSLSectionCountsIndividualBandFields() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.hsl.red.hue = 10
        adjustments.hsl.red.saturation = 20
        adjustments.hsl.blue.luminance = -5

        XCTAssertEqual(InspectorGroupSummary.summary(for: .hsl, in: adjustments), .adjusted(count: 3))
    }

    func testPresenceSectionCountsEachNonZeroField() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.presence.texture = 15

        XCTAssertEqual(InspectorGroupSummary.summary(for: .presence, in: adjustments), .adjusted(count: 1))
    }

    /// Sections without a cheap per-field breakdown (Curve, Geometry, Local
    /// Adjustments) still correctly report "modified", just as a coarse
    /// count of 1 rather than an exact per-control tally.
    func testSectionsWithoutAPerFieldBreakdownStillReportModified() {
        var adjustments = PhotoAdjustments.neutral
        adjustments.geometry.rotationDegrees = 90

        XCTAssertEqual(InspectorGroupSummary.summary(for: .geometry, in: adjustments), .adjusted(count: 1))
    }

    /// Locale-independent: only proves the modified summary actually
    /// interpolates the count and the format placeholder is never left
    /// unresolved, without asserting a specific resolved-language string
    /// (which depends on the test host's locale resolution).
    func testModifiedSummaryInterpolatesTheCount() {
        let text = InspectorGroupSummary.adjusted(count: 3).localizedText
        XCTAssertTrue(text.contains("3"), "the modified summary must interpolate the field count: \(text)")
        XCTAssertFalse(text.contains("%d"), "the format placeholder must be resolved, not left literal: \(text)")
    }

    func testNeutralAndModifiedSummariesAreDistinctText() {
        XCTAssertNotEqual(InspectorGroupSummary.notAdjusted.localizedText, InspectorGroupSummary.adjusted(count: 1).localizedText)
    }
}
