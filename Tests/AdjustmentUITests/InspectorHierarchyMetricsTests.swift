import Foundation
import XCTest
@testable import AdjustmentUI

final class InspectorHierarchyMetricsTests: XCTestCase {
    func testEveryNestedLevelHasACumulativeLeadingInset() {
        XCTAssertEqual(InspectorHierarchyMetrics.level1Inset, 0)
        XCTAssertGreaterThan(InspectorHierarchyMetrics.level2Inset, InspectorHierarchyMetrics.level1Inset)
        XCTAssertGreaterThan(InspectorHierarchyMetrics.level3Inset, InspectorHierarchyMetrics.level2Inset)
        XCTAssertEqual(
            InspectorHierarchyMetrics.level3Inset,
            InspectorHierarchyMetrics.level2Inset + InspectorHierarchyMetrics.level3RelativeInset
        )
    }

    func testLevel2ChevronIsVisuallySmallerThanTheSystemLevel1Disclosure() {
        XCTAssertLessThan(InspectorHierarchyMetrics.level2ChevronSize, 12)
    }

    /// Level 1's chevron is the largest of the three disclosure levels
    /// (spec §5.1: "Level 1 rows use the largest disclosure chevron").
    func testLevel1ChevronIsTheLargestDisclosureIndicator() {
        XCTAssertGreaterThan(InspectorHierarchyMetrics.level1ChevronSize, InspectorHierarchyMetrics.level2ChevronSize)
    }

    /// A 2026-09-14 user acceptance pass found that bumping `level2Inset`'s
    /// numeric value alone never produced a visible gap between the Level 1
    /// title text and its expanded content -- the Level 1 host's native
    /// `DisclosureGroup` silently absorbed the padding in real windowed
    /// rendering. `level1ContentLeadingInset` fixes this at the type level:
    /// it is *defined* as `level1TitleLeadingOffset + level2Inset`, so this
    /// test (unlike checking a bare literal) would fail if a future edit
    /// changed the computation to drop the relationship, even if the
    /// resulting literal value happened to still be a plausible-looking
    /// number.
    func testLevel1ContentLeadingInsetIsMeasuredFromTheTitleTextNotAnUnrelatedOrigin() {
        XCTAssertEqual(
            InspectorHierarchyMetrics.level1TitleLeadingOffset,
            InspectorHierarchyMetrics.level1ChevronColumnWidth + InspectorHierarchyMetrics.level1HeaderSpacing
        )
        XCTAssertEqual(
            InspectorHierarchyMetrics.level1ContentLeadingInset,
            InspectorHierarchyMetrics.level1TitleLeadingOffset + InspectorHierarchyMetrics.level2Inset
        )
        // The user-visible quantity: content text must land exactly
        // `level2Inset` to the right of where the title text itself starts.
        XCTAssertEqual(
            InspectorHierarchyMetrics.level1ContentLeadingInset - InspectorHierarchyMetrics.level1TitleLeadingOffset,
            InspectorHierarchyMetrics.level2Inset
        )
    }

    /// Header row height and the actions menu's own hit target (spec §5.1 /
    /// this session's acceptance pass: "at least 44 pt").
    func testLevel1MinRowHeightMeetsThePointerAndTouchTargetFloor() {
        XCTAssertGreaterThanOrEqual(InspectorHierarchyMetrics.level1MinRowHeight, 44)
    }

