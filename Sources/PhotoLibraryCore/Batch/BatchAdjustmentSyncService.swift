import Foundation
import PresetCore
import RawProcessingCore

/// The outcome of syncing one target photo's adjustments during a batch
/// gesture (Phase 3 Task 3.3).
public enum BatchWriteResult: Sendable, Equatable {
    case success
    /// A safe, non-leaking description -- never an arbitrary caught
    /// `Error`'s raw description, which can carry an absolute path (see
    /// `PhotoLibraryCore/Preset/PresetRepository.swift`'s
    /// `safeCopiedSourceRetainedReason(for:)` for the same concern, same
    /// fix).
    case failure(String)
}

/// One completed (or attempted) batch sync -- a slider drag on the source
/// photo, replayed onto every other selected photo. `before`/`after` are
/// each target's *own* values for exactly `modifiedFieldIDs`, not the
/// source's -- e.g. `before[target]` is what that target's own patch held
/// before this sync touched it, useful both as an audit trail and as the
/// basis for Task 3.4's compound batch undo (revert = write `before[id]`
/// back).
public struct BatchAdjustmentTransaction: Sendable, Equatable {
    public var id: UUID
    public var sourcePhotoID: PhotoID
    /// Frozen at `beginGesture` -- see that method's own doc comment.
    public var targetPhotoIDs: [PhotoID]
    public var modifiedFieldIDs: [AdjustmentFieldID]
    public var before: [PhotoID: AdjustmentPatch]
    public var after: [PhotoID: AdjustmentPatch]
    public var results: [PhotoID: BatchWriteResult]

    public init(
        id: UUID = UUID(),
        sourcePhotoID: PhotoID,
        targetPhotoIDs: [PhotoID],
        modifiedFieldIDs: [AdjustmentFieldID],
        before: [PhotoID: AdjustmentPatch],
        after: [PhotoID: AdjustmentPatch],
        results: [PhotoID: BatchWriteResult]
    ) {
        self.id = id
        self.sourcePhotoID = sourcePhotoID
        self.targetPhotoIDs = targetPhotoIDs
        self.modifiedFieldIDs = modifiedFieldIDs
        self.before = before
        self.after = after
        self.results = results
    }
}

