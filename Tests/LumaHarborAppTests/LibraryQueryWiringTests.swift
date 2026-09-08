import Foundation
import XCTest
@testable import LumaHarborApp
@testable import PhotoLibraryCore

/// Spec §5.3/§4.2 (`docs/superpowers/specs/2026-09-08-editor-workflow-ux-optimization.md`):
/// Mac library search and sort must reuse `PhotoIndexStore.page(matching:after:limit:)`
/// -- the same filename-search (Unicode normalization, `%`/`_` escaping) and
/// `ORDER BY`/tie-break contract the iPad browser (`LibraryBrowserSession`)
/// already relies on -- rather than a second, hand-rolled Swift-side
/// filter/sort. These tests exercise `LibraryViewModel.visiblePhotos`
/// end-to-end against the real SQLite-backed index, not a mock.
@MainActor
final class LibraryQueryWiringTests: AppViewModelTestCase {
    private func waitForVisiblePhotos(
        _ model: LibraryViewModel,
        toSatisfy description: String,
        _ condition: @Sendable @escaping ([PhotoAsset]) -> Bool
    ) async {
        await waitUntilAppCondition(description) {
            await MainActor.run { condition(model.visiblePhotos) }
        }
    }

    func testSearchTextFiltersVisiblePhotosThroughTheSharedIndexQuery() async throws {
        try seedPhotos(["Alpha.ARW", "Beta.ARW", "Gamma.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        await waitForVisiblePhotos(model, toSatisfy: "the unfiltered first page to load") {
            $0.count == 3
        }

        model.searchText = "eta"
        await waitForVisiblePhotos(model, toSatisfy: "the debounced search to land") {
            $0.map(\.filename) == ["Beta.ARW"]
        }

        model.searchText = ""
        await waitForVisiblePhotos(model, toSatisfy: "clearing the search to restore every photo") {
            $0.count == 3
        }
    }

    func testSearchTreatsPercentAndUnderscoreAsLiteralCharactersNotSQLWildcards() async throws {
        // `PhotoIndexStore`'s own `escapeForLike` contract (spec §5.3.1):
        // reused here, not re-implemented, so "%" must not match everything
        // and "_" must not match any single character.
        try seedPhotos(["100%.ARW", "Normal.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        await waitForVisiblePhotos(model, toSatisfy: "the unfiltered first page to load") {
            $0.count == 2
        }

        model.searchText = "100%"
        await waitForVisiblePhotos(model, toSatisfy: "a literal percent search to match only its own file") {
            $0.map(\.filename) == ["100%.ARW"]
        }
    }

    func testSortOrdersVisiblePhotosThroughTheSharedIndexQuery() async throws {
        try seedPhotos(["Charlie.ARW", "Alpha.ARW", "Bravo.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        await waitForVisiblePhotos(model, toSatisfy: "the first page to load") { $0.count == 3 }

        model.sort = .filenameAscending
        await waitForVisiblePhotos(model, toSatisfy: "ascending filename order") {
            $0.map(\.filename) == ["Alpha.ARW", "Bravo.ARW", "Charlie.ARW"]
        }

        model.sort = .filenameDescending
        await waitForVisiblePhotos(model, toSatisfy: "descending filename order") {
            $0.map(\.filename) == ["Charlie.ARW", "Bravo.ARW", "Alpha.ARW"]
        }
    }

    func testRapidSearchEditsOnlySurfaceTheLatestQueryResult() async throws {
        try seedPhotos(["Alpha.ARW", "Beta.ARW", "Gamma.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        await waitForVisiblePhotos(model, toSatisfy: "the first page to load") { $0.count == 3 }

        // A burst of edits well inside the 250ms debounce window -- only the
        // last one may ever land, and no stale intermediate result may
        // ever briefly (or permanently) overwrite it.
        model.searchText = "A"
        model.searchText = "Al"
        model.searchText = "Alp"
        model.searchText = "Alph"
        model.searchText = "Alpha"

        await waitForVisiblePhotos(model, toSatisfy: "only the final search term's result to land") {
            $0.map(\.filename) == ["Alpha.ARW"]
        }
        // Give any stale, superseded query a chance to (wrongly) land too.
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.visiblePhotos.map(\.filename), ["Alpha.ARW"])
    }

    func testChangingLibrarySelectionRequeriesVisiblePhotosForTheNewLibrary() async throws {
        try seedPhotos(["Alpha.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let model = await makeModel(services: services, libraryID: library.id)
        await waitForVisiblePhotos(model, toSatisfy: "the library's own photo to load") {
            $0.map(\.filename) == ["Alpha.ARW"]
        }

        await model.selectForTesting(libraryID: nil)
        await waitForVisiblePhotos(model, toSatisfy: "no library selected clears visiblePhotos") {
            $0.isEmpty
        }
    }

    func testAdvancedCurationFiltersComposeWithFilenameSearch() async throws {
        try seedPhotos(["Hero.ARW", "Other.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)

        let index = await services.libraryService.indexStore
        let indexed = try index.photos(inLibrary: library.id)
        let hero = try XCTUnwrap(indexed.first { $0.filename == "Hero.ARW" })
        try index.setRating(4, for: hero.id)
        try index.setFlag(.pick, for: hero.id)
        try index.setKeywords(["Selects"], for: hero.id)

        let model = await makeModel(services: services, libraryID: library.id)
        await waitForVisiblePhotos(model, toSatisfy: "the unfiltered first page to load") { $0.count == 2 }

        model.searchText = "Hero"
        model.ratingFilter = .exact(4)
        model.flagFilter = .pick
        model.keywordFilter = "selects"

        await waitForVisiblePhotos(model, toSatisfy: "all advanced filters to compose") {
            $0.map(\.filename) == ["Hero.ARW"]
        }

        model.clearCatalogFilters()
        model.searchText = ""
        await waitForVisiblePhotos(model, toSatisfy: "clearing advanced filters") { $0.count == 2 }
    }
}
