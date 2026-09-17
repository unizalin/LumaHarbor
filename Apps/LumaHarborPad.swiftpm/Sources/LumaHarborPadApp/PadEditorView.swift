import AdjustmentUI
import EditorCore
import Localization
import PhotoLibraryCore
import Photos
import PresetCore
import RawProcessingCore
import SwiftUI
import UniformTypeIdentifiers

/// The adaptive editing surface: one Inspector content hierarchy whose
/// container adapts to the available size. `PadEditorLayoutPolicy` decides
/// trailing dock vs. movable compact overlay purely from width/height; the
/// overlay's drag and minimize actions only change presentation state.
///
/// `editor` — and therefore the open photo, its adjustments, and its undo
/// stack — is the same `EditorSession` instance across every layout this
/// view ever renders; resizing, rotating, moving, or minimizing only changes
/// where the same controls render, never what document is open or what state
/// it holds.
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

    /// Document-scoped presentation preferences and floating-panel position.
    /// The Inspector never changes `workspaceMode`; the existing field stays
    /// in the shared state model for compatibility with other workspace
    /// consumers.
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
                .onAppear {
                    availableSize = proxy.size
                    reclampFloatingPanelOffset(for: proxy.size)
                }
                .onChange(of: proxy.size) { _, newSize in
                    availableSize = newSize
                    reclampFloatingPanelOffset(for: newSize)
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
                inspectorPresentationButton
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

    private func minimizeInspector() {
        isInspectorMinimized = true
    }

    private func restoreInspector() {
        isInspectorMinimized = false
        reclampFloatingPanelOffset(for: availableSize)
    }

    /// The toolbar action selects the Adjustments domain and restores the
    /// one Inspector only when it is minimized. A visible compact Inspector
    /// stays exactly where the user placed it.
    private func presentInspectorFromToolbar() {
        inspector.selectDomain(.adjust)

        if isInspectorMinimized {
            restoreInspector()
        }
    }

    /// Commits a direct drag of the compact Inspector without entering a
    /// second workspace mode. The offset is relative to the adaptive
    /// bottom-centered origin, so the panel keeps its current visual place
    /// when the available width changes.
    private func commitMovableInspectorDrag(with translation: CGSize, in size: CGSize) {
        let proposed = CGSize(
            width: workspaceState.floatingPanelOffset.width + translation.width,
            height: workspaceState.floatingPanelOffset.height + translation.height
        )
        workspaceState.floatingPanelOffset = PadFloatingPanelLayout.clampedOffset(
            proposedOffset: proposed,
            panelOrigin: movableInspectorOrigin(for: size),
            panelSize: floatingPanelMeasuredSize,
            availableSize: size,
            minimumVisibleEdge: Self.floatingPanelMinimumVisibleEdge
        )
    }

    // MARK: - Inspector presentation

    /// The explicit entry point for the adjustment popup. It reuses the
    /// single adaptive Inspector instead of introducing a second sheet or a
    /// separate floating-panel toggle.
    private var inspectorPresentationButton: some View {
        Button(action: presentInspectorFromToolbar) {
            Label(L10n.t("Adjustments"), systemImage: "slider.horizontal.3")
        }
        .accessibilityLabel(Text(L10n.t("Adjustments")))
        .accessibilityHint(Text(L10n.t("Show Inspector")))
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

    private func workspaceContent(for size: CGSize) -> some View {
        workLayout(for: size)
    }

    @ViewBuilder
    private func workLayout(for size: CGSize) -> some View {
        let plan = PadEditorLayoutPolicy.plan(for: size)
        ZStack(alignment: .topLeading) {
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
            case .bottomDrawer, .floating:
                canvas(for: size)
                if !isInspectorMinimized {
                    movableInspectorPanel(for: size)
                        .background(floatingPanelSizeReader)
                        .offset(
                            x: movableInspectorOrigin(for: size).x
                                + workspaceState.floatingPanelOffset.width
                                + floatingPanelDragTranslation.width,
                            y: movableInspectorOrigin(for: size).y
                                + workspaceState.floatingPanelOffset.height
                                + floatingPanelDragTranslation.height
                        )
                }
            }

            if isInspectorMinimized {
                inspectorRestoreTile
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
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
        guard sceneWorkspaceState.isFilmstripVisible else { return false }
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

    private func trailingDockPanel(width: CGFloat) -> some View {
        inspectorPanelContent(showsDomainBar: false)
        .frame(width: width)
        .background(.thickMaterial)
    }

    /// The same Inspector surface used by the compact path. Its width and
    /// height adapt to the current GeometryReader size, while the content
    /// hierarchy and coordinator identity remain unchanged.
    private func movableInspectorPanel(for size: CGSize) -> some View {
        inspectorPanelContent
            .frame(width: PadEditorLayoutPolicy.movableInspectorWidth(for: size))
            .frame(maxHeight: PadEditorLayoutPolicy.movableInspectorHeight(for: size))
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: PadBottomDrawerMetrics.cornerRadius, style: .continuous))
            .shadow(radius: 12)
    }

    /// The single Inspector surface used before and after a move. Position
    /// and hosting container may change, but the header, domain bar, content,
    /// and adjustment controls do not.
    private var inspectorPanelContent: some View {
        inspectorPanelContent(showsDomainBar: true)
    }

    @ViewBuilder
    private func inspectorPanelContent(showsDomainBar: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            inspectorPanelHeader
            Divider()
            PadInspectorHost(
                inspector: inspector,
                navigation: inspectorNavigation,
                editor: editor,
                presetLibrary: presetLibrary,
                library: library,
                batchCoordinator: batchCoordinator,
                showsDomainBar: showsDomainBar
            )
        }
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
            reclampFloatingPanelOffset(for: availableSize)
        }
    }

    /// One header is shared by the trailing dock and movable overlay. Only
    /// this handle owns the panel drag gesture; sliders and the rest of the
    /// Inspector remain free to receive their own gestures.
    private var inspectorPanelHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                inspectorPanelDragHandle
                saveStatusIndicator
                undoRedoControls
            }
            Spacer(minLength: 0)
            inspectorMinimizeButton
        }
        .padding()
    }

    private var inspectorPanelDragHandle: some View {
        HStack(spacing: 12) {
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
            DragGesture(minimumDistance: 8)
                .updating($floatingPanelDragTranslation) { value, state, _ in
                    if isCompactInspectorPresentation {
                        state = value.translation
                    }
                }
                .onEnded { value in
                    guard isCompactInspectorPresentation else { return }
                    if PadEditorLayoutPolicy.shouldDismissMovableInspector(for: value.translation) {
                        minimizeInspector()
                    } else {
                        commitMovableInspectorDrag(with: value.translation, in: availableSize)
                    }
                }
        )
    }

    private var isCompactInspectorPresentation: Bool {
        PadEditorLayoutPolicy.presentation(
            forWidth: availableSize.width,
            height: availableSize.height
        ) == .bottomDrawer
    }

    private var inspectorMinimizeButton: some View {
        Button(action: minimizeInspector) {
            Image(systemName: "xmark.circle.fill")
                .imageScale(.large)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .accessibilityLabel(Text(L10n.t("Hide Inspector")))
        .accessibilityHint(Text(L10n.t("Show Inspector")))
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
    private func movableInspectorOrigin(for size: CGSize) -> CGPoint {
        PadEditorLayoutPolicy.movableInspectorOrigin(
            for: size,
            panelSize: floatingPanelMeasuredSize
        )
    }

    private func reclampFloatingPanelOffset(for size: CGSize) {
        guard size != .zero else { return }
        workspaceState.floatingPanelOffset = PadFloatingPanelLayout.clampedOffset(
            proposedOffset: workspaceState.floatingPanelOffset,
            panelOrigin: movableInspectorOrigin(for: size),
            panelSize: floatingPanelMeasuredSize,
            availableSize: size,
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


// MARK: - Info panel helpers

/// RGB histogram block for the Info domain. Renders the current rendered-preview
/// histogram; shows a localized fallback while histogram is nil (still computing).
struct PadHistogramBlock: View {
    let histogram: HistogramData?

    var body: some View {
        HistogramPanel(histogram: histogram)
    }
}

/// Displays the current EditorSession save state in the Info domain.
struct PadSaveStateBlock: View {
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
struct PadMetadataBlock: View {
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
