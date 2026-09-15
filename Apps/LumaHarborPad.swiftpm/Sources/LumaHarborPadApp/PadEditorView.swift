import AdjustmentUI
import EditorCore
import Localization
import PhotoLibraryCore
import Photos
import PresetCore
import RawProcessingCore
import SwiftUI
import UniformTypeIdentifiers

/// The adaptive editing surface (Task 7): the same canvas and the same ten
/// basic sliders as Task 6, but the *container* the sliders live in adapts
/// to the available size and to an explicit work/focus toggle —
/// `PadEditorLayoutPolicy` decides trailing dock vs. bottom drawer purely
/// from width/height, `PadBottomDrawerPolicy` decides whether the drawer
/// sheet should actually be presented, and `workspaceState.workspaceMode`
/// decides work vs. focus.
///
/// `editor` — and therefore the open photo, its adjustments, and its undo
/// stack — is the same `EditorSession` instance across every layout this
/// view ever renders; resizing, rotating, or toggling work/focus only ever
/// changes which container the same controls render inside, never what
/// document is open or what state it holds.
///
/// `workspaceState` (mode, canvas zoom, floating-panel offset) is
/// deliberately scoped to *one specific document*, not to this view's own
/// lifetime: `PadEditorView` is not recreated when `model.document` changes
/// from one document to another (`PadRootView` keeps showing the same
/// `PadEditorView` the whole time `model.document != nil`), so this view
/// explicitly resets that state via `PadDocumentScopedWorkspacePolicy`
/// whenever the open document's id actually changes — see `body`'s
/// `.onChange(of: model.document?.id)`.
struct PadEditorView: View {
    @ObservedObject var model: PadEditorModel
    @ObservedObject private var editor: EditorSession
    @ObservedObject private var library: PadLibraryModel
    @ObservedObject private var batchCoordinator: PadBatchAdjustmentCoordinator
    let exporter: PhotoExporter
    let services: PadAppServices
    @ObservedObject private var presetLibrary: PadPresetLibrary
    @Binding private var sceneWorkspaceState: PadWorkspaceState

    /// Work/focus mode, canvas zoom, and floating-panel position — see the
    /// type's own documentation for why these three travel together and
    /// reset together. View-local `@State`: survives every work/focus
    /// toggle and every resize/rotation for the *same* document, but is
    /// explicitly reset (not merely "happens to survive") when the open
    /// document's id changes underneath this same view instance.
    @State private var workspaceState = PadDocumentScopedWorkspaceState.initial

    /// Owns all inspector presentation state (active domain, Adjust submode,
    /// panel hosting) for this editor surface. Scoped to this view's lifetime,
    /// which is stable for the duration of one open-document session.
    /// Never holds a second copy of `PhotoAdjustments` or touches undo/redo.
    @StateObject private var inspector = PadInspectorCoordinator()

    /// P2 (`2026-09-10-shared-professional-inspector-catalog.md`): the same
    /// shared state machine Mac's `InspectorView` attaches -- search,
    /// favorites, pin, smart follow. `body`'s `.onChange` handlers below keep
    /// `inspector`'s domain/submode in sync whenever this model's
    /// `activeSectionID` moves, whether from an explicit tap (search result,
    /// favorite) or from Smart Follow reacting to `editor.toolMode`.
    @StateObject private var inspectorNavigation = InspectorNavigationModel()

    /// Whether the bottom drawer sheet is currently presented — a real,
    /// toggleable binding driven by `PadBottomDrawerPolicy`, never a
    /// `.sheet(isPresented: .constant(true))`. See `updateDrawerPresentation`.
    @State private var isDrawerPresented = false

    /// Remembers an intentional drawer dismissal so a rotation or Split View
    /// resize does not immediately cover the photo again. Switching back to
    /// work mode or pressing the inspector toolbar button clears this flag.
    @State private var isDrawerDismissedByUser = false

    /// The single Inspector can be temporarily reduced to a visible restore
    /// tile so the photo stays unobstructed. This is presentation state only;
    /// adjustment values remain owned by `EditorSession`.
    @State private var isInspectorMinimized = false

    /// The most recent size `GeometryReader` reported. Kept as `@State`
    /// (rather than threaded through every computed property that needs
    /// it) so gesture callbacks — which run outside `body`'s own
    /// evaluation — can still read "what's the available size right now."
    @State private var availableSize: CGSize = .zero

    /// The floating panel's own measured size, captured via
    /// `FloatingPanelSizeKey` below. Used only for clamping; defaults to a
    /// reasonable estimate so a re-clamp before the very first real
    /// measurement still behaves
    /// sanely rather than clamping against a degenerate zero-size box.
    @State private var floatingPanelMeasuredSize = CGSize(
        width: PadEditorLayoutPolicy.minimumInspectorWidth,
        height: 400
    )
    @State private var exportedURL: URL?
    @State private var isExporting = false
    @State private var isPresentingExportOptions = false
    @State private var exportOptions = PadExportOptions()
    @State private var adjustmentClipboard: PadAdjustmentClipboard?
    @State private var clipboardFields = Set(AdjustmentFieldID.allCases)
    @State private var copyIncludesGeometry = false
    @State private var copyIncludesLocalAdjustments = false
    @State private var isSavingToPhotos = false
    @State private var batchMessage: String?
    /// Drives the explicit "Save to Files" `fileExporter` flow (spec
    /// §5.5.1), alongside the existing ShareLink/Photos destinations --
    /// never a second export path, only a second *destination picker* over
    /// the same already-exported file at `exportedURL`.
    @State private var isPresentingFileExporter = false
    /// The wipe handle is rendered as a 44pt strip, so `DragGesture`'s local
    /// location cannot be treated as a canvas coordinate. Capture the
    /// normalized position once per drag and apply the gesture translation to
    /// it instead; this keeps the divider stable while the strip moves.
    @State private var wipeDragStartPosition: CGFloat?

    @GestureState private var floatingPanelDragTranslation: CGSize = .zero
    @GestureState private var canvasMagnification: CGFloat = 1

    private static let minimumCanvasScale: CGFloat = 1
    private static let maximumCanvasScale: CGFloat = 5
    /// How much of the floating panel must stay reachable within the
    /// available area at all times — see `PadFloatingPanelLayout`.
    private static let floatingPanelMinimumVisibleEdge = PadEditorLayoutPolicy.floatingPanelMinimumVisibleEdge
    private static let floatingPanelDefaultOrigin = CGPoint(x: 24, y: 24)

    init(
        model: PadEditorModel,
        exporter: PhotoExporter,
        presetLibrary: PadPresetLibrary,
        library: PadLibraryModel,
        services: PadAppServices,
        sceneWorkspaceState: Binding<PadWorkspaceState>
    ) {
        self.model = model
        self.editor = model.editor
        self.exporter = exporter
        self.presetLibrary = presetLibrary
        self.library = library
        self.services = services
        self._batchCoordinator = ObservedObject(wrappedValue: services.batchCoordinator)
        self._sceneWorkspaceState = sceneWorkspaceState
    }

