import Combine
import CoreGraphics
import Foundation
import Localization
import PhotoLibraryCore
import PresetCore
import RawProcessingCore

/// Whether the current edit has reached the SSD.
public enum SaveState: Equatable, Sendable {
    case unchanged
    case pending
    case saving
    case saved(Date)
    /// Spec §8.2: a failed write must never read as "saved".
    case failed(String)

    public var isDirty: Bool {
        switch self {
        case .unchanged, .saved: return false
        case .pending, .saving, .failed: return true
        }
    }
}

/// Drives the editing surface for one photo.
@MainActor
public final class EditorSession: ObservableObject {
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

    @Published public private(set) var photo: PhotoAsset?
    @Published public private(set) var sourceURL: URL?
    @Published public private(set) var previewImage: CGImage?
    @Published public private(set) var originalImage: CGImage?
    @Published public private(set) var previewQuality: PreviewQuality = .interactive
    @Published public private(set) var isRendering = false

    /// True once a decode has failed and nothing since -- a new photo
    /// opened, a fresh frame produced -- has superseded that outcome. Lets
    /// `EditorView` tell "still working" (`isRendering`) apart from "gave up
    /// for good"; without this, `previewImage == nil` alone can't
    /// distinguish the two, and the view fell back to showing an indefinite
    /// "Decoding RAW…" spinner after a decode failure even though nothing
    /// was actually running (round 3 smoke test: opening a corrupt RAW,
    /// dismissing the alert, and being stuck looking like it's still
    /// decoding forever).
    @Published public private(set) var decodeFailed = false

    /// The RGB histogram of the currently displayed preview frame -- parity
    /// design spec §6.2: it must track `previewImage`, not the RAW file's
    /// own fixed metadata. `nil` before anything has rendered, after a
    /// decode failure, or once the photo closes; never a stale histogram
    /// left over from a previous photo or a superseded frame (see
    /// `scheduleHistogramComputation(for:generation:)`).
    @Published public private(set) var histogram: HistogramData?

    @Published public private(set) var saveState: SaveState = .unchanged
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false
    @Published public var isShowingOriginal = false
    @Published public var alert: EditorAlert?

    /// Longest edge the preview should cover, in backing-store pixels.
    @Published public var previewPixelDimension = 1_600

    /// Fires after a successful sidecar write so the grid's edit badge can
    /// follow along. Addendum §3.2: this is the *only* thing a save changes in
    /// the browser — the neutral thumbnail is deliberately left alone.
    public var onSaved: ((PhotoID, Bool) -> Void)?

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
    private var services: EditorDependencies?
    private var eventTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var histogramTask: Task<Void, Never>?
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
    @Published public private(set) var presetPreviewDiagnostics: [PresetDiagnostic] = []

    /// The exact, safe text `PresetBrowserView` shows for the current hover
    /// preview -- `nil` when there's nothing to say, so the caller can drop
    /// the row entirely rather than reserve space for an empty message
    /// (round 2, finding #3: this was published but never read by any
    /// View). Recomputed from `presetPreviewDiagnostics` rather than stored
    /// separately, so there is exactly one source of truth for "is there a
    /// diagnostic right now" and it can never drift out of sync with it.
    public var presetPreviewMessage: String? { Self.userMessage(for: presetPreviewDiagnostics) }

    /// Round 3 (Codex re-review): a hover/keyboard preset preview used to
    /// call `requestInteractivePreview()` unconditionally on every hover,
    /// even when the preset resolved to exactly the committed adjustments
    /// (nothing to render, only a diagnostic to show) or when the render it
    /// triggered failed -- against a photo whose decode fails outright, that
    /// meant every hover kicked off a fresh doomed decode and popped the
    /// modal `alert` used for "the photo itself can't be shown", burying the
    /// non-modal `presetPreviewMessage` underneath it and flooding the
    /// screen with alerts as the pointer moved. The four properties below
    /// are what let `previewPreset`/`cancelPresetPreview`/`handle(_:)` tell
    /// "this decode was submitted while previewing, and is still the most
    /// recent preview intent" apart from every other kind of render request,
    /// so a preview-originated failure can be shown safely instead.

