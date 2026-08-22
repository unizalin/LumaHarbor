import CoreGraphics
import Localization
import Foundation
import PhotoLibraryCore
import PresetCore
import RawProcessingCore
import SwiftUI

/// Whether the current edit has reached the SSD.
enum SaveState: Equatable {
    case unchanged
    case pending
    case saving
    case saved(Date)
    /// Spec §8.2: a failed write must never read as "saved".
    case failed(String)

    var isDirty: Bool {
        switch self {
        case .unchanged, .saved: return false
        case .pending, .saving, .failed: return true
        }
    }
}

/// Drives the editing surface for one photo.
@MainActor
final class EditorViewModel: ObservableObject {
    /// How long the sliders must be still before the high-quality preview and
    /// the sidecar write are scheduled. Long enough that a drag doesn't queue
    /// dozens of full renders, short enough to feel automatic.
    static let settleDelay = Duration.milliseconds(350)
    static let autosaveDelay = Duration.milliseconds(700)
    /// Floor between interactive preview submissions while dragging. RAW decode
    /// can't be interrupted mid-call (spec §11), so submitting faster than one
    /// decode can finish just queues dead work; this caps the submit rate
    /// instead of relying on cancellation to save time it can't actually save.
    static let interactiveThrottleInterval = Duration.milliseconds(80)
    /// How many times `flushPendingEdits()` will re-save when the user keeps
    /// editing during the write. Generous enough never to be hit by a human,
    /// small enough that a stuck state can't spin forever.
    static let maximumFlushAttempts = 8

    @Published private(set) var photo: PhotoAsset?
    @Published private(set) var sourceURL: URL?
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var originalImage: CGImage?
    @Published private(set) var previewQuality: PreviewQuality = .interactive
    @Published private(set) var isRendering = false
    @Published private(set) var saveState: SaveState = .unchanged
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var isShowingOriginal = false
    @Published var alert: UserAlert?

    /// Longest edge the preview should cover, in backing-store pixels.
    @Published var previewPixelDimension = 1_600

    /// Fires after a successful sidecar write so the grid's edit badge can
    /// follow along. Addendum §3.2: this is the *only* thing a save changes in
    /// the browser — the neutral thumbnail is deliberately left alone.
    var onSaved: ((PhotoID, Bool) -> Void)?

    private var history = EditHistory<PhotoAdjustments>(initial: .neutral)
    /// What's actually on disk for this photo right now — set on `open()`, kept
    /// in step by a successful `save()`. `didChangeAdjustments()` compares
    /// `history.current` against this rather than just reacting to "an edit
    /// happened", so undoing or resetting back to the saved value clears
    /// dirtiness. Without that, a single touch on a read-only photo leaves
    /// `saveState` stuck at `.failed` forever — `flushPendingEdits()` refuses
    /// to write next-to-nothing, and since `resetAll()`/`undo()` re-mark
    /// `.pending` unconditionally, there was no way back to a clean state and
    /// therefore no way to navigate away at all (found manually 2026-08-18).
    private var lastSavedAdjustments: PhotoAdjustments = .neutral
    private var services: AppServices?
    private var eventTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var originalRenderTask: Task<Void, Never>?
    private var interactiveThrottleTask: Task<Void, Never>?
    private var lastInteractiveSubmit: ContinuousClock.Instant?
    private var isReadOnlyLibrary = false
    /// Generations increase globally, so this alone rejects any frame that is
    /// older than what's already on screen.
    private var lastDisplayedGeneration: UInt64 = 0

    /// The as-shot neutral for the currently open photo, captured from the
    /// first preview that reports one. Needed to turn a preset's absolute
    /// Kelvin/tint into LumaHarbor's relative offsets (spec §5.3); cleared on
    /// every `open()`/`close()` so a preset previewed for one photo can never
    /// be resolved against another's baseline.
    private var whiteBalanceBaseline: RawWhiteBalanceBaseline?

