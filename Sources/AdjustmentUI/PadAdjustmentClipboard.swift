import PresetCore
import RawProcessingCore

/// In-memory clipboard for iPad adjustment transfer. It intentionally stores
/// only adjustment data; photo identity, rating, flag, keyword, source URL,
/// and metadata never cross through this value.
public struct PadAdjustmentClipboard: Equatable, Sendable {
    public let patch: AdjustmentPatch
    public let geometry: GeometryAdjustments?
    public let localAdjustments: [LocalAdjustment]?

    public init(
        patch: AdjustmentPatch,
        geometry: GeometryAdjustments? = nil,
        localAdjustments: [LocalAdjustment]? = nil
    ) {
        self.patch = patch
        self.geometry = geometry
        self.localAdjustments = localAdjustments
    }

    public static func copying(
        from adjustments: PhotoAdjustments,
        fields: Set<AdjustmentFieldID>,
        includeGeometry: Bool,
        includeLocalAdjustments: Bool
    ) -> PadAdjustmentClipboard {
        PadAdjustmentClipboard(
            patch: AdjustmentPatch.extracting(fields, from: adjustments),
            geometry: includeGeometry ? adjustments.geometry : nil,
            localAdjustments: includeLocalAdjustments ? adjustments.localAdjustments : nil
        )
    }
}
