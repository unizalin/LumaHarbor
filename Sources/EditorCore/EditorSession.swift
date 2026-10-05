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

/// The identity of a selected local editing object.  A UUID alone is not
/// sufficient because legacy local masks and adjustment brushes can legally
/// carry the same UUID while belonging to different collections.
public enum EditorSelectionIdentity: Equatable, Sendable {
    case localAdjustment(UUID)
    case brushMask(UUID)

    /// Compatibility spelling for callers that describe the old collection
    /// as a legacy brush selection.
    public static func legacyLocal(_ id: UUID) -> Self { .localAdjustment(id) }
}

public typealias BrushMaskSelection = EditorSelectionIdentity

/// Settings frozen at brush press time.  Every point in one gesture uses the
/// same settings; changing a control while the pointer is down cannot mutate
/// the pending stroke behind the editor's back.
public struct BrushMaskGestureSettings: Equatable, Sendable {
    public var mode: BrushMaskStrokeMode
    public var size: Double
    public var feather: Double
    public var flow: Double
    public var density: Double
    public var adjustments: BrushMaskPatch
    public var name: String

    public init(
        mode: BrushMaskStrokeMode = .paint,
        size: Double = 0.05,
        feather: Double = 0,
        flow: Double = 1,
        density: Double = 1,
        adjustments: BrushMaskPatch = .neutral,
        name: String = ""
    ) {
        self.mode = mode
        self.size = size
        self.feather = feather
        self.flow = flow
        self.density = density
        self.adjustments = adjustments
        self.name = name
    }

    fileprivate func validated() -> Self? {
        let stroke = BrushMaskStroke(
            mode: mode, size: size, feather: feather, flow: flow, density: density
        )
        guard (try? stroke.validated()) != nil, (try? adjustments.validated()) != nil else {
            return nil
        }
        return self
    }
}

/// Frozen identity for one brush gesture.  The token is intentionally
/// value-typed and must be supplied by UI clients when they keep a gesture
/// alive across callbacks; stale tokens are rejected at release.
public struct BrushMaskGestureContext: Equatable, Sendable {
    public let photoID: PhotoID
    public let revision: UInt64
    public let mapping: BrushCoordinateMapping
    public let settings: BrushMaskGestureSettings
    fileprivate let id: UUID

    fileprivate init(
        photoID: PhotoID,
        revision: UInt64,
        mapping: BrushCoordinateMapping,
        settings: BrushMaskGestureSettings,
        id: UUID = UUID()
    ) {
        self.photoID = photoID
        self.revision = revision
        self.mapping = mapping
        self.settings = settings
        self.id = id
    }
}

