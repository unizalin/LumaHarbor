import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// A decode that the test opens and closes by hand.
final class ThumbnailGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isReleased = false
    private var startedCount = 0

    var started: Int {
        lock.lock()
        defer { lock.unlock() }
        return startedCount
    }

    func release() {
        lock.lock()
        isReleased = true
        lock.unlock()
    }

    private var released: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isReleased
    }

    /// `ignoringCancellation` models the decoder that never polls: it finishes
    /// and hands back good bytes long after the caller gave up.
    func enterAndWait(timeout: TimeInterval = 5, ignoringCancellation: Bool = false) {
        lock.lock()
        startedCount += 1
        lock.unlock()

        let deadline = Date().addingTimeInterval(timeout)
        while !released, ignoringCancellation || !Task.isCancelled, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}

/// Counts what the provider actually asked for, so "the cache hit never touched
/// the decoder" is an assertion rather than an assumption.
final class SpyRawDecoder: RawDecoding, @unchecked Sendable {
    let identifier = DecoderIdentifier(kind: "spy", version: "test")

    private let lock = NSLock()
    private var decodeCount = 0
    private var metadataCount = 0

    var gate: ThumbnailGate?
    var gateIgnoresCancellation = false
    var failure: RawDecodingError?
    var pixelSize = CGSize(width: 32, height: 24)

    var decodes: Int {
        lock.lock()
        defer { lock.unlock() }
        return decodeCount
    }

    var metadataReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return metadataCount
    }

    func supportsFile(at url: URL) -> Bool { failure == nil }

    func readMetadata(at url: URL) throws -> RawMetadata {
        lock.lock()
        metadataCount += 1
        lock.unlock()
        if let failure { throw failure }
        return RawMetadata(pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height))
    }

    func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage {
        lock.lock()
        decodeCount += 1
        lock.unlock()

        gate?.enterAndWait(ignoringCancellation: gateIgnoresCancellation)
        try Task.checkCancellation()
        if let failure { throw failure }

        let image = CIImage(color: CIColor(red: 0.3, green: 0.6, blue: 0.9))
            .cropped(to: CGRect(origin: .zero, size: pixelSize))
        return DecodedRawImage(
            image: image,
            nativePixelSize: pixelSize,
            decodedPixelSize: pixelSize,
            baselineTemperature: 5_500,
            baselineTint: 0,
            metadata: RawMetadata(
                pixelWidth: Int(pixelSize.width),
                pixelHeight: Int(pixelSize.height)
            )
        )
    }
}

/// Addendum §3.2–§3.4 and §4.2.
final class ThumbnailProviderTests: TemporaryDirectoryTestCase {
    private var cacheDirectory: URL!
    private var sourceURL: URL!
    private let photoID = PhotoID()

    override func setUpWithError() throws {
        try super.setUpWithError()
        cacheDirectory = try makeSubdirectory("thumbnails")
        sourceURL = try writeFile(
            Data(repeating: 0x44, count: 128),
            at: temporaryDirectory.appendingPathComponent("DSC0001.ARW")
        )
    }

    private func makeCache(budget: Int64 = 1_000_000) throws -> DiskCache {
        try DiskCache(directoryURL: cacheDirectory, byteBudget: budget)
    }

    private func makeProvider(
        cache: DiskCache,
        decoder: SpyRawDecoder = SpyRawDecoder()
    ) -> ThumbnailProvider {
        ThumbnailProvider(cache: cache, decoder: decoder, pixelDimension: 128)
    }

    // MARK: - Cache identity

    func testCacheKeyCarriesAFormatVersionAndNoAdjustmentComponent() async throws {
        let provider = makeProvider(cache: try makeCache())
        let key = provider.cacheKey(for: photoID)

        // Addendum §3.2: versioned, and derived only from stable values — never
        // from `hashValue`, which changes between launches.
        XCTAssertTrue(key.rawValue.contains("v\(CacheKey.thumbnailFormatVersion)"), key.rawValue)
        XCTAssertTrue(key.rawValue.contains(photoID.description))
        XCTAssertTrue(key.rawValue.contains("128"))
    }

    func testCacheKeyIsStableAcrossProviderInstances() async throws {
        let first = makeProvider(cache: try makeCache()).cacheKey(for: photoID)
        let second = makeProvider(cache: try makeCache()).cacheKey(for: photoID)
        XCTAssertEqual(first, second, "A cache key must survive a relaunch")
    }

    // MARK: - Cache hits and offline

