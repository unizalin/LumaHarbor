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
    /// Fires with `history.current` the instant `EditorSession.beginAdjustmentGesture()`
    /// is called -- Phase 3 Task 3.3's own seam for a caller that supports
    /// thumbnail multi-select (`LibraryViewModel`, in practice) to snapshot
    /// a batch sync's target list and source baseline at exactly the right
    /// moment. `EditorSession` itself has no concept of "the library" or
    /// "other selected photos"; it only fires this hook, if one was given.
    /// `nil` (the default) everywhere that doesn't support batch sync.
    public let onBeginAdjustmentGesture: (@Sendable (PhotoAdjustments) -> Void)?
    /// Fires with `history.current` the instant `EditorSession.endAdjustmentGesture()`
    /// is called -- the counterpart to `onBeginAdjustmentGesture` above.
    public let onEndAdjustmentGesture: (@Sendable (PhotoAdjustments) -> Void)?
    public let loadSnapshots: (@Sendable (PhotoAsset) async throws -> [EditSnapshot])?
    public let saveSnapshots: (@Sendable ([EditSnapshot], PhotoAsset) async throws -> Void)?

    public init(
        previewScheduler: PreviewScheduler,
        previewRenderer: any PreviewRendering,
        loadAdjustments: @escaping @Sendable (PhotoAsset) async throws -> PhotoAdjustments,
        saveAdjustments: @escaping @Sendable (PhotoAdjustments, PhotoAsset) async throws -> Void,
        computeHistogram: @escaping @Sendable (CGImage) async -> HistogramData? = { image in
            (try? await runOffActor(priority: .utility) { HistogramComputer.histogram(for: image) }) ?? nil
        },
        onBeginAdjustmentGesture: (@Sendable (PhotoAdjustments) -> Void)? = nil,
        onEndAdjustmentGesture: (@Sendable (PhotoAdjustments) -> Void)? = nil,
        loadSnapshots: (@Sendable (PhotoAsset) async throws -> [EditSnapshot])? = nil,
        saveSnapshots: (@Sendable ([EditSnapshot], PhotoAsset) async throws -> Void)? = nil
    ) {
        self.previewScheduler = previewScheduler
        self.previewRenderer = previewRenderer
        self.loadAdjustments = loadAdjustments
        self.saveAdjustments = saveAdjustments
        self.computeHistogram = computeHistogram
        self.onBeginAdjustmentGesture = onBeginAdjustmentGesture
        self.onEndAdjustmentGesture = onEndAdjustmentGesture
        self.loadSnapshots = loadSnapshots
        self.saveSnapshots = saveSnapshots
    }

    /// A copy with just the two batch-gesture hooks replaced -- the seam a
    /// caller that supports thumbnail multi-select (`LibraryViewModel`, in
    /// practice) uses to attach its own batch sync wiring onto services that
    /// were otherwise built without any knowledge of "the library" or
    /// "other selected photos" (`AppServices.editorDependencies`).
    public func addingBatchGestureHooks(
        onBegin: @escaping @Sendable (PhotoAdjustments) -> Void,
        onEnd: @escaping @Sendable (PhotoAdjustments) -> Void
    ) -> EditorDependencies {
        EditorDependencies(
            previewScheduler: previewScheduler,
            previewRenderer: previewRenderer,
            loadAdjustments: loadAdjustments,
            saveAdjustments: saveAdjustments,
            computeHistogram: computeHistogram,
            onBeginAdjustmentGesture: onBegin,
            onEndAdjustmentGesture: onEnd,
            loadSnapshots: loadSnapshots,
            saveSnapshots: saveSnapshots
        )
    }
}
