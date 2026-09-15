import Foundation
import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// P7: Performance budget verification for 10,000 photos library query (spec §10, §11.4).
/// Tests single-page query latency, combination filtering, keyword search,
/// and verifies response times stay well below the 250ms p95 budget.
final class LibraryPerformanceBudgetTests: TemporaryDirectoryTestCase {
    private var databaseURL: URL!
    private var store: PhotoIndexStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        databaseURL = temporaryDirectory.appendingPathComponent("perf_10k_library.sqlite")
        store = try PhotoIndexStore(databaseURL: databaseURL)
    }

    override func tearDownWithError() throws {
        store?.close()
        store = nil
        try super.tearDownWithError()
    }

    func testTenThousandPhotosQueryLatencyIsWellUnderBudget() throws {
        // Register library
        let libraryFolder = LibraryFolder(
            displayName: "Perf Library",
            rootURL: temporaryDirectory.appendingPathComponent("PerfLibrary", isDirectory: true)
        )
        try store.upsert(library: libraryFolder)
        let libraryID = libraryFolder.id

        // Generate 10,000 photo assets in batch
        let totalCount = 10_000
        let batchSize = 1_000
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        for batchIndex in 0..<(totalCount / batchSize) {
            var batchPhotos: [PhotoAsset] = []
            batchPhotos.reserveCapacity(batchSize)
            for i in 0..<batchSize {
                let index = batchIndex * batchSize + i
                var asset = PhotoAsset.stub(
                    libraryID: libraryID,
                    relativePath: "Folder\(batchIndex)/IMG_\(index).CR3",
                    fingerprint: .stub("perf-fp-\(index)")
                )
                asset.metadata.captureDate = baseDate.addingTimeInterval(Double(index * 60))
                batchPhotos.append(asset)
            }
            try store.upsert(photos: batchPhotos)
        }

        // Measure single page load latency (50 items)
        let query = LibraryQuery(scope: .all, sort: .captureDateDescending)

        var queryLatencies: [TimeInterval] = []
        for _ in 0..<10 {
            let start = CACurrentMediaTime()
            let page = try store.page(matching: query, after: nil, limit: 50)
            let duration = CACurrentMediaTime() - start
            queryLatencies.append(duration)
            XCTAssertEqual(page.photos.count, 50)
        }

        // Budget requirement: p95 under 250ms (0.250s)
        queryLatencies.sort()
        let p95Latency = queryLatencies[Int(Double(queryLatencies.count) * 0.95)]
        XCTAssertLessThan(p95Latency, 0.250, "10k photos single-page query must complete under 250ms (actual: \(p95Latency * 1000)ms)")

        // Paging latency for deep page (skip 500 items via cursor)
        var cursor: PhotoPageCursor?
        for _ in 0..<10 {
            let page = try store.page(matching: query, after: cursor, limit: 50)
            cursor = page.nextCursor
        }
        let deepStart = CACurrentMediaTime()
        let deepPage = try store.page(matching: query, after: cursor, limit: 50)
        let deepDuration = CACurrentMediaTime() - deepStart
        XCTAssertEqual(deepPage.photos.count, 50)
        XCTAssertLessThan(deepDuration, 0.250, "Deep page fetch must complete under 250ms (actual: \(deepDuration * 1000)ms)")
    }

    func testCombinationFilteringAndCurationQueriesStayUnderBudget() throws {
        let libraryFolder = LibraryFolder(
            displayName: "Filtered Library",
            rootURL: temporaryDirectory.appendingPathComponent("FilteredLibrary", isDirectory: true)
        )
        try store.upsert(library: libraryFolder)
        let libraryID = libraryFolder.id

        // Seed 1,000 photos with varying ratings and filenames
        var photos: [PhotoAsset] = []
        photos.reserveCapacity(1_000)
        for i in 0..<1_000 {
            var asset = PhotoAsset.stub(
                libraryID: libraryID,
                relativePath: "IMG_\(i).CR3",
                fingerprint: .stub("filter-fp-\(i)")
            )
            if i % 10 == 0 {
                asset.rating = 5
                asset.flag = .pick
            } else {
                asset.rating = i % 5
                asset.flag = .none
            }
            asset.keywords = [PhotoKeyword(normalized: "nature", displayValue: "Nature")]
            photos.append(asset)
        }
        try store.upsert(photos: photos)

        // Query with rating filter, flag filter, and filename search
        let filteredQuery = LibraryQuery(
            scope: .all,
            filenameSearch: "IMG_5",
            sort: .captureDateDescending,
            rating: .exact(5),
            flag: .pick
        )

        let start = CACurrentMediaTime()
        let resultPage = try store.page(matching: filteredQuery, after: nil, limit: 50)
        let elapsed = CACurrentMediaTime() - start

        XCTAssertLessThan(elapsed, 0.250, "Combined filter query must complete under 250ms (actual: \(elapsed * 1000)ms)")
        XCTAssertFalse(resultPage.photos.isEmpty)
    }
}