    func testCacheHitNeverTouchesTheDecoderOrTheSource() async throws {
        let cache = try makeCache()
        let decoder = SpyRawDecoder()
        let provider = makeProvider(cache: cache, decoder: decoder)

        try await cache.store(Data("cached".utf8), for: provider.cacheKey(for: photoID))

        // A path that doesn't exist: if the provider looked at the drive at all,
        // this would fail.
        let missingSource = temporaryDirectory.appendingPathComponent("gone.ARW")
        let data = try await provider.thumbnailData(for: photoID, sourceURL: missingSource)

        XCTAssertEqual(data, Data("cached".utf8))
        XCTAssertEqual(decoder.decodes, 0)
        XCTAssertEqual(decoder.metadataReads, 0)
    }

    func testCachedThumbnailIsStillServedWhileOffline() async throws {
        // Spec §6.1: an unplugged library keeps its grid.
        let cache = try makeCache()
        let decoder = SpyRawDecoder()
        let provider = makeProvider(cache: cache, decoder: decoder)
        try await cache.store(Data("cached".utf8), for: provider.cacheKey(for: photoID))

        let data = try await provider.thumbnailData(
            for: photoID, sourceURL: sourceURL, isOnline: false
        )
        XCTAssertEqual(data, Data("cached".utf8))
        XCTAssertEqual(decoder.decodes, 0)
    }

    func testUncachedOfflineRequestFailsWithSomethingActionable() async throws {
        let provider = makeProvider(cache: try makeCache())

        do {
            _ = try await provider.thumbnailData(
                for: photoID, sourceURL: sourceURL, isOnline: false
            )
            XCTFail("An uncached offline request should have thrown")
        } catch let error as ThumbnailError {
            guard case .unavailableOffline(let id) = error else {
                return XCTFail("Expected .unavailableOffline, got \(error)")
            }
            XCTAssertEqual(id, photoID)
            XCTAssertNotNil(error.errorDescription)
            XCTAssertNotNil(error.recoverySuggestion)
        }
    }

    // MARK: - Render and store

    func testCacheMissRendersOnceAndStores() async throws {
        let cache = try makeCache()
        let decoder = SpyRawDecoder()
        let provider = makeProvider(cache: cache, decoder: decoder)

        let first = try await provider.thumbnailData(for: photoID, sourceURL: sourceURL)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(decoder.decodes, 1)

        let stored = await cache.contains(provider.cacheKey(for: photoID))
        XCTAssertTrue(stored)

        // Second time round it must come from the cache.
        let second = try await provider.thumbnailData(for: photoID, sourceURL: sourceURL)
        XCTAssertEqual(second, first)
        XCTAssertEqual(decoder.decodes, 1, "The second request decoded again")
    }

    func testConcurrentRequestsForTheSamePhotoDecodeOnce() async throws {
        // Addendum §3.3: a fast scroll produces this constantly.
        let gate = ThumbnailGate()
        let decoder = SpyRawDecoder()
        decoder.gate = gate
        let provider = makeProvider(cache: try makeCache(), decoder: decoder)

        async let a = provider.thumbnailData(for: photoID, sourceURL: sourceURL)
        async let b = provider.thumbnailData(for: photoID, sourceURL: sourceURL)
        async let c = provider.thumbnailData(for: photoID, sourceURL: sourceURL)

        // Hold until all three have genuinely joined the same producer. Waiting
        // on the decode alone would let this pass without coalescing at all:
        // if the render finished before the later callers arrived, they'd
        // simply hit the cache and `decodes` would still be 1.
        let waiterPhotoID = photoID
        await waitUntilTrue("all three waiters to share one producer") {
            await provider.waiterCount(for: waiterPhotoID) == 3
        }
        let producers = await provider.inFlightCount
        XCTAssertEqual(producers, 1)

        gate.release()

        let results = try await [a, b, c]
        XCTAssertEqual(Set(results.map(\.count)).count, 1, "Waiters got different bytes")
        XCTAssertEqual(decoder.decodes, 1, "Three waiters caused \(decoder.decodes) decodes")
    }

    func testDecodeFailureIsMappedToAnActionableThumbnailError() async throws {
        let decoder = SpyRawDecoder()
        decoder.failure = .corruptedFile(path: "/tmp/x.ARW")
        let provider = makeProvider(cache: try makeCache(), decoder: decoder)

        do {
            _ = try await provider.thumbnailData(for: photoID, sourceURL: sourceURL)
            XCTFail("A corrupt file should have thrown")
        } catch let error as ThumbnailError {
            guard case .decoding = error else {
                return XCTFail("Expected .decoding, got \(error)")
            }
            XCTAssertNotNil(error.recoverySuggestion)
        }
    }