    /// A preset applied via `previewPreset(_:mode:)`, not yet committed.
    /// Transient by construction: nothing here ever reaches `history`,
    /// `saveState` or autosave (spec §5.3/§9.1) -- only what's drawn changes.
    private var previewedPresetAdjustments: PhotoAdjustments?

    /// What `previewPreset(_:mode:)` reported about the *currently previewed*
    /// preset -- e.g. a contextual leaf skipped for lack of a white-balance
    /// baseline yet. Published (not thrown away like `applying(_:mode:)`
    /// used to with `try?`) so the preset browser can show something
    /// non-blocking while hovering, without a modal firing on every row.
    @Published private(set) var presetPreviewDiagnostics: [PresetDiagnostic] = []

    var adjustments: PhotoAdjustments { history.current }

    /// What the preview pipeline should actually render: a live preset
    /// preview if one is active, otherwise the committed edit.
    var displayedAdjustments: PhotoAdjustments { previewedPresetAdjustments ?? history.current }

    var hasEdits: Bool { !history.current.isNeutral }

    /// What the main view should draw right now.
    var displayedImage: CGImage? {
        if isShowingOriginal, let originalImage { return originalImage }
        return previewImage
    }

    var canCompareWithOriginal: Bool { originalImage != nil && hasEdits }

    deinit {
        eventTask?.cancel()
        settleTask?.cancel()
        autosaveTask?.cancel()
        originalRenderTask?.cancel()
        interactiveThrottleTask?.cancel()
    }

    func attach(services: AppServices) {
        guard self.services == nil else { return }
        self.services = services
        startObservingPreviews(scheduler: services.previewScheduler)
    }

    // MARK: - Opening

    func open(
        photo: PhotoAsset,
        sourceURL: URL,
        adjustments: PhotoAdjustments,
        isReadOnly: Bool
    ) {
        cancelPendingWork()

        self.photo = photo
        self.sourceURL = sourceURL
        self.history = EditHistory(initial: adjustments)
        self.lastSavedAdjustments = adjustments
        self.isReadOnlyLibrary = isReadOnly
        self.previewImage = nil
        self.originalImage = nil
        self.isShowingOriginal = false
        self.saveState = .unchanged
        self.lastDisplayedGeneration = 0
        self.whiteBalanceBaseline = nil
        self.previewedPresetAdjustments = nil
        self.presetPreviewDiagnostics = []
        refreshUndoState()

        submitInteractivePreview()
        scheduleSettledPreview()
        renderOriginalReference()
    }

    /// Tears the editor down.
    ///
    /// Callers must have called `flushPendingEdits()` first and seen it succeed
    /// — this drops `history`, so anything unsaved at this point is gone.
    func close() {
        cancelPendingWork()
        photo = nil
        sourceURL = nil
        previewImage = nil
        originalImage = nil
        history = EditHistory(initial: .neutral)
        saveState = .unchanged
        whiteBalanceBaseline = nil
        previewedPresetAdjustments = nil
        presetPreviewDiagnostics = []
        refreshUndoState()
        if let scheduler = services?.previewScheduler {
            Task { await scheduler.cancelAll() }
        }
    }

    // MARK: - Editing

    func setAdjustment(_ kind: AdjustmentKind, to value: Double) {
        guard photo != nil else { return }
        guard history.setAdjustment(kind, to: value) else { return }
        didChangeAdjustments()
    }

    func resetAdjustment(_ kind: AdjustmentKind) {
        guard photo != nil, history.resetAdjustment(kind) else { return }
        didChangeAdjustments()
    }

    func resetAll() {
        guard photo != nil, history.resetToNeutral() else { return }
        didChangeAdjustments()
    }

    func undo() {
        guard history.undo() != nil else { return }
        didChangeAdjustments()
    }

    func redo() {
        guard history.redo() != nil else { return }
        didChangeAdjustments()
    }

