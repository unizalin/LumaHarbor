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
/// `workspaceState` (canvas zoom, floating-panel offset) is
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

    /// Document-scoped canvas scale and floating-panel position.
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

    /// The floating panel's own measured size, captured by the Inspector
    /// container. Used only for clamping; defaults to a
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
            PadEditorToolbar(
                model: model,
                editor: editor,
                batchCoordinator: batchCoordinator,
                exportedURL: exportedURL,
                selectedPhotoCount: library.selectedPhotoIDs.count,
                isExporting: $isExporting,
                isPresentingExportOptions: $isPresentingExportOptions,
                isPresentingFileExporter: $isPresentingFileExporter,
                isSavingToPhotos: $isSavingToPhotos,
                adjustmentClipboard: $adjustmentClipboard,
                clipboardFields: $clipboardFields,
                copyIncludesGeometry: $copyIncludesGeometry,
                copyIncludesLocalAdjustments: $copyIncludesLocalAdjustments,
                onClose: { Task { await model.closeCurrentDocument() } },
                onPresentInspector: presentInspectorFromToolbar,
                onSaveToPhotos: saveToPhotos,
                onBatchMessage: { batchMessage = $0 }
            )
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
            panelOrigin: PadEditorLayoutPolicy.movableInspectorOrigin(
                for: size,
                panelSize: floatingPanelMeasuredSize
            ),
            panelSize: floatingPanelMeasuredSize,
            availableSize: size,
            minimumVisibleEdge: Self.floatingPanelMinimumVisibleEdge
        )
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
                    PadEditorCanvasView(
                        editor: editor,
                        library: library,
                        services: services,
                        canvasScale: $workspaceState.canvasScale,
                        size: size,
                        filmstripPhotos: filmstripPhotos,
                        showsFilmstrip: shouldShowFilmstrip(forWidth: size.width),
                        onSelectFilmstripPhoto: openFilmstripPhoto
                    )
                    if !isInspectorMinimized {
                        Divider()
                        inspectorContainer(
                            presentation: .trailingDock,
                            dockWidth: plan.inspectorWidth ?? PadEditorLayoutPolicy.minimumInspectorWidth,
                            availableSize: size,
                            isRestoreTile: false
                        )
                    }
                }
            case .bottomDrawer:
                PadEditorCanvasView(
                    editor: editor,
                    library: library,
                    services: services,
                    canvasScale: $workspaceState.canvasScale,
                    size: size,
                    filmstripPhotos: filmstripPhotos,
                    showsFilmstrip: shouldShowFilmstrip(forWidth: size.width),
                    onSelectFilmstripPhoto: openFilmstripPhoto
                )
                if !isInspectorMinimized {
                    inspectorContainer(
                        presentation: .bottomDrawer,
                        dockWidth: nil,
                        availableSize: size,
                        isRestoreTile: false
                    )
                }
            }

            if isInspectorMinimized {
                inspectorContainer(
                    presentation: plan.presentation,
                    dockWidth: plan.inspectorWidth,
                    availableSize: size,
                    isRestoreTile: true
                )
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    /// Builds the one Inspector surface used by both adaptive presentations.
    /// The root only supplies shared state and event closures; movement,
    /// drag-dismiss, and panel chrome live in `PadEditorInspectorContainer`.
    private func inspectorContainer(
        presentation: PadInspectorPresentation,
        dockWidth: CGFloat?,
        availableSize: CGSize,
        isRestoreTile: Bool
    ) -> some View {
        PadEditorInspectorContainer(
            inspector: inspector,
            navigation: inspectorNavigation,
            editor: editor,
            presetLibrary: presetLibrary,
            library: library,
            batchCoordinator: batchCoordinator,
            isMinimized: $isInspectorMinimized,
            floatingPanelOffset: $workspaceState.floatingPanelOffset,
            availableSize: availableSize,
            floatingPanelMeasuredSize: floatingPanelMeasuredSize,
            presentation: presentation,
            dockWidth: dockWidth,
            onMeasurePanel: { measuredSize in
                floatingPanelMeasuredSize = measuredSize
                reclampFloatingPanelOffset(for: availableSize)
            },
            onCommitDrag: { translation, dragSize in
                commitMovableInspectorDrag(with: translation, in: dragSize)
            },
            onMinimize: minimizeInspector,
            onRestore: restoreInspector,
            isRestoreTile: isRestoreTile
        )
    }

    private func shouldShowFilmstrip(forWidth width: CGFloat) -> Bool {
        guard sceneWorkspaceState.isFilmstripVisible else { return false }
        return PadWorkspaceLayoutPolicy.layout(forWidth: width).showsFilmstrip
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
            model.openLibraryAsset(asset)
        }
    }

    /// Re-clamps the stored panel offset whenever the available area or the
    /// measured content size changes, keeping the drag handle reachable after
    /// rotation, Split View, or dynamic type changes.
    private func reclampFloatingPanelOffset(for size: CGSize) {
        guard size != .zero else { return }
        workspaceState.floatingPanelOffset = PadFloatingPanelLayout.clampedOffset(
            proposedOffset: workspaceState.floatingPanelOffset,
            panelOrigin: PadEditorLayoutPolicy.movableInspectorOrigin(
                for: size,
                panelSize: floatingPanelMeasuredSize
            ),
            panelSize: floatingPanelMeasuredSize,
            availableSize: size,
            minimumVisibleEdge: Self.floatingPanelMinimumVisibleEdge
        )
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

    private func alertBody(_ alert: EditorAlert) -> String {
        [alert.message, alert.nextStep].compactMap { $0 }.joined(separator: "\n\n")
    }
}