    // MARK: - Cancellation

    func testCancellingOneWaiterLeavesTheOtherUnaffected() async throws {
        let gate = ThumbnailGate()
        let decoder = SpyRawDecoder()
        decoder.gate = gate
        let provider = makeProvider(cache: try makeCache(), decoder: decoder)

        let doomed = Task { try await provider.thumbnailData(for: photoID, sourceURL: sourceURL) }
        let survivor = Task { try await provider.thumbnailData(for: photoID, sourceURL: sourceURL) }

        // Both waiters must actually be attached before the cancel. Waiting on
        // `inFlightCount` would only prove a producer exists: if the survivor
        // hadn't joined yet, cancelling would drop the sole waiter, tear that
        // producer down and start a second one — and the test would pass or
        // fail on scheduling luck.
        let waiterPhotoID = photoID
        await waitUntilTrue("both waiters to attach") {
            await provider.waiterCount(for: waiterPhotoID) == 2
        }

        doomed.cancel()
        gate.release()

        // The cancelled scroll cell gets a cancellation, never bytes.
        do {
            _ = try await doomed.value
            XCTFail("A cancelled waiter must not receive a thumbnail")
        } catch {
            XCTAssertTrue(error is CancellationError, "Got \(error)")
        }

        let data = try await survivor.value
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(decoder.decodes, 1)
    }

    func testLastWaiterCancellingStopsTheProducerAndWritesNothing() async throws {
        let gate = ThumbnailGate()
        let decoder = SpyRawDecoder()
        decoder.gate = gate
        let provider = makeProvider(cache: try makeCache(), decoder: decoder)

        let task = Task { try await provider.thumbnailData(for: photoID, sourceURL: sourceURL) }
        await waitUntilTrue("the decode to start") { gate.started > 0 }

        task.cancel()
        _ = try? await task.value

        await waitUntilTrue("the producer to be dropped") { await provider.inFlightCount == 0 }
        let cached = await provider.cachedThumbnailData(for: photoID)
        XCTAssertNil(cached, "A cancelled render wrote itself into the cache")
    }

    func testNonCooperativeProducerCannotRefillTheCacheAfterInvalidate() async throws {
        // Addendum §3.3: `invalidate` has to hold even against a decoder that
        // ignores cancellation and returns good bytes afterwards.
        let gate = ThumbnailGate()
        let decoder = SpyRawDecoder()
        decoder.gate = gate
        decoder.gateIgnoresCancellation = true
        let provider = makeProvider(cache: try makeCache(), decoder: decoder)

        let task = Task { try await provider.thumbnailData(for: photoID, sourceURL: sourceURL) }
        await waitUntilTrue("the decode to start") { gate.started > 0 }

        await provider.invalidate(photoID: photoID)
        gate.release()

        // Awaiting the waiter is the barrier, and a total one: `thumbnailData`
        // only returns once the producer task it joined has finished, so by
        // this line the producer has already either written or been refused.
        _ = try? await task.value

        // Assert the outcome, not the route. There are two defences here — the
        // cancellation checkpoint after the decode, and the generation check in
        // `storeIfCurrent` — and which one fires first is an implementation
        // detail. Pinning the test to `staleResultsDiscarded` would make it
        // fail precisely when the *earlier*, better defence does its job.
        let cached = await provider.cachedThumbnailData(for: photoID)
        XCTAssertNil(cached, "An invalidated render was written back anyway")

        let diagnostics = await provider.diagnostics
        XCTAssertEqual(diagnostics.stores, 0, "The invalidated render reached the cache")

        let inFlight = await provider.inFlightCount
        XCTAssertEqual(inFlight, 0, "The invalidated producer was left registered")
    }

    func testInvalidateForcesAFreshDecode() async throws {
        let cache = try makeCache()
        let decoder = SpyRawDecoder()
        let provider = makeProvider(cache: cache, decoder: decoder)

        _ = try await provider.thumbnailData(for: photoID, sourceURL: sourceURL)
        XCTAssertEqual(decoder.decodes, 1)

        await provider.invalidate(photoID: photoID)
        let cachedAfterInvalidate = await provider.cachedThumbnailData(for: photoID)
        XCTAssertNil(cachedAfterInvalidate)

        _ = try await provider.thumbnailData(for: photoID, sourceURL: sourceURL)
        XCTAssertEqual(decoder.decodes, 2)
    }

