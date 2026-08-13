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

    public init(
        decoder: any RawDecoding = CoreImageRawDecoder(),
        pipeline: AdjustmentPipeline = AdjustmentPipeline(),
        renderService: ImageRenderService = ImageRenderService()
    ) {
        self.decoder = decoder
        self.pipeline = pipeline
        self.renderService = renderService
    }

    public func render(_ request: PreviewRequest) async throws -> PreviewImage {
        try Task.checkCancellation()

        let parameters = AdjustmentMapping.renderParameters(for: request.adjustments)
        let decodeRequest = RawDecodeRequest(
            url: request.url,
            quality: request.decodeQuality,
            whiteBalance: parameters.whiteBalance
        )

        // Spec §11: never decode, hash or encode on the main thread.
        let decoder = self.decoder
        let pipeline = self.pipeline
        let renderService = self.renderService

        return try await Task.detached(priority: request.quality == .interactive ? .userInitiated : .utility) {
            try Task.checkCancellation()
            let decoded = try decoder.decode(decodeRequest)

            try Task.checkCancellation()
            let adjusted = pipeline.apply(parameters, to: decoded.image)

            try Task.checkCancellation()
            let cgImage = try renderService.makeCGImage(adjusted)

            return PreviewImage(
                cgImage: cgImage,
                pixelSize: CGSize(width: cgImage.width, height: cgImage.height)
            )
        }.value
    }
}
