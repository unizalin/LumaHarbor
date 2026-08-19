import CoreImage
import Localization
import Foundation
import RawProcessingCore

public enum ThumbnailError: Error, Equatable, Sendable {
    /// Not cached and the drive holding the original isn't connected.
    case unavailableOffline(PhotoID)
    case decoding(RawDecodingError)
    case renderFailed
}

extension ThumbnailError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailableOffline:
            return L10n.t("This photo hasn't been cached yet and its drive isn't connected.")
        case .decoding(let error):
            return error.errorDescription
        case .renderFailed:
            return L10n.t("The thumbnail couldn't be rendered.")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unavailableOffline:
            return L10n.t("Reconnect the drive to generate a thumbnail.")
        case .decoding(let error):
            return error.recoverySuggestion
        case .renderFailed:
            return L10n.t("Try again.")
        }
    }
}

/// Observable counters.
///
/// Addendum §3.4 requires a failed cache write to stay visible rather than
/// being silently reported as cached. There is no UI warning channel in this
/// stage, so it surfaces here — and the same counters let tests assert "decoded
/// exactly once" without reaching into private state.
public struct ThumbnailDiagnostics: Sendable, Equatable {
    public var cacheHits = 0
    public var decodes = 0
    public var stores = 0
    /// Results that came back after an invalidate or a cancel, and were dropped
    /// rather than written back.
    public var staleResultsDiscarded = 0
    /// Set when the bytes were produced but couldn't be persisted — the
    /// thumbnail still displays, it just won't survive a relaunch.
    public var lastCacheWriteFailure: String?

    public init() {}
}

