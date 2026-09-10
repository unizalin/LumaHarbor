import AdjustmentUI
import Combine
import EditorCore
import Localization
import PhotoLibraryCore
import RawProcessingCore

/// Main-actor bridge between the iPad selection model and the shared batch
/// adjustment engine. The engine remains an actor and owns all per-target
/// load/merge/save sequencing; this type only freezes the current selection,
/// forwards editor gesture hooks, and updates the visible edit badges.
@MainActor
final class PadBatchAdjustmentCoordinator: ObservableObject {
    @Published private(set) var lastTransaction: BatchAdjustmentTransaction?
    @Published private(set) var isSyncing = false

    private let library: PadLibraryModel
    private let libraryService: PhotoLibraryService
    private let service: BatchAdjustmentSyncService
    private weak var editor: PadEditorModel?
    private var isUndoing = false

    private struct TargetUnavailable: Error {}

    init(library: PadLibraryModel, libraryService: PhotoLibraryService) {
        self.library = library
        self.libraryService = libraryService
        self.service = BatchAdjustmentSyncService(
            loadAdjustments: { id in
                guard let asset = await MainActor.run(body: {
                    library.photos.first(where: { $0.id == id })
                }) else {
                    throw TargetUnavailable()
                }
                return try await libraryService.adjustments(for: asset)
            },
            saveAdjustments: { adjustments, id in
                guard let asset = await MainActor.run(body: {
                    library.photos.first(where: { $0.id == id })
                }) else {
                    throw TargetUnavailable()
                }
                try await libraryService.saveAdjustments(adjustments, for: asset)
            }
        )
    }

    func attach(editor: PadEditorModel) {
        self.editor = editor
    }

    /// Called by `EditorSession` when a slider drag begins. The target list
    /// is read once here, before any await, so changing the grid selection
    /// during a drag cannot retarget that drag.
    func beginGesture(baseline: PhotoAdjustments) async {
        guard let sourcePhotoID = editor?.editor.photo?.id else { return }
        let targets = library.selectedPhotoIDs
        guard targets.count > 1 else { return }
        await service.beginGesture(
            sourcePhotoID: sourcePhotoID,
            targetPhotoIDs: targets,
            sourceBaseline: baseline
        )
    }

    /// Commits the frozen gesture and updates only the visible target badges.
    func endGesture(after: PhotoAdjustments) async {
        guard let transaction = await service.commitGesture(sourceAfter: after) else { return }
        guard !transaction.modifiedFieldIDs.isEmpty else { return }
        lastTransaction = transaction
        markSuccessfulTargets(in: transaction)
    }

    /// Applies an explicit copy/paste patch to every other selected photo.
    /// Geometry and local adjustments stay on the current editor only; the
    /// shared batch service intentionally handles stable field-level patches.
    func sync(_ clipboard: PadAdjustmentClipboard?, sourcePhotoID: PhotoID?) async -> BatchAdjustmentTransaction? {
        guard let clipboard, let sourcePhotoID else { return nil }
        let targets = library.selectedPhotoIDs
        guard targets.count > 1 else { return nil }
        isSyncing = true
        defer { isSyncing = false }
        let transaction = await service.syncPatch(
            clipboard.patch,
            sourcePhotoID: sourcePhotoID,
            targetPhotoIDs: targets
        )
        lastTransaction = transaction
        markSuccessfulTargets(in: transaction)
        return transaction
    }

    /// Persists curation fields sidecar-first through `PhotoLibraryService`
    /// (spec §6.1 rule 1: the sidecar, not `PhotoIndexStore`, is
    /// authoritative). These methods do not touch RAW files.
    func setRating(_ rating: Int, for photoID: PhotoID) async -> Bool {
        guard let asset = await MainActor.run(body: { library.photos.first(where: { $0.id == photoID }) }) else {
            return false
        }
        do {
            try await libraryService.setRating(rating, for: asset)
            library.updatePhotoCuration(photoID: photoID, rating: rating)
            return true
        } catch {
            return false
        }
    }

    func setFlag(_ flag: PhotoFlag, for photoID: PhotoID) async -> Bool {
        guard let asset = await MainActor.run(body: { library.photos.first(where: { $0.id == photoID }) }) else {
            return false
        }
        do {
            try await libraryService.setFlag(flag, for: asset)
            library.updatePhotoCuration(photoID: photoID, flag: flag)
            return true
        } catch {
            return false
        }
    }

    func setKeywords(_ inputs: [String], for photoID: PhotoID) async -> Bool {
        guard let asset = await MainActor.run(body: { library.photos.first(where: { $0.id == photoID }) }) else {
            return false
        }
        do {
            try await libraryService.setKeywords(inputs, for: asset)
            let keywords = inputs.compactMap(PhotoKeyword.make(from:))
            var seen = Set<String>()
            let unique = keywords.filter { seen.insert($0.normalized).inserted }
            library.updatePhotoCuration(photoID: photoID, keywords: unique)
            return true
        } catch {
            return false
        }
    }

    /// Reverts the most recent batch transaction. A partial failure keeps the
    /// transaction available so the next attempt can retry only safe targets.
    func undoLastTransaction() async -> BatchAdjustmentSyncService.BatchUndoSummary? {
        guard !isUndoing, let transaction = lastTransaction else { return nil }
        isUndoing = true
        defer { isUndoing = false }
        let summary = await service.undo(transaction)
        if summary.failed == 0, lastTransaction?.id == transaction.id {
            lastTransaction = nil
        }
        for targetID in transaction.targetPhotoIDs where transaction.results[targetID] == .success {
            guard let asset = library.photos.first(where: { $0.id == targetID }),
                  let adjustments = try? await load(asset) else { continue }
            library.markPhotoHasEdits(targetID, hasEdits: !adjustments.isNeutral)
        }
        return summary
    }

    nonisolated static func summaryMessage(_ transaction: BatchAdjustmentTransaction) -> String {
        let succeeded = transaction.results.values.filter { $0 == .success }.count
        let failed = transaction.results.count - succeeded
        var parts: [String] = []
        if succeeded > 0 { parts.append("\(succeeded) \(L10n.t("synced"))") }
        if failed > 0 { parts.append("\(failed) \(L10n.t("failed to sync"))") }
        return parts.isEmpty ? L10n.t("Nothing to sync.") : parts.joined(separator: ", ")
    }

    nonisolated static func undoSummaryMessage(_ summary: BatchAdjustmentSyncService.BatchUndoSummary) -> String {
        var parts: [String] = []
        if summary.affected > 0 { parts.append("\(summary.affected) \(L10n.t("reverted"))") }
        if summary.failed > 0 { parts.append("\(summary.failed) \(L10n.t("failed to revert"))") }
        if summary.skipped > 0 { parts.append("\(summary.skipped) \(L10n.t("skipped"))") }
        return parts.isEmpty ? L10n.t("Nothing to undo.") : parts.joined(separator: ", ")
    }

    private func markSuccessfulTargets(in transaction: BatchAdjustmentTransaction) {
        for targetID in transaction.targetPhotoIDs where transaction.results[targetID] == .success {
            library.markPhotoHasEdits(targetID, hasEdits: true)
        }
    }

    private func load(_ asset: PhotoAsset) async throws -> PhotoAdjustments {
        try await libraryService.adjustments(for: asset)
    }
}