    // MARK: - Presets

    /// Shows what a preset would look like, without touching history, dirty
    /// state or autosave (spec §5.3, §9.1: hover/keyboard preview is purely
    /// visual). Applied on top of the *committed* edit, not any preview
    /// already in progress, so repeated hovering over a list never compounds.
    ///
    /// Uses `requestInteractivePreview()` (the throttled entry point every
    /// slider-driven edit goes through), not `submitInteractivePreview()`
    /// directly -- quickly hovering across several rows must coalesce into
    /// one decode, not queue one un-interruptible full RAW decode per row.
    /// The state update below is synchronous and unthrottled, so whichever
    /// preset was hovered *last* is always what a delayed/coalesced
    /// submission actually renders.
    func previewPreset(_ preset: PresetDocument, mode: PresetApplicationMode) {
        guard photo != nil else { return }
        let result = applying(preset, mode: mode)
        previewedPresetAdjustments = result.adjustments
        presetPreviewDiagnostics = result.diagnostics
        requestInteractivePreview()
    }

    /// Restores the render to the committed edit. Safe to call even if no
    /// preview is active.
    func cancelPresetPreview() {
        guard previewedPresetAdjustments != nil else { return }
        previewedPresetAdjustments = nil
        presetPreviewDiagnostics = []
        requestInteractivePreview()
        scheduleSettledPreview()
    }

    /// Applies a preset as one undoable step, regardless of how many leaves
    /// it touches (spec §5.3: one click, one Undo entry). Never calls
    /// `history.record` more than once.
    ///
    /// Unlike hover preview, a diagnostic here (e.g. white balance skipped
    /// because no baseline was available yet) surfaces through `alert` --
    /// this is a deliberate, one-time action the user chose, not something
    /// that fires continuously while moving the pointer, so a single
    /// non-blocking-but-visible notice is appropriate where a modal on every
    /// hover would not be.
    func commitPreset(_ preset: PresetDocument, mode: PresetApplicationMode) {
        guard photo != nil else { return }
        let result = applying(preset, mode: mode)
        previewedPresetAdjustments = nil
        presetPreviewDiagnostics = []
        guard history.record(result.adjustments) else { return }
        if let message = Self.userMessage(for: result.diagnostics) {
            alert = UserAlert(title: L10n.t("This preset was applied with some limitations"), message: message)
        }
        didChangeAdjustments()
    }

    /// Safe, fixed, localizable text per diagnostic code -- never the
    /// diagnostic's own `detail` (spec §11: user-facing text must not carry
    /// unvetted internal detail). `nil` when there's nothing worth telling
    /// the user about.
    private static func userMessage(for diagnostics: [PresetDiagnostic]) -> String? {
        guard !diagnostics.isEmpty else { return nil }
        var messages: [String] = []
        if diagnostics.contains(where: { $0.code == "missingWhiteBalanceBaseline" }) {
            messages.append(L10n.t("White balance from this preset couldn't be applied yet because this photo hasn't finished decoding."))
        }
        if diagnostics.contains(where: { $0.code == "clampedWhiteBalance" }) {
            messages.append(L10n.t("White balance from this preset was adjusted to stay within the allowed range."))
        }
        if messages.isEmpty {
            messages.append(L10n.t("Some settings in this preset couldn't be applied exactly as specified."))
        }
        return messages.joined(separator: " ")
    }

    private func applying(_ preset: PresetDocument, mode: PresetApplicationMode) -> PresetApplicationResult {
        let temperatureIsAbsoluteKelvin: Bool
        switch preset.source {
        case .native: temperatureIsAbsoluteKelvin = false
        case .adobeXMP: temperatureIsAbsoluteKelvin = true
        }
        let context = PresetApplicationContext(
            baselineTemperatureKelvin: whiteBalanceBaseline?.temperatureKelvin,
            baselineTint: whiteBalanceBaseline?.tint
        )
        return PresetApplicator().apply(
            preset.patch,
            to: history.current,
            mode: mode,
            context: context,
            temperatureIsAbsoluteKelvin: temperatureIsAbsoluteKelvin
        )
    }

