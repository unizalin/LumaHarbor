import Foundation
import PhotoLibraryCore
import RawProcessingCore

public struct EditorDependencies: Sendable {
    public let previewScheduler: PreviewScheduler
    public let previewRenderer: any PreviewRendering
    public let loadAdjustments: @Sendable (PhotoAsset) async throws -> PhotoAdjustments
    public let saveAdjustments: @Sendable (PhotoAdjustments, PhotoAsset) async throws -> Void

    public init(
        previewScheduler: PreviewScheduler,
        previewRenderer: any PreviewRendering,
        loadAdjustments: @escaping @Sendable (PhotoAsset) async throws -> PhotoAdjustments,
        saveAdjustments: @escaping @Sendable (PhotoAdjustments, PhotoAsset) async throws -> Void
    ) {
        self.previewScheduler = previewScheduler
        self.previewRenderer = previewRenderer
        self.loadAdjustments = loadAdjustments
        self.saveAdjustments = saveAdjustments
    }
}