    /// Bumped by every call that changes what the *current* preview intent
    /// is -- a new hover (whether or not it actually submits a decode), or a
    /// cancel -- independently of whether a decode was submitted. A
    /// preview-context frame or failure tagged with an older intent must
    /// never be applied, even if the scheduler itself still considers it
    /// current: a no-op hover deliberately skips submitting a replacement
    /// decode (see `previewPreset` below), so the scheduler never learns the
    /// prior in-flight one is now stale. This is what makes "the
    /// most-recently-hovered preset always wins" hold even across that case.
    private var previewIntentVersion: UInt64 = 0

    /// Which (scheduler generation, intent version) pair the most recently
    /// *submitted* preview-context decode belongs to. `nil` whenever nothing
    /// preview-related is in flight or expected.
    private var previewRequestGeneration: (schedulerGeneration: UInt64, intentVersion: UInt64)?

    /// True once a preview-context decode has actually landed and changed
    /// what `previewImage` shows since the current preview started -- i.e.
    /// the screen no longer matches the committed render. Only then does
    /// `cancelPresetPreview()` need to submit a fresh decode to put the
    /// committed render back; if the preview never produced a frame (still
    /// in flight, a no-op, or itself failed and therefore never touched
    /// `previewImage`), there is nothing on screen to restore, and
    /// re-decoding anyway would just risk failing a second time for exactly
    /// the photo that made the first attempt fail -- reproducing the same
    /// alert flood one step later, on hover-*out* instead of hover-in.
    private var previewImageReflectsAPreview = false

    /// The exact, safe text for a preview-context render failure -- e.g. a
    /// preset that genuinely changes the picture, hovered over a photo whose
    /// decode fails. Never the modal `alert` (spec: a general/committed
    /// render failure keeps using that; only a *preview's* failure moves
    /// here), and never the underlying error's own detail (same rule as
    /// `userMessage(for:)` below). A single overwritable value, not a list,
    /// so repeated failures for the same or different hovered presets
    /// de-duplicate onto one line instead of accumulating.
    @Published public private(set) var previewRenderFailureMessage: String?

    public var adjustments: PhotoAdjustments { history.current }

    /// What the preview pipeline should actually render: a live preset
    /// preview if one is active, otherwise the committed edit.
    public var displayedAdjustments: PhotoAdjustments { previewedPresetAdjustments ?? history.current }

    public var hasEdits: Bool { !history.current.isNeutral }

    /// What the main view should draw right now.
    public var displayedImage: CGImage? {
        if isShowingOriginal, let originalImage { return originalImage }
        return previewImage
    }

    public var canCompareWithOriginal: Bool { originalImage != nil && hasEdits }

    public init() {}

    deinit {
        eventTask?.cancel()
        settleTask?.cancel()
        autosaveTask?.cancel()
        histogramTask?.cancel()
        originalRenderTask?.cancel()
        interactiveThrottleTask?.cancel()
    }

    public func attach(dependencies: EditorDependencies) {
        guard services == nil else { return }
        services = dependencies
        startObservingPreviews(scheduler: dependencies.previewScheduler)
    }

    // MARK: - Opening

    public func open(
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
        self.decodeFailed = false
        self.histogram = nil
        self.originalImage = nil
        self.isShowingOriginal = false
        self.saveState = .unchanged
        self.lastDisplayedGeneration = 0
        self.whiteBalanceBaseline = nil
        self.previewedPresetAdjustments = nil
        self.presetPreviewDiagnostics = []
        self.previewRenderFailureMessage = nil
        self.previewIntentVersion += 1
        self.previewRequestGeneration = nil
        self.previewImageReflectsAPreview = false
        refreshUndoState()

        submitInteractivePreview()
        scheduleSettledPreview()
        renderOriginalReference()
    }

