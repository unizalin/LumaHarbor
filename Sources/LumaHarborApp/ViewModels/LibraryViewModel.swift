import AppKit
import Localization
import Combine
import EditorCore
import Foundation
import PhotoLibraryCore
import PresetCore
import RawProcessingCore
import SwiftUI

struct ScanProgress: Equatable {
    var libraryID: LibraryID
    var indexedCount: Int
    var failedCount: Int
    var isFinished: Bool

    var summary: String {
        let photosPart = indexedCount == 1
            ? L10n.t("1 photo")
            : "\(indexedCount) " + L10n.t("photos")
        if isFinished {
            return failedCount == 0
                ? photosPart
                : "\(photosPart), \(failedCount) " + L10n.t("skipped")
        }
        return "\(L10n.t("Scanning —")) \(indexedCount) " + L10n.t("found")
    }
}

struct ExportState: Equatable {
    var photoID: PhotoID
    var filename: String
    var isFinished: Bool
    var resultPath: String?
    /// Phase 5 Task 5.2: `true` when this export finished by being skipped
    /// under `.skip` collision policy -- nothing was written, and the sheet
    /// must say so plainly rather than reusing the "Exported" success copy
    /// (design spec §8.3: never disguise a skip as success).
    var wasSkipped: Bool = false
}

/// Every user-facing choice `ExportSheet` collects, bundled so
/// `LibraryViewModel.export(photo:to:options:)` takes one value instead of a
/// long positional-argument list. 1:1 with `RawProcessingCore.ExportRequest`'s
/// own new fields (design spec §6.11); `LibraryViewModel` maps this straight
/// across when it builds the request.
struct MacExportOptions: Equatable {
    var format: ExportFormat
    var quality: Double
    var bitDepth: ExportBitDepth
    var maximumWidth: Int?
    var maximumHeight: Int?
    var dpi: Double?
    var exifRetentionPolicy: ExifRetentionPolicy
    var namingTemplate: ExportNamingTemplate
    var collisionPolicy: ExportCollisionPolicy
    var watermark: Watermark?

    static let `default` = MacExportOptions(
        format: .jpeg,
        quality: 0.9,
        bitDepth: .eightBit,
        maximumWidth: nil,
        maximumHeight: nil,
        dpi: nil,
        exifRetentionPolicy: .preserveAll,
        namingTemplate: .default,
        collisionPolicy: .default,
        watermark: nil
    )
}

enum MacGridDensity: String, CaseIterable, Identifiable {
    case compact
    case standard
    case large

    var id: Self { self }

    var minimumWidth: CGFloat {
        switch self {
        case .compact: return 132
        case .standard: return 180
        case .large: return 260
        }
    }

    var maximumWidth: CGFloat {
        switch self {
        case .compact: return 190
        case .standard: return 260
        case .large: return 360
        }
    }
}

