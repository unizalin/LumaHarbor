import EditorCore
import PhotoLibraryCore
import Localization
import SwiftUI

/// Centre pane: the large preview plus the filmstrip (spec §6.2).
struct EditorView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.displayScale) private var displayScale

    @State private var viewport = CanvasViewportState(scale: 1, offset: .zero, mode: .fit)
    @State private var viewportPhotoID: PhotoID?
    @State private var viewportImageSize: CGSize = .zero
    @State private var viewportSize: CGSize = .zero
    @State private var magnificationBaseline: CanvasViewportState?
    @State private var panBaseline: CanvasViewportState?
    /// Tracks whether the Space key is currently held, so `viewportPan` can
    /// require it (spec §5.2.2: "按住 Space 拖曳"). A *local* event monitor
    /// only observes events already dispatched to this app -- unlike a
    /// global event tap, it needs no Accessibility permission -- and it
    /// never consumes the event, so Space still types normally in any text
    /// field (the search bar included).
    @State private var isSpaceKeyDown = false
    @State private var spaceKeyMonitor: Any?
    /// The wipe divider's position at the start of the current drag, so each
    /// `DragGesture` update can be applied as `baseline + translation` in the
    /// canvas's own coordinate space, rather than the handle's local one
    /// (see `wipeDragPosition(baseline:translation:width:)`).
    @State private var wipeDragBaseline: Double?

    /// Phase 2.3 (spec §6.3): the filmstrip is one of the three optional
    /// workspace chrome panes -- shown only when its own preference is on
    /// *and* focus mode isn't hiding it, exactly like the sidebar and
    /// inspector `RootView` gates. This never affects the toolbar below
    /// (Back to Library, Undo, Redo, Compare stay reachable regardless).
    @AppStorage(WorkspaceLayoutState.StorageKey.showFilmstrip) private var showFilmstrip = true
    @AppStorage(WorkspaceLayoutState.StorageKey.focusMode) private var focusMode = false

    private var effectiveShowFilmstrip: Bool {
        WorkspaceLayoutState(showFilmstrip: showFilmstrip, focusMode: focusMode).effectiveShowFilmstrip
    }

    var body: some View {
        VStack(spacing: 0) {
            previewArea
            if effectiveShowFilmstrip {
                Divider()
                FilmstripView()
                    .frame(height: 108)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .navigationTitle(model.selectedPhoto?.filename ?? "LumaHarbor")
        .toolbar { toolbarContent }
        .alert(item: Binding(
            get: { model.editor.alert },
            set: { model.editor.alert = $0 }
        )) { alert in
            Alert(
                title: Text(alert.title),
                message: Text([alert.message, alert.nextStep]
                    .compactMap { $0 }
                    .joined(separator: "\n\n")),
                dismissButton: .default(Text(L10n.t("OK")))
            )
        }
        .onChange(of: model.selectedPhotoID) { _, _ in
            viewportPhotoID = nil
            viewportImageSize = .zero
            viewport = CanvasViewportState(scale: 1, offset: .zero, mode: .fit)
        }
        .onAppear { installSpaceKeyMonitor() }
        .onDisappear { removeSpaceKeyMonitor() }
    }

    private func installSpaceKeyMonitor() {
        guard spaceKeyMonitor == nil else { return }
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            if event.keyCode == 49 { // kVK_Space
                isSpaceKeyDown = event.type == .keyDown
            }
            // Never consumed: Space must keep working normally everywhere
            // else (typing a space in the search field, for instance).
            return event
        }
    }

    private func removeSpaceKeyMonitor() {
        if let spaceKeyMonitor {
            NSEvent.removeMonitor(spaceKeyMonitor)
        }
        spaceKeyMonitor = nil
    }

    private var previewArea: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .underPageBackgroundColor)

                if let image = model.editor.displayedImage {
                    let imageFrame = AspectFitRect.fitting(
                        imageSize: CGSize(width: image.width, height: image.height),
                        in: geometry.size,
                        padding: 16
                    )
                    let cropImageFrame = AspectFitRect.fitting(
                        imageSize: CGSize(width: image.width, height: image.height),
                        in: geometry.size,
                        padding: 16
                    )
                    let eyedropperImageFrame = AspectFitRect.fitting(
                        imageSize: CGSize(width: image.width, height: image.height),
                        in: geometry.size,
                        padding: 16
                    )
                    let linearGradientImageFrame = AspectFitRect.fitting(
                        imageSize: CGSize(width: image.width, height: image.height),
                        in: geometry.size,
                        padding: 16
                    )
                    let spotHealImageFrame = AspectFitRect.fitting(
                        imageSize: CGSize(width: image.width, height: image.height),
                        in: geometry.size,
                        padding: 16
                    )
                    // Phase 2.1 (spec §6.1): side-by-side/wipe only apply in
                    // the plain adjust tool -- crop/eyedropper/gradient/spot
                    // heal keep using the single-image path above them so
                    // their own overlays never have to reason about a second
                    // image on screen.
                    let isComparingLayout = model.editor.toolMode == .adjust
                        && model.editor.compareMode != .single
                        && model.editor.canCompareWithOriginal

                    Group {
                        if isComparingLayout, let original = model.editor.originalImage {
                            if model.editor.compareMode == .sideBySide {
                                sideBySideCompareView(original: original, edited: image, size: geometry.size)
                            } else {
                                wipeCompareView(original: original, edited: image, size: geometry.size)
                            }
                        } else {
                            ZStack {
                                Image(decorative: image, scale: 1, orientation: .up)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .padding(16)

                                if model.editor.toolMode == .crop {
                                    CropOverlayView(editor: model.editor, imageFrame: cropImageFrame)
                                }

                                if model.editor.toolMode == .whiteBalance {
                                    EyedropperOverlayView(
                                        editor: model.editor,
                                        imageFrame: eyedropperImageFrame,
                                        image: image
                                    )
                                }

                                if model.editor.toolMode == .linearGradient {
                                    LinearGradientOverlayView(editor: model.editor, imageFrame: linearGradientImageFrame)
                                }

                                if model.editor.toolMode == .spotHeal {
                                    SpotHealOverlayView(editor: model.editor, imageFrame: spotHealImageFrame)
                                }
                            }
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(viewport.scale)
                    .offset(viewport.offset)
                    .contentShape(Rectangle())
                    .gesture(viewportMagnification(in: geometry.size))
                    .simultaneousGesture(viewportPan(in: geometry.size))
                    .simultaneousGesture(viewportDoubleClick(in: geometry.size))
                    .onAppear {
                        prepareViewport(imageSize: imageFrame.size, viewportSize: geometry.size)
                    }
                    .onChange(of: imageFrame.size) { _, newSize in
                        prepareViewport(imageSize: newSize, viewportSize: geometry.size)
                    }
                } else if model.editor.decodeFailed {
                    // Distinct from the spinner below: nothing is actually
                    // running (isRendering is false too), so showing
                    // "Decoding RAW…" here would be a permanent lie -- the
                    // decode already gave up, dismissing the alert doesn't
                    // change that.
                    decodeFailedPlaceholder
                } else {
                    ProgressView(L10n.t("Decoding RAW…"))
                        .controlSize(.large)
                }

                if model.editor.compareMode == .single, model.editor.isShowingOriginal {
                    Text(L10n.t("Original"))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.thinMaterial, in: Capsule())
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            // Decode at the size actually on screen, not at native resolution
            // (spec §9).
            .onChange(of: geometry.size) { _, newSize in
                updatePreviewSize(newSize)
            }
            .onAppear {
                updatePreviewSize(geometry.size)
                viewportSize = geometry.size
            }
        }
    }

    /// The transform is deliberately UI-only. It is applied to the image and
    /// its active overlay together, so crop and healing handles never drift
    /// away from the pixels they describe.
    private var viewportTransform: CGAffineTransform {
        CGAffineTransform(translationX: viewport.offset.width, y: viewport.offset.height)
            .scaledBy(x: viewport.scale, y: viewport.scale)
    }

    private func prepareViewport(imageSize: CGSize, viewportSize: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let photoID = model.selectedPhotoID
        guard viewportPhotoID != photoID || viewportImageSize != imageSize else { return }
        viewportPhotoID = photoID
        viewportImageSize = imageSize
        self.viewportSize = viewportSize
        viewport.setFit(imageSize: imageSize, viewportSize: viewportSize)
    }

    private func viewportMagnification(in size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                guard model.editor.toolMode == .adjust else { return }
                if magnificationBaseline == nil {
                    magnificationBaseline = viewport
                }
                guard let baseline = magnificationBaseline else { return }
                var next = baseline
                next.zoom(
                    to: baseline.scale * value,
                    anchor: CGPoint(x: size.width / 2, y: size.height / 2),
                    imageSize: viewportImageSize,
                    viewportSize: size
                )
                viewport = next
            }
            .onEnded { _ in
                magnificationBaseline = nil
            }
    }

    /// Spec §5.2.2: panning by click-drag requires holding Space, so a plain
    /// click on the canvas doesn't fight the crop/eyedropper/gradient/spot
    /// overlays' own drags.
    private func viewportPan(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard model.editor.toolMode == .adjust, isSpaceKeyDown else { return }
                if panBaseline == nil {
                    panBaseline = viewport
                }
                guard var next = panBaseline else { return }
                next.pan(
                    by: value.translation,
                    imageSize: viewportImageSize,
                    viewportSize: size
                )
                viewport = next
            }
            .onEnded { _ in
                panBaseline = nil
            }
    }

    /// Spec §5.2.2: double-click toggles Fit/100%, centred on the click.
    private func viewportDoubleClick(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                guard model.editor.toolMode == .adjust else { return }
                if viewport.mode == .fit {
                    setViewportScale(1, anchor: value.location)
                } else {
                    resetViewportToFit()
                }
            }
    }

    /// Phase 2.1 side-by-side comparison (spec §6.1): the original and
    /// edited photo each occupy their own half of the canvas. Neither pane
    /// applies its own scale/offset -- the caller (`previewArea`) applies
    /// `viewport.scale`/`viewport.offset` once, to this whole view, so a
    /// pinch-zoom or Space-drag can never leave the two sides looking at
    /// different positions.
    private func sideBySideCompareView(original: CGImage, edited: CGImage, size: CGSize) -> some View {
        HStack(spacing: 1) {
            compareHalf(image: original, label: L10n.t("Original"))
            compareHalf(image: edited, label: L10n.t("Edited"))
        }
        .frame(width: size.width, height: size.height)
    }

    private func compareHalf(image: CGImage, label: String) -> some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
                .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// Phase 2.1 vertical wipe (spec §6.1): both images are drawn full-size,
    /// under the same shared `viewport` transform the caller applies to this
    /// whole view -- the original layer is simply masked to the divider's
    /// current fraction of the canvas width (`model.editor.wipePosition`),
    /// so dragging the handle never needs its own zoom/pan math.
    /// The `DragGesture` on the wipe handle reports `location`/`translation`
    /// in the handle circle's own small local coordinate space, not the
    /// canvas's -- so the divider's new position must be derived from the
    /// drag's *translation* (a relative delta, unaffected by which view it's
    /// attached to) added to the divider's position when the drag began,
    /// rather than from the handle-local `location` directly. Clamping here
    /// mirrors `EditorSession.setWipePosition`'s own clamp so a test can
    /// verify this pure math in isolation, without going through a gesture.
    static func wipeDragPosition(baseline: Double, translation: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return baseline }
        let raw = baseline + Double(translation / width)
        return min(max(raw, EditorSession.minimumWipePosition), EditorSession.maximumWipePosition)
    }

    private func wipeCompareView(original: CGImage, edited: CGImage, size: CGSize) -> some View {
        let dividerX = min(max(size.width * CGFloat(model.editor.wipePosition), 0), size.width)
        return ZStack(alignment: .topLeading) {
            Image(decorative: edited, scale: 1, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(16)
                .frame(width: size.width, height: size.height)

            Image(decorative: original, scale: 1, orientation: .up)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(16)
                .frame(width: size.width, height: size.height)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: dividerX, height: size.height)
                }

            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: size.height)
                .position(x: dividerX, y: size.height / 2)
                .allowsHitTesting(false)

            Circle()
                .fill(Color.white)
                .overlay(Circle().stroke(Color.black.opacity(0.2)))
                .frame(width: 24, height: 24)
                .position(x: dividerX, y: size.height / 2)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let baseline = wipeDragBaseline ?? model.editor.wipePosition
                            wipeDragBaseline = baseline
                            model.editor.setWipePosition(
                                Self.wipeDragPosition(baseline: baseline, translation: value.translation.width, width: size.width)
                            )
                        }
                        .onEnded { _ in
                            wipeDragBaseline = nil
                        }
                )

            Text(L10n.t("Original"))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
                .padding(16)

            Text(L10n.t("Edited"))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: size.width, height: size.height)
    }

    private var decodeFailedPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(L10n.t("Couldn't show this photo"))
                .foregroundStyle(.secondary)
        }
    }

    private func updatePreviewSize(_ size: CGSize) {
        let longestEdge = max(size.width, size.height) * displayScale
        guard longestEdge.isFinite, longestEdge > 0 else { return }
        // Round to a step so a live window resize doesn't re-decode on every
        // frame of the drag.
        let stepped = (Int(longestEdge) / 256 + 1) * 256
        if abs(stepped - model.editor.previewPixelDimension) >= 256 {
            model.editor.previewPixelDimension = stepped
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.requestSelectPhoto(nil)
            } label: {
                Label(L10n.t("Back to Library"), systemImage: "square.grid.2x2")
            }
            .help(L10n.t("Back to the library grid"))
        }

        ToolbarItemGroup(placement: .principal) {
            CompareButton()

            Picker(L10n.t("Compare Mode"), selection: Binding(
                get: { model.editor.compareMode },
                set: { model.editor.setCompareMode($0) }
            )) {
                Text(L10n.t("Single View")).tag(EditorSession.CompareMode.single)
                Text(L10n.t("Side by Side")).tag(EditorSession.CompareMode.sideBySide)
                Text(L10n.t("Wipe")).tag(EditorSession.CompareMode.verticalWipe)
            }
            .pickerStyle(.menu)
            .disabled(!model.editor.canCompareWithOriginal)
            .help(L10n.t("Compare Mode"))

            Button {
                model.editor.undo()
            } label: {
                Label(L10n.t("Undo"), systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.editor.canUndo)

            Button {
                model.editor.redo()
            } label: {
                Label(L10n.t("Redo"), systemImage: "arrow.uturn.forward")
            }
            .disabled(!model.editor.canRedo)
        }

        ToolbarItemGroup(placement: .automatic) {
            Button {
                resetViewportToFit()
            } label: {
                Label(L10n.t("Fit"), systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .keyboardShortcut("0", modifiers: .command)
            .help(L10n.t("Fit the photo to the canvas"))

            Button {
                setViewportScale(1)
            } label: {
                Text("100%")
                    .monospacedDigit()
            }
            .keyboardShortcut("1", modifiers: .command)
            .help(L10n.t("View at 100 percent"))

            Button {
                zoomViewportStepped(direction: -1)
            } label: {
                Label(L10n.t("Zoom out"), systemImage: "minus.magnifyingglass")
            }
            .keyboardShortcut("-", modifiers: .command)
            .help(L10n.t("Zoom out"))

            Text("\(Int((viewport.scale * 100).rounded()))%")
                .monospacedDigit()
                .frame(minWidth: 44)

            Button {
                zoomViewportStepped(direction: 1)
            } label: {
                Label(L10n.t("Zoom in"), systemImage: "plus.magnifyingglass")
            }
            .keyboardShortcut("+", modifiers: .command)
            .help(L10n.t("Zoom in"))
        }

        ToolbarItem(placement: .automatic) {
            SaveStateLabel(state: model.editor.saveState)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                model.isShowingExportSheet = true
            } label: {
                Label(L10n.t("Export"), systemImage: "square.and.arrow.up")
            }
            .disabled(model.selectedPhoto == nil)
            .help(L10n.t("Export a full-resolution photo"))
        }
    }

    private func resetViewportToFit() {
        viewport.setFit(imageSize: viewportImageSize, viewportSize: viewportSize)
    }

    private func setViewportScale(_ scale: CGFloat, anchor: CGPoint? = nil) {
        viewport.zoom(
            to: scale,
            anchor: anchor ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2),
            imageSize: viewportImageSize,
            viewportSize: viewportSize
        )
    }

    /// Command +/- (spec §5.2.1): steps through the fixed zoom ladder rather
    /// than scaling by a continuous factor.
    private func zoomViewportStepped(direction: Int) {
        setViewportScale(CanvasViewportState.steppedScale(from: viewport.scale, direction: direction))
    }
}

