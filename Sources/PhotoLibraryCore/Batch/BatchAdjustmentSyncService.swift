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
    /// Independent review of Task 3.4: a target's own `load → merge → save`
    /// cycle (in either `commitGesture` or `undo`) spans several `await`
    /// points, so actor isolation alone doesn't make it atomic -- a second
    /// call into this actor (e.g. `undo` invoked while a still-in-flight
    /// `commitGesture` is mid-write for a target they share) can otherwise
    /// interleave with it and lose whichever write finishes first. Every
    /// per-target cycle registers here for its own duration; a target
    /// already present is left alone by whichever call finds it that way,
    /// rather than racing.
    private var targetsInFlight: Set<PhotoID> = []

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
            guard !targetsInFlight.contains(targetID) else {
                results[targetID] = .failure(Self.conflictingOperationMessage)
                continue
            }
            targetsInFlight.insert(targetID)
            defer { targetsInFlight.remove(targetID) }
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

    /// The outcome of undoing one `BatchAdjustmentTransaction` (Phase 3 Task
    /// 3.4) -- tallied rather than surfaced per target, the same reason
    /// `PresetRestoreSummary` tallies a multi-document restore instead of
    /// throwing at the first problem.
    public struct BatchUndoSummary: Sendable, Equatable {
        /// A target successfully reverted to its own pre-sync values.
        public var affected = 0
        /// A target the original sync had already written to, but whose
        /// revert write (load or save) itself failed -- left exactly as the
        /// original sync left it, never half-written, and distinct from
        /// `skipped` because there *is* something on disk to fix here.
        public var failed = 0
        /// A target the original sync never actually wrote to (it failed
        /// back then), or one whose synced fields no longer hold what the
        /// sync wrote (edited again since, directly or by a later batch
        /// sync) -- nothing safe to revert, so undo leaves it untouched
        /// either way.
        public var skipped = 0

        public init() {}
    }

    /// Reverts `transaction`: every target it actually wrote to
    /// (`results[target] == .success`) gets `before[target]` merged back
    /// onto its *current* adjustments -- not a blind overwrite, so any edit
    /// a target received after the original sync (to a field the sync never
    /// touched) survives the undo exactly as it survived the sync itself. A
    /// target the original sync never wrote to is `skipped`, never touched.
    ///
    /// Independent review of Task 3.4: a target's *synced* field can also
    /// have been deliberately changed again since the sync -- directly, or
    /// by a later batch sync -- before this undo runs. Blindly merging
    /// `before[target]` back in that case would silently discard that later
    /// edit with no warning. Guarded by checking the target's current value
    /// on exactly the fields this sync touched (`modifiedFieldIDs`) against
    /// `after[target]` -- what the sync itself wrote -- first; a mismatch
    /// means the target moved on since, so this undo leaves it alone
    /// entirely (`skipped`) rather than guessing which part is still safe.
    /// One target's revert failing doesn't stop the rest, mirroring
    /// `commitGesture`'s own per-target fault tolerance. A target already
    /// mid-write from a concurrent `commitGesture`/`undo` call (see
    /// `targetsInFlight`) is tallied `failed` rather than raced -- a
    /// deliberately conservative label, not a precise one: this call never
    /// got far enough to load the target and compare it against
    /// `syncedPatch`, so a retry once the conflicting operation clears may
    /// well re-tally the same target as `skipped` instead (e.g. if the
    /// operation that was in flight turns out to have been what changed
    /// this field again). Reported as `failed` anyway because there's
    /// nothing safe to conclude yet, and `failed` is what invites a retry.
    public func undo(_ transaction: BatchAdjustmentTransaction) async -> BatchUndoSummary {
        var summary = BatchUndoSummary()
        guard !transaction.modifiedFieldIDs.isEmpty else { return summary }
        let modifiedFields = Set(transaction.modifiedFieldIDs)

        for targetID in transaction.targetPhotoIDs {
            guard transaction.results[targetID] == .success,
                  let priorPatch = transaction.before[targetID],
                  let syncedPatch = transaction.after[targetID] else {
                summary.skipped += 1
                continue
            }
            guard !targetsInFlight.contains(targetID) else {
                summary.failed += 1
                continue
            }
            targetsInFlight.insert(targetID)
            defer { targetsInFlight.remove(targetID) }
            do {
                let current = try await loadAdjustments(targetID)
                guard AdjustmentPatch.extracting(modifiedFields, from: current) == syncedPatch else {
                    summary.skipped += 1
                    continue
                }
                let reverted = applicator.apply(priorPatch, to: current, mode: .merge, context: .none).adjustments
                try await saveAdjustments(reverted, targetID)
                summary.affected += 1
            } catch {
                summary.failed += 1
            }
        }

        return summary
    }

    /// Phase 2.2 "Sync to Selected Photos" (spec §6.2): the explicit-action
    /// sibling of `commitGesture` -- same per-target load/merge/save/
    /// fault-tolerance loop and the same undoable `BatchAdjustmentTransaction`
    /// result, but driven by an already-built `patch` (e.g. an
    /// `AdjustmentClipboard`'s copied fields) instead of diffing a live
    /// gesture's before/after. Never touches `activeGesture` -- independent
    /// of any slider-drag gesture that may or may not be in flight.
    ///
    /// `targetPhotoIDs` is expected to already be frozen by the caller (the
    /// same "read the selection once, before any `await`" discipline
    /// `LibraryViewModel.beginBatchGesture` uses) -- this method also
    /// excludes `sourcePhotoID` from it as a defensive second guarantee, the
    /// same as `beginGesture` does for the gesture path.
    @discardableResult
    public func syncPatch(
        _ patch: AdjustmentPatch,
        sourcePhotoID: PhotoID,
        targetPhotoIDs: Set<PhotoID>
    ) async -> BatchAdjustmentTransaction {
        let fields = Set(AdjustmentFieldID.allCases.filter(patch.contains))
        let targets = Array(targetPhotoIDs.subtracting([sourcePhotoID]))
        guard !fields.isEmpty, !targets.isEmpty else {
            return BatchAdjustmentTransaction(
                sourcePhotoID: sourcePhotoID,
                targetPhotoIDs: targets,
                modifiedFieldIDs: [],
                before: [:],
                after: [:],
                results: [:]
            )
        }

        var before: [PhotoID: AdjustmentPatch] = [:]
        var after: [PhotoID: AdjustmentPatch] = [:]
        var results: [PhotoID: BatchWriteResult] = [:]

        for targetID in targets {
            guard !targetsInFlight.contains(targetID) else {
                results[targetID] = .failure(Self.conflictingOperationMessage)
                continue
            }
            targetsInFlight.insert(targetID)
            defer { targetsInFlight.remove(targetID) }
            do {
                let current = try await loadAdjustments(targetID)
                before[targetID] = AdjustmentPatch.extracting(fields, from: current)
                let merged = applicator.apply(patch, to: current, mode: .merge, context: .none).adjustments
                try await saveAdjustments(merged, targetID)
                after[targetID] = AdjustmentPatch.extracting(fields, from: merged)
                results[targetID] = .success
            } catch {
                results[targetID] = .failure(Self.safeDescription(for: error))
            }
        }

        return BatchAdjustmentTransaction(
            sourcePhotoID: sourcePhotoID,
            targetPhotoIDs: targets,
            modifiedFieldIDs: Array(fields),
            before: before,
            after: after,
            results: results
        )
    }

    private static let conflictingOperationMessage = "a conflicting batch operation is already in progress for this photo"

    private static func safeDescription(for error: Error) -> String {
        if let presetError = error as? PresetError, let description = presetError.errorDescription {
            return description
        }
        return "unknown error"
    }
}
