import XCTest
@testable import PhotoLibraryCore

/// Spec §8.3: the cache is disposable, budgeted and LRU-pruned, and it survives
/// a relaunch by reading whatever is on disk.
final class DiskCacheTests: TemporaryDirectoryTestCase {
    private func makeCache(budget: Int64) throws -> DiskCache {
        try DiskCache(
            directoryURL: temporaryDirectory.appendingPathComponent("cache", isDirectory: true),
            byteBudget: budget
        )
    }

    func testStoreAndFetchRoundTrips() async throws {
        let cache = try makeCache(budget: 1_000)
        let key = CacheKey("thumb-a")
        try await cache.store(Data(repeating: 0x01, count: 100), for: key)

        let fetched = await cache.data(for: key)
        XCTAssertEqual(fetched?.count, 100)
        let contains = await cache.contains(key)
        XCTAssertTrue(contains)
    }

    func testMissingKeyReturnsNil() async throws {
        let cache = try makeCache(budget: 1_000)
        let fetched = await cache.data(for: CacheKey("absent"))
        XCTAssertNil(fetched)
    }

    func testTotalByteCountTracksStoredEntries() async throws {
        let cache = try makeCache(budget: 10_000)
        try await cache.store(Data(repeating: 0, count: 300), for: CacheKey("a"))
        try await cache.store(Data(repeating: 0, count: 200), for: CacheKey("b"))
        let total = await cache.totalByteCount
        XCTAssertEqual(total, 500)
    }

    func testExceedingTheBudgetEvictsTheColdestEntry() async throws {
        let cache = try makeCache(budget: 250)
        try await cache.store(Data(repeating: 0, count: 100), for: CacheKey("oldest"))
        try await cache.store(Data(repeating: 0, count: 100), for: CacheKey("middle"))
        // Touch "middle" so "oldest" is unambiguously the least recent.
        _ = await cache.data(for: CacheKey("middle"))
        try await cache.store(Data(repeating: 0, count: 100), for: CacheKey("newest"))

        let hasOldest = await cache.contains(CacheKey("oldest"))
        let hasNewest = await cache.contains(CacheKey("newest"))
        XCTAssertFalse(hasOldest)
        XCTAssertTrue(hasNewest)
        let total = await cache.totalByteCount
        XCTAssertLessThanOrEqual(total, 250)
    }

    func testPinnedEntriesAreNotEvicted() async throws {
        let cache = try makeCache(budget: 150)
        let pinned = CacheKey("onScreen")
        try await cache.store(Data(repeating: 0, count: 100), for: pinned)
        await cache.pin(pinned)

        // Storing a second 100-byte entry pushes total usage to 200, over the
        // 150-byte budget. The pinned entry must survive; the competing
        // unpinned entry is the one the planner evicts.
        try await cache.store(Data(repeating: 0, count: 100), for: CacheKey("other"))
        let stillThere = await cache.contains(pinned)
        XCTAssertTrue(stillThere, "The photo on screen was evicted mid-render")
        let otherStillThere = await cache.contains(CacheKey("other"))
        XCTAssertFalse(otherStillThere, "The unpinned competitor should have been evicted instead")

        await cache.unpin(pinned)
        // Unpinning alone creates no pressure (100 bytes is under the
        // 150-byte budget), so force real pressure before expecting eviction.
        try await cache.store(Data(repeating: 0, count: 100), for: CacheKey("pressure"))
        let afterUnpin = await cache.contains(pinned)
        XCTAssertFalse(afterUnpin, "The formerly pinned entry should now be evictable under pressure")

        let total = await cache.totalByteCount
        XCTAssertLessThanOrEqual(total, 150)
    }

    func testLoweringTheBudgetPrunesImmediately() async throws {
        let cache = try makeCache(budget: 10_000)
        for index in 0..<5 {
            try await cache.store(Data(repeating: 0, count: 100), for: CacheKey("e\(index)"))
        }
        try await cache.setByteBudget(250)
        let total = await cache.totalByteCount
        XCTAssertLessThanOrEqual(total, 250)
    }

    func testRemoveAllEmptiesTheCacheButKeepsItUsable() async throws {
        let cache = try makeCache(budget: 1_000)
        try await cache.store(Data(repeating: 0, count: 100), for: CacheKey("a"))
        try await cache.removeAll()

        let count = await cache.entryCount
        XCTAssertEqual(count, 0)
        // Spec §13.9: deleting the cache must cost nothing but regeneration.
        try await cache.store(Data(repeating: 0, count: 50), for: CacheKey("b"))
        let restored = await cache.data(for: CacheKey("b"))
        XCTAssertEqual(restored?.count, 50)
    }

    func testARelaunchPicksUpEntriesAlreadyOnDisk() async throws {
        let directory = temporaryDirectory.appendingPathComponent("cache", isDirectory: true)
        let first = try DiskCache(directoryURL: directory, byteBudget: 1_000)
        try await first.store(Data(repeating: 0x09, count: 120), for: CacheKey("survivor"))

        let second = try DiskCache(directoryURL: directory, byteBudget: 1_000)
        let count = await second.entryCount
        let total = await second.totalByteCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(total, 120)
        let data = await second.data(for: CacheKey("survivor"))
        XCTAssertEqual(data?.count, 120)
    }

    func testAFileDeletedBehindOurBackIsForgotten() async throws {
        let directory = temporaryDirectory.appendingPathComponent("cache", isDirectory: true)
        let cache = try DiskCache(directoryURL: directory, byteBudget: 1_000)
        let key = CacheKey("vanishing")
        try await cache.store(Data(repeating: 0, count: 40), for: key)

        try FileManager.default.removeItem(at: directory.appendingPathComponent(key.filename))

        let data = await cache.data(for: key)
        XCTAssertNil(data)
        let count = await cache.entryCount
        XCTAssertEqual(count, 0)
    }

    func testCacheErrorsOfferANextStep() {
        for error in [CacheError.insufficientDiskSpace, .writeFailed(reason: "x")] {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertNotNil(error.recoverySuggestion)
        }
    }
}
