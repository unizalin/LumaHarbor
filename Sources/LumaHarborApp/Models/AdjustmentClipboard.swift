import PresetCore
import RawProcessingCore

/// Phase 2.2: UI-only "clipboard" for the Mac copy/paste/sync-adjustments
/// workflow (spec §6.2). Lives only in `LibraryViewModel`, in memory, for as
/// long as the app process runs -- never written to a photo's sidecar,
/// never persisted across launches, never enters any photo's undo history
/// by itself.
struct AdjustmentClipboard: Equatable {
    /// Exactly the `AdjustmentFieldID`s the source photo differed from
    /// neutral by at copy time (`AdjustmentPatch.modifiedFields(in:)`) --
    /// not every field, so a paste/sync never stamps a target's own
    /// deliberate edit on some other global field back to neutral.
    var patch: AdjustmentPatch
    /// `nil` unless the user explicitly opted in at copy time (spec §6.2:
    /// "Geometry 與 Local Adjustments 必須由使用者明確勾選").
    var geometry: GeometryAdjustments?
    /// `nil` unless the user explicitly opted in at copy time.
    var localAdjustments: [LocalAdjustment]?
}