    private func didChangeAdjustments() {
        refreshUndoState()
        // Interactive first so the slider keeps up (spec §11), then the good one
        // once the user stops -- the preview always follows the sliders,
        // dirty or not.
        requestInteractivePreview()
        scheduleSettledPreview()

        if history.current == lastSavedAdjustments {
            // Undid or reset back to what's already on disk: nothing to write.
            autosaveTask?.cancel()
            autosaveTask = nil
            saveState = .unchanged
        } else {
            saveState = .pending
            scheduleAutosave()
        }
    }

    private func refreshUndoState() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    // MARK: - Preview

    private func requestPreview(quality: PreviewQuality) {
        guard let photo, let sourceURL, let services else { return }
        isRendering = true
        let request = PreviewRequest(
            subject: PreviewSubject(photo.id.rawValue),
            url: sourceURL,
            adjustments: displayedAdjustments,
            targetPixelDimension: previewPixelDimension,
            quality: quality
        )
        Task { await services.previewScheduler.submit(request) }
    }

    /// Submits an interactive preview, but never faster than
    /// `interactiveThrottleInterval` — a rapid drag coalesces into the last
    /// value instead of queueing one decode per tick (spec §11).
    private func requestInteractivePreview() {
        let now = ContinuousClock.now
        if let last = lastInteractiveSubmit,
           now - last < Self.interactiveThrottleInterval {
            interactiveThrottleTask?.cancel()
            interactiveThrottleTask = Task { [weak self] in
                try? await Task.sleep(for: Self.interactiveThrottleInterval)
                guard !Task.isCancelled else { return }
                self?.submitInteractivePreview()
            }
            return
        }
        submitInteractivePreview()
    }

    private func submitInteractivePreview() {
        interactiveThrottleTask?.cancel()
        interactiveThrottleTask = nil
        lastInteractiveSubmit = ContinuousClock.now
        requestPreview(quality: .interactive)
    }

