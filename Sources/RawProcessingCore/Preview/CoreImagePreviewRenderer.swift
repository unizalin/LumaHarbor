import CoreGraphics
import CoreImage
import Foundation

/// The production `PreviewRendering`: decode → adjust → render.
///
/// Cancellation is checked between every stage. A full-frame RAW decode is the
/// expensive part, so bailing out before it starts is what keeps rapid photo
/// switching from queueing minutes of dead work (spec §11).
public struct CoreImagePreviewRenderer: PreviewRendering {
    private let decoder: any RawDecoding
    private let pipeline: AdjustmentPipeline
    private let renderService: ImageRenderService
    private let brushRenderObserverFactory: @Sendable () -> BrushMaskRenderObserver?
    private let stageTimingObserver: @Sendable (PreviewStageTimings) -> Void
    private let decodedPreviewCache: DecodedPreviewCache

    public init(
        decoder: any RawDecoding = CoreImageRawDecoder(),
        pipeline: AdjustmentPipeline = AdjustmentPipeline(),
        renderService: ImageRenderService = ImageRenderService()
    ) {
        self.decoder = decoder
        self.pipeline = pipeline
        self.renderService = renderService
        self.brushRenderObserverFactory = { nil }
        self.stageTimingObserver = { _ in }
        self.decodedPreviewCache = DecodedPreviewCache()
    }

    internal init(
        decoder: any RawDecoding,
        pipeline: AdjustmentPipeline = AdjustmentPipeline(),
        renderService: ImageRenderService = ImageRenderService(),
        brushRenderObserverFactory: @escaping @Sendable () -> BrushMaskRenderObserver?,
        stageTimingObserver: @escaping @Sendable (PreviewStageTimings) -> Void = { _ in },
        decodedPreviewCache: DecodedPreviewCache = DecodedPreviewCache()
    ) {
        self.decoder = decoder
        self.pipeline = pipeline
        self.renderService = renderService
        self.brushRenderObserverFactory = brushRenderObserverFactory
        self.stageTimingObserver = stageTimingObserver
        self.decodedPreviewCache = decodedPreviewCache
    }

    internal init(
        decoder: any RawDecoding,
        pipeline: AdjustmentPipeline = AdjustmentPipeline(),
        renderService: ImageRenderService = ImageRenderService(),
        stageTimingObserver: @escaping @Sendable (PreviewStageTimings) -> Void
    ) {
        self.init(
            decoder: decoder,
            pipeline: pipeline,
            renderService: renderService,
            brushRenderObserverFactory: { nil },
            stageTimingObserver: stageTimingObserver
        )
    }

    /// Drops retained decoded previews after a source/library change or an
    /// explicit memory-pressure boundary. File identity is also part of every
    /// cache key, so ordinary edits naturally miss without requiring callers
    /// to remember invalidation.
    public func clearDecodedPreviewCache() async {
        await decodedPreviewCache.removeAll()
    }

    public func render(_ request: PreviewRequest) async throws -> PreviewImage {
        try Task.checkCancellation()

        let parameters = AdjustmentMapping.renderParameters(for: request.adjustments)
        let recipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(
                policy: request.adjustments.rawRenderingCompatibility,
                quality: request.decodeQuality,
                whiteBalance: parameters.whiteBalance,
                lensCorrection: request.adjustments.lensCorrection,
                cameraProfileRequest: request.cameraProfileRequest
            ),
            capabilities: RawDecoderCapabilities(decoderIdentifier: decoder.identifier)
        )
        let decodeRequest = RawDecodeRequest(
            url: request.url,
            quality: request.decodeQuality,
            whiteBalance: parameters.whiteBalance,
            lensCorrection: request.adjustments.lensCorrection,
            rawRenderingCompatibility: request.adjustments.rawRenderingCompatibility,
            cameraProfileRequest: request.cameraProfileRequest,
            rawRenderRecipe: recipe
        )

