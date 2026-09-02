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

    /// Real-device V2.1 regression: the sidebar toolbar's small `+` button
    /// can fail to present the folder picker on iPad, leaving an empty
    /// library with no usable way to add its first external source. The empty
    /// state in the main content area must therefore expose the same action as
    /// a visible button, not just descriptive text.
    func testEmptyLibraryStateOffersAVisibleAddSourceAction() throws {
        let source = try Self.loadSource("PadLibraryGrid.swift")

        XCTAssertTrue(
            source.contains("let onAddSource: () -> Void"),
            "PadLibraryGrid must receive an add-source action from the parent view"
        )
        XCTAssertTrue(
            source.contains("Button(L10n.t(\"Add Source\"), action: onAddSource)"),
            "the empty library state must include a visible Add Source button"
        )
    }

    /// Real-device V2.1 regression, round 2: routing the main empty-state
    /// button through SwiftUI's `.fileImporter(allowedContentTypes: [.folder])`
    /// can leave the app apparently doing nothing on iPad. The add-source flow
    /// must present the system folder picker through an explicit document
    /// picker sheet owned by `PadLibraryView`, so both the sidebar `+` and the
    /// visible empty-state button use the same reliable presenter.
    func testAddSourceUsesDedicatedFolderDocumentPickerSheet() throws {
        let source = try Self.loadSource("PadLibraryView.swift")

        XCTAssertTrue(
            source.contains(".sheet(isPresented: $isAddingSource)"),
            "PadLibraryView must present add-source through a sheet, not a detached fileImporter"
        )
        XCTAssertTrue(
            source.contains("FolderDocumentPicker("),
            "PadLibraryView must use the dedicated folder document picker for add-source"
        )
        XCTAssertFalse(
            source.contains("allowedContentTypes: [.folder]"),
            "the add-source presenter must not fall back to SwiftUI's folder fileImporter"
        )
    }

    func testFolderDocumentPickerOpensFoldersWithoutCopying() throws {
        let source = try Self.loadSource("FolderDocumentPicker.swift")

        XCTAssertTrue(source.contains("import UIKit"), "the picker wrapper must use UIKit's document picker")
        XCTAssertTrue(
            source.contains("UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)"),
            "external folders must be opened in place rather than copied into the app sandbox"
        )
        XCTAssertTrue(
            source.contains("picker.allowsMultipleSelection = false"),
            "add-source must keep the single-folder contract"
        )
        XCTAssertTrue(source.contains("documentPickerWasCancelled"), "the picker must dismiss cleanly on cancel")
        XCTAssertTrue(source.contains("didPickDocumentsAt"), "the picker must report the selected folder URL")
    }

    /// UIKit's document picker hands back a security-scoped URL whose access
    /// must be actively held by our app while the async library-add path
    /// creates its bookmark and starts the first scan. Without this, real
    /// iPad external-drive picks can appear to work at the source-list level
    /// but later fail opening the child `.ARW` with an access/permission alert.
    func testAddSourceKeepsPickedFolderSecurityScopeDuringAsyncRegistration() throws {
        let source = try Self.loadSource("PadLibraryView.swift")

        XCTAssertTrue(
            source.contains("ScopedFolderAccess(url: url, startAccessing: true)"),
            "PadLibraryView must explicitly start security-scoped access for the picked folder URL"
        )
        XCTAssertTrue(
            source.contains("defer { scope.stop() }"),
            "the picked folder scope must stay alive until async source registration and initial scan have been kicked off"
        )
    }

    /// Real-device UX follow-up: after the folder picker returns, source
    /// registration and the first scan can take long enough on an external
    /// drive that the app must show an explicit progress state rather than
    /// appearing frozen.
    func testAddSourceRegistrationShowsAVisibleLoadingOverlay() throws {
        let source = try Self.loadSource("PadLibraryView.swift")

        // Task 2: registration progress is no longer tracked by a
        // view-local flag -- `LibraryBrowserSession.addSource(at:sourceKind:)`
        // itself publishes `.addingSource` for the whole duration (Task 1),
        // so PadLibraryView only needs to read `library.operationState`.
        XCTAssertTrue(
            source.contains("library.operationState"),
            "PadLibraryView must derive its overlay from the session's operationState"
        )
        XCTAssertTrue(
            source.contains("PadLibraryProgressOverlay("),
            "PadLibraryView must show a visible loading overlay while registering a source"
        )
        XCTAssertTrue(
            source.contains("L10n.t(\"Adding source…\")"),
            "the source-registration overlay must have user-visible text"
        )
    }

    /// The first implementation only showed progress during the brief
    /// registry/bookmark step, then hid it before the actual external-drive
    /// scan began. Real-device feedback must stay visible while the browser
    /// session reports an active per-source scan.
    func testSourceScanProgressKeepsAVisibleLoadingOverlayMounted() throws {
        let source = try Self.loadSource("PadLibraryView.swift")

        XCTAssertTrue(
            source.contains("private var hasActiveSourceScan: Bool"),
            "PadLibraryView must derive visible progress from the library session's active source scans"
        )
        XCTAssertTrue(
            source.contains("library.sourceProgress.values.contains"),
            "the scan overlay must observe sourceProgress, not only the short add-source task"
        )
        XCTAssertTrue(
            source.contains("case .scanning: return true"),
            "the scan overlay must stay mounted while a source is scanning"
        )
        // Task 2: `hasActiveSourceScan` is now only consulted as a fallback
        // once `library.operationState` is `.idle` -- a non-idle
        // operationState (add/scan/reconnect/remove) always takes priority.
        XCTAssertTrue(
            source.contains("case .idle:") && source.contains("guard hasActiveSourceScan else { return nil }"),
            "the overlay must fall back to sourceProgress-driven scanning only once operationState is idle"
        )
    }

    /// Manual rescan should not reuse the add-source wording. Otherwise the
    /// user taps "Rescan" and sees "Adding source…", which sounds like the
    /// app is creating a duplicate source instead of refreshing the index.
    func testSourceScanProgressUsesScanningCopyInsteadOfAddSourceCopy() throws {
        let source = try Self.loadSource("PadLibraryView.swift")

        XCTAssertTrue(
            source.contains("private var activeLibraryOverlay: (title: String, message: String)?"),
            "PadLibraryView must derive the overlay title/message from a single operationState-driven property"
        )
        XCTAssertTrue(
            source.contains("case .scanningSource:"),
            "scanning must be its own operationState case, distinct from adding a source"
        )
        XCTAssertTrue(
            source.contains("L10n.t(\"Scanning source…\")"),
            "active source scans must use scan-specific visible text"
        )
        XCTAssertTrue(
            source.contains("title: overlay.title"),
            "the progress overlay must use the derived title rather than hard-coding add-source text"
        )
    }

    /// Real-device UX follow-up: tapping a RAW thumbnail from an indexed
    /// external source starts an async library resolution step before the
    /// editor takes over. That wait must be visible and cancellable by
    /// superseding taps, not an apparently inert grid.
    func testOpeningPhotoFromGridShowsAVisibleLoadingOverlay() throws {
        let source = try Self.loadSource("PadLibraryGrid.swift")

        XCTAssertTrue(
            source.contains("@State private var openingPhotoID: PhotoID?"),
            "PadLibraryGrid must track the currently-opening photo"
        )
        XCTAssertTrue(
            source.contains("PadLibraryProgressOverlay("),
            "PadLibraryGrid must show a visible loading overlay while preparing a photo"
        )
        XCTAssertTrue(
            source.contains("L10n.t(\"Preparing photo…\")"),
            "the photo-opening overlay must have user-visible text"
        )
    }

    /// A very fast library resolution can otherwise set and clear
    /// `openingPhotoID` within one render pass, making the progress text
    /// technically present in source but invisible on the device.
    func testOpeningPhotoProgressHasAMinimumVisibleDuration() throws {
        let source = try Self.loadSource("PadLibraryGrid.swift")

        XCTAssertTrue(
            source.contains("minimumOpeningProgressDuration"),
            "PadLibraryGrid must keep the opening progress visible long enough to be seen"
        )
        XCTAssertTrue(
            source.contains("Task.sleep(for: Self.minimumOpeningProgressDuration)"),
            "opening progress must wait for the minimum visible duration before dismissing"
        )
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

    /// The next-page prefetch indicator is often the only feedback while
    /// scrolling deep into an external SSD. It needs readable text, not only
    /// an unlabeled spinner at the bottom of the grid.
    func testNextPageLoadingIndicatorHasReadableText() throws {
        let source = try Self.loadSource("PadLibraryGrid.swift")

        XCTAssertTrue(
            source.contains("ProgressView(L10n.t(\"Loading more photos…\"))"),
            "the next-page loading indicator must include visible localized text"
        )
    }

    /// Real-device UX follow-up: removing an external source can touch the
    /// local index/bookmark store and should not look like a dead tap after
    /// the destructive confirmation is accepted. The visible copy must also
    /// keep reinforcing that RAW files are not deleted.
    func testRemovingSourceShowsVisibleProgressAndRawSafetyCopy() throws {
        let source = try Self.loadSource("PadLibrarySidebar.swift")

        XCTAssertTrue(
            source.contains("@State private var removingSourceID: LibraryID?"),
            "PadLibrarySidebar must track the source currently being removed"
        )
        XCTAssertTrue(
            source.contains("PadLibraryProgressOverlay("),
            "PadLibrarySidebar must show a visible progress overlay while removing a source"
        )
        XCTAssertTrue(
            source.contains("L10n.t(\"Removing source…\")"),
            "the remove-source progress overlay must have user-visible text"
        )
        XCTAssertTrue(
            source.contains("L10n.t(\"RAW files stay exactly where they are.\")"),
            "the remove-source progress copy must reassure users that RAW files are not deleted"
        )
    }

    /// Reconnecting a source can spend visible time validating the selected
    /// folder's identity. The UI should say that explicitly so users do not
    /// tap again or assume LumaHarbor accepted a same-named wrong drive.
    func testReconnectingSourceShowsVisibleProgressAndIdentityCopy() throws {
        let source = try Self.loadSource("PadLibrarySidebar.swift")

        XCTAssertTrue(
            source.contains("@State private var reconnectingSourceID: LibraryID?"),
            "PadLibrarySidebar must track the source currently being reconnected"
        )
        XCTAssertTrue(
            source.contains("L10n.t(\"Reconnecting source…\")"),
            "the reconnect progress overlay must have user-visible text"
        )
        XCTAssertTrue(
            source.contains("L10n.t(\"Checking this folder matches the original source.\")"),
            "the reconnect progress copy must explain identity verification"
        )
        XCTAssertTrue(
            source.contains("await library.relinkSource(target.id, to: url)"),
            "the reconnect progress state must wrap the existing relink call"
        )
    }

    /// Source rows should expose scan state inline, not only as a temporary
    /// overlay. After a partial failure the row is often the user's only
    /// persistent clue that a source needs attention.
    func testSourceRowsShowScanProgressAndFailureState() throws {
        let source = try Self.loadSource("PadLibrarySidebar.swift")

        XCTAssertTrue(
            source.contains("library.sourceProgress[source.id]"),
            "source rows must read per-source scan progress"
        )
        XCTAssertTrue(
            source.contains("case .scanning: return L10n.t(\"Scanning…\")"),
            "source rows must show visible scanning text"
        )
        // Task 2: a failed scan that still left usable partial results
        // (something indexed, or an individual per-photo failure) must read
        // differently from a scan that never got anywhere.
        XCTAssertTrue(source.contains("case .failed:"), "source rows must branch on scan failure")
        XCTAssertTrue(
            source.contains("L10n.t(\"Partial issue\")") && source.contains("L10n.t(\"Scan problem\")"),
            "source rows must distinguish a partially-failed scan from a fully-failed one"
        )
    }

    /// Task 2: source rows must expose every lifecycle state the spec
    /// requires as its own distinct, visible text -- never one state
    /// standing in for another -- and the remove confirmation must
    /// explicitly promise the RAW files, sidecars, and the source's own
    /// `.lumaharbor` manifest are untouched.
    func testSourceRowsExposeDistinctLifecycleText() throws {
        let source = try Self.loadSource("PadLibrarySidebar.swift")

        for key in ["Read-only", "Offline", "Needs Access", "Scanning…", "Partial issue", "Scan problem"] {
            XCTAssertTrue(source.contains("L10n.t(\"\(key)\")"), "missing \(key)")
        }
        XCTAssertTrue(
            source.contains("RAW files and sidecars stay exactly where they are"),
            "the remove confirmation must state that RAW files and sidecars are untouched"
        )
        XCTAssertTrue(
            source.contains("manifest"),
            "the remove confirmation must also mention the source's .lumaharbor manifest is untouched"
        )
    }

    /// Codex pre-landing review, Task 7 round, finding 2 (P1, blocking):
    /// `LibraryBrowserSession.restoreGridPosition()` re-fetches the right
    /// page, but nothing here previously consumed `pendingScrollAnchor` to
    /// actually scroll the view there. Source-parsing is the only
    /// verification available for this file (same `.swiftpm`-package
    /// constraint as everything else in this test file), so this asserts
    /// the three pieces the fix requires are actually wired together: a
    /// `ScrollViewReader` wraps the grid, it scrolls to
    /// `library.pendingScrollAnchor`, and it acknowledges the anchor
    /// afterward so a later, unrelated `photos` change never re-triggers
    /// the same scroll.
    func testGridWiresUpScrollToRestorationAnchor() throws {
        let source = try Self.loadSource("PadLibraryGrid.swift")

        XCTAssertTrue(source.contains("ScrollViewReader"), "the grid must use a ScrollViewReader to scroll programmatically")
        guard let scrollRange = source.range(of: "private func scrollToAnchorIfNeeded") else {
            return XCTFail("PadLibraryGrid must define a scrollToAnchorIfNeeded(_:proxy:) helper")
        }
        let scrollBody = source[scrollRange.upperBound...]

        XCTAssertTrue(scrollBody.contains("library.pendingScrollAnchor"), "must read the session's pending scroll anchor")
        XCTAssertTrue(
            scrollBody.contains("photos.contains(where:"),
            "must only scroll once the anchor is actually present in photos, never a blind/empty scroll"
        )
        XCTAssertTrue(scrollBody.contains("proxy.scrollTo("), "must actually call scrollTo on the anchor")
        XCTAssertTrue(
            scrollBody.contains("library.acknowledgeScrollToAnchor()"),
            "must acknowledge the anchor after scrolling so a later photos change can't re-trigger the same scroll"
        )

        // Both entry points that could make the anchor already-satisfied --
        // the view first appearing, and photos changing after that -- must
        // route through the same check.
        XCTAssertTrue(source.contains(".onAppear {"), "must check for an already-satisfiable anchor on first appearance")
        XCTAssertTrue(
            source.contains(".onChange(of: library.photos)"),
            "must re-check whenever photos changes (e.g. once the anchor's page finishes loading)"
        )
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
