import SwiftUI
import XCTest
@testable import LumaHarborApp
@testable import PresetCore

/// Round 3 (Codex re-review): `PresetLibraryViewModel.copy(_:to:)` and the
/// preview mechanism itself were already covered end to end, but the
/// *presentation* decisions layered on top in `PresetBrowserView` -- which
/// scope the copy menu item offers, and how hover vs. keyboard focus
/// arbitrate ownership of the transient preview -- had no tests of their
/// own. These types are factored out of the view specifically so they're
/// testable without a SwiftUI rendering harness, which this project doesn't
/// have.
final class PresetBrowserPresentationTests: XCTestCase {

    // MARK: - PresetCopyDestination (finding #3: copy had no UI entry point)

    func testMineOffersLibraryOnlyWhenALibraryIsOpen() {
        XCTAssertEqual(
            PresetCopyDestination.destination(for: .mine, hasLibraryScope: true), .library,
            "A 'mine' preset should offer copying into the open library"
        )
        XCTAssertNil(
            PresetCopyDestination.destination(for: .mine, hasLibraryScope: false),
            "With no library open there is nowhere to copy a 'mine' preset to -- must not offer a destination that will just fail"
        )
    }

    func testLibraryAlwaysOffersMineRegardlessOfLibraryState() {
        XCTAssertEqual(
            PresetCopyDestination.destination(for: .library, hasLibraryScope: true), .mine,
            "A library preset can always be copied to My Presets"
        )
        XCTAssertEqual(
            PresetCopyDestination.destination(for: .library, hasLibraryScope: false), .mine,
            "hasLibraryScope describes whether a *library* destination exists, not whether 'mine' does -- irrelevant here"
        )
    }

    // MARK: - PresetPreviewOwner (finding #4: hover/keyboard must not cancel each other)

    func testANewHoverBecomesTheOwner() {
        let idA = UUID()
        let owner = PresetPreviewOwner.hover(idA)
        XCTAssertTrue(owner.shouldCancel(onHoverExit: idA))
        XCTAssertFalse(owner.shouldCancel(onKeyboardExit: idA), "A hover owner must not be cancelled by a keyboard-exit event")
    }

    func testKeyboardFocusTakingOverIgnoresAStaleHoverExit() {
        let idA = UUID()
        let idB = UUID()
        // Row A was hovered, then keyboard focus moved to row B -- the real
        // sequence this guards against: the pointer is still resting over A
        // (or nearby) when a stray `.onHover(false)` for A arrives afterward.
        var owner = PresetPreviewOwner.hover(idA)
        owner = .keyboard(idB)
        XCTAssertFalse(
            owner.shouldCancel(onHoverExit: idA),
            "A's hover-exit must not cancel B's now-current keyboard preview"
        )
        XCTAssertTrue(owner.shouldCancel(onKeyboardExit: idB))
    }

    func testHoverTakingOverIgnoresAStaleKeyboardExit() {
        let idA = UUID()
        let idB = UUID()
        var owner = PresetPreviewOwner.keyboard(idA)
        owner = .hover(idB)
        XCTAssertFalse(
            owner.shouldCancel(onKeyboardExit: idA),
            "A's focus-exit must not cancel B's now-current hover preview"
        )
        XCTAssertTrue(owner.shouldCancel(onHoverExit: idB))
    }

    func testNoneOwnerCancelsNothing() {
        let id = UUID()
        XCTAssertFalse(PresetPreviewOwner.none.shouldCancel(onHoverExit: id))
        XCTAssertFalse(PresetPreviewOwner.none.shouldCancel(onKeyboardExit: id))
    }

    // MARK: - PresetFocusNavigation (arrow-key row-to-row movement)

    func testDownFromNoSelectionGoesToTheFirstRow() {
        XCTAssertEqual(PresetFocusNavigation.nextIndex(current: nil, direction: .down, count: 3), 0)
    }

    func testUpFromNoSelectionGoesNowhere() {
        XCTAssertNil(PresetFocusNavigation.nextIndex(current: nil, direction: .up, count: 3))
    }

    func testDownAdvancesByOne() {
        XCTAssertEqual(PresetFocusNavigation.nextIndex(current: 0, direction: .down, count: 3), 1)
    }

    func testUpRetreatsByOne() {
        XCTAssertEqual(PresetFocusNavigation.nextIndex(current: 1, direction: .up, count: 3), 0)
    }

    func testDownAtTheLastRowGoesNowhere() {
        XCTAssertNil(
            PresetFocusNavigation.nextIndex(current: 2, direction: .down, count: 3),
            "Must not wrap or move past the end of the list"
        )
    }

    func testUpAtTheFirstRowGoesNowhere() {
        XCTAssertNil(PresetFocusNavigation.nextIndex(current: 0, direction: .up, count: 3))
    }

    func testAnEmptyListNeverProducesAnIndex() {
        XCTAssertNil(PresetFocusNavigation.nextIndex(current: nil, direction: .down, count: 0))
    }

    func testUnhandledDirectionsGoNowhere() {
        XCTAssertNil(PresetFocusNavigation.nextIndex(current: 1, direction: .left, count: 3))
        XCTAssertNil(PresetFocusNavigation.nextIndex(current: 1, direction: .right, count: 3))
    }
}
