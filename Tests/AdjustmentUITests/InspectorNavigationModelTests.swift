import XCTest
import EditorCore
@testable import AdjustmentUI

/// P2: `InspectorNavigationModel` is the shared state machine both platforms attach
/// to their Inspector host -- search text, pin state, active section, and favorites
/// pass-through. Pure state transitions, no SwiftUI involved.
final class InspectorNavigationModelTests: XCTestCase {

    final class InMemoryStore: InspectorFavoritesPersisting {
        var saved: Set<String> = []
        func favoriteSectionIDs() -> Set<String> { saved }
        func setFavoriteSectionIDs(_ ids: Set<String>) { saved = ids }
    }

    @MainActor
    private func makeModel(initial: InspectorSectionID = .basic) -> InspectorNavigationModel {
        InspectorNavigationModel(initialSection: initial, favorites: InspectorFavoritesModel(store: InMemoryStore()))
    }

    @MainActor
    func testStartsUnpinnedAtTheGivenInitialSection() {
        let model = makeModel(initial: .curve)
        XCTAssertEqual(model.activeSectionID, .curve)
        XCTAssertFalse(model.isPinned)
    }

    @MainActor
    func testFollowMovesActiveSectionWhenUnpinned() {
        let model = makeModel()
        model.follow(toolMode: .crop)
        XCTAssertEqual(model.activeSectionID, .geometry)
    }

    @MainActor
    func testFollowDoesNothingForModesWithNoMapping() {
        let model = makeModel(initial: .detail)
        model.follow(toolMode: .adjust)
        XCTAssertEqual(model.activeSectionID, .detail, "no mapping for .adjust means the current section is preserved")
    }

    @MainActor
    func testPinSuppressesFollow() {
        let model = makeModel(initial: .basic)
        model.togglePin()
        XCTAssertTrue(model.isPinned)

        model.follow(toolMode: .spotHeal)
        XCTAssertEqual(model.activeSectionID, .basic, "a pinned inspector must not be moved by smart follow")
    }

    @MainActor
    func testUnpinningRestoresFollow() {
        let model = makeModel(initial: .basic)
        model.togglePin()
        model.togglePin()
        XCTAssertFalse(model.isPinned)

        model.follow(toolMode: .linearGradient)
        XCTAssertEqual(model.activeSectionID, .local)
    }

    @MainActor
    func testExplicitSelectAlwaysWinsEvenWhenPinned() {
        let model = makeModel(initial: .basic)
        model.togglePin()
        model.select(.effects)
        XCTAssertEqual(model.activeSectionID, .effects, "an explicit tap must always navigate, pinned or not")
        XCTAssertTrue(model.isPinned, "an explicit selection must not silently clear pin")
    }

    @MainActor
    func testSearchResultsFilterTheCatalog() {
        let model = makeModel()
        model.searchQuery = "exposure"
        XCTAssertTrue(model.searchResults.contains(where: { $0.id == .basic }))
        XCTAssertFalse(model.searchResults.contains(where: { $0.id == .geometry }))
    }

    @MainActor
    func testClearSearchEmptiesTheQueryAndResults() {
        let model = makeModel()
        model.searchQuery = "crop"
        XCTAssertFalse(model.searchResults.isEmpty)

        model.clearSearch()
        XCTAssertEqual(model.searchQuery, "")
        XCTAssertTrue(model.searchResults.isEmpty)
    }

    @MainActor
    func testFavoritesPassThrough() {
        let model = makeModel()
        XCTAssertFalse(model.isFavorite(.basic))
        model.toggleFavorite(.basic)
        XCTAssertTrue(model.isFavorite(.basic))
    }
}
