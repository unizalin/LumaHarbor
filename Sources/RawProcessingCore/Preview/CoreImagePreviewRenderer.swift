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

    public init(
        decoder: any RawDecoding = CoreImageRawDecoder(),
        pipeline: AdjustmentPipeline = AdjustmentPipeline(),
        renderService: ImageRenderService = ImageRenderService()
    ) {
        self.decoder = decoder
        self.pipeline = pipeline
        self.renderService = renderService
        self.brushRenderObserverFactory = { nil }
    }

    internal init(
        decoder: any RawDecoding,
        pipeline: AdjustmentPipeline = AdjustmentPipeline(),
        renderService: ImageRenderService = ImageRenderService(),
        brushRenderObserverFactory: @escaping @Sendable () -> BrushMaskRenderObserver?
    ) {
        self.decoder = decoder
        self.pipeline = pipeline
        self.renderService = renderService
        self.brushRenderObserverFactory = brushRenderObserverFactory
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

        return try await runOffActor(
            priority: request.quality == .interactive ? .userInitiated : .utility
        ) {
            try Task.checkCancellation()
            let decoded = try decoder.decode(decodeRequest)

            try Task.checkCancellation()
            let adjusted = pipeline.apply(
                parameters,
                to: decoded.image,
                recipe: decoded.rawRenderRecipe ?? recipe,
                scaleFactor: decoded.scaleFactor
            )
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
                observer: brushRenderObserver
            )
            let withGeometry = GeometryRenderer.apply(request.adjustments.geometry, to: withBrushMasks)
            let withLocalAdjustments = LocalAdjustmentRenderer.apply(request.adjustments.localAdjustments, to: withGeometry)
            let withPreviewOptions = ProfessionalPreviewRenderer.apply(request.previewOptions, to: withLocalAdjustments)

            try Task.checkCancellation()
            let cgImage = try renderService.makeCGImage(withPreviewOptions)

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