/// Owns library-level state: which folders exist, which photos are in them, and
/// which photo is open.
@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published private(set) var libraries: [LibraryFolder] = []
    @Published private(set) var photos: [PhotoAsset] = []

    /// Selection is read-only from the outside.
    ///
    /// Addendum §3.1: moving away from a photo has to flush its edits first,
    /// and that is asynchronous — a plain `didSet` can't hold the UI back until
    /// the sidecar is actually written. Views go through
    /// `requestSelectPhoto(_:)` / `requestSelectLibrary(_:)` (or the bindings
    /// below) instead, and the selection only changes once the write lands.
    @Published private(set) var selectedLibraryID: LibraryID?
    @Published private(set) var selectedPhotoID: PhotoID?
    /// Which photos are included in the current batch sync target set
    /// (Phase 3 Task 3.3), always a superset of `selectedPhotoID` while a
    /// photo is open. Cmd-clicking a thumbnail toggles membership here
    /// without changing which photo is actually open in the editor;
    /// `toggleMultiSelect(_:)` is the only mutator.
    @Published private(set) var selectedPhotoIDs: Set<PhotoID> = []
    @Published var searchText = ""
    @Published var sort: PhotoSort = .captureDateDescending
    /// Phase 3 curation filters. They live in the query value and therefore
    /// compose with filename search without a second Swift-side filtering pass.
    @Published var ratingFilter: PhotoRatingFilter?
    @Published var flagFilter: PhotoFlag?
    @Published var hasEditsFilter: Bool?
    @Published var formatFilter: String?
    @Published var cameraFilter: String?
    @Published var lensFilter: String?
    @Published var captureDateStartFilter: Date?
    @Published var captureDateEndFilter: Date?
    @Published var keywordFilter: String?
    /// Rejects are excluded from batch export by default; the export sheet
    /// opts in explicitly for a deliberate reject-inclusive export.
    @Published var includeRejectedInBatchExport = false
    @Published var gridDensity: MacGridDensity = .standard
    /// The grid's actual contents: `photos` filtered/sorted by `searchText`/
    /// `sort`. Spec §5.3.1/§4.2: this is driven entirely by
    /// `PhotoIndexStore.page(matching:after:limit:)` -- the same SQL filename
    /// search (Unicode normalization, `%`/`_` escaping) and `ORDER BY`/
    /// tie-break rules the iPad browser already uses -- rather than a second,
    /// hand-rolled Swift-side filter/sort. See `scheduleVisibleQuery(debounced:)`.
    @Published private(set) var visiblePhotos: [PhotoAsset] = []
    @Published private(set) var isSelecting = false
    @Published private(set) var selectionAnchor: PhotoID?
    /// Phase 3 Task 3.4: the most recent batch sync that actually changed
    /// something, kept around for exactly one "Undo Batch Sync" -- `nil`
    /// whenever there's nothing to undo (no batch sync has happened yet, a
    /// gesture's diff was empty, or the last one was already undone).
    @Published private(set) var lastBatchTransaction: BatchAdjustmentTransaction?
    /// Phase 2.2 (spec §6.2): the most recently copied adjustments, or
    /// `nil` if nothing has been copied yet this session. UI-only -- never
    /// written to any photo's sidecar.
    @Published private(set) var adjustmentClipboard: AdjustmentClipboard?
    /// Whether the *next* "Copy Adjustments" also captures the open photo's
    /// committed crop/rotate geometry. Off by default (spec §6.2: "Geometry
    /// 與 Local Adjustments 必須由使用者明確勾選").
    @Published var copyIncludesGeometry = false
    /// Whether the *next* "Copy Adjustments" also captures the open photo's
    /// local adjustment brushes. Off by default, same reasoning as
    /// `copyIncludesGeometry`.
    @Published var copyIncludesLocalAdjustments = false
    @Published private(set) var scanProgress: ScanProgress?
    @Published private(set) var exportState: ExportState?
    /// Phase 5 Task 5.1: live per-file status for the batch export currently
    /// running (or the most recently finished one, left visible until a new
    /// batch starts or the sheet is closed via `closeBatchExportSheet()`) --
    /// one entry per photo in `selectedPhotoIDs` at the moment the batch
    /// started. Populated and driven by `startBatchExport(to:options:)`.
    @Published private(set) var batchExportItems: [BatchExportItem] = []
    @Published private(set) var isBatchExporting = false
    @Published private(set) var startupFailure: String?
    @Published var alert: UserAlert?
    @Published var isShowingExportSheet = false
    @Published var isShowingBatchExportSheet = false

    let editor = EditorSession()
    let presetLibrary = PresetLibraryViewModel()

    /// Views only ever hold `@EnvironmentObject var model: LibraryViewModel`
    /// and read `model.editor.*` through it — `editor` is never injected as its
    /// own environment object. Without this, `editor`'s own `@Published`
    /// mutations (a new photo opening, its preview arriving) never republish
    /// through `self`, so SwiftUI has nothing telling it to redraw: the
    /// inspector and preview pane show whatever editor state existed at the
    /// last unrelated `LibraryViewModel` publish, one selection behind.
    private var editorForwarding: AnyCancellable?
    /// Same reasoning as `editorForwarding`, for `presetLibrary`.
    private var presetLibraryForwarding: AnyCancellable?
    /// Re-runs `visiblePhotos`'s query whenever `searchText` (debounced),
    /// `sort` or `photos` (both immediate) changes -- see
    /// `scheduleVisibleQuery(debounced:)`.
    private var visibleQueryForwarding: Set<AnyCancellable> = []
    /// Bumped on every new query; a page result is only committed if it's
    /// still current when it lands (mirrors `LibraryBrowserSession`'s own
    /// `queryGeneration` guard).
    private var visibleQueryGeneration: UInt64 = 0
    private var visibleQueryTask: Task<Void, Never>?

    private var services: AppServices?
    private var scanTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var batchExportTask: Task<Void, Never>?
    /// Rebuilt in `install(services:)` against `services.exporter` -- the
    /// same decoder/pipeline/render-service graph a single-photo export
    /// uses (and the one tests inject). The `BatchExportQueue()` default
    /// here only matters before `install(services:)` has run, which no
    /// action that reads it is reachable before.
    private var batchExportQueue = BatchExportQueue()
    private var hasBootstrapped = false

    /// Only ever holds the most recent request: clicking three thumbnails
    /// quickly should land on the third, not walk through all of them.
    private var pendingSelection: SelectionRequest?
    private var isApplyingSelection = false

    /// Reading a sidecar is asynchronous, so a fast A→B can land B's selection
    /// while A's read is still out. The token is what lets a late read tell
    /// that it is answering a question nobody is asking any more.
    private var openTask: Task<Void, Never>?
    private var selectionGeneration: UInt64 = 0

    private enum SelectionRequest: Equatable {
        case photo(PhotoID?)
        case library(LibraryID?)
    }

    /// Phase 3 Task 3.3: `BatchAdjustmentSyncService`'s load/save closures
    /// are keyed by `PhotoID` alone (it has no concept of "the currently
    /// open library"), so these map back to a `PhotoAsset` via `photos`
    /// before delegating to `services.libraryService` -- the same
    /// `PhotoAsset`-keyed API `loadAdjustments`/`saveAdjustments` already
    /// use for the open photo.
    private struct BatchSyncPhotoUnavailable: Error {}

    private lazy var batchSyncService = BatchAdjustmentSyncService(
        loadAdjustments: { [weak self] id in
            guard let self, let (services, asset) = await self.batchSyncTarget(for: id) else {
                throw BatchSyncPhotoUnavailable()
            }
            // Routes through `services.loadAdjustments`, not
            // `services.libraryService.adjustments(for:)` directly -- the
            // same seam the currently-open photo's own load/save already
            // goes through, generic over *any* `PhotoAsset`, not just the
            // open one. In production `AppServices.makeDefault()` wires
            // both to the identical `libraryService` call either way; the
            // difference only matters for tests, which override this seam
            // (`AppTestSupport.makeServices(loadAdjustments:saveAdjustments:)`)
            // to observe every write, target photos included.
            return try await services.loadAdjustments(asset)
        },
        saveAdjustments: { [weak self] adjustments, id in
            guard let self, let (services, asset) = await self.batchSyncTarget(for: id) else {
                throw BatchSyncPhotoUnavailable()
            }
            try await services.saveAdjustments(adjustments, asset)
        }
    )

    private func photo(for id: PhotoID) -> PhotoAsset? {
        photos.first { $0.id == id }
    }

    private func batchSyncTarget(for id: PhotoID) -> (AppServices, PhotoAsset)? {
        guard let services, let asset = photo(for: id) else { return nil }
        return (services, asset)
    }

    public init() {
        editorForwarding = editor.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        presetLibraryForwarding = presetLibrary.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }

        // Spec §5.3.1: search is debounced 250ms; sort and the underlying
        // `photos` snapshot (a fresh library selection, a scan batch, or an
        // edit-badge update) re-query immediately.
        $searchText
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleVisibleQuery(debounced: true) }
            .store(in: &visibleQueryForwarding)
        Publishers.Merge($sort.removeDuplicates().map { _ in () }, $photos.map { _ in () })
            .sink { [weak self] _ in self?.scheduleVisibleQuery(debounced: false) }
            .store(in: &visibleQueryForwarding)
        Publishers.MergeMany(
            $ratingFilter.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $flagFilter.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $hasEditsFilter.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $formatFilter.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $cameraFilter.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $lensFilter.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $captureDateStartFilter.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $captureDateEndFilter.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            $keywordFilter.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] _ in self?.scheduleVisibleQuery(debounced: false) }
        .store(in: &visibleQueryForwarding)
    }

    private func install(services: AppServices) {
        self.services = services
        batchExportQueue = BatchExportQueue(exporter: services.exporter)
        editor.attach(dependencies: services.editorDependencies.addingBatchGestureHooks(
            onBegin: { [weak self] baseline in
                Task { @MainActor in await self?.beginBatchGesture(baseline: baseline) }
            },
            onEnd: { [weak self] after in
                Task { @MainActor in await self?.endBatchGesture(after: after) }
            }
        ))
        editor.onSaved = { [weak self] photoID, hasEdits in
            self?.updateEditBadge(photoID: photoID, hasEdits: hasEdits)
        }
        presetLibrary.attach(myRepository: services.myPresetsRepository)
    }

    /// Test seam: wires already-built services and reads current state from
    /// them, skipping the Application Support discovery `bootstrap()` does.
    ///
    /// Everything downstream — the flush-before-transition rule, the selection
    /// token, the edit badge — is the production code path; only where the
    /// services come from differs.
    func attachForTesting(services: AppServices) async {
        hasBootstrapped = true
        install(services: services)
        libraries = await services.libraryService.knownLibraries()
    }

    /// Test seam: loads the photo list for a library without going through a
    /// selection transition, so a test can set up state before exercising one.
    func selectForTesting(libraryID: LibraryID?) async {
        selectedLibraryID = libraryID
        presetLibrary.updateLibraryRepository(
            selectedLibrary.map { FilePresetRepository(scope: .libraryPresets(libraryRootURL: $0.rootURL)) }
        )
        selectedPhotoID = nil
        selectedPhotoIDs = []
        await reloadPhotos()
    }

    // MARK: - Selection

    /// Asks to open a photo. The change lands once the current photo's edits
    /// are safely on disk; if that write fails, the selection stays put.
    func requestSelectPhoto(_ photoID: PhotoID?) {
        guard photoID != selectedPhotoID else { return }
        enqueue(.photo(photoID))
    }

    func requestSelectLibrary(_ libraryID: LibraryID?) {
        guard libraryID != selectedLibraryID else { return }
        enqueue(.library(libraryID))
    }

    /// Cmd-click in the grid (Phase 3 Task 3.3): adds/removes `photoID` from
    /// the batch sync target set without changing which photo is open in
    /// the editor. Purely local UI state -- unlike `requestSelectPhoto`,
    /// there is no sidecar to flush, so this never needs to be async.
    func toggleMultiSelect(_ photoID: PhotoID) {
        isSelecting = true
        if selectedPhotoIDs.contains(photoID) {
            selectedPhotoIDs.remove(photoID)
        } else {
            selectedPhotoIDs.insert(photoID)
        }
        selectionAnchor = photoID
    }

    func beginSelection() {
        isSelecting = true
        selectionAnchor = selectedPhotoID ?? selectedPhotoIDs.first
    }

    func finishSelection() {
        isSelecting = false
        selectionAnchor = nil
    }

    func clearSelection() {
        selectedPhotoIDs = []
        selectionAnchor = nil
    }

    func selectAllVisible() {
        isSelecting = true
        selectedPhotoIDs.formUnion(visiblePhotos.map(\.id))
        selectionAnchor = visiblePhotos.first?.id
    }

    func selectRange(to photoID: PhotoID) {
        let orderedIDs = visiblePhotos.map(\.id)
        guard let anchor = selectionAnchor,
              let start = orderedIDs.firstIndex(of: anchor),
              let end = orderedIDs.firstIndex(of: photoID) else {
            toggleMultiSelect(photoID)
            return
        }
        let range = start <= end ? start...end : end...start
        isSelecting = true
        selectedPhotoIDs.formUnion(range.map { orderedIDs[$0] })
        selectionAnchor = photoID
    }

    func editSelectedPhotos() {
        guard let photoID = selectionAnchor ?? visiblePhotos.first(where: { selectedPhotoIDs.contains($0.id) })?.id else {
            return
        }
        requestSelectPhoto(photoID)
    }

    // MARK: - Visible-photos query (spec §5.3, §4.2)

    /// Schedules a fresh `visiblePhotos` query, discarding whatever query is
    /// already in flight. `debounced` mirrors `LibraryBrowserSession
    /// .searchDebounceDelay`'s own 250ms so the two platforms share the same
    /// "don't query on every keystroke" contract, not just the same SQL.
    private func scheduleVisibleQuery(debounced: Bool) {
        visibleQueryGeneration += 1
        let generation = visibleQueryGeneration
        visibleQueryTask?.cancel()
        visibleQueryTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            await self?.runVisibleQuery(generation: generation)
        }
    }

    /// Pages through `PhotoIndexStore.page(matching:after:limit:)` -- the
    /// exact filename-search (Unicode normalization, `%`/`_` escaping) and
    /// `ORDER BY`/tie-break contract `LibraryBrowserSession` already relies
    /// on for iPad -- accumulating every page for the current library into
    /// `visiblePhotos`. A generation check before *and* after every `await`
    /// means a stale query (superseded by a newer search/sort/library
    /// change) can never clobber a fresher one's result, the same pattern
    /// `LibraryBrowserSession.loadFirstPage` uses.
    private func runVisibleQuery(generation: UInt64) async {
        guard generation == visibleQueryGeneration else { return }
        guard let services, let libraryID = selectedLibraryID else {
            if generation == visibleQueryGeneration { visiblePhotos = [] }
            return
        }

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = LibraryQuery(
            scope: .source(libraryID),
            filenameSearch: trimmedSearch.isEmpty ? nil : trimmedSearch,
            sort: sort,
            rating: ratingFilter,
            flag: flagFilter,
            hasEdits: hasEditsFilter,
            format: formatFilter,
            camera: cameraFilter,
            lens: lensFilter,
            captureDate: (captureDateStartFilter != nil || captureDateEndFilter != nil)
                ? PhotoDateRange(start: captureDateStartFilter, end: captureDateEndFilter)
                : nil,
            keyword: keywordFilter
        )
        let indexStore = await services.libraryService.indexStore

        var results: [PhotoAsset] = []
        var cursor: PhotoPageCursor?
        repeat {
            guard generation == visibleQueryGeneration else { return }
            guard let page = try? indexStore.page(matching: query, after: cursor, limit: 200) else { break }
            results.append(contentsOf: page.photos)
            cursor = page.nextCursor
        } while cursor != nil

        guard generation == visibleQueryGeneration else { return }
        visiblePhotos = results
    }

    // MARK: - Curation metadata

    func setRatingForSelectedPhoto(_ rating: Int) {
        guard let photoID = selectedPhotoID, let services, let photo = photo(for: photoID) else { return }
        Task { [weak self] in
            do {
                try await services.libraryService.setRating(rating, for: photo)
                await self?.reloadPhotos()
            } catch {
                self?.alert = UserAlert(title: L10n.t("Couldn't save rating"), error: error)
            }
        }
    }

    func setFlagForSelectedPhoto(_ flag: PhotoFlag) {
        guard let photoID = selectedPhotoID, let services, let photo = photo(for: photoID) else { return }
        Task { [weak self] in
            do {
                try await services.libraryService.setFlag(flag, for: photo)
                await self?.reloadPhotos()
            } catch {
                self?.alert = UserAlert(title: L10n.t("Couldn't save flag"), error: error)
            }
        }
    }

    func setKeywordsForPhoto(_ photoID: PhotoID, inputs: [String]) {
        guard let services, let photo = photo(for: photoID) else { return }
        Task { [weak self] in
            do {
                try await services.libraryService.setKeywords(inputs, for: photo)
                await self?.reloadPhotos()
            } catch {
                self?.alert = UserAlert(title: L10n.t("Couldn't save keywords"), error: error)
            }
        }
    }

    func setKeywordsForSelectedPhoto(_ inputs: [String]) {
        guard let photoID = selectedPhotoID else { return }
        setKeywordsForPhoto(photoID, inputs: inputs)
    }

    func clearCatalogFilters() {
        ratingFilter = nil
        flagFilter = nil
        hasEditsFilter = nil
        formatFilter = nil
        cameraFilter = nil
        lensFilter = nil
        captureDateStartFilter = nil
        captureDateEndFilter = nil
        keywordFilter = nil
    }

    /// `EditorDependencies.onBeginAdjustmentGesture`'s target -- snapshots
    /// the batch's target list and the open photo's own baseline into
    /// `batchSyncService`. A no-op unless at least one *other* photo is
    /// actually selected: opening a single photo with nothing else
    /// multi-selected must never spuriously start a batch.
    private func beginBatchGesture(baseline: PhotoAdjustments) async {
        guard let source = selectedPhotoID, selectedPhotoIDs.count > 1 else { return }
        let targets = selectedPhotoIDs.subtracting([source])
        guard !targets.isEmpty else { return }
        await batchSyncService.beginGesture(sourcePhotoID: source, targetPhotoIDs: targets, sourceBaseline: baseline)
    }

    /// `EditorDependencies.onEndAdjustmentGesture`'s target -- commits
    /// whatever gesture `batchSyncService` has active (a no-op if
    /// `beginBatchGesture` never started one) and refreshes the grid's own
    /// "has edits" badge for every target that was actually written.
    private func endBatchGesture(after: PhotoAdjustments) async {
        guard let transaction = await batchSyncService.commitGesture(sourceAfter: after) else { return }
        guard !transaction.modifiedFieldIDs.isEmpty else { return }
        lastBatchTransaction = transaction
        for targetID in transaction.targetPhotoIDs where transaction.results[targetID] == .success {
            updateEditBadge(photoID: targetID, hasEdits: true)
        }
    }

    /// Guards `undoLastBatchTransaction()` against a second, concurrent
    /// call while the first is still running (e.g. a double-click on "Undo
    /// Batch Sync" before the menu has re-disabled itself) -- both calls
    /// would otherwise start reverting the *same* transaction, and while
    /// `BatchAdjustmentSyncService`'s own `targetsInFlight` guard (Task 3.4
    /// independent review, Finding 2) stops that from corrupting any
    /// target's data, it would still surface a confusing spurious "1
    /// failed" from the second call alone racing the first.
    private var isUndoingLastBatchTransaction = false

    /// Phase 3 Task 3.4: reverts `lastBatchTransaction` (`before[id]` merged
    /// back onto each target's *current* adjustments -- not a blind
    /// overwrite, so anything a target picked up since the sync survives),
    /// then refreshes the grid's edit badge for every target the original
    /// sync actually wrote to, from the ground truth left on disk rather
    /// than assuming the revert made it neutral.
    ///
    /// Independent review of Task 3.4, Finding 4: only consumes the
    /// transaction when every target it touched reverted cleanly
    /// (`summary.failed == 0`). A partial failure keeps `lastBatchTransaction`
    /// around so choosing "Undo Batch Sync" again retries -- safely, since
    /// `BatchAdjustmentSyncService.undo(_:)`'s own conflict check (Finding 1's
    /// fix) means a target already reverted by the first attempt no longer
    /// matches its recorded `after` value and is `skipped`, not re-reverted,
    /// on the retry.
    ///
    /// Independent review of the Task 3.4 follow-up round itself, Finding 1:
    /// a brand-new, unrelated batch sync landing in `endBatchGesture` while
    /// this `await` is in flight replaces `lastBatchTransaction` with its
    /// own transaction -- this function must only write back to
    /// `lastBatchTransaction` if it's still the exact transaction (by `id`)
    /// this call started with, or it would clear/leave-for-retry a
    /// completely different, newer transaction the user never asked to
    /// touch.
    @discardableResult
    func undoLastBatchTransaction() async -> BatchAdjustmentSyncService.BatchUndoSummary? {
        guard !isUndoingLastBatchTransaction, let transaction = lastBatchTransaction else { return nil }
        isUndoingLastBatchTransaction = true
        defer { isUndoingLastBatchTransaction = false }

        let summary = await batchSyncService.undo(transaction)
        if summary.failed == 0, lastBatchTransaction?.id == transaction.id {
            lastBatchTransaction = nil
        }
        for targetID in transaction.targetPhotoIDs where transaction.results[targetID] == .success {
            guard let (services, asset) = batchSyncTarget(for: targetID) else { continue }
            if let reverted = try? await services.loadAdjustments(asset) {
                updateEditBadge(photoID: targetID, hasEdits: !reverted.isNeutral)
            }
        }
        return summary
    }

    /// Phase 3 Task 3.4: "affected N, failed M, skipped K" report copy,
    /// following the same additive-parts convention (skip a count that's
    /// zero, join the rest with ", ") `PresetBrowserView.restoreSummaryMessage`
    /// already established for `PresetRestoreSummary`.
    nonisolated static func batchUndoSummaryMessage(_ summary: BatchAdjustmentSyncService.BatchUndoSummary) -> String {
        var parts: [String] = []
        if summary.affected > 0 { parts.append("\(summary.affected) \(L10n.t("reverted"))") }
        // A dedicated key, not the "failed" `PresetRestoreSummary` reuses --
        // that one reads fine on its own ("3 failed") but its zh-Hant
        // translation ("失敗") has no measure word, inconsistent with
        // "reverted"/"skipped" here (both "張…") once joined into one
        // photo-counting sentence.
        if summary.failed > 0 { parts.append("\(summary.failed) \(L10n.t("failed to revert"))") }
        if summary.skipped > 0 { parts.append("\(summary.skipped) \(L10n.t("skipped"))") }
        return parts.isEmpty ? L10n.t("Nothing to undo.") : parts.joined(separator: ", ")
    }

    // MARK: - Phase 2.2: copy, paste, sync adjustments (spec §6.2)

    /// Snapshots the currently-open photo's own current adjustments into
    /// `adjustmentClipboard` -- UI-only in-memory state, never written to
    /// any photo's sidecar. Global adjustments are captured as exactly the
    /// fields that differ from neutral (`AdjustmentPatch.modifiedFields(in:)`
    /// -- the same "only what was actually changed" diff the slider-drag
    /// batch sync already uses), not a blind snapshot of every
    /// `AdjustmentFieldID`: a target photo's own deliberate edit on a field
    /// the source never touched must survive a later paste/sync, the same
    /// way it already survives a drag-triggered sync. Geometry and Local
    /// Adjustments are captured only when
    /// `copyIncludesGeometry`/`copyIncludesLocalAdjustments` are on.
    func copyAdjustments() {
        guard editor.photo != nil else { return }
        let current = editor.adjustments
        let modifiedFields = AdjustmentPatch.modifiedFields(in: current)
        adjustmentClipboard = AdjustmentClipboard(
            patch: AdjustmentPatch.extracting(modifiedFields, from: current),
            geometry: copyIncludesGeometry ? current.geometry : nil,
            localAdjustments: copyIncludesLocalAdjustments ? current.localAdjustments : nil
        )
    }

    /// Applies `adjustmentClipboard` to the currently-open photo as one
    /// undoable step (`EditorSession.pasteAdjustments` records history
    /// exactly once). A no-op with nothing copied yet, or no photo open.
    func pasteAdjustments() {
        guard let clipboard = adjustmentClipboard else { return }
        editor.pasteAdjustments(
            patch: clipboard.patch,
            geometry: clipboard.geometry,
            localAdjustments: clipboard.localAdjustments
        )
    }

    /// "Sync to Selected Photos": pushes `adjustmentClipboard`'s global
    /// fields onto every other currently-selected photo, reusing
    /// `BatchAdjustmentSyncService`'s existing per-target snapshot/merge/
    /// fault-tolerance machinery via `syncPatch(_:sourcePhotoID:targetPhotoIDs:)`
    /// -- the explicit-action sibling of the slider-drag gesture's
    /// `commitGesture`. Geometry/Local Adjustments in the clipboard are
    /// never part of this: `BatchAdjustmentSyncService` only understands
    /// `AdjustmentPatch`'s stable field IDs, and giving it a second,
    /// parallel safety model for those fields is out of scope for this
    /// round (see `docs/coordination/CURRENT.md`).
    ///
    /// The target set is frozen synchronously -- `selectedPhotoIDs` is read
    /// into a local `let` before the `await` below, the same guarantee
    /// `beginBatchGesture` already gives the drag path, so a selection
    /// change while this runs cannot retarget it. The source photo itself
    /// (always a member of `selectedPhotoIDs` while it's open) is never its
    /// own sync target -- reported as `skipped` in the summary alert rather
    /// than silently dropped.
    @discardableResult
    func syncAdjustmentsToSelectedPhotos() async -> BatchAdjustmentTransaction? {
        guard let clipboard = adjustmentClipboard, let source = selectedPhotoID else { return nil }
        let frozenSelection = selectedPhotoIDs
        let targets = frozenSelection.subtracting([source])
        guard !targets.isEmpty else { return nil }
        let skipped = frozenSelection.count - targets.count

        let transaction = await batchSyncService.syncPatch(clipboard.patch, sourcePhotoID: source, targetPhotoIDs: targets)
        lastBatchTransaction = transaction
        for targetID in transaction.targetPhotoIDs where transaction.results[targetID] == .success {
            updateEditBadge(photoID: targetID, hasEdits: true)
        }
        let succeeded = transaction.results.values.filter { $0 == .success }.count
        let failed = transaction.results.count - succeeded
        alert = UserAlert(
            title: L10n.t("Sync to Selected Photos"),
            message: Self.batchSyncSummaryMessage(succeeded: succeeded, failed: failed, skipped: skipped)
        )
        return transaction
    }

    /// "Succeeded N, failed M, skipped K" report copy for
    /// `syncAdjustmentsToSelectedPhotos()`, following the same
    /// additive-parts convention `batchUndoSummaryMessage` already
    /// established. `skipped` here counts the source photo itself -- it's
    /// always part of the frozen selection snapshot but never its own sync
    /// target.
    nonisolated static func batchSyncSummaryMessage(succeeded: Int, failed: Int, skipped: Int) -> String {
        var parts: [String] = []
        if succeeded > 0 { parts.append("\(succeeded) \(L10n.t("synced"))") }
        if failed > 0 { parts.append("\(failed) \(L10n.t("failed to sync"))") }
        if skipped > 0 { parts.append("\(skipped) \(L10n.t("skipped"))") }
        return parts.isEmpty ? L10n.t("Nothing to sync.") : parts.joined(separator: ", ")
    }

    /// For `List(selection:)` and anything else that needs a two-way binding.
    var photoSelection: Binding<PhotoID?> {
        Binding(
            get: { [weak self] in self?.selectedPhotoID ?? nil },
            set: { [weak self] in self?.requestSelectPhoto($0) }
        )
    }

    var librarySelection: Binding<LibraryID?> {
        Binding(
            get: { [weak self] in self?.selectedLibraryID ?? nil },
            set: { [weak self] in self?.requestSelectLibrary($0) }
        )
    }

    private func enqueue(_ request: SelectionRequest) {
        pendingSelection = request
        guard !isApplyingSelection else { return }
        isApplyingSelection = true
        Task { [weak self] in
            await self?.applyPendingSelections()
        }
    }

    /// Serialised on purpose: two overlapping transitions could each flush the
    /// same dirty edit, or worse, commit out of order.
    private func applyPendingSelections() async {
        defer { isApplyingSelection = false }

        while let request = pendingSelection {
            pendingSelection = nil

            // Addendum §3.1: the edit reaches the sidecar before the UI moves on.
            guard await editor.flushPendingEdits() else {
                // The editor has already raised an actionable error. Stay
                // exactly where we are — including dropping queued requests,
                // since the user needs to deal with this before navigating.
                pendingSelection = nil
                return
            }

            switch request {
            case .photo(let photoID):
                commitPhotoSelection(photoID)
            case .library(let libraryID):
                commitLibrarySelection(libraryID)
            }
        }
    }

    /// Keeps the grid badge in step with what was just written. Resetting a
    /// photo back to neutral clears it again, which is why this takes the flag
    /// rather than only ever setting it.
    private func updateEditBadge(photoID: PhotoID, hasEdits: Bool) {
        guard let index = photos.firstIndex(where: { $0.id == photoID }),
              photos[index].hasEdits != hasEdits else { return }
        photos[index].hasEdits = hasEdits
    }

    private func commitPhotoSelection(_ photoID: PhotoID?) {
        guard photoID != selectedPhotoID else { return }
        selectedPhotoID = photoID
        // A plain click always opens exactly what was clicked -- if it
        // wasn't already part of an existing cmd-click batch, opening it
        // starts a fresh one rather than leaving a stale multi-selection
        // pointed at photos the user never asked to keep. Clicking a photo
        // that *is* already in the batch (its own row) just changes which
        // one is the sync source, leaving the rest of the batch intact.
        if let photoID, !selectedPhotoIDs.contains(photoID) {
            selectedPhotoIDs = [photoID]
        } else if photoID == nil {
            selectedPhotoIDs = []
        }
        handlePhotoSelectionChange()
    }

    private func commitLibrarySelection(_ libraryID: LibraryID?) {
        guard libraryID != selectedLibraryID else { return }
        selectedLibraryID = libraryID
        selectedPhotoID = nil
        selectedPhotoIDs = []
        handleLibrarySelectionChange()
    }

    var selectedLibrary: LibraryFolder? {
        guard let selectedLibraryID else { return nil }
        return libraries.first { $0.id == selectedLibraryID }
    }

    var selectedPhoto: PhotoAsset? {
        guard let selectedPhotoID else { return nil }
        return photos.first { $0.id == selectedPhotoID }
    }

    var isExporting: Bool {
        guard let exportState else { return false }
        return !exportState.isFinished
    }

    var thumbnailProvider: ThumbnailProvider? { services?.thumbnailProvider }

    // MARK: - Startup

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        do {
            let services = try AppServices.makeDefault()
            install(services: services)
            // Spec §7: resolve every saved bookmark and re-take its scope.
            libraries = try await services.libraryService.restoreLibraries()
            if selectedLibraryID == nil {
                // Nothing is open yet, so there is no edit to flush.
                commitLibrarySelection(
                    libraries.first(where: { $0.isOnline })?.id ?? libraries.first?.id
                )
            }
        } catch {
            startupFailure = (error as? LocalizedError)?.errorDescription
                ?? (error as NSError).localizedDescription
            alert = UserAlert(title: L10n.t("LumaHarbor couldn't start up"), error: error)
        }
    }

    // MARK: - Libraries

    func presentAddFolderPanel() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("Choose a photo folder")
        panel.message = L10n.t("Pick the folder on your drive that holds your RAW files.")
        panel.prompt = L10n.t("Add Folder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await addLibrary(at: url) }
    }

    func addLibrary(at url: URL) async {
        guard let services else { return }
        do {
            let folder = try await services.libraryService.addLibrary(at: url)
            libraries = await services.libraryService.knownLibraries()
            requestSelectLibrary(folder.id)
            startScan(libraryID: folder.id)
        } catch {
            alert = UserAlert(title: L10n.t("Couldn't add that folder"), error: error)
        }
    }

    /// Spec §7: when a bookmark no longer resolves, the user re-picks the folder
    /// and the library keeps its identity — and therefore its edits.
    func presentRelinkPanel(for libraryID: LibraryID) {
        guard let library = libraries.first(where: { $0.id == libraryID }) else { return }
        let panel = NSOpenPanel()
        panel.title = "\(L10n.t("Reconnect")) \(library.displayName)"
        panel.message = L10n.t("Choose the folder again to restore access to your photos.")
        panel.prompt = L10n.t("Reconnect")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await relink(libraryID: libraryID, to: url) }
    }

    func relink(libraryID: LibraryID, to url: URL) async {
        guard let services else { return }
        do {
            _ = try await services.libraryService.relink(libraryID: libraryID, to: url)
            libraries = await services.libraryService.knownLibraries()
            await reloadPhotos()
            startScan(libraryID: libraryID)
            editor.retrySaveAfterReconnect(
                isReadOnly: !(libraries.first { $0.id == libraryID }?.isWritable ?? false)
            )
        } catch {
            alert = UserAlert(title: L10n.t("Couldn't reconnect that folder"), error: error)
        }
    }

    func removeLibrary(_ libraryID: LibraryID) async {
        guard let services else { return }

        // Removing the folder the user is editing in takes the sidecar's
        // destination with it, so a pending edit has to land first. A failed
        // flush cancels the removal outright: losing the edit is far worse than
        // leaving the folder in the list, and the editor has already put an
        // actionable error on screen.
        if selectedLibraryID == libraryID {
            guard await editor.flushPendingEdits() else { return }
        }

        do {
            try await services.libraryService.removeLibrary(id: libraryID)
            libraries = await services.libraryService.knownLibraries()
            if selectedLibraryID == libraryID {
                // Safe to drop history now — it is already on disk.
                editor.close()
                commitLibrarySelection(libraries.first?.id)
            }
        } catch {
            alert = UserAlert(title: L10n.t("Couldn't remove that folder"), error: error)
        }
    }

    // MARK: - Virtual copies

    /// Phase 3 Task 3.5: creates an independently-editable "virtual copy" of
    /// `photo`, sharing its own RAW file on disk (never duplicated) but
    /// starting its own independent adjustments (an exact duplicate of
    /// `photo`'s own current edit, from this moment on). Reloads the grid
    /// so the new copy appears immediately, grouped next to its original.
    func duplicateAsVirtualCopy(_ photo: PhotoAsset, named name: String? = nil) async {
        guard let services else { return }
        do {
            try await services.libraryService.createVirtualCopy(of: photo, named: name)
        } catch {
            alert = UserAlert(title: L10n.t("Couldn't create a virtual copy"), error: error)
            return
        }
        await reloadPhotos()
    }

    /// Deletes `copy` -- its own sidecar and index row only, never the
    /// shared RAW file or any other photo (Phase 3 Task 3.5). The delete
    /// itself is attempted before touching any editor/selection state, so a
    /// failure (e.g. the drive went offline) never tears down an
    /// in-progress edit for nothing. If `copy` was the photo open in the
    /// editor, closes it once the delete has actually succeeded -- there's
    /// nothing left to flush once its sidecar is gone.
    func deleteVirtualCopy(_ copy: PhotoAsset) async {
        guard let services else { return }
        do {
            try await services.libraryService.deleteVirtualCopy(copy)
        } catch {
            alert = UserAlert(title: L10n.t("Couldn't delete this virtual copy"), error: error)
            return
        }
        selectedPhotoIDs.remove(copy.id)
        if selectedPhotoID == copy.id {
            invalidateOpenTask()
            editor.close()
            selectedPhotoID = nil
        }
        await reloadPhotos()
    }

    /// Re-checks whether the drive is still mounted. Called on window focus and
    /// after a failed operation, which is how "SSD unplugged" surfaces.
    func refreshAvailability() async {
        guard let services, let selectedLibraryID else { return }
        guard let updated = try? await services.libraryService
            .refreshAvailability(libraryID: selectedLibraryID) else { return }
        if let index = libraries.firstIndex(where: { $0.id == updated.id }) {
            libraries[index] = updated
        }
        editor.retrySaveAfterReconnect(isReadOnly: !updated.isWritable)
    }

    /// Runs after `commitLibrarySelection` has already cleared the photo
    /// selection — by this point any dirty edit has been flushed.
    private func handleLibrarySelectionChange() {
        // A pending open belongs to the folder we just left.
        invalidateOpenTask()
        editor.close()
        scanTask?.cancel()
        scanProgress = nil
        presetLibrary.updateLibraryRepository(
            selectedLibrary.map { FilePresetRepository(scope: .libraryPresets(libraryRootURL: $0.rootURL)) }
        )
        Task {
            await reloadPhotos()
            if let selectedLibraryID,
               let library = libraries.first(where: { $0.id == selectedLibraryID }),
               library.isOnline,
               library.lastScanAt == nil {
                startScan(libraryID: selectedLibraryID)
            }
        }
    }

    // MARK: - Scanning

    func startScan(libraryID: LibraryID? = nil) {
        guard let services else { return }
        guard let target = libraryID ?? selectedLibraryID else { return }

        scanTask?.cancel()
        scanProgress = ScanProgress(
            libraryID: target, indexedCount: 0, failedCount: 0, isFinished: false
        )

        scanTask = Task { [weak self] in
            for await event in services.libraryService.scan(libraryID: target) {
                guard !Task.isCancelled else { return }
                guard let self else { return }

                switch event {
                case .started:
                    continue

                case .photosIndexed(let batch):
                    // Spec §6.1: grow the grid as results arrive rather than
                    // blocking on the whole folder.
                    self.mergePhotos(batch)
                    self.scanProgress?.indexedCount += batch.count

                case .photoFailed:
                    self.scanProgress?.failedCount += 1

                case .finished(let result):
                    self.scanProgress?.indexedCount = result.indexedCount
                    self.scanProgress?.failedCount = result.failedCount
                    self.scanProgress?.isFinished = true
                    self.libraries = await services.libraryService.knownLibraries()
                    await self.reloadPhotos()
                    if let failure = result.manifestWriteFailure {
                        // The specific reason (read-only vs. out of space vs.
                        // ...) determines the right next step -- "unlock the
                        // drive" is correct advice for the first and actively
                        // wrong for the second, so this must come from the
                        // failing error's own recoverySuggestion rather than
                        // one hardcoded string for every cause (found by hand
                        // 2026-08-19 testing a disk-full drive: the message
                        // correctly said "insufficient space" but the next
                        // step still said to unlock the drive).
                        let nextStep = result.manifestWriteRecoverySuggestion
                            ?? L10n.t("Unlock the drive to save changes back to it.")
                        self.alert = UserAlert(
                            title: L10n.t("Scanned, but couldn't update the library file"),
                            message: failure,
                            nextStep: L10n.t("Your photos are still browsable.") + " " + nextStep
                        )
                    }

                case .failed(let error):
                    self.alert = UserAlert(title: L10n.t("Scan problem"), error: error)
                }
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanProgress?.isFinished = true
    }

    private func mergePhotos(_ batch: [PhotoAsset]) {
        var byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        for photo in batch {
            byID[photo.id] = photo
        }
        photos = Self.orderedForDisplay(Array(byID.values))
    }

    private func reloadPhotos() async {
        guard let services, let selectedLibraryID else {
            photos = []
            return
        }
        do {
            photos = Self.orderedForDisplay(
                try await services.libraryService.photos(inLibrary: selectedLibraryID)
            )
        } catch {
            photos = []
            alert = UserAlert(title: L10n.t("Couldn't read the local index"), error: error)
        }
    }

    /// Capture time when known, filename otherwise, so a folder of files with no
    /// EXIF still has a stable order.
    private static func displayOrder(_ lhs: PhotoAsset, _ rhs: PhotoAsset) -> Bool {
        switch (lhs.metadata.captureDate, rhs.metadata.captureDate) {
        case let (left?, right?) where left != right:
            return left < right
        default:
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    /// Phase 3 Task 3.5: every virtual copy is pulled out of its own natural
    /// `displayOrder` position and reinserted immediately after its
    /// original, in whichever relative order `displayOrder`'s own stable
    /// sort already gave same-original copies.
    ///
    /// A copy shares its original's `relativePath`/`captureDate` at the
    /// moment it's created, so in the common case `displayOrder` alone
    /// already ties them together and this function changes nothing
    /// visible. It stops being a no-op the moment the *original* is later
    /// relinked to a new path (the user renamed or moved the file) --
    /// `RelinkResolver` never touches a virtual copy's own record (it's
    /// invisible to scanning entirely, see that type's own doc comment), so
    /// the copy's `relativePath` stays frozen at whatever it was when
    /// duplicated. Without this grouping pass, that drift would silently
    /// separate a copy from an original that has since moved; grouping by
    /// `variantOf`'s `PhotoID` instead of by relativePath keeps them
    /// together regardless. A copy whose original isn't present in this
    /// same list (shouldn't happen in practice -- originals are never
    /// deleted through this app -- but never silently dropped if it does)
    /// falls back to its own natural sort position among the originals
    /// instead of vanishing.
    private static func orderedForDisplay(_ photos: [PhotoAsset]) -> [PhotoAsset] {
        let sorted = photos.sorted(by: displayOrder)
        var copiesByOriginal: [PhotoID: [PhotoAsset]] = [:]
        var originalsAndOrphanedCopies: [PhotoAsset] = []
        originalsAndOrphanedCopies.reserveCapacity(sorted.count)
        let knownIDs = Set(sorted.map(\.id))
        for photo in sorted {
            if let originalID = photo.variantOf, knownIDs.contains(originalID) {
                copiesByOriginal[originalID, default: []].append(photo)
            } else {
                originalsAndOrphanedCopies.append(photo)
            }
        }

        // `createVirtualCopy(of:)` explicitly allows a copy of a copy (its
        // own doc comment: "works whether `photo` is itself an original or
        // another virtual copy"), so a group's own members can themselves
        // have further copies grouped under *their* id. Appending each
        // group member's own group recursively -- rather than only the one
        // level `copiesByOriginal[photo.id]` gives directly -- is what
        // keeps every generation of a copy chain in `result` instead of
        // silently dropping anything past the first generation.
        func append(_ photo: PhotoAsset, into result: inout [PhotoAsset]) {
            result.append(photo)
            guard let copies = copiesByOriginal.removeValue(forKey: photo.id) else { return }
            for copy in copies {
                append(copy, into: &result)
            }
        }

        var result: [PhotoAsset] = []
        result.reserveCapacity(sorted.count)
        for photo in originalsAndOrphanedCopies {
            append(photo, into: &result)
        }
        return result
    }

    // MARK: - Photo selection

    /// Invalidates any in-flight photo open and hands back the token the next
    /// one should carry.
    @discardableResult
    private func invalidateOpenTask() -> UInt64 {
        openTask?.cancel()
        openTask = nil
        selectionGeneration += 1
        return selectionGeneration
    }

    private func handlePhotoSelectionChange() {
        let generation = invalidateOpenTask()

        guard let selectedPhotoID else {
            editor.close()
            return
        }
        guard let photo = photos.first(where: { $0.id == selectedPhotoID }),
              let library = selectedLibrary else { return }

        guard library.isOnline else {
            // Spec §10: offline libraries stay browsable, but the editor needs
            // the original file.
            editor.close()
            alert = UserAlert(
                title: L10n.t("This drive isn't connected"),
                message: L10n.t("LumaHarbor can show cached thumbnails, but editing needs the original file."),
                nextStep: L10n.t("Reconnect the drive, then try again.")
            )
            return
        }

        openTask = Task { [weak self] in
            guard let self, let services else { return }
            let url = photo.url(inLibraryRootedAt: library.rootURL)

            let loaded: Result<PhotoAdjustments, Error>
            do {
                loaded = .success(try await services.loadAdjustments(photo))
            } catch {
                loaded = .failure(error)
            }

            // The user may have moved on while the sidecar was being read. The
            // token *and* the current selection are both checked: a late read
            // must not open the photo they left, and must not drop its error
            // on top of the one they're looking at now either.
            guard !Task.isCancelled,
                  self.selectionGeneration == generation,
                  self.selectedPhotoID == photo.id,
                  self.selectedLibraryID == library.id else { return }

            switch loaded {
            case .success(let adjustments):
                self.editor.open(
                    photo: photo,
                    sourceURL: url,
                    adjustments: adjustments,
                    isReadOnly: !library.isWritable
                )
            case .failure(let error):
                // Spec §10: a damaged sidecar is reported, never silently
                // replaced. Open at neutral so the photo is still viewable.
                self.editor.open(
                    photo: photo,
                    sourceURL: url,
                    adjustments: .neutral,
                    isReadOnly: !library.isWritable
                )
                self.alert = UserAlert(title: L10n.t("Couldn't read saved edits"), error: error)
            }
        }
    }

    func selectNextPhoto() {
        movePhotoSelection(by: 1)
    }

    func selectPreviousPhoto() {
        movePhotoSelection(by: -1)
    }

    private func movePhotoSelection(by offset: Int) {
        guard !photos.isEmpty else { return }
        guard let current = selectedPhotoID,
              let index = photos.firstIndex(where: { $0.id == current }) else {
            requestSelectPhoto(photos.first?.id)
            return
        }
        let next = index + offset
        guard photos.indices.contains(next) else { return }
        requestSelectPhoto(photos[next].id)
    }

    // MARK: - Export

    func presentExportPanel(options: MacExportOptions) {
        guard let photo = selectedPhoto else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.t("Export Photo")
        panel.message = L10n.t("Choose where to save the exported photo.")
        panel.prompt = L10n.t("Export Here")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let directory = panel.url else { return }
        export(photo: photo, to: directory, options: options)
    }

    func export(photo: PhotoAsset, to directory: URL, options: MacExportOptions) {
        guard let services, let library = selectedLibrary else { return }

        exportTask?.cancel()
        let baseFilename = options.namingTemplate.render(ExportNamingTemplate.Context(
            originalFilename: photo.baseFilename,
            sequence: 1,
            date: photo.metadata.captureDate,
            // No per-photo "currently applied preset" is tracked yet, so
            // `.presetNameAndOriginalFilename` falls back to the plain
            // original filename here -- see `ExportNamingTemplate`'s own
            // doc comment on that fallback.
            presetName: nil,
            virtualCopyName: photo.variantName
        ))
        exportState = ExportState(
            photoID: photo.id,
            filename: baseFilename,
            isFinished: false,
            resultPath: nil
        )

        let request = ExportRequest(
            sourceURL: photo.url(inLibraryRootedAt: library.rootURL),
            adjustments: editor.adjustments,
            destinationDirectory: directory,
            baseFilename: baseFilename,
            format: options.format,
            quality: options.quality,
            bitDepth: options.bitDepth,
            maximumWidth: options.maximumWidth,
            maximumHeight: options.maximumHeight,
            dpi: options.dpi,
            exifRetentionPolicy: options.exifRetentionPolicy,
            collisionPolicy: options.collisionPolicy,
            watermark: options.watermark
        )

        exportTask = Task { [weak self] in
            do {
                let outcome = try await services.exporter.export(request)
                guard !Task.isCancelled else { return }
                self?.exportState = ExportState(
                    photoID: photo.id,
                    filename: outcome.url.lastPathComponent,
                    isFinished: true,
                    resultPath: outcome.url.path
                )
            } catch is CancellationError {
                self?.exportState = nil
            } catch ExportError.skippedExistingFile {
                guard !Task.isCancelled else { return }
                self?.exportState = ExportState(
                    photoID: photo.id,
                    filename: baseFilename,
                    isFinished: true,
                    resultPath: nil,
                    wasSkipped: true
                )
            } catch {
                guard !Task.isCancelled else { return }
                self?.exportState = nil
                self?.alert = UserAlert(title: L10n.t("Export failed"), error: error)
            }
        }
    }

    /// Spec §6.3: a cancelled export removes its partial output.
    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportState = nil
    }

    func revealExportInFinder() {
        guard let path = exportState?.resultPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Batch export (Phase 5 Task 5.1)

    func presentBatchExportPanel(options: MacExportOptions) {
        guard !selectedPhotoIDs.isEmpty, selectedLibrary != nil else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.t("Export Photos")
        panel.message = L10n.t("Choose where to save the exported photos.")
        panel.prompt = L10n.t("Export Here")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let directory = panel.url else { return }
        startBatchExport(
            to: directory,
            options: options,
            includeRejected: includeRejectedInBatchExport
        )
    }

    /// Exports every photo in `selectedPhotoIDs` through `batchExportQueue`,
    /// reusing the same `PhotoExporter` guarantees (full-resolution re-decode,
    /// no silent overwrite, no partial output on cancel) a single-photo
    /// export already relies on.
    ///
    /// Each target uses its own adjustments: the currently open photo's live
    /// in-editor state if it's part of the selection (matching what a
    /// single-photo export of that same photo would use), its saved sidecar
    /// otherwise -- every other selected photo is, by definition, not open
    /// in the editor.
    func startBatchExport(
        to directory: URL,
        options: MacExportOptions,
        includeRejected: Bool? = nil
    ) {
        guard let services, let library = selectedLibrary else { return }
        let includeRejected = includeRejected ?? includeRejectedInBatchExport
        let targets = photos.filter {
            selectedPhotoIDs.contains($0.id) && (includeRejected || $0.flag != .reject)
        }
        guard !targets.isEmpty else { return }

        batchExportTask?.cancel()
        isBatchExporting = true
        // Seeded with `.neutral` placeholders so the sheet has something to
        // show (filenames, pending status) the instant the batch starts,
        // before any per-photo adjustments have actually loaded.
        batchExportItems = targets.enumerated().map { index, target in
            BatchExportItem(request: batchExportRequest(
                target, sequence: index + 1, library: library, directory: directory, options: options, adjustments: .neutral
            ))
        }

        let openPhotoID = selectedPhotoID
        let liveAdjustments = editor.adjustments
        let loadAdjustments = services.loadAdjustments

        batchExportTask = Task { [weak self] in
            guard let self else { return }
            var requests: [ExportRequest] = []
            for (index, target) in targets.enumerated() {
                let adjustments: PhotoAdjustments
                if target.id == openPhotoID {
                    adjustments = liveAdjustments
                } else {
                    adjustments = (try? await loadAdjustments(target)) ?? .neutral
                }
                requests.append(self.batchExportRequest(
                    target, sequence: index + 1, library: library, directory: directory, options: options, adjustments: adjustments
                ))
            }

            guard !Task.isCancelled else {
                self.batchExportItems = requests.map { BatchExportItem(request: $0, status: .cancelled) }
                self.isBatchExporting = false
                return
            }

            _ = await self.batchExportQueue.run(requests) { [weak self] items in
                guard let self else { return }
                await MainActor.run { self.batchExportItems = items }
            }
            self.isBatchExporting = false
        }
    }

    /// Cancellation is cooperative, the same pattern `cancelExport()` above
    /// uses: cancel the `Task`, and let `BatchExportQueue.run` (and
    /// `PhotoExporter` underneath it) notice and unwind on their own.
    func cancelBatchExport() {
        batchExportTask?.cancel()
    }

    /// Closes the batch export sheet. A finished (or cancelled) report is
    /// cleared so reopening the sheet starts clean; a still-running batch's
    /// live progress is preserved so reopening the sheet shows where it
    /// actually is, rather than discarding an in-flight export's status.
    func closeBatchExportSheet() {
        isShowingBatchExportSheet = false
        if !isBatchExporting {
            batchExportItems = []
        }
    }

    private func batchExportRequest(
        _ photo: PhotoAsset,
        sequence: Int,
        library: LibraryFolder,
        directory: URL,
        options: MacExportOptions,
        adjustments: PhotoAdjustments
    ) -> ExportRequest {
        let baseFilename = options.namingTemplate.render(ExportNamingTemplate.Context(
            originalFilename: photo.baseFilename,
            sequence: sequence,
            date: photo.metadata.captureDate,
            // See the matching comment in `export(photo:to:options:)`.
            presetName: nil,
            virtualCopyName: photo.variantName
        ))
        return ExportRequest(
            sourceURL: photo.url(inLibraryRootedAt: library.rootURL),
            adjustments: adjustments,
            destinationDirectory: directory,
            baseFilename: baseFilename,
            format: options.format,
            quality: options.quality,
            bitDepth: options.bitDepth,
            maximumWidth: options.maximumWidth,
            maximumHeight: options.maximumHeight,
            dpi: options.dpi,
            exifRetentionPolicy: options.exifRetentionPolicy,
            collisionPolicy: options.collisionPolicy,
            watermark: options.watermark
        )
    }
}