        // Spec §11: never decode, hash or encode on the main thread.
        let decoder = self.decoder
        let pipeline = self.pipeline
        let renderService = self.renderService.configured(for: recipe)
        let brushRenderObserver = brushRenderObserverFactory()
        let decodedPreviewCache = self.decodedPreviewCache
        let cacheKey = DecodedPreviewCache.Key.make(
            request: decodeRequest,
            decoderIdentifier: decoder.identifier,
            resolvedRecipe: recipe
        )

        let stageTimingObserver = self.stageTimingObserver
        return try await runOffActor(
            priority: request.quality == .interactive ? .userInitiated : .utility
        ) {
            let stageCollector = PreviewStageTimingCollector()
            let totalStart = DispatchTime.now().uptimeNanoseconds
            defer {
                var timings = PreviewStageTimings()
                timings.rawDecode = stageCollector.duration(for: .rawDecode)
                timings.globalAdjustmentGraph = stageCollector.duration(for: .globalAdjustmentGraph)
                timings.validationSampling = stageCollector.duration(for: .validationSampling)
                timings.coverageRaster = stageCollector.duration(for: .coverageRaster)
                timings.perMaskAdjustmentBlend = stageCollector.duration(for: .perMaskAdjustmentBlend)
                timings.finalMakeCGImage = stageCollector.duration(for: .finalMakeCGImage)
                timings.totalMaterialized = Double(
                    DispatchTime.now().uptimeNanoseconds - totalStart
                ) / 1_000_000_000
                stageTimingObserver(timings)
            }
            try Task.checkCancellation()
            let decodeStart = DispatchTime.now().uptimeNanoseconds
            let decoded: DecodedRawImage
            if let cacheKey, let cached = await decodedPreviewCache.value(for: cacheKey) {
                decoded = cached
            } else {
                decoded = try decoder.decode(decodeRequest)
                if let cacheKey {
                    await decodedPreviewCache.insert(decoded, for: cacheKey)
                }
            }
            stageCollector.record(.rawDecode, start: decodeStart, end: DispatchTime.now().uptimeNanoseconds)

            try Task.checkCancellation()
            let globalStart = DispatchTime.now().uptimeNanoseconds
            let adjusted = pipeline.apply(
                parameters,
                to: decoded.image,
                recipe: decoded.rawRenderRecipe ?? recipe,
                scaleFactor: decoded.scaleFactor
            )
            stageCollector.record(.globalAdjustmentGraph, start: globalStart, end: DispatchTime.now().uptimeNanoseconds)
            let brushMapping: BrushCoordinateMapping? = try GeometryRenderer.brushCoordinateMapping(
                sourceExtent: decoded.image.extent,
                geometry: request.adjustments.geometry
            )
            let withBrushMasks = try await BrushMaskRenderer._applyValidatedAsync(
                request.adjustments.brushMasks,
                to: adjusted,
                mapping: brushMapping,
                recipe: decoded.rawRenderRecipe ?? recipe,
                scaleFactor: decoded.scaleFactor,
                observer: brushRenderObserver,
                stageIntervalObserver: { interval in stageCollector.record(interval) }
            )
            let withGeometry = GeometryRenderer.apply(request.adjustments.geometry, to: withBrushMasks)
            let withLocalAdjustments = LocalAdjustmentRenderer.apply(request.adjustments.localAdjustments, to: withGeometry)
            let withPreviewOptions = ProfessionalPreviewRenderer.apply(request.previewOptions, to: withLocalAdjustments)

            try Task.checkCancellation()
            let materializeStart = DispatchTime.now().uptimeNanoseconds
            let cgImage = try renderService.makeCGImage(withPreviewOptions)
            stageCollector.record(.finalMakeCGImage, start: materializeStart, end: DispatchTime.now().uptimeNanoseconds)

            return PreviewImage(
                cgImage: cgImage,
                pixelSize: CGSize(width: cgImage.width, height: cgImage.height),
                whiteBalanceBaseline: RawWhiteBalanceBaseline(
                    temperatureKelvin: decoded.baselineTemperature,
                    tint: decoded.baselineTint
                ),
                rawRenderRecipe: decoded.rawRenderRecipe ?? recipe,
                brushCoordinateMapping: brushMapping
            )
        }
    }
}