/// Hold to peek at the original, click to pin it (spec §6.2).
private struct CompareButton: View {
    @EnvironmentObject private var model: LibraryViewModel
    /// The persistent "pinned" state a click toggles. Kept separate from
    /// `model.editor.isShowingOriginal`, which also gets driven transiently
    /// while a hold is in progress.
    @State private var isPinned = false
    @State private var pressBeganAt: Date?
    /// Below this, a press+release is a click; at or above it, a hold-to-peek.
    private static let holdThreshold: TimeInterval = 0.25

    var body: some View {
        Button {
            // Intentionally empty. A first attempt kept the toggle here
            // alongside the gesture below, but `minimumDistance: 0` means the
            // gesture also fires for a plain click, not just a drag -- so a
            // click ran both this action *and* the gesture, and the two
            // fought over `isShowingOriginal` (found manually 2026-08-18:
            // clicking always ended up pinned to the original, never toggling
            // back). A second attempt moved the toggle into the gesture but
            // deferred "peek" through an async `Task.sleep`; that made both
            // click *and* hold stop working (found manually 2026-08-19) --
            // an active drag gesture runs the run loop in event-tracking
            // mode, which can starve a Task-based timer until the mouse is
            // released, i.e. after the decision was already needed. This
            // version has exactly one thing deciding `isShowingOriginal`,
            // computed synchronously from real press/release timestamps, so
            // there is nothing left to race and nothing waiting on a timer
            // that a live drag can starve.
        } label: {
            Label(L10n.t("Original"), systemImage: "rectangle.righthalf.inset.filled.arrow.right")
        }
        .disabled(!model.editor.canCompareWithOriginal || model.editor.compareMode != .single)
        .help(L10n.t("Hold to compare with the original, or click to pin it"))
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard model.editor.canCompareWithOriginal else { return }
                    if pressBeganAt == nil {
                        pressBeganAt = Date()
                    }
                    // Immediate feedback for the whole press, tap or hold
                    // alike -- onEnded below decides what happens on release.
                    model.editor.isShowingOriginal = true
                }
                .onEnded { _ in
                    defer { pressBeganAt = nil }
                    let heldLongEnough = pressBeganAt.map {
                        Date().timeIntervalSince($0) >= Self.holdThreshold
                    } ?? false
                    if heldLongEnough {
                        // Hold-to-peek ends: back to whatever was pinned.
                        model.editor.isShowingOriginal = isPinned
                    } else {
                        // A quick tap: toggle the pin.
                        isPinned.toggle()
                        model.editor.isShowingOriginal = isPinned
                    }
                }
        )
    }
}

private struct SaveStateLabel: View {
    let state: SaveState

    var body: some View {
        switch state {
        case .unchanged:
            EmptyView()
        case .pending:
            Label(L10n.t("Unsaved"), systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .saving:
            Label(L10n.t("Saving…"), systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .saved:
            Label(L10n.t("Saved"), systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(L10n.t("Not saved"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(message)
        }
    }
}
