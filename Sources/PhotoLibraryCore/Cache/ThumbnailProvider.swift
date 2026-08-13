import CoreImage
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
            return "This photo hasn't been cached yet and its drive isn't connected."
        case .decoding(let error):
            return error.errorDescription
        case .renderFailed:
            return "The thumbnail couldn't be rendered."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unavailableOffline:
            return "Reconnect the drive to generate a thumbnail."
        case .decoding(let error):
            return error.recoverySuggestion
        case .renderFailed:
            return "Try again."
        }
    }
}

/// Cached grid thumbnails.
///
/// Spec §6.1 requires an offline library to keep showing its cached thumbnails,
/// so the cache is checked before the drive is ever touched — that check is also
/// what meets the 300 ms budget in spec §11.
public actor ThumbnailProvider {
    public static let defaultPixelDimension = 512

    private let cache: DiskCache
    private let decoder: any RawDecoding
    private let pipeline: AdjustmentPipeline
    private let renderService: ImageRenderService
    private let pixelDimension: Int
    private let jpegQuality: Double

    /// Coalesces concurrent requests for the same photo, which a fast scroll
    /// produces constantly.
    private var inFlight: [CacheKey: Task<Data, Error>] = [:]

    public init(
        cache: DiskCache,
        decoder: any RawDecoding = CoreImageRawDecoder(),
        pipeline: AdjustmentPipeline = AdjustmentPipeline(),
        renderService: ImageRenderService = ImageRenderService(),
        pixelDimension: Int = ThumbnailProvider.defaultPixelDimension,
        jpegQuality: Double = 0.8
    ) {
        self.cache = cache
        self.decoder = decoder
        self.pipeline = pipeline
        self.renderService = renderService
        self.pixelDimension = pixelDimension
        self.jpegQuality = jpegQuality
    }

    public func cacheKey(for photoID: PhotoID) -> CacheKey {
        CacheKey.thumbnail(photoID: photoID, pixelDimension: pixelDimension)
    }

    /// Cached JPEG bytes if present, without touching the source drive.
    public func cachedThumbnailData(for photoID: PhotoID) async -> Data? {
        await cache.data(for: cacheKey(for: photoID))
    }

    /// Cached bytes, or a freshly rendered thumbnail from the original.
    ///
    /// `adjustments` is applied so an edited photo's grid cell matches what the
    /// editor shows.
    public func thumbnailData(
        for photoID: PhotoID,
        sourceURL: URL,
        adjustments: PhotoAdjustments = .neutral,
        isOnline: Bool = true
    ) async throws -> Data {
        let key = cacheKey(for: photoID)
        if let cached = await cache.data(for: key) {
            return cached
        }
        guard isOnline else {
            throw ThumbnailError.unavailableOffline(photoID)
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let decoder = self.decoder
        let pipeline = self.pipeline
        let renderService = self.renderService
        let pixelDimension = self.pixelDimension
        let jpegQuality = self.jpegQuality

        let task = Task<Data, Error> {
            // Spec §11: decoding never runs on the main thread.
            try await Task.detached(priority: .utility) { () -> Data in
                let parameters = AdjustmentMapping.renderParameters(for: adjustments)
                let decoded = try decoder.decode(RawDecodeRequest(
                    url: sourceURL,
                    quality: .thumbnail(maximumPixelDimension: pixelDimension),
                    whiteBalance: parameters.whiteBalance
                ))
                let adjusted = pipeline.apply(parameters, to: decoded.image)
                return try renderService.jpegData(from: adjusted, quality: jpegQuality)
            }.value
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        do {
            let data = try await task.value
            // A cache write failure is not the user's problem — the thumbnail is
            // already rendered, it just won't survive a relaunch.
            _ = try? await cache.store(data, for: key)
            return data
        } catch let error as RawDecodingError {
            throw ThumbnailError.decoding(error)
        } catch let error as ImageRenderError where error == .renderFailed {
            throw ThumbnailError.renderFailed
        }
    }

    public func invalidate(photoID: PhotoID) async {
        await cache.remove(cacheKey(for: photoID))
    }

    /// Keeps a thumbnail alive while its cell is visible (spec §8.3).
    public func pin(photoID: PhotoID) async {
        await cache.pin(cacheKey(for: photoID))
    }

    public func unpin(photoID: PhotoID) async {
        await cache.unpin(cacheKey(for: photoID))
    }
}