    var body: some View {
        GeometryReader { proxy in
            // Use the same live size for the layout decision that SwiftUI is
            // currently proposing. `availableSize` is retained for gesture
            // callbacks, but it can lag one render behind during rotation or
            // Split View changes and must not decide whether the dock fits.
            workspaceContent(for: proxy.size)
                .sheet(isPresented: $isDrawerPresented, onDismiss: handleDrawerDismissal) {
                    bottomDrawerPanel
                        .presentationDetents([.height(PadBottomDrawerMetrics.peekHeight), .medium, .large])
                        .presentationDragIndicator(.visible)
                        .presentationCornerRadius(PadBottomDrawerMetrics.cornerRadius)
                        .presentationBackground(.thickMaterial)
                        .presentationContentInteraction(.scrolls)
                        .presentationBackgroundInteraction(.enabled)
                }
                .onAppear {
                    availableSize = proxy.size
                    updateDrawerPresentation()
                }
                .onChange(of: proxy.size) { _, newSize in
                    availableSize = newSize
                    updateDrawerPresentation()
                    reclampFloatingPanelOffset()
                }
                .onChange(of: workspaceState.workspaceMode) { _, newMode in
                    if newMode == .work {
                        isDrawerDismissedByUser = false
                    }
                    updateDrawerPresentation()
                }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.t("Close")) {
                    Task { await model.closeCurrentDocument() }
                }
                .disabled(model.isPreparingDocument)
            }
            ToolbarItem(placement: .primaryAction) {
                workspaceModeToggle
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isPresentingExportOptions = true
                } label: {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(L10n.t("Export"), systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting || model.document == nil)
                .accessibilityLabel(Text(L10n.t("Export")))

                if let exportedURL {
                    ShareLink(item: exportedURL) {
                        Label(L10n.t("Share"), systemImage: "square.and.arrow.up.on.square")
                    }
                    .accessibilityLabel(Text(L10n.t("Share exported photo")))

                    Button {
                        saveToPhotos(exportedURL)
                    } label: {
                        if isSavingToPhotos {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(L10n.t("Save to Photos"), systemImage: "photo.badge.plus")
                        }
                    }
                    .disabled(isSavingToPhotos)

                    Button {
                        isPresentingFileExporter = true
                    } label: {
                        Label(L10n.t("Save to Files"), systemImage: "folder")
                    }
                    .accessibilityLabel(Text(L10n.t("Save to Files")))
                }

                compareMenu
                adjustmentClipboardMenu
            }
        }
        .alert(item: $editor.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alertBody(alert)),
                dismissButton: .default(Text(L10n.t("OK")))
            )
        }
        // Spec §5.5.1/§5.5.2: a third, explicit destination over the exact
        // same full-resolution export `exportFullResolution()` already
        // produced -- never a second encode of the photo, just a
        // `FileDocument` wrapper (`ExportedPhotoFileDocument`) around the
        // bytes already on disk at `exportedURL`.
        .fileExporter(
            isPresented: $isPresentingFileExporter,
            document: exportedURL.map { ExportedPhotoFileDocument(fileURL: $0) },
            contentType: UTType(exportOptions.format.utTypeIdentifier) ?? .data,
            defaultFilename: exportedURL?.deletingPathExtension().lastPathComponent
        ) { result in
            switch result {
            case .success:
                break
            case .failure(let error):
                // Spec §5.5.3/§5.5.4: the user dismissing the picker is
                // `cancelled`, never shown as a failure alert.
                guard (error as? CocoaError)?.code != .userCancelled else { return }
                model.alert = EditorAlert(
                    title: L10n.t("Couldn't save to Files"),
                    message: error.localizedDescription,
                    nextStep: L10n.t("Try again.")
                )
            }
        }
        .sheet(isPresented: $isPresentingExportOptions) {
            PadExportOptionsSheet(options: $exportOptions) {
                isPresentingExportOptions = false
                exportFullResolution()
            }
        }
        .alert(
            L10n.t("Batch action"),
            isPresented: Binding(
                get: { batchMessage != nil },
                set: { if !$0 { batchMessage = nil } }
            )
        ) {
            Button(L10n.t("OK"), role: .cancel) { batchMessage = nil }
        } message: {
            Text(batchMessage ?? "")
        }
        // The open document's identity, not this view's own lifetime, is
        // what scopes `workspaceState` — see the type's documentation.
        .onChange(of: model.document?.id) { oldValue, newValue in
            workspaceState = PadDocumentScopedWorkspacePolicy.resettingIfNeeded(
                workspaceState, previousDocumentID: oldValue, currentDocumentID: newValue
            )
        }
        .onChange(of: editor.toolMode) { _, newValue in
            inspectorNavigation.follow(toolMode: newValue)
        }
        .onChange(of: inspectorNavigation.activeSectionID) { _, newValue in
            applyInspectorNavigation(newValue)
        }
    }

    /// Bridges a shared-catalog section (search tap, favorite tap, or Smart
    /// Follow) onto `inspector`'s domain/submode -- the one place iPad
    /// translates `InspectorSectionID` into `PadInspectorDomain`/
    /// `PadAdjustSubmode`, so search/favorites/smart-follow never need their
    /// own copy of that mapping.
    private func applyInspectorNavigation(_ sectionID: InspectorSectionID) {
        let section = InspectorCatalog.section(sectionID)
        inspector.selectDomain(section.domain)
        if let submode = section.submode {
            inspector.selectAdjustSubmode(submode)
        }
    }

    // MARK: - Drawer presentation

    /// Reconciles automatic layout presentation with the user's explicit
    /// close choice. Called whenever mode or `availableSize` changes
    /// (resize/rotation/Split View); explicit close/open actions use the
    /// helpers below so they remain reversible.
    private func updateDrawerPresentation() {
        let inspectorPresentation = PadEditorLayoutPolicy.presentation(forWidth: availableSize.width, height: availableSize.height)
        let target = PadBottomDrawerPolicy.presentation(mode: workspaceState.workspaceMode, inspectorPresentation: inspectorPresentation) == .presented
        let shouldPresent = target && !isDrawerDismissedByUser && !isInspectorMinimized
        if isDrawerPresented != shouldPresent {
            isDrawerPresented = shouldPresent
        }
    }

    /// A user-dismissed drawer stays out of the way until explicitly
    /// reopened. Automatic layout changes still dismiss it when the editor
    /// becomes wide enough for the trailing dock, without marking that as a
    /// user preference.
    private func handleDrawerDismissal() {
        let presentation = PadEditorLayoutPolicy.presentation(
            forWidth: availableSize.width,
            height: availableSize.height
        )
        guard workspaceState.workspaceMode == .work, presentation == .bottomDrawer else { return }
        isDrawerDismissedByUser = true
    }

    private func dismissBottomDrawer() {
        isDrawerDismissedByUser = true
        isDrawerPresented = false
    }

    private func presentBottomDrawer() {
        isInspectorMinimized = false
        isDrawerDismissedByUser = false
        isDrawerPresented = true
    }

    private func minimizeInspector() {
        isInspectorMinimized = true
        isDrawerDismissedByUser = true
        isDrawerPresented = false
        workspaceState.workspaceMode = .work
    }

    private func restoreInspector() {
        isInspectorMinimized = false
        isDrawerDismissedByUser = false
        updateDrawerPresentation()
    }

    /// A horizontal drag on the drawer's dedicated handle hands the same
    /// panel to Focus Mode. The offset is seeded from the drag so the panel
    /// appears where the user moved it instead of jumping back to center.
    private func moveDrawerToFocus(with translation: CGSize) {
        guard abs(translation.width) >= abs(translation.height),
              abs(translation.width) >= 48 else { return }

        let proposedOffset = CGSize(width: translation.width, height: 0)
        workspaceState.floatingPanelOffset = PadFloatingPanelLayout.clampedOffset(
            proposedOffset: proposedOffset,
            panelOrigin: Self.floatingPanelDefaultOrigin,
            panelSize: floatingPanelMeasuredSize,
            availableSize: availableSize,
            minimumVisibleEdge: Self.floatingPanelMinimumVisibleEdge
        )
        isInspectorMinimized = false
        isDrawerDismissedByUser = false
        workspaceState.workspaceMode = .focus
    }

    // MARK: - Work / focus toggle

    private var workspaceModeToggle: some View {
        // Switching `workspaceState.workspaceMode` is the only thing this
        // button does directly — no `editor` call of any kind, so it can
        // never create an undo entry, touch adjustments, or open/close
        // anything. `updateDrawerPresentation()` (triggered by the
        // `.onChange` below, not called here) only ever touches
        // `isDrawerPresented`, equally inert from `editor`'s perspective.
        Button {
            workspaceState.workspaceMode = (workspaceState.workspaceMode == .work) ? .focus : .work
        } label: {
            switch workspaceState.workspaceMode {
            case .work:
                Label(L10n.t("Focus Mode"), systemImage: "rectangle.inset.filled")
            case .focus:
                Label(L10n.t("Work Mode"), systemImage: "rectangle.split.2x1")
            }
        }
        // Explicit, not left to `Label`'s own inference — a toolbar can
        // render this icon-only depending on available space, and an
        // icon-only control must still have a real accessibility label.
        .accessibilityLabel(Text(workspaceState.workspaceMode == .work ? L10n.t("Focus Mode") : L10n.t("Work Mode")))
    }

    private var compareMenu: some View {
        Menu {
            Button {
                editor.setCompareMode(.single)
            } label: {
                Label(L10n.t("Single View"), systemImage: "rectangle")
            }
            .disabled(editor.compareMode == .single)

            Button {
                editor.setCompareMode(.sideBySide)
            } label: {
                Label(L10n.t("Side by Side"), systemImage: "rectangle.split.2x1")
            }
            .disabled(!editor.canCompareWithOriginal)

            Button {
                editor.setCompareMode(.verticalWipe)
            } label: {
                Label(L10n.t("Wipe"), systemImage: "rectangle.split.2x1.fill")
            }
            .disabled(!editor.canCompareWithOriginal)

            Divider()

            Toggle(isOn: $editor.isShowingOriginal) {
                Label(L10n.t("Hold Before"), systemImage: "eye")
            }
            .disabled(editor.compareMode != .single || !editor.canCompareWithOriginal)

            if !editor.snapshots.isEmpty {
                Divider()
                Menu(L10n.t("Compare with Snapshot")) {
                    ForEach(editor.snapshots) { snap in
                        Button {
                            if editor.comparisonSnapshot?.id == snap.id {
                                editor.comparisonSnapshot = nil
                            } else {
                                editor.comparisonSnapshot = snap
                            }
                        } label: {
                            HStack {
                                Text(snap.name)
                                if editor.comparisonSnapshot?.id == snap.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    if editor.comparisonSnapshot != nil {
                        Divider()
                        Button(L10n.t("Exit Compare")) {
                            editor.comparisonSnapshot = nil
                        }
                    }
                }
            }
        } label: {
            Label(L10n.t("Compare Mode"), systemImage: "rectangle.on.rectangle")
        }
        .accessibilityLabel(Text(L10n.t("Compare")))
    }

    private var adjustmentClipboardMenu: some View {
        Menu {
            Toggle(L10n.t("Include Geometry"), isOn: $copyIncludesGeometry)
            Toggle(L10n.t("Include Local Adjustments"), isOn: $copyIncludesLocalAdjustments)

            Divider()

            Button {
                adjustmentClipboard = PadAdjustmentClipboard.copying(
                    from: editor.adjustments,
                    fields: clipboardFields,
                    includeGeometry: copyIncludesGeometry,
                    includeLocalAdjustments: copyIncludesLocalAdjustments
                )
            } label: {
                Label(L10n.t("Copy Adjustments"), systemImage: "doc.on.doc")
            }
            .disabled(editor.photo == nil || clipboardFields.isEmpty)

            Button {
                guard let adjustmentClipboard else { return }
                editor.pasteAdjustments(
                    patch: adjustmentClipboard.patch,
                    geometry: adjustmentClipboard.geometry,
                    localAdjustments: adjustmentClipboard.localAdjustments
                )
            } label: {
                Label(L10n.t("Paste Adjustments"), systemImage: "doc.on.clipboard")
            }
            .disabled(editor.photo == nil || adjustmentClipboard == nil)

            Button {
                Task {
                    let transaction = await batchCoordinator.sync(
                        adjustmentClipboard,
                        sourcePhotoID: editor.photo?.id
                    )
                    guard let transaction else {
                        batchMessage = L10n.t("Nothing to sync.")
                        return
                    }
                    batchMessage = PadBatchAdjustmentCoordinator.summaryMessage(transaction)
                }
            } label: {
                Label(L10n.t("Sync to Selected Photos"), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(editor.photo == nil || adjustmentClipboard == nil || library.selectedPhotoIDs.count < 2)

            Button {
                Task {
                    guard let summary = await batchCoordinator.undoLastTransaction() else { return }
                    batchMessage = PadBatchAdjustmentCoordinator.undoSummaryMessage(summary)
                }
            } label: {
                Label(L10n.t("Undo Batch Sync"), systemImage: "arrow.uturn.backward")
            }
            .disabled(batchCoordinator.lastTransaction == nil)
        } label: {
            Image(systemName: "slider.horizontal.2.square")
        }
        .accessibilityLabel(Text(L10n.t("Copy Adjustments")))
    }

    // MARK: - Layout selection

    @ViewBuilder
    private func workspaceContent(for size: CGSize) -> some View {
        switch workspaceState.workspaceMode {
        case .work:
            workLayout(for: size)
        case .focus:
            focusLayout(for: size)
        }
    }

    /// The bottom drawer's own presentation is handled entirely by the
    /// `.sheet(isPresented: $isDrawerPresented)` attached once, up in
    /// `body` — never nested inside this `switch`, so its view identity
    /// stays stable across every presentation/mode change instead of
    /// being torn down and rebuilt (which is what made the drawer
    /// unreliable to close and reopen before). This only decides the
    /// *dock* layout; `.bottomDrawer` just needs the canvas alone.
    @ViewBuilder
    private func workLayout(for size: CGSize) -> some View {
        let plan = PadEditorLayoutPolicy.plan(for: size)
        ZStack(alignment: .bottomTrailing) {
            switch plan.presentation {
            case .trailingDock:
                HStack(spacing: 0) {
                    PadToolRail(selection: Binding(
                        get: { inspector.activeDomain },
                        set: { inspector.selectDomain($0) }
                    ))
                    Divider()
                    canvas(for: size)
                    if !isInspectorMinimized {
                        Divider()
                        trailingDockPanel(width: plan.inspectorWidth ?? PadEditorLayoutPolicy.minimumInspectorWidth)
                    }
                }
            case .bottomDrawer:
                canvas(for: size)
            case .floating:
                // `.floating` is the focus-mode presentation and is never
                // produced by `PadEditorLayoutPolicy` while in work mode.
                // Treat it as canvas-only (the bottom drawer sheet, if needed,
                // is still driven by `PadBottomDrawerPolicy` via the shared
                // `.sheet` in `body`).
                canvas(for: size)
            }

            if isInspectorMinimized {
                inspectorRestoreTile
                    .padding(12)
            }
        }
    }

    private func focusLayout(for size: CGSize) -> some View {
        ZStack(alignment: .bottomTrailing) {
            canvas(for: size)
            if !isInspectorMinimized {
                floatingPanel(width: PadEditorLayoutPolicy.floatingPanelWidth(for: size))
                    .background(floatingPanelSizeReader)
                    .offset(
                        x: Self.floatingPanelDefaultOrigin.x + workspaceState.floatingPanelOffset.width + floatingPanelDragTranslation.width,
                        y: Self.floatingPanelDefaultOrigin.y + workspaceState.floatingPanelOffset.height + floatingPanelDragTranslation.height
                    )
            } else {
                inspectorRestoreTile
                    .padding(12)
            }
        }
    }

    // MARK: - Canvas (shared by every layout)

    @ViewBuilder
    private func canvas(for size: CGSize) -> some View {
        ZStack {
            Color.black
            if editor.previewImage != nil || editor.originalImage != nil {
                comparisonCanvas
                    .scaleEffect(workspaceState.canvasScale * canvasMagnification)
                    .gesture(
                        MagnificationGesture()
                            .updating($canvasMagnification) { value, state, _ in
                                state = value
                            }
                            .onEnded { value in
                                let proposed = workspaceState.canvasScale * value
                                workspaceState.canvasScale = min(max(proposed, Self.minimumCanvasScale), Self.maximumCanvasScale)
                            }
                    )
            } else if editor.decodeFailed {
                ContentUnavailableView(
                    L10n.t("Couldn't show this photo"),
                    systemImage: "exclamationmark.triangle"
                )
            } else {
                ProgressView(L10n.t("Decoding RAW…"))
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if shouldShowFilmstrip(forWidth: size.width) {
                PadEditorFilmstrip(
                    photos: filmstripPhotos,
                    currentPhotoID: editor.photo?.id,
                    library: library,
                    services: services,
                    onSelect: openFilmstripPhoto
                )
            }
        }
    }

    private func shouldShowFilmstrip(forWidth width: CGFloat) -> Bool {
        guard workspaceState.workspaceMode == .work,
              sceneWorkspaceState.isFilmstripVisible else { return false }
        return PadWorkspaceLayoutPolicy.layout(
            forWidth: width
        ).showsFilmstrip
    }

    private var filmstripPhotos: [PhotoAsset] {
        guard let currentID = editor.photo?.id else { return [] }
        guard let index = library.photos.firstIndex(where: { $0.id == currentID }) else {
            return []
        }
        let start = max(0, index - 4)
        let end = min(library.photos.count, index + 5)
        return Array(library.photos[start..<end])
    }

    private func openFilmstripPhoto(_ photo: PhotoAsset) {
        guard photo.id != editor.photo?.id else { return }
        Task {
            guard let asset = await library.openAsset(for: photo) else { return }
            editorModelOpen(asset)
        }
    }

    private func editorModelOpen(_ asset: LibraryOpenAsset) {
        model.openLibraryAsset(asset)
    }

    @ViewBuilder
    private var comparisonCanvas: some View {
        GeometryReader { proxy in
            switch editor.compareMode {
            case .single:
                if let image = editor.displayedImage {
                    canvasImageWithOverlays(image, in: proxy.size)
                }
            case .sideBySide:
                HStack(spacing: 1) {
                    if let original = editor.originalImage {
                        canvasImage(original)
                            .frame(maxWidth: .infinity)
                    }
                    if let edited = editor.previewImage {
                        canvasImage(edited)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
            case .verticalWipe:
                verticalWipeCanvas
            }
        }
    }

    /// The wipe viewport is padded like the side-by-side comparison, so its
    /// divider must use the post-padding content width. A nested reader keeps
    /// the image clip, divider, and 44pt gesture strip on the same coordinate
    /// system in portrait, landscape, and Split View.
    private var verticalWipeCanvas: some View {
        GeometryReader { wipeProxy in
            ZStack(alignment: .leading) {
                if let edited = editor.previewImage {
                    canvasImage(edited)
                }
                if let original = editor.originalImage {
                    canvasImage(original)
                        .frame(width: wipeProxy.size.width * editor.wipePosition)
                        .clipped()
                }
                Rectangle()
                    .fill(.white.opacity(0.9))
                    .frame(width: 2)
                    .offset(x: wipeProxy.size.width * editor.wipePosition - 1)

                // Keep the divider visually precise while giving iPad a
                // reliable touch target in portrait and Split View.
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 44)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .offset(x: wipeProxy.size.width * editor.wipePosition - 22)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard wipeProxy.size.width > 0 else { return }
                                let start = wipeDragStartPosition ?? editor.wipePosition
                                if wipeDragStartPosition == nil {
                                    wipeDragStartPosition = start
                                }
                                editor.setWipePosition(
                                    start + value.translation.width / wipeProxy.size.width
                                )
                            }
                            .onEnded { _ in
                                wipeDragStartPosition = nil
                            }
                    )
            }
            .frame(width: wipeProxy.size.width, height: wipeProxy.size.height)
        }
        .padding()
    }

    private func canvasImageWithOverlays(_ image: CGImage, in canvasSize: CGSize) -> some View {
        let imageFrame = fittedImageFrame(
            imageSize: CGSize(width: image.width, height: image.height),
            in: canvasSize,
            padding: 0
        )

        return ZStack {
            canvasImage(image)

            if editor.toolMode == .crop {
                PadCropOverlayView(editor: editor, imageFrame: imageFrame)
            }

            if editor.toolMode == .radialGradient {
                RadialMaskOverlayView(editor: editor, imageFrame: imageFrame)
            }

            if editor.toolMode == .brush {
                BrushMaskOverlayView(editor: editor, imageFrame: imageFrame)
            }

            if editor.toolMode == .linearGradient {
                LinearGradientMaskOverlayView(editor: editor, imageFrame: imageFrame)
            }

            if editor.toolMode == .spotHeal {
                SpotHealMaskOverlayView(editor: editor, imageFrame: imageFrame)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    private func fittedImageFrame(imageSize: CGSize, in container: CGSize, padding: CGFloat) -> CGRect {
        let available = CGSize(
            width: max(container.width - padding * 2, 0),
            height: max(container.height - padding * 2, 0)
        )
        guard imageSize.width > 0, imageSize.height > 0, available.width > 0, available.height > 0 else {
            return CGRect(origin: CGPoint(x: padding, y: padding), size: available)
        }

        let aspect = imageSize.width / imageSize.height
        let availableAspect = available.width / available.height
        let fittedSize: CGSize
        if aspect > availableAspect {
            fittedSize = CGSize(width: available.width, height: available.width / aspect)
        } else {
            fittedSize = CGSize(width: available.height * aspect, height: available.height)
        }
        return CGRect(
            x: padding + (available.width - fittedSize.width) / 2,
            y: padding + (available.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private func canvasImage(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFit()
    }

    private struct PadEditorFilmstrip: View {
        let photos: [PhotoAsset]
        let currentPhotoID: PhotoID?
        @ObservedObject var library: PadLibraryModel
        let services: PadAppServices
        let onSelect: (PhotoAsset) -> Void

        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(photos) { photo in
                        let folder = library.folder(for: photo.libraryID)
                        PadThumbnailCell(
                            photo: photo,
                            isBatchSelected: false,
                            isSelectionMode: false,
                            isOnline: photo.libraryID == .appStorage || folder?.isOnline == true,
                            sourceDisplayName: folder?.displayName ?? L10n.t("This iPad"),
                            sourceStatusMessage: filmstripStatus(for: folder),
                            provider: services.thumbnailProvider,
                            compact: true,
                            resolveSourceURL: { photo in
                                await services.thumbnailSourceURL(for: photo)
                            }
                        )
                        .frame(width: 116, height: 100)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    photo.id == currentPhotoID ? Color.accentColor : .clear,
                                    lineWidth: 3
                                )
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(photo) }
                        .accessibilityAddTraits(photo.id == currentPhotoID ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(height: 116)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Divider() }
            .accessibilityLabel(Text(L10n.t("Filmstrip")))
        }

        private func filmstripStatus(for folder: LibraryFolder?) -> String? {
            guard let folder else { return nil }
            switch folder.connectionState {
            case .ready: return nil
            case .readOnly: return L10n.t("Read-only")
            case .offline: return L10n.t("Offline")
            case .needsAuthorization: return L10n.t("Needs access")
            }
        }
    }

    // MARK: - Full-resolution export

    private func exportFullResolution() {
        guard let document = model.document else { return }
        isExporting = true

        Task {
            do {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LumaHarbor-Exports", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let request = exportOptions.request(
                    sourceURL: document.workingURL,
                    adjustments: editor.adjustments,
                    destinationDirectory: directory,
                    baseFilename: document.workingURL.deletingPathExtension().lastPathComponent
                )
                let outcome = try await exporter.export(request)
                exportedURL = outcome.url
            } catch {
                model.alert = EditorAlert(
                    title: L10n.t("Export failed"),
                    message: error.localizedDescription,
                    nextStep: L10n.t("Try again.")
                )
            }
            isExporting = false
        }
    }

    private func saveToPhotos(_ url: URL) {
        isSavingToPhotos = true
        Task {
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authorization == .authorized || authorization == .limited else {
                model.alert = EditorAlert(
                    title: L10n.t("Photos access is needed"),
                    message: L10n.t("Allow LumaHarbor to add exported photos in Settings."),
                    nextStep: nil
                )
                isSavingToPhotos = false
                return
            }

            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            } catch {
                model.alert = EditorAlert(
                    title: L10n.t("Couldn't save to Photos"),
                    message: error.localizedDescription,
                    nextStep: L10n.t("Try again.")
                )
            }
            isSavingToPhotos = false
        }
    }

    // MARK: - Work mode: trailing dock

    private func trailingDockPanel(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    saveStatusIndicator
                    Spacer(minLength: 8)
                    inspectorMinimizeButton
                }
                undoRedoControls
            }
            .padding()
            Divider()
            PadInspectorHost(
                inspector: inspector,
                navigation: inspectorNavigation,
                editor: editor,
                presetLibrary: presetLibrary,
                library: library,
                batchCoordinator: batchCoordinator,
                showsDomainBar: false
            )
        }
        .frame(width: width)
        .background(.thickMaterial)
    }

    // MARK: - Work mode: bottom drawer

    private var bottomDrawerPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    saveStatusIndicator
                    Spacer(minLength: 8)
                    bottomDrawerDragHandle
                    inspectorMinimizeButton
                    Button {
                        dismissBottomDrawer()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(L10n.t("Close")))
                    .help(Text(L10n.t("Close")))
                }
                undoRedoControls
            }
            .padding()
            Divider()
            PadInspectorHost(
                inspector: inspector,
                navigation: inspectorNavigation,
                editor: editor,
                presetLibrary: presetLibrary,
                library: library,
                batchCoordinator: batchCoordinator,
                showsDomainBar: true
            )
        }
    }

    // MARK: - Focus mode: floating panel

    private func floatingPanel(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    floatingPanelHeader
                    inspectorMinimizeButton
                }
                saveStatusIndicator
                undoRedoControls
            }
            .padding()
            Divider()
            PadInspectorHost(
                inspector: inspector,
                navigation: inspectorNavigation,
                editor: editor,
                presetLibrary: presetLibrary,
                library: library,
                batchCoordinator: batchCoordinator,
                showsDomainBar: true
            )
                .frame(maxHeight: 420)
        }
        .frame(width: width)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(radius: 12)
    }

    /// Measures the floating panel's actual rendered size into
    /// `floatingPanelMeasuredSize`, so `PadFloatingPanelLayout.clampedOffset`
    /// always clamps against the real size rather than a hardcoded guess —
    /// its height varies slightly with content/dynamic type, and this
    /// stays correct without depending on either.
    private var floatingPanelSizeReader: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: FloatingPanelSizeKey.self, value: proxy.size)
        }
        .onPreferenceChange(FloatingPanelSizeKey.self) { size in
            guard size != .zero else { return }
            floatingPanelMeasuredSize = size
        }
    }

    /// A dedicated drag handle, not the whole panel — the panel also
    /// contains `Slider`s (via `BasicAdjustmentPanel`), and a drag
    /// gesture covering the entire panel would fight their own drag
    /// gestures instead of letting them work.
    private var floatingPanelHeader: some View {
        HStack {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.t("Adjustments"))
                .font(.headline)
            Text(L10n.t("Drag to move this panel."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L10n.t("Adjustments")))
        .accessibilityHint(Text(L10n.t("Drag to move this panel.")))
        .gesture(
            DragGesture()
                .updating($floatingPanelDragTranslation) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    let proposed = CGSize(
                        width: workspaceState.floatingPanelOffset.width + value.translation.width,
                        height: workspaceState.floatingPanelOffset.height + value.translation.height
                    )
                    workspaceState.floatingPanelOffset = PadFloatingPanelLayout.clampedOffset(
                        proposedOffset: proposed,
                        panelOrigin: Self.floatingPanelDefaultOrigin,
                        panelSize: floatingPanelMeasuredSize,
                        availableSize: availableSize,
                        minimumVisibleEdge: Self.floatingPanelMinimumVisibleEdge
                    )
                }
        )
    }

    /// The drawer uses the same direct manipulation model as the floating
    /// panel. Dragging this handle moves the existing Inspector into Focus
    /// mode; there is no second "floating panel" mode button to discover.
    private var bottomDrawerDragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(Text(L10n.t("Adjustments")))
            .accessibilityHint(Text(L10n.t("Drag to move this panel.")))
            .help(Text(L10n.t("Drag to move this panel.")))
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onEnded { value in
                        moveDrawerToFocus(with: value.translation)
                    }
            )
    }

    private var inspectorMinimizeButton: some View {
        Button(action: minimizeInspector) {
            Image(systemName: "rectangle.compress.vertical")
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.t("Minimize Inspector")))
        .help(Text(L10n.t("Minimize Inspector")))
    }

    private var inspectorRestoreTile: some View {
        Button(action: restoreInspector) {
            Image(systemName: "slider.horizontal.3")
                .font(.headline)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel(Text(L10n.t("Show Inspector")))
        .help(Text(L10n.t("Show Inspector")))
    }

    /// Re-clamps whatever offset is already committed against the current
    /// `availableSize` — called on every resize/rotation/Split View change,
    /// so a panel left near an edge before the area shrank doesn't end up
    /// stranded outside it.
    private func reclampFloatingPanelOffset() {
        workspaceState.floatingPanelOffset = PadFloatingPanelLayout.clampedOffset(
            proposedOffset: workspaceState.floatingPanelOffset,
            panelOrigin: Self.floatingPanelDefaultOrigin,
            panelSize: floatingPanelMeasuredSize,
            availableSize: availableSize,
            minimumVisibleEdge: Self.floatingPanelMinimumVisibleEdge
        )
    }

    // MARK: - Shared controls

    @ViewBuilder
    private var saveStatusIndicator: some View {
        switch editor.saveState {
        case .unchanged, .saved:
            Label(L10n.t("Saved"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .pending:
            Label(L10n.t("Unsaved"), systemImage: "clock")
                .foregroundStyle(.secondary)
        case .saving:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.t("Saving…"))
            }
            .foregroundStyle(.secondary)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(L10n.t("Save failed"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.t("Your RAW original was not changed."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var undoRedoControls: some View {
        HStack {
            Button {
                editor.undo()
            } label: {
                Label(L10n.t("Undo"), systemImage: "arrow.uturn.backward")
            }
            .disabled(!editor.canUndo)
            .accessibilityLabel(Text(L10n.t("Undo")))

            Button {
                editor.redo()
            } label: {
                Label(L10n.t("Redo"), systemImage: "arrow.uturn.forward")
            }
            .disabled(!editor.canRedo)
            .accessibilityLabel(Text(L10n.t("Redo")))

            Spacer()
        }
    }

    private func alertBody(_ alert: EditorAlert) -> String {
        [alert.message, alert.nextStep].compactMap { $0 }.joined(separator: "\n\n")
    }
}

/// Carries the floating panel's own measured size out of
/// `PadEditorView.floatingPanelSizeReader`'s background `GeometryReader`.
private struct FloatingPanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

// MARK: - PadToolRail (inlined for xcodeproj fixed source list)

/// A five-item tool rail that exposes every `PadInspectorDomain` as a tappable
/// button. Axis-agnostic: `.vertical` for the leading-edge rail in work mode,
/// `.horizontal` for a compact domain bar. Carries no local state.
private struct PadToolRail: View {
    @Binding var selection: PadInspectorDomain
    var axis: Axis = .vertical

    private struct RailItem: Identifiable {
        let id: PadInspectorDomain
        let symbol: String
        let labelKey: String
    }

    private static let items: [RailItem] = [
        RailItem(id: .adjust,   symbol: "slider.horizontal.3", labelKey: "Adjustments"),
        RailItem(id: .preset,   symbol: "sparkles",            labelKey: "Presets"),
        RailItem(id: .geometry, symbol: "crop.rotate",         labelKey: "Geometry"),
        RailItem(id: .local,    symbol: "paintbrush.pointed",  labelKey: "Local Adjustments"),
        RailItem(id: .info,     symbol: "info.circle",         labelKey: "Info"),
    ]

    var body: some View {
        Group {
            if axis == .vertical {
                VStack(spacing: 0) {
                    ForEach(Self.items) { item in railButton(item) }
                    Spacer()
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(Self.items) { item in railButton(item) }
                }
            }
        }
        .padding(axis == .vertical ? .vertical : .horizontal, 8)
        // Keep the rendered rail, including its horizontal padding, inside
        // the 88pt budget used by PadEditorLayoutPolicy.
        .frame(width: axis == .vertical ? 88 : nil)
        .background(.thickMaterial)
    }

    private func railButton(_ item: RailItem) -> some View {
        let isSelected = selection == item.id
        return Button {
            selection = item.id
        } label: {
            VStack(spacing: 2) {
                Image(systemName: item.symbol)
                    .imageScale(.small)
                Text(L10n.t(item.labelKey))
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }
            .frame(minWidth: 64, minHeight: 44)
            // Keep the whole stable rail cell tappable, including the
            // wrapped-label area in portrait and Split View layouts.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(axis == .vertical ? .horizontal : .vertical, 4)
        .accessibilityLabel(Text(L10n.t(item.labelKey)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - PadInspectorHost (inlined for xcodeproj fixed source list)

/// Routes the inspector panel to the correct content for the active domain.
/// The Adjust and Preset domains are fully wired. Never holds a second copy
/// of `PhotoAdjustments`.
///
/// `showsDomainBar`: pass `true` for bottom-drawer / floating-panel
/// presentations where the vertical `PadToolRail` is absent.
private struct PadInspectorHost: View {
    @ObservedObject var inspector: PadInspectorCoordinator
    @ObservedObject var navigation: InspectorNavigationModel
    @ObservedObject var editor: EditorSession
    @ObservedObject var presetLibrary: PadPresetLibrary
    @ObservedObject var library: PadLibraryModel
    @ObservedObject var batchCoordinator: PadBatchAdjustmentCoordinator
    let showsDomainBar: Bool
    // Adjustments starts with only Basic open. Dedicated Geometry and Local
    // pages are already inside their own first-level host, so they open with
    // their page content available on first visit rather than showing a
    // seemingly empty inspector until the user taps the title.
    @State private var expandedSections = InspectorSectionExpansionPolicy.initialExpanded
        .union([.geometry, .local])

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDomainBar {
                compactDomainBar
                Divider()
            }
            if showsCatalogNavigation {
                catalogToolbar
                Divider()
            }
            if showsCatalogNavigation,
               !navigation.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResultsList
            } else {
                switch inspector.activeDomain {
                case .adjust:
                    adjustPanel
                case .preset:
                    PadPresetPanel(editor: editor, presetLibrary: presetLibrary)
                case .geometry:
                    ScrollView {
                        domainSection(
                            .geometry,
                            titleKey: "Geometry"
                        ) {
                            GeometryAdjustmentPanel(editor: editor)
                        }
                        .padding()
                    }
                case .local:
                    ScrollView {
                        domainSection(
                            .local,
                            titleKey: "Local Adjustments"
                        ) {
                            LocalAdjustmentsPanel(editor: editor)
                        }
                        .padding()
                    }
                case .info:
                    infoPanel
                }
            }
        }
        .onChange(of: inspector.activeDomain) { _, _ in
            // A domain switch is an explicit navigation action. Do not leave
            // an old catalog query intercepting the newly selected page; the
            // Preset page owns its own search field and Info has none.
            navigation.clearSearch()
        }
    }

    /// The shared catalog only describes editable adjustment domains. Presets
    /// and Info have their own page-specific controls and must not inherit a
    /// misleading "Search Adjustments" field or catalog result list.
    private var showsCatalogNavigation: Bool {
        switch inspector.activeDomain {
        case .adjust, .geometry, .local:
            return true
        case .preset, .info:
            return false
        }
    }

    /// Geometry and Local are dedicated domains on iPad, but their content
    /// still needs the same Level 1 hierarchy as an Adjustments page. Without
    /// this host the panels' Level 2 groups render at the page root, so their
    /// chevrons, titles, and 16pt inset lose the cross-platform relationship.
    @ViewBuilder
    private func domainSection<Content: View>(
        _ sectionID: InspectorSectionID,
        titleKey: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let summary = InspectorGroupSummary.summary(for: sectionID, in: editor.adjustments)
        InspectorLevel1DisclosureGroup(
            L10n.t(titleKey),
            summary: summary.localizedText,
            isExpanded: Binding(
                get: { expandedSections.contains(sectionID) },
                set: { isExpanded in
                    expandedSections = isExpanded
                        ? expandedSections.union([sectionID])
                        : expandedSections.subtracting([sectionID])
                }
            ),
            content: content
        )
    }

    // MARK: - Shared catalog toolbar (search, favorite, pin, reset)

    /// P2: the same search/favorite/pin/reset affordances Mac's
    /// `InspectorView` exposes, all driven by the shared `InspectorCatalog`/
    /// `InspectorNavigationModel` -- no iPad-only reimplementation.
    /// `currentSectionID`/`currentResetDomain` are `nil` for the Preset and
    /// Info domains, which are not part of the field catalog: favorite/reset
    /// simply hide rather than show a control with nothing to act on.
    private var catalogToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                catalogSearchField
                Spacer(minLength: 4)
                catalogToolbarActions
            }

            VStack(alignment: .leading, spacing: 4) {
                catalogSearchField
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Spacer(minLength: 0)
                    catalogToolbarActions
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var catalogSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.t("Search Adjustments"), text: $navigation.searchQuery)
                .textFieldStyle(.plain)
            if !navigation.searchQuery.isEmpty {
                Button {
                    navigation.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(Text(L10n.t("Clear Search")))
            }
        }
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var catalogToolbarActions: some View {
        if let sectionID = currentSectionID {
            Button {
                navigation.toggleFavorite(sectionID)
            } label: {
                Image(systemName: navigation.isFavorite(sectionID) ? "star.fill" : "star")
                    .foregroundStyle(navigation.isFavorite(sectionID) ? .yellow : .secondary)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text(navigation.isFavorite(sectionID) ? L10n.t("Remove from Favorites") : L10n.t("Add to Favorites")))
        }
        Button {
            navigation.togglePin()
        } label: {
            Image(systemName: navigation.isPinned ? "pin.fill" : "pin")
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(Text(navigation.isPinned ? L10n.t("Unpin Section") : L10n.t("Pin Section")))
        .accessibilityAddTraits(navigation.isPinned ? .isSelected : [])
        if let domain = currentResetDomain {
            Button {
                editor.updateAdjustments { adjustments in
                    adjustments = InspectorCatalog.resetting(domain: domain, in: adjustments)
                }
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .frame(minWidth: 44, minHeight: 44)
            .disabled(editor.photo == nil || InspectorCatalog.isNeutral(domain: domain, in: editor.adjustments))
            .accessibilityLabel(Text(L10n.t("Reset")))
        }
    }

    /// A representative catalog section for the currently active
    /// domain/submode, used only for the favorite star (reset uses the whole
    /// domain, not one section). `nil` for Preset/Info, which the shared
    /// catalog does not cover.
    private var currentSectionID: InspectorSectionID? {
        switch inspector.activeDomain {
        case .adjust:
            switch inspector.adjustSubmode {
            case .light: return .basic
            case .color: return .whiteBalance
            case .detail: return .detail
            }
        case .geometry: return .geometry
        case .local: return .local
        case .preset, .info: return nil
        }
    }

    private var currentResetDomain: PadInspectorDomain? {
        switch inspector.activeDomain {
        case .adjust, .geometry, .local: return inspector.activeDomain
        case .preset, .info: return nil
        }
    }

    private var searchResultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                let results = navigation.searchResults
                if results.isEmpty {
                    Text(L10n.t("No matching tools"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(results) { section in
                        Button {
                            navigation.select(section.id)
                            navigation.clearSearch()
                        } label: {
                            HStack {
                                Image(systemName: section.symbol)
                                Text(L10n.t(section.titleKey))
                                Spacer()
                                if navigation.isFavorite(section.id) {
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(.yellow)
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
    }

    // MARK: Compact domain bar

    private struct DomainBarItem: Identifiable {
        let id: PadInspectorDomain
        let symbol: String
        let labelKey: String
    }

    private static let domainBarItems: [DomainBarItem] = [
        DomainBarItem(id: .adjust,   symbol: "slider.horizontal.3", labelKey: "Adjustments"),
        DomainBarItem(id: .preset,   symbol: "sparkles",            labelKey: "Presets"),
        DomainBarItem(id: .geometry, symbol: "crop.rotate",         labelKey: "Geometry"),
        DomainBarItem(id: .local,    symbol: "paintbrush.pointed",  labelKey: "Local Adjustments"),
        DomainBarItem(id: .info,     symbol: "info.circle",         labelKey: "Info"),
    ]

    private var compactDomainBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Self.domainBarItems) { item in
                    let isSelected = inspector.activeDomain == item.id
                    Button {
                        inspector.selectDomain(item.id)
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: item.symbol)
                                .imageScale(.small)
                            Text(L10n.t(item.labelKey))
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.center)
                        }
                        .frame(minWidth: 88, minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .background(
                        isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .accessibilityLabel(Text(L10n.t(item.labelKey)))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: Adjust domain

    @ViewBuilder
    private var adjustPanel: some View {
        adjustSubmodePicker
            .padding(.horizontal)
            .padding(.vertical, 8)
        Divider()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                adjustContent
            }
            .padding()
        }
    }

    private var adjustSubmodePicker: some View {
        ViewThatFits(in: .horizontal) {
            submodePicker
            submodeMenu
        }
        .accessibilityLabel(Text(L10n.t("Adjust submode")))
    }

    private var submodePicker: some View {
        Picker(L10n.t("Adjustments"), selection: Binding(
            get: { inspector.adjustSubmode },
            set: { inspector.selectAdjustSubmode($0) }
        )) {
            Text(L10n.t("Light")).tag(PadAdjustSubmode.light)
            Text(L10n.t("Color")).tag(PadAdjustSubmode.color)
            Text(L10n.t("Detail")).tag(PadAdjustSubmode.detail)
        }
        .pickerStyle(.segmented)
        .frame(minHeight: 44)
    }

    private var submodeMenu: some View {
        Picker(L10n.t("Adjustments"), selection: Binding(
            get: { inspector.adjustSubmode },
            set: { inspector.selectAdjustSubmode($0) }
        )) {
            Text(L10n.t("Light")).tag(PadAdjustSubmode.light)
            Text(L10n.t("Color")).tag(PadAdjustSubmode.color)
            Text(L10n.t("Detail")).tag(PadAdjustSubmode.detail)
        }
        .pickerStyle(.menu)
        .frame(minHeight: 44, alignment: .leading)
    }

    /// P2 (`2026-09-10-shared-professional-inspector-catalog.md` §2): field
    /// vocabulary for every submode comes from `InspectorCatalog`, the same
    /// declaration point Mac's `InspectorView` reads. The `.color` case now
    /// also mounts the White Balance panel -- previously
    /// `PadAdjustSubmodeKinds.color` declared `basic.temperature`/
    /// `basic.tint` in its vocabulary but no panel ever rendered them; this
    /// closes that gap and brings iPad to parity with Mac's `.color`
    /// `DisclosureGroup` (White Balance + HSL together).
    @ViewBuilder
    private var adjustContent: some View {
        switch inspector.adjustSubmode {
        case .light:
            adjustmentSection(.basic, titleKey: "Basic") {
                RenderingProfilePanel(editor: editor)
                BasicAdjustmentPanel(editor: editor, kinds: InspectorCatalog.section(.basic).adjustmentKinds)
            }
            adjustmentSection(.presence, titleKey: "Presence") {
                PresenceAdjustmentPanel(editor: editor)
            }
            adjustmentSection(.curve, titleKey: "Curve") {
                CurveAdjustmentPanel(editor: editor)
            }
        case .color:
            adjustmentSection(.hsl, titleKey: "Color", summarySections: [.whiteBalance, .hsl]) {
                Level2Section(L10n.t("White Balance")) {
                    BasicAdjustmentPanel(editor: editor, kinds: InspectorCatalog.section(.whiteBalance).adjustmentKinds)
                }
                ColorAdjustmentPanel(editor: editor)
            }
            adjustmentSection(.colorGrading, titleKey: "Color Grading") {
                ColorGradingAdjustmentPanel(editor: editor)
            }
        case .detail:
            adjustmentSection(.detail, titleKey: "Detail") {
                DetailAdjustmentPanel(editor: editor)
            }
            adjustmentSection(.effects, titleKey: "Effects") {
                EffectsAdjustmentPanel(editor: editor)
            }
        }
    }

    @ViewBuilder
    private func adjustmentSection<Content: View>(
        _ sectionID: InspectorSectionID,
        titleKey: String,
        summarySections: [InspectorSectionID]? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let ids = summarySections ?? [sectionID]
        let adjustedCount = ids.reduce(0) { partial, id in
            switch InspectorGroupSummary.summary(for: id, in: editor.adjustments) {
            case .notAdjusted:
                return partial
            case .adjusted(let count):
                return partial + count
            }
        }
        let summary: InspectorGroupSummary = adjustedCount == 0 ? .notAdjusted : .adjusted(count: adjustedCount)
        InspectorLevel1DisclosureGroup(
            L10n.t(titleKey),
            summary: summary.localizedText,
            isExpanded: Binding(
                get: { expandedSections.contains(sectionID) },
                set: { isExpanded in
                    expandedSections = isExpanded
                        ? expandedSections.union([sectionID])
                        : expandedSections.subtracting([sectionID])
                }
            ),
            content: content
        )
    }

    // MARK: Info domain

    @ViewBuilder
    private var infoPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PadHistogramBlock(histogram: editor.histogram)
                Divider()
                if let photo = editor.photo {
                    let curationPhoto = library.photos.first(where: { $0.id == photo.id }) ?? photo
                    PadMetadataBlock(
                        snapshot: EditorMetadataSnapshot(photo: curationPhoto),
                        photo: curationPhoto,
                        batchCoordinator: batchCoordinator
                    )
                } else {
                    Text(L10n.t("Photo not yet loaded."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }
                Divider()
                PadSaveStateBlock(saveState: editor.saveState)
                Divider()
                if editor.photo != nil {
                    SnapshotsPanel(editor: editor)
                }
            }
            .padding()
        }
    }

    // MARK: Unavailable placeholder

    private func unavailablePlaceholder(domain: String, symbol: String, note: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: symbol)
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Text(domain)
                .font(.headline)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(domain): \(note)"))
    }
}

// MARK: - Info panel helpers

/// RGB histogram block for the Info domain. Renders the current rendered-preview
/// histogram; shows a localized fallback while histogram is nil (still computing).
private struct PadHistogramBlock: View {
    let histogram: HistogramData?

    var body: some View {
        HistogramPanel(histogram: histogram)
    }
}

/// Displays the current EditorSession save state in the Info domain.
private struct PadSaveStateBlock: View {
    let saveState: SaveState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("Save State"))
                .font(.subheadline.weight(.semibold))
            switch saveState {
            case .unchanged, .saved:
                Label(L10n.t("Saved"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            case .pending:
                Label(L10n.t("Unsaved changes"), systemImage: "clock")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            case .saving:
                Label(L10n.t("Saving…"), systemImage: "arrow.clockwise")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            case .failed(let message):
                Label(L10n.t("Save failed"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Displays safe EditorMetadataSnapshot fields (no path, bookmark, or signing info).
private struct PadMetadataBlock: View {
    let snapshot: EditorMetadataSnapshot
    let photo: PhotoAsset
    @ObservedObject var batchCoordinator: PadBatchAdjustmentCoordinator

    @State private var keywordText: String
    @State private var isSavingKeywords = false
    @State private var message: String?

    init(
        snapshot: EditorMetadataSnapshot,
        photo: PhotoAsset,
        batchCoordinator: PadBatchAdjustmentCoordinator
    ) {
        self.snapshot = snapshot
        self.photo = photo
        self.batchCoordinator = batchCoordinator
        _keywordText = State(initialValue: photo.keywords.map(\.displayValue).joined(separator: ", "))
    }

    private struct Row: View {
        let label: String
        let value: String

        var body: some View {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    labelView
                        .frame(width: 96, alignment: .leading)
                    valueView
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 2) {
                    labelView
                    valueView
                }
            }
        }

        private var labelView: some View {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        private var valueView: some View {
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("File Info"))
                .font(.subheadline.weight(.semibold))
            Row(label: L10n.t("Filename"), value: snapshot.filename)
            Row(label: L10n.t("Format"), value: snapshot.formatDescription)
            if let v = snapshot.pixelDimensions   { Row(label: L10n.t("Dimensions"),   value: v) }
            if let v = snapshot.fileSizeDescription { Row(label: L10n.t("File Size"),   value: v) }
            if let v = snapshot.cameraDescription  { Row(label: L10n.t("Camera"),       value: v) }
            if let v = snapshot.lensDescription    { Row(label: L10n.t("Lens"),         value: v) }
            if let v = snapshot.focalLengthDescription { Row(label: L10n.t("Focal Length"), value: v) }
            if let v = snapshot.apertureDescription  { Row(label: L10n.t("Aperture"),   value: v) }
            if let v = snapshot.shutterSpeedDescription { Row(label: L10n.t("Shutter"), value: v) }
            if let v = snapshot.isoDescription       { Row(label: L10n.t("ISO"),        value: v) }
            if let v = snapshot.captureDateDescription { Row(label: L10n.t("Date"),     value: v) }
            if let v = snapshot.orientationDescription { Row(label: L10n.t("Orientation"), value: v) }

            Divider()
            Text(L10n.t("Curation"))
                .font(.subheadline.weight(.semibold))
            ratingControls
            flagControl
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Keywords"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                keywordEditor
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: photo.id) { _, _ in
            keywordText = photo.keywords.map(\.displayValue).joined(separator: ", ")
        }
    }

    private var keywordEditor: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                keywordField
                saveKeywordsButton
            }

            VStack(alignment: .leading, spacing: 6) {
                keywordField
                HStack {
                    Spacer(minLength: 0)
                    saveKeywordsButton
                }
            }
        }
    }

    private var keywordField: some View {
        TextField(L10n.t("Keyword"), text: $keywordText)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
    }

    private var saveKeywordsButton: some View {
        Button {
            saveKeywords()
        } label: {
            if isSavingKeywords {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark")
            }
        }
        .buttonStyle(.borderedProminent)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(isSavingKeywords)
        .accessibilityLabel(Text(L10n.t("Save Keywords")))
    }

    private var ratingControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                ratingLabel
                    .frame(width: 96, alignment: .leading)
                ratingButtons
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                ratingLabel
                ratingButtons
            }
        }
    }

    private var ratingLabel: some View {
        Text(L10n.t("Rating"))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var ratingButtons: some View {
        HStack(spacing: 0) {
            ForEach(0...5, id: \.self) { value in
                Button {
                    Task {
                        let succeeded = await batchCoordinator.setRating(value, for: photo.id)
                        if !succeeded { message = L10n.t("Couldn't save rating") }
                    }
                } label: {
                    Image(systemName: value == 0 ? "xmark.circle" : "star.fill")
                        .foregroundStyle(value > photo.rating ? Color.secondary : Color.yellow)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(Text("\(L10n.t("Rating")) \(value)"))
            }
        }
    }

    private var flagControl: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                flagLabel
                    .frame(width: 96, alignment: .leading)
                flagMenu
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                flagLabel
                flagMenu
            }
        }
    }

    private var flagLabel: some View {
        Text(L10n.t("Flag"))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var flagMenu: some View {
        Menu {
            ForEach(PhotoFlag.allCases, id: \.self) { flag in
                Button {
                    Task {
                        let succeeded = await batchCoordinator.setFlag(flag, for: photo.id)
                        if !succeeded { message = L10n.t("Couldn't save flag") }
                    }
                } label: {
                    Label(flagTitle(flag), systemImage: photo.flag == flag ? "checkmark" : "")
                }
            }
        } label: {
            Label(flagTitle(photo.flag), systemImage: flagSymbol(photo.flag))
        }
        .frame(minWidth: 44, minHeight: 44)
    }

    private func saveKeywords() {
        isSavingKeywords = true
        let inputs = keywordText
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        Task {
            let succeeded = await batchCoordinator.setKeywords(inputs, for: photo.id)
            isSavingKeywords = false
            if !succeeded {
                message = L10n.t("Couldn't save keywords")
            } else {
                message = nil
                keywordText = inputs.joined(separator: ", ")
            }
        }
    }

    private func flagTitle(_ flag: PhotoFlag) -> String {
        switch flag {
        case .none: return L10n.t("None")
        case .pick: return L10n.t("Pick")
        case .reject: return L10n.t("Reject")
        }
    }

    private func flagSymbol(_ flag: PhotoFlag) -> String {
        switch flag {
        case .none: return "flag"
        case .pick: return "flag.fill"
        case .reject: return "flag.slash"
        }
    }
}

// MARK: - Preset panel

/// The full Preset inspector: search, scope filter, apply-mode control, and
/// a scrollable list where a single tap previews and an explicit Apply button
/// commits via `editor.commitPreset(_:mode:)` — one undo step per apply.
///
/// Never holds a second copy of `PhotoAdjustments`. Preview is cancelled
/// automatically when the panel disappears so no stale preset render lingers.
struct PadPresetPanel: View {
    @ObservedObject var editor: EditorSession
    @ObservedObject var presetLibrary: PadPresetLibrary

    @State private var applicationMode: PresetApplicationMode = .merge
    @State private var previewingPresetID: UUID?
    @State private var isCreatingPreset = false
    @State private var editingPreset: PresetDocument?
    @State private var isImportingFiles = false
    @State private var isRestoringBackup = false
    @State private var isExportingFile = false
    @State private var exportDocument: PadPresetDataFileDocument?
    @State private var exportFilename = "preset.lhpreset"

    var body: some View {
        VStack(spacing: 0) {
            presetActionBar
            Divider()
            searchBar
            Divider()
            scopePicker
            Divider()
            applyModePicker
            Divider()
            presetList
        }
        .task { await presetLibrary.load() }
        .onDisappear {
            if previewingPresetID != nil {
                editor.cancelPresetPreview()
                previewingPresetID = nil
            }
        }
        .sheet(isPresented: $isCreatingPreset) {
            NavigationStack {
                PadPresetCreateSheet(
                    adjustments: editor.adjustments,
                    presetLibrary: presetLibrary
                ) {
                    isCreatingPreset = false
                }
            }
        }
        .sheet(item: $editingPreset) { preset in
            NavigationStack {
                PadPresetEditSheet(preset: preset, presetLibrary: presetLibrary) {
                    editingPreset = nil
                }
            }
        }
        .fileImporter(
            isPresented: $isImportingFiles,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task { await presetLibrary.importFiles(urls) }
        }
        .fileImporter(
            isPresented: $isRestoringBackup,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                guard let data = presetLibrary.readData(from: url) else {
                    presetLibrary.message = L10n.t("This backup could not be read.")
                    return
                }
                await presetLibrary.restoreBackup(data)
            }
        }
        .fileExporter(
            isPresented: $isExportingFile,
            document: exportDocument,
            contentType: .data,
            defaultFilename: exportFilename
        ) { result in
            if case .failure = result {
                presetLibrary.message = L10n.t("The preset file could not be saved.")
            }
            exportDocument = nil
        }
        .alert(
            L10n.t("Preset"),
            isPresented: Binding(
                get: { presetLibrary.message != nil },
                set: { if !$0 { presetLibrary.message = nil } }
            )
        ) {
            Button(L10n.t("OK"), role: .cancel) { presetLibrary.message = nil }
        } message: {
            Text(presetLibrary.message ?? "")
        }
    }

    /// Keeps Preset actions attached to the page instead of relying on the
    /// editor's root NavigationStack toolbar, whose many document actions can
    /// collapse page-specific controls into an overflow menu on iPad.
    private var presetActionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                favoritesButton
                createPresetButton
                presetActionsMenu
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    favoritesButton
                    createPresetButton
                    presetActionsMenu
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private var favoritesButton: some View {
        Button {
            presetLibrary.favoritesOnly.toggle()
        } label: {
            Image(systemName: presetLibrary.favoritesOnly ? "star.fill" : "star")
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel(Text(L10n.t("Favorites only")))
        .accessibilityAddTraits(presetLibrary.favoritesOnly ? .isSelected : [])
    }

    private var createPresetButton: some View {
        Button {
            isCreatingPreset = true
        } label: {
            Image(systemName: "plus")
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel(Text(L10n.t("Create preset")))
    }

    private var presetActionsMenu: some View {
        Menu {
            Button {
                isImportingFiles = true
            } label: {
                Label(L10n.t("Import preset files"), systemImage: "square.and.arrow.down")
            }
            Button {
                isRestoringBackup = true
            } label: {
                Label(L10n.t("Restore backup"), systemImage: "arrow.counterclockwise")
            }
            Button {
                exportBackup()
            } label: {
                Label(L10n.t("Export backup"), systemImage: "archivebox")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel(Text(L10n.t("Preset actions")))
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L10n.t("Search Presets"), text: $presetLibrary.searchQuery)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
        }
        .padding(.horizontal)
        .frame(height: 44)
        .accessibilityLabel(Text(L10n.t("Search Presets")))
    }

    private var scopePicker: some View {
        ViewThatFits(in: .horizontal) {
            Picker(L10n.t("Scope"), selection: $presetLibrary.scope) {
                ForEach(PadPresetScope.allCases) { scope in
                    Text(L10n.t(scope.rawValue)).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)

            Picker(L10n.t("Scope"), selection: $presetLibrary.scope) {
                ForEach(PadPresetScope.allCases) { scope in
                    Text(L10n.t(scope.rawValue)).tag(scope)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .accessibilityLabel(Text(L10n.t("Preset scope")))
    }

    private var applyModePicker: some View {
        ViewThatFits(in: .horizontal) {
            Picker(L10n.t("Apply Mode"), selection: $applicationMode) {
                Text(L10n.t("Merge")).tag(PresetApplicationMode.merge)
                Text(L10n.t("Replace")).tag(PresetApplicationMode.replace)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)

            Picker(L10n.t("Apply Mode"), selection: $applicationMode) {
                Text(L10n.t("Merge")).tag(PresetApplicationMode.merge)
                Text(L10n.t("Replace")).tag(PresetApplicationMode.replace)
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .accessibilityLabel(Text(L10n.t("Apply mode")))
    }

    @ViewBuilder
    private var presetList: some View {
        if presetLibrary.isLoading {
            Spacer()
            ProgressView()
                .frame(maxWidth: .infinity)
            Spacer()
        } else if presetLibrary.filteredPresets.isEmpty {
            Spacer()
            Text(presetLibrary.searchQuery.isEmpty
                 ? L10n.t("No presets.")
                 : L10n.t("No results."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(presetLibrary.filteredPresets) { preset in
                        presetRow(preset)
                        Divider()
                    }
                }
            }
        }
    }

    private func presetRow(_ preset: PresetDocument) -> some View {
        let isPreviewing = previewingPresetID == preset.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                presetSummary(preset)
                Spacer(minLength: 8)
                favoriteButton(for: preset)
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    Spacer(minLength: 0)
                    presetApplyButton(preset, isPreviewing: isPreviewing)
                    presetActionsMenu(for: preset)
                }

                VStack(alignment: .leading, spacing: 4) {
                    presetApplyButton(preset, isPreviewing: isPreviewing)
                    presetActionsMenu(for: preset)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(minHeight: 76)
        .background(
            isPreviewing ? Color.accentColor.opacity(0.10) : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isPreviewing {
                // Second tap on the same row commits, identical to the Apply button.
                editor.commitPreset(preset, mode: applicationMode)
                previewingPresetID = nil
            } else {
                if previewingPresetID != nil {
                    editor.cancelPresetPreview()
                }
                previewingPresetID = preset.id
                editor.previewPreset(preset, mode: applicationMode)
            }
        }
        .accessibilityLabel(Text(preset.name))
        .accessibilityHint(Text(isPreviewing
            ? L10n.t("Previewing. Tap again or use Apply button to commit.")
            : L10n.t("Tap to preview this preset.")))
        .accessibilityAddTraits(isPreviewing ? .isSelected : [])
    }

    private func presetSummary(_ preset: PresetDocument) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(preset.name)
                .font(.body)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            if !preset.groupPath.isEmpty {
                Text(preset.groupPath.joined(separator: " › "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if presetLibrary.isBuiltIn(preset) {
                Text(L10n.t("Built-In"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func favoriteButton(for preset: PresetDocument) -> some View {
        Button {
            Task { await presetLibrary.toggleFavorite(preset) }
        } label: {
            Image(systemName: preset.isFavorite ? "star.fill" : "star")
                .foregroundStyle(preset.isFavorite ? .yellow : .secondary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(presetLibrary.isBuiltIn(preset))
        .accessibilityLabel(Text(preset.isFavorite ? L10n.t("Remove favorite") : L10n.t("Add favorite")))
    }

    @ViewBuilder
    private func presetApplyButton(_ preset: PresetDocument, isPreviewing: Bool) -> some View {
        if isPreviewing {
            Button(L10n.t("Apply")) {
                editor.commitPreset(preset, mode: applicationMode)
                previewingPresetID = nil
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .frame(minHeight: 44)
            .accessibilityLabel(Text(L10n.t("Apply") + " " + preset.name))
        }
    }

    private func presetActionsMenu(for preset: PresetDocument) -> some View {
        Menu {
            if !presetLibrary.isBuiltIn(preset) {
                Button {
                    editingPreset = preset
                } label: {
                    Label(L10n.t("Edit preset"), systemImage: "pencil")
                }
                Button(role: .destructive) {
                    Task { await presetLibrary.delete(preset) }
                } label: {
                    Label(L10n.t("Delete preset"), systemImage: "trash")
                }
            }
            Button {
                exportPreset(preset, as: .native)
            } label: {
                Label(L10n.t("Export .lhpreset"), systemImage: "square.and.arrow.up")
            }
            Button {
                exportPreset(preset, as: .xmp)
            } label: {
                Label(L10n.t("Export XMP"), systemImage: "doc.text")
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
        }
        .menuOrder(.fixed)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(Text(L10n.t("Preset actions")))
    }

    private enum ExportKind { case native, xmp }

    private func exportPreset(_ preset: PresetDocument, as kind: ExportKind) {
        do {
            let data: Data
            switch kind {
            case .native:
                data = try presetLibrary.exportNative(preset)
                exportFilename = "\(preset.name).lhpreset"
            case .xmp:
                data = try presetLibrary.exportXMP(preset)
                exportFilename = "\(preset.name).xmp"
            }
            exportDocument = PadPresetDataFileDocument(data: data)
            isExportingFile = true
        } catch {
            presetLibrary.message = L10n.t("This preset could not be exported.")
        }
    }

    private func exportBackup() {
        Task {
            do {
                let data = try await presetLibrary.exportBackup()
                exportFilename = "LumaHarbor-Presets.lhpresetbackup"
                exportDocument = PadPresetDataFileDocument(data: data)
                isExportingFile = true
            } catch {
                presetLibrary.message = L10n.t("The preset backup could not be created.")
            }
        }
    }
}

/// Data-only FileDocument used by the iPad Files picker for native presets,
/// XMP and backup archives. The file extension is supplied by the caller; the
/// payload is never re-encoded by the picker.
private struct PadPresetDataFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.data] }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct PadPresetCreateSheet: View {
    let adjustments: PhotoAdjustments
    @ObservedObject var presetLibrary: PadPresetLibrary
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var groupPath = ""
    @State private var isFavorite = false
    @State private var selectedFields: Set<AdjustmentFieldID>
    @State private var isSaving = false

    init(adjustments: PhotoAdjustments, presetLibrary: PadPresetLibrary, onDismiss: @escaping () -> Void) {
        self.adjustments = adjustments
        self.presetLibrary = presetLibrary
        self.onDismiss = onDismiss
        _selectedFields = State(initialValue: AdjustmentPatch.modifiedFields(in: adjustments))
    }

    var body: some View {
        Form {
            Section(L10n.t("Preset details")) {
                TextField(L10n.t("Name"), text: $name)
                TextField(L10n.t("Group (optional)"), text: $groupPath)
                Toggle(L10n.t("Favorite"), isOn: $isFavorite)
            }
            PadPresetFieldSelection(selectedFields: $selectedFields)
        }
        .navigationTitle(L10n.t("Create preset"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.t("Cancel")) { dismissSheet() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.t("Save")) { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            let saved = await presetLibrary.createPreset(
                name: name,
                groupPath: groupPath.isEmpty ? [] : [groupPath],
                isFavorite: isFavorite,
                selectedFields: selectedFields,
                from: adjustments
            )
            isSaving = false
            if saved { dismissSheet() }
        }
    }

    private func dismissSheet() {
        onDismiss()
        dismiss()
    }
}

private struct PadPresetEditSheet: View {
    let preset: PresetDocument
    @ObservedObject var presetLibrary: PadPresetLibrary
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var groupPath: String
    @State private var isFavorite: Bool
    @State private var selectedFields: Set<AdjustmentFieldID>
    @State private var isSaving = false

    init(preset: PresetDocument, presetLibrary: PadPresetLibrary, onDismiss: @escaping () -> Void) {
        self.preset = preset
        self.presetLibrary = presetLibrary
        self.onDismiss = onDismiss
        _name = State(initialValue: preset.name)
        _groupPath = State(initialValue: preset.groupPath.joined(separator: " / "))
        _isFavorite = State(initialValue: preset.isFavorite)
        _selectedFields = State(initialValue: Set(AdjustmentFieldID.allCases.filter { preset.patch.contains($0) }))
    }

    var body: some View {
        Form {
            Section(L10n.t("Preset details")) {
                TextField(L10n.t("Name"), text: $name)
                TextField(L10n.t("Group (optional)"), text: $groupPath)
                Toggle(L10n.t("Favorite"), isOn: $isFavorite)
            }
            PadPresetFieldSelection(selectedFields: $selectedFields)
        }
        .navigationTitle(L10n.t("Edit preset"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.t("Cancel")) { dismissSheet() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.t("Save")) { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            let saved = await presetLibrary.updatePreset(
                preset,
                name: name,
                groupPath: groupPath.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) },
                isFavorite: isFavorite,
                keptFields: selectedFields
            )
            isSaving = false
            if saved { dismissSheet() }
        }
    }

    private func dismissSheet() {
        onDismiss()
        dismiss()
    }
}

private struct PadPresetFieldSelection: View {
    @Binding var selectedFields: Set<AdjustmentFieldID>

    var body: some View {
        Section(L10n.t("Included adjustments")) {
            ForEach(AdjustmentFieldID.allCases, id: \.self) { field in
                Toggle(isOn: binding(for: field)) {
                    Text(L10n.t(field.rawValue))
                }
            }
        }
    }

    private func binding(for field: AdjustmentFieldID) -> Binding<Bool> {
        Binding(
            get: { selectedFields.contains(field) },
            set: { included in
                if included { selectedFields.insert(field) }
                else { selectedFields.remove(field) }
            }
        )
    }
}

private struct PadExportOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var options: PadExportOptions
    let onExport: () -> Void
    @State private var maximumDimensionText: String
    @State private var dpiText: String

    init(options: Binding<PadExportOptions>, onExport: @escaping () -> Void) {
        self._options = options
        self.onExport = onExport
        self._maximumDimensionText = State(initialValue: options.wrappedValue.maximumDimension.map(String.init) ?? "")
        self._dpiText = State(initialValue: options.wrappedValue.dpi.map { String(Int($0)) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.t("Format")) {
                    Picker(L10n.t("Format"), selection: $options.format) {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }

                    if options.format.usesQuality {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(L10n.t("Quality"))
                                Spacer()
                                Text("\(Int(options.qualityPercentage.rounded()))%")
                                    .monospacedDigit()
                            }
                            Slider(value: $options.quality, in: 0...1, step: 0.01)
                        }
                    }

                    if options.format.supportsBitDepthChoice {
                        Picker(L10n.t("Bit Depth"), selection: $options.bitDepth) {
                            ForEach(ExportBitDepth.allCases, id: \.self) { depth in
                                Text(depth.displayName).tag(depth)
                            }
                        }
                    }
                }

                Section(L10n.t("Size")) {
                    TextField(L10n.t("Size"), text: $maximumDimensionText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Text(L10n.t("Leave blank to keep the full resolution."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(L10n.t("DPI")) {
                    TextField(L10n.t("DPI"), text: $dpiText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Text(L10n.t("Leave blank to use the encoder default."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(L10n.t("EXIF")) {
                    Picker(L10n.t("EXIF"), selection: $options.exifRetentionPolicy) {
                        ForEach(ExifRetentionPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                }

                Section(L10n.t("Collision")) {
                    Picker(L10n.t("Collision"), selection: $options.collisionPolicy) {
                        ForEach(ExportCollisionPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("Export"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Export")) {
                        commitOptionalFields()
                        onExport()
                    }
                }
            }
        }
    }

    private func commitOptionalFields() {
        let dimension = Int(maximumDimensionText.trimmingCharacters(in: .whitespacesAndNewlines))
        options.setMaximumDimension(dimension)
        let dpi = Double(dpiText.trimmingCharacters(in: .whitespacesAndNewlines))
        options.setDPI(dpi)
    }
}

/// Wraps an already-exported photo file so SwiftUI's `fileExporter` can
/// hand it to the system Files picker (spec §5.5.1's "Save to Files")
/// without this view re-encoding or re-deriving anything: the bytes were
/// already produced by `PhotoExporter` in `exportFullResolution()`, and
/// `fileWrapper(configuration:)` below just reads them back off disk.
private struct ExportedPhotoFileDocument: FileDocument {
    /// Never actually read back through this type -- `fileExporter` only
    /// writes -- but the protocol requires a non-empty answer for the
    /// picker to treat this as an exportable kind at all.
    static var readableContentTypes: [UTType] { [.jpeg, .heic, .png, .tiff] }
    static var writableContentTypes: [UTType] { [.jpeg, .heic, .png, .tiff] }

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: fileURL, options: .immediate)
    }
}

/// iPad's crop overlay uses the same normalized crop model as the Mac editor.
/// It is kept in this target because the iPad app intentionally does not
/// depend on the Mac-only `LumaHarborApp` target.
private struct PadCropOverlayView: View {
    @ObservedObject private var editor: EditorSession
    let imageFrame: CGRect

    /// The white corner dot stays visually small, but its transparent gesture
    /// surface must meet the iPad touch-target minimum so crop handles remain
    /// usable in portrait and Split View layouts.
    private static let handleHitAreaSize: CGFloat = 44

    @State private var dragBaseCrop: NormalizedCropRect?

    init(editor: EditorSession, imageFrame: CGRect) {
        self.editor = editor
        self.imageFrame = imageFrame
    }

    private var currentAdjustments: PhotoAdjustments {
        editor.adjustments
    }

    private var aspectRatio: Double? {
        switch currentAdjustments.geometry.cropAspectRatio {
        case .freeform: return nil
        case .original: return 1
        case .square: return imageFrame.height / imageFrame.width
        case .custom(let width, let height):
            guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
            return (width / height) * imageFrame.height / imageFrame.width
        }
    }

    private var crop: NormalizedCropRect {
        let base = currentAdjustments.geometry.crop ?? .full
        return aspectRatio.map { base.fitting(aspectRatio: $0) } ?? base
    }

    private var cropFrame: CGRect {
        CGRect(
            x: imageFrame.minX + crop.x * imageFrame.width,
            y: imageFrame.minY + crop.y * imageFrame.height,
            width: crop.width * imageFrame.width,
            height: crop.height * imageFrame.height
        )
    }

    var body: some View {
        ZStack {
            Path { path in
                path.addRect(imageFrame)
                path.addRect(cropFrame)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: cropFrame.width, height: cropFrame.height)
                .position(x: cropFrame.midX, y: cropFrame.midY)
                .allowsHitTesting(false)

            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: cropFrame.width, height: cropFrame.height)
                .position(x: cropFrame.midX, y: cropFrame.midY)
                .gesture(dragGesture(for: .move))

            ForEach(PadCropHandle.corners, id: \.self) { handle in
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(radius: 1)
                    .frame(width: Self.handleHitAreaSize, height: Self.handleHitAreaSize)
                    .contentShape(Circle())
                    .position(handlePosition(handle))
                    .gesture(dragGesture(for: handle))
                    .accessibilityLabel(Text(handle.accessibilityLabel))
            }
        }
    }

    private func handlePosition(_ handle: PadCropHandle) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: cropFrame.minX, y: cropFrame.minY)
        case .topRight: return CGPoint(x: cropFrame.maxX, y: cropFrame.minY)
        case .bottomLeft: return CGPoint(x: cropFrame.minX, y: cropFrame.maxY)
        case .bottomRight: return CGPoint(x: cropFrame.maxX, y: cropFrame.maxY)
        case .move: return CGPoint(x: cropFrame.midX, y: cropFrame.midY)
        }
    }

    private func dragGesture(for handle: PadCropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let base = dragBaseCrop ?? crop
                if dragBaseCrop == nil { dragBaseCrop = base }
                let updated = PadCropDragMath.updatedCrop(
                    base: base,
                    handle: handle,
                    translation: value.translation,
                    imageFrameSize: imageFrame.size,
                    normalizedAspectRatio: aspectRatio
                )
                editor.updateAdjustments { $0.geometry.crop = updated.isFull ? nil : updated }
            }
            .onEnded { _ in dragBaseCrop = nil }
    }
}

private enum PadCropHandle: Hashable {
    case topLeft, topRight, bottomLeft, bottomRight, move

    static let corners: [PadCropHandle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]

    var accessibilityLabel: String {
        switch self {
        case .topLeft: return "Crop top left"
        case .topRight: return "Crop top right"
        case .bottomLeft: return "Crop bottom left"
        case .bottomRight: return "Crop bottom right"
        case .move: return "Move crop"
        }
    }
}

private enum PadCropDragMath {
    static func updatedCrop(
        base: NormalizedCropRect,
        handle: PadCropHandle,
        translation: CGSize,
        imageFrameSize: CGSize,
        normalizedAspectRatio: Double?
    ) -> NormalizedCropRect {
        guard imageFrameSize.width > 0, imageFrameSize.height > 0 else { return base }
        let dx = Double(translation.width / imageFrameSize.width)
        let dy = Double(translation.height / imageFrameSize.height)
        guard let ratio = normalizedAspectRatio, ratio.isFinite, ratio > 0 else {
            switch handle {
            case .topLeft: return NormalizedCropRect(x: base.x + dx, y: base.y + dy, width: base.width - dx, height: base.height - dy)
            case .topRight: return NormalizedCropRect(x: base.x, y: base.y + dy, width: base.width + dx, height: base.height - dy)
            case .bottomLeft: return NormalizedCropRect(x: base.x + dx, y: base.y, width: base.width - dx, height: base.height + dy)
            case .bottomRight: return NormalizedCropRect(x: base.x, y: base.y, width: base.width + dx, height: base.height + dy)
            case .move: return NormalizedCropRect(x: base.x + dx, y: base.y + dy, width: base.width, height: base.height)
            }
        }
        if handle == .move {
            return NormalizedCropRect(x: base.x + dx, y: base.y + dy, width: base.width, height: base.height)
        }

        let left = handle == .topLeft || handle == .bottomLeft
        let top = handle == .topLeft || handle == .topRight
        let fixedX = left ? base.x + base.width : base.x
        let fixedY = top ? base.y + base.height : base.y
        let draggedX = left ? base.x + dx : base.x + base.width + dx
        let draggedY = top ? base.y + dy : base.y + base.height + dy
        let requestedWidth = max(abs(draggedX - fixedX), NormalizedCropRect.minimumDimension)
        let requestedHeight = max(abs(draggedY - fixedY), NormalizedCropRect.minimumDimension)
        let width = max(requestedWidth, requestedHeight * ratio)
        let maxWidth = min(left ? fixedX : 1 - fixedX, (top ? fixedY : 1 - fixedY) * ratio)
        let clampedWidth = min(max(width, NormalizedCropRect.minimumDimension), max(maxWidth, NormalizedCropRect.minimumDimension))
        let height = clampedWidth / ratio
        return NormalizedCropRect(
            x: left ? fixedX - clampedWidth : fixedX,
            y: top ? fixedY - height : fixedY,
            width: clampedWidth,
            height: height
        )
    }
}