    func testLevel2RowsKeepAPlatformAppropriateFullRowHitTarget() throws {
        XCTAssertGreaterThanOrEqual(InspectorHierarchyMetrics.level2MinRowHeight, 32)
        let source = try Self.level2ComponentsSource()
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: ".frame(maxWidth: .infinity, minHeight: InspectorHierarchyMetrics.level2MinRowHeight, alignment: .leading)").count - 1,
            2,
            "Level 2 headings must reserve a full-width platform-sized hit row"
        )
    }

    func testDisclosureHeadersExposeExpandedStateToAssistiveTechnology() throws {
        let level1 = try Self.level1ComponentsSource()
        let level2 = try Self.level2ComponentsSource()
        for source in [level1, level2] {
            XCTAssertTrue(source.contains("accessibilityValue(Text(L10n.t(isExpanded ? \"Expanded\" : \"Collapsed\")))"))
            XCTAssertTrue(source.contains("accessibilityAddTraits(.isHeader)"))
        }
    }

    /// User acceptance preference: Level 1 titles should be 18pt so they
    /// remain the strongest navigation signal in the inspector.
    func testLevel1MacTitleBaseSizeUsesTheEighteenPointHierarchyLevel() {
        XCTAssertEqual(InspectorHierarchyMetrics.level1MacTitleBaseSize, 18)
    }

    /// User acceptance preference: Level 2 subsection titles should be 16pt,
    /// clearly below Level 1 but above ordinary field labels.
    func testLevel2MacTitleBaseSizeUsesTheSixteenPointHierarchyLevel() throws {
        let source = try Self.level2ComponentsSource()
        XCTAssertTrue(
            source.contains("level2TitleBaseSize: CGFloat = 16"),
            "Level 2 headers must define and use the shared 16pt hierarchy metric"
        )
        XCTAssertLessThan(16, InspectorHierarchyMetrics.level1MacTitleBaseSize)
    }

    /// Collapsed-summary caption: "12-13pt" per this session's requirement,
    /// and it must stay visually secondary to (smaller than) the title.
    func testLevel1MacSummaryBaseSizeIsReadableButSecondaryToTheTitle() {
        XCTAssertGreaterThanOrEqual(InspectorHierarchyMetrics.level1MacSummaryBaseSize, 12)
        XCTAssertLessThanOrEqual(InspectorHierarchyMetrics.level1MacSummaryBaseSize, 13)
        XCTAssertLessThan(InspectorHierarchyMetrics.level1MacSummaryBaseSize, InspectorHierarchyMetrics.level1MacTitleBaseSize)
    }

    func testSharedHierarchyMetricsApplyToBothPlatforms() {
        XCTAssertEqual(InspectorHierarchyMetrics.level1TitleBaseSize, 18)
        XCTAssertEqual(InspectorHierarchyMetrics.level2TitleBaseSize, 16)
        XCTAssertEqual(InspectorHierarchyMetrics.level1SummaryBaseSize, 13)
    }

    func testLevel1HeaderKeepsAReadableGapBetweenDisclosureAndTitle() {
        XCTAssertGreaterThanOrEqual(InspectorHierarchyMetrics.level1HeaderSpacing, 12)
    }

    func testIPadInspectorStartsWithOnlyBasicExpanded() {
        XCTAssertEqual(InspectorSectionExpansionPolicy.initialExpanded, [.basic])
    }

    func testIPadInspectorExpansionTogglesOnlyTheSelectedSection() {
        let expanded = InspectorSectionExpansionPolicy.toggled(.hsl, in: [.basic])
        XCTAssertEqual(expanded, [.basic, .hsl])
        XCTAssertEqual(InspectorSectionExpansionPolicy.toggled(.hsl, in: expanded), [.basic])
    }

    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // InspectorHierarchyMetricsTests.swift
            .deletingLastPathComponent() // AdjustmentUITests
            .deletingLastPathComponent() // Tests
    }()

    private static func level2ComponentsSource() throws -> String {
        try String(
            contentsOf: repositoryRootURL
                .appendingPathComponent("Sources/AdjustmentUI/Level2DisclosureGroup.swift"),
            encoding: .utf8
        )
    }

    private static func level1ComponentsSource() throws -> String {
        try String(
            contentsOf: repositoryRootURL
                .appendingPathComponent("Sources/AdjustmentUI/InspectorLevel1DisclosureGroup.swift"),
            encoding: .utf8
        )
    }

    /// `InspectorView.inspectorGroup` (the Level 1 host) applies
    /// `level2Inset` exactly once, to its whole expanded-content container
    /// (see `InspectorSharedCatalogContractTests
    /// .testLevel1ExpandedContentIsIndentedRelativeToItsOwnHeader`). If
    /// `Level2Section`/`Level2DisclosureGroup` also applied `level2Inset` to
    /// themselves, every Level 2 header nested inside a Level 1 group (White
    /// Balance, HSL, Sharpening, ...) would double-indent to 32pt instead of
    /// the spec's 12-16pt cumulative range. Only the Level 3 *relative* step
    /// belongs here.
    func testLevel2ComponentsDoNotReapplyTheLevel1HostsLeadingInset() throws {
        let source = try Self.level2ComponentsSource()

        XCTAssertFalse(
            source.contains(".padding(.leading, InspectorHierarchyMetrics.level2Inset)"),
            "Level2Section/Level2DisclosureGroup must not re-apply level2Inset -- their Level 1 host already applies it once"
        )
        XCTAssertTrue(
            source.contains(".padding(.leading, InspectorHierarchyMetrics.level3RelativeInset)"),
            "Level 3 content must still add the relative step beyond whatever inset its ancestors already applied"
        )
    }
}
