import Foundation

/// Bounded, invalidation-safe cache for decoded interactive/high-quality
/// previews. The cache stores only the decoder result; global and local
/// adjustments remain request-specific and are always rebuilt.
internal actor DecodedPreviewCache {
    internal struct Key: Hashable, Sendable {
        let standardizedPath: String
        let fileResourceIdentifier: String?
        let fileSize: Int64?
        let modificationTime: TimeInterval?
        let generationIdentifier: String?
        let decoderIdentifier: DecoderIdentifier
        let quality: DecodeQuality
        let whiteBalance: RawWhiteBalance
        let lensCorrection: LensCorrectionAdjustments
        let rawRenderingCompatibility: RawRenderingCompatibility
        let cameraProfileRequest: RawCameraProfileRequest?
        let resolvedRecipe: ResolvedRawRenderRecipe

        static func make(
            request: RawDecodeRequest,
            decoderIdentifier: DecoderIdentifier,
            resolvedRecipe: ResolvedRawRenderRecipe
        ) -> Self? {
            guard request.quality.maximumPixelDimension != nil else { return nil }
            let values: URLResourceValues?
            values = try? request.url.resourceValues(forKeys: [
                .fileResourceIdentifierKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .generationIdentifierKey
            ])
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: request.url.standardizedFileURL.path
            )
            let attributeSize = (attributes?[.size] as? NSNumber)?.int64Value
            let attributeModificationTime = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate
            let attributeGeneration = attributes?[.systemFileNumber].map { String(describing: $0) }
            return Self(
                standardizedPath: request.url.standardizedFileURL.path,
                fileResourceIdentifier: values?.fileResourceIdentifier.map { String(describing: $0) },
                fileSize: attributeSize ?? values?.fileSize.map(Int64.init),
                modificationTime: attributeModificationTime ?? values?.contentModificationDate?.timeIntervalSinceReferenceDate,
                generationIdentifier: values?.generationIdentifier.map { String(describing: $0) } ?? attributeGeneration,
                decoderIdentifier: decoderIdentifier,
                quality: request.quality,
                whiteBalance: request.whiteBalance,
                lensCorrection: request.lensCorrection,
                rawRenderingCompatibility: request.rawRenderingCompatibility,
                cameraProfileRequest: request.cameraProfileRequest,
                resolvedRecipe: resolvedRecipe
            )
        }
    }

    private struct Entry {
        let image: DecodedRawImage
        let cost: Int64
        var lastUse: UInt64
    }

    private let maxEntries: Int
    private let maxCost: Int64
    private var clock: UInt64 = 0
    private var entries: [Key: Entry] = [:]
    private var totalCost: Int64 = 0

    init(maxEntries: Int = 4, maxCost: Int64 = 64 * 1_024 * 1_024) {
        self.maxEntries = max(1, maxEntries)
        self.maxCost = max(1, maxCost)
    }

    func value(for key: Key) -> DecodedRawImage? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.lastUse = clock
        entries[key] = entry
        return entry.image
    }

    func insert(_ image: DecodedRawImage, for key: Key) {
        let width = max(Int64(image.decodedPixelSize.width.rounded(.up)), 1)
        let height = max(Int64(image.decodedPixelSize.height.rounded(.up)), 1)
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else { return }
        let (cost, costOverflow) = pixelCount.multipliedReportingOverflow(by: 16)
        guard !costOverflow, cost <= maxCost else { return }

        if let old = entries.removeValue(forKey: key) {
            totalCost -= old.cost
        }
        clock &+= 1
        entries[key] = Entry(image: image, cost: cost, lastUse: clock)
        totalCost += cost
        evictIfNeeded()
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: true)
        totalCost = 0
    }

    private func evictIfNeeded() {
        while entries.count > maxEntries || totalCost > maxCost {
            guard let victim = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
            totalCost -= victim.value.cost
            entries.removeValue(forKey: victim.key)
        }
    }
}