/// Cached grid thumbnails.
///
/// Spec §6.1 requires an offline library to keep showing its cached thumbnails,
/// so the cache is checked before the drive is ever touched — that check is also
/// what meets the 300 ms budget in spec §11.
///
/// Addendum §3.2 fixes the MVP definition of a grid thumbnail: the **neutral**
/// render of the source RAW, with no sidecar adjustments applied. Whether a
/// photo has edits is shown by the badge, not by the pixels. That is why this
/// type takes no `PhotoAdjustments` and owns no `AdjustmentPipeline` — an
/// adjustment input with a cache key that ignores it is how one photo's edited
/// thumbnail ends up permanently standing in for another's.
public actor ThumbnailProvider {
    public static let defaultPixelDimension = 512

    private let cache: DiskCache
    private let decoder: any RawDecoding
    private let renderService: ImageRenderService
    private let pixelDimension: Int
    private let jpegQuality: Double

    /// One in-flight render, shared by every caller that wants the same key.
    private struct Producer {
        let generation: UInt64
        let task: Task<Data, Error>
        var waiters: Set<UInt64>
    }

    /// Identifies one caller's stake in a producer, so a single cancelled
    /// scroll cell can't take down a render the rest of the grid still wants.
    private struct WaiterTicket: Sendable {
        let key: CacheKey
        let generation: UInt64
        let waiterID: UInt64
        let task: Task<Data, Error>
    }

    private var producers: [CacheKey: Producer] = [:]
    private var generationCounter: UInt64 = 0
    private var waiterCounter: UInt64 = 0

    public private(set) var diagnostics = ThumbnailDiagnostics()

    public init(
        cache: DiskCache,
        decoder: any RawDecoding = CoreImageRawDecoder(),
        renderService: ImageRenderService = ImageRenderService(),
        pixelDimension: Int = ThumbnailProvider.defaultPixelDimension,
        jpegQuality: Double = 0.8
    ) {
        self.cache = cache
        self.decoder = decoder
        self.renderService = renderService
        self.pixelDimension = pixelDimension
        self.jpegQuality = jpegQuality
    }

    public nonisolated func cacheKey(for photoID: PhotoID) -> CacheKey {
        CacheKey.thumbnail(photoID: photoID, pixelDimension: pixelDimension)
    }

    /// Cached JPEG bytes if present, without touching the source drive.
    public func cachedThumbnailData(for photoID: PhotoID) async -> Data? {
        let data = await cache.data(for: cacheKey(for: photoID))
        if data != nil { diagnostics.cacheHits += 1 }
        return data
    }

    /// Cached bytes, or a freshly rendered neutral thumbnail from the original.
    public func thumbnailData(
        for photoID: PhotoID,
        sourceURL: URL,
        isOnline: Bool = true
    ) async throws -> Data {
        let key = cacheKey(for: photoID)

        // Spec §6.1: the cache answers before anything looks at the drive, so an
        // unplugged library still fills its grid — and the decoder is never
        // consulted on a hit.
        if let cached = await cache.data(for: key) {
            diagnostics.cacheHits += 1
            return cached
        }
        guard isOnline else {
            throw ThumbnailError.unavailableOffline(photoID)
        }

        let ticket = attachWaiter(key: key, sourceURL: sourceURL)

        let outcome: Result<Data, Error>
        do {
            let data = try await withTaskCancellationHandler {
                try await ticket.task.value
            } onCancel: {
                // Leaving is what decides whether the render carries on for the
                // other waiters or stops because nobody wants it any more.
                Task { await self.detachWaiter(ticket) }
            }
            outcome = .success(data)
        } catch {
            outcome = .failure(error)
        }

        detachWaiter(ticket)

        // A cancelled caller gets a cancellation, never bytes — even when the
        // shared producer finished successfully for somebody else.
        try Task.checkCancellation()

        switch outcome {
        case .success(let data):
            return data
        case .failure(let error):
            throw Self.mapError(error)
        }
    }

    /// Drops the cached bytes and makes sure nothing in flight can put them back.
    public func invalidate(photoID: PhotoID) async {
        let key = cacheKey(for: photoID)
        if let producer = producers[key] {
            // This render started before the invalidation, so its pixels are
            // stale by definition. Detaching it from `producers` is what stops
            // `storeIfCurrent` accepting the result later, even if the decoder
            // ignores the cancel and returns normally.
            producer.task.cancel()
            producers[key] = nil
        }
        await cache.remove(key)
    }

    /// Stops every in-flight render. For teardown, or when the library goes away.
    public func cancelAll() {
        for (_, producer) in producers {
            producer.task.cancel()
        }
        producers.removeAll()
    }

    public var inFlightCount: Int { producers.count }

    /// How many callers are currently waiting on the shared render for
    /// `photoID`.
    ///
    /// Test observability only, and `internal` so it stays out of the public
    /// surface. `inFlightCount` counts *producers*, which can't distinguish
    /// "one render, one waiter" from "one render, three waiters" — and the
    /// coalescing and per-waiter cancellation rules in addendum §3.3 are
    /// entirely about that difference. Without it a test has to guess when the
    /// second waiter attached, which is exactly the kind of sleep-based
    /// guessing the addendum rules out.
    func waiterCount(for photoID: PhotoID) -> Int {
        producers[cacheKey(for: photoID)]?.waiters.count ?? 0
    }

    /// Keeps a thumbnail alive while its cell is visible (spec §8.3).
    /// Safe to call before the entry exists — the pin applies to whatever is
    /// stored under the key later.
    public func pin(photoID: PhotoID) async {
        await cache.pin(cacheKey(for: photoID))
    }

    public func unpin(photoID: PhotoID) async {
        await cache.unpin(cacheKey(for: photoID))
    }

    public func resetDiagnostics() {
        diagnostics = ThumbnailDiagnostics()
    }

    // MARK: - Producer lifecycle

    private func attachWaiter(key: CacheKey, sourceURL: URL) -> WaiterTicket {
        waiterCounter += 1
        let waiterID = waiterCounter

        if var existing = producers[key] {
            // Spec addendum §3.3: many waiters, at most one decode.
            existing.waiters.insert(waiterID)
            producers[key] = existing
            return WaiterTicket(
                key: key,
                generation: existing.generation,
                waiterID: waiterID,
                task: existing.task
            )
        }

        generationCounter += 1
        let generation = generationCounter
        diagnostics.decodes += 1
        let task = makeProducerTask(key: key, sourceURL: sourceURL, generation: generation)
        producers[key] = Producer(generation: generation, task: task, waiters: [waiterID])
        return WaiterTicket(key: key, generation: generation, waiterID: waiterID, task: task)
    }

    /// Idempotent: it runs both from the cancellation handler and on the normal
    /// path, and the generation check keeps an old ticket from disturbing a
    /// newer producer under the same key.
    private func detachWaiter(_ ticket: WaiterTicket) {
        guard var producer = producers[ticket.key],
              producer.generation == ticket.generation else { return }

        producer.waiters.remove(ticket.waiterID)
        if producer.waiters.isEmpty {
            producer.task.cancel()
            producers[ticket.key] = nil
        } else {
            producers[ticket.key] = producer
        }
    }

    private func makeProducerTask(
        key: CacheKey,
        sourceURL: URL,
        generation: UInt64
    ) -> Task<Data, Error> {
        let decoder = self.decoder
        let renderService = self.renderService
        let pixelDimension = self.pixelDimension
        let jpegQuality = self.jpegQuality

        return Task {
            // Spec §11: decoding never runs on the main thread. `runOffActor`
            // rather than a bare `Task.detached` so cancellation actually
            // reaches the decode.
            let data = try await runOffActor(priority: .utility) { () -> Data in
                try Task.checkCancellation()
                let decoded = try decoder.decode(RawDecodeRequest(
                    url: sourceURL,
                    quality: .thumbnail(maximumPixelDimension: pixelDimension)
                ))
                try Task.checkCancellation()
                return try renderService.jpegData(from: decoded.image, quality: jpegQuality)
            }

            try Task.checkCancellation()
            await self.storeIfCurrent(data, key: key, generation: generation)
            return data
        }
    }

    /// Writes the bytes back only if this render is still the one the provider
    /// is waiting on. An `invalidate` or a last-waiter cancel removes the
    /// producer entry, and that absence is what rejects a late result — no
    /// cooperation required from the decoder.
    private func storeIfCurrent(_ data: Data, key: CacheKey, generation: UInt64) async {
        guard producers[key]?.generation == generation else {
            diagnostics.staleResultsDiscarded += 1
            return
        }
        do {
            try await cache.store(data, for: key)
            diagnostics.stores += 1
            diagnostics.lastCacheWriteFailure = nil
        } catch {
            // The thumbnail is already rendered and will still be shown; it just
            // won't survive a relaunch. Recorded rather than swallowed so
            // "disk full" doesn't look like a silent success.
            diagnostics.lastCacheWriteFailure =
                (error as? LocalizedError)?.errorDescription
                    ?? (error as NSError).localizedDescription
        }
    }

    /// Keeps internal render/encode failures from leaking to the UI as
    /// something it has no next step for (addendum §3.3).
    private static func mapError(_ error: Error) -> Error {
        switch error {
        case let error as ThumbnailError:
            return error
        case let error as RawDecodingError:
            return ThumbnailError.decoding(error)
        case is ImageRenderError:
            return ThumbnailError.renderFailed
        case is CancellationError:
            return error
        default:
            return error
        }
    }
}