    /// Tears the editor down.
    ///
    /// Callers must have called `flushPendingEdits()` first and seen it succeed
    /// — this drops `history`, so anything unsaved at this point is gone.
    public func close() {
        cancelPendingWork()
        photo = nil
        sourceURL = nil
        previewImage = nil
        decodeFailed = false
        histogram = nil
        originalImage = nil
        history = EditHistory(initial: .neutral)
        saveState = .unchanged
        whiteBalanceBaseline = nil
        previewedPresetAdjustments = nil
        presetPreviewDiagnostics = []
        previewRenderFailureMessage = nil
        previewIntentVersion += 1
        previewRequestGeneration = nil
        previewImageReflectsAPreview = false
        refreshUndoState()
        if let scheduler = services?.previewScheduler {
            Task { await scheduler.cancelAll() }
        }
    }

    // MARK: - Editing

    public func setAdjustment(_ kind: AdjustmentKind, to value: Double) {
        guard photo != nil else { return }
        guard history.setAdjustment(kind, to: value) else { return }
        didChangeAdjustments()
    }

    public func resetAdjustment(_ kind: AdjustmentKind) {
        guard photo != nil, history.resetAdjustment(kind) else { return }
        didChangeAdjustments()
    }

    public func resetAll() {
        guard photo != nil, history.resetToNeutral() else { return }
        didChangeAdjustments()
    }

    /// General entry point for editing fields `setAdjustment(_:to:)` can't
    /// reach -- `hsl`, `advancedToneCurve`, `sharpening`, `noiseReduction`,
    /// `vignette` and `grain` have no `AdjustmentKind` case of their own, so
    /// the Color/Curve/Detail/Effects inspector panels (Phase 1 Task 3) go
    /// through this instead. Goes through exactly the same undo/autosave
    /// path as `setAdjustment(_:to:)`: `history.record` is a no-op when the
    /// transform doesn't actually change anything, and `clamped()` keeps a
    /// caller-supplied out-of-range value from reaching the render pipeline.
    public func updateAdjustments(_ transform: (inout PhotoAdjustments) -> Void) {
        guard photo != nil else { return }
        var updated = history.current
        transform(&updated)
        guard history.record(updated.clamped()) else { return }
        didChangeAdjustments()
    }

    public func undo() {
        guard history.undo() != nil else { return }
        didChangeAdjustments()
    }

