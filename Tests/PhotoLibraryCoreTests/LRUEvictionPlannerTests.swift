import XCTest
@testable import PhotoLibraryCore

/// Spec §8.3: a configurable ceiling, least-recently-used first, and anything
/// on screen or mid-export is protected.
final class LRUEvictionPlannerTests: XCTestCase {
    private func entry(_ name: String, bytes: Int64, minutesAgo: Int) -> CacheEntryMetadata {
        CacheEntryMetadata(
            key: CacheKey(name),
            byteCount: bytes,
            lastAccessedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(minutesAgo) * 60)
        )
    }

    func testDefaultBudgetIsTenGibibytes() {
        XCTAssertEqual(LRUEvictionPlanner.defaultByteBudget, 10 * 1_024 * 1_024 * 1_024)
    }

    func testNothingIsEvictedUnderBudget() {
        let entries = [entry("a", bytes: 100, minutesAgo: 10), entry("b", bytes: 100, minutesAgo: 5)]
        XCTAssertEqual(LRUEvictionPlanner.keysToEvict(entries: entries, byteBudget: 1_000), [])
    }

    func testNothingIsEvictedExactlyAtBudget() {
        let entries = [entry("a", bytes: 500, minutesAgo: 10), entry("b", bytes: 500, minutesAgo: 5)]
        XCTAssertEqual(LRUEvictionPlanner.keysToEvict(entries: entries, byteBudget: 1_000), [])
    }

    func testOldestEntriesGoFirst() {
        let entries = [
            entry("newest", bytes: 400, minutesAgo: 1),
            entry("oldest", bytes: 400, minutesAgo: 30),
            entry("middle", bytes: 400, minutesAgo: 15)
        ]
        let plan = LRUEvictionPlanner.keysToEvict(entries: entries, byteBudget: 800)
        XCTAssertEqual(plan, [CacheKey("oldest")])
    }

    func testEvictsUntilItFitsAndNoFurther() {
        let entries = (0..<10).map { entry("e\($0)", bytes: 100, minutesAgo: 100 - $0) }
        let plan = LRUEvictionPlanner.keysToEvict(entries: entries, byteBudget: 550)
        // 1000 bytes down to 550 needs 5 entries gone; a 6th would be waste.
        XCTAssertEqual(plan.count, 5)
        XCTAssertEqual(plan.first, CacheKey("e0"))
    }

    func testPinnedEntriesSurviveEvenWhenTheyAreTheOldest() {
        // Spec §8.3: the photo on screen or being exported must not be evicted
        // out from under the work using it.
        let entries = [
            entry("onScreen", bytes: 400, minutesAgo: 60),
            entry("cold", bytes: 400, minutesAgo: 30),
            entry("warm", bytes: 400, minutesAgo: 1)
        ]
        let plan = LRUEvictionPlanner.keysToEvict(
            entries: entries,
            byteBudget: 800,
            pinned: [CacheKey("onScreen")]
        )
        XCTAssertEqual(plan, [CacheKey("cold")])
    }

    func testStaysOverBudgetRatherThanEvictingPinnedWork() {
        // A stalled render is worse than a temporarily oversized cache.
        let entries = [
            entry("a", bytes: 900, minutesAgo: 60),
            entry("b", bytes: 900, minutesAgo: 30)
        ]
        let plan = LRUEvictionPlanner.keysToEvict(
            entries: entries,
            byteBudget: 100,
            pinned: [CacheKey("a"), CacheKey("b")]
        )
        XCTAssertEqual(plan, [])
    }

    func testPlanIsDeterministicWhenTimestampsCollide() {
        // A fast disk produces identical timestamps constantly.
        let entries = ["c", "a", "b"].map { entry($0, bytes: 400, minutesAgo: 5) }
        let plan = LRUEvictionPlanner.keysToEvict(entries: entries, byteBudget: 800)
        XCTAssertEqual(plan, [CacheKey("a")])
        XCTAssertEqual(
            LRUEvictionPlanner.keysToEvict(entries: entries.reversed(), byteBudget: 800),
            plan
        )
    }

    func testZeroBudgetEvictsEverythingUnpinned() {
        let entries = [entry("a", bytes: 10, minutesAgo: 2), entry("b", bytes: 10, minutesAgo: 1)]
        let plan = LRUEvictionPlanner.keysToEvict(entries: entries, byteBudget: 0)
        XCTAssertEqual(Set(plan), [CacheKey("a"), CacheKey("b")])
    }

    func testEmptyCacheProducesAnEmptyPlan() {
        XCTAssertEqual(LRUEvictionPlanner.keysToEvict(entries: [], byteBudget: 0), [])
    }

    // MARK: - Cache keys

    func testThumbnailKeysAreDistinctPerPhotoAndSize() {
        let first = PhotoID()
        let second = PhotoID()
        XCTAssertNotEqual(
            CacheKey.thumbnail(photoID: first, pixelDimension: 512),
            CacheKey.thumbnail(photoID: second, pixelDimension: 512)
        )
        XCTAssertNotEqual(
            CacheKey.thumbnail(photoID: first, pixelDimension: 512),
            CacheKey.thumbnail(photoID: first, pixelDimension: 256)
        )
    }

    func testThumbnailKeyCarriesAFormatVersion() {
        // Addendum §3.2: changing the thumbnail encoding must be able to
        // invalidate every cached file at once.
        let key = CacheKey.thumbnail(photoID: PhotoID(), pixelDimension: 512)
        XCTAssertTrue(key.rawValue.contains("v\(CacheKey.thumbnailFormatVersion)"), key.rawValue)
    }

    func testKeyFilenamesAreSafeOnDisk() {
        XCTAssertFalse(CacheKey("a/b:c").filename.contains("/"))
        XCTAssertFalse(CacheKey("a/b:c").filename.contains(":"))
    }
}