public typealias BrushMaskGestureToken = BrushMaskGestureContext

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
    /// Provenance for the frame currently displayed. Cleared on photo changes
    /// and failures so diagnostics cannot leak from a previous RAW.
    @Published public private(set) var latestRawRenderRecipe: ResolvedRawRenderRecipe?
    /// Monotonic editing context used by native input and async frame guards.
    @Published public private(set) var adjustmentRevision: UInt64 = 0
    @Published public private(set) var whiteBalanceCapability: WhiteBalancePresentation.Capability = .unavailable
    @Published public private(set) var whiteBalanceDiagnostic: WhiteBalancePresentation.ResolutionDiagnostic = .none
    @Published public private(set) var eyedropperIssue: WhiteBalanceEyedropper.SampleIssue?

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

    /// Before/after comparison layout (spec §6.1). `.single` is the
    /// pre-existing hold-to-peek/click-to-pin behavior driven by
    /// `isShowingOriginal`; `.sideBySide` and `.verticalWipe` show both
    /// images at once. Purely UI/view state -- like `toolMode`, it never
    /// touches `history`, `saveState` or the sidecar.
    public enum CompareMode: Equatable, Sendable {
        case single
        case sideBySide
        case verticalWipe
    }

    @Published public private(set) var compareMode: CompareMode = .single
    /// Fraction (0...1) of the canvas width where the vertical wipe divider
    /// sits, clamped away from the very edges so dragging it can never fully
    /// collapse the comparison down to showing only one image.
    @Published public private(set) var wipePosition: Double = 0.5
    public static let minimumWipePosition: Double = 0.02
    public static let maximumWipePosition: Double = 0.98

    /// Which on-canvas tool is active right now (design spec §6.5). Reset to
    /// `.adjust` on every `open()`/`close()` so switching photos never
    /// leaves a crop overlay armed against a photo the user didn't ask to
    /// crop.
    @Published public private(set) var toolMode: EditorToolMode = .adjust

    /// Which entry in `adjustments.localAdjustments` the linear gradient
    /// overlay/panel is currently showing full drag handles and mini-
    /// adjustment controls for (Task 4.3). Purely UI state -- like
    /// `toolMode`, it never touches `history`. Reset alongside `toolMode` on
    /// every `open()`/`close()` for the same reason: switching photos must
    /// never leave a selection pointed at an entry that belongs to the
    /// photo just left behind.
    @Published public var selectedLocalAdjustmentID: UUID? {
        didSet {
            guard selectedLocalAdjustmentID != oldValue else { return }
            if let id = selectedLocalAdjustmentID {
                selectedAdjustmentIdentity = .localAdjustment(id)
                selectedBrushMaskID = nil
            } else if case .localAdjustment = selectedAdjustmentIdentity {
                selectedAdjustmentIdentity = nil
            }
        }
    }

    /// Typed selection for the two independent local-edit collections.  The
    /// legacy UUID property above remains source-compatible with existing UI;
    /// new brush-mask clients should use this discriminator.
    @Published public private(set) var selectedAdjustmentIdentity: EditorSelectionIdentity?
    @Published public private(set) var selectedBrushMaskID: UUID? {
        didSet {
            guard selectedBrushMaskID != oldValue else { return }
            if let id = selectedBrushMaskID {
                selectedAdjustmentIdentity = .brushMask(id)
                selectedLocalAdjustmentID = nil
            } else if case .brushMask = selectedAdjustmentIdentity {
                selectedAdjustmentIdentity = nil
            }
        }
    }

    /// Snapshots saved on this photo (spec §6.6).
    @Published public private(set) var snapshots: [EditSnapshot] = []

    /// Professional preview overlays and soft-proofing options (spec §7.4).
    @Published public var previewOptions: ProfessionalPreviewOptions = .standard

    /// Transient snapshot reference used for A/B comparison.
    /// Toggling comparison changes session state only; never mutates adjustments or writes sidecar.
    @Published public private(set) var comparisonSnapshot: EditSnapshot?

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
    /// Monotonic token for in-flight sidecar writes.  Every edit, photo
    /// transition, and save submission advances it so an older completion
    /// cannot claim a newer document is saved.
    private var saveOperationGeneration: UInt64 = 0
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
    @Published public private(set) var whiteBalanceBaseline: RawWhiteBalanceBaseline?
    private var editRevision: UInt64 = 0
    private var eyedropperCandidateRevision: UInt64?
    private var eyedropperCandidatePhotoID: PhotoID?
    private var eyedropperCandidateDiagnostic: WhiteBalancePresentation.ResolutionDiagnostic = .none
    private var committedWhiteBalanceDiagnostic: WhiteBalancePresentation.ResolutionDiagnostic = .none

    public struct EyedropperSamplingContext: Equatable {
        public let photoID: PhotoID
        public let revision: UInt64
        public let generation: UInt64
        fileprivate let id: UUID
    }
    private var activeEyedropperContext: EyedropperSamplingContext?
    private var requiresFreshEyedropperGesture = false
    private struct FrameContext {
        let revision: UInt64
        let intent: UInt64
        let recipe: PhotoAdjustments
        let isPreview: Bool
    }
    private var frameContexts: [UUID: FrameContext] = [:]
    private var displayedFrameContext: FrameContext?

    private struct ActiveBrushMaskGesture {
        let context: BrushMaskGestureContext
        let targetMaskID: UUID?
        var paths: [BrushMaskPath]
        var acceptsNextPoint: Bool
    }
    private var activeBrushMaskGesture: ActiveBrushMaskGesture?

    public var hasEyedropperPreview: Bool { previewedEyedropperAdjustments != nil }

    /// A preset applied via `previewPreset(_:mode:)`, not yet committed.
    /// Transient by construction: nothing here ever reaches `history`,
    /// `saveState` or autosave (spec §5.3/§9.1) -- only what's drawn changes.
    private var previewedPresetAdjustments: PhotoAdjustments?

    /// A white balance eyedropper sample applied via `previewEyedropper
    /// (sample:)`, not yet committed. Same non-committing contract as
    /// `previewedPresetAdjustments` (spec §6.4: "使用者必須能取消滴管，不得在
    /// hover / preview 階段寫入 sidecar"), kept as its own field rather than
    /// reusing the preset one so an eyedropper drag and a preset-browser
    /// hover can never clobber each other's preview state.
    private var previewedEyedropperAdjustments: PhotoAdjustments?

    /// A continuous-drag preview (slider tick, tone-curve control-point
    /// drag/insert/delete, ...) applied via `previewContinuousEdit(_:)`, not
    /// yet committed. Same non-committing contract as
    /// `previewedEyedropperAdjustments` -- a caller invokes this on every
    /// drag tick so the render stays live, but only `commitContinuousEdit()`
    /// pushes an Undo entry, so a whole gesture (however many ticks it
    /// reports) becomes exactly one Undo step (visual polish spec §5.1;
    /// generalized by the 2026-09-14 inspector hierarchy/preview spec §5.6
    /// from what was originally curve-only state under the name
    /// `previewedCurveAdjustments`).
    private var previewedContinuousAdjustments: PhotoAdjustments?

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

    /// What the preview pipeline should actually render: a live eyedropper
    /// preview if one is active, else a live preset preview, else the
    /// committed edit. Both preview kinds are gated on mutually exclusive
    /// `toolMode`s in practice, so precedence between them is not expected
    /// to matter in normal use.
    ///
    /// Independent-review P1 fix: while the crop tool is active, the crop
    /// itself is stripped from what's rendered (though never from what's
    /// committed -- `adjustments.geometry.crop` is untouched). `GeometryRenderer
    /// .apply(_:to:)` applies crop *last*, in the already-rotated/flipped/
    /// straightened frame, which is exactly the frame `CropOverlayView`
    /// draws and drags against -- so the crop tool's own preview must show
    /// that same pre-crop, post-rotate frame, not the already-cropped-and-
    /// filled result a committed crop would otherwise produce. Without
    /// this, re-editing an existing crop had no correct frame to reference
    /// at all.
    public var displayedAdjustments: PhotoAdjustments {
        if let comparisonSnapshot {
            return comparisonSnapshot.adjustments
        }
        var adjustments = previewedEyedropperAdjustments ?? previewedContinuousAdjustments ?? previewedPresetAdjustments ?? history.current
        if toolMode == .crop {
            adjustments.geometry.crop = nil
        }
        return adjustments
    }

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

    #if DEBUG
    /// Test support for editor-only interaction tests that do not run a real
    /// preview renderer. Production paths always obtain this value from the
    /// rendered frame, so a missing baseline remains fail-closed.
    internal func setWhiteBalanceBaselineForTesting(_ baseline: RawWhiteBalanceBaseline) {
        whiteBalanceBaseline = baseline
        whiteBalanceCapability = WhiteBalancePresentation.capability(
            baseline: baseline.temperatureKelvin
        )
    }

    internal func advanceEyedropperGenerationForTesting() {
        lastDisplayedGeneration &+= 1
    }

    internal func enableComparisonForTesting() {
        var pixel: [UInt8] = [0, 0, 0, 255]
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        originalImage = context?.makeImage()
    }

    @discardableResult
    internal func beginEyedropperForTesting() -> EyedropperSamplingContext? {
        guard let photo, whiteBalanceCapability == .valid else { return nil }
        let context = EyedropperSamplingContext(
            photoID: photo.id, revision: editRevision,
            generation: lastDisplayedGeneration, id: UUID()
        )
        activeEyedropperContext = context
        requiresFreshEyedropperGesture = false
        return context
    }
    #endif

    // MARK: - Opening

    public func open(
        photo: PhotoAsset,
        sourceURL: URL,
        adjustments: PhotoAdjustments,
        isReadOnly: Bool,
        snapshots: [EditSnapshot] = []
    ) {
        cancelPendingWork()
        saveOperationGeneration &+= 1

        self.photo = photo
        self.sourceURL = sourceURL
        self.history = EditHistory(initial: adjustments)
        self.lastSavedAdjustments = adjustments
        self.isReadOnlyLibrary = isReadOnly
        self.snapshots = snapshots
        self.previewOptions = .standard
        self.comparisonSnapshot = nil
        self.previewImage = nil
        self.latestRawRenderRecipe = nil
        self.decodeFailed = false
        self.histogram = nil
        self.originalImage = nil
        self.isShowingOriginal = false
        self.compareMode = .single
        self.wipePosition = 0.5
        self.saveState = .unchanged
        self.lastDisplayedGeneration = 0
        self.adjustmentRevision &+= 1
        self.whiteBalanceBaseline = nil
        self.whiteBalanceCapability = .loading
        self.whiteBalanceDiagnostic = .none
        self.eyedropperIssue = nil
        self.editRevision &+= 1
        self.activeEyedropperContext = nil
        self.requiresFreshEyedropperGesture = false
        self.displayedFrameContext = nil
        self.frameContexts.removeAll()
        self.committedWhiteBalanceDiagnostic = .none
        self.eyedropperCandidateRevision = nil
        self.eyedropperCandidatePhotoID = nil
        self.previewedPresetAdjustments = nil
        self.previewedEyedropperAdjustments = nil
        self.previewedContinuousAdjustments = nil
        self.presetPreviewDiagnostics = []
        self.previewRenderFailureMessage = nil
        self.previewIntentVersion += 1
        self.previewRequestGeneration = nil
        self.previewImageReflectsAPreview = false
        self.toolMode = .adjust
        self.selectedLocalAdjustmentID = nil
        self.selectedBrushMaskID = nil
        self.selectedAdjustmentIdentity = nil
        self.activeBrushMaskGesture = nil
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
        saveOperationGeneration &+= 1
        photo = nil
        sourceURL = nil
        previewImage = nil
        latestRawRenderRecipe = nil
        decodeFailed = false
        histogram = nil
        originalImage = nil
        compareMode = .single
        wipePosition = 0.5
        snapshots = []
        previewOptions = .standard
        comparisonSnapshot = nil
        history = EditHistory(initial: .neutral)
        saveState = .unchanged
        adjustmentRevision &+= 1
        whiteBalanceBaseline = nil
        whiteBalanceCapability = .unavailable
        whiteBalanceDiagnostic = .none
        eyedropperIssue = nil
        previewedPresetAdjustments = nil
        previewedEyedropperAdjustments = nil
        previewedContinuousAdjustments = nil
        editRevision &+= 1
        activeEyedropperContext = nil
        requiresFreshEyedropperGesture = true
        displayedFrameContext = nil
        frameContexts.removeAll()
        committedWhiteBalanceDiagnostic = .none
        eyedropperCandidateRevision = nil
        eyedropperCandidatePhotoID = nil
        presetPreviewDiagnostics = []
        previewRenderFailureMessage = nil
        previewIntentVersion += 1
        previewRequestGeneration = nil
        previewImageReflectsAPreview = false
        toolMode = .adjust
        selectedLocalAdjustmentID = nil
        selectedBrushMaskID = nil
        selectedAdjustmentIdentity = nil
        activeBrushMaskGesture = nil
        refreshUndoState()
        if let scheduler = services?.previewScheduler {
            Task { await scheduler.cancelAll() }
        }
    }

    // MARK: - Editing

    public func setAdjustment(_ kind: AdjustmentKind, to value: Double) {
        guard photo != nil, value.isFinite else { return }
        adjustmentRevision &+= 1
        editRevision &+= 1
        activeEyedropperContext = nil
        requiresFreshEyedropperGesture = true
        previewedEyedropperAdjustments = nil
        eyedropperCandidateRevision = nil
        eyedropperCandidatePhotoID = nil
        var requested = value
        var diagnostic: WhiteBalancePresentation.ResolutionDiagnostic?
        if kind == .temperature {
            guard let resolution = resolveNewTemperature(value),
                  let resolved = resolution.effectiveStoredOffset else { return }
            requested = resolved
            diagnostic = resolution.diagnostic
        }
        guard history.setAdjustment(kind, to: requested) else { return }
        didChangeAdjustments()
        if let diagnostic {
            committedWhiteBalanceDiagnostic = diagnostic
            refreshWhiteBalanceDiagnostic()
        }
    }

    /// Independent review of Task 3.3: a batch's other selected photos must
    /// hear about a reset the same way they hear about a drag on that same
    /// field -- otherwise resetting one of the ten basic sliders (via the
    /// context menu, a double-click, or "Reset All") silently leaves the
    /// rest of the batch stuck at whatever value the last real drag synced,
    /// with no way for the user to tell the two have diverged. Brackets its
    /// own change with the same begin/end hooks a drag fires, using the
    /// value from just before the reset as the baseline.
    public func resetAdjustment(_ kind: AdjustmentKind) {
        guard photo != nil else { return }
        adjustmentRevision &+= 1
        editRevision &+= 1
        activeEyedropperContext = nil
        requiresFreshEyedropperGesture = true
        previewedEyedropperAdjustments = nil
        eyedropperCandidateRevision = nil
        eyedropperCandidatePhotoID = nil
        let baseline = history.current
        guard history.resetAdjustment(kind) else { return }
        services?.onBeginAdjustmentGesture?(baseline)
        didChangeAdjustments()
        services?.onEndAdjustmentGesture?(history.current)
    }

    public func resetAll() {
        guard photo != nil else { return }
        adjustmentRevision &+= 1
        editRevision &+= 1
        activeEyedropperContext = nil
        requiresFreshEyedropperGesture = true
        previewedEyedropperAdjustments = nil
        eyedropperCandidateRevision = nil
        eyedropperCandidatePhotoID = nil
        let baseline = history.current
        guard history.resetToNeutral() else { return }
        services?.onBeginAdjustmentGesture?(baseline)
        didChangeAdjustments()
        services?.onEndAdjustmentGesture?(history.current)
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
        adjustmentRevision &+= 1
        editRevision &+= 1
        activeEyedropperContext = nil
        requiresFreshEyedropperGesture = true
        previewedEyedropperAdjustments = nil
        eyedropperCandidateRevision = nil
        eyedropperCandidatePhotoID = nil
        var updated = history.current
        transform(&updated)
        var resolution: WhiteBalancePresentation.Resolution?
        if updated.temperature != history.current.temperature {
            resolution = resolveNewTemperature(updated.temperature)
            updated.temperature = resolution?.effectiveStoredOffset ?? history.current.temperature
        }
        if !updated.tint.isFinite { updated.tint = history.current.tint }
        guard history.record(updated.clamped()) else { return }
        didChangeAdjustments()
        if let resolution {
            committedWhiteBalanceDiagnostic = resolution.diagnostic
            refreshWhiteBalanceDiagnostic()
        }
    }

    public func undo() {
        activeBrushMaskGesture = nil
        adjustmentRevision &+= 1
        editRevision &+= 1
        activeEyedropperContext = nil
        requiresFreshEyedropperGesture = true
        previewedEyedropperAdjustments = nil
        eyedropperCandidateRevision = nil
        eyedropperCandidatePhotoID = nil
        guard history.undo() != nil else { return }
        didChangeAdjustments()
    }

    /// Marks the start of a continuous slider drag (Phase 3 Task 3.3).
    /// SwiftUI reports every tick of a drag as its own value change --
    /// there is no built-in signal distinguishing "the user just started
    /// dragging" from "one more tick of an already-running drag" -- so a
    /// caller (an `AdjustmentSliderRow`'s `Slider(..., onEditingChanged:)`)
    /// calls this exactly once, right before the drag's first change.
    /// Fires `EditorDependencies.onBeginAdjustmentGesture` with the
    /// adjustments as they stood at that instant, so a batch sync service
    /// can snapshot every other selected photo's own target list and
    /// baseline relative to this moment -- never a moment it has to guess
    /// at by watching `history` for changes. A no-op without an open photo
    /// or without a hook attached (every environment that doesn't support
    /// batch sync).
    public func beginAdjustmentGesture() {
        guard photo != nil else { return }
        services?.onBeginAdjustmentGesture?(history.current)
    }

    /// Marks the end of a drag started by `beginAdjustmentGesture()`. Fires
    /// `EditorDependencies.onEndAdjustmentGesture` with the adjustments as
    /// they stand now -- the batch sync service (if any) is responsible for
    /// diffing this against the baseline it was given at
    /// `beginAdjustmentGesture` and syncing only the fields that actually
    /// changed (Task 3.3: "only modified field IDs are synchronized").
    public func endAdjustmentGesture() {
        guard photo != nil else { return }
        services?.onEndAdjustmentGesture?(history.current)
    }

    /// Switches the on-canvas interaction mode. Purely UI state -- it never
    /// touches `history`, `saveState` or the preview, unlike every other
    /// method in this section.
    public func setToolMode(_ mode: EditorToolMode) {
        if mode != .brushMask, activeBrushMaskGesture != nil {
            cancelBrushMaskGesture()
        }
        toolMode = mode
    }

    /// Selects one legacy local adjustment.  The explicit discriminator keeps
    /// a UUID collision from routing an edit to the independent brush array.
    public func selectLocalAdjustment(id: UUID?) {
        selectedLocalAdjustmentID = id
    }

    /// Selects one independent adjustment brush.  Selection alone is UI state
    /// and never creates an undo entry or schedules a save.
    public func selectBrushMask(id: UUID?) {
        guard id == nil || history.current.brushMasks.contains(where: { $0.id == id }) else { return }
        selectedBrushMaskID = id
    }

    /// Compatibility name used by canvas clients.
    public func selectBrushMask(_ id: UUID?) { selectBrushMask(id: id) }

    // MARK: - Adjustment brush gestures

    public var hasActiveBrushMaskGesture: Bool { activeBrushMaskGesture != nil }

    /// Captures the photo, revision, mapper and brush controls at press time.
    /// No model/history mutation occurs until `endBrushMaskGesture` receives a
    /// valid release, so activating the tool or pressing outside the frame is
    /// a true no-op.
    @discardableResult
    public func beginBrushMaskGesture(
        at displayPoint: CGPoint,
        mapping: BrushCoordinateMapping,
        settings: BrushMaskGestureSettings = BrushMaskGestureSettings()
    ) -> BrushMaskGestureContext? {
        guard let photo, let settings = settings.validated(),
              let sourcePoint = try? mapping.displayToSource(displayPoint) else {
            return nil
        }
        let point = BrushMaskPoint(x: sourcePoint.x, y: sourcePoint.y)
        let targetMaskID: UUID?
        if case let .brushMask(id) = selectedAdjustmentIdentity,
           history.current.brushMasks.contains(where: { $0.id == id }) {
            targetMaskID = id
        } else {
            targetMaskID = nil
        }
        let context = BrushMaskGestureContext(
            photoID: photo.id,
            revision: editRevision,
            mapping: mapping,
            settings: settings
        )
        activeBrushMaskGesture = ActiveBrushMaskGesture(
            context: context,
            targetMaskID: targetMaskID,
            paths: [BrushMaskPath(points: [point])],
            acceptsNextPoint: true
        )
        return context
    }

    /// Alias matching the stroke terminology used by some platform overlays.
    @discardableResult
    public func beginBrushMaskStroke(
        at displayPoint: CGPoint,
        mapping: BrushCoordinateMapping,
        settings: BrushMaskGestureSettings = BrushMaskGestureSettings()
    ) -> BrushMaskGestureContext? {
        beginBrushMaskGesture(at: displayPoint, mapping: mapping, settings: settings)
    }

    /// Adds a transient point.  A point after an out-of-frame gap starts a
    /// fresh path, ensuring the renderer never bridges across the gap.
    @discardableResult
    public func updateBrushMaskGesture(
        at displayPoint: CGPoint,
        context: BrushMaskGestureContext? = nil
    ) -> Bool {
        guard var active = activeBrushMaskGesture,
              isCurrentBrushMaskGesture(active, context: context) else {
            return false
        }
        guard let sourcePoint = try? active.context.mapping.displayToSource(displayPoint) else {
            active.acceptsNextPoint = false
            activeBrushMaskGesture = active
            return false
        }
        let point = BrushMaskPoint(x: sourcePoint.x, y: sourcePoint.y)
        if !active.acceptsNextPoint || active.paths.isEmpty {
            active.paths.append(BrushMaskPath(points: [point]))
        } else {
            guard var path = active.paths.popLast() else { return false }
            if let last = path.points.last,
               abs(last.x - point.x) + abs(last.y - point.y) < 0.000_001 {
                active.paths.append(path)
                activeBrushMaskGesture = active
                return true
            }
            path.points.append(point)
            active.paths.append(path)
        }
        active.acceptsNextPoint = true
        activeBrushMaskGesture = active
        return true
    }

    @discardableResult
    public func appendBrushMaskPoint(
        at displayPoint: CGPoint,
        context: BrushMaskGestureContext? = nil
    ) -> Bool {
        updateBrushMaskGesture(at: displayPoint, context: context)
    }

    /// Commits one valid gesture as one history entry and one autosave intent.
    /// A stale token, invalid release, empty path, or cancelled gesture is a
    /// strict no-op.
    @discardableResult
    public func endBrushMaskGesture(context: BrushMaskGestureContext? = nil) -> Bool {
        guard let active = activeBrushMaskGesture,
              isCurrentBrushMaskGesture(active, context: context) else {
            return false
        }
        activeBrushMaskGesture = nil
        let strokes = active.paths.compactMap { path -> BrushMaskStroke? in
            guard !path.points.isEmpty else { return nil }
            return BrushMaskStroke(
                path: path,
                mode: active.context.settings.mode,
                size: active.context.settings.size,
                feather: active.context.settings.feather,
                flow: active.context.settings.flow,
                density: active.context.settings.density
            )
        }
        guard !strokes.isEmpty else { return false }

        var updated = history.current
        let maskID: UUID
        if let targetID = active.targetMaskID,
           let index = updated.brushMasks.firstIndex(where: { $0.id == targetID }) {
            maskID = targetID
            updated.brushMasks[index].strokes.append(contentsOf: strokes)
        } else {
            let mask = BrushMask(
                name: active.context.settings.name,
                strokes: strokes,
                adjustments: active.context.settings.adjustments
            )
            maskID = mask.id
            updated.brushMasks.append(mask)
        }
        guard history.record(updated) else { return false }
        selectedBrushMaskID = maskID
        didChangeAdjustments()
        return true
    }

    /// Release variant used by pointer/touch clients that report the final
    /// location.  Releasing outside the visible frame is invalid and drops
    /// the transient gesture rather than committing a partial stroke.
    @discardableResult
    public func endBrushMaskGesture(
        at displayPoint: CGPoint,
        context: BrushMaskGestureContext? = nil
    ) -> Bool {
        guard let active = activeBrushMaskGesture,
              isCurrentBrushMaskGesture(active, context: context),
              (try? active.context.mapping.displayToSource(displayPoint)) != nil else {
            activeBrushMaskGesture = nil
            return false
        }
        return endBrushMaskGesture(context: context)
    }

    @discardableResult
    public func commitBrushMaskGesture(context: BrushMaskGestureContext? = nil) -> Bool {
        endBrushMaskGesture(context: context)
    }

    @discardableResult
    public func endBrushMaskStroke(context: BrushMaskGestureContext? = nil) -> Bool {
        endBrushMaskGesture(context: context)
    }

    @discardableResult
    public func endBrushMaskStroke(
        at displayPoint: CGPoint,
        context: BrushMaskGestureContext? = nil
    ) -> Bool {
        endBrushMaskGesture(at: displayPoint, context: context)
    }

    /// Cancelling discards all transient paths and never touches history or
    /// save state.  It also invalidates any token retained by a late release.
    public func cancelBrushMaskGesture() {
        activeBrushMaskGesture = nil
    }

    public func cancelBrushMaskStroke() { cancelBrushMaskGesture() }

    /// Adds an empty adjustment brush explicitly from a panel.  This is an
    /// intentional edit (unlike tool activation) and therefore is undoable.
    @discardableResult
    public func addBrushMask(
        name: String = "",
        adjustments: BrushMaskPatch = .neutral
    ) -> UUID? {
        guard photo != nil, (try? adjustments.validated()) != nil else { return nil }
        var updated = history.current
        let mask = BrushMask(name: name, adjustments: adjustments)
        updated.brushMasks.append(mask)
        guard history.record(updated) else { return nil }
        selectedBrushMaskID = mask.id
        didChangeAdjustments()
        return mask.id
    }

    @discardableResult
    public func deleteBrushMask(id: UUID) -> Bool {
        guard photo != nil, history.current.brushMasks.contains(where: { $0.id == id }) else { return false }
        var updated = history.current
        updated.brushMasks.removeAll { $0.id == id }
        guard history.record(updated) else { return false }
        if selectedBrushMaskID == id { selectedBrushMaskID = nil }
        didChangeAdjustments()
        return true
    }

    @discardableResult
    public func deleteSelectedBrushMask() -> Bool {
        guard let id = selectedBrushMaskID else { return false }
        return deleteBrushMask(id: id)
    }

    private func isCurrentBrushMaskGesture(
        _ active: ActiveBrushMaskGesture,
        context: BrushMaskGestureContext?
    ) -> Bool {
        guard context.map({ $0.id == active.context.id }) ?? true,
              let photo, photo.id == active.context.photoID,
              active.context.revision == editRevision else {
            activeBrushMaskGesture = nil
            return false
        }
        return true
    }

    /// Switches the before/after comparison layout (spec §6.1). Entering
    /// `.sideBySide`/`.verticalWipe` requires both an original to compare
    /// against and an actual edit to show -- the same gate the pre-existing
    /// hold/pin compare control already uses (`canCompareWithOriginal`) --
    /// so a stale menu selection can never leave the canvas trying to show a
    /// comparison with nothing real to compare. `.single` is always allowed,
    /// so leaving a comparison layout never gets stuck.
    public func setCompareMode(_ mode: CompareMode) {
        guard mode == .single || canCompareWithOriginal else { return }
        guard mode != compareMode else { return }
        activeBrushMaskGesture = nil
        compareMode = mode
        invalidateEyedropperInteraction()
        requestInteractivePreview()
    }

    private func invalidateEyedropperInteraction() {
        activeEyedropperContext = nil
        requiresFreshEyedropperGesture = true
        previewedEyedropperAdjustments = nil
        eyedropperCandidateRevision = nil
        eyedropperCandidatePhotoID = nil
        eyedropperIssue = nil
        previewIntentVersion &+= 1
        previewImageReflectsAPreview = false
        refreshWhiteBalanceDiagnostic()
    }

    /// Moves the vertical wipe divider (spec §6.1: "wipe 分隔位置要可由拖曳調整並
    /// clamp 在合理範圍"). Purely UI state, like `compareMode` itself.
    public func setWipePosition(_ position: Double) {
        wipePosition = min(max(position, Self.minimumWipePosition), Self.maximumWipePosition)
    }

    public func redo() {
        activeBrushMaskGesture = nil
        adjustmentRevision &+= 1
        editRevision &+= 1
        activeEyedropperContext = nil
        requiresFreshEyedropperGesture = true
        previewedEyedropperAdjustments = nil
        eyedropperCandidateRevision = nil
        eyedropperCandidatePhotoID = nil
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
        invalidateEyedropperInteraction()
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

    /// Phase 2.2 "Paste Adjustments" (spec §6.2): applies a copied
    /// `AdjustmentPatch` as one undoable step, the same "one action, one
    /// Undo entry" contract `commitPreset` already gives preset application.
    /// `patch` goes through the same `.merge`-mode `PresetApplicator` path a
    /// preset does, so any field the patch doesn't include is left exactly
    /// as this photo's own edits left it -- never a blind overwrite.
    /// `geometry`/`localAdjustments` are copied verbatim only when the
    /// caller passes them (the clipboard's own opt-in checkboxes), never
    /// partially or inferred; passing `nil` for either leaves this photo's
    /// own current value untouched.
    public func pasteAdjustments(
        patch: AdjustmentPatch,
        geometry: GeometryAdjustments?,
        localAdjustments: [LocalAdjustment]?,
        brushMasks: [BrushMask]? = nil
    ) {
        guard photo != nil else { return }
        let context = PresetApplicationContext(
            baselineTemperatureKelvin: whiteBalanceBaseline?.temperatureKelvin,
            baselineTint: whiteBalanceBaseline?.tint
        )
        var result = PresetApplicator().apply(patch, to: history.current, mode: .merge, context: context).adjustments
        if let geometry {
            result.geometry = geometry
        }
        if let localAdjustments {
            result.localAdjustments = localAdjustments
        }
        if let brushMasks {
            result.brushMasks = brushMasks
        }
        guard history.record(result) else { return }
        didChangeAdjustments()
    }

    // MARK: - Snapshots & Professional Preview

    /// Captures the current adjustments as a new snapshot (spec §6.6).
    public func createSnapshot(name: String) {
        guard let photo else { return }
        activeBrushMaskGesture = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshotName = trimmed.isEmpty ? "\(L10n.t("Snapshot")) \(snapshots.count + 1)" : trimmed
        let snapshot = EditSnapshot(name: snapshotName, adjustments: history.current)
        snapshots.append(snapshot)
        invalidateEyedropperInteraction()
        persistSnapshots(for: photo)
    }

    /// Renames an existing snapshot by ID.
    public func renameSnapshot(id: UUID, newName: String) {
        guard let photo, let index = snapshots.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activeBrushMaskGesture = nil
        snapshots[index].name = trimmed
        persistSnapshots(for: photo)
    }

    /// Duplicates an existing snapshot.
    public func duplicateSnapshot(id: UUID) {
        guard let photo, let snapshot = snapshots.first(where: { $0.id == id }) else { return }
        activeBrushMaskGesture = nil
        let copy = EditSnapshot(
            name: "\(snapshot.name) \(L10n.t("Copy"))",
            adjustments: snapshot.adjustments
        )
        snapshots.append(copy)
        persistSnapshots(for: photo)
    }

    /// Deletes a snapshot by ID.
    public func deleteSnapshot(id: UUID) {
        guard let photo, let index = snapshots.firstIndex(where: { $0.id == id }) else { return }
        activeBrushMaskGesture = nil
        snapshots.remove(at: index)
        if comparisonSnapshot?.id == id {
            comparisonSnapshot = nil
            requestInteractivePreview()
        }
        persistSnapshots(for: photo)
    }

    /// Restores adjustments from a snapshot in a single compound undo transaction (spec §6.6).
    public func restoreSnapshot(id: UUID) {
        guard let snapshot = snapshots.first(where: { $0.id == id }) else { return }
        updateAdjustments { adjustments in
            adjustments = snapshot.adjustments
        }
    }

    /// Updates preview options (highlight/shadow clipping, gamut warning, soft proof).
    /// Purely preview state; never saved to sidecar or export.
    public func setPreviewOptions(_ options: ProfessionalPreviewOptions) {
        previewOptions = options
        invalidateEyedropperInteraction()
        requestInteractivePreview()
        scheduleSettledPreview()
    }

    /// Sets or clears the comparison snapshot for A/B preview.
    /// Purely session state; never mutates adjustments or saves to sidecar.
    public func setComparisonSnapshot(_ snapshot: EditSnapshot?) {
        activeBrushMaskGesture = nil
        comparisonSnapshot = snapshot
        invalidateEyedropperInteraction()
        requestInteractivePreview()
        scheduleSettledPreview()
    }

    /// Toggles A/B compare against the first snapshot or clears comparison.
    public func toggleABCompare() {
        activeBrushMaskGesture = nil
        if comparisonSnapshot != nil {
            comparisonSnapshot = nil
        } else if let first = snapshots.first {
            comparisonSnapshot = first
        }
        requestInteractivePreview()
        scheduleSettledPreview()
    }

    private func persistSnapshots(for photo: PhotoAsset) {
        guard let save = services?.saveSnapshots else { return }
        let currentSnapshots = self.snapshots
        Task {
            try? await save(currentSnapshots, photo)
        }
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

    // MARK: - White balance eyedropper

    /// Shows what sampling `sample` would do to temperature/tint, without
    /// touching `history`, `saveState` or autosave (spec §6.4: "使用者必須能
    /// 取消滴管，不得在 hover / preview 階段寫入 sidecar") -- the same
    /// non-committing contract `previewPreset(_:mode:)` already guarantees
    /// for presets. `WhiteBalanceEyedropper.delta(neutralizing:)` returns an
    /// *additive* delta, so repeated sampling (e.g. dragging across the
    /// photo before releasing) refines the previous preview rather than
    /// compounding onto it -- each call replaces `previewedEyedropperAdjustments`
    /// from `history.current`, never from the previous preview.
    public func beginEyedropperSampling(sourceImage: CGImage) -> EyedropperSamplingContext? {
        guard let photo, whiteBalanceCapability == .valid,
              sourceImage === previewImage, let frame = displayedFrameContext,
              frame.recipe == history.current, frame.revision == editRevision else { return nil }
        let context = EyedropperSamplingContext(photoID: photo.id, revision: editRevision,
            generation: lastDisplayedGeneration, id: UUID())
        activeEyedropperContext = context
        requiresFreshEyedropperGesture = false
        return context
    }

    private func isCurrent(_ context: EyedropperSamplingContext) -> Bool {
        context == activeEyedropperContext && context.photoID == photo?.id
            && context.revision == editRevision
            && context.generation == lastDisplayedGeneration
    }

    public func previewEyedropper(sample: WhiteBalanceEyedropper.Sample,
                                  context: EyedropperSamplingContext? = nil) {
        guard photo != nil else { return }
        if let context {
            guard isCurrent(context) else { return }
        } else {
            guard !requiresFreshEyedropperGesture else { return }
            if activeEyedropperContext == nil {
                if let image = previewImage {
                    guard beginEyedropperSampling(sourceImage: image) != nil else {
                        rejectEyedropperSample(whiteBalanceCapability == .valid ? .staleFrame : .unavailableBaseline)
                        return
                    }
                } else if whiteBalanceCapability == .valid, let photo {
                    activeEyedropperContext = EyedropperSamplingContext(
                        photoID: photo.id, revision: editRevision,
                        generation: lastDisplayedGeneration, id: UUID()
                    )
                    requiresFreshEyedropperGesture = false
                } else {
                    rejectEyedropperSample(whiteBalanceCapability == .valid ? .staleFrame : .unavailableBaseline)
                    return
                }
            }
        }
        if let issue = WhiteBalanceEyedropper.issue(for: sample) {
            rejectEyedropperSample(issue)
            return
        }
        previewIntentVersion += 1
        eyedropperIssue = nil
        let delta = WhiteBalanceEyedropper.delta(neutralizing: sample)
        guard let result = WhiteBalanceEyedropper.applyingResolved(
            delta: delta, to: history.current,
            baselineKelvin: whiteBalanceBaseline?.temperatureKelvin
        ) else {
            rejectEyedropperSample(.unavailableBaseline)
            return
        }
        previewedEyedropperAdjustments = result.adjustments
        eyedropperCandidateRevision = editRevision
        eyedropperCandidatePhotoID = photo?.id
        eyedropperCandidateDiagnostic = result.diagnostic
        whiteBalanceDiagnostic = result.diagnostic
        guard result.adjustments != history.current else {
            restoreAuthoritativePreview()
            return
        }
        requestInteractivePreview()
    }

    /// Restores the render to the committed edit. Safe to call even if no
    /// eyedropper preview is active.
    public func rejectEyedropperSample(_ issue: WhiteBalanceEyedropper.SampleIssue,
                                       context: EyedropperSamplingContext? = nil) {
        guard photo != nil else { return }
        if let context, !isCurrent(context) { return }
        previewIntentVersion += 1
        eyedropperIssue = issue
        previewedEyedropperAdjustments = nil
        eyedropperCandidateRevision = nil
        eyedropperCandidatePhotoID = nil
        refreshWhiteBalanceDiagnostic()
        restoreAuthoritativePreview()
    }

    public func cancelEyedropperPreview() {
        activeEyedropperContext = nil
        requiresFreshEyedropperGesture = true
        guard previewedEyedropperAdjustments != nil || eyedropperIssue != nil else { return }
        previewedEyedropperAdjustments = nil
        eyedropperIssue = nil
        eyedropperCandidateRevision = nil
        eyedropperCandidatePhotoID = nil
        refreshWhiteBalanceDiagnostic()
        previewIntentVersion += 1
        // Same reasoning as `cancelPresetPreview()`: only submit a
        // restoring decode if the preview actually changed what's on
        // screen.
        guard previewImageReflectsAPreview else { return }
        previewImageReflectsAPreview = false
        requestInteractivePreview()
        scheduleSettledPreview()
    }

    /// Commits the current eyedropper preview as one undoable step. A no-op
    /// if nothing is being previewed, or if the sample happened to resolve
    /// to exactly the current temperature/tint (`history.record` itself is
    /// the no-op guard, same as every other edit path in this class).
    @discardableResult
    public func commitEyedropper(context: EyedropperSamplingContext? = nil) -> Bool {
        if let context {
            guard isCurrent(context) else { return false }
        } else if let activeEyedropperContext {
            guard isCurrent(activeEyedropperContext) else { return false }
        }
        guard let baselineKelvin = whiteBalanceBaseline?.temperatureKelvin,
              WhiteBalancePresentation.isValidBaseline(baselineKelvin) else {
            return false
        }
        guard let previewed = previewedEyedropperAdjustments,
              eyedropperCandidateRevision == editRevision,
              eyedropperCandidatePhotoID == photo?.id else { return false }
        previewedEyedropperAdjustments = nil
        eyedropperIssue = nil
        eyedropperCandidateRevision = nil
        eyedropperCandidatePhotoID = nil
        previewIntentVersion += 1
        previewImageReflectsAPreview = false
        let diagnostic = eyedropperCandidateDiagnostic
        if history.record(previewed.clamped()) {
            didChangeAdjustments()
        } else {
            restoreAuthoritativePreview()
        }
        committedWhiteBalanceDiagnostic = diagnostic
        whiteBalanceDiagnostic = diagnostic
        activeEyedropperContext = nil
        requiresFreshEyedropperGesture = false
        return true
    }

    private func refreshWhiteBalanceDiagnostic() {
        if previewedEyedropperAdjustments != nil {
            whiteBalanceDiagnostic = eyedropperCandidateDiagnostic
            return
        }
        if committedWhiteBalanceDiagnostic == .clamped {
            whiteBalanceDiagnostic = .clamped
            return
        }
        guard let baseline = whiteBalanceBaseline?.temperatureKelvin else {
            whiteBalanceDiagnostic = .none
            return
        }
        whiteBalanceDiagnostic = WhiteBalancePresentation.resolve(
            storedOffset: history.current.temperature, baselineKelvin: baseline
        ).diagnostic
    }

    private func resolveNewTemperature(_ value: Double) -> WhiteBalancePresentation.Resolution? {
        guard value.isFinite, let baseline = whiteBalanceBaseline?.temperatureKelvin,
              WhiteBalancePresentation.isValidBaseline(baseline) else { return nil }
        return WhiteBalancePresentation.resolve(storedOffset: value, baselineKelvin: baseline)
    }

    private func restoreAuthoritativePreview() {
        guard let frame = displayedFrameContext, frame.recipe == history.current,
              let image = previewImage else {
            requestInteractivePreview()
            scheduleSettledPreview()
            return
        }
        displayedFrameContext = FrameContext(revision: editRevision,
            intent: previewIntentVersion, recipe: history.current, isPreview: false)
        previewImageReflectsAPreview = false
        scheduleHistogramComputation(for: image, generation: lastDisplayedGeneration)
    }

    /// Live preview for one continuous-adjustment gesture (slider drag,
    /// pointer drag, keyboard continuous adjustment, accessibility
    /// adjustable action, or a tone-curve control-point drag/insert/delete).
    /// Mirrors `previewEyedropper(sample:)`: never touches `history` by
    /// itself, so a caller can invoke this on every drag tick for a live
    /// render without filling the Undo stack -- only
    /// `commitContinuousEdit()` does that, once, at the end of the gesture
    /// (inspector hierarchy/preview spec §5.6: "one gesture, one edit").
    public func previewContinuousEdit(_ transform: (inout PhotoAdjustments) -> Void) {
        guard photo != nil else { return }
        previewIntentVersion += 1
        var updated = history.current
        transform(&updated)
        previewedContinuousAdjustments = updated
        guard updated != history.current else { return }
        requestInteractivePreview()
    }

    /// Commits the current continuous-adjustment preview as one undoable
    /// step. A no-op if nothing is being previewed, or if the gesture
    /// resolved to exactly the current value (`history.record` itself is
    /// the no-op guard, same as every other edit path in this class).
    public func commitContinuousEdit() {
        guard let previewed = previewedContinuousAdjustments else { return }
        previewedContinuousAdjustments = nil
        previewIntentVersion += 1
        previewImageReflectsAPreview = false
        guard history.record(previewed.clamped()) else { return }
        didChangeAdjustments()
    }

    /// Cancels the current continuous-adjustment preview, restoring the
    /// display to the committed baseline without adding a history entry
    /// (spec §5.6 "cancel"). Safe to call even if no preview is active.
    public func cancelContinuousEdit() {
        guard previewedContinuousAdjustments != nil else { return }
        previewedContinuousAdjustments = nil
        previewIntentVersion += 1
        guard previewImageReflectsAPreview else { return }
        previewImageReflectsAPreview = false
        requestInteractivePreview()
        scheduleSettledPreview()
    }

    /// `CurveAdjustmentPanel`'s original entry points, kept as aliases over
    /// the generalized lifecycle above (2026-09-14 inspector hierarchy/
    /// preview spec §5.6) so existing call sites and tests keep compiling
    /// and behaving identically -- both names share the same underlying
    /// `previewedContinuousAdjustments` slot.
    public func previewCurveEdit(_ transform: (inout PhotoAdjustments) -> Void) {
        previewContinuousEdit(transform)
    }

    public func commitCurveEdit() {
        commitContinuousEdit()
    }

    private func didChangeAdjustments() {
        activeBrushMaskGesture = nil
        saveOperationGeneration &+= 1
        editRevision &+= 1
        adjustmentRevision &+= 1
        previewIntentVersion &+= 1
        activeEyedropperContext = nil
        requiresFreshEyedropperGesture = true
        previewedEyedropperAdjustments = nil
        eyedropperCandidateRevision = nil
        eyedropperCandidatePhotoID = nil
        eyedropperIssue = nil
        committedWhiteBalanceDiagnostic = .none
        refreshWhiteBalanceDiagnostic()
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

    #if DEBUG
    /// Exact history depths used by editor-core regression tests.  The
    /// production surface continues to expose only the boolean affordances.
    internal var undoCountForTesting: Int { history.undoCount }
    internal var redoCountForTesting: Int { history.redoCount }
    #endif

    // MARK: - Preview

    private func requestPreview(quality: PreviewQuality) {
        guard let photo, let sourceURL, let services else { return }
        isRendering = true
        // Captured synchronously, before the `await` below -- this is
        // exactly what distinguishes "a decode requested while a preset or
        // eyedropper preview is active" from a normal/committed one,
        // regardless of how this call was reached (directly, or via the
        // interactive-preview throttle's delayed `Task`, by which point a
        // hover may have already been cancelled or replaced -- either way,
        // whatever `previewedPresetAdjustments`/`previewedEyedropperAdjustments`/
        // `previewIntentVersion` are *right now* is the truth for this
        // submission).
        let isPreviewContext = previewedPresetAdjustments != nil || previewedEyedropperAdjustments != nil || previewedContinuousAdjustments != nil
        let intentVersion = previewIntentVersion
        let contextID = UUID()
        let frame = FrameContext(revision: editRevision, intent: intentVersion,
            recipe: displayedAdjustments, isPreview: isPreviewContext)
        frameContexts = frameContexts.filter { $0.value.revision == editRevision && $0.value.intent == intentVersion }
        frameContexts[contextID] = frame
        let request = PreviewRequest(
            subject: PreviewSubject(photo.id.rawValue),
            url: sourceURL,
            adjustments: displayedAdjustments,
            targetPixelDimension: previewPixelDimension,
            quality: quality,
            previewOptions: previewOptions,
            cameraProfileRequest: displayedAdjustments.rawCameraProfile.requestedName.map {
                RawCameraProfileRequest(sourceName: $0)
            },
            contextID: contextID
        )
        Task {
            guard frame.revision == editRevision, frame.intent == previewIntentVersion else { return }
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
    private func previewContextRelevance(for token: PreviewToken) -> Bool? {
        guard let id = token.contextID else { return nil }
        guard let frame = frameContexts[id],
              frame.revision == editRevision, frame.intent == previewIntentVersion else {
            return false
        }
        return frame.isPreview ? true : nil
    }

    private func handle(_ event: PreviewEvent) {
        switch event {
        case .produced(let result):
            // The scheduler already dropped stale work; this is the second half
            // of the guarantee — the view model refuses anything that isn't the
            // photo currently open (spec §9).
            guard let photo, result.token.subject.rawValue == photo.id.rawValue else { return }
            guard result.token.generation > lastDisplayedGeneration else { return }
            switch previewContextRelevance(for: result.token) {
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
            displayedFrameContext = result.token.contextID.flatMap { frameContexts[$0] }
            previewImage = result.image.cgImage
            latestRawRenderRecipe = result.image.rawRenderRecipe
            decodeFailed = false
            scheduleHistogramComputation(for: result.image.cgImage, generation: result.token.generation)
            previewQuality = result.quality
            let baseline = result.image.whiteBalanceBaseline
            if whiteBalanceBaseline?.temperatureKelvin.bitPattern != baseline?.temperatureKelvin.bitPattern
                || whiteBalanceBaseline?.tint.bitPattern != baseline?.tint.bitPattern {
                adjustmentRevision &+= 1
                activeEyedropperContext = nil
                requiresFreshEyedropperGesture = true
                previewedEyedropperAdjustments = nil
            }
            whiteBalanceBaseline = baseline
            whiteBalanceCapability = WhiteBalancePresentation.capability(
                baseline: baseline?.temperatureKelvin
            )
            refreshWhiteBalanceDiagnostic()
            // An interactive frame means the settled render is still to come.
            isRendering = result.quality == .interactive
            // Recomputed from this specific frame's own origin every time,
            // rather than only ever set `true` -- a *non*-preview frame
            // landing (e.g. `cancelPresetPreview`'s restore, or a real edit)
            // correctly means the screen no longer reflects a preview.
            previewImageReflectsAPreview = previewContextRelevance(for: result.token) == true

        case .failed(let token, let error):
            guard let photo, token.subject.rawValue == photo.id.rawValue else { return }
            guard token.generation > lastDisplayedGeneration else { return }
            isRendering = false
            latestRawRenderRecipe = nil
            switch previewContextRelevance(for: token) {
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
            displayedFrameContext = nil
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
        let revision = editRevision
        let intent = previewIntentVersion
        histogramTask = Task { [weak self] in
            let computed = await compute(image)
            guard let self, !Task.isCancelled else { return }
            guard generation == self.lastDisplayedGeneration else { return }
            guard revision == self.editRevision, intent == self.previewIntentVersion else { return }
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
        guard !isReadOnlyLibrary else {
            saveState = .failed(L10n.t("This drive is read-only, so edits can't be saved."))
            return
        }
        let adjustments = history.current
        saveOperationGeneration &+= 1
        let operationGeneration = saveOperationGeneration
        let photoID = photo.id
        saveState = .saving
        do {
            try await services.saveAdjustments(adjustments, photo)
            guard operationGeneration == saveOperationGeneration,
                  self.photo?.id == photoID,
                  history.current == adjustments else { return }
            lastSavedAdjustments = adjustments
            // Only report success once the atomic write actually returned.
            if history.current == adjustments {
                saveState = .saved(Date())
            }
            onSaved?(photo.id, !adjustments.isNeutral)
        } catch {
            guard operationGeneration == saveOperationGeneration,
                  self.photo?.id == photoID,
                  history.current == adjustments else { return }
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