    public func redo() {
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
    public func previewPreset(_ preset: PresetDocument, mode: PresetApplicationMode) {
        guard photo != nil else { return }
        previewIntentVersion += 1
        let result = applying(preset, mode: mode)
        previewedPresetAdjustments = result.adjustments
        presetPreviewDiagnostics = result.diagnostics
        previewRenderFailureMessage = nil
        // Round 3: nothing to render -- e.g. the only leaf this preset has
        // was skipped for lack of a white-balance baseline, so the result is
        // pixel-for-pixel the committed edit. Submitting a decode here would
        // just be a second attempt at rendering something already on
        // screen (or, against a photo whose decode fails outright, a second
        // doomed attempt that pops another alert every time the pointer
        // crosses this row).
        guard result.adjustments != history.current else { return }
        requestInteractivePreview()
    }

    /// Restores the render to the committed edit. Safe to call even if no
    /// preview is active.
    public func cancelPresetPreview() {
        guard previewedPresetAdjustments != nil else { return }
        previewedPresetAdjustments = nil
        presetPreviewDiagnostics = []
        previewRenderFailureMessage = nil
        previewIntentVersion += 1
        // Round 3: only submit a restoring decode if the preview actually
        // got as far as changing what's on screen. If it never did --
        // still in flight, itself a no-op, or the preview's own decode
        // failed (never applied to `previewImage`, see `handle(_:)`) --
        // `previewImage` already shows the committed render (or the same
        // nothing it always showed), and re-decoding here would risk
        // failing a second time against exactly the photo that made the
        // preview fail in the first place, just shifted from hover-in to
        // hover-out.
        guard previewImageReflectsAPreview else { return }
        previewImageReflectsAPreview = false
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
    public func commitPreset(_ preset: PresetDocument, mode: PresetApplicationMode) {
        guard photo != nil else { return }
        let result = applying(preset, mode: mode)
        previewedPresetAdjustments = nil
        presetPreviewDiagnostics = []
        previewRenderFailureMessage = nil
        previewIntentVersion += 1
        previewImageReflectsAPreview = false
        // `history.record` is a no-op (returns `false`, pushes no Undo entry,
        // leaves `current` untouched) whenever the preset's applicable
        // leaves resolve to exactly what's already committed -- e.g. a
        // preset with only an absolute white-balance leaf, previewed before
        // the first preview frame has reported a baseline, so the leaf is
        // skipped and nothing else in the preset touches anything (round 2,
        // finding #3). That's still something the user needs to know about:
        // the diagnostic must surface either way. Only the dirty/Undo/redraw
        // side effects in `didChangeAdjustments()` are conditional on
        // something having actually changed.
        let recorded = history.record(result.adjustments)
        if let message = Self.userMessage(for: result.diagnostics) {
            alert = EditorAlert(title: L10n.t("This preset was applied with some limitations"), message: message)
        }
        guard recorded else { return }
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
        // Captured synchronously, before the `await` below -- this is
        // exactly what distinguishes "a decode requested while a preset
        // preview is active" from a normal/committed one, regardless of how
        // this call was reached (directly, or via the interactive-preview
        // throttle's delayed `Task`, by which point a hover may have already
        // been cancelled or replaced -- either way, whatever
        // `previewedPresetAdjustments`/`previewIntentVersion` are *right
        // now* is the truth for this submission).
        let isPreviewContext = previewedPresetAdjustments != nil
        let intentVersion = previewIntentVersion
        let request = PreviewRequest(
            subject: PreviewSubject(photo.id.rawValue),
            url: sourceURL,
            adjustments: displayedAdjustments,
            targetPixelDimension: previewPixelDimension,
            quality: quality
        )
        Task {
            let token = await services.previewScheduler.submit(request)
            if isPreviewContext {
                previewRequestGeneration = (schedulerGeneration: token.generation, intentVersion: intentVersion)
            }
        }
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

    /// Whether `token` belongs to the decode most recently submitted while a
    /// preset preview was active, *and* no newer preview intent (another
    /// hover, a no-op hover, or a cancel) has superseded it since -- see the
    /// doc comment on `previewIntentVersion`. `nil` means "not preview
    /// context at all" (a normal/committed request); `false` means "was
    /// preview context, but it's stale now and must be silently ignored".
    private func previewContextRelevance(for generation: UInt64) -> Bool? {
        guard let pending = previewRequestGeneration, pending.schedulerGeneration == generation else {
            return nil
        }
        return pending.intentVersion == previewIntentVersion
    }

    private func handle(_ event: PreviewEvent) {
        switch event {
        case .produced(let result):
            // The scheduler already dropped stale work; this is the second half
            // of the guarantee — the view model refuses anything that isn't the
            // photo currently open (spec §9).
            guard let photo, result.token.subject.rawValue == photo.id.rawValue else { return }
            guard result.token.generation > lastDisplayedGeneration else { return }
            switch previewContextRelevance(for: result.token.generation) {
            case .some(false):
                // A newer preview intent (possibly a no-op with nothing to
                // render) has since superseded this frame -- applying it now
                // would show a stale preset preview instead of whatever the
                // user is actually hovering/focusing right now.
                return
            case .some(true), .none:
                break
            }
            lastDisplayedGeneration = result.token.generation
            previewImage = result.image.cgImage
            decodeFailed = false
            scheduleHistogramComputation(for: result.image.cgImage, generation: result.token.generation)
            previewQuality = result.quality
            if let baseline = result.image.whiteBalanceBaseline {
                whiteBalanceBaseline = baseline
            }
            // An interactive frame means the settled render is still to come.
            isRendering = result.quality == .interactive
            // Recomputed from this specific frame's own origin every time,
            // rather than only ever set `true` -- a *non*-preview frame
            // landing (e.g. `cancelPresetPreview`'s restore, or a real edit)
            // correctly means the screen no longer reflects a preview.
            previewImageReflectsAPreview = previewContextRelevance(for: result.token.generation) == true

        case .failed(let token, let error):
            guard let photo, token.subject.rawValue == photo.id.rawValue else { return }
            isRendering = false
            switch previewContextRelevance(for: token.generation) {
            case .some(true):
                // Round 3: a preset preview that genuinely changes the
                // picture, but the RAW decode it needed failed -- shown
                // non-modally, right next to `presetPreviewMessage`, instead
                // of the modal `alert` that would otherwise cover it and
                // fire again on every hover.
                previewRenderFailureMessage = Self.previewFailureMessage(for: error)
                return
            case .some(false):
                // Stale: a newer preview intent already replaced this one:
                // nothing to show, the newer intent's own outcome (or lack
                // of one yet) is what's relevant now.
                return
            case .none:
                break
            }
            // A failed decode must not leave the previous photo's frame on
            // screen looking like a successful one (Gate E: no fake success).
            // This is the *general* path -- opening a photo, an actual edit,
            // or restoring the committed render after a preview -- so it
            // keeps the modal alert: spec requires a real error stay visible
            // here, not just the preview-only path above.
            previewImage = nil
            decodeFailed = true
            histogramTask?.cancel()
            histogram = nil
            alert = SafeErrorPresentation.alert(title: L10n.t("Couldn't show this photo"), for: error)
        }
    }

    /// Safe, fixed text for a preview-context render failure -- never the
    /// underlying error's own detail (same rule `userMessage(for:)` follows
    /// for preset-application diagnostics).
    private static func previewFailureMessage(for error: Error) -> String {
        L10n.t("This preset's preview couldn't be rendered right now.")
    }

    // MARK: - Histogram

    /// Kicks off the histogram computation for a just-accepted preview frame
    /// off the main actor (`EditorDependencies.computeHistogram`'s own
    /// default already hops off it). Cancelling the previous
    /// `histogramTask` here is best-effort only -- `HistogramComputer`'s
    /// tight per-pixel loop has no cancellation checkpoints of its own, so
    /// the real staleness guard is the `generation` comparison below, the
    /// same pattern `previewContextRelevance` already establishes for
    /// preset previews: an already-in-flight computation for a frame the
    /// user has since moved on from must never overwrite what's actually
    /// displayed now, regardless of which one happens to finish last.
    private func scheduleHistogramComputation(for image: CGImage, generation: UInt64) {
        guard let services else { return }
        histogramTask?.cancel()
        let compute = services.computeHistogram
        histogramTask = Task { [weak self] in
            let computed = await compute(image)
            guard let self, !Task.isCancelled else { return }
            guard generation == self.lastDisplayedGeneration else { return }
            self.histogram = computed
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
    public func save() async {
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
            saveState = .failed(SafeErrorPresentation.message(for: error))
            alert = SafeErrorPresentation.alert(title: L10n.t("Couldn't save your edits"), for: error)
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
    public func flushPendingEdits() async -> Bool {
        // The debounce is about to be redundant either way.
        autosaveTask?.cancel()
        autosaveTask = nil

        guard photo != nil, saveState.isDirty else { return true }

        if isReadOnlyLibrary {
            // Nothing can be written. Saying so here is what stops the caller
            // navigating away and dropping the edit on the floor.
            saveState = .failed(L10n.t("This drive is read-only, so edits can't be saved."))
            alert = EditorAlert(
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
    public func retrySaveAfterReconnect(isReadOnly: Bool) {
        isReadOnlyLibrary = isReadOnly
        guard !isReadOnly, saveState.isDirty else { return }
        Task { await save() }
    }

    private func cancelPendingWork() {
        settleTask?.cancel()
        autosaveTask?.cancel()
        histogramTask?.cancel()
        originalRenderTask?.cancel()
        interactiveThrottleTask?.cancel()
        settleTask = nil
        autosaveTask = nil
        histogramTask = nil
        originalRenderTask = nil
        interactiveThrottleTask = nil
        lastInteractiveSubmit = nil
    }
}