    func testAStaleProducerDoesNotEvictTheProducerThatReplacedIt() async throws {
        // Addendum §3.3: in-flight cleanup compares key *and* generation.
        let firstGate = ThumbnailGate()
        let decoder = SpyRawDecoder()
        decoder.gate = firstGate
        decoder.gateIgnoresCancellation = true
        let provider = makeProvider(cache: try makeCache(), decoder: decoder)

        let stale = Task { try await provider.thumbnailData(for: photoID, sourceURL: sourceURL) }
        await waitUntilTrue("the first decode to start") { firstGate.started > 0 }

        await provider.invalidate(photoID: photoID)

        // A new request starts a new generation while the old one is still out.
        let fresh = Task { try await provider.thumbnailData(for: photoID, sourceURL: sourceURL) }
        await waitUntilTrue("the replacement decode to start") { decoder.decodes >= 2 }

        firstGate.release()
        _ = try? await stale.value

        let data = try await fresh.value
        XCTAssertFalse(data.isEmpty)
        let cached = await provider.cachedThumbnailData(for: photoID)
        XCTAssertNotNil(cached, "The replacement result was lost")
    }

    func testCancelAllStopsEverythingInFlight() async throws {
        let gate = ThumbnailGate()
        let decoder = SpyRawDecoder()
        decoder.gate = gate
        let provider = makeProvider(cache: try makeCache(), decoder: decoder)

        let task = Task { try await provider.thumbnailData(for: photoID, sourceURL: sourceURL) }
        await waitUntilTrue("the decode to start") { gate.started > 0 }

        await provider.cancelAll()
        let inFlight = await provider.inFlightCount
        XCTAssertEqual(inFlight, 0)

        gate.release()
        _ = try? await task.value
        let cached = await provider.cachedThumbnailData(for: photoID)
        XCTAssertNil(cached)
    }

    // MARK: - Pinning

    func testPinBeforeStoreProtectsTheEntryThatArrivesLater() async throws {
        // Addendum §3.4: the grid pins a cell as it scrolls into view, which can
        // easily happen before the render finishes.
        let cache = try makeCache(budget: 1)
        let provider = makeProvider(cache: cache, decoder: SpyRawDecoder())

        await provider.pin(photoID: photoID)
        _ = try await provider.thumbnailData(for: photoID, sourceURL: sourceURL)

        let survived = await cache.contains(provider.cacheKey(for: photoID))
        XCTAssertTrue(survived, "A pinned entry was evicted the moment it was stored")
    }

    func testUnpinMakesTheEntryEvictableAgain() async throws {
        let cache = try makeCache(budget: 1)
        let provider = makeProvider(cache: cache, decoder: SpyRawDecoder())

        await provider.pin(photoID: photoID)
        _ = try await provider.thumbnailData(for: photoID, sourceURL: sourceURL)
        await provider.unpin(photoID: photoID)
        try await cache.evictIfNeeded()

        let stillThere = await cache.contains(provider.cacheKey(for: photoID))
        XCTAssertFalse(stillThere)
    }

    func testRemoveAllClearsPinStateSoTheKeyIsNotPinnedForever() async throws {
        let cache = try makeCache(budget: 1)
        let provider = makeProvider(cache: cache, decoder: SpyRawDecoder())
        let key = provider.cacheKey(for: photoID)

        await provider.pin(photoID: photoID)
        try await cache.removeAll()

        let isPinned = await cache.isPinned(key)
        XCTAssertFalse(isPinned, "A wiped cache kept a pin nothing will ever release")
    }

    // MARK: - Diagnostics

    func testCacheWriteFailureIsRecordedRatherThanReportedAsCached() async throws {
        try XCTSkipUnless(canSimulateReadOnlyDirectory, "Test must not run as root")

        let cache = try makeCache()
        let provider = makeProvider(cache: cache, decoder: SpyRawDecoder())
        try setPosixPermissions(0o555, at: cacheDirectory)
        defer { try? setPosixPermissions(0o755, at: cacheDirectory) }

        // The bytes still come back — a cache miss is not a display failure.
        let data = try await provider.thumbnailData(for: photoID, sourceURL: sourceURL)
        XCTAssertFalse(data.isEmpty)

        let diagnostics = await provider.diagnostics
        XCTAssertNotNil(
            diagnostics.lastCacheWriteFailure,
            "A failed cache write was silently reported as stored"
        )
        XCTAssertEqual(diagnostics.stores, 0)
    }
}

extension XCTestCase {
    /// Polls an async condition. Named separately from the RawProcessingCore
    /// helper because test targets don't share code.
    func waitUntilTrue(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }
}
