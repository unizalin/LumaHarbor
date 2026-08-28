import Foundation
import XCTest

/// Task 7's grid/cell views (`PadLibraryGrid.swift`, `PadThumbnailCell.swift`)
/// live in a `.swiftpm` app package with no test target `swift test` can
/// compile or run -- the same situation `PadLibraryCompositionContractTests`
/// documents for `PadLibraryModel.swift`/`LumaHarborPadApp.swift`. There is
/// no way to instantiate and inspect the actual SwiftUI view hierarchy from
/// here, so this file source-parses the two files' raw text instead, and
/// asserts on exactly the two accessibility contracts the brief calls for:
/// every cell has an accessibility label built from filename/capture date/
/// source name/status/edited state, and every interactive control (cells,
/// sort menu, grid-density menu) declares at least a 44×44 pt hit region.
final class PadLibraryAccessibilityContractTests: XCTestCase {

    // MARK: - Source-parsing contract

    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PadLibraryAccessibilityContractTests.swift
            .deletingLastPathComponent() // AdjustmentUITests
            .deletingLastPathComponent() // Tests
    }()

    private static func padAppSourceURL(_ filename: String) -> URL {
        repositoryRootURL
            .appendingPathComponent("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp", isDirectory: true)
            .appendingPathComponent(filename)
    }

    private static func loadSource(_ filename: String) throws -> String {
        try String(contentsOf: padAppSourceURL(filename), encoding: .utf8)
    }

    // MARK: - PadThumbnailCell.swift

    func testThumbnailCellDeclaresAnAccessibilityLabel() throws {
        let source = try Self.loadSource("PadThumbnailCell.swift")

        XCTAssertTrue(
            source.contains(".accessibilityLabel(Text(accessibilityLabel))"),
            "PadThumbnailCell must declare a single accessibility label for the whole cell"
        )
        // `.accessibilityElement(children: .ignore)` is what keeps VoiceOver
        // from reading the filename/caption/badge as separate fragmented
        // elements instead of the one composed label above.
        XCTAssertTrue(
            source.contains(".accessibilityElement(children: .ignore)"),
            "PadThumbnailCell must collapse its subviews into one accessibility element"
        )
    }

    /// Every new visible piece of cell state the brief calls for: filename,
    /// capture date when available, source display name, connection/error
    /// status, and edited state.
    func testThumbnailCellAccessibilityLabelIncludesEveryRequiredComponent() throws {
        let source = try Self.loadSource("PadThumbnailCell.swift")

        guard let labelRange = source.range(of: "private var accessibilityLabel: String {") else {
            return XCTFail("PadThumbnailCell must define an accessibilityLabel computed property")
        }
        let labelBody = source[labelRange.upperBound...]

        XCTAssertTrue(labelBody.contains("photo.filename"), "the label must include the filename")
        XCTAssertTrue(
            labelBody.contains("dateFormatter.string(from: date)"),
            "the label must include the capture date when available"
        )
        XCTAssertTrue(labelBody.contains("sourceDisplayName"), "the label must include the source's display name")
        XCTAssertTrue(
            labelBody.contains("photo.statusMessage") && labelBody.contains("sourceStatusMessage"),
            "the label must include both a per-photo status and the source's connection status"
        )
        XCTAssertTrue(
            labelBody.contains("L10n.t(\"Edited\")") && labelBody.contains("photo.hasEdits"),
            "the label must include the edited state"
        )
    }

    /// Status is never conveyed by color alone (global constraint): each
    /// non-image state pairs a distinct SF Symbol with caption text, rather
    /// than relying on a tint color to distinguish "offline" from "error".
    func testThumbnailCellDoesNotConveyStatusByColorAlone() throws {
        let source = try Self.loadSource("PadThumbnailCell.swift")

        XCTAssertTrue(source.contains("\"wifi.slash\""), "the offline state must show a distinct icon")
        XCTAssertTrue(source.contains("L10n.t(\"Offline\")"), "the offline state must show text, not just an icon or color")
        XCTAssertTrue(source.contains("\"exclamationmark.triangle\""), "the error state must show a distinct icon")
        XCTAssertTrue(
            source.contains("L10n.t(\"Couldn't load\")"),
            "the error state must show text, not just an icon or color"
        )
    }

    /// The Mac app's `ThumbnailView`/`PhotoGridCell` use AppKit's `NSImage`
    /// -- the iPad target is iOS, so this file must use `UIImage`/
    /// `Image(uiImage:)` instead, never re-import AppKit.
    func testThumbnailCellUsesUIImageNotNSImage() throws {
        let source = try Self.loadSource("PadThumbnailCell.swift")

        XCTAssertTrue(source.contains("import UIKit"), "must import UIKit for UIImage")
        // Checked as an actual usage (instantiation/type), not a bare
        // substring match -- this file's own doc comment legitimately
        // mentions "NSImage" by name when contrasting with the Mac app's
        // AppKit-based cell.
        XCTAssertFalse(source.contains("NSImage("), "must never instantiate AppKit's NSImage")
        XCTAssertFalse(source.contains("import AppKit"), "must never import AppKit")
        XCTAssertTrue(source.contains("Image(uiImage:"), "must render via Image(uiImage:)")
    }

    /// Every cell keeps at least a 44×44 pt hit region (global constraint),
    /// regardless of the grid-density preference's actual thumbnail size.
    func testThumbnailCellDeclaresTheMinimumHitTarget() throws {
        let source = try Self.loadSource("PadThumbnailCell.swift")

        XCTAssertTrue(
            source.contains(".frame(minWidth: 44, minHeight: 44)"),
            "PadThumbnailCell must guarantee at least a 44×44 pt hit region"
        )
    }

    // MARK: - PadLibraryGrid.swift

    /// The toolbar's sort and grid-density controls are also interactive
    /// elements the 44×44 pt constraint applies to, not just grid cells.
    func testToolbarControlsDeclareTheMinimumHitTarget() throws {
        let source = try Self.loadSource("PadLibraryGrid.swift")

        let occurrences = source.components(separatedBy: ".frame(minWidth: 44, minHeight: 44)").count - 1
        XCTAssertGreaterThanOrEqual(
            occurrences, 2,
            "both the sort menu and the grid-density menu must declare a 44×44 pt minimum hit region"
        )
    }

    /// Step 3's fixed-sort UI concern: while `.recentlyEdited` is selected,
    /// the sort control must not offer a choice that has no effect (the
    /// SQL layer always overrides sort for that scope -- see
    /// `LibraryBrowserSession.isSortFixedByScope`'s own doc comment).
    func testSortMenuIsDisabledWhenTheScopeFixesTheSort() throws {
        let source = try Self.loadSource("PadLibraryGrid.swift")

        XCTAssertTrue(
            source.contains(".disabled(library.isSortFixedByScope)"),
            "the sort menu must be disabled while the current scope ignores sort entirely"
        )
    }

    /// Every distinct sort choice from the brief's "four sorts" must be
    /// reachable from the toolbar.
    func testAllFourSortsAreOfferedInTheToolbar() throws {
        let source = try Self.loadSource("PadLibraryGrid.swift")

        for sort in [".captureDateDescending", ".captureDateAscending", ".filenameAscending", ".filenameDescending"] {
            XCTAssertTrue(source.contains(sort), "the sort menu must offer \(sort)")
        }
    }

    /// The grid must trigger its own near-end prefetch, rather than relying
    /// only on a plain "last item" check -- the brief's "last 20 visible
    /// items" threshold.
    func testGridTriggersPrefetchNearTheEndOfTheLoadedPhotos() throws {
        let source = try Self.loadSource("PadLibraryGrid.swift")

        XCTAssertTrue(
            source.contains("prefetchThreshold = 20"),
            "the grid's near-end prefetch threshold must be exactly 20"
        )
        XCTAssertTrue(source.contains("library.loadNextPage()"), "the grid must call loadNextPage() near the end")
    }

    // MARK: - PadLibrarySettingsView.swift (Task 7 Step 5, review round 1 Important #4)

    /// The plan's own literal acceptance numbers (512 MiB through 10 GiB) --
    /// checked by exact text match against the raw source rather than
    /// re-derived arithmetically, so a typo'd constant fails this test
    /// instead of silently agreeing with itself.
    func testCacheBudgetOffersExactlyThePlansFiveByteConstants() throws {
        let source = try Self.loadSource("PadLibrarySettingsView.swift")

        for constant in ["536_870_912", "1_073_741_824", "2_147_483_648", "5_368_709_120", "10_737_418_240"] {
            XCTAssertTrue(source.contains(constant), "the cache-budget enum must offer the exact byte constant \(constant)")
        }
    }

    /// 2 GiB is the documented default -- both as the enum's own `default`
    /// and as `resolvingPersisted`'s fallback (checked separately below).
    func testCacheBudgetDefaultIsExactlyTwoGibibytes() throws {
        let source = try Self.loadSource("PadLibrarySettingsView.swift")

        XCTAssertTrue(
            source.contains("static let `default`: PadThumbnailCacheBudget = .gib2"),
            "the cache-budget enum must declare .gib2 as its exact default"
        )
    }

    /// An absent/invalid/out-of-range persisted value must resolve to
    /// `.default`, never an arbitrary budget built by force-unwrapping or
    /// otherwise trusting the raw stored `Int64` directly.
    func testResolvingPersistedFallsBackToDefaultRatherThanTrustingTheRawStoredValue() throws {
        let source = try Self.loadSource("PadLibrarySettingsView.swift")

        guard let range = source.range(of: "static func resolvingPersisted(") else {
            return XCTFail("PadThumbnailCacheBudget must declare resolvingPersisted(_:)")
        }
        let body = source[range.upperBound...]

        XCTAssertTrue(
            body.contains("?? .default"),
            "resolvingPersisted must fall back to .default rather than force-unwrapping or trusting the raw value"
        )
        XCTAssertFalse(
            body.contains("PadThumbnailCacheBudget(rawValue: stored)!"),
            "resolvingPersisted must never force-unwrap an untrusted stored value"
        )
    }

    /// Step 5's "applies immediately" requirement: selecting a budget must
    /// not just persist it for the next launch -- it must call
    /// `setByteBudget` on the live provider in the same action.
    func testApplyCallsSetByteBudgetOnTheLiveProvider() throws {
        let source = try Self.loadSource("PadLibrarySettingsView.swift")

        guard let range = source.range(of: "private func apply(_ budget: PadThumbnailCacheBudget) {") else {
            return XCTFail("PadLibrarySettingsView must declare apply(_:)")
        }
        let body = source[range.upperBound...]

        XCTAssertTrue(
            body.contains("services.thumbnailProvider.setByteBudget(budget.rawValue)"),
            "apply(_:) must call setByteBudget on the live provider, not just persist the selection"
        )
    }

    /// Review round 1, Important #2: a thrown `setByteBudget` failure must
    /// surface as a real alert, never be swallowed by `try?`.
    func testApplyPropagatesSetByteBudgetFailuresInsteadOfSwallowingThem() throws {
        let source = try Self.loadSource("PadLibrarySettingsView.swift")

        guard let range = source.range(of: "private func apply(_ budget: PadThumbnailCacheBudget) {") else {
            return XCTFail("PadLibrarySettingsView must declare apply(_:)")
        }
        let body = source[range.upperBound...]

        XCTAssertFalse(
            body.contains("try? await services.thumbnailProvider.setByteBudget"),
            "apply(_:) must not silently discard a setByteBudget failure with try?"
        )
        XCTAssertTrue(
            body.contains("do {") && body.contains("} catch {"),
            "apply(_:) must catch a thrown setByteBudget failure"
        )
        XCTAssertTrue(
            body.contains("alert = SafeErrorPresentation.alert("),
            "apply(_:) must surface the failure as a SafeErrorPresentation alert"
        )
    }
}
