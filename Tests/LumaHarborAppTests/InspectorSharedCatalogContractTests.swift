import Foundation
import XCTest

/// P2 (`2026-09-10-shared-professional-inspector-catalog.md` §5): proves Mac's
/// `InspectorView` actually wires up the shared `InspectorCatalog`/
/// `InspectorNavigationModel` -- search, favorites, pin, smart follow, and
/// section/domain reset -- rather than these types existing unused in
/// `AdjustmentUI`. Same source-parsing approach as the sibling
/// `InspectorAdjustmentGroupsContractTests` (no SwiftUI view-inspection
/// dependency in this package).
final class InspectorSharedCatalogContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // InspectorSharedCatalogContractTests.swift
            .deletingLastPathComponent() // LumaHarborAppTests
            .deletingLastPathComponent() // Tests
    }()

    private static func inspectorSource() throws -> String {
        try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent("Sources/LumaHarborApp/Views/InspectorView.swift"),
            encoding: .utf8
        )
    }

    func testInspectorViewOwnsTheSharedNavigationModel() throws {
        let source = try Self.inspectorSource()
        XCTAssertTrue(source.contains("InspectorNavigationModel()"),
                      "InspectorView must attach the shared navigation model, not a Mac-only reimplementation")
    }

    func testInspectorViewExposesASearchFieldBoundToTheSharedModel() throws {
        let source = try Self.inspectorSource()
        XCTAssertTrue(source.contains("navigation.searchQuery"))
        XCTAssertTrue(source.contains("L10n.t(\"Search Adjustments\")"))
    }

    func testInspectorViewExposesFavoriteTogglesThroughTheSharedModel() throws {
        let source = try Self.inspectorSource()
        XCTAssertTrue(source.contains("navigation.toggleFavorite"))
        XCTAssertTrue(source.contains("navigation.isFavorite"))
    }

    func testInspectorViewExposesAPinToggle() throws {
        let source = try Self.inspectorSource()
        XCTAssertTrue(source.contains("navigation.togglePin()"))
        XCTAssertTrue(source.contains("navigation.isPinned"))
    }

    func testInspectorViewFollowsCanvasToolModeChanges() throws {
        let source = try Self.inspectorSource()
        XCTAssertTrue(source.contains("navigation.follow(toolMode:"))
        XCTAssertTrue(source.contains("model.editor.toolMode"))
    }

    func testInspectorViewOffersSectionAndDomainResetThroughTheSharedCatalog() throws {
        let source = try Self.inspectorSource()
        XCTAssertTrue(source.contains("InspectorCatalog.resetting("), "section/domain reset must route through InspectorCatalog, not a duplicated reset routine")
        XCTAssertTrue(source.contains("InspectorCatalog.isNeutral("))
        XCTAssertTrue(source.contains("L10n.t(\"Reset Adjust\")"))
        XCTAssertTrue(source.contains("L10n.t(\"Reset Geometry\")"))
        XCTAssertTrue(source.contains("L10n.t(\"Reset Local Adjustments\")"))
    }

    func testInspectorViewUsesAllSummarySectionsForAVisualGroupReset() throws {
        let source = try Self.inspectorSource()

        XCTAssertTrue(source.contains("actionSectionIDs: sections"))
        XCTAssertTrue(source.contains("InspectorCatalog.resetting(actionSectionIDs"))
        XCTAssertTrue(source.contains("InspectorCatalog.isNeutral(actionSectionIDs"))
    }

    func testWhiteBalanceUsesLevel2AndLevel3CumulativeHierarchy() throws {
        let source = try Self.inspectorSource()

        XCTAssertTrue(source.contains("Level2Section(L10n.t(\"White Balance\")"))
    }

    /// A user acceptance pass (2026-09-14) reported that a prior fix attempt
    /// -- which only changed `Level2DisclosureGroup`'s internal
    /// `level2Inset` constant from 12 to 16 -- produced no visible change.
    /// Root cause: `inspectorGroup(...)`'s Level 1 host was built on the
    /// native `DisclosureGroup`, whose own content indentation is opaque
    /// platform behavior; a follow-up render experiment (`ImageRenderer`
    /// against an isolated reproduction of the same view tree) confirmed a
    /// `.padding(.leading, ...)` applied inside a native `DisclosureGroup`'s
    /// content closure does not reliably produce the expected on-screen
    /// offset. `inspectorGroup(...)` was rewritten to build its own header
    /// (mirroring `Level2DisclosureGroup`) so every position is deterministic
    /// SwiftUI stack/padding layout instead of native control internals.
    /// This test reads the actual `inspectorGroup(...)` body and requires
    /// the leading-inset padding to be applied to the caller-supplied
    /// `content()` closure using the exact constant
    /// (`level1ContentLeadingInset`) that is *defined* relative to the
    /// title's own leading offset (see `InspectorHierarchyMetricsTests
    /// .testLevel1ContentLeadingInsetIsMeasuredFromTheTitleTextNotAnUnrelatedOrigin`),
    /// not a constant-only fix that leaves the actual on-screen relationship
    /// unverified.
    func testLevel1ExpandedContentIsIndentedRelativeToItsOwnHeader() throws {
        let source = try Self.inspectorSource()

        guard let funcRange = source.range(of: "private func inspectorGroup") else {
            XCTFail("expected InspectorView to still declare the shared inspectorGroup(...) builder")
            return
        }
        guard let nextFuncRange = source.range(of: "\n    private func", range: funcRange.upperBound..<source.endIndex) else {
            XCTFail("expected another private func declaration after inspectorGroup(...) to bound its body")
            return
        }
        let functionBody = String(source[funcRange.lowerBound..<nextFuncRange.lowerBound])

        XCTAssertFalse(
            functionBody.contains("DisclosureGroup("),
            "inspectorGroup(...) must not fall back to the native DisclosureGroup, whose content " +
            "indentation is opaque platform behavior this app cannot verify or reliably adjust"
        )
        XCTAssertTrue(
            functionBody.contains("if isExpanded {") && functionBody.contains("content()"),
            "expected the caller-supplied content() closure to render only while the group is expanded"
        )
        XCTAssertTrue(
            functionBody.contains(".padding(.leading, InspectorHierarchyMetrics.level1ContentLeadingInset)"),
            "Level 1 expanded content must carry a leading inset defined relative to the title's own " +
            "leading offset (level1ContentLeadingInset), not an unrelated origin or a bare literal"
        )
    }

    /// This session's user acceptance pass: the actions menu (ellipsis)
    /// must not render a second, competing disclosure-looking chevron next
    /// to it -- the left-side chevron built in `inspectorGroup` is the
    /// row's only disclosure indicator. `Menu` renders its own caret by
    /// default; `.menuIndicator(.hidden)` is required to suppress it.
    func testGroupActionsMenuHasNoSecondDisclosureIndicator() throws {
        let source = try Self.inspectorSource()

        guard let funcRange = source.range(of: "private func groupActionsMenu") else {
            XCTFail("expected InspectorView to still declare groupActionsMenu(...)")
            return
        }
        let functionBody = String(source[funcRange.lowerBound...])

        XCTAssertTrue(
            functionBody.contains(".menuIndicator(.hidden)"),
            "groupActionsMenu must hide Menu's own automatic caret so the ellipsis button does not look " +
            "like a second section-disclosure toggle next to the row's actual chevron"
        )
    }

    /// This session's user acceptance pass: the whole header row (chevron,
    /// title, summary, and the blank trailing gap) needs at least a 44pt
    /// hit height with a full rectangular hit area, and tapping any blank
    /// space in it must only toggle disclosure -- never the actions menu,
    /// which keeps its own independent hit target as a sibling, not a
    /// nested control inside the toggle button.
    func testLevel1HeaderRowHasAFullHitTargetAtTheMinimumRowHeight() throws {
        let source = try Self.inspectorSource()

        guard let funcRange = source.range(of: "private func inspectorGroup") else {
            XCTFail("expected InspectorView to still declare the shared inspectorGroup(...) builder")
            return
        }
        guard let nextFuncRange = source.range(of: "\n    private func", range: funcRange.upperBound..<source.endIndex) else {
            XCTFail("expected another private func declaration after inspectorGroup(...) to bound its body")
            return
        }
        let functionBody = String(source[funcRange.lowerBound..<nextFuncRange.lowerBound])

        XCTAssertTrue(
            functionBody.contains(".frame(minHeight: InspectorHierarchyMetrics.level1MinRowHeight, alignment: .leading)"),
            "the disclosure toggle button's own label must reserve at least level1MinRowHeight so its hit " +
            "target is a full-height rectangle, not just the text baseline"
        )
        XCTAssertTrue(
            functionBody.contains(".frame(minHeight: InspectorHierarchyMetrics.level1MinRowHeight)\n"),
            "the whole header HStack (button + favorite star + actions menu) must also be at least " +
            "level1MinRowHeight tall so expanded/collapsed rows do not change height"
        )

        guard let buttonRange = functionBody.range(of: "Button {"),
              let buttonStyleRange = functionBody.range(of: ".buttonStyle(.plain)", range: buttonRange.upperBound..<functionBody.endIndex) else {
            XCTFail("expected the disclosure toggle to be a plain-style Button")
            return
        }
        let buttonLabelBlock = String(functionBody[buttonRange.upperBound..<buttonStyleRange.lowerBound])

        XCTAssertTrue(
            buttonLabelBlock.contains("Spacer(minLength: 8)"),
            "the blank trailing gap must be inside the toggle button's own label so tapping it also " +
            "toggles disclosure, per spec: clicking any blank part of the row toggles the group"
        )
        XCTAssertTrue(
            buttonLabelBlock.contains(".contentShape(Rectangle())"),
            "the toggle button's label must use a rectangular content shape, not just its text/icon glyphs"
        )

        guard let groupActionsCallRange = functionBody.range(of: "groupActionsMenu(", range: buttonStyleRange.upperBound..<functionBody.endIndex) else {
            XCTFail("expected groupActionsMenu(...) to be called after the toggle button closes, as an " +
                    "independent sibling rather than nested inside the toggle Button's own label")
            return
        }
        XCTAssertTrue(
            groupActionsCallRange.lowerBound > buttonStyleRange.upperBound,
            "groupActionsMenu(...) must be called outside the disclosure toggle Button so tapping it " +
            "never also fires the toggle Button's action"
        )
    }

    /// This session's user acceptance pass: "「基本」標題／摘要與控制文字偏小" --
    /// the collapsed/expanded screenshots showed the Level 1 title reading no
    /// larger than an ordinary field label. Root cause (see
    /// `InspectorHierarchyMetricsTests
    /// .testLevel1MacTitleBaseSizeMeetsTheSixteenPointFloorAndBeatsFieldLabelSize`'s
    /// doc comment): macOS's `.subheadline` text style is 11pt, smaller than
    /// the 12pt `.callout` an ordinary adjustment label inherits. The title
    /// must use the explicit shared `level1TitleBaseSize`-driven `ScaledMetric`
    /// instead, and that font call must live outside the `if !isExpanded`
    /// summary conditional so the title itself never shrinks or changes
    /// between the expanded and collapsed states.
    func testLevel1TitleFontIsAppliedUnconditionallyAndUsesTheSharedSize() throws {
        let source = try Self.inspectorSource()

        XCTAssertTrue(
            source.contains(
                "@ScaledMetric(relativeTo: .headline) private var level1TitleFontSize: CGFloat = " +
                "InspectorHierarchyMetrics.level1TitleBaseSize"
            ),
            "the Level 1 title must read its font size from a ScaledMetric tied to " +
            "InspectorHierarchyMetrics.level1TitleBaseSize, not a semantic style rendered below 16pt"
        )
        XCTAssertTrue(
            source.contains(
                "@ScaledMetric(relativeTo: .caption) private var level1SummaryFontSize: CGFloat = " +
                "InspectorHierarchyMetrics.level1SummaryBaseSize"
            ),
            "the collapsed-group summary must read its font size from a ScaledMetric tied to " +
            "InspectorHierarchyMetrics.level1SummaryBaseSize, not the platform's smallest caption style"
        )

        guard let funcRange = source.range(of: "private func inspectorGroup") else {
            XCTFail("expected InspectorView to still declare the shared inspectorGroup(...) builder")
            return
        }
        guard let nextFuncRange = source.range(of: "\n    private func", range: funcRange.upperBound..<source.endIndex) else {
            XCTFail("expected another private func declaration after inspectorGroup(...) to bound its body")
            return
        }
        let functionBody = String(source[funcRange.lowerBound..<nextFuncRange.lowerBound])

        XCTAssertFalse(
            functionBody.contains(".subheadline"),
            "the Level 1 title must not fall back to macOS's .subheadline text style (11pt), which reads " +
            "smaller than the .callout (12pt) an ordinary field label inherits"
        )
        XCTAssertFalse(
            functionBody.contains(".font(.caption)"),
            "the collapsed-group summary must not fall back to macOS's bare 10pt .caption text style"
        )

        guard let titleBlockRange = functionBody.range(of: "VStack(alignment: .leading, spacing: 2) {") else {
            XCTFail("expected the title/summary VStack to still exist")
            return
        }
        guard let conditionalSummaryRange = functionBody.range(
            of: "if !isExpanded {",
            range: titleBlockRange.upperBound..<functionBody.endIndex
        ) else {
            XCTFail("expected the collapsed-only summary conditional to still exist")
            return
        }
        let titleOnlyBlock = String(functionBody[titleBlockRange.upperBound..<conditionalSummaryRange.lowerBound])

        XCTAssertTrue(
            titleOnlyBlock.contains("Text(title)"),
            "expected the title Text to render before the collapsed-only summary conditional"
        )
        XCTAssertTrue(
            titleOnlyBlock.contains(".font(.system(size: level1TitleFontSize, weight: .semibold))"),
            "the title's explicit-size font must apply outside the `if !isExpanded` conditional, so the " +
            "title itself is never inside a conditional that could vary its size between states"
        )
    }

    /// This session's user acceptance pass: "每個區塊與區塊之間需要更清楚的間距與分隔" --
    /// the previous layout put `Divider()` as the *last child* inside the
    /// header/content `VStack(spacing: 0)`, gluing it directly against the
    /// last content row with zero gap, and risking it sitting flush against
    /// a nested subsection's own lighter divider (reading as one doubled-up
    /// line). The divider must instead be a sibling of that VStack, so the
    /// outer `adjustmentContent` `VStack(alignment: .leading, spacing: 12)`
    /// supplies a consistent 12pt gap on both sides of it automatically, in
    /// both the collapsed and expanded state.
    func testLevel1DividerIsASiblingOfTheHeaderContentStackNotGluedInsideIt() throws {
        let source = try Self.inspectorSource()

        guard let funcRange = source.range(of: "private func inspectorGroup") else {
            XCTFail("expected InspectorView to still declare the shared inspectorGroup(...) builder")
            return
        }
        guard let nextFuncRange = source.range(of: "\n    private func", range: funcRange.upperBound..<source.endIndex) else {
            XCTFail("expected another private func declaration after inspectorGroup(...) to bound its body")
            return
        }
        let functionBody = String(source[funcRange.lowerBound..<nextFuncRange.lowerBound])

        let fullRange = NSRange(functionBody.startIndex..<functionBody.endIndex, in: functionBody)
        let dedentedDividerRegex = try NSRegularExpression(pattern: "^ {8}Divider\\(\\)$", options: [.anchorsMatchLines])
        let nestedDividerRegex = try NSRegularExpression(pattern: "^ {12}Divider\\(\\)$", options: [.anchorsMatchLines])

        XCTAssertEqual(
            dedentedDividerRegex.numberOfMatches(in: functionBody, range: fullRange), 1,
            "the trailing Divider() must be dedented to the same indentation as the header/content " +
            "VStack (a sibling of it), so the outer adjustmentContent VStack's own 12pt spacing applies " +
            "uniformly before and after it"
        )
        XCTAssertEqual(
            nestedDividerRegex.numberOfMatches(in: functionBody, range: fullRange), 0,
            "Divider() must not remain nested as the last child inside the spacing-0 header/content VStack"
        )
    }

    func testInspectorViewDoesNotDeclareItsOwnSeparateFieldVocabulary() throws {
        let source = try Self.inspectorSource()
        XCTAssertFalse(source.contains("static let toneKinds: [AdjustmentKind] = [\n"),
                       "tone kinds must be derived from InspectorCatalog, not hand-duplicated")
    }
}
