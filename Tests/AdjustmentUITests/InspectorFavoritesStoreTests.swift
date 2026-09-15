import XCTest
@testable import AdjustmentUI

/// P2: favorites are section-level, device-local only (spec §7.1 "收藏只存裝置本機
/// preferences"). Tests inject an in-memory fake store so they never touch real
/// `UserDefaults` and stay hermetic/parallel-safe.
final class InspectorFavoritesStoreTests: XCTestCase {

    final class InMemoryStore: InspectorFavoritesPersisting {
        var saved: Set<String> = []
        func favoriteSectionIDs() -> Set<String> { saved }
        func setFavoriteSectionIDs(_ ids: Set<String>) { saved = ids }
    }

    @MainActor
    func testStartsWithNoFavorites() {
        let model = InspectorFavoritesModel(store: InMemoryStore())
        XCTAssertTrue(model.favoriteSectionIDs.isEmpty)
        XCTAssertFalse(model.isFavorite(.basic))
    }

    @MainActor
    func testToggleFavoriteAddsAndRemoves() {
        let model = InspectorFavoritesModel(store: InMemoryStore())

        model.toggleFavorite(.curve)
        XCTAssertTrue(model.isFavorite(.curve))
        XCTAssertEqual(model.favoriteSectionIDs, [.curve])

        model.toggleFavorite(.curve)
        XCTAssertFalse(model.isFavorite(.curve))
        XCTAssertTrue(model.favoriteSectionIDs.isEmpty)
    }

    @MainActor
    func testTogglingOneSectionDoesNotAffectAnother() {
        let model = InspectorFavoritesModel(store: InMemoryStore())
        model.toggleFavorite(.basic)
        model.toggleFavorite(.geometry)
        XCTAssertEqual(model.favoriteSectionIDs, [.basic, .geometry])
    }

    @MainActor
    func testFavoritesPersistThroughTheInjectedStore() {
        let store = InMemoryStore()
        let first = InspectorFavoritesModel(store: store)
        first.toggleFavorite(.local)

        let second = InspectorFavoritesModel(store: store)
        XCTAssertTrue(second.isFavorite(.local), "a new model reading the same store must see the persisted favorite")
    }
}