    private func scheduleSettledPreview() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.requestPreview(quality: .high)
        }
    }

    /// Renders the untouched photo once per open, so holding the compare key is
    /// instant instead of queueing a decode behind the edited preview.
    private func renderOriginalReference() {
        guard let photo, let sourceURL, let services else { return }
        originalRenderTask?.cancel()
        let request = PreviewRequest(
            subject: PreviewSubject(photo.id.rawValue),
            url: sourceURL,
            adjustments: .neutral,
            targetPixelDimension: previewPixelDimension,
            quality: .interactive
        )
        let renderer = services.previewRenderer
        let openedPhotoID = photo.id
        originalRenderTask = Task { [weak self] in
            guard let image = try? await renderer.render(request) else { return }
            guard !Task.isCancelled else { return }
            // The user may have moved on while this was decoding.
            guard let self, self.photo?.id == openedPhotoID else { return }
            self.originalImage = image.cgImage
        }
    }

    private func startObservingPreviews(scheduler: PreviewScheduler) {
        eventTask?.cancel()
        // `Task {}` here inherits `@MainActor`, so the handler runs on the main
        // actor while the stream itself suspends off it.
        eventTask = Task { [weak self] in
            for await event in scheduler.events {
                guard !Task.isCancelled else { return }
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: PreviewEvent) {
        switch event {
        case .produced(let result):
            // The scheduler already dropped stale work; this is the second half
            // of the guarantee — the view model refuses anything that isn't the
            // photo currently open (spec §9).
            guard let photo, result.token.subject.rawValue == photo.id.rawValue else { return }
            guard result.token.generation > lastDisplayedGeneration else { return }
            lastDisplayedGeneration = result.token.generation
            previewImage = result.image.cgImage
            previewQuality = result.quality
            if let baseline = result.image.whiteBalanceBaseline {
                whiteBalanceBaseline = baseline
            }
            // An interactive frame means the settled render is still to come.
            isRendering = result.quality == .interactive

        case .failed(let token, let error):
            guard let photo, token.subject.rawValue == photo.id.rawValue else { return }
            isRendering = false
            // A failed decode must not leave the previous photo's frame on
            // screen looking like a successful one (Gate E: no fake success).
            previewImage = nil
            alert = UserAlert(title: L10n.t("Couldn't show this photo"), error: error)
        }
    }

    // MARK: - Saving

    private func scheduleAutosave() {
        guard !isReadOnlyLibrary else {
            saveState = .failed(L10n.t("This drive is read-only, so edits can't be saved."))
            return
        }
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }

    /// Writes the sidecar now. Also used by ⌘S and by "close photo".
    func save() async {
        guard let photo, let services, saveState.isDirty else { return }
        let adjustments = history.current
        saveState = .saving
        do {
            try await services.saveAdjustments(adjustments, photo)
            lastSavedAdjustments = adjustments
            // Only report success once the atomic write actually returned.
            if history.current == adjustments {
                saveState = .saved(Date())
            }
            onSaved?(photo.id, !adjustments.isNeutral)
        } catch {
            saveState = .failed(
                (error as? LocalizedError)?.errorDescription
                    ?? (error as NSError).localizedDescription
            )
            alert = UserAlert(title: L10n.t("Couldn't save your edits"), error: error)
        }
    }

    /// Writes everything the user has typed, and keeps writing until the sidecar
    /// matches what is actually on screen.
    ///
    /// Addendum §3.1: leaving a photo must not race the autosave debounce. The
    /// loop exists because the user can keep dragging while a write is in
    /// flight — reporting the first snapshot as "all saved" would lose whatever
    /// they did during it.
    ///
    /// Returns `false` when the edit is still unsaved, in which case the caller
    /// must stay exactly where it is.
    @discardableResult
    func flushPendingEdits() async -> Bool {
        // The debounce is about to be redundant either way.
        autosaveTask?.cancel()
        autosaveTask = nil

        guard photo != nil, saveState.isDirty else { return true }

        if isReadOnlyLibrary {
            // Nothing can be written. Saying so here is what stops the caller
            // navigating away and dropping the edit on the floor.
            saveState = .failed(L10n.t("This drive is read-only, so edits can't be saved."))
            alert = UserAlert(
                title: L10n.t("Couldn't save your edits"),
                message: L10n.t("This drive is read-only, so LumaHarbor can't write next to your photos."),
                nextStep: L10n.t("Unlock the drive, or copy the library somewhere writable, then try again.")
            )
            return false
        }

        // Bounded so a user who never stops dragging can't wedge the transition.
        for _ in 0..<Self.maximumFlushAttempts {
            guard saveState.isDirty else { return true }
            await save()
            switch saveState {
            case .failed:
                return false
            case .saved, .unchanged:
                return true
            case .pending, .saving:
                // `save()` only reports success when the snapshot it wrote is
                // still current; anything else means the edit moved under us.
                continue
            }
        }
        return !saveState.isDirty
    }

    /// Called when the drive comes back after being unplugged mid-edit.
    /// Spec §10: in-memory adjustments are kept and the save is retried.
    func retrySaveAfterReconnect(isReadOnly: Bool) {
        isReadOnlyLibrary = isReadOnly
        guard !isReadOnly, saveState.isDirty else { return }
        Task { await save() }
    }

    private func cancelPendingWork() {
        settleTask?.cancel()
        autosaveTask?.cancel()
        originalRenderTask?.cancel()
        interactiveThrottleTask?.cancel()
        settleTask = nil
        autosaveTask = nil
        originalRenderTask = nil
        interactiveThrottleTask = nil
        lastInteractiveSubmit = nil
    }
}
