import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

final class PhotoCatalogMetadataTests: TemporaryDirectoryTestCase {
    private var store: PhotoIndexStore!
    private var library: LibraryFolder!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try PhotoIndexStore(databaseURL: temporaryDirectory.appendingPathComponent("library.sqlite"))
        library = LibraryFolder(
            displayName: "Catalog",
            rootURL: temporaryDirectory.appendingPathComponent("Photos", isDirectory: true)
        )
        try store.upsert(library: library)
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try super.tearDownWithError()
    }

    func testKeywordNormalizationKeepsFirstDisplaySpellingAndRejectsBlank() throws {
        let photo = PhotoAsset.stub(
            libraryID: library.id,
            relativePath: "Trip/one.ARW",
            fingerprint: .stub("one")
        )
        try store.upsert(photo: photo)

        try store.setKeywords(["  Café  ", "cafe\u{0301}", "Mount"], for: photo.id)
        XCTAssertEqual(try store.keywords(for: photo.id), [
            PhotoKeyword(normalized: "café", displayValue: "Café"),
            PhotoKeyword(normalized: "mount", displayValue: "Mount")
        ])

        XCTAssertThrowsError(try store.setKeywords(["valid", "   "], for: photo.id)) { error in
            XCTAssertEqual(error as? LibraryQueryError, .invalidKeyword)
        }
        XCTAssertEqual(try store.keywords(for: photo.id).map(\.normalized), ["café", "mount"])
    }

    func testRatingAndFlagSurviveARescanUpsert() throws {
        let photo = PhotoAsset.stub(
            libraryID: library.id,
            relativePath: "Trip/one.ARW",
            fingerprint: .stub("one")
        )
        try store.upsert(photo: photo)
        try store.setRating(4, for: photo.id)
        try store.setFlag(.pick, for: photo.id)

        var rescanned = photo
        rescanned.metadata.cameraModel = "ILCE-7M4"
        rescanned.fingerprint = .stub("new-edge")
        try store.upsert(photo: rescanned)

        let reloaded = try XCTUnwrap(store.photo(id: photo.id))
        XCTAssertEqual(reloaded.rating, 4)
        XCTAssertEqual(reloaded.flag, .pick)
        XCTAssertEqual(reloaded.metadata.cameraModel, "ILCE-7M4")
    }

    func testRatingAndFlagValidation() throws {
        let photo = PhotoAsset.stub(libraryID: library.id, fingerprint: .stub("one"))
        try store.upsert(photo: photo)
        XCTAssertThrowsError(try store.setRating(6, for: photo.id)) { error in
            XCTAssertEqual(error as? LibraryQueryError, .invalidRating(6))
        }
        XCTAssertNoThrow(try store.setRating(0, for: photo.id))
        XCTAssertNoThrow(try store.setFlag(.reject, for: photo.id))
        let reloaded = try XCTUnwrap(store.photo(id: photo.id))
        XCTAssertEqual(reloaded.rating, 0)
        XCTAssertEqual(reloaded.flag, .reject)
    }

    func testComposedCatalogFiltersMatchAllSelectedPredicates() throws {
        let targetID = PhotoID()
        var target = PhotoAsset.stub(
            id: targetID,
            libraryID: library.id,
            relativePath: "Trip/target.ARW",
            fingerprint: .stub("target")
        )
        target.metadata.captureDate = Date(timeIntervalSince1970: 1_700_000_000)
        target.metadata.cameraModel = "ILCE-7M4"
        target.metadata.lensModel = "FE 24-70mm"
        target.hasEdits = true
        try store.upsert(photo: target)
        try store.setRating(5, for: targetID)
        try store.setFlag(.pick, for: targetID)
        try store.setKeywords(["Portrait"], for: targetID)

        var decoy = PhotoAsset.stub(
            libraryID: library.id,
            relativePath: "Trip/decoy.JPG",
            fingerprint: .stub("decoy")
        )
        decoy.metadata.captureDate = Date(timeIntervalSince1970: 1_700_000_100)
        decoy.metadata.cameraModel = "ILCE-7M4"
        try store.upsert(photo: decoy)
        try store.setRating(5, for: decoy.id)
        try store.setFlag(.pick, for: decoy.id)

        let query = LibraryQuery(
            scope: .source(library.id),
            filenameSearch: "tar",
            sort: .filenameAscending,
            rating: .exact(5),
            flag: .pick,
            hasEdits: true,
            format: "arw",
            camera: "ilce-7m4",
            lens: "FE 24-70MM",
            captureDate: PhotoDateRange(
                start: Date(timeIntervalSince1970: 1_699_999_999),
                end: Date(timeIntervalSince1970: 1_700_000_001)
            ),
            keyword: "portrait"
        )
        let page = try store.page(matching: query, after: nil, limit: 20)
        XCTAssertEqual(page.photos.map(\.id), [targetID])
        XCTAssertEqual(page.photos.first?.keywords, [PhotoKeyword(normalized: "portrait", displayValue: "Portrait")])
    }
}
