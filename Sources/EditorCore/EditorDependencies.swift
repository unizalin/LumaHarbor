import CoreGraphics
import Foundation
import PhotoLibraryCore
import RawProcessingCore

public struct EditorDependencies: Sendable {
    public let previewScheduler: PreviewScheduler
    public let previewRenderer: any PreviewRendering
    public let loadAdjustments: @Sendable (PhotoAsset) async throws -> PhotoAdjustments
    public let saveAdjustments: @Sendable (PhotoAdjustments, PhotoAsset) async throws -> Void
    /// Computes the histogram for a just-rendered preview frame. Injectable
    /// so `EditorSession` can be tested without a real per-pixel scan, and
    /// so a future faster/GPU-based implementation can replace
    /// `HistogramComputer` without touching `EditorSession` itself. The
    /// default already hops off the main actor via `runOffActor` (spec:
    /// histogram computation must stay cheap enough not to block slider
    /// interaction).
    public let computeHistogram: @Sendable (CGImage) async -> HistogramData?

    public init(
        previewScheduler: PreviewScheduler,
        previewRenderer: any PreviewRendering,
        loadAdjustments: @escaping @Sendable (PhotoAsset) async throws -> PhotoAdjustments,
        saveAdjustments: @escaping @Sendable (PhotoAdjustments, PhotoAsset) async throws -> Void,
        computeHistogram: @escaping @Sendable (CGImage) async -> HistogramData? = { image in
            (try? await runOffActor(priority: .utility) { HistogramComputer.histogram(for: image) }) ?? nil
        }
    ) {
        self.previewScheduler = previewScheduler
        self.previewRenderer = previewRenderer
        self.loadAdjustments = loadAdjustments
        self.saveAdjustments = saveAdjustments
        self.computeHistogram = computeHistogram
    }
}