/// Drives Phase 3 Task 3.3's "batch snapshot semantics": when the user drags
/// a slider on the currently-open photo while other photos are also
/// selected in the grid, every other selected photo's *own* sidecar gets
/// the same field-level change synced into it, without ever touching the
/// fields that drag didn't change.
///
/// An `actor` -- not `EditorSession`-owned or MainActor-bound -- because the
/// per-target load/save/merge work has no reason to compete with UI work,
/// and because the load/save closures given at `init` are themselves the
/// only thing this type touches outside its own state (dependency
/// injection, the same pattern `EditorDependencies` already established, so
/// this is testable without any real `PhotoLibraryService`/filesystem).
///
/// Deliberately holds no reference to "the current selection" at all: the
/// caller (`LibraryViewModel`, in practice) must pass the target set as a
/// plain value into `beginGesture`, once, at the moment the drag starts.
/// Nothing this type does afterward can ever re-read a live selection, so a
/// selection change mid-drag structurally cannot retarget an
/// already-started gesture (Task 3.3: "selection changes mid-drag do not
/// change the current batch target list").
public actor BatchAdjustmentSyncService {
    public typealias Loader = @Sendable (PhotoID) async throws -> PhotoAdjustments
    public typealias Saver = @Sendable (PhotoAdjustments, PhotoID) async throws -> Void

    private struct ActiveGesture {
        var sourcePhotoID: PhotoID
        var targetPhotoIDs: [PhotoID]
        var sourceBaseline: PhotoAdjustments
    }

    private let loadAdjustments: Loader
    private let saveAdjustments: Saver
    private let applicator = PresetApplicator()
    private var activeGesture: ActiveGesture?

    public init(loadAdjustments: @escaping Loader, saveAdjustments: @escaping Saver) {
        self.loadAdjustments = loadAdjustments
        self.saveAdjustments = saveAdjustments
    }

    public var hasActiveGesture: Bool { activeGesture != nil }
    /// The target list frozen by the most recent `beginGesture`, if a
    /// gesture is currently active -- exposed for callers/tests to confirm
    /// the snapshot without waiting for a commit.
    public var currentTargetPhotoIDs: [PhotoID] { activeGesture?.targetPhotoIDs ?? [] }

    /// Snapshots `targetPhotoIDs` (minus `sourcePhotoID` itself, which is
    /// never its own sync target even if the selection set happens to
    /// include it) and `sourceBaseline` -- the source photo's own
    /// adjustments at the exact instant the drag began. Replaces any
    /// previous, uncommitted gesture rather than merging with it: only one
    /// gesture is ever in flight (a new drag can't start until the SwiftUI
    /// slider that owns the previous one has already reported its own end).
    public func beginGesture(sourcePhotoID: PhotoID, targetPhotoIDs: Set<PhotoID>, sourceBaseline: PhotoAdjustments) {
        let targets = targetPhotoIDs.subtracting([sourcePhotoID])
        activeGesture = ActiveGesture(sourcePhotoID: sourcePhotoID, targetPhotoIDs: Array(targets), sourceBaseline: sourceBaseline)
    }

    /// Discards the active gesture without syncing anything -- e.g. the
    /// photo was closed mid-drag.
    public func cancelGesture() {
        activeGesture = nil
    }

    /// Diffs `sourceAfter` against the baseline captured at `beginGesture`
    /// (`AdjustmentPatch.modifiedFields(in:comparedTo:)` -- Task 3.3: "only
    /// modified field IDs are synchronized"), then for every frozen target:
    /// loads its own current adjustments, merges just the modified fields'
    /// new (absolute) values onto them via `PresetApplicator`'s existing
    /// `.merge` mode (every other field stays exactly as that target's own
    /// edits left it), and saves the result. One target failing to
    /// load/save doesn't stop the rest -- each result is tallied
    /// individually. Returns `nil` if there was no active gesture to
    /// commit (e.g. a stray call with no matching `beginGesture`, or a
    /// second commit after the first already cleared it).
    @discardableResult
    public func commitGesture(sourceAfter: PhotoAdjustments) async -> BatchAdjustmentTransaction? {
        guard let gesture = activeGesture else { return nil }
        activeGesture = nil

        let modifiedFields = AdjustmentPatch.modifiedFields(in: sourceAfter, comparedTo: gesture.sourceBaseline)
        guard !modifiedFields.isEmpty else {
            return BatchAdjustmentTransaction(
                sourcePhotoID: gesture.sourcePhotoID,
                targetPhotoIDs: gesture.targetPhotoIDs,
                modifiedFieldIDs: [],
                before: [:],
                after: [:],
                results: [:]
            )
        }

        let syncedPatch = AdjustmentPatch.extracting(modifiedFields, from: sourceAfter)
        var before: [PhotoID: AdjustmentPatch] = [:]
        var after: [PhotoID: AdjustmentPatch] = [:]
        var results: [PhotoID: BatchWriteResult] = [:]

        for targetID in gesture.targetPhotoIDs {
            do {
                let current = try await loadAdjustments(targetID)
                before[targetID] = AdjustmentPatch.extracting(modifiedFields, from: current)
                let merged = applicator.apply(syncedPatch, to: current, mode: .merge, context: .none).adjustments
                try await saveAdjustments(merged, targetID)
                after[targetID] = AdjustmentPatch.extracting(modifiedFields, from: merged)
                results[targetID] = .success
            } catch {
                results[targetID] = .failure(Self.safeDescription(for: error))
            }
        }

        return BatchAdjustmentTransaction(
            sourcePhotoID: gesture.sourcePhotoID,
            targetPhotoIDs: gesture.targetPhotoIDs,
            modifiedFieldIDs: Array(modifiedFields),
            before: before,
            after: after,
            results: results
        )
    }

    private static func safeDescription(for error: Error) -> String {
        if let presetError = error as? PresetError, let description = presetError.errorDescription {
            return description
        }
        return "unknown error"
    }
}
